# frozen_string_literal: true

require_relative 'helper'

# A monolith with both shapes that look bidirectional in a naive graph:
#
#   Order       <-> Billing  -- association from both ends. ONE relationship
#                               written twice; the standard Rails idiom.
#   Fulfillment <-> Billing  -- method calls both ways. A real cycle.
#
# Collapsing these is the false positive the README singles out as the one that
# makes engineers stop trusting the report.
FIXTURE = {
  'app/models/application_record.rb' => "class ApplicationRecord\nend\n",
  'app/models/order.rb' => <<~RB,
    class Order < ApplicationRecord
      has_many :invoices, class_name: "Billing::Invoice"
    end
  RB
  'app/models/billing/invoice.rb' => <<~RB,
    module Billing
      class Invoice < ApplicationRecord
        belongs_to :order
      end
    end
  RB
  'app/models/billing/calculator.rb' => <<~RB,
    module Billing
      class Calculator
        def go
          Fulfillment::Picker.new
        end
      end
    end
  RB
  'app/models/fulfillment/picker.rb' => <<~RB
    module Fulfillment
      class Picker
        def go
          Billing::Invoice.find(1)
        end
      end
    end
  RB
}.freeze

# Search::Entry points at an open set via `record`, implemented by Catalog.
# Search::Orphan declares an interface nobody implements -- unbounded, which is
# a worse finding than a bounded one and must not read as clean.
POLY_FIXTURE = {
  'app/models/application_record.rb' => "class ApplicationRecord\nend\n",
  'app/models/search/entry.rb' => <<~RB,
    module Search
      class Entry < ApplicationRecord
        belongs_to :record, polymorphic: true
      end
    end
  RB
  'app/models/search/orphan.rb' => <<~RB,
    module Search
      class Orphan < ApplicationRecord
        belongs_to :owner, polymorphic: true
      end
    end
  RB
  'app/models/catalog/product.rb' => <<~RB,
    module Catalog
      class Product < ApplicationRecord
        has_one :entry, as: :record, class_name: 'Search::Entry'
      end
    end
  RB
  'lib/search/query.rb' => <<~RB
    module Search
      class Query
        def run
          Entry.where(record_type: 'Catalog::Product')
        end
      end
    end
  RB
}.freeze

