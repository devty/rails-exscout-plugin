#!/usr/bin/env ruby
# frozen_string_literal: true

# analyze_domain.rb -- Score how entangled a domain is, from the constant graph.
#
# Consumes build_index.rb output. Resolves a domain name to a file set, walks
# every constant reference crossing that boundary, and classifies the crossings
# into seam types ordered by what blocks what.
#
# Deliberately NOT analyzed (say so in the report rather than implying clean):
#   schema foreign keys, transaction boundaries, git co-change, runtime config.
#
# Usage:
#   analyze_domain.rb --index idx.json --domain Billing [--format text|json]
#   analyze_domain.rb --index idx.json --domain Billing --extra-const Invoice \
#                     --extra-file app/models/ledger_entry.rb

require 'json'
require 'set'
require 'optparse'

module ExtractScout
  # An edge that crosses the domain boundary.
  Crossing = Struct.new(
    :from_file, :from_const, :to_const, :to_file, :line, :kind, :direction,
    keyword_init: true
  )

  class DomainResolver
    def initialize(index)
      @index = index
    end

    # Mechanical resolution only. Semantic expansion ("Invoice belongs to Billing
    # even though it isn't namespaced") is the boundary-resolver agent's job and
    # arrives via --extra-const / --extra-file.
    def resolve(domain, extra_consts: [], extra_files: [])
      files = Set.new
      evidence = Hash.new { |h, k| h[k] = [] }

      # A declared Packwerk boundary is the strongest evidence available: the
      # team wrote it down, rather than the tool inferring it from a name.
      if (pack_root = (@index['packs'] || {})[domain])
        @index['files'].each_key do |rel|
          next unless rel.start_with?("#{pack_root}/")

          files << rel
          evidence[rel] << 'pack'
        end
      end

      if (ns_files = @index['namespaces'][domain])
        ns_files.each { |f| files << f; evidence[f] << 'namespace' }
      end

      @index['constants'].each do |const, owners|
        next unless const == domain || const.start_with?("#{domain}::")

        owners.each { |f| files << f; evidence[f] << 'constant' }
      end

      needle = snake(domain)
      @index['files'].each_key do |rel|
        next unless rel.split('/').any? { |seg| seg == needle || seg == "#{needle}.rb" }

        files << rel
        evidence[rel] << 'path'
      end

      extra_consts.each do |const|
        (@index['constants'][const] || []).each { |f| files << f; evidence[f] << 'agent:const' }
        (@index['namespaces'][const] || []).each { |f| files << f; evidence[f] << 'agent:const' }
      end
      extra_files.each do |f|
        next unless @index['files'].key?(f)

        files << f
        evidence[f] << 'agent:file'
      end

      { files: files, evidence: evidence }
    end

    private

    def snake(str)
      str.gsub('::', '/')
         .gsub(/([a-z\d])([A-Z])/, '\1_\2')
         .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
         .downcase
    end
  end

  # Mirrors Ruby's Module.nesting constant lookup: innermost namespace outward,
  # then absolute. Without this, a bare `LedgerEntry` inside `module Billing`
  # either misses entirely or falsely binds to a same-named class elsewhere.
  class ConstantResolver
    def initialize(index)
      @constants = index['constants']
      @ubiquitous = Set.new(index['ubiquitous'])
    end

    def resolve(const, from_namespace)
      return nil if @ubiquitous.include?(const)

      clean = const.delete_prefix('::')
      parts = (from_namespace || '').split('::')

      parts.length.downto(0) do |n|
        candidate = (parts[0...n] + [clean]).join('::')
        owners = @constants[candidate]
        return [candidate, owners.first] if owners && !owners.empty?
      end
      nil
    end
  end

  class Analyzer
    ASSOCIATION_KINDS = %w[association].freeze

    # Edges that represent one object *using* another, as opposed to merely
    # declaring a structural relationship. The distinction matters enormously in
    # Rails: `Invoice belongs_to :order` paired with `Order has_many :invoices`
    # is ONE relationship written from both ends -- the standard idiom -- not a
    # dependency cycle. Calling that a blocker is the false positive that makes
    # engineers stop trusting the report.
    BEHAVIORAL_KINDS = %w[reference mixin superclass dsl_string delegation
                          polymorphic_ref].freeze

    def initialize(index, domain, extra_consts: [], extra_files: [])
      @index = index
      @domain = domain
      resolved = DomainResolver.new(index).resolve(
        domain, extra_consts: extra_consts, extra_files: extra_files
      )
      @domain_files = resolved[:files]
      @evidence = resolved[:evidence]
      @resolver = ConstantResolver.new(index)
    end

    attr_reader :domain_files

    def analyze
      inbound  = []
      outbound = []
      internal = 0

      @index['files'].each do |rel, meta|
        from_ns = namespace_of(meta['primary_const'])
        from_is_domain = @domain_files.include?(rel)

        meta['refs'].each do |ref|
          hit = @resolver.resolve(ref['const'], from_ns)
          next unless hit

          to_const, to_file = hit
          next if to_file == rel

          to_is_domain = @domain_files.include?(to_file)

          crossing = Crossing.new(
            from_file: rel, from_const: meta['primary_const'],
            to_const: to_const, to_file: to_file,
            line: ref['line'], kind: ref['kind'],
            direction: nil
          )

          if to_is_domain && !from_is_domain
            crossing.direction = 'inbound'
            inbound << crossing
          elsif from_is_domain && !to_is_domain
            crossing.direction = 'outbound'
            outbound << crossing
          elsif from_is_domain && to_is_domain
            internal += 1
          end
        end
      end

      build_report(inbound, outbound, internal)
    end

    private

    def namespace_of(const)
      return '' unless const&.include?('::')

      const.split('::')[0..-2].join('::')
    end

    def unit_of(const)
      return 'unknown' if const.nil?

      const.include?('::') ? const.split('::').first : const
    end

    def build_report(inbound, outbound, internal)
      inbound_units  = inbound.group_by { |c| unit_of(c.from_const) }
      outbound_units = outbound.group_by { |c| unit_of(c.to_const) }

      # A unit with edges in both directions is only a genuine cycle when BOTH
      # directions carry behavioral edges. Association-only bidirectionality is
      # an inverse pair and belongs with the association seam instead.
      bidirectional = (inbound_units.keys & outbound_units.keys).sort
      behavioral_both, assoc_pair_units = bidirectional.partition do |unit|
        behavioral?(inbound_units[unit]) && behavioral?(outbound_units[unit])
      end

      # Behaviour in both directions is necessary but not sufficient. A unit is
      # a whole namespace, so `Ledger::Report` calling in and `Ledger::Secret`
      # being called back collapses into one bidirectional unit -- while nothing
      # says the two Ledger files depend on each other at all. Only when the
      # same file appears on both sides is a cycle demonstrated.
      cycle_units, namespace_pair_units = behavioral_both.partition do |unit|
        files_both_ways?(inbound_units[unit], outbound_units[unit])
      end

      # Distinct domain constants reached from outside = how leaky the facade is.
      exposed = inbound.map(&:to_const).uniq.sort

      poly = (inbound + outbound).select { |c| c.kind == 'polymorphic' }
      poly_refs = (inbound + outbound).select { |c| c.kind == 'polymorphic_ref' }
      unbounded = unbounded_interfaces

      {
        'domain'  => @domain,
        'files'   => @domain_files.to_a.sort,
        'evidence' => @evidence,
        # The denominator. Saturation constants are absolute -- 10 inbound units
        # is 10 client adapters to write whether the repo has 34 models or 400 --
        # so the score estimates WORK and travels across repos. What does not
        # travel is reading it as a percentile: on a small app a mid score is an
        # outlier, on a large one it is unremarkable. Carry the scale so the
        # reader can tell which they are looking at.
        'repo' => {
          'files_indexed' => (@index['stats'] || {})['files_indexed'],
          'constants'     => (@index['stats'] || {})['constants']
        },
        'not_analyzed' => [
          'schema foreign keys / column-level sharing',
          'transaction boundaries spanning the seam',
          'git co-change (temporal) coupling',
          'runtime config: env vars, feature flags, queues, cron'
        ],
        'metrics' => {
          'domain_files'        => @domain_files.size,
          'domain_loc'          => @domain_files.sum { |f| @index['files'][f]['loc'] },
          'inbound_edges'       => inbound.size,
          'outbound_edges'      => outbound.size,
          'internal_edges'      => internal,
          'inbound_units'       => inbound_units.keys.size,
          'outbound_units'      => outbound_units.keys.size,
          'inbound_files'       => inbound.map(&:from_file).uniq.size,
          'exposed_constants'   => exposed.size,
          'cycle_units'         => cycle_units.size,
          'namespace_pair_units' => namespace_pair_units.size,
          'assoc_pair_units'    => assoc_pair_units.size,
          'boundary_assocs'     => (inbound + outbound).count { |c| ASSOCIATION_KINDS.include?(c.kind) },
          'string_couplings'    => (inbound + outbound).count { |c| c.kind == 'dsl_string' },
          'polymorphic_edges'   => poly.size,
          'polymorphic_string_refs' => poly_refs.size,
          'polymorphic_unbounded' => unbounded.size,
          'cohesion_ratio'      => cohesion(internal, inbound.size + outbound.size)
        },
        'exposed_constants' => exposed,
        'cycles'   => cycle_units.map { |u| cycle_detail(u, inbound_units, outbound_units) },
        'namespace_pairs' => namespace_pair_units.map { |u| cycle_detail(u, inbound_units, outbound_units) },
        'inverse_association_pairs' => assoc_pair_units,
        'inbound'  => summarize_units(inbound_units),
        'outbound' => summarize_units(outbound_units),
        'seams'    => rank_seams(inbound, outbound, inbound_units, outbound_units,
                                 cycle_units, assoc_pair_units, exposed, poly, unbounded,
                                 namespace_pair_units, poly_refs)
      }
    end

    def behavioral?(crossings)
      crossings.any? { |c| BEHAVIORAL_KINDS.include?(c.kind) }
    end

    # The external files that call in, versus the external files that get called
    # back. An intersection means one file is on both sides -- a demonstrated
    # cycle. Disjoint sets mean the namespace, not any file, is bidirectional.
    def files_both_ways?(inbound, outbound)
      callers = inbound.map(&:from_file).to_set
      callees = outbound.map(&:to_file).to_set
      callers.intersect?(callees)
    end

    def plural(count, singular, plural_form = nil)
      count == 1 ? singular : (plural_form || "#{singular}s")
    end

    def cohesion(internal, crossing)
      total = internal + crossing
      return 1.0 if total.zero?

      (internal.to_f / total).round(3)
    end

    def cycle_detail(unit, inbound_units, outbound_units)
      {
        'unit' => unit,
        'calls_in'  => inbound_units[unit].map { |c| cite(c) },
        'called_by' => outbound_units[unit].map { |c| cite(c) }
      }
    end

    def summarize_units(units)
      units.map do |unit, crossings|
        {
          'unit'  => unit,
          'edges' => crossings.size,
          'files' => crossings.map(&:from_file).uniq.size,
          'kinds' => crossings.group_by(&:kind).transform_values(&:size),
          'citations' => crossings.sort_by { |c| [c.from_file, c.line] }.first(12).map { |c| cite(c) }
        }
      end.sort_by { |u| -u['edges'] }
    end

    def cite(crossing)
      {
        'at'   => "#{crossing.from_file}:#{crossing.line}",
        'from' => crossing.from_const,
        'to'   => crossing.to_const,
        'kind' => crossing.kind
      }
    end

    # ------------------------------------------------------------------ seams
    #
    # Ordering rule: a seam ranks above another when breaking it is a
    # PRECONDITION for breaking the other -- not when it is merely bigger.
    # Cycles outrank volume because you cannot even draw the boundary while a
    # cycle crosses it. Facade leakage outranks raw fan-in because a wide but
    # narrow-surfaced dependency is mechanical to fix, while a narrow but deeply
    # reaching one is a redesign.
    #
    # Weights live in one place on purpose -- see SEAM_WEIGHTS below.

    # Crossing associations per domain file at which the volume stops being
    # ordinary Rails and starts being a project.
    ASSOC_MAJOR_PER_FILE = 5

    SEAM_WEIGHTS = {
      'cycle'            => 100,
      'polymorphic'      => 90,
      'namespace_pair'   => 65,
      'facade_leak'      => 60,
      'boundary_assoc'   => 45,
      'string_coupling'  => 40,
      'shared_mixin'     => 35,
      'inbound_volume'   => 25,
      'outbound_dep'     => 20
    }.freeze

    # A polymorphic interface declared inside the domain that no file in the
    # repo implements. It produces no edges at all, so counting only crossings
    # would make the least bounded case the quietest one in the report.
    def unbounded_interfaces
      @domain_files.flat_map do |rel|
        meta = @index['files'][rel] || {}
        implemented = meta.fetch('refs', []).select { |r| r['kind'] == 'polymorphic' }
                          .map { |r| r['line'] }.to_set
        meta.fetch('polymorphic', []).reject { |d| implemented.include?(d['line']) }
            .map do |d|
              { 'at' => "#{rel}:#{d['line']}", 'from' => meta['primary_const'],
                'to' => ":#{d['name']} (no implementor in this repo)", 'kind' => 'polymorphic' }
            end
      end
    end

    def rank_seams(inbound, outbound, inbound_units, outbound_units,
                   cycle_units, assoc_pair_units, exposed, poly, unbounded,
                   namespace_pair_units, poly_refs)
      seams = []
      poly_seam = polymorphic_seam(poly, unbounded, poly_refs)
      seams << poly_seam if poly_seam

      cycle_units.each do |unit|
        into = inbound_units[unit].size
        outof = outbound_units[unit].size
        seams << {
          'type' => 'cycle', 'severity' => 'blocker', 'title' => "Cycle: #{@domain} <-> #{unit}",
          'why' => "#{unit} calls into #{@domain} (#{into} #{plural(into, 'edge')}) and #{@domain} " \
                   "calls back into #{unit} (#{outof} #{plural(outof, 'edge')}), with real behaviour " \
                   'on both sides. Neither can move until this is one-directional.',
          'break_with' => 'Invert one direction: dependency injection, a domain event, or a ' \
                          'shared interface both sides depend on.',
          'score' => SEAM_WEIGHTS['cycle'] + into + outof,
          'citations' => (inbound_units[unit] + outbound_units[unit]).first(8).map { |c| cite(c) }
        }
      end

      namespace_pair_units.each do |unit|
        into = inbound_units[unit].size
        outof = outbound_units[unit].size
        seams << {
          'type' => 'namespace_pair', 'severity' => 'major',
          'title' => "Namespace pair: #{@domain} <-> #{unit} (not a file-level cycle)",
          'why' => "#{unit} calls into #{@domain} (#{into} #{plural(into, 'edge')}) and #{@domain} " \
                   "calls back into #{unit} (#{outof} #{plural(outof, 'edge')}) -- but through " \
                   'disjoint files. No file is on both sides, so nothing here demonstrates a ' \
                   'cycle; the namespace is bidirectional, not any pair of files. Real work, ' \
                   'not a precondition.',
          'break_with' => "Confirm the #{unit} files involved do not depend on each other. If they " \
                          'do, this is a cycle and must be inverted; if they do not, split the ' \
                          'namespace so the direction is visible in the structure.',
          'score' => SEAM_WEIGHTS['namespace_pair'] + into + outof,
          'citations' => (inbound_units[unit] + outbound_units[unit]).first(8).map { |c| cite(c) }
        }
      end

      if exposed.size > 3
        top = inbound.group_by(&:to_const).transform_values(&:size).sort_by { |_, v| -v }.first(8)
        seams << {
          'type' => 'facade_leak', 'severity' => exposed.size > 8 ? 'blocker' : 'major',
          'title' => "No facade: #{exposed.size} #{@domain} constants referenced from outside",
          'why' => 'External code reaches past any single entry point into domain internals. ' \
                   'Every one of these becomes a public API method or a breaking change.',
          'break_with' => "Introduce #{@domain}::API (or a service object) and route external " \
                          'callers through it, one constant at a time.',
          'score' => SEAM_WEIGHTS['facade_leak'] + exposed.size * 2,
          'detail' => top.map { |const, n| "#{const} (#{n} refs)" },
          'citations' => inbound.sort_by { |c| [c.from_file, c.line] }.first(8).map { |c| cite(c) }
        }
      end

      assoc = (inbound + outbound).select { |c| ASSOCIATION_KINDS.include?(c.kind) }
      if assoc.any?
        pair_note =
          if assoc_pair_units.any?
            " #{assoc_pair_units.size} of these are inverse pairs (#{assoc_pair_units.first(4).join(', ')}) " \
            '-- one relationship declared from both ends, not a cycle.'
          else
            ''
          end
        # Severity scales with how far past a normal model this is. A typical
        # Rails model declares two to four associations, so five or more
        # crossings per file is genuinely above the norm, and below that it is
        # ordinary Rails. Never a blocker: an association crossing is work to
        # do, not a precondition for drawing the boundary at all.
        per_file = assoc.size.to_f / [@domain_files.size, 1].max
        seams << {
          'type' => 'boundary_assoc',
          'severity' => per_file >= ASSOC_MAJOR_PER_FILE ? 'major' : 'moderate',
          'title' => "#{assoc.size} ActiveRecord #{plural(assoc.size, 'association')} " \
                     "#{assoc.size == 1 ? 'crosses' : 'cross'} the boundary",
          'why' => 'Each implies a join and almost always a foreign key. After extraction ' \
                   'these cannot be traversed in SQL -- they become remote calls or denormalized ' \
                   "ids. That is #{format('%.1f', per_file)} per domain file; " \
                   "#{ASSOC_MAJOR_PER_FILE}+ is where this stops being ordinary Rails." + pair_note,
          'break_with' => 'Replace traversal with an explicit id column plus a lookup at the ' \
                          'seam. Confirm the FK in schema.rb -- schema analysis is out of scope here.',
          'score' => SEAM_WEIGHTS['boundary_assoc'] + assoc.size * 3,
          'citations' => assoc.sort_by { |c| [c.from_file, c.line] }.first(10).map { |c| cite(c) }
        }
      end

      strings = (inbound + outbound).select { |c| c.kind == 'dsl_string' }
      if strings.any?
        seams << {
          'type' => 'string_coupling', 'severity' => 'major',
          'title' => "#{strings.size} string-based #{plural(strings.size, 'reference')} " \
                     "#{strings.size == 1 ? 'crosses' : 'cross'} the boundary",
          'why' => 'Constantized strings, routing targets and job class names are invisible to ' \
                   'every refactoring tool. These break at runtime, in production, not at boot.',
          'break_with' => 'Replace with real constant references before moving anything, so the ' \
                          'rest of the extraction fails loudly instead of silently.',
          'score' => SEAM_WEIGHTS['string_coupling'] + strings.size * 4,
          'citations' => strings.first(10).map { |c| cite(c) }
        }
      end

      mixins = outbound.select { |c| c.kind == 'mixin' }
      if mixins.any?
        seams << {
          'type' => 'shared_mixin', 'severity' => 'moderate',
          'title' => "#{@domain} includes #{mixins.map(&:to_const).uniq.size} " \
                     "#{plural(mixins.map(&:to_const).uniq.size, 'module')} defined outside it",
          'why' => 'Shared concerns travel with the extracted code or stay behind. Either way ' \
                   'they become duplicated logic or a new shared dependency.',
          'break_with' => 'Vendor the concern into the domain, or promote it to an explicitly ' \
                          'shared library both sides may depend on.',
          'score' => SEAM_WEIGHTS['shared_mixin'] + mixins.size * 2,
          'citations' => mixins.first(8).map { |c| cite(c) }
        }
      end

      noncycle_in = inbound_units.reject { |u, _| cycle_units.include?(u) }
                                 .sort_by { |_, v| -v.size }.first(3)
      noncycle_in.each do |unit, crossings|
        next if crossings.size < 3

        seams << {
          'type' => 'inbound_volume', 'severity' => 'moderate',
          'title' => "#{unit} depends on #{@domain} in #{crossings.size} places",
          'why' => 'One-directional, so it does not block the split -- but every call site ' \
                   'needs a client-side replacement on cutover day.',
          'break_with' => "Route #{unit} through a single #{@domain} client/adapter first.",
          'score' => SEAM_WEIGHTS['inbound_volume'] + crossings.size,
          'citations' => crossings.sort_by { |c| [c.from_file, c.line] }.first(6).map { |c| cite(c) }
        }
      end

      seams.sort_by { |s| -s['score'] }
    end

    # Ranked just below a cycle. A cycle stops you drawing the boundary at all;
    # a polymorphic association lets you draw it and then cannot survive it --
    # no foreign key, no join, and a target set the type column decides at
    # runtime. Both are preconditions, not volume.
    def polymorphic_seam(poly, unbounded, poly_refs)
      return nil if poly.empty? && unbounded.empty? && poly_refs.empty?

      titles = []
      if poly.any?
        titles << "#{poly.size} polymorphic #{plural(poly.size, 'association')} " \
                  "#{poly.size == 1 ? 'crosses' : 'cross'} the boundary"
      end
      if unbounded.any?
        titles << "#{unbounded.size} declared #{plural(unbounded.size, 'interface')} " \
                  "#{unbounded.size == 1 ? 'has' : 'have'} no implementor in this repo"
      end
      if poly_refs.any?
        titles << "#{poly_refs.size} #{plural(poly_refs.size, 'place')} " \
                  "#{poly_refs.size == 1 ? 'compares' : 'compare'} the type column as a bare string"
      end

      why = +'A polymorphic association is a class name stored as a string, with no foreign key. ' \
             'The database cannot enforce it and no join can traverse it once the sides are apart. '
      why += "Concrete targets found: #{poly.map(&:to_const).uniq.sort.join(', ')}. " if poly.any?
      if unbounded.any?
        why += 'The unbounded ones cannot be enumerated statically at all -- any model may be ' \
               'stored in the type column, including ones added after this report. '
      end
      if poly_refs.any?
        why += 'The class names are also written out as string literals at the call sites below, ' \
               'where no compiler, rename or refactoring tool can see them -- renaming a model ' \
               'stops the match silently rather than failing.'
      end

      {
        'type' => 'polymorphic',
        'severity' => poly.any? ? 'blocker' : 'major',
        'title' => titles.join('; '),
        'why' => why,
        'break_with' => 'Replace the polymorphic association with one explicit association per ' \
                        'concrete type, or an id the extracted service owns. Audit every string ' \
                        'comparison against the type column first -- renaming a model silently ' \
                        'stops matching instead of failing.',
        'score' => SEAM_WEIGHTS['polymorphic'] + poly.size * 3 + unbounded.size * 5 +
                   poly_refs.size * 2,
        'citations' => poly.first(6).map { |c| cite(c) } + unbounded.first(3) +
                       poly_refs.first(6).map { |c| cite(c) }
      }
    end
  end

  # ------------------------------------------------------------------- verdict
  #
  # Extractability is TWO readings, deliberately not collapsed into one number:
  #
  #   score(m)         MAGNITUDE -- how much work, 0-10.
  #   max_severity(s)  BLOCKING  -- whether anything must break before the
  #                                 boundary can even be drawn.
  #
  # They answer different questions, and a small domain can be badly blocked.
  # Collapsing them loses exactly the fact an engineer acts on: an earlier build
  # scored one true cycle at 1.1/10 and printed "Clean -- extractable as-is"
  # directly above "[BLOCKER] Cycle", contradicting its own report.
  #
  # Keep the split. Magnitude saturates on purpose; blocking must never be
  # smuggled back into the score to compensate.

  module Verdict
    SEVERITY_RANK = { 'blocker' => 3, 'major' => 2, 'moderate' => 1 }.freeze

    module_function

    # Highest severity among the ranked seams; nil when there are none.
    def max_severity(seams)
      present = Array(seams).map { |s| s['severity'] }.select { |s| SEVERITY_RANK.key?(s) }
      return nil if present.empty?

      present.max_by { |s| SEVERITY_RANK.fetch(s) }
    end

    def blocked?(seams)
      max_severity(seams) == 'blocker'
    end

    # MAGNITUDE only. Each component saturates so no single large count drives
    # the whole number -- 400 inbound edges is a lot of mechanical work, not an
    # impossibility. Whether the split is BLOCKED is max_severity's job.
    def score(m)
      sat = ->(value, full) { [value.to_f / full, 1.0].min }
      composite =
        sat.call(m['cycle_units'], 3)       * 3.2 +
        sat.call(m['exposed_constants'], 12) * 2.3 +
        sat.call(m['inbound_units'], 10)    * 1.7 +
        sat.call(m['boundary_assocs'], 10)  * 1.4 +
        sat.call(m['outbound_units'], 12)   * 0.9 +
        sat.call(m['string_couplings'], 5)  * 0.5
      composite.round(1)
    end

    # The volume reading of the score alone, with no blocking information.
    def magnitude(score)
      case score
      when 0...2.0   then 'Clean'
      when 2.0...4.5 then 'Moderate'
      when 4.5...7.0 then 'Hard'
      else 'Very hard'
      end
    end

    # The headline phrase after "ENTANGLEMENT: {score}/10 -- ".
    #
    # Blocking QUALIFIES magnitude rather than replacing it. A blocked domain may
    # still be small and otherwise cheap; dropping the magnitude word hides that
    # and turns every blocked domain into the same undifferentiated "Blocked".
    # "Clean, but BLOCKED" is deliberately a little jarring -- the tension is the
    # finding, not a wording problem to smooth away.
    #
    # nil severity is NOT a clean bill of health. It means the constant graph came
    # back empty, while foreign keys, transactions, git co-change and runtime
    # config were never examined at all. Say which surfaces are still unread
    # rather than letting silence read as safety.
    def verdict(score, max_severity)
      mag = magnitude(score)
      case max_severity
      when 'blocker'
        # "but" only reads as qualification while the magnitude sounds reassuring.
        # "Very hard, but BLOCKED" implies a contrast that isn't there.
        contrast = %w[Clean Moderate].include?(mag) ? 'but' : 'and'
        "#{mag}, #{contrast} BLOCKED -- a seam must break before the boundary can be drawn"
      when 'major'
        "#{mag} -- preparatory work required before any code moves"
      when 'moderate'
        "#{mag} -- minor seams, mechanical to clear"
      else
        "#{mag} -- no seams in the constant graph; requires further " \
        'investigation: schema FKs, transaction boundaries, git co-change, runtime config'
      end
    end
  end

  # ----------------------------------------------------------------- portfolio
  #
  # A sweep over many domains is deterministic work -- resolve, score, rank --
  # and it was being done by hand in the conversation: 34 JSON files aggregated
  # with ad-hoc one-liners, re-derived every run, each pass a chance to
  # transcribe a number wrong. It belongs in the script, where it is
  # reproducible without a model.

  module_function

  # Every unit worth scouting in a portfolio pass.
  #
  # Namespaces are the real domains when an app has them. Most Rails apps have
  # none, and coming back empty would be useless there -- so fall back to
  # top-level constants, which are that app's de-facto units.
  def candidate_domains(index)
    # A Packwerk app has already answered this question, explicitly and with
    # more information than a convention guess. Prefer its answer.
    packs = index['packs'] || {}
    return packs.keys.sort unless packs.empty?

    namespaces = index['namespaces'].keys.reject { |n| n.include?('::') }
    return namespaces.sort unless namespaces.empty?

    index['constants'].keys.reject { |c| c.include?('::') }.sort
  end

  # The headline numbers for one domain. nil when the name resolves to nothing,
  # so a caller can filter_map over a speculative list.
  def summarize(index, domain, extra_consts: [], extra_files: [])
    analyzer = Analyzer.new(index, domain, extra_consts: extra_consts, extra_files: extra_files)
    return nil if analyzer.domain_files.empty?

    report = analyzer.analyze
    score = Verdict.score(report['metrics'])
    severity = Verdict.max_severity(report['seams'])
    {
      'domain' => domain,
      'entanglement_score' => score,
      'max_severity' => severity,
      'verdict' => Verdict.verdict(score, severity),
      'metrics' => report['metrics'],
      'seams' => report['seams'].map { |s| s.slice('type', 'severity', 'title') }
    }
  end

  # Ascending extraction cost. Blocking is a precondition rather than a
  # quantity, so it outranks magnitude outright: a blocked 2.0 goes after a
  # clean 6.0. Domain name breaks ties so the order is stable across runs.
  def rank(rows)
    rows.sort_by do |r|
      [r['max_severity'] == 'blocker' ? 1 : 0, r['entanglement_score'], r['domain']]
    end
  end

  # ---------------------------------------------------------------- diagnostics
  #
  # The eval that generalises without hand-labelled ground truth.
  #
  # D1 -- class_name: read only on the macro's own physical line -- survived the
  # entire life of the tool with a green suite, because a unit test asserts the
  # parser does what it was written to do, and D1 was a shape the fixtures did
  # not contain. No amount of the same kind of test would have found it.
  #
  # But it left a signature. A misparse fabricates a constant, and a fabricated
  # constant resolves to nothing. So "what fraction of association references
  # name a constant this repo actually defines" is a correctness proxy that needs
  # no labels and runs on any repo. On DocuSeal that number was 84.7% while every
  # test was green.
  #
  # Deliberate non-resolution is excluded rather than counted as failure:
  # ubiquitous base classes resolve to nil by design, and counting them would
  # make every healthy repo look broken.

  # Associations name models in this repo, so they should almost all resolve.
  # A handful legitimately will not -- STI, gem-provided models, an interface
  # nobody implements -- so the floor is not 100%.
  ASSOC_RESOLUTION_FLOOR = 0.9

  module_function

  def diagnose(index, floor: ASSOC_RESOLUTION_FLOOR)
    resolver = ConstantResolver.new(index)
    ubiquitous = Set.new(index['ubiquitous'])
    by_kind = Hash.new { |h, k| h[k] = { 'total' => 0, 'ubiquitous' => 0, 'resolved' => 0, 'examples' => [] } }

    index['files'].each do |rel, meta|
      const = meta['primary_const']
      from_ns = const&.include?('::') ? const.split('::')[0..-2].join('::') : ''

      meta['refs'].each do |ref|
        bucket = by_kind[ref['kind']]
        bucket['total'] += 1

        if ubiquitous.include?(ref['const'])
          bucket['ubiquitous'] += 1
          next
        end

        if resolver.resolve(ref['const'], from_ns)
          bucket['resolved'] += 1
        elsif bucket['examples'].size < 10
          bucket['examples'] << { 'at' => "#{rel}:#{ref['line']}", 'const' => ref['const'] }
        end
      end
    end

    by_kind.each_value do |b|
      expected = b['total'] - b['ubiquitous']
      b['unresolved'] = expected - b['resolved']
      b['rate'] = expected.zero? ? 1.0 : (b['resolved'].to_f / expected).round(3)
    end

    # Drop the default block. Every read below this point is a lookup, and a
    # lookup on a Hash.new{} MATERIALISES a bucket -- one with no 'rate', because
    # rates were computed above. A repo with references but no associations then
    # grew an empty 'association' row that crashed the renderer.
    by_kind = Hash[by_kind]

    # Under Zeitwerk a booting app guarantees the path-derived constant is one
    # the file actually declares. A mismatch is not a style question -- it is
    # proof of an inflection rule this tool does not know, and every edge
    # touching that constant is being dropped. Detectable with no references in
    # the repo at all, which makes it the cheapest tripwire available.
    name_mismatches = []
    index['files'].each do |rel, meta|
      next unless meta['autoloadable']

      declared = Array(meta['declared'])
      primary = meta['primary_const']
      next if declared.empty? || primary.nil?
      next if declared.include?(primary)

      tail = primary.split('::').last
      next if declared.any? { |d| d.split('::').last == tail }

      name_mismatches << {
        'file' => rel, 'path_implies' => primary, 'file_declares' => declared
      }
    end

    warnings = []
    unless name_mismatches.empty?
      warnings << "#{name_mismatches.size} file(s) declare a constant the path does not imply " \
                  "(e.g. #{name_mismatches.first['file']} declares " \
                  "#{name_mismatches.first['file_declares'].first} but the path implies " \
                  "#{name_mismatches.first['path_implies']}). That is an inflection rule this " \
                  'index does not know -- check config/initializers/inflections.rb.'
    end

    assoc = by_kind['association']
    if assoc && (assoc['total'] - assoc['ubiquitous']).positive? && assoc['rate'] < floor
      warnings << "association resolution #{(assoc['rate'] * 100).round}% is below the " \
                  "#{(floor * 100).round}% floor -- #{assoc['unresolved']} of " \
                  "#{assoc['total'] - assoc['ubiquitous']} associations name a constant this repo " \
                  'does not define. That is the signature of a parser defect, not of coupling.'
    end

    {
      'files_indexed' => (index['stats'] || {})['files_indexed'],
      'by_kind' => by_kind,
      'name_mismatches' => name_mismatches,
      'warnings' => warnings
    }
  end

  # -------------------------------------------------------------------- render

  module Render
    module_function

    def bar(value, full, width = 10)
      filled = [[(value.to_f / full * width).round, width].min, 0].max
      ('#' * filled) + ('.' * (width - filled))
    end

    # The portfolio table. Deliberately narrow enough to paste into a planning
    # doc without reflowing -- the per-domain detail lives in the full reports.
    def summary(rows)
      return "No domains resolved -- nothing to rank.\n" if rows.empty?

      out = []
      out << format('%-22s %6s %6s %5s %5s %8s %7s  %s',
                    'DOMAIN', 'SCORE', 'FILES', 'IN', 'OUT', 'EXPOSED', 'CYCLES', 'VERDICT')
      rows.each do |r|
        m = r['metrics']
        headline = Verdict.magnitude(r['entanglement_score'])
        headline += ', BLOCKED' if r['max_severity'] == 'blocker'
        out << format('%-22s %6s %6d %5d %5d %8d %7d  %s',
                      r['domain'], r['entanglement_score'], m['domain_files'],
                      m['inbound_units'], m['outbound_units'], m['exposed_constants'],
                      m['cycle_units'], headline)
      end
      out << ''
      out << 'Ordered by ascending extraction cost. Blocking outranks size: a blocked 2.0'
      out << 'goes after a clean 6.0, because a blocker is a precondition, not a quantity.'
      out << ''
      out << 'NOT ANALYZED (ranking on partial signal is still ranking on partial signal):'
      out << '  - schema foreign keys / column-level sharing'
      out << '  - transaction boundaries spanning the seam'
      out << '  - git co-change (temporal) coupling'
      out << '  - runtime config: env vars, feature flags, queues, cron'
      out.join("\n")
    end

    def diagnostics(d)
      out = []
      out << "RESOLUTION DIAGNOSTICS  (#{d['files_indexed'] || '?'} files indexed)"
      out << ''
      out << format('  %-14s %6s %6s %9s %11s %6s',
                    'KIND', 'TOTAL', 'UBIQ', 'RESOLVED', 'UNRESOLVED', 'RATE')
      d['by_kind'].sort_by { |k, _| k }.each do |kind, b|
        out << format('  %-14s %6d %6d %9d %11d %5d%%',
                      kind, b['total'], b['ubiquitous'], b['resolved'], b['unresolved'],
                      ((b['rate'] || 1.0) * 100).round)
      end
      out << ''
      if d['warnings'].empty?
        out << '  ok: no kind is below its resolution floor'
      else
        out << '  WARNINGS'
        d['warnings'].each { |w| out << "    - #{w}" }
      end
      mismatches = d['name_mismatches'] || []
      unless mismatches.empty?
        out << ''
        out << '  NAME MISMATCHES (the path implies one constant, the file declares another)'
        mismatches.first(10).each do |m|
          out << format('    %-44s path: %-22s file: %s',
                        m['file'], m['path_implies'], m['file_declares'].join(', '))
        end
        out << '    Under Zeitwerk a booting app cannot disagree here, so each of these is an'
        out << '    inflection rule this index does not know -- see config/initializers/inflections.rb.'
      end

      examples = d['by_kind'].flat_map { |kind, b| b['examples'].map { |e| [kind, e] } }
      unless examples.empty?
        out << ''
        out << '  UNRESOLVED EXAMPLES (each is a constant no file in this repo defines)'
        examples.first(15).each do |kind, e|
          out << format('    %-40s %-12s -> %s', e['at'], kind, e['const'])
        end
      end
      out.join("\n")
    end

    def text(report)
      m = report['metrics']
      score = Verdict.score(m)
      severity = Verdict.max_severity(report['seams'])
      out = []
      out << "DOMAIN: #{report['domain']}"
      indexed = (report['repo'] || {})['files_indexed']
      scale = indexed ? " of #{indexed} indexed" : ''
      out << "Resolved to #{m['domain_files']} files#{scale} (#{m['domain_loc']} LOC)"
      out << ''
      out << "ENTANGLEMENT: #{score}/10 -- #{Verdict.verdict(score, severity)}"
      out << ''
      out << format('  Inbound   %s  %d edges from %d units (%d files)',
                    bar(m['inbound_units'], 10), m['inbound_edges'], m['inbound_units'], m['inbound_files'])
      out << format('  Outbound  %s  %d edges to %d units',
                    bar(m['outbound_units'], 12), m['outbound_edges'], m['outbound_units'])
      out << format('  Facade    %s  %d domain constants referenced externally',
                    bar(m['exposed_constants'], 12), m['exposed_constants'])
      out << format('  Cycles    %s  %d true %s (+%d inverse assoc %s)',
                    bar(m['cycle_units'], 3), m['cycle_units'],
                    m['cycle_units'] == 1 ? 'cycle' : 'cycles',
                    m['assoc_pair_units'],
                    m['assoc_pair_units'] == 1 ? 'pair' : 'pairs')
      out << format('  Cohesion  %s  %.0f%% of edges stay inside the domain',
                    bar(m['cohesion_ratio'], 1.0), m['cohesion_ratio'] * 100)
      out << ''
      out << 'WHAT HAS TO BREAK FIRST'
      out << ''
      report['seams'].each_with_index do |seam, idx|
        out << format('  %d. [%s] %s', idx + 1, seam['severity'].upcase, seam['title'])
        out << "     #{seam['why']}"
        out << "     Break with: #{seam['break_with']}"
        (seam['citations'] || []).first(4).each do |c|
          out << "       - #{c['at']}  #{c['kind']}  -> #{c['to']}"
        end
        out << ''
      end
      out << 'NOT ANALYZED (absence of a finding here is not evidence of absence):'
      report['not_analyzed'].each { |n| out << "  - #{n}" }
      out.join("\n")
    end
  end
