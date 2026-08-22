# frozen_string_literal: true

require_relative 'helper'

# A concern included by 52 of an app's 60 domains is not coupling. It is ambient
# infrastructure, and reporting it as a seam in every domain's report at once is
# noise everywhere simultaneously -- with advice ("promote it to a shared library
# both sides may depend on") that is unactionable, because it already is one.
#
# On Mastodon this was the whole of the #1 ranked seam: Redisable (52 domains),
# Payloadable (27), RoutingHelper (26). Counting them inflated ActivityPub's
# shared_mixin seam to 98 edges, enough to outrank 26 blockers.
#
# The codebase already applies this principle twice -- "not defined in this repo"
# catches framework code, and DEFAULT_UBIQUITOUS lists base classes. This is the
# third case, measured rather than listed, so it cannot rot the way a list does.
class TestAmbient < Minitest::Test
  include FixtureRepo

  def setup = ExtractScout::Inflect.reset!
  def teardown = ExtractScout::Inflect.reset!

  # 14 domains. Redisable is included by 12 of them; Niche by 2.
  def wide_app
    files = {
      'app/models/concerns/redisable.rb' => "module Redisable\nend\n",
      'app/models/concerns/niche.rb' => "module Niche\nend\n"
    }
    14.times do |i|
      mixins = ["  include Redisable"]
      mixins = [] if i >= 12
      mixins << '  include Niche' if i < 2
      files["app/models/d#{i}/thing.rb"] =
        "module D#{i}\n  class Thing\n#{mixins.join("\n")}\n  end\nend\n"
    end
    files
  end

  def index(files)
    with_repo(files) { |dir| return ExtractScout::Indexer.new(repo_root: dir).build }
  end

  def test_a_widely_included_concern_is_detected_as_ambient
    assert_includes index(wide_app)['ambient'].keys, 'Redisable'
  end

  def test_a_narrowly_shared_concern_is_not_ambient
    refute_includes index(wide_app)['ambient'].keys, 'Niche'
  end

  # The count is what makes it arguable rather than a magic verdict.
  def test_ambient_records_how_many_units_reach_it
    assert_operator index(wide_app)['ambient']['Redisable']['units'], :>=, 10
  end

  def test_ambient_constants_are_filtered_from_the_graph
    idx = index(wide_app)
    assert_includes idx['ubiquitous'], 'Redisable'
    r = ExtractScout::Analyzer.new(idx, 'D0').analyze
    refute_includes r['outbound'].map { |u| u['unit'] }, 'Redisable'
  end

  def test_narrow_sharing_still_shows_as_a_real_edge
    r = ExtractScout::Analyzer.new(index(wide_app), 'D0').analyze
    assert_includes r['outbound'].map { |u| u['unit'] }, 'Niche'
  end

  # Set aside is not the same as ignored. A reader has to be able to see what
  # was removed and disagree with it.
  def test_the_report_names_what_was_set_aside
    r = ExtractScout::Analyzer.new(index(wide_app), 'D0').analyze
    assert_includes r['ambient'].keys, 'Redisable'
  end

  def test_the_text_report_surfaces_it
    idx = index(wide_app)
    r = ExtractScout::Analyzer.new(idx, 'D0').analyze
    r['entanglement_score'] = ExtractScout::Verdict.score(r['metrics'])
    text = ExtractScout::Render.text(r)
    assert_match(/AMBIENT/i, text)
    assert_includes text, 'Redisable'
  end

  # Measurement subsumes the hardcoded list: a base class every model inherits
  # is detected without being named in a constant.
  def test_measurement_finds_base_classes_the_list_would_have_named
    files = { 'app/models/widget_base.rb' => "class WidgetBase\nend\n" }
    14.times { |i| files["app/models/d#{i}/thing.rb"] = "module D#{i}\n  class Thing < WidgetBase\n  end\nend\n" }
    assert_includes index(files)['ambient'].keys, 'WidgetBase'
  end

  # On a small repo a ratio is meaningless -- three of six units is not evidence
  # of anything. Below the floor, only the curated list applies.
  def test_a_small_repo_does_not_manufacture_ambient_constants
    files = { 'app/models/concerns/shared.rb' => "module Shared\nend\n" }
    3.times { |i| files["app/models/d#{i}/thing.rb"] = "module D#{i}\n  class Thing\n    include Shared\n  end\nend\n" }
    assert_empty index(files)['ambient']
  end

  def test_the_curated_list_still_applies_everywhere
    files = { 'app/models/application_record.rb' => "class ApplicationRecord\nend\n",
              'app/models/thing.rb' => "class Thing < ApplicationRecord\nend\n" }
    assert_includes index(files)['ubiquitous'], 'ApplicationRecord'
  end