class TestAnalyzeDomain < Minitest::Test
  include FixtureRepo

  def analyze(dir, domain, **opts)
    idx = ExtractScout::Indexer.new(repo_root: dir).build
    ExtractScout::Analyzer.new(idx, domain, **opts).analyze
  end

  def with_billing
    with_repo(FIXTURE) { |dir| yield analyze(dir, 'Billing') }
  end

  # ------------------------------------------------------- domain resolution

  def test_namespace_resolves_the_domain_to_its_files
    with_billing do |r|
      assert_equal ['app/models/billing/calculator.rb', 'app/models/billing/invoice.rb'], r['files']
    end
  end

  def test_resolution_records_its_evidence
    with_billing do |r|
      assert_includes r['evidence']['app/models/billing/invoice.rb'], 'namespace'
    end
  end

  def test_extra_file_pulls_an_unnamespaced_model_into_the_domain
    with_repo(FIXTURE) do |dir|
      r = analyze(dir, 'Billing', extra_files: ['app/models/order.rb'])
      assert_includes r['files'], 'app/models/order.rb'
      assert_includes r['evidence']['app/models/order.rb'], 'agent:file'
    end
  end

  def test_extra_const_pulls_a_constant_into_the_domain
    with_repo(FIXTURE) do |dir|
      r = analyze(dir, 'Billing', extra_consts: ['Order'])
      assert_includes r['files'], 'app/models/order.rb'
    end
  end

  # ------------------------------------------------------------- polymorphic

  def with_search
    with_repo(POLY_FIXTURE) { |dir| yield analyze(dir, 'Search') }
  end

  def test_polymorphic_crossings_are_counted
    with_search { |r| assert_equal 1, r['metrics']['polymorphic_edges'] }
  end

  def test_polymorphic_crossing_is_a_blocker
    with_search do |r|
      seam = r['seams'].find { |x| x['type'] == 'polymorphic' }
      refute_nil seam
      assert_equal 'blocker', seam['severity']
    end
  end

  # The discriminator has no foreign key, so the pair is not a cycle -- the
  # inverse-pair rule must keep holding for this new edge kind.
  def test_polymorphic_pair_is_not_promoted_to_a_cycle
    with_search { |r| assert_empty r['cycles'] }
  end

  # An interface nobody implements produces no edges. Counting only edges would
  # make the least bounded case the quietest one.
  def test_unbounded_polymorphic_interface_is_reported
    with_search { |r| assert_equal 1, r['metrics']['polymorphic_unbounded'] }
  end

  # Catalog's `has_one :entry` is a genuine association crossing and still
  # counts. The polymorphic edge back must not be counted a second time.
  # The discriminator comparison and the association are one problem. Reporting
  # them in two places -- a blocker seam and a generic string coupling -- made
  # the string half read as unrelated boilerplate. (D2, loose end)
  def test_discriminator_strings_are_counted_with_the_polymorphic_seam
    with_search { |r| assert_equal 1, r['metrics']['polymorphic_string_refs'] }
  end

  def test_discriminator_strings_are_not_counted_as_string_couplings
    with_search { |r| assert_equal 0, r['metrics']['string_couplings'] }
  end

  def test_polymorphic_edges_do_not_inflate_the_association_count
    with_search { |r| assert_equal 1, r['metrics']['boundary_assocs'] }
  end

  def test_polymorphic_seam_cites_the_declaration
    with_search do |r|
      seam = r['seams'].find { |x| x['type'] == 'polymorphic' }
      assert(seam['citations'].any? { |c| c['at'].include?('search/entry.rb') })
    end
  end

  # ------------------------------------------------------- association volume
  #
  # `boundary_assoc` was hardcoded `major`, so it fired at the same severity for
  # a model with three associations and one with forty-three. On a Rails app
  # every model crosses a boundary somewhere, which pinned max_severity at
  # `major` for 31 of 34 domains and made the axis carry no signal. (D3)

  def test_a_few_crossing_associations_are_moderate_not_major
    with_billing do |r|
      seam = r['seams'].find { |x| x['type'] == 'boundary_assoc' }
      refute_nil seam
      assert_equal 'moderate', seam['severity']
    end
  end

  def test_many_crossing_associations_per_file_are_major
    targets = %w[shipment customer coupon refund dispute payout ledger adjustment statement]
    # The targets must exist, or the associations resolve to nothing and never
    # cross -- the same silent drop D1 and D6 were about.
    models = targets.to_h do |t|
      ["app/models/#{t}.rb", "class #{t.capitalize} < ApplicationRecord\nend\n"]
    end
    invoice = "module Billing\n  class Invoice < ApplicationRecord\n" +
              targets.map { |t| "    belongs_to :#{t}\n" }.join +
              "  end\nend\n"

    with_repo(FIXTURE.merge(models).merge('app/models/billing/invoice.rb' => invoice)) do |dir|
      r = analyze(dir, 'Billing')
      assert_operator r['metrics']['boundary_assocs'], :>=, 9
      seam = r['seams'].find { |x| x['type'] == 'boundary_assoc' }
      assert_equal 'major', seam['severity']
    end
  end

  # An association crossing is work, never a precondition. Nothing about
  # volume should ever make it a blocker.
  def test_association_volume_is_never_a_blocker
    with_billing do |r|
      severities = r['seams'].select { |x| x['type'] == 'boundary_assoc' }.map { |x| x['severity'] }
      refute_includes severities, 'blocker'
    end
  end

  # ------------------------------------------------ namespace-level pseudo-cycle

  # Ledger:: has edges both ways, but *through disjoint files*: Ledger::Report
  # reads the domain, and the domain calls Ledger::Secret. Nothing shows the two
  # Ledger files depend on each other, so this is not a cycle at file
  # granularity -- collapsing a namespace into one unit only makes it look like
  # one. This was the sweep's only reported blocker, and it was wrong. (D4)
  PSEUDO_CYCLE = {
    'app/models/application_record.rb' => "class ApplicationRecord\nend\n",
    'app/models/vault/key.rb' => <<~RB,
      module Vault
        class Key < ApplicationRecord
          def rotate
            Ledger::Secret.generate
          end
        end
      end
    RB
    'lib/ledger/report.rb' => <<~RB,
      module Ledger
        class Report
          def run
            Vault::Key.find(1)
          end
        end
      end
    RB
    'lib/ledger/secret.rb' => <<~RB
      module Ledger
        module Secret
          def self.generate = 'x'
        end
      end
    RB
  }.freeze

  def with_vault
    with_repo(PSEUDO_CYCLE) { |dir| yield analyze(dir, 'Vault') }
  end

  def test_bidirectional_namespace_through_disjoint_files_is_not_a_cycle
    with_vault do |r|
      assert_equal 0, r['metrics']['cycle_units']
      assert_empty r['cycles']
    end
  end

  def test_disjoint_namespace_pair_is_reported_but_not_as_a_blocker
    with_vault do |r|
      seam = r['seams'].find { |x| x['type'] == 'namespace_pair' }
      refute_nil seam
      assert_equal 'major', seam['severity']
      assert_includes seam['why'], 'disjoint'
    end
  end

  def test_disjoint_namespace_pair_is_counted_separately
    with_vault { |r| assert_equal 1, r['metrics']['namespace_pair_units'] }
  end

  # --------------------------------------------------- cycles vs inverse pairs

  def test_association_only_bidirectionality_is_not_a_cycle
    with_billing do |r|
      assert_includes r['inverse_association_pairs'], 'Order'
      refute_includes r['cycles'].map { |c| c['unit'] }, 'Order'
    end
  end

  def test_behavioural_bidirectionality_is_a_cycle
    with_billing do |r|
      assert_equal ['Fulfillment'], r['cycles'].map { |c| c['unit'] }
      assert_equal 1, r['metrics']['cycle_units']
    end
  end

  def test_cycle_detail_cites_both_directions
    with_billing do |r|
      cycle = r['cycles'].first
      refute_empty cycle['calls_in']
      refute_empty cycle['called_by']
    end
  end

  # ------------------------------------------------------------------ edges

  def test_inbound_and_outbound_are_counted_separately
    with_billing do |r|
      assert_equal 2, r['metrics']['inbound_edges']
      assert_equal 2, r['metrics']['outbound_edges']
    end
  end

  # ApplicationRecord is defined in the repo, so nothing but the ubiquitous list
  # stops every model in the app from sharing a fat, meaningless edge.
  def test_ubiquitous_base_classes_are_not_edges
    with_billing do |r|
      targets = r['outbound'].map { |u| u['unit'] }
      refute_includes targets, 'ApplicationRecord'
    end
  end

  def test_exposed_constants_measure_facade_leakage
    with_billing do |r|
      assert_equal ['Billing::Invoice'], r['exposed_constants']
    end
  end

  def test_cohesion_is_a_ratio_of_internal_to_total
    with_billing do |r|
      assert_operator r['metrics']['cohesion_ratio'], :>=, 0.0
      assert_operator r['metrics']['cohesion_ratio'], :<=, 1.0
    end
  end

  def test_citations_carry_file_and_line
    with_billing do |r|
      r['inbound'].flat_map { |u| u['citations'] }.each do |c|
        assert_match(%r{\A[\w/.]+\.rb:\d+\z}, c['at'])
      end
    end
  end

  # ------------------------------------------------------------------ seams

  def test_cycle_outranks_volume_in_the_seam_ordering
    with_billing do |r|
      assert_equal 'cycle', r['seams'].first['type']
      assert_equal 'blocker', r['seams'].first['severity']
    end
  end

  def test_seams_are_sorted_by_descending_score
    with_billing do |r|
      scores = r['seams'].map { |s| s['score'] }
      assert_equal scores.sort.reverse, scores
    end
  end

  def test_every_seam_carries_citations_and_a_remedy
    with_billing do |r|
      r['seams'].each do |seam|
        refute_empty seam['break_with']
        refute_nil seam['citations']
      end
    end
  end

  # The honesty clause. Absence of a finding is not evidence of absence, and the
  # report must say which surfaces were never read.
  def test_not_analyzed_is_always_reported
    with_billing do |r|
      assert_equal 4, r['not_analyzed'].size
      assert(r['not_analyzed'].any? { |n| n.include?('foreign key') })
    end
  end

  def test_unresolvable_domain_yields_no_files
    with_repo(FIXTURE) do |dir|
      idx = ExtractScout::Indexer.new(repo_root: dir).build
      assert_empty ExtractScout::Analyzer.new(idx, 'Nonexistent').domain_files
    end
  end
