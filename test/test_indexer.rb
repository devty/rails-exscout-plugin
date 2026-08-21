# frozen_string_literal: true

require_relative 'helper'

class TestIndexer < Minitest::Test
  include FixtureRepo

  APP = {
    'app/models/order.rb' => "class Order < ApplicationRecord\nend\n",
    'app/models/billing/calculator.rb' => "module Billing\n  class Calculator\n  end\nend\n",
    'app/models/concerns/auditable.rb' => "module Auditable\nend\n",
    'config/application.rb' => "module App\nend\n",
    'spec/models/order_spec.rb' => "describe Order do\nend\n",
    'vendor/gems/thing.rb' => "class Thing\nend\n",
    'node_modules/pkg/x.rb' => "class X\nend\n",
    'db/migrate/001_x.rb' => "class CreateX\nend\n"
  }.freeze

  def index(dir, **opts) = ExtractScout::Indexer.new(repo_root: dir, **opts).build

  # Two models declare the `record` interface; only SearchEntry is actually
  # targeted by an `as: :record` declaration, so WebhookEvent's target set is
  # empty. That asymmetry is the point: the pairing key is the association's
  # own target constant, not the bare interface name.
  POLY = {
    'app/models/search_entry.rb' =>
      "class SearchEntry < ApplicationRecord\n  belongs_to :record, polymorphic: true\nend\n",
    'app/models/submitter.rb' =>
      "class Submitter < ApplicationRecord\n  has_one :search_entry, as: :record\nend\n",
    'app/models/template.rb' =>
      "class Template < ApplicationRecord\n  has_one :search_entry, as: :record\nend\n",
    'app/models/webhook_event.rb' =>
      "class WebhookEvent < ApplicationRecord\n  belongs_to :record, polymorphic: true\nend\n"
  }.freeze

  def poly_refs(idx, rel)
    idx['files'][rel]['refs'].select { |r| r['kind'] == 'polymorphic' }
  end

  def test_polymorphic_edges_resolve_to_the_models_implementing_the_interface
    with_repo(POLY) do |dir|
      consts = poly_refs(index(dir), 'app/models/search_entry.rb').map { |r| r['const'] }
      assert_equal %w[Submitter Template], consts.sort
    end
  end

  def test_polymorphic_edges_are_cited_at_the_declaration_line
    with_repo(POLY) do |dir|
      lines = poly_refs(index(dir), 'app/models/search_entry.rb').map { |r| r['line'] }.uniq
      assert_equal [2], lines
    end
  end

  def test_polymorphic_interface_with_no_implementors_yields_no_edges
    with_repo(POLY) do |dir|
      assert_empty poly_refs(index(dir), 'app/models/webhook_event.rb')
    end
  end

  # Recorded even when unresolvable, so a domain can report an unbounded
  # polymorphic association rather than looking clean.
  def test_polymorphic_declarations_are_recorded_on_the_file
    with_repo(POLY) do |dir|
      assert_equal [{ 'name' => 'record', 'line' => 2 }],
                   index(dir)['files']['app/models/webhook_event.rb']['polymorphic']
    end
  end

  def test_indexes_application_code
    with_repo(APP) do |dir|
      files = index(dir)['files'].keys
      assert_includes files, 'app/models/order.rb'
      assert_includes files, 'app/models/billing/calculator.rb'
    end
  end

  def test_excludes_vendor_node_modules_and_migrations
    with_repo(APP) do |dir|
      files = index(dir)['files'].keys
      refute_includes files, 'vendor/gems/thing.rb'
      refute_includes files, 'node_modules/pkg/x.rb'
      refute_includes files, 'db/migrate/001_x.rb'
    end
  end

  def test_excludes_tests_by_default_and_includes_them_on_request
    with_repo(APP) do |dir|
      refute_includes index(dir)['files'].keys, 'spec/models/order_spec.rb'
      assert_includes index(dir, include_tests: true)['files'].keys, 'spec/models/order_spec.rb'
    end
  end

  def test_extra_excludes_are_honoured
    with_repo(APP) do |dir|
      refute_includes index(dir, extra_excludes: ['app/models/billing'])['files'].keys,
                      'app/models/billing/calculator.rb'
    end
  end

  # The single most important registration rule. `module Billing; class Calculator`
  # declares the bare token 'Calculator', but under Zeitwerk the file owns
  # Billing::Calculator and nothing else. Registering the bare name would let an
  # unrelated top-level `Calculator` elsewhere resolve here and invent an edge.
  def test_bare_nested_constants_do_not_claim_the_top_level_name
    with_repo(APP) do |dir|
      constants = index(dir)['constants']
      assert_includes constants.keys, 'Billing::Calculator'
      refute_includes constants.keys, 'Calculator'
      refute_includes constants.keys, 'Billing'
    end
  end

  def test_namespaces_are_derived_from_the_path_constant
    with_repo(APP) do |dir|
      assert_equal ['app/models/billing/calculator.rb'], index(dir)['namespaces']['Billing']
    end
  end

  def test_concern_owns_its_bare_name
    with_repo(APP) do |dir|
      assert_includes index(dir)['constants'].keys, 'Auditable'
    end
  end

  # Outside every autoload root there is no path constant, so the tokens are all
  # we have -- fall back to what the file declares rather than dropping it.
  def test_files_outside_autoload_roots_fall_back_to_declared_constants
    with_repo(APP) do |dir|
      idx = index(dir)
      assert_includes idx['constants'].keys, 'App'
      refute idx['files']['config/application.rb']['autoloadable']
    end
  end

  def test_autoloadable_flag_is_set_for_app_code
    with_repo(APP) do |dir|
      assert index(dir)['files']['app/models/order.rb']['autoloadable']
    end
  end

  def test_stats_and_schema_are_reported
    with_repo(APP) do |dir|
      idx = index(dir)
      assert_equal 1, idx['schema_version']
      assert_equal idx['files'].size, idx['stats']['files_indexed']
      assert_operator idx['stats']['constants'], :>, 0
    end
  end

  def test_loc_is_counted
    with_repo(APP) do |dir|
      assert_operator index(dir)['files']['app/models/order.rb']['loc'], :>=, 2
    end
  end
end
