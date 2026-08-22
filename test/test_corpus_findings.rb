# frozen_string_literal: true

require_relative 'helper'

# Defects found by running the scout over Mastodon (248 models, 1487 indexed
# files) and hand-checking every unresolved association against the source.
#
# None of these could have come from a synthetic fixture: each is a real Rails
# idiom nobody thought to write a test for. That is the whole argument for the
# corpus -- unit tests assert the analyzer does what it was written to do, and
# every one of these passed the suite while fabricating constants.
class TestCorpusFindings < Minitest::Test
  include FixtureRepo

  def setup = ExtractScout::Inflect.reset!
  def teardown = ExtractScout::Inflect.reset!

  # -- F1: ActiveModel::Serializer reuses the association macro names ---------
  #
  # 105 of Mastodon's 153 unresolved associations were in app/serializers.
  # `has_one :object, serializer: ActivityPub::FollowSerializer` declares a
  # serialized attribute, not an ActiveRecord association -- there is no Object
  # model and there never was. Counting these inflates boundary_assocs and
  # invents edges between domains that share nothing.

  SERIALIZER = <<~RB
    class ActivityPub::AcceptFollowSerializer < ActivityPub::Serializer
      attributes :id, :type, :actor
      has_one :object, serializer: ActivityPub::FollowSerializer
      has_many :items, serializer: ActivityPub::ItemSerializer
    end
  RB

  def test_serializer_macros_are_not_activerecord_associations
    kinds = ExtractScout::FileAnalyzer.new('app/serializers/accept_follow_serializer.rb', SERIALIZER)
                                      .analyze.refs.map(&:kind)
    refute_includes kinds, 'association'
  end

  # The real dependency is the serializer named in the option, and it is still
  # recorded -- dropping the fabricated association loses nothing.
  def test_the_serializer_option_target_is_still_an_edge
    consts = ExtractScout::FileAnalyzer.new('app/serializers/accept_follow_serializer.rb', SERIALIZER)
                                       .analyze.refs.map(&:const)
    assert_includes consts, 'ActivityPub::FollowSerializer'
  end

  # Detected by superclass, not only by directory: not every app puts these in
  # app/serializers, and the hook sees added text with no path context to spare.
  def test_serializer_detected_by_superclass_outside_the_conventional_directory
    src = "class Thing < ActiveModel::Serializer\n  has_one :object\nend\n"
    kinds = ExtractScout::FileAnalyzer.new('app/presenters/thing.rb', src).analyze.refs.map(&:kind)
    refute_includes kinds, 'association'
  end

  def test_a_real_model_in_a_normal_directory_is_untouched
    src = "class Invoice < ApplicationRecord\n  has_one :order\nend\n"
    kinds = ExtractScout::FileAnalyzer.new('app/models/invoice.rb', src).analyze.refs.map(&:kind)
    assert_includes kinds, 'association'
  end

  # -- F2: with_options carries class_name over a whole block ----------------
  #
  # D1's cousin. The override is not on the macro's line, or even on a
  # continuation of it -- it is on an enclosing block, and every association
  # inside inherits it.

  WITH_OPTIONS = <<~RB
    class Report < ApplicationRecord
      with_options class_name: 'Account' do
        belongs_to :target_account
        belongs_to :action_taken_by_account, optional: true
        belongs_to :assigned_account, optional: true
      end
      belongs_to :status
    end
  RB

  def test_with_options_class_name_applies_to_every_association_inside
    refs = ExtractScout::FileAnalyzer.new('app/models/report.rb', WITH_OPTIONS).analyze.refs
    assoc = refs.select { |r| r.kind == 'association' }.map(&:const)
    assert_equal %w[Account Account Account Status], assoc
  end

  def test_associations_outside_the_block_keep_their_own_inference
    refs = ExtractScout::FileAnalyzer.new('app/models/report.rb', WITH_OPTIONS).analyze.refs
    assert_includes refs.select { |r| r.kind == 'association' }.map(&:const), 'Status'
  end

  # An explicit class_name on the macro itself is more specific than the block.
  def test_an_inner_class_name_beats_the_block_default
    src = <<~RB
      class Report < ApplicationRecord
        with_options class_name: 'Account' do
          belongs_to :target_account
          belongs_to :reporter, class_name: 'User'
        end
      end
    RB
    assoc = ExtractScout::FileAnalyzer.new('app/models/report.rb', src)
                                      .analyze.refs.select { |r| r.kind == 'association' }.map(&:const)
    assert_equal %w[Account User], assoc
  end

  def test_a_with_options_without_class_name_changes_nothing
    src = "class R < ApplicationRecord\n  with_options optional: true do\n    belongs_to :account\n  end\nend\n"
    assoc = ExtractScout::FileAnalyzer.new('app/models/r.rb', src)
                                      .analyze.refs.select { |r| r.kind == 'association' }.map(&:const)
    assert_equal %w[Account], assoc
  end

  def test_unparseable_source_with_with_options_does_not_raise
    src = "class R\n  with_options class_name: 'A' do\n    belongs_to :x\n"
    ExtractScout::FileAnalyzer.new('app/models/r.rb', src).analyze
  end

  # -- F3: irregular plurals are suffix rules, not whole-word rules ----------
  #
  # has_many :preview_cards_statuses inferred PreviewCardsStatuse. ActiveSupport
  # applies irregular rules as suffix patterns; our table was exact-match only.

  def test_irregular_plurals_apply_as_suffixes
    assert_equal 'preview_cards_status', ExtractScout::Inflect.singularize('preview_cards_statuses')
    assert_equal 'staff_person', ExtractScout::Inflect.singularize('staff_people')
  end

  def test_whole_word_irregulars_still_work
    assert_equal 'status', ExtractScout::Inflect.singularize('statuses')
  end

  def test_repo_irregulars_apply_as_suffixes_too
    ExtractScout::Inflect.configure(irregular: { 'media' => 'medium' })
    assert_equal 'social_medium', ExtractScout::Inflect.singularize('social_media')
  end

  # A word merely ending in the same letters is not the irregular plural --
  # the underscore boundary is what makes the suffix rule safe.
  def test_suffix_matching_respects_the_word_boundary
    refute_equal 'gratu', ExtractScout::Inflect.singularize('gratuses')
    assert_equal 'bonuse', ExtractScout::Inflect.singularize('bonuses')
  end
