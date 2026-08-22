# frozen_string_literal: true

require_relative 'helper'

# Every piece of advice the tool gives assumes extraction to another Ruby
# service. "Promote the concern to a shared library both sides may depend on"
# and "confirm the FK in schema.rb" mean something different, or nothing, if the
# destination is a Node rewrite or a Packwerk pack in the same process.
#
# The DocuSeal engagement was a Rails -> Node port, and the tool ranked cycles
# first -- the axis that mattered least, because both sides were being rewritten
# together and nothing moved incrementally.
class TestTarget < Minitest::Test
  include FixtureRepo

  APP = {
    'app/models/application_record.rb' => "class ApplicationRecord\nend\n",
    'app/models/order.rb' => <<~RB,
      class Order < ApplicationRecord
        include Auditable
        has_many :invoices, class_name: "Billing::Invoice"
        def total
          Billing::Calculator.new(self).total
        end
      end
    RB
    'app/models/concerns/auditable.rb' => "module Auditable\nend\n",
    'app/models/billing/invoice.rb' => <<~RB,
      module Billing
        class Invoice < ApplicationRecord
          include Auditable
          belongs_to :order
        end
      end
    RB
    'app/models/billing/calculator.rb' => <<~RB
      module Billing
        class Calculator
          def total
            Order.find(1).amount
          end
        end
      end
    RB
  }.freeze

  def report(target: nil)
    with_repo(APP) do |dir|
      idx = ExtractScout::Indexer.new(repo_root: dir).build
      kw = target ? { target: target } : {}
      return ExtractScout::Analyzer.new(idx, 'Billing', **kw).analyze
    end
  end

  def seam(report, type) = report['seams'].find { |s| s['type'] == type }

  # ------------------------------------------------------------------ basics

  def test_default_target_is_a_ruby_service
    assert_equal 'ruby-service', report['target']
  end

  def test_unknown_target_is_rejected_with_the_valid_ones_named
    err = assert_raises(ArgumentError) { report(target: 'nonsense') }
    assert_includes err.message, 'ruby-service'
    assert_includes err.message, 'other-language'
  end

  def test_every_target_carries_a_human_label
    %w[ruby-service modular-monolith other-language].each do |t|
      refute_empty report(target: t)['target_label']
    end
  end

  # ------------------------------------------------- cross-language rewrite

  # Nothing moves incrementally in a rewrite: both sides are reimplemented
  # together, so a cycle is a sequencing note rather than a precondition.
  def test_a_cycle_is_not_a_blocker_when_both_sides_are_being_rewritten
    assert_equal 'blocker', seam(report, 'cycle')['severity']
    refute_equal 'blocker', seam(report(target: 'other-language'), 'cycle')['severity']
  end

  def test_a_rewrite_is_not_blocked_by_a_cycle_alone
    r = report(target: 'other-language')
    refute_equal 'blocker', ExtractScout::Verdict.max_severity(r['seams'])
  end

  # "Promote it to a shared library both sides may depend on" is false across a
  # language boundary -- the logic gets reimplemented, as new code.
  def test_shared_mixin_advice_stops_promising_a_shared_library
    assert_includes seam(report, 'shared_mixin')['break_with'], 'shared'
    rewritten = seam(report(target: 'other-language'), 'shared_mixin')['break_with']
    assert_match(/reimplement/i, rewritten)
  end

  # The data layer is the specification for the new system, not a thing to sever.
  def test_association_advice_reframes_the_schema_as_the_specification
    rewritten = seam(report(target: 'other-language'), 'boundary_assoc')['break_with']
    assert_match(/schema|data model/i, rewritten)
    refute_match(/remote call/i, rewritten)
  end

  def test_associations_outrank_cycles_for_a_rewrite
    r = report(target: 'other-language')
    types = r['seams'].map { |s| s['type'] }
    assert_operator types.index('boundary_assoc'), :<, types.index('cycle')
  end

  # The most useful thing the tool can say about a port is that it is ranking
  # the wrong axis.
  def test_a_rewrite_is_told_the_decisive_factors_are_unmodelled
    r = report(target: 'other-language')
    refute_nil r['target_caveat']
    assert_match(/runtime|not modelled|not modeled/i, r['target_caveat'])
    assert(r['not_analyzed'].any? { |n| n.match?(/encrypt|serialize|ActiveStorage|runtime/i) })
  end

  # ---------------------------------------------------- modular monolith

  # A cross-pack association keeps working: it becomes a declared dependency,
  # not a remote call. It is still worth knowing and is no longer the long pole.
  def test_associations_matter_less_inside_one_process
    default_score = seam(report, 'boundary_assoc')['score']
    modular_score = seam(report(target: 'modular-monolith'), 'boundary_assoc')['score']
    assert_operator modular_score, :<, default_score
  end

  def test_association_advice_points_at_declaring_rather_than_severing
    advice = seam(report(target: 'modular-monolith'), 'boundary_assoc')['break_with']
    assert_match(/declar|package\.yml/i, advice)
  end

  def test_a_cycle_is_still_a_blocker_inside_one_process
    assert_equal 'blocker', seam(report(target: 'modular-monolith'), 'cycle')['severity']
  end

  def test_facade_leak_matters_more_when_the_boundary_is_the_product
    with_repo(APP) do |dir|
      idx = ExtractScout::Indexer.new(repo_root: dir).build
      a = ExtractScout::Analyzer.new(idx, 'Billing').analyze
      b = ExtractScout::Analyzer.new(idx, 'Billing', target: 'modular-monolith').analyze
      next if seam(a, 'facade_leak').nil?

      assert_operator seam(b, 'facade_leak')['score'], :>, seam(a, 'facade_leak')['score']
    end
  end

  # ------------------------------------------------------------------ render

  def test_the_text_report_names_the_target_it_assumed
    with_repo(APP) do |dir|
      idx = ExtractScout::Indexer.new(repo_root: dir).build
      r = ExtractScout::Analyzer.new(idx, 'Billing', target: 'other-language').analyze
      r['entanglement_score'] = ExtractScout::Verdict.score(r['metrics'])
      text = ExtractScout::Render.text(r)
      assert_match(/TARGET/i, text)
      assert_match(/another language|rewrite/i, text)
    end
  end
end
