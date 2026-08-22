# frozen_string_literal: true

require_relative 'helper'

# A Packwerk app has already declared its boundaries, with more information than
# any naming convention can recover. Competing with that declaration would be
# strictly worse than reading it: package.yml is the team's own answer to the
# question this tool exists to guess at.
class TestPackwerk < Minitest::Test
  include FixtureRepo

  APP = {
    'packs/billing/package.yml' => "enforce_dependencies: true\ndependencies:\n  - packs/platform\n",
    'packs/billing/app/models/invoice.rb' => "class Invoice\n  belongs_to :shipment\nend\n",
    'packs/shipping/package.yml' => "enforce_dependencies: true\n",
    'packs/shipping/app/models/shipment.rb' => "class Shipment\nend\n",
    'app/models/legacy_thing.rb' => "class LegacyThing\nend\n"
  }.freeze

  def index(files = APP)
    with_repo(files) { |dir| return ExtractScout::Indexer.new(repo_root: dir).build }
  end

  def test_packs_are_recorded_in_the_index
    packs = index['packs']
    assert_equal 'packs/billing', packs['Billing']
    assert_equal 'packs/shipping', packs['Shipping']
  end

  # An app with no package.yml anywhere must not grow an empty packs concept.
  def test_a_non_packwerk_app_records_no_packs
    assert_empty index('app/models/thing.rb' => "class Thing\nend\n")['packs']
  end

  def test_packs_become_the_candidate_domains
    assert_equal %w[Billing Shipping], ExtractScout.candidate_domains(index)
  end

  # Without packs the fallback is unchanged.
  def test_namespaces_still_win_when_there_are_no_packs
    flat = {
      'app/models/billing/invoice.rb' => "module Billing\n  class Invoice\n  end\nend\n"
    }
    assert_equal ['Billing'], ExtractScout.candidate_domains(index(flat))
  end

  def test_a_pack_resolves_to_exactly_its_own_files
    r = ExtractScout::Analyzer.new(index, 'Billing').analyze
    assert_equal ['packs/billing/app/models/invoice.rb'], r['files']
  end

  # Pack membership is stronger evidence than a path-segment name match, and the
  # report should say which it was -- the boundary-resolver dispatch keys on it.
  def test_pack_membership_is_recorded_as_evidence
    r = ExtractScout::Analyzer.new(index, 'Billing').analyze
    assert_includes r['evidence']['packs/billing/app/models/invoice.rb'], 'pack'
  end

  def test_files_outside_every_pack_are_not_claimed_by_one
    r = ExtractScout::Analyzer.new(index, 'Billing').analyze
    refute_includes r['files'], 'app/models/legacy_thing.rb'
  end
end
