# frozen_string_literal: true

require_relative 'helper'

# The DocuSeal sweep produced 34 JSON reports and aggregated them with ad-hoc
# one-liners written in the conversation: sorting, grouping, tier-building, the
# markdown table. All of it deterministic, all re-derived from scratch, all
# consuming model context and open to transcription error. It belongs here.
class TestSummary < Minitest::Test
  include FixtureRepo

  # Shipping is a leaf. Billing <-> Fulfillment is a genuine behavioural cycle,
  # so Billing must rank as harder than Shipping despite being smaller.
  APP = {
    'app/models/application_record.rb' => "class ApplicationRecord\nend\n",
    'app/models/billing/invoice.rb' => <<~RB,
      module Billing
        class Invoice < ApplicationRecord
          def go
            Fulfillment::Picker.new
          end
        end
      end
    RB
    'app/models/fulfillment/picker.rb' => <<~RB,
      module Fulfillment
        class Picker
          def go
            Billing::Invoice.find(1)
          end
        end
      end
    RB
    'app/models/shipping/label.rb' => "module Shipping\n  class Label\n  end\nend\n"
  }.freeze

  def index(dir) = ExtractScout::Indexer.new(repo_root: dir).build

  def test_candidate_domains_are_the_namespaces_when_there_are_any
    with_repo(APP) do |dir|
      assert_equal %w[Billing Fulfillment Shipping], ExtractScout.candidate_domains(index(dir))
    end
  end

  # Most Rails apps have no namespaces at all, and a portfolio pass over such an
  # app should not come back empty -- its models are its de-facto units.
  def test_candidate_domains_fall_back_to_top_level_units
    flat = {
      'app/models/order.rb' => "class Order\nend\n",
      'app/models/invoice.rb' => "class Invoice\nend\n"
    }
    with_repo(flat) do |dir|
      assert_equal %w[Invoice Order], ExtractScout.candidate_domains(index(dir))
    end
  end

  def test_summarize_returns_the_headline_numbers_for_one_domain
    with_repo(APP) do |dir|
      row = ExtractScout.summarize(index(dir), 'Billing')
      assert_equal 'Billing', row['domain']
      assert_equal 'blocker', row['max_severity']
      assert_includes row['verdict'], 'BLOCKED'
      assert_operator row['metrics']['domain_files'], :>=, 1
    end
  end

  def test_summarize_returns_nil_for_a_domain_that_resolves_to_nothing
    with_repo(APP) do |dir|
      assert_nil ExtractScout.summarize(index(dir), 'Nonexistent')
    end
  end

  # The documented rule: "a blocked 2.0 goes after a clean 6.0". Blocking is a
  # precondition, so it outranks magnitude no matter how the scores fall.
  def test_ranking_puts_blocked_domains_last_regardless_of_score
    rows = [
      { 'domain' => 'Blocked', 'entanglement_score' => 2.0, 'max_severity' => 'blocker' },
      { 'domain' => 'Big',     'entanglement_score' => 6.0, 'max_severity' => 'major' },
      { 'domain' => 'Small',   'entanglement_score' => 1.0, 'max_severity' => nil }
    ]
    assert_equal %w[Small Big Blocked], ExtractScout.rank(rows).map { |r| r['domain'] }
  end

  def test_ranking_is_ascending_by_cost_within_a_blocking_tier
    rows = [
      { 'domain' => 'B', 'entanglement_score' => 5.0, 'max_severity' => 'major' },
      { 'domain' => 'A', 'entanglement_score' => 1.0, 'max_severity' => 'moderate' }
    ]
    assert_equal %w[A B], ExtractScout.rank(rows).map { |r| r['domain'] }
  end

  def test_ranking_is_stable_on_ties
    rows = [
      { 'domain' => 'Zeta',  'entanglement_score' => 1.0, 'max_severity' => nil },
      { 'domain' => 'Alpha', 'entanglement_score' => 1.0, 'max_severity' => nil }
    ]
    assert_equal %w[Alpha Zeta], ExtractScout.rank(rows).map { |r| r['domain'] }
  end

  # ------------------------------------------------------------------ render

  def rows_for(dir)
    idx = index(dir)
    ExtractScout.rank(ExtractScout.candidate_domains(idx).filter_map { |d| ExtractScout.summarize(idx, d) })
  end

  def test_summary_table_lists_every_domain_with_its_numbers
    with_repo(APP) do |dir|
      text = ExtractScout::Render.summary(rows_for(dir))
      assert_includes text, 'DOMAIN'
      %w[Billing Fulfillment Shipping].each { |d| assert_includes text, d }
    end
  end

  def test_summary_table_marks_blocked_domains
    with_repo(APP) do |dir|
      line = ExtractScout::Render.summary(rows_for(dir)).lines.find { |l| l.start_with?('Billing') }
      assert_includes line, 'BLOCKED'
    end
  end

  def test_summary_table_orders_easiest_first
    with_repo(APP) do |dir|
      text = ExtractScout::Render.summary(rows_for(dir))
      names = text.lines.filter_map { |l| l[/\A(\w+)/, 1] }.reject { |n| n == 'DOMAIN' }
      assert_equal 'Shipping', names.first
    end
  end

  # Ranking on partial signal is still ranking on partial signal.
  def test_summary_carries_the_honesty_clause
    with_repo(APP) do |dir|
      assert_includes ExtractScout::Render.summary(rows_for(dir)), 'NOT ANALYZED'
    end
  end

  def test_summary_of_nothing_says_so_rather_than_printing_an_empty_table
    assert_includes ExtractScout::Render.summary([]), 'No domains resolved'
  end
end
