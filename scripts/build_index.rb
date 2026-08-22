#!/usr/bin/env ruby
# frozen_string_literal: true

# build_index.rb -- Build a constant-reference index for a Ruby/Rails codebase.
#
# Ruby has no import statements. Zeitwerk autoloads constants by path convention,
# so the dependency graph of a Rails app *is* its constant-reference graph.
#
# This lexes every .rb file with Ripper (stdlib -- no gems, no bundler) and records:
#   - constants each file DEFINES   (Zeitwerk path convention, verified against tokens)
#   - constants each file REFERENCES, with line numbers and edge kind
#
# Edge kinds: superclass, mixin, association, delegation, dsl_string, reference
#
# Emits JSON on stdout. Consumed by analyze_domain.rb.

require 'ripper'
require 'json'
require 'set'
require 'optparse'

module ExtractScout
  # Directories that are never application code.
  DEFAULT_EXCLUDES = %w[
    vendor node_modules tmp log coverage public storage .git .bundle
    db/migrate node_modules/.bin
  ].freeze

  TEST_DIRS = %w[spec test features].freeze

  # Ambient infrastructure: a constant so widely reached that its presence in one
  # domain's report says nothing about that domain. A concern included by 52 of an
  # app's 60 units is not coupling to be broken -- it is already a shared library,
  # and "promote it to a shared library" is unactionable advice.
  #
  # Measured rather than listed, because a list of framework names rots with every
  # Rails release while "reached by most of the app" stays true by construction.
  # This is the same principle the resolver already applies to gem code ("not
  # defined in this repo") extended to code that IS defined here.
  #
  # A ratio travels across repo sizes where a fixed count does not; the absolute
  # floor stops a six-unit app from manufacturing infrastructure out of noise; and
  # the measurable minimum stops the ratio being computed where it is meaningless.
  # Edges that say "this constant is scaffolding I am built ON", as opposed to
  # "this constant is a thing I use". The distinction is what separates a shared
  # concern from a god-model, and on real code it is bimodal: Mastodon's
  # ApplicationRecord is 93% structural and BaseService, Redisable and
  # RoutingHelper are 100%, while Account, Status, User and Tag are all 0%.
  #
  # Breadth alone cannot tell them apart -- Account has the WIDEST reach in the
  # app at 171 units, and it is the single most important coupling fact there,
  # not noise. A breadth-only rule deletes the headline.
  STRUCTURAL_KINDS = %w[mixin superclass].freeze
  AMBIENT_STRUCTURAL_PCT = 90
  AMBIENT_MIN_UNITS = 10
  AMBIENT_MEASURABLE_MIN = 12

  ASSOCIATION_MACROS = %w[belongs_to has_many has_one has_and_belongs_to_many].freeze
  MIXIN_MACROS       = %w[include extend prepend].freeze

  # Bracket tokens, for finding the end of a logical statement. :on_tlambeg is
  # the `{` of a `-> { }` scope, which Ripper lexes distinctly from :on_lbrace;
  # both are closed by :on_rbrace.
  OPENERS = %i[on_lparen on_lbracket on_lbrace on_tlambeg on_embexpr_beg].freeze
  CLOSERS = %i[on_rparen on_rbracket on_rbrace on_embexpr_end].freeze

  # Base classes so ubiquitous that edges to them are noise rather than signal.
  # These ARE defined in the repo, so resolution-filtering won't drop them.
  DEFAULT_UBIQUITOUS = %w[
    ApplicationRecord ApplicationController ApplicationJob ApplicationMailer
    ApplicationHelper ApplicationService ApplicationPolicy ApplicationSerializer
    ApplicationCable ApplicationDecorator ApplicationInteractor
  ].freeze

  # Ruby's own irregular plurals we can't derive. Kept deliberately tiny --
  # ActiveSupport::Inflector isn't available without loading Rails.
  IRREGULAR_SINGULAR = {
    'people' => 'person', 'children' => 'child', 'men' => 'man',
    'women' => 'woman', 'teeth' => 'tooth', 'feet' => 'foot',
    'mice' => 'mouse', 'geese' => 'goose', 'data' => 'datum',
    'indices' => 'index', 'matrices' => 'matrix', 'vertices' => 'vertex',
    'statuses' => 'status', 'aliases' => 'alias', 'taxes' => 'tax'
  }.freeze

  # ---------------------------------------------------------------- inflection

  module Inflect
    module_function

    # Repo-specific rules, loaded once per index build by InflectionRules.load.
    #
    # This is module-level state, which is a smell in a library and deliberate in
    # a CLI: every caller in the process is analyzing the same repo, and
    # threading an inflector through AutoloadRoots, FileAnalyzer and the hook
    # would add a parameter to every call site to express something that is
    # genuinely global to a run. `reset!` keeps it testable.
    def config
      @config ||= { acronyms: {}, irregular: {}, uncountable: Set.new, overrides: {} }
    end

    def reset!
      @config = nil
    end

    def configure(acronyms: [], irregular: {}, uncountable: [], overrides: {})
      config[:acronyms]   = acronyms.to_h { |a| [a.downcase, a] }
      config[:irregular]  = irregular
      config[:uncountable] = Set.new(uncountable)
      config[:overrides]  = overrides
      config
    end

    def camelize(str)
      # An explicit Zeitwerk override is the last word -- it exists precisely
      # because the derived name was wrong.
      return config[:overrides][str] if config[:overrides].key?(str)

      str.split('_').map do |part|
        next part if part.empty?

        config[:acronyms][part] || (part[0].upcase + part[1..].to_s)
      end.join
    end

    def all_irregular
      IRREGULAR_SINGULAR.merge(config[:irregular])
    end

    def singularize(word)
      return word if config[:uncountable].include?(word)

      table = all_irregular
      return table[word] if table.key?(word)

      # ActiveSupport applies irregular rules as suffix patterns, not whole-word
      # ones: preview_cards_statuses singularizes to preview_cards_status, and a
      # whole-word table returns preview_cards_statuse. The underscore boundary
      # is what stops 'gratuses' matching the 'statuses' rule.
      table.each do |plural_form, singular_form|
        next unless word.end_with?("_#{plural_form}")

        return "#{word[0...-plural_form.length]}#{singular_form}"
      end

      case word
      when /(.*[^aeiou])ies\z/          then "#{Regexp.last_match(1)}y"
      when /(.*)(ch|sh|ss|x|z)es\z/     then "#{Regexp.last_match(1)}#{Regexp.last_match(2)}"
      when /(.*)ves\z/                  then "#{Regexp.last_match(1)}f"
      when /(.*[^s])s\z/                then Regexp.last_match(1)
      else word
      end
    end

    # :line_items -> "LineItem"
    def association_constant(symbol_name, plural:)
      base = plural ? singularize(symbol_name) : symbol_name
      camelize(base)
    end
  end

  # -------------------------------------------------------- inflection rules
  #
  # Rails apps configure their own inflections, and when they do, every constant
  # carrying the rule mis-resolves without them: `inflect.acronym 'API'` makes
  # app/models/api_key.rb define APIKey, and a tool deriving ApiKey drops every
  # edge touching it. That is the D1 failure mode -- a constant resolving to
  # nothing, dropped silently, understating coupling with no visible symptom.
  #
  # Read with Ripper rather than regex, so a commented-out rule is not a rule.
  module InflectionRules
    # Rules are not only in the app's own config/initializers. Solidus declares
    # `acronym "RMA"` in core/config/initializers -- a GEM's initializers -- and
    # `acronym "UI"` inside admin/lib/solidus_admin/engine.rb. Any initializer
    # may declare them, so the globs are wide and the cheap substring check
    # below keeps the cost to one read per candidate.
    SOURCE_GLOBS = [
      'config/initializers/*.rb',
      '*/config/initializers/*.rb',
      'engines/*/config/initializers/*.rb',
      'lib/**/engine.rb',
      '*/lib/**/engine.rb'
    ].freeze

    module_function

    def load(repo_root)
      found = { acronyms: [], irregular: {}, uncountable: [], overrides: {} }
      SOURCE_GLOBS.each do |glob|
        Dir.glob(File.join(repo_root, glob)).sort.each do |abs|
          next unless File.file?(abs)

          source = File.read(abs)
          # Cheap gate: only the handful of files that mention it get lexed.
          next unless source.include?('inflect')

          merge!(found, extract(source))
        end
      end
      found
    rescue StandardError
      { acronyms: [], irregular: {}, uncountable: [], overrides: {} }
    end

    def merge!(into, from)
      into[:acronyms]    |= from[:acronyms]
      into[:uncountable] |= from[:uncountable]
      into[:irregular].merge!(from[:irregular])
      into[:overrides].merge!(from[:overrides])
      into
    end

    # Collects the string literals following each rule call, on that call's own
    # logical line -- the same shape scan_for_class_name uses for class_name:.
    def extract(source)
      out = { acronyms: [], irregular: {}, uncountable: [], overrides: {} }
      tokens = begin
        Ripper.lex(source)
      rescue StandardError
        nil
      end
      return out if tokens.nil?

      tokens.each_with_index do |tok, i|
        (line, _col), type, value = tok
        next unless type == :on_ident

        strings = strings_on_line(tokens, i, line)
        case value
        when 'acronym'     then out[:acronyms] |= strings.first(1)
        when 'uncountable' then out[:uncountable] |= strings
        when 'irregular'
          out[:irregular][strings[1]] = strings[0] if strings.size >= 2
        when 'singular'
          # inflect.singular 'data', 'data' -- states the singular form directly,
          # and overrides our own table, which says data -> datum.
          out[:irregular][strings[0]] = strings[1] if strings.size >= 2
        when 'inflect'
          # Two different things are spelled `inflect`. The Zeitwerk override is
          # a CALL -- inflector.inflect("html_parser" => "HTMLParser"). The other
          # is the block variable in an inflections block, where `inflect` is a
          # RECEIVER: inflect.singular 'data', 'data'. Only the call carries
          # camelize overrides, and a receiver is followed by a period.
          next if receiver?(tokens, i)

          strings.each_slice(2) { |k, v| out[:overrides][k] = v if k && v }
        end
      end
      out
    end

    def receiver?(tokens, i)
      j = i + 1
      j += 1 while j < tokens.length && %i[on_sp on_nl on_ignored_nl].include?(tokens[j][1])
      j < tokens.length && tokens[j][1] == :on_period
    end

    # Ripper never yields a comment's contents as :on_tstring_content, so a
    # commented-out rule contributes nothing and needs no special case.
    def strings_on_line(tokens, start, line)
      found = []
      j = start + 1
      while j < tokens.length
        (tok_line, _c), type, value = tokens[j]
        # `inflect(...)` spans lines; keep reading while the args do.
        break if tok_line > line && type == :on_ident

        found << value if type == :on_tstring_content
        break if type == :on_nl && found.any?

        j += 1
      end
      found
    end
  end

  # ------------------------------------------------------------ path -> const

  # Rails autoload roots. Every subdirectory of app/ is its own root, which is
  # why app/models/billing/invoice.rb is Billing::Invoice and not
  # App::Models::Billing::Invoice.
  class AutoloadRoots
    GEM_EXCLUDED_SEGMENTS = %w[spec test tmp vendor node_modules dummy].freeze

    def initialize(repo_root)
      @repo_root = repo_root
      @roots = discover
    end

    attr_reader :roots

    def discover
      found = []
      # app/<subdir> for the main app and for every engine/pack/component.
      #
      # gem_app_globs picks up engine monorepos, where each gem sits in a
      # top-level directory of its own -- Solidus is core/, api/, admin/,
      # backend/ and so on. Matching only the engines|packs|components names
      # found zero roots there, and 1204 files were indexed with no constants at
      # all. A .gemspec is the marker that says "this directory is a gem".
      (%w[app engines/*/app packs/*/app components/*/app lib/*/app] + gem_app_globs).each do |glob|
        Dir.glob(File.join(@repo_root, glob, '*')).each do |dir|
          found << dir if File.directory?(dir)
        end
        # Rails registers app/*/concerns as autoload roots in their own right,
        # so app/models/concerns/auditable.rb defines Auditable -- NOT
        # Concerns::Auditable. Getting this wrong silently orphans every concern.
        Dir.glob(File.join(@repo_root, glob, '*', 'concerns')).each do |dir|
          found << dir if File.directory?(dir)
        end
      end
      # lib/ is an autoload root only when the app opts in. Rails 7+ does not
      # autoload it by default, and a lib/ that is NOT autoloaded typically
      # holds gem monkey-patches: lib/paperclip/url_generator_extensions.rb
      # reopens Paperclip, it does not define Paperclip::UrlGeneratorExtensions.
      # Assuming the root invents a constant per file and then reports each one
      # as a missing inflection rule.
      if autoloads_lib?
        %w[lib engines/*/lib packs/*/lib components/*/lib].each do |glob|
          Dir.glob(File.join(@repo_root, glob)).each do |dir|
            found << dir if File.directory?(dir)
          end
        end
      end
      # Longest first so the most specific root wins.
      found.uniq.sort_by { |d| -d.length }
    end

    # Directories holding a .gemspec, as app-relative globs. Excluded segments
    # keep a gem's own spec/dummy harness from registering as application code.
    def gem_app_globs
      Dir.glob(File.join(@repo_root, '*', '*.gemspec')).filter_map do |spec|
        rel = File.dirname(spec).delete_prefix("#{@repo_root}/")
        next if rel.split('/').any? { |seg| GEM_EXCLUDED_SEGMENTS.include?(seg) }

        "#{rel}/app"
      end.uniq
    end

    # Read with Ripper so a commented-out `config.autoload_lib` -- which is how
    # the line ships in a generated Rails app -- is not mistaken for an opt-in.
    def autoloads_lib?
      return @autoloads_lib unless @autoloads_lib.nil?

      @autoloads_lib = Dir.glob(File.join(@repo_root, 'config', 'application.rb')).any? do |cfg|
        tokens = begin
          Ripper.lex(File.read(cfg))
        rescue StandardError
          nil
        end
        next false if tokens.nil?

        idents = tokens.select { |(_p, type, _v)| type == :on_ident }.map { |t| t[2] }
        next true if idents.include?('autoload_lib')

        (idents & %w[autoload_paths eager_load_paths]).any? &&
          tokens.any? { |(_p, type, v)| type == :on_tstring_content && v.to_s.split('/').include?('lib') }
      end
    end

    # Returns the fully-qualified constant Zeitwerk would autoload from this path,
    # or nil if the file sits outside every autoload root.
    def constant_for(abs_path)
      root = @roots.find { |r| abs_path.start_with?("#{r}/") }
      return nil unless root

      rel = abs_path.delete_prefix("#{root}/").delete_suffix('.rb')
      rel.split('/').map { |seg| Inflect.camelize(seg) }.join('::')
    end
  end

  # ------------------------------------------------------------ with_options
  #
  # `with_options class_name: 'Account' do ... end` applies the override to every
  # association in the block. That is D1's cousin: the override is not on the
  # macro's line, nor on a continuation of it, but on an enclosing block, and
  # every association inside inherits it. Missing it fabricates one constant per
  # association, each resolving to nothing.
  #
  # Ripper.lex cannot see block structure, so this takes one Ripper.sexp pass,
  # gated on the string appearing at all -- a file without with_options pays
  # only a substring check.
  module WithOptions
    module_function

    # => { line_number => class_name }
    def scan(source)
      return {} unless source.include?('with_options')

      tree = begin
        Ripper.sexp(source)
      rescue StandardError
        nil
      end
      return {} if tree.nil?

      out = {}
      walk(tree, nil, out)
      out
    end

    def walk(node, inherited, out)
      return unless node.is_a?(Array)

      if node[0] == :method_add_block
        name, = call_info(node[1])
        if name == 'with_options'
          walk(node[2], class_name_in(node[1]) || inherited, out)
          return
        end
      end

      if inherited
        name, line = call_info(node)
        out[line] = inherited if line && ASSOCIATION_MACROS.include?(name)
      end

      node.each { |child| walk(child, inherited, out) }
    end

    # Handles `belongs_to :x` (:command) and `belongs_to(:x)` (:method_add_arg).
    def call_info(node)
      return [nil, nil] unless node.is_a?(Array)

      ident =
        case node[0]
        when :command then node[1]
        when :method_add_arg
          node[1].is_a?(Array) && node[1][0] == :fcall ? node[1][1] : nil
        end
      return [nil, nil] unless ident.is_a?(Array) && ident[0] == :@ident

      [ident[1], ident[2].is_a?(Array) ? ident[2][0] : nil]
    end

    def class_name_in(node)
      found = nil
      visit = lambda do |n|
        return if found
        return unless n.is_a?(Array)

        if n[0] == :assoc_new && n[1].is_a?(Array) && n[1][0] == :@label && n[1][1] == 'class_name:'
          found = string_value(n[2])
        end
        n.each { |c| visit.call(c) }
      end
      visit.call(node)
      found
    end

    def string_value(node)
      return nil unless node.is_a?(Array) && node[0] == :string_literal

      content = node[1].is_a?(Array) ? node[1][1] : nil
      content[1] if content.is_a?(Array) && content[0] == :@tstring_content
    end
  end

  # ------------------------------------------------------------------ analyzer

  Ref = Struct.new(:const, :line, :kind, keyword_init: true)

  # When the same constant is seen twice on one line by two different detectors
  # (`class_name: "Billing::Invoice"` is both an association target and a
  # constant-shaped string), keep the most specific reading.
  KIND_PRIORITY = {
    'superclass' => 0, 'association' => 1, 'polymorphic' => 2, 'mixin' => 3,
    'delegation' => 4, 'reference' => 5, 'polymorphic_ref' => 6, 'dsl_string' => 7
  }.freeze

  # A string is only a constant reference when some DSL gives it that meaning.
  # `*_type` is Rails' polymorphic discriminator; the rest are the places a
  # class name is conventionally written as a string.
  DISCRIMINATOR_LABEL = /\A[a-z_]*_type:\z/.freeze
  DISCRIMINATOR_IDENT = /\A[a-z_]*_type\z/.freeze
  CONSTANTIZERS       = %w[constantize safe_constantize].freeze
  CONST_STRING_LABELS = %w[class_name: job_class: parent_mailer: serializer:].freeze
  ROUTING_TARGET      = %r{\A[a-z0-9_]+(/[a-z0-9_]+)+#[a-z0-9_]+\z}.freeze
  CONST_SHAPE         = /\A[A-Z][A-Za-z0-9_]*(::[A-Z][A-Za-z0-9_]*)*\z/.freeze

  class FileAnalyzer
    # Files whose has_many/has_one/belongs_to declare serialized attributes
    # rather than ActiveRecord associations.
    SERIALIZER_DIRS = %w[serializers presenters representers].freeze

    def initialize(path, source)
      @path = path
      @source = source
      @defines = []
      @refs = []
      @with_options = WithOptions.scan(source)
      # Token indices of string literals already consumed as a `class_name:`
      # value. Without this the override string is re-detected by
      # maybe_dsl_string as a phantom coupling on its own line, which dedupe!
      # cannot merge away because the association edge sits on the macro's line.
      @consumed_strings = Set.new
      # association symbol => class it resolves to, for `through:` lookups.
      # Through associations go in @assoc_through instead, so a chain follows to
      # the base rather than stopping at a name-inferred constant.
      @assoc_class = {}
      @assoc_through = {}
      @pending_through = []
      # Polymorphic interfaces this file declares (`belongs_to :x, polymorphic:
      # true`) and implements (`has_one :y, as: :x`). Both halves are needed:
      # the target set of a polymorphic association is never in the file that
      # declares it.
      @polymorphic = []
      @polymorphic_impls = []
    end

    attr_reader :defines, :refs, :polymorphic, :polymorphic_impls

    def analyze
      tokens = lex
      return self if tokens.nil?

      i = 0
      while i < tokens.length
        tok = tokens[i]
        (line, _col), type, value = tok

        case type
        when :on_kw
          if %w[class module].include?(value)
            i = handle_definition(tokens, i, line)
            next
          end
        when :on_ident
          if MIXIN_MACROS.include?(value) && command_position?(tokens, i)
            i = handle_mixin(tokens, i, line)
            next
          elsif ASSOCIATION_MACROS.include?(value) && command_position?(tokens, i)
            i = handle_association(tokens, i, line, value)
            next
          elsif value == 'delegate' && command_position?(tokens, i)
            i = handle_delegate(tokens, i, line)
            next
          end
        when :on_const
          const, consumed = read_const_path(tokens, i)
          if const
            # `EligibilityResult = Struct.new(...)` defines a constant just as a
            # class keyword does. Recording it as a reference instead made the
            # file look like it declared only its enclosing module, which the
            # name-mismatch tripwire then blamed on a missing inflection rule.
            if constant_assignment?(tokens, i + consumed)
              @defines << { 'const' => const, 'line' => line }
            else
              @refs << Ref.new(const: const, line: line, kind: 'reference')
            end
          end
          i += consumed
          next
        when :on_tstring_content
          maybe_dsl_string(tokens, i, value, line) unless @consumed_strings.include?(i)
        end

        i += 1
      end

      emit_through_edges

      # ActiveModel::Serializer reuses the association macro names for
      # serialized attributes: `has_one :object, serializer: FollowSerializer`
      # declares an attribute, and there is no Object model. On Mastodon this
      # was 105 of 153 unresolved associations. The real dependency -- the
      # serializer named in the option -- is already recorded by the constant
      # scanner, so dropping these loses nothing.
      @refs.reject! { |r| r.kind == 'association' } if serializer_context?

      dedupe!
      self
    end

    def serializer_context?
      return true if @path.to_s.split('/').any? { |seg| SERIALIZER_DIRS.include?(seg) }

      @refs.any? do |r|
        r.kind == 'superclass' && r.const.split('::').last.end_with?('Serializer')
      end
    end

    private

    def dedupe!
      best = {}
      @refs.each do |ref|
        key = [ref.const, ref.line]
        incumbent = best[key]
        if incumbent.nil? || KIND_PRIORITY.fetch(ref.kind, 9) < KIND_PRIORITY.fetch(incumbent.kind, 9)
          best[key] = ref
        end
      end
      @refs = best.values.sort_by { |r| [r.line, r.const] }
    end

    # Ripper.lex never raises on syntax errors -- it returns what it could lex --
    # but a file using syntax newer than the running Ruby yields garbage. Guard it.
    def lex
      Ripper.lex(@source)
    rescue StandardError
      nil
    end

    def significant?(type)
      ![:on_sp, :on_nl, :on_ignored_nl, :on_comment, :on_embdoc,
        :on_embdoc_beg, :on_embdoc_end].include?(type)
    end

    # A single `=` immediately after the constant path. `==`, `=>` and `||=` are
    # distinct token values, so an exact match tells them apart.
    def constant_assignment?(tokens, after)
      j = nxt(tokens, after)
      j < tokens.length && tokens[j][1] == :on_op && tokens[j][2] == '='
    end

    # Index of the next significant token at or after i.
    def nxt(tokens, i)
      j = i
      j += 1 while j < tokens.length && !significant?(tokens[j][1])
      j
    end

    # A bare `include Foo` is a method call in command position. `x.include Foo`
    # or `foo(include: 1)` are not -- guard against both.
    def command_position?(tokens, i)
      j = i - 1
      j -= 1 while j >= 0 && !significant?(tokens[j][1])
      return true if j.negative?

      prev_type, prev_val = tokens[j][1], tokens[j][2]
      # Ripper lexes a plain `.` as :on_period, NOT :on_op. Matching only :on_op
      # here silently let `obj.extend Foo` through as a mixin edge, which then
      # inflated the shared_mixin seam with receiver calls that mix nothing in.
      return false if prev_type == :on_period
      return false if prev_type == :on_op && %w[&. ::].include?(prev_val)
      return false if prev_type == :on_symbeg
      return false if prev_type == :on_label

      # `include:` as a hash key -- the *next* token tells us.
      k = nxt(tokens, i + 1)
      return false if k < tokens.length && tokens[k][1] == :on_label_end

      true
    end

    # Reads Foo::Bar::Baz starting at a :on_const. Returns [full_path, tokens_consumed].
    def read_const_path(tokens, i)
      parts = [tokens[i][2]]
      consumed = 1
      j = i + 1
      loop do
        j = nxt(tokens, j)
        break unless j < tokens.length && tokens[j][1] == :on_op && tokens[j][2] == '::'

        k = nxt(tokens, j + 1)
        break unless k < tokens.length && tokens[k][1] == :on_const

        parts << tokens[k][2]
        consumed = (k - i) + 1
        j = k + 1
      end
      [parts.join('::'), consumed]
    end

    def handle_definition(tokens, i, line)
      j = nxt(tokens, i + 1)
      # `class ::Spree::Foo` reopens a class from inside a namespace without
      # relative resolution. Skip the leading `::` so the definition is seen --
      # missing it dropped the class entirely and left the file appearing to
      # declare only whatever constant it assigned next.
      j = nxt(tokens, j + 1) if j < tokens.length && tokens[j][1] == :on_op && tokens[j][2] == '::'
      # `class << self` and anonymous `Class.new` forms have no const here.
      return i + 1 unless j < tokens.length && tokens[j][1] == :on_const

      name, consumed = read_const_path(tokens, j)
      @defines << { 'const' => name, 'line' => line }
      after = j + consumed

      # Superclass: `class Invoice < ApplicationRecord`
      k = nxt(tokens, after)
      if k < tokens.length && tokens[k][1] == :on_op && tokens[k][2] == '<'
        m = nxt(tokens, k + 1)
        # `class Foo < ::Spree::Base` -- same leading `::` as the definition
        # side. Without this the parent is still seen, but as a plain reference
        # rather than a superclass edge, which ranks differently in the seams.
        m = nxt(tokens, m + 1) if m < tokens.length && tokens[m][1] == :on_op && tokens[m][2] == '::'
        if m < tokens.length && tokens[m][1] == :on_const
          sup, sup_consumed = read_const_path(tokens, m)
          @refs << Ref.new(const: sup, line: tokens[m][0][0], kind: 'superclass')
          return m + sup_consumed
        end
      end

      after
    end

    def handle_mixin(tokens, i, line)
      j = nxt(tokens, i + 1)
      return i + 1 unless j < tokens.length && tokens[j][1] == :on_const

      const, consumed = read_const_path(tokens, j)
      @refs << Ref.new(const: const, line: line, kind: 'mixin')
      j + consumed
    end

    # belongs_to :order                       -> Order
    # has_many   :line_items                  -> LineItem
    # has_many   :entries, class_name: "Ledger::Entry" -> Ledger::Entry (explicit wins)
    def handle_association(tokens, i, line, macro)
      plural = macro.start_with?('has_') && macro != 'has_one'
      j = nxt(tokens, i + 1)
      return i + 1 unless j < tokens.length && tokens[j][1] == :on_symbeg

      k = nxt(tokens, j + 1)
      return i + 1 unless k < tokens.length && %i[on_ident on_const].include?(tokens[k][1])

      name = tokens[k][2]
      opts = scan_association_options(tokens, k)

      # A polymorphic belongs_to names an interface, not a class. Inferring a
      # constant from the association name fabricates one that does not exist;
      # the real targets are resolved across files by the Indexer.
      if opts[:polymorphic]
        @polymorphic << { 'name' => name, 'line' => line }
        return k + 1
      end

      # An explicit class_name on the macro itself is more specific than one
      # inherited from an enclosing with_options block, so it wins.
      const = opts[:class_name] || @with_options[line] ||
              Inflect.association_constant(name, plural: plural)
      @refs << Ref.new(const: const, line: line, kind: 'association')

      if opts[:as]
        @polymorphic_impls << { 'interface' => opts[:as], 'const' => const, 'line' => line }
      end

      if opts[:through]
        @assoc_through[name] = opts[:through]
        @pending_through << [opts[:through], line]
      else
        @assoc_class[name] = const
      end
      k + 1
    end

    # A `has_many :through` depends on two models: the join, which this file
    # always names, and the far end, which is decided by the `source:`
    # association on the join and so cannot be resolved from one file. The far
    # end is already emitted as a guess from the association name -- right often
    # enough to be worth keeping, and dropped downstream when the constant does
    # not exist. The join is the half that is always knowable here.
    def emit_through_edges
      @pending_through.each do |sym, line|
        @refs << Ref.new(const: resolve_join(sym), line: line, kind: 'association')
      end
    end

    # Follows `through:` chains to the first association whose class this file
    # states. `seen` makes a self- or mutually-referential chain terminate.
    def resolve_join(sym, seen = [])
      return @assoc_class[sym] if @assoc_class.key?(sym)

      nxt_sym = @assoc_through[sym]
      return resolve_join(nxt_sym, seen + [sym]) if nxt_sym && !seen.include?(sym)

      Inflect.association_constant(sym, plural: sym.end_with?('s'))
    end

    # Walks to the end of the association's logical statement looking for an
    # explicit class_name:. Rails wraps these across lines constantly, and
    # stopping at the macro's own physical line pointed the edge at a constant
    # that does not exist -- which then resolved to nothing and was dropped.
    #
    # Statement end is an :on_nl at bracket depth 0. Both halves are load
    # bearing: a newline after a trailing comma lexes as :on_ignored_nl so
    # newline kind alone gets the common case right, but a newline *inside* a
    # brace-delimited option lexes as :on_nl, so depth is what stops that case
    # from ending the scan one option early.
    def scan_association_options(tokens, start)
      opts = {}
      depth = 0
      j = start
      while j < tokens.length
        type = tokens[j][1]
        if OPENERS.include?(type)
          depth += 1
        elsif CLOSERS.include?(type)
          depth -= 1
        elsif type == :on_nl && depth <= 0
          break
        elsif type == :on_label
          case tokens[j][2]
          when 'class_name:'  then opts[:class_name]  ||= read_class_name(tokens, j)
          when 'through:'     then opts[:through]     ||= read_symbol_value(tokens, j)
          when 'as:'          then opts[:as]          ||= read_symbol_value(tokens, j)
          when 'polymorphic:' then opts[:polymorphic] ||= true_literal?(tokens, j)
          end
        end
        j += 1
      end
      opts
    end

    # polymorphic: true -- only the literal counts. `polymorphic: flag` is not
    # something this analysis can evaluate, so it is left as an ordinary edge.
    def true_literal?(tokens, label_index)
      k = nxt(tokens, label_index + 1)
      k < tokens.length && tokens[k][1] == :on_kw && tokens[k][2] == 'true' || nil
    end

    # class_name: "Billing::Invoice"  (string) or ::Billing::Invoice (const)
    def read_class_name(tokens, label_index)
      k = nxt(tokens, label_index + 1)
      return nil unless k < tokens.length

      if tokens[k][1] == :on_tstring_beg
        m = nxt(tokens, k + 1)
        return nil unless m < tokens.length && tokens[m][1] == :on_tstring_content

        @consumed_strings << m
        tokens[m][2]
      elsif tokens[k][1] == :on_const
        read_const_path(tokens, k).first
      end
    end

    # through: :account_linked_accounts -> "account_linked_accounts"
    def read_symbol_value(tokens, label_index)
      k = nxt(tokens, label_index + 1)
      return nil unless k < tokens.length && tokens[k][1] == :on_symbeg

      m = nxt(tokens, k + 1)
      return nil unless m < tokens.length && tokens[m][1] == :on_ident

      tokens[m][2]
    end

    # delegate :total, to: :invoice  -- a real dependency, but weaker: the target
    # is a method, not a constant, so we record it only when it names a constant.
    def handle_delegate(tokens, i, line)
      j = i
      while j < tokens.length && tokens[j][0][0] == line
        if tokens[j][1] == :on_label && tokens[j][2] == 'to:'
          k = nxt(tokens, j + 1)
          if k < tokens.length && tokens[k][1] == :on_const
            const, = read_const_path(tokens, k)
            @refs << Ref.new(const: const, line: line, kind: 'delegation')
          end
          break
        end
        j += 1
      end
      i + 1
    end

    # Rails hides constant references inside strings -- but most capitalised
    # strings are just words. Matching on shape alone recorded 'UTC', 'DocuSeal'
    # and 'Checkbox' as constants: 94% of dsl_string refs were unresolvable
    # noise, and that made the survivors untrustworthy too. Require a syntactic
    # reason, and separate the polymorphic discriminators from the rest.
    def maybe_dsl_string(tokens, i, value, line)
      return unless value.is_a?(String)

      if value.match?(ROUTING_TARGET)
        # "billing/invoices#show" -> Billing::InvoicesController
        const = value.split('#').first.split('/').map { |s| Inflect.camelize(s) }.join('::')
        @refs << Ref.new(const: "#{const}Controller", line: line, kind: 'dsl_string')
        return
      end
      return unless value.match?(CONST_SHAPE) && value.length > 2

      # Context first: `record_type: 'Billing::Invoice'` is a discriminator
      # whether or not it is namespaced. Only when no DSL explains the string
      # does its shape decide -- a `::` is evidence in itself, since prose
      # almost never carries a scope operator, while the single-segment strings
      # are where the noise lives ('UTC', 'DocuSeal') and need a reason.
      kind = string_context(tokens, i) || (value.include?('::') ? 'dsl_string' : nil)
      @refs << Ref.new(const: value, line: line, kind: kind) if kind
    end

    # Which DSL, if any, gives this string constant meaning -- and whether that
    # DSL is a polymorphic discriminator.
    def string_context(tokens, i)
      before = prev_sig(tokens, i)
      before = prev_sig(tokens, before) if before && tokens[before][1] == :on_tstring_beg
      if before
        type, val = tokens[before][1], tokens[before][2]
        if type == :on_label
          return 'polymorphic_ref' if val.match?(DISCRIMINATOR_LABEL)
          return 'dsl_string' if CONST_STRING_LABELS.include?(val)
        end
        # `attachment.record_type != 'Submitter'`
        if type == :on_op && %w[== != <=>].include?(val)
          lhs = prev_sig(tokens, before)
          if lhs && tokens[lhs][1] == :on_ident && tokens[lhs][2].match?(DISCRIMINATOR_IDENT)
            return 'polymorphic_ref'
          end
        end
      end

      # `'BillingJob'.constantize`
      after = nxt(tokens, i + 1)
      after = nxt(tokens, after + 1) if after < tokens.length && tokens[after][1] == :on_tstring_end
      if after < tokens.length && tokens[after][1] == :on_period
        m = nxt(tokens, after + 1)
        return 'dsl_string' if m < tokens.length && CONSTANTIZERS.include?(tokens[m][2].to_s)
      end
      nil
    end

    # Index of the previous significant token, or nil at the start of the file.
    def prev_sig(tokens, i)
      j = i - 1
      j -= 1 while j >= 0 && !significant?(tokens[j][1])
      j.negative? ? nil : j
    end
  end

  # --------------------------------------------------------------------- index

  class Indexer
    def initialize(repo_root:, include_tests: false, extra_excludes: [], ubiquitous: nil)
      @repo_root = File.expand_path(repo_root)
      @include_tests = include_tests
      @excludes = DEFAULT_EXCLUDES + extra_excludes
      @excludes += TEST_DIRS unless include_tests
      @ubiquitous = Set.new(ubiquitous || DEFAULT_UBIQUITOUS)
      # Must happen before AutoloadRoots, which camelizes path segments.
      @inflections = InflectionRules.load(@repo_root)
      @packs = discover_packs
      Inflect.configure(**@inflections)
      @autoload = AutoloadRoots.new(@repo_root)
    end

    def build
      files = {}
      const_to_files = Hash.new { |h, k| h[k] = [] }
      # [owner constant, interface name] => models declaring `as: <interface>`
      # against it. Keyed on the association's own target, not the bare
      # interface name, so two models sharing an interface name stay distinct.
      impl_index = Hash.new { |h, k| h[k] = [] }
      skipped = 0

      ruby_files.each do |abs|
        rel = abs.delete_prefix("#{@repo_root}/")
        source = safe_read(abs)
        if source.nil?
          skipped += 1
          next
        end

        analyzer = FileAnalyzer.new(rel, source).analyze
        path_const = @autoload.constant_for(abs)

        # Prefer the Zeitwerk-implied constant; fall back to what the tokens said.
        # A booting Rails app guarantees these agree, so a mismatch is itself a
        # finding worth surfacing.
        declared = analyzer.defines.map { |d| d['const'] }
        primary = path_const || declared.first

        files[rel] = {
          'path'          => rel,
          'primary_const' => primary,
          'declared'      => declared,
          'autoloadable'  => !path_const.nil?,
          'loc'           => source.count("\n") + 1,
          'refs'          => analyzer.refs.map(&:to_h).map { |h| h.transform_keys(&:to_s) },
          'polymorphic'   => analyzer.polymorphic
        }

        analyzer.polymorphic_impls.each do |impl|
          next unless primary

          impl_index[[impl['const'], impl['interface']]] << primary
        end

        # Register only names Ruby would actually resolve to this file.
        # Under Zeitwerk the path is authoritative, so a bare `Calculator` token
        # inside `module Billing` must NOT own the top-level name Calculator --
        # lexical-scope lookup is the resolver's job, not the index's.
        registerable =
          if path_const
            [path_const] + declared.select { |c| c.include?('::') }
          else
            declared
          end
        registerable.compact.uniq.each { |c| const_to_files[c] << rel }
      end

      resolve_polymorphic_edges(files, impl_index)
      namespaces = derive_namespaces(files)
      ambient = derive_ambient(files)

      {
        'schema_version' => 1,
        'repo_root'      => @repo_root,
        'generated_by'   => 'extract-scout/build_index.rb',
        'stats'          => {
          'files_indexed'  => files.size,
          'files_skipped'  => skipped,
          'constants'      => const_to_files.size,
          'autoload_roots' => @autoload.roots.map { |r| r.delete_prefix("#{@repo_root}/") },
          'inflection_rules' => {
            'acronyms' => @inflections[:acronyms],
            'irregular' => @inflections[:irregular].size,
            'uncountable' => @inflections[:uncountable].size,
            'overrides' => @inflections[:overrides].size
          }
        },
        'ubiquitous'     => (@ubiquitous.to_a + ambient.keys).uniq.sort,
        'ambient'        => ambient,
        'namespaces'     => namespaces,
        'packs'          => @packs,
        'constants'      => const_to_files,
        'files'          => files
      }
    end

    private

    # The target set of a polymorphic association lives in whichever files
    # declare `as:` against it, so it can only be resolved once every file has
    # been read. An interface nobody implements yields no edges -- deliberately:
    # an unbounded polymorphic association is a finding, not an empty one, and
    # the declaration stays on the file for the report to pick up.
    def resolve_polymorphic_edges(files, impl_index)
      files.each_value do |meta|
        owner = meta['primary_const']
        next unless owner

        meta['polymorphic'].each do |decl|
          impl_index[[owner, decl['name']]].uniq.sort.each do |implementor|
            meta['refs'] << {
              'const' => implementor, 'line' => decl['line'], 'kind' => 'polymorphic'
            }
          end
        end
      end
    end

    # Constants reached by so much of the app that they are ambient rather than
    # coupled. Breadth is counted in distinct top-level units, not files: one unit
    # including a concern from thirty of its own files is still one dependency.
    def derive_ambient(files)
      units = files.each_value.filter_map { |m| m['primary_const']&.split('::')&.first }.uniq
      return {} if units.size < AMBIENT_MEASURABLE_MIN

      reach = Hash.new { |h, k| h[k] = Set.new }
      kinds = Hash.new { |h, k| h[k] = Hash.new(0) }

      files.each_value do |meta|
        unit = meta['primary_const']&.split('::')&.first
        next if unit.nil?

        meta['refs'].each do |ref|
          # A unit reaching its own name is not reach.
          next if ref['const'].split('::').first == unit

          reach[ref['const']] << unit
          kinds[ref['const']][ref['kind']] += 1
        end
      end

      reach.each_with_object({}) do |(const, hitters), out|
        next if hitters.size < AMBIENT_MIN_UNITS

        edges = kinds[const]
        total = edges.values.sum
        next if total.zero?

        structural = edges.select { |k, _| STRUCTURAL_KINDS.include?(k) }.values.sum
        pct = (structural * 100.0 / total).round
        next if pct < AMBIENT_STRUCTURAL_PCT

        out[const] = {
          'units' => hitters.size, 'of' => units.size,
          'structural_pct' => pct, 'min_units' => AMBIENT_MIN_UNITS
        }
      end
    end

    # Billing::Invoice implies the namespace Billing owns that file too.
    # Domain resolution leans on this: `/extract-scout Billing` should find
    # every file under the Billing namespace without grepping.
    def derive_namespaces(files)
      out = Hash.new { |h, k| h[k] = [] }
      files.each do |rel, meta|
        const = meta['primary_const']
        next unless const&.include?('::')

        parts = const.split('::')
        (1...parts.length).each { |n| out[parts[0...n].join('::')] << rel }
      end
      out
    end

    # Packwerk packages, keyed by the constant-shaped name a domain would be
    # named by. An app running Packwerk has already declared its boundaries with
    # more information than any naming convention can recover -- reading that
    # declaration beats competing with it.
    def discover_packs
      out = {}
      %w[packs/**/package.yml components/*/package.yml engines/*/package.yml].each do |glob|
        Dir.glob(File.join(@repo_root, glob)).sort.each do |yml|
          dir = File.dirname(yml)
          rel = dir.delete_prefix("#{@repo_root}/")
          next if rel == dir || rel.empty?
          next if rel.split('/').any? { |seg| @excludes.include?(seg) }

          out[Inflect.camelize(File.basename(dir))] = rel
        end
      end
      out
    end

    def ruby_files
      Dir.glob(File.join(@repo_root, '**', '*.rb')).reject { |p| excluded?(p) }.sort
    end

    def excluded?(abs)
      rel = abs.delete_prefix("#{@repo_root}/")
      @excludes.any? do |ex|
        rel == ex || rel.start_with?("#{ex}/") || rel.split('/').include?(ex)
      end
    end

    def safe_read(path)
      src = File.read(path, encoding: 'UTF-8')
      src.valid_encoding? ? src : src.encode('UTF-8', invalid: :replace, undef: :replace)
    rescue StandardError
      nil
    end
  end
end

# ------------------------------------------------------------------------ main

if __FILE__ == $PROGRAM_NAME
  options = { root: Dir.pwd, include_tests: false, exclude: [], out: nil }

  OptionParser.new do |opts|
    opts.banner = 'Usage: build_index.rb [options]'
    opts.on('--root PATH', 'Repository root (default: cwd)') { |v| options[:root] = v }
    opts.on('--include-tests', 'Index spec/ and test/ too') { options[:include_tests] = true }
    opts.on('--exclude DIR', 'Additional directory to skip (repeatable)') { |v| options[:exclude] << v }
    opts.on('--out PATH', 'Write JSON here instead of stdout') { |v| options[:out] = v }
    opts.on('-h', '--help') { puts opts; exit 0 }
  end.parse!

  index = ExtractScout::Indexer.new(
    repo_root: options[:root],
    include_tests: options[:include_tests],
    extra_excludes: options[:exclude]
  ).build

  json = JSON.pretty_generate(index)
  if options[:out]
    File.write(options[:out], json)
    warn "extract-scout: indexed #{index['stats']['files_indexed']} files -> #{options[:out]}"
  else
    puts json
  end
end
