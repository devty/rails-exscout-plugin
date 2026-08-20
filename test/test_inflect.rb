# frozen_string_literal: true

require_relative 'helper'

# The inflector exists because ActiveSupport isn't available without booting
# Rails. It only has to be right for association names, which is a much smaller
# job than general English -- but every miss becomes a silently dropped edge.
class TestInflect < Minitest::Test
  I = ExtractScout::Inflect

  def test_camelize
    assert_equal 'LineItem', I.camelize('line_item')
    assert_equal 'InvoicesController', I.camelize('invoices_controller')
    assert_equal 'Order', I.camelize('order')
  end

  def test_camelize_tolerates_doubled_underscores
    assert_equal 'LineItem', I.camelize('line__item')
  end

  def test_regular_plurals
    assert_equal 'order',     I.singularize('orders')
    assert_equal 'line_item', I.singularize('line_items')
  end

  def test_ies_plural_needs_a_consonant_before_it
    assert_equal 'entry', I.singularize('entries')
    assert_equal 'policy', I.singularize('policies')
  end

  def test_sibilant_plurals
    assert_equal 'box',   I.singularize('boxes')
    assert_equal 'dish',  I.singularize('dishes')
    assert_equal 'class', I.singularize('classes')
    assert_equal 'batch', I.singularize('batches')
  end

  def test_ves_plural
    assert_equal 'shelf', I.singularize('shelves')
  end

  def test_irregulars_win_over_the_rules
    # 'taxes' would otherwise hit the (ch|sh|ss|x|z)es rule and still land on
    # 'tax', but 'statuses' and 'people' would not survive the general rules.
    assert_equal 'tax',    I.singularize('taxes')
    assert_equal 'status', I.singularize('statuses')
    assert_equal 'person', I.singularize('people')
    assert_equal 'child',  I.singularize('children')
    assert_equal 'datum',  I.singularize('data')
    assert_equal 'index',  I.singularize('indices')
    assert_equal 'alias',  I.singularize('aliases')
  end

  def test_association_constant_respects_plurality
    assert_equal 'LineItem', I.association_constant('line_items', plural: true)
    assert_equal 'Order',    I.association_constant('order', plural: false)
    # has_one :billing_profile must NOT be singularized -- it is already singular
    # and 'billing_profile' -> 'billing_profil' would orphan the edge.
    assert_equal 'BillingProfile', I.association_constant('billing_profile', plural: false)
  end
end
