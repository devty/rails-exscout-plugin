# frozen_string_literal: true

require_relative 'helper'

# The token walker is where the whole analysis can go quietly wrong: a missed
# edge understates coupling, a phantom edge overstates it, and both look like
# confident output. These tests pin the behaviour Rails code actually produces.
class TestFileAnalyzer < Minitest::Test
  include FixtureRepo

  # ------------------------------------------------------------- definitions

  def test_records_class_and_module_definitions
    a = ExtractScout::FileAnalyzer.new('t.rb', "module Billing\n  class Invoice\n  end\nend\n").analyze
    assert_equal %w[Billing Invoice], a.defines.map { |d| d['const'] }
  end

  def test_records_compact_style_definition_whole
    a = ExtractScout::FileAnalyzer.new('t.rb', "class Billing::Invoice\nend\n").analyze
    assert_equal ['Billing::Invoice'], a.defines.map { |d| d['const'] }
  end

  def test_singleton_class_defines_nothing
    a = ExtractScout::FileAnalyzer.new('t.rb', "class << self\n  def x; end\nend\n").analyze
    assert_empty a.defines
  end

  def test_superclass_is_its_own_edge_kind
    assert_equal [['ApplicationRecord', 'superclass']],
                 kinds_for("class Invoice < ApplicationRecord\nend\n")
  end

  def test_namespaced_superclass_is_read_whole
    assert_equal [['Billing::Base', 'superclass']],
                 kinds_for("class Invoice < Billing::Base\nend\n")
  end

  # ------------------------------------------------------------------ mixins

  def test_all_three_mixin_macros
    assert_equal [['A', 'mixin']], kinds_for("include A\n")
    assert_equal [['B', 'mixin']], kinds_for("extend B\n")
    assert_equal [['C', 'mixin']], kinds_for("prepend C\n")
  end

  # A method call on a receiver is not a mixin. The constant is still a genuine
  # reference -- it just must not feed the shared_mixin seam, which exists to
  # find modules the domain mixes in, not every object it talks to.
  def test_receiver_calls_are_references_not_mixins
    assert_equal [['Foo', 'reference']], kinds_for("x.include Foo\n")
    assert_equal [['Foo', 'reference']], kinds_for("x&.include Foo\n")
    assert_equal [['Helpers', 'reference']], kinds_for("obj.extend Helpers\n")
  end

  def test_include_as_a_hash_key_is_not_a_mixin
    assert_empty kinds_for("scope :with, -> { joins(include: 1) }\n")
  end

  def test_include_as_a_symbol_is_not_a_mixin
    assert_empty kinds_for("a = :include\n")
  end

  # ------------------------------------------------------------ associations

  def test_belongs_to_and_has_one_are_singular
    assert_equal [['Order', 'association']],   kinds_for("belongs_to :order\n")
    assert_equal [['Profile', 'association']], kinds_for("has_one :profile\n")
  end

  def test_has_many_and_habtm_are_singularized
    assert_equal [['LineItem', 'association']], kinds_for("has_many :line_items\n")
    assert_equal [['Tag', 'association']],      kinds_for("has_and_belongs_to_many :tags\n")
  end

  # An explicit class_name is the whole point of the macro -- inferring from the
  # symbol here would point the edge at a constant that does not exist.
  def test_class_name_string_overrides_the_inferred_constant
    assert_equal [['Billing::LineItem', 'association']],
                 kinds_for(%(has_many :line_items, class_name: "Billing::LineItem"\n))
  end

  def test_class_name_constant_overrides_the_inferred_constant
    assert_equal [['Ledger::Entry', 'association']],
                 kinds_for("has_many :entries, class_name: Ledger::Entry\n")
  end

  # The README states this explicitly: one relationship, one edge. Counting the
  # symbol AND the string doubles every explicitly-classed association.
  def test_class_name_association_is_exactly_one_edge
    assert_equal 1, refs_for(%(has_many :items, class_name: "Billing::Item"\n)).size
  end

  def test_other_options_do_not_disturb_inference
    assert_equal [['Order', 'association']],
                 kinds_for("belongs_to :order, optional: true, touch: true\n")
  end

  # Known limit, asserted so a future change to scan_for_class_name is a
  # deliberate improvement rather than an accident: the override is only found
  # on the macro's own line.
  def test_class_name_on_a_continuation_line_falls_back_to_inference
    src = "has_many :entries,\n  class_name: \"Ledger::Entry\"\n"
    assert_includes consts_for(src), 'Entry'
  end

  # ------------------------------------------------------------- delegation

  def test_delegate_to_a_constant_is_an_edge
    assert_equal [['Billing::Invoice', 'delegation']],
                 kinds_for("delegate :total, to: Billing::Invoice\n")
  end

  def test_delegate_to_a_method_is_not_a_constant_edge
    assert_empty kinds_for("delegate :total, to: :invoice\n")
  end

  # ------------------------------------------------------------ dsl strings

  def test_constant_shaped_strings_are_recorded
    assert_equal [['BillingJob', 'dsl_string']], kinds_for(%(x = "BillingJob".constantize\n))
  end

  def test_namespaced_constant_shaped_strings_are_recorded
    assert_equal [['Billing::Job', 'dsl_string']], kinds_for(%(x = "Billing::Job"\n))
  end

  def test_routing_targets_become_controller_constants
    assert_equal [['Billing::InvoicesController', 'dsl_string']],
                 kinds_for(%(get "/x", to: "billing/invoices#show"\n))
  end

  def test_prose_strings_are_ignored
    assert_empty kinds_for(%(x = "hello world"\n))
    assert_empty kinds_for(%(x = "Ab"\n))
  end

  # ------------------------------------------------------- dedupe and lines

  def test_line_numbers_are_recorded_per_reference
    src = "class Invoice < ApplicationRecord\n  include Auditable\n  belongs_to :order\nend\n"
    assert_equal [['ApplicationRecord', 1], ['Auditable', 2], ['Order', 3]],
                 refs_for(src).map { |r| [r.const, r.line] }
  end

  def test_same_constant_on_different_lines_is_kept_twice
    src = "Order.find(1)\nOrder.find(2)\n"
    assert_equal 2, refs_for(src).size
  end

  def test_refs_are_sorted_by_line
    src = "class A < Zed\n  include Alpha\nend\n"
    lines = refs_for(src).map(&:line)
    assert_equal lines.sort, lines
  end

  # ---------------------------------------------------------------- comments

  def test_commented_out_code_is_not_an_edge
    assert_empty kinds_for("# belongs_to :order\n# include Auditable\n")
  end

  # -------------------------------------------------------------- resilience

  def test_unparseable_source_does_not_raise
    a = ExtractScout::FileAnalyzer.new('t.rb', "class Foo\n  def bar(\n").analyze
    assert_kind_of Array, a.refs
  end

  def test_empty_source_is_inert
    a = ExtractScout::FileAnalyzer.new('t.rb', '').analyze
    assert_empty a.refs
    assert_empty a.defines
  end
end
