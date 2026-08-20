#!/usr/bin/env ruby
# frozen_string_literal: true

# verdict_matrix.rb -- every (score, severity) combination the headline can hit.
#
# Verdict.score and Verdict.verdict encode judgment, not fact, so they cannot be
# unit-tested against a right answer. What they CAN be checked against is the one
# rule the skills state outright: "Do not soften a blocker."
#
# This prints the full matrix so the wording can be read in one pass, then checks
# the invariant mechanically -- without presuming any particular phrasing.
#
#   ruby test/verdict_matrix.rb

require 'json'

root = File.expand_path('..', __dir__)
src = File.read(File.join(root, 'scripts', 'analyze_domain.rb'))
# Load the library without executing the CLI main block.
eval(src.sub(/^if __FILE__ == \$PROGRAM_NAME.*/m, ''), TOPLEVEL_BINDING) # rubocop:disable Security/Eval

V = ExtractScout::Verdict

def seams_with(*severities)
  severities.map { |s| { 'severity' => s, 'title' => "synthetic #{s}" } }
end

def metrics(**over)
  {
    'cycle_units' => 0, 'exposed_constants' => 0, 'inbound_units' => 0,
    'boundary_assocs' => 0, 'outbound_units' => 0, 'string_couplings' => 0
  }.merge(over.transform_keys(&:to_s))
end

# Cases chosen to cover the corners, plus the real one that exposed the bug.
CASES = [
  ['fixture: 1 cycle, tiny domain',
   metrics(cycle_units: 1, exposed_constants: 1, inbound_units: 1, boundary_assocs: 1, outbound_units: 2),
   seams_with('blocker', 'major', 'moderate')],
  ['1 cycle, nothing else',        metrics(cycle_units: 1),  seams_with('blocker')],
  ['3 cycles, nothing else',       metrics(cycle_units: 3),  seams_with('blocker')],
  ['10 cycles, nothing else',      metrics(cycle_units: 10), seams_with('blocker')],
  ['high volume, zero cycles',
   metrics(exposed_constants: 99, inbound_units: 99, boundary_assocs: 99, outbound_units: 99, string_couplings: 99),
   seams_with('major', 'moderate')],
  ['high volume + a cycle',
   metrics(cycle_units: 3, exposed_constants: 99, inbound_units: 99, boundary_assocs: 99, outbound_units: 99, string_couplings: 99),
   seams_with('blocker', 'major')],
  ['moderate seams only',          metrics(inbound_units: 6), seams_with('moderate')],
  ['nothing found at all',         metrics,                   []]
].freeze

def render(score, severity)
  V.verdict(score, severity)
rescue NotImplementedError
  '<Verdict.verdict is unwritten>'
end

puts
puts format('  %-30s %6s  %-9s  %s', 'CASE', 'SCORE', 'SEVERITY', 'HEADLINE')
puts "  #{'-' * 96}"
CASES.each do |name, m, seams|
  score = V.score(m)
  severity = V.max_severity(seams)
  puts format('  %-30s %6s  %-9s  %s', name, score, severity || '-', render(score, severity))
end
puts

# --- invariant: blocking must change the headline -------------------------------
#
# Wording is a free choice. Legibility is not: if a blocker produces the same
# headline as no seams at all at the same score, the blocker is invisible.
failures = []
[0.5, 1.1, 3.2, 6.8, 9.5].each do |score|
  blocked = render(score, 'blocker')
  next if blocked.start_with?('<')

  clean = render(score, nil)
  failures << "score #{score}: blocker and no-seams both read #{blocked.inspect}" if blocked == clean

  major = render(score, 'major')
  failures << "score #{score}: blocker and major both read #{blocked.inspect}" if blocked == major
end

if failures.empty?
  puts render(1.1, 'blocker').start_with?('<') ? "  (invariant not checked -- write Verdict.verdict first)\n\n" : "  ok: a blocker is distinguishable at every score\n\n"
else
  puts "  FAIL: 'do not soften a blocker' violated"
  failures.each { |f| puts "    - #{f}" }
  puts
  exit 1
end
