# frozen_string_literal: true

require_relative 'helper'

# D1 went undetected for the whole life of the tool. Every unit test passed,
# because a test asserts the parser does what it was written to do and D1 was a
# case the fixtures did not contain.
#
# What D1 *did* leave behind was a signature: a misparse fabricates a constant,
# and a fabricated constant resolves to nothing. That is measurable on any repo
# with no hand-labelled ground truth at all -- which is what makes it the check
# that generalises, and the one that would have caught D1 the day it was written.
class TestDiagnose < Minitest::Test
  include FixtureRepo

  HEALTHY = {
    'app/models/application_record.rb' => "class ApplicationRecord\nend\n",
    'app/models/order.rb' => <<~RB,
      class Order < ApplicationRecord
        has_many :line_items
        belongs_to :customer
      end
    RB
    'app/models/line_item.rb' => "class LineItem < ApplicationRecord\nend\n",
    'app/models/customer.rb' => "class Customer < ApplicationRecord\nend\n"
  }.freeze

  def index(files)
    with_repo(files) { |dir| return ExtractScout::Indexer.new(repo_root: dir).build }
  end

  def test_counts_references_by_kind
    d = ExtractScout.diagnose(index(HEALTHY))
    assert_equal 2, d['by_kind']['association']['total']
    assert_operator d['by_kind']['superclass']['total'], :>=, 3
  end

  def test_associations_that_name_real_models_all_resolve
    d = ExtractScout.diagnose(index(HEALTHY))
    assert_equal 2, d['by_kind']['association']['resolved']
    assert_in_delta 1.0, d['by_kind']['association']['rate'], 0.001
  end

  # Ubiquitous base classes resolve to nil by design, so they must not be
  # counted as parser failures -- otherwise every healthy repo looks broken.
  def test_deliberate_non_resolution_is_not_counted_against_the_rate
    d = ExtractScout.diagnose(index(HEALTHY))
    refute_includes d['by_kind'].keys, 'ubiquitous'
    assert_equal 0, d['by_kind']['superclass']['unresolved']
  end

  # The shape of D1: an association naming a constant that does not exist.
  BROKEN = HEALTHY.merge(
    'app/models/invoice.rb' => <<~RB
      class Invoice < ApplicationRecord
        belongs_to :nonexistent_thing
        belongs_to :other_missing_thing
        belongs_to :third_missing_thing
      end
    RB
  ).freeze

  def test_fabricated_association_targets_drop_the_rate
    d = ExtractScout.diagnose(index(BROKEN))
    assert_equal 3, d['by_kind']['association']['unresolved']
    assert_operator d['by_kind']['association']['rate'], :<, 0.9
  end

  def test_unresolved_examples_are_cited_so_they_can_be_checked
    d = ExtractScout.diagnose(index(BROKEN))
    example = d['by_kind']['association']['examples'].first
    assert_match(%r{\Aapp/models/invoice\.rb:\d+\z}, example['at'])
    assert_match(/Thing\z/, example['const'])
  end

  def test_healthy_repo_passes_the_association_floor
    assert_empty ExtractScout.diagnose(index(HEALTHY))['warnings']
  end

  def test_broken_repo_trips_the_association_floor
    warnings = ExtractScout.diagnose(index(BROKEN))['warnings']
    refute_empty warnings
    assert(warnings.any? { |w| w.include?('association') })
  end

  # A repo with no associations at all must not divide by zero or claim failure.
  def test_a_repo_with_no_associations_is_not_a_failure
    d = ExtractScout.diagnose(index('app/models/thing.rb' => "class Thing\nend\n"))
    assert_empty d['warnings']
  end

  def test_render_reports_rates_and_warnings
    text = ExtractScout::Render.diagnostics(ExtractScout.diagnose(index(BROKEN)))
    assert_includes text, 'association'
    assert_includes text, 'RESOLUTION'
    assert_includes text, 'NonexistentThing'
  end
end