end

# ------------------------------------------------------------------------ main

if __FILE__ == $PROGRAM_NAME
  opts = { format: 'text', extra_consts: [], extra_files: [], domains: [] }
  OptionParser.new do |o|
    o.banner = <<~BANNER
      Usage: analyze_domain.rb --index PATH --domain NAME [options]
             analyze_domain.rb --index PATH --summary --all
    BANNER
    o.on('--index PATH', 'Index JSON from build_index.rb') { |v| opts[:index] = v }
    o.on('--domain NAME', 'Domain name, e.g. Billing (repeatable)') { |v| opts[:domains] << v }
    o.on('--domains-from PATH', 'File of domain names, one per line') { |v| opts[:domains_from] = v }
    o.on('--all', 'Every namespace in the index, or every top-level unit if it has none') { opts[:all] = true }
    o.on('--summary', 'Rank the domains in one table instead of reporting each in full') { opts[:summary] = true }
    o.on('--diagnose', 'Report constant-resolution rates for the whole index and exit') { opts[:diagnose] = true }
    o.on('--extra-const NAME', 'Additional constant in this domain (repeatable)') { |v| opts[:extra_consts] << v }
    o.on('--extra-file PATH', 'Additional file in this domain (repeatable)') { |v| opts[:extra_files] << v }
    o.on('--format FMT', 'text (default) or json') { |v| opts[:format] = v }
    o.on('-h', '--help') { puts o; exit 0 }
  end.parse!

  abort 'error: --index is required' unless opts[:index]

  index = JSON.parse(File.read(opts[:index]))

  if opts[:diagnose]
    d = ExtractScout.diagnose(index)
    puts opts[:format] == 'json' ? JSON.pretty_generate(d) : ExtractScout::Render.diagnostics(d)
    exit(d['warnings'].empty? ? 0 : 1)
  end

  domains = opts[:domains].dup
  if opts[:domains_from]
    domains += File.readlines(opts[:domains_from]).map(&:strip).reject { |l| l.empty? || l.start_with?('#') }
  end
  selected_all = opts[:all] ? ExtractScout.candidate_domains(index) : []
  domains = (domains + selected_all).uniq

  # "--all is required" when --all was given sends the reader to fix the wrong
  # thing. An empty selector and an empty result are different failures.
  if domains.empty?
    if opts[:all] || opts[:domains_from]
      abort "error: no domains found. The index at #{opts[:index]} holds " \
            "#{index['stats']['files_indexed']} files and #{index['stats']['constants']} constants " \
            '-- rebuild it with build_index.rb --root <repo> if that looks wrong.'
    end
    abort 'error: --domain, --domains-from or --all is required'
  end

  if opts[:summary] || domains.size > 1
    rows = ExtractScout.rank(domains.filter_map { |d| ExtractScout.summarize(index, d) })
    missed = domains - rows.map { |r| r['domain'] }
    # Silent truncation reads as "covered everything". Name what did not resolve.
    warn "extract-scout: #{missed.size} of #{domains.size} names resolved to no files: " \
         "#{missed.sort.join(', ')}" unless missed.empty?

    puts opts[:format] == 'json' ? JSON.pretty_generate(rows) : ExtractScout::Render.summary(rows)
    exit 0
  end

  domain = domains.first
  analyzer = ExtractScout::Analyzer.new(
    index, domain,
    extra_consts: opts[:extra_consts], extra_files: opts[:extra_files]
  )

  if analyzer.domain_files.empty?
    abort "error: '#{domain}' matched no files. Try --extra-const/--extra-file, " \
          'or check that the domain name matches a namespace, constant or path segment.'
  end

  report = analyzer.analyze
  report['entanglement_score'] = ExtractScout::Verdict.score(report['metrics'])
  report['max_severity']       = ExtractScout::Verdict.max_severity(report['seams'])
  report['verdict']            = ExtractScout::Verdict.verdict(
    report['entanglement_score'], report['max_severity']
  )

  puts opts[:format] == 'json' ? JSON.pretty_generate(report) : ExtractScout::Render.text(report)
end
