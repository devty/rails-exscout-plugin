# frozen_string_literal: true

require_relative 'helper'

# A monolith with both shapes that look bidirectional in a naive graph:
#
#   Order       <-> Billing  -- association from both ends. ONE relationship
#                               written twice; the standard Rails idiom.
#   Fulfillment <-> Billing  -- method calls both ways. A real cycle.
#
# Collapsing these is the false positive the README singles out as the one that
# makes engineers stop trusting the report.
FIXTURE = {
  'app/models/application_record.rb' => "class ApplicationRecord\nend\n",
  'app/models/order.rb' => <<~RB,
    class Order < ApplicationRecord
      has_many :invoices, class_name: "Billing::Invoice"
    end
  RB
  'app/models/billing/invoice.rb' => <<~RB,
    module Billing
      class Invoice < ApplicationRecord
        belongs_to :order
      end
    end
  RB
  'app/models/billing/calculator.rb' => <<~RB,
    module Billing
      class Calculator
        def go
          Fulfillment::Picker.new
        end
      end
    end
  RB
  'app/models/fulfillment/picker.rb' => <<~RB
    module Fulfillment
      class Picker
        def go
          Billing::Invoice.find(1)
        end
      end
    end
  RB
}.freeze

class TestAnalyzeDomain < Minitest::Test
  include FixtureRepo

  def analyze(dir, domain, **opts)
    idx = ExtractScout::Indexer.new(repo_root: dir).build
    ExtractScout::Analyzer.new(idx, domain, **opts).analyze
  end

  def with_billing
    with_repo(FIXTURE) { |dir| yield analyze(dir, 'Billing') }
  end

  # ------------------------------------------------------- domain resolution

  def test_namespace_resolves_the_domain_to_its_files
    with_billing do |r|
      assert_equal ['app/models/billing/calculator.rb', 'app/models/billing/invoice.rb'], r['files']
    end
  end

  def test_resolution_records_its_evidence
    with_billing do |r|
      assert_includes r['evidence']['app/models/billing/invoice.rb'], 'namespace'
    end
  end

  def test_extra_file_pulls_an_unnamespaced_model_into_the_domain
    with_repo(FIXTURE) do |dir|
      r = analyze(dir, 'Billing', extra_files: ['app/models/order.rb'])
      assert_includes r['files'], 'app/models/order.rb'
      assert_includes r['evidence']['app/models/order.rb'], 'agent:file'
    end
  end

  def test_extra_const_pulls_a_constant_into_the_domain
    with_repo(FIXTURE) do |dir|
      r = analyze(dir, 'Billing', extra_consts: ['Order'])
      assert_includes r['files'], 'app/models/order.rb'
    end
  end

  # --------------------------------------------------- cycles vs inverse pairs

  def test_association_only_bidirectionality_is_not_a_cycle
    with_billing do |r|
      assert_includes r['inverse_association_pairs'], 'Order'
      refute_includes r['cycles'].map { |c| c['unit'] }, 'Order'
    end
  end

  def test_behavioural_bidirectionality_is_a_cycle
    with_billing do |r|
      assert_equal ['Fulfillment'], r['cycles'].map { |c| c['unit'] }
      assert_equal 1, r['metrics']['cycle_units']
    end
  end

  def test_cycle_detail_cites_both_directions
    with_billing do |r|
      cycle = r['cycles'].first
      refute_empty cycle['calls_in']
      refute_empty cycle['called_by']
    end
  end

  # ------------------------------------------------------------------ edges

  def test_inbound_and_outbound_are_counted_separately
    with_billing do |r|
      assert_equal 2, r['metrics']['inbound_edges']
      assert_equal 2, r['metrics']['outbound_edges']
    end
  end

  # ApplicationRecord is defined in the repo, so nothing but the ubiquitous list
  # stops every model in the app from sharing a fat, meaningless edge.
  def test_ubiquitous_base_classes_are_not_edges
    with_billing do |r|
      targets = r['outbound'].map { |u| u['unit'] }
      refute_includes targets, 'ApplicationRecord'
    end
  end

  def test_exposed_constants_measure_facade_leakage
    with_billing do |r|
      assert_equal ['Billing::Invoice'], r['exposed_constants']
    end
  end

  def test_cohesion_is_a_ratio_of_internal_to_total
    with_billing do |r|
      assert_operator r['metrics']['cohesion_ratio'], :>=, 0.0
      assert_operator r['metrics']['cohesion_ratio'], :<=, 1.0
    end
  end

  def test_citations_carry_file_and_line
    with_billing do |r|
      r['inbound'].flat_map { |u| u['citations'] }.each do |c|
        assert_match(%r{\A[\w/.]+\.rb:\d+\z}, c['at'])
      end
    end
  end

  # ------------------------------------------------------------------ seams

  def test_cycle_outranks_volume_in_the_seam_ordering
    with_billing do |r|
      assert_equal 'cycle', r['seams'].first['type']
      assert_equal 'blocker', r['seams'].first['severity']
    end
  end

  def test_seams_are_sorted_by_descending_score
    with_billing do |r|
      scores = r['seams'].map { |s| s['score'] }
      assert_equal scores.sort.reverse, scores
    end
  end

  def test_every_seam_carries_citations_and_a_remedy
    with_billing do |r|
      r['seams'].each do |seam|
        refute_empty seam['break_with']
        refute_nil seam['citations']
      end
    end
  end

  # The honesty clause. Absence of a finding is not evidence of absence, and the
  # report must say which surfaces were never read.
  def test_not_analyzed_is_always_reported
    with_billing do |r|
      assert_equal 4, r['not_analyzed'].size
      assert(r['not_analyzed'].any? { |n| n.include?('foreign key') })
    end
  end

  def test_unresolvable_domain_yields_no_files
    with_repo(FIXTURE) do |dir|
      idx = ExtractScout::Indexer.new(repo_root: dir).build
      assert_empty ExtractScout::Analyzer.new(idx, 'Nonexistent').domain_files
    end
  end
end

# The constant walk mirrors Ruby's own Module.nesting lookup. Without it a bare
# token either misses entirely or binds to a same-named class in another domain.
class TestConstantResolver < Minitest::Test
  include FixtureRepo

  def resolver(dir)
    ExtractScout::ConstantResolver.new(ExtractScout::Indexer.new(repo_root: dir).build)
  end

  def test_bare_constant_prefers_the_enclosing_namespace
    with_repo(FIXTURE.merge(
                'app/models/billing/picker.rb' => "module Billing\n  class Picker\n  end\nend\n"
              )) do |dir|
      const, = resolver(dir).resolve('Picker', 'Billing')
      assert_equal 'Billing::Picker', const
    end
  end

  def test_bare_constant_falls_back_to_top_level
    with_repo(FIXTURE) do |dir|
      const, = resolver(dir).resolve('Order', 'Billing')
      assert_equal 'Order', const
    end
  end

  def test_ubiquitous_constants_never_resolve
    with_repo(FIXTURE) do |dir|
      assert_nil resolver(dir).resolve('ApplicationRecord', 'Billing')
    end
  end

  def test_unknown_constants_resolve_to_nothing
    with_repo(FIXTURE) do |dir|
      assert_nil resolver(dir).resolve('Nope', '')
    end
  end
end
