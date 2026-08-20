#!/usr/bin/env ruby
# frozen_string_literal: true

# check_cross_domain.rb -- PostToolUse guard against new cross-domain associations.
#
# Fires after Edit/MultiEdit/Write. Warns when the edit ADDS an ActiveRecord
# association whose target lives in a different domain than the edited file.
#
# Design constraints, in priority order:
#
#   1. SILENT unless there is something real to say. This runs on every edit; a
#      hook that cries wolf gets switched off within a day and then protects
#      nothing. Every ambiguous case resolves to silence.
#   2. FAST. Parses only the text the edit added, never the repo. Two globs at
#      most. Budget is tens of milliseconds, not seconds.
#   3. SHARED DEFINITIONS. Reuses build_index.rb's FileAnalyzer, so the hook and
#      `/extract-scout` can never disagree about what an association is.
#
# Boundary knowledge comes from, in order:
#   - .extract-scout/domains.json  (written by /extract-scout; knows unnamespaced
#     domains a namespace check cannot see)
#   - Zeitwerk namespace inference (fallback; only warns when BOTH sides are
#     namespaced, which is the near-zero-false-positive case)
#
# Disable with EXTRACT_SCOUT_HOOK=off

require 'json'
require 'set'

module ExtractScout
  module Hook
    APP_ROOTS = %w[app lib engines packs components].freeze
    EDIT_TOOLS = %w[Edit MultiEdit Write].freeze

    module_function

    # ---------------------------------------------------------------- payload

    def added_text(tool_name, tool_input)
      case tool_name
      when 'Write'
        tool_input['content'].to_s
      when 'Edit'
        diff_added(tool_input['old_string'].to_s, tool_input['new_string'].to_s)
      when 'MultiEdit'
        Array(tool_input['edits']).map { |e|
          diff_added(e['old_string'].to_s, e['new_string'].to_s)
        }.join("\n")
      else
        ''
      end
    end

    # Only lines genuinely introduced by this edit. Without this, re-editing a
    # file for an unrelated reason re-warns about associations already reviewed.
    def diff_added(old_str, new_str)
      old_lines = old_str.lines.map(&:strip).to_set
      new_str.lines.reject { |l| old_lines.include?(l.strip) }.join
    end

    # ----------------------------------------------------------------- domains

    # Boundary map persisted by /extract-scout. Optional -- absence just means
    # the hook falls back to namespace inference.
    def load_domains(project_dir)
      path = File.join(project_dir, '.extract-scout', 'domains.json')
      return nil unless File.file?(path)

      data = JSON.parse(File.read(path))
      return nil unless data.is_a?(Hash) && data['domains'].is_a?(Hash)

      data
    rescue StandardError
      nil
    end

    def ignored?(domains, rel_path)
      Array(domains && domains['ignore']).any? do |pattern|
        File.fnmatch?(pattern, rel_path, File::FNM_PATHNAME | File::FNM_EXTGLOB)
      end
    end

    # Which domain owns this file? nil means "no domain we can identify".
    def domain_of_file(domains, rel_path, const)
      if domains
        domains['domains'].each do |name, meta|
          return name if Array(meta['files']).include?(rel_path)
          return name if const && Array(meta['constants']).include?(const)
        end
      end
      namespace_of(const)
    end

    def domain_of_const(domains, const)
      if domains
        domains['domains'].each do |name, meta|
          return name if Array(meta['constants']).include?(const)
          return name if const == name || const.start_with?("#{name}::")
        end
      end
      namespace_of(const)
    end

    def namespace_of(const)
      return nil unless const&.include?('::')

      const.split('::').first
    end

    # ---------------------------------------------------------------- resolve

    # Ruby resolves a bare constant against the enclosing namespace first, so
    # `belongs_to :line_item` inside Billing::Invoice means Billing::LineItem
    # when that exists. Checking this is what keeps the hook quiet about a
    # domain's own internal associations.
    def resolve_target(project_dir, source_ns, const)
      return const if const.include?('::')

      if source_ns && file_exists_for?(project_dir, "#{source_ns}::#{const}")
        return "#{source_ns}::#{const}"
      end

      const
    end

    def file_exists_for?(project_dir, const)
      rel = const.split('::').map { |seg| snake(seg) }.join('/')
      APP_ROOTS.any? do |root|
        !Dir.glob(File.join(project_dir, root, '**', "#{rel}.rb")).empty?
      end
    end

    def snake(str)
      str.gsub(/([a-z\d])([A-Z])/, '\1_\2')
         .gsub(/([A-Z]+)([A-Z][a-z])/, '\1_\2')
         .downcase
    end

    # ----------------------------------------------------------------- report

    def format_warning(findings, source_domain, authoritative)
      lines = []
      noun = findings.size == 1 ? 'association' : 'associations'
      lines << "extract-scout: new cross-domain #{noun}"
      lines << ''
      findings.each do |f|
        lines << "  #{f[:rel_path]}  (#{source_domain} -> #{f[:target_domain]})"
        lines << "    #{f[:snippet]}"
      end
      lines << ''
      lines << '  This association crosses a domain boundary. It implies a join and almost'
      lines << '  always a foreign key -- neither survives extracting either side into its'
      lines << '  own service.'
      lines << ''
      lines << '  If deliberate, carry on. If not, an explicit id column plus a lookup at'
      lines << '  the seam gives you the same data without welding the domains together.'
      unless authoritative
        lines << ''
        lines << '  (Boundaries inferred from namespaces. Run /extract-scout to record a'
        lines << '   boundary map and catch unnamespaced domains too.)'
      end
      lines << ''
      lines << '  Silence this hook: EXTRACT_SCOUT_HOOK=off'
      lines.join("\n")
    end

    # ------------------------------------------------------------------- main

    def run
      exit 0 if ENV['EXTRACT_SCOUT_HOOK'].to_s.downcase == 'off'

      raw = $stdin.read
      exit 0 if raw.nil? || raw.strip.empty?

      payload = JSON.parse(raw)
      tool_name = payload['tool_name'].to_s
      exit 0 unless EDIT_TOOLS.include?(tool_name)

      tool_input = payload['tool_input']
      exit 0 unless tool_input.is_a?(Hash)

      file_path = tool_input['file_path'].to_s
      exit 0 unless file_path.end_with?('.rb')

      project_dir = ENV['CLAUDE_PROJECT_DIR'] || payload['cwd'] || Dir.pwd
      project_dir = File.expand_path(project_dir)
      abs = File.expand_path(file_path, project_dir)
      exit 0 unless abs.start_with?("#{project_dir}/")

      rel_path = abs.delete_prefix("#{project_dir}/")
      exit 0 unless APP_ROOTS.include?(rel_path.split('/').first)

      added = added_text(tool_name, tool_input)
      exit 0 if added.strip.empty?
      # Cheap pre-filter: skip the parser entirely when no macro is present.
      exit 0 unless added.match?(/\b(belongs_to|has_many|has_one|has_and_belongs_to_many)\b/)

      # Only now is the parser worth loading. A crashing PostToolUse hook is far
      # worse than a missed warning, so a failed load exits quietly.
      begin
        require_relative '../../scripts/build_index'
      rescue StandardError, LoadError
        exit 0
      end

      domains = load_domains(project_dir)
      exit 0 if ignored?(domains, rel_path)

      source_const = AutoloadRoots.new(project_dir).constant_for(abs)
      source_domain = domain_of_file(domains, rel_path, source_const)
      # No identifiable source domain means no boundary to cross. Stay quiet.
      exit 0 if source_domain.nil?

      source_ns = namespace_of(source_const)
      analyzer = FileAnalyzer.new(rel_path, added).analyze
      associations = analyzer.refs.select { |r| r.kind == 'association' }
      exit 0 if associations.empty?

      added_lines = added.lines
      findings = []

      associations.each do |ref|
        target = resolve_target(project_dir, source_ns, ref.const)
        target_domain = domain_of_const(domains, target)
        next if target_domain == source_domain

        # Only warn when the target belongs to a DIFFERENT IDENTIFIED domain.
        # A target we cannot classify is unclassified, not foreign -- warning
        # about it means warning about half the models in a normal Rails app.
        # Leaving a domain is expected and already quantified by /extract-scout;
        # the sharper signal this hook exists for is welding two known domains
        # together.
        next if target_domain.nil?

        snippet = added_lines[ref.line - 1].to_s.strip
        next if snippet.empty?

        findings << {
          rel_path: rel_path,
          snippet: snippet,
          target_domain: target_domain
        }
      end

      exit 0 if findings.empty?

      puts JSON.generate(
        'systemMessage' => format_warning(findings, source_domain, !domains.nil?)
      )
      exit 0
    rescue StandardError
      # Never let an analysis bug surface as a tool error.
      exit 0
    end
  end
end

ExtractScout::Hook.run if __FILE__ == $PROGRAM_NAME