end

# -- F5: lib/ is not an autoload root unless the app says so ----------------
#
# Rails 7+ does not autoload lib/ by default; you opt in with
# `config.autoload_lib`. Mastodon has that line commented out, so its lib/ holds
# gem monkey-patches -- lib/paperclip/url_generator_extensions.rb reopens
# Paperclip, it does not define Paperclip::URLGeneratorExtensions.
#
# Treating lib/ as a root regardless invented 9 constants nothing references and
# reported all 9 as missing inflection rules, which they were not.
class TestLibAutoload < Minitest::Test
  include FixtureRepo

  def setup = ExtractScout::Inflect.reset!
  def teardown = ExtractScout::Inflect.reset!

  MONKEY_PATCH = {
    'lib/paperclip/url_generator_extensions.rb' => "module Paperclip\n  module UrlGeneratorExtensions\n  end\nend\n",
    'app/models/thing.rb' => "class Thing\nend\n"
  }.freeze

  COMMENTED = "module App\n  class Application < Rails::Application\n" \
              "    # config.autoload_lib(ignore: %w(assets tasks))\n  end\nend\n"

  OPTED_IN = "module App\n  class Application < Rails::Application\n" \
             "    config.autoload_lib(ignore: %w(assets tasks))\n  end\nend\n"

  def roots(files)
    with_repo(files) { |dir| return ExtractScout::AutoloadRoots.new(dir).roots.map { |r| r.sub("#{dir}/", '') } }
  end

  def test_lib_is_not_a_root_by_default
    refute_includes roots(MONKEY_PATCH), 'lib'
  end

  # A commented-out opt-in is not an opt-in.
  def test_a_commented_out_autoload_lib_does_not_count
    refute_includes roots(MONKEY_PATCH.merge('config/application.rb' => COMMENTED)), 'lib'
  end

  def test_lib_is_a_root_when_the_app_opts_in
    assert_includes roots(MONKEY_PATCH.merge('config/application.rb' => OPTED_IN)), 'lib'
  end

  def test_autoload_paths_referencing_lib_also_opts_in
    cfg = "module App\n  class Application < Rails::Application\n" \
          "    config.autoload_paths << Rails.root.join('lib')\n  end\nend\n"
    assert_includes roots(MONKEY_PATCH.merge('config/application.rb' => cfg)), 'lib'
  end

  # Without lib as a root the monkey-patch file has no path constant, so it
  # falls back to what it declares -- which is right -- and stops being reported
  # as a missing inflection rule.
  def test_monkey_patches_stop_looking_like_missing_inflection_rules
    with_repo(MONKEY_PATCH.merge('config/application.rb' => COMMENTED)) do |dir|
      idx = ExtractScout::Indexer.new(repo_root: dir).build
      assert_empty ExtractScout.diagnose(idx)['name_mismatches']
      refute idx['files']['lib/paperclip/url_generator_extensions.rb']['autoloadable']
    end
  end
