# frozen_string_literal: true

require_relative 'helper'

# Path -> constant is the load-bearing assumption of the whole tool: under
# Zeitwerk the path IS the constant, so getting a root wrong silently orphans
# every file beneath it and understates coupling everywhere.
class TestAutoloadRoots < Minitest::Test
  include FixtureRepo

  APP = {
    'app/models/order.rb' => "class Order\nend\n",
    'app/models/billing/invoice.rb' => "module Billing\n  class Invoice\n  end\nend\n",
    'app/models/concerns/auditable.rb' => "module Auditable\nend\n",
    'app/controllers/billing/invoices_controller.rb' => "module Billing\n  class InvoicesController\n  end\nend\n",
    'app/controllers/concerns/authenticable.rb' => "module Authenticable\nend\n",
    'lib/reporting/exporter.rb' => "module Reporting\n  class Exporter\n  end\nend\n",
    'engines/shipping/app/models/shipment.rb' => "class Shipment\nend\n",
    'packs/catalog/app/models/product.rb' => "class Product\nend\n",
    'components/search/app/models/query.rb' => "class Query\nend\n",
    'config/application.rb' => "module App\nend\n"
  }.freeze

  def roots_for(dir) = ExtractScout::AutoloadRoots.new(dir)

  def test_app_subdirectories_are_each_their_own_root
    with_repo(APP) do |dir|
      assert_equal 'Order', roots_for(dir).constant_for(File.join(dir, 'app/models/order.rb'))
    end
  end

  def test_nested_directory_becomes_a_namespace
    with_repo(APP) do |dir|
      assert_equal 'Billing::Invoice',
                   roots_for(dir).constant_for(File.join(dir, 'app/models/billing/invoice.rb'))
    end
  end

  # Rails registers app/*/concerns as a root in its own right. Miss it and
  # auditable.rb claims Concerns::Auditable, a constant nothing references, so
  # every concern in the app silently drops out of the graph.
  def test_concerns_is_a_root_not_a_namespace
    with_repo(APP) do |dir|
      r = roots_for(dir)
      assert_equal 'Auditable', r.constant_for(File.join(dir, 'app/models/concerns/auditable.rb'))
      assert_equal 'Authenticable',
                   r.constant_for(File.join(dir, 'app/controllers/concerns/authenticable.rb'))
    end
  end

  def test_controller_paths_camelize_fully
    with_repo(APP) do |dir|
      assert_equal 'Billing::InvoicesController',
                   roots_for(dir).constant_for(File.join(dir, 'app/controllers/billing/invoices_controller.rb'))
    end
  end

  def test_lib_is_a_root
    with_repo(APP) do |dir|
      assert_equal 'Reporting::Exporter',
                   roots_for(dir).constant_for(File.join(dir, 'lib/reporting/exporter.rb'))
    end
  end

  def test_engines_packs_and_components_are_roots
    with_repo(APP) do |dir|
      r = roots_for(dir)
      assert_equal 'Shipment', r.constant_for(File.join(dir, 'engines/shipping/app/models/shipment.rb'))
      assert_equal 'Product',  r.constant_for(File.join(dir, 'packs/catalog/app/models/product.rb'))
      assert_equal 'Query',    r.constant_for(File.join(dir, 'components/search/app/models/query.rb'))
    end
  end

  def test_files_outside_every_root_have_no_constant
    with_repo(APP) do |dir|
      assert_nil roots_for(dir).constant_for(File.join(dir, 'config/application.rb'))
    end
  end

  # Longest-first ordering is what makes the concerns root beat the models root.
  def test_roots_are_ordered_most_specific_first
    with_repo(APP) do |dir|
      lengths = roots_for(dir).roots.map(&:length)
      assert_equal lengths.sort.reverse, lengths
    end
  end
end
