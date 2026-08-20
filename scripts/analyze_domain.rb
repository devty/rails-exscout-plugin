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
    BEHAVIORAL_KINDS = %w[reference mixin superclass dsl_string delegation].freeze

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
      cycle_units, assoc_pair_units = bidirectional.partition do |unit|
        behavioral?(inbound_units[unit]) && behavioral?(outbound_units[unit])
      end

      # Distinct domain constants reached from outside = how leaky the facade is.
      exposed = inbound.map(&:to_const).uniq.sort

      {
        'domain'  => @domain,
        'files'   => @domain_files.to_a.sort,
        'evidence' => @evidence,
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
          'assoc_pair_units'    => assoc_pair_units.size,
          'boundary_assocs'     => (inbound + outbound).count { |c| ASSOCIATION_KINDS.include?(c.kind) },
          'string_couplings'    => (inbound + outbound).count { |c| c.kind == 'dsl_string' },
          'cohesion_ratio'      => cohesion(internal, inbound.size + outbound.size)
        },
        'exposed_constants' => exposed,
        'cycles'   => cycle_units.map { |u| cycle_detail(u, inbound_units, outbound_units) },
        'inverse_association_pairs' => assoc_pair_units,
        'inbound'  => summarize_units(inbound_units),
        'outbound' => summarize_units(outbound_units),
        'seams'    => rank_seams(inbound, outbound, inbound_units, outbound_units,
                                 cycle_units, assoc_pair_units, exposed)
      }
    end

    def behavioral?(crossings)
      crossings.any? { |c| BEHAVIORAL_KINDS.include?(c.kind) }
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

    SEAM_WEIGHTS = {
      'cycle'            => 100,
      'facade_leak'      => 60,
      'boundary_assoc'   => 45,
      'string_coupling'  => 40,
      'shared_mixin'     => 35,
      'inbound_volume'   => 25,
      'outbound_dep'     => 20
    }.freeze

    def rank_seams(inbound, outbound, inbound_units, outbound_units,
                   cycle_units, assoc_pair_units, exposed)
      seams = []

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
        seams << {
          'type' => 'boundary_assoc', 'severity' => 'major',
          'title' => "#{assoc.size} ActiveRecord #{plural(assoc.size, 'association')} " \
                     "#{assoc.size == 1 ? 'crosses' : 'cross'} the boundary",
          'why' => 'Each implies a join and almost always a foreign key. After extraction ' \
                   'these cannot be traversed in SQL -- they become remote calls or denormalized ids.' + pair_note,
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

  # -------------------------------------------------------------------- render

  module Render
    module_function

    def bar(value, full, width = 10)
      filled = [[(value.to_f / full * width).round, width].min, 0].max
      ('#' * filled) + ('.' * (width - filled))
    end

    def text(report)
      m = report['metrics']
      score = Verdict.score(m)
      severity = Verdict.max_severity(report['seams'])
      out = []
      out << "DOMAIN: #{report['domain']}"
      out << "Resolved to #{m['domain_files']} files (#{m['domain_loc']} LOC)"
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
  opts = { format: 'text', extra_consts: [], extra_files: [] }
  OptionParser.new do |o|
    o.banner = 'Usage: analyze_domain.rb --index PATH --domain NAME [options]'
    o.on('--index PATH', 'Index JSON from build_index.rb') { |v| opts[:index] = v }
    o.on('--domain NAME', 'Domain name, e.g. Billing') { |v| opts[:domain] = v }
    o.on('--extra-const NAME', 'Additional constant in this domain (repeatable)') { |v| opts[:extra_consts] << v }
    o.on('--extra-file PATH', 'Additional file in this domain (repeatable)') { |v| opts[:extra_files] << v }
    o.on('--format FMT', 'text (default) or json') { |v| opts[:format] = v }
    o.on('-h', '--help') { puts o; exit 0 }
  end.parse!

  abort 'error: --index and --domain are required' unless opts[:index] && opts[:domain]

  index = JSON.parse(File.read(opts[:index]))
  analyzer = ExtractScout::Analyzer.new(
    index, opts[:domain],
    extra_consts: opts[:extra_consts], extra_files: opts[:extra_files]
  )

  if analyzer.domain_files.empty?
    abort "error: '#{opts[:domain]}' matched no files. Try --extra-const/--extra-file, " \
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
