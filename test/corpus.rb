#!/usr/bin/env ruby
# frozen_string_literal: true

# corpus.rb -- resolution baselines against real Rails apps.
#
#   EXTRACT_SCOUT_CORPUS=~/corpus ruby test/corpus.rb
#
# Why this exists, and why it is separate from test/run_all.rb:
#
# The unit suite asserts the analyzer does what it was written to do. Every one
# of D1-D6 passed it, because each was a shape the synthetic fixtures did not
# contain. Synthetic tests cannot find the case nobody thought of; only real code
# can, because real code contains the cases nobody thought of.
#
# What makes that checkable without hand-labelled ground truth is the signature a
# misparse leaves: a fabricated constant resolves to nothing. See the diagnostics
# section of scripts/analyze_domain.rb.
#
# This harness deliberately does NOT clone anything. It tells you what to fetch
# and skips what is missing, so it is safe to run anywhere and honest about what
# it did not check.

require 'json'
require 'fileutils'

ROOT = File.expand_path('..', __dir__)
require File.join(ROOT, 'scripts', 'build_index')
require File.join(ROOT, 'scripts', 'analyze_domain')

manifest_path = ENV.fetch('EXTRACT_SCOUT_CORPUS_MANIFEST', File.join(__dir__, 'corpus.json'))
manifest = JSON.parse(File.read(manifest_path))
corpus_dir = ENV['EXTRACT_SCOUT_CORPUS']

if corpus_dir.nil? || corpus_dir.empty?
  warn 'corpus.rb: set EXTRACT_SCOUT_CORPUS to a directory holding the checkouts.'
  warn ''
end

checked = 0
skipped = []
failures = []

manifest['repos'].each do |entry|
  name = entry['name']
  path = corpus_dir && File.join(File.expand_path(corpus_dir), name)

  unless path && File.directory?(path)
    skipped << entry
    next
  end

  head = `git -C #{path.inspect} rev-parse --short HEAD 2>/dev/null`.strip
  index = ExtractScout::Indexer.new(repo_root: path).build
  d = ExtractScout.diagnose(index)
  assoc = d['by_kind']['association'] || { 'total' => 0, 'rate' => 1.0 }
  expect = entry['expect']

  puts "#{name} @ #{head.empty? ? '?' : head} (pinned #{entry['ref']})"
  puts format('  files indexed      %d   (expect >= %d)', d['files_indexed'], expect['files_indexed_min'])
  puts format('  association refs   %d   (expect >= %d)', assoc['total'], expect['association_total_min'])
  puts format('  association rate   %d%%  (expect >= %d%%)',
              (assoc['rate'] * 100).round, (expect['association_rate_min'] * 100).round)

  if head != '' && !entry['ref'].start_with?(head) && !head.start_with?(entry['ref'])
    puts "  NOTE: checkout is not at the pinned ref -- baselines may not apply"
  end

  {
    'files_indexed' => [d['files_indexed'], expect['files_indexed_min']],
    'association_total' => [assoc['total'], expect['association_total_min']],
    'association_rate' => [assoc['rate'], expect['association_rate_min']]
  }.each do |metric, (actual, minimum)|
    failures << "#{name}: #{metric} #{actual} < #{minimum}" if actual < minimum
  end

  unless d['warnings'].empty?
    d['warnings'].each { |w| failures << "#{name}: #{w}" }
  end

  checked += 1
  puts
end

unless skipped.empty?
  puts 'SKIPPED -- not checked out:'
  skipped.each do |entry|
    dest = corpus_dir ? File.join(corpus_dir, entry['name']) : "<corpus>/#{entry['name']}"
    puts "  #{entry['name']}: #{entry['notes']}"
    puts "    git clone #{entry['clone']} #{dest} && git -C #{dest} checkout #{entry['ref']}"
  end
  puts
end

# Silent truncation reads as "covered everything". Say what was not covered.
puts "checked #{checked} of #{manifest['repos'].size} corpus repos" \
     "#{skipped.empty? ? '' : ", #{skipped.size} skipped"}"

if failures.empty?
  puts checked.zero? ? 'nothing verified -- no baselines were exercised' : 'all baselines met'
  exit 0
end

puts
puts 'FAILURES'
failures.each { |f| puts "  - #{f}" }
exit 1