end

# -- F6: engine monorepos put app/ under a gem directory --------------------
#
# Solidus is one repo of seven gems: core/, api/, admin/, backend/ ... each with
# its own app/ and a .gemspec marking it as a gem. The autoload globs covered
# engines/*, packs/* and components/* by name, so Solidus resolved to ZERO
# autoload roots -- 1204 files indexed, nothing given a constant, every rate in
# the diagnostics collapsing together.
#
# A .gemspec is the principled marker: it says "this directory is a gem", and a
# Rails engine's app/ subdirectories are autoload roots.
class TestEngineMonorepo < Minitest::Test
  include FixtureRepo

  def setup = ExtractScout::Inflect.reset!
  def teardown = ExtractScout::Inflect.reset!

  MONOREPO = {
    'core/solidus_core.gemspec' => "Gem::Specification.new\n",
    'core/app/models/spree/order.rb' => "module Spree\n  class Order\n    belongs_to :user\n  end\nend\n",
    'core/app/models/spree/user.rb' => "module Spree\n  class User\n  end\nend\n",
    'core/app/models/concerns/spree/ordered.rb' => "module Spree\n  module Ordered\n  end\nend\n",
    'api/solidus_api.gemspec' => "Gem::Specification.new\n",
    'api/app/controllers/spree/api/orders_controller.rb' => "module Spree\n  module Api\n    class OrdersController\n    end\n  end\nend\n",
    'app/models/thing.rb' => "class Thing\nend\n"
  }.freeze

  def roots(dir) = ExtractScout::AutoloadRoots.new(dir).roots.map { |r| r.sub("#{dir}/", '') }

  def test_a_gemspec_marks_its_app_subdirectories_as_roots
    with_repo(MONOREPO) do |dir|
      assert_includes roots(dir), 'core/app/models'
      assert_includes roots(dir), 'api/app/controllers'
    end
  end

  def test_the_main_app_is_still_a_root
    with_repo(MONOREPO) { |dir| assert_includes roots(dir), 'app/models' }
  end

  def test_concerns_inside_a_gem_are_their_own_root
    with_repo(MONOREPO) { |dir| assert_includes roots(dir), 'core/app/models/concerns' }
  end

  def test_constants_resolve_across_the_monorepo
    with_repo(MONOREPO) do |dir|
      idx = ExtractScout::Indexer.new(repo_root: dir).build
      assert_equal 'Spree::Order', idx['files']['core/app/models/spree/order.rb']['primary_const']
      assert_equal 'Spree::Api::OrdersController',
                   idx['files']['api/app/controllers/spree/api/orders_controller.rb']['primary_const']
      # ...and an association across the gem boundary lands on a real constant.
      assert_equal 1.0, ExtractScout.diagnose(idx)['by_kind']['association']['rate']
    end
  end

  # A dummy app under spec/ is a test harness, not a gem to index.
  def test_a_dummy_app_under_spec_is_not_a_root
    files = MONOREPO.merge('core/spec/dummy/app/models/fake.rb' => "class Fake\nend\n")
    with_repo(files) do |dir|
      refute(roots(dir).any? { |r| r.include?('dummy') })
    end
  end
end

