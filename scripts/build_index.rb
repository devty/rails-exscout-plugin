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

  ASSOCIATION_MACROS = %w[belongs_to has_many has_one has_and_belongs_to_many].freeze
  MIXIN_MACROS       = %w[include extend prepend].freeze

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

    def camelize(str)
      str.split('_').map { |part| part.empty? ? part : part[0].upcase + part[1..].to_s }.join
    end

    def singularize(word)
      return IRREGULAR_SINGULAR[word] if IRREGULAR_SINGULAR.key?(word)

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

  # ------------------------------------------------------------ path -> const

  # Rails autoload roots. Every subdirectory of app/ is its own root, which is
  # why app/models/billing/invoice.rb is Billing::Invoice and not
  # App::Models::Billing::Invoice.
  class AutoloadRoots
    def initialize(repo_root)
      @repo_root = repo_root
      @roots = discover
    end

    attr_reader :roots

    def discover
      found = []
      # app/<subdir> for the main app and for every engine/pack/component
      %w[app engines/*/app packs/*/app components/*/app lib/*/app].each do |glob|
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
      # lib/ is an autoload root in many apps
      %w[lib engines/*/lib packs/*/lib components/*/lib].each do |glob|
        Dir.glob(File.join(@repo_root, glob)).each do |dir|
          found << dir if File.directory?(dir)
        end
      end
      # Longest first so the most specific root wins.
      found.uniq.sort_by { |d| -d.length }
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

  # ------------------------------------------------------------------ analyzer

  Ref = Struct.new(:const, :line, :kind, keyword_init: true)

  # When the same constant is seen twice on one line by two different detectors
  # (`class_name: "Billing::Invoice"` is both an association target and a
  # constant-shaped string), keep the most specific reading.
  KIND_PRIORITY = {
    'superclass' => 0, 'association' => 1, 'mixin' => 2,
    'delegation' => 3, 'reference' => 4, 'dsl_string' => 5
  }.freeze

  class FileAnalyzer
    def initialize(path, source)
      @path = path
      @source = source
      @defines = []
      @refs = []
    end

    attr_reader :defines, :refs

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
          @refs << Ref.new(const: const, line: line, kind: 'reference') if const
          i += consumed
          next
        when :on_tstring_content
          maybe_dsl_string(value, line)
        end

        i += 1
      end

      dedupe!
      self
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
      return false if prev_type == :on_op && %w[. &. ::].include?(prev_val)
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
      # `class << self` and anonymous `Class.new` forms have no const here.
      return i + 1 unless j < tokens.length && tokens[j][1] == :on_const

      name, consumed = read_const_path(tokens, j)
      @defines << { 'const' => name, 'line' => line }
      after = j + consumed

      # Superclass: `class Invoice < ApplicationRecord`
      k = nxt(tokens, after)
      if k < tokens.length && tokens[k][1] == :on_op && tokens[k][2] == '<'
        m = nxt(tokens, k + 1)
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

      inferred = Inflect.association_constant(tokens[k][2], plural: plural)

      # Scan the rest of this logical line for an explicit class_name: override.
      explicit = scan_for_class_name(tokens, k, line)
      const = explicit || inferred
      @refs << Ref.new(const: const, line: line, kind: 'association')
      k + 1
    end

    def scan_for_class_name(tokens, start, line)
      j = start
      while j < tokens.length && tokens[j][0][0] == line
        if tokens[j][1] == :on_label && tokens[j][2] == 'class_name:'
          k = nxt(tokens, j + 1)
          # class_name: "Billing::Invoice"  (string) or ::Billing::Invoice (const)
          if k < tokens.length && tokens[k][1] == :on_tstring_beg
            m = nxt(tokens, k + 1)
            return tokens[m][2] if m < tokens.length && tokens[m][1] == :on_tstring_content
          elsif k < tokens.length && tokens[k][1] == :on_const
            return read_const_path(tokens, k).first
          end
        end
        j += 1
      end
      nil
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

    # Rails hides constant references inside strings all over the place:
    #   "BillingJob".constantize, to: "billing/invoices#show", sidekiq class names.
    # Only treat a string as a constant reference when it *looks* like one.
    def maybe_dsl_string(value, line)
      return unless value.is_a?(String)

      if value.match?(/\A[A-Z][A-Za-z0-9_]*(::[A-Z][A-Za-z0-9_]*)*\z/) && value.length > 2
        @refs << Ref.new(const: value, line: line, kind: 'dsl_string')
      elsif value.match?(%r{\A[a-z0-9_]+(/[a-z0-9_]+)+#[a-z0-9_]+\z})
        # Routing target: "billing/invoices#show" -> Billing::InvoicesController
        controller = value.split('#').first
        const = controller.split('/').map { |s| Inflect.camelize(s) }.join('::')
        @refs << Ref.new(const: "#{const}Controller", line: line, kind: 'dsl_string')
      end
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
      @autoload = AutoloadRoots.new(@repo_root)
    end

    def build
      files = {}
      const_to_files = Hash.new { |h, k| h[k] = [] }
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
          'refs'          => analyzer.refs.map(&:to_h).map { |h| h.transform_keys(&:to_s) }
        }

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

      namespaces = derive_namespaces(files)

      {
        'schema_version' => 1,
        'repo_root'      => @repo_root,
        'generated_by'   => 'extract-scout/build_index.rb',
        'stats'          => {
          'files_indexed'  => files.size,
          'files_skipped'  => skipped,
          'constants'      => const_to_files.size,
          'autoload_roots' => @autoload.roots.map { |r| r.delete_prefix("#{@repo_root}/") }
        },
        'ubiquitous'     => @ubiquitous.to_a.sort,
        'namespaces'     => namespaces,
        'constants'      => const_to_files,
        'files'          => files
      }
    end

    private

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
