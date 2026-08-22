# frozen_string_literal: true

require_relative 'helper'

# Ambience is measured across the whole app, but a report is about one domain.
#
# Mastodon's JsonLdHelper has 46 includes and 35 of them (76%) are inside
# ActivityPub. It is 379 lines of canonicalize / compact / patch_for_forwarding!
# / fetch_resource -- ActivityPub protocol implementation, factored into a
# helper. Being used elsewhere too does not make it ambient to the domain that
# owns it, and anyone extracting ActivityPub takes those 379 lines with them.
#
# By contrast RoutingHelper (30% inside), Payloadable (21%) and Redisable (9%)
# are genuinely spread. The separation is clean, same as the structural split.
class TestAmbientRelative < Minitest::Test
  include FixtureRepo

  def setup = ExtractScout::Inflect.reset!
  def teardown = ExtractScout::Inflect.reset!

  # Mirrors the real shape. A domain contributes many EDGES but only one UNIT,
  # so the two measures pull apart -- which is exactly why ambience read
  # globally and coupling read per-domain can disagree.
  #
  #   Owned : 30 edges, 20 inside Core (67%), reached by 11 units -> reinstated
  #   Spread: 14 edges,  2 inside Core (14%), reached by 13 units -> stays ambient
  def app
    files = {
      'app/models/concerns/owned.rb' => "module Owned\nend\n",
      'app/models/concerns/spread.rb' => "module Spread\nend\n"
    }
    20.times { |i| files["app/models/core/o#{i}.rb"] = "module Core\n  class O#{i}\n    include Owned\n  end\nend\n" }
    10.times { |i| files["app/models/out#{i}.rb"] = "class Out#{i}\n  include Owned\nend\n" }
    2.times  { |i| files["app/models/core/s#{i}.rb"] = "module Core\n  class S#{i}\n    include Spread\n  end\nend\n" }
    12.times { |i| files["app/models/far#{i}.rb"] = "class Far#{i}\n  include Spread\nend\n" }
    files
  end

  def report_for(domain)
    with_repo(app) do |dir|
      idx = ExtractScout::Indexer.new(repo_root: dir).build
      return [idx, ExtractScout::Analyzer.new(idx, domain).analyze]
    end
  end

  def test_both_modules_are_globally_ambient
    idx, = report_for('Core')
    assert_includes idx['ambient'].keys, 'Owned'
    assert_includes idx['ambient'].keys, 'Spread'
  end

  # The point: globally ambient, but this domain's own code.
  def test_a_module_owned_by_the_domain_is_reinstated
    _, r = report_for('Core')
    assert_includes r['ambient_reinstated'].keys, 'Owned'
    refute_includes r['ambient'].keys, 'Owned'
  end

  def test_a_genuinely_spread_module_stays_set_aside
    _, r = report_for('Core')
    assert_includes r['ambient'].keys, 'Spread'
    refute_includes r['ambient_reinstated'].keys, 'Spread'
  end

  # Reinstated means it counts, not just that it is mentioned.
  def test_a_reinstated_module_becomes_real_coupling_again
    _, r = report_for('Core')
    assert_includes r['outbound'].map { |u| u['unit'] }, 'Owned'
    refute_includes r['outbound'].map { |u| u['unit'] }, 'Spread'
  end

  def test_reinstatement_records_the_share_that_justified_it
    _, r = report_for('Core')
    assert_operator r['ambient_reinstated']['Owned']['inside_pct'], :>=, 60
  end

  # Same module, different domain: for a domain that merely uses it, it is still
  # ambient. Ambience is a property of the pair, not of the constant.
  def test_the_same_module_stays_ambient_for_a_domain_that_does_not_own_it
    _, r = report_for('Out0')
    refute_includes r['ambient_reinstated'].keys, 'Owned'
  end

  def test_the_text_report_distinguishes_set_aside_from_reinstated
    idx, r = report_for('Core')
    r['entanglement_score'] = ExtractScout::Verdict.score(r['metrics'])
    text = ExtractScout::Render.text(r)
    assert_match(/AMBIENT/i, text)
    assert_match(/reinstated/i, text)
    assert_includes text, 'Owned'
    refute_nil idx
  end
end