end

# "Seams are ordered by what blocks what, not by size" is the README's promise.
# Scores had no saturation, so shared_mixin (35 + mixins*2 = 231 on ActivityPub)
# outranked a cycle (100 + edges = 135) -- a moderate seam above 26 blockers.
class TestSeamOrdering < Minitest::Test
  include FixtureRepo

  def test_severity_tiers_order_before_score
    seams = [
      { 'type' => 'shared_mixin', 'severity' => 'moderate', 'score' => 231 },
      { 'type' => 'cycle', 'severity' => 'blocker', 'score' => 135 },
      { 'type' => 'namespace_pair', 'severity' => 'major', 'score' => 200 }
    ]
    ordered = ExtractScout::Analyzer.order_seams(seams)
    assert_equal %w[blocker major moderate], ordered.map { |s| s['severity'] }
  end

  def test_score_still_orders_within_a_tier
    seams = [
      { 'type' => 'cycle', 'severity' => 'blocker', 'score' => 110 },
      { 'type' => 'facade_leak', 'severity' => 'blocker', 'score' => 178 }
    ]
    assert_equal [178, 110], ExtractScout::Analyzer.order_seams(seams).map { |s| s['score'] }
  end

  def test_a_moderate_seam_can_never_outrank_a_blocker_however_large
    seams = [
      { 'type' => 'shared_mixin', 'severity' => 'moderate', 'score' => 99_999 },
      { 'type' => 'cycle', 'severity' => 'blocker', 'score' => 1 }
    ]
    assert_equal 'blocker', ExtractScout::Analyzer.order_seams(seams).first['severity']
  end
end

# Breadth alone is not the discriminator, and getting this wrong is worse than
# not filtering at all. On Mastodon the widest-reach constant is Account at 171
# units -- the god-model, and the single most important coupling fact in the app.
# A breadth-only rule sets it aside as infrastructure and deletes the headline.
#
# Edge kind separates them cleanly, and bimodally: ApplicationRecord 93%
# structural, BaseService/Redisable/RoutingHelper 100%, against Account/Status/
# User/Tag at 0%. Nothing sits in between.
class TestAmbientVsGodModel < Minitest::Test
  include FixtureRepo

  def setup = ExtractScout::Inflect.reset!
  def teardown = ExtractScout::Inflect.reset!

  # 16 units. Everything includes Redisable and inherits BaseService (structural),
  # and everything also references Account (behavioural).
  def app
    files = {
      'app/models/concerns/redisable.rb' => "module Redisable\nend\n",
      'app/services/base_service.rb' => "class BaseService\nend\n",
      'app/models/account.rb' => "class Account\nend\n"
    }
    16.times do |i|
      files["app/models/d#{i}/thing.rb"] = <<~RB
        module D#{i}
          class Thing < BaseService
            include Redisable
            def go
              Account.find(1)
            end
          end
        end
      RB
    end
    files
  end

  def ambient
    with_repo(app) { |dir| return ExtractScout::Indexer.new(repo_root: dir).build['ambient'] }
  end

  def test_a_widely_included_concern_is_ambient
    assert_includes ambient.keys, 'Redisable'
  end

  def test_a_widely_inherited_base_class_is_ambient
    assert_includes ambient.keys, 'BaseService'
  end

  # The whole point. Account has the same reach and must survive.
  def test_a_god_model_with_the_same_reach_is_not_ambient
    refute_includes ambient.keys, 'Account'
  end

  def test_the_god_model_still_shows_as_coupling
    with_repo(app) do |dir|
      idx = ExtractScout::Indexer.new(repo_root: dir).build
      r = ExtractScout::Analyzer.new(idx, 'D0').analyze
      assert_includes r['outbound'].map { |u| u['unit'] }, 'Account'
    end
  end

  # Why it was set aside has to be inspectable, not asserted.
  def test_ambient_records_the_structural_share_that_justified_it
    assert_operator ambient['Redisable']['structural_pct'], :>=, 90
  end
end