end

# The constant walk mirrors Ruby's own Module.nesting lookup. Without it a bare
# token either misses entirely or binds to a same-named class in another domain.
class TestConstantResolver < Minitest::Test
  include FixtureRepo

  def resolver(dir)
    ExtractScout::ConstantResolver.new(ExtractScout::Indexer.new(repo_root: dir).build)
  end

  def test_bare_constant_prefers_the_enclosing_namespace
    with_repo(FIXTURE.merge(
                'app/models/billing/picker.rb' => "module Billing\n  class Picker\n  end\nend\n"
              )) do |dir|
      const, = resolver(dir).resolve('Picker', 'Billing')
      assert_equal 'Billing::Picker', const
    end
  end

  def test_bare_constant_falls_back_to_top_level
    with_repo(FIXTURE) do |dir|
      const, = resolver(dir).resolve('Order', 'Billing')
      assert_equal 'Order', const
    end
  end

  def test_ubiquitous_constants_never_resolve
    with_repo(FIXTURE) do |dir|
      assert_nil resolver(dir).resolve('ApplicationRecord', 'Billing')
    end
  end

  def test_unknown_constants_resolve_to_nothing
    with_repo(FIXTURE) do |dir|
      assert_nil resolver(dir).resolve('Nope', '')
    end
  end
end