# -- F7/F8: inflections and constant assignments ---------------------------
class TestMoreCorpusFindings < Minitest::Test
  include FixtureRepo

  def setup = ExtractScout::Inflect.reset!
  def teardown = ExtractScout::Inflect.reset!

  # Solidus declares `inflect.acronym "RMA"` in core/config/initializers/ -- a
  # GEM's initializers, not the repo root's -- and `inflect.acronym "UI"` inside
  # admin/lib/solidus_admin/engine.rb. Looking only at <root>/config/initializers
  # missed both, and RMARequired was reported as a mismatch we could not explain.
  def test_inflections_in_a_nested_gem_initializer_are_read
    files = { 'core/config/initializers/inflections.rb' =>
                "ActiveSupport::Inflector.inflections do |inflect|\n  inflect.acronym \"RMA\"\nend\n" }
    with_repo(files) do |dir|
      assert_includes ExtractScout::InflectionRules.load(dir)[:acronyms], 'RMA'
    end
  end

  def test_inflections_declared_inside_an_engine_are_read
    files = { 'admin/lib/solidus_admin/engine.rb' =>
                "module SolidusAdmin\n  class Engine < Rails::Engine\n" \
                "    ActiveSupport::Inflector.inflections { |inflect| inflect.acronym \"UI\" }\n  end\nend\n" }
    with_repo(files) do |dir|
      assert_includes ExtractScout::InflectionRules.load(dir)[:acronyms], 'UI'
    end
  end

  def test_an_initializer_without_inflections_is_not_scanned_for_rules
    files = { 'config/initializers/session_store.rb' => "Rails.application.config.session_store :cookie_store\n" }
    with_repo(files) { |dir| assert_empty ExtractScout::InflectionRules.load(dir)[:acronyms] }
  end

  # `EligibilityResult = Struct.new(...)` defines a constant. Recording only
  # class/module keywords made the file look like it declared just its enclosing
  # module, which the mismatch tripwire then reported as a missing inflection
  # rule it was not.
  def test_constant_assignment_is_a_definition
    src = "module SolidusPromotions\n  EligibilityResult = Struct.new(:item, keyword_init: true)\nend\n"
    defines = ExtractScout::FileAnalyzer.new('app/models/x.rb', src).analyze.defines.map { |d| d['const'] }
    assert_includes defines, 'EligibilityResult'
  end

  def test_a_struct_definition_does_not_also_read_as_a_reference_to_itself
    src = "module M\n  Thing = Struct.new(:a)\nend\n"
    refs = ExtractScout::FileAnalyzer.new('app/models/x.rb', src).analyze.refs
    refute_includes refs.map(&:const), 'Thing'
    assert_includes refs.map(&:const), 'Struct'
  end

  def test_comparison_is_not_an_assignment
    src = "class X\n  def y?\n    Status == other\n  end\nend\n"
    defines = ExtractScout::FileAnalyzer.new('app/models/x.rb', src).analyze.defines.map { |d| d['const'] }
    refute_includes defines, 'Status'
  end

  def test_a_struct_constant_stops_looking_like_a_missing_inflection_rule
    files = { 'app/models/solidus_promotions/eligibility_result.rb' =>
                "module SolidusPromotions\n  EligibilityResult = Struct.new(:item)\nend\n" }
    with_repo(files) do |dir|
      idx = ExtractScout::Indexer.new(repo_root: dir).build
      assert_empty ExtractScout.diagnose(idx)['name_mismatches']
    end
  end
end

# -- F9: root-scoped definitions -------------------------------------------
#
# `class ::Spree::PromotionCode::BatchBuilder` is how you reopen a class from
# inside a namespace without Ruby resolving the name relatively. handle_definition
# looked for a constant token immediately after the keyword and found the `::`
# operator, so the class was not recorded at all -- and once constant assignments
# became definitions, the file appeared to declare only its DEFAULT_OPTIONS.
class TestRootScopedDefinitions < Minitest::Test
  include FixtureRepo

  def setup = ExtractScout::Inflect.reset!
  def teardown = ExtractScout::Inflect.reset!

  SRC = "class ::Spree::PromotionCode::BatchBuilder\n  DEFAULT_OPTIONS = { a: 1 }\nend\n"

  def test_a_root_scoped_class_is_a_definition
    defines = ExtractScout::FileAnalyzer.new('app/models/x.rb', SRC).analyze.defines.map { |d| d['const'] }
    assert_includes defines, 'Spree::PromotionCode::BatchBuilder'
  end

  def test_the_leading_colons_are_not_kept_in_the_name
    defines = ExtractScout::FileAnalyzer.new('app/models/x.rb', SRC).analyze.defines.map { |d| d['const'] }
    refute(defines.any? { |d| d.start_with?('::') })
  end

  def test_a_root_scoped_module_is_a_definition
    src = "module ::Spree::Config\nend\n"
    defines = ExtractScout::FileAnalyzer.new('app/models/x.rb', src).analyze.defines.map { |d| d['const'] }
    assert_includes defines, 'Spree::Config'
  end

  def test_a_root_scoped_superclass_is_still_an_edge
    src = "class Foo < ::Spree::Base\nend\n"
    refs = ExtractScout::FileAnalyzer.new('app/models/foo.rb', src).analyze.refs
    sup = refs.find { |r| r.kind == 'superclass' }
    refute_nil sup
    assert_equal 'Spree::Base', sup.const
  end

  def test_the_file_no_longer_reads_as_a_name_mismatch
    with_repo('app/models/spree/promotion_code/batch_builder.rb' => SRC) do |dir|
      idx = ExtractScout::Indexer.new(repo_root: dir).build
      assert_empty ExtractScout.diagnose(idx)['name_mismatches']
    end
  end
end
