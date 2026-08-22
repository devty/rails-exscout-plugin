# frozen_string_literal: true

require_relative 'helper'

# Found by running the skill end to end against Mastodon. None of these is a
# correctness bug -- the numbers were right. They are the difference between a
# report a person reads and one they scroll past.
class TestBriefFormat < Minitest::Test
  include FixtureRepo

  def setup = ExtractScout::Inflect.reset!
  def teardown = ExtractScout::Inflect.reset!

  # Enough files that the full JSON carries real weight.
  def app
    files = { 'app/models/application_record.rb' => "class ApplicationRecord\nend\n" }
    14.times do |i|
      files["app/models/core/m#{i}.rb"] = <<~RB
        module Core
          class M#{i} < ApplicationRecord
            belongs_to :outsider
            def go = Outsider.find(1)
          end
        end
      RB
    end
    files['app/models/outsider.rb'] = "class Outsider < ApplicationRecord\n  def go = Core::M0.find(1)\nend\n"
    files
  end

  def reports
    with_repo(app) do |dir|
      idx = ExtractScout::Indexer.new(repo_root: dir).build
      full = ExtractScout::Analyzer.new(idx, 'Core').analyze
      return [full, ExtractScout.brief(full)]
    end
  end

  # Step 3 asked the model to read --format json to check one thing: how the
  # boundary resolved. On Mastodon's ActivityPub that is 271 KB / ~68k tokens for
  # a binary decision, and it scales with domain size -- worst on exactly the
  # domains most worth scouting.
  def test_brief_is_dramatically_smaller_than_the_full_report
    full, brief = reports
    assert_operator brief.to_json.bytesize * 3, :<, full.to_json.bytesize
  end

  # The per-file evidence map is what makes the full report large, and the
  # decision only ever needed the tally.
  def test_brief_tallies_evidence_instead_of_listing_it_per_file
    _, brief = reports
    refute brief['evidence'].is_a?(Hash) && brief['evidence'].values.first.is_a?(Array)
    assert_kind_of Integer, brief['evidence_tally'].values.first
    assert_equal 14, brief['evidence_tally'].values.sum
  end

  def test_brief_keeps_everything_a_dispatch_decision_needs
    _, brief = reports
    %w[domain target metrics entanglement_score max_severity verdict seams not_analyzed].each do |k|
      refute_nil brief[k], "brief dropped #{k}"
    end
  end

  # Step 4 dispatches on severity and Step 5 reports citations, so both survive.
  def test_brief_keeps_seam_severities_and_a_few_citations
    _, brief = reports
    seam = brief['seams'].first
    refute_nil seam['severity']
    assert_operator (seam['citations'] || []).size, :<=, 4
  end

  def test_brief_keeps_the_honesty_clause_intact
    full, brief = reports
    assert_equal full['not_analyzed'], brief['not_analyzed']
  end

  def test_brief_reports_the_repo_scale
    _, brief = reports
    refute_nil brief['repo']
  end
end

# The terminal summary rendered every seam. On ActivityPub that was 32 seams over
# 267 lines -- not a summary. Capping it is fine; capping it silently is not,
# because a truncated list reads as a complete one.
class TestSeamRenderCap < Minitest::Test
  include FixtureRepo

  def report_with(n_seams)
    seams = Array.new(n_seams) do |i|
      { 'type' => 'cycle', 'severity' => 'blocker', 'title' => "Cycle: X <-> U#{i}",
        'why' => 'w', 'break_with' => 'b', 'score' => 100 - i, 'citations' => [] }
    end
    {
      'domain' => 'X', 'seams' => seams, 'ambient' => {},
      'repo' => { 'files_indexed' => 100 },
      'metrics' => { 'domain_files' => 1, 'domain_loc' => 1, 'inbound_edges' => 0,
                     'outbound_edges' => 0, 'inbound_units' => 0, 'outbound_units' => 0,
                     'inbound_files' => 0, 'exposed_constants' => 0, 'cycle_units' => 0,
                     'assoc_pair_units' => 0, 'cohesion_ratio' => 1.0 },
      'not_analyzed' => ['x']
    }
  end

  def test_a_short_seam_list_is_shown_whole_with_no_note
    text = ExtractScout::Render.text(report_with(4))
    assert_equal 4, text.scan(/^  \d+\. \[/).size
    refute_match(/not shown/i, text)
  end

  def test_a_long_seam_list_is_capped
    text = ExtractScout::Render.text(report_with(40))
    assert_operator text.scan(/^  \d+\. \[/).size, :<, 40
  end

  # Silent truncation reads as "covered everything".
  def test_the_cap_says_what_it_left_out
    text = ExtractScout::Render.text(report_with(40))
    assert_match(/not shown/i, text)
    assert_match(/40/, text)
  end

  def test_the_cap_names_how_to_see_the_rest
    assert_match(/--format json/, ExtractScout::Render.text(report_with(40)))
  end
end
