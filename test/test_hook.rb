# frozen_string_literal: true

require_relative 'helper'
require 'json'
require 'open3'

# The PostToolUse hook publishes a silence matrix in the README. A hook that
# cries wolf gets switched off within a day and then protects nothing, so every
# ambiguous case must resolve to silence -- and that is a contract, not a
# preference. These run the real script as a subprocess, the way Claude Code does.
class TestHook < Minitest::Test
  include FixtureRepo

  HOOK = File.join(ROOT, 'hooks', 'scripts', 'check_cross_domain.rb')

  APP = {
    'app/models/billing/invoice.rb' => "module Billing\n  class Invoice\n  end\nend\n",
    'app/models/billing/line_item.rb' => "module Billing\n  class LineItem\n  end\nend\n",
    'app/models/shipping/shipment.rb' => "module Shipping\n  class Shipment\n  end\nend\n",
    'app/models/order.rb' => "class Order\nend\n",
    'app/models/ledger_entry.rb' => "class LedgerEntry\nend\n"
  }.freeze

  # Returns the systemMessage the hook emitted, or nil when it stayed silent.
  def fire(dir, payload, env = {})
    out, = Open3.capture2({ 'CLAUDE_PROJECT_DIR' => dir }.merge(env),
                          RbConfig.ruby, HOOK, stdin_data: payload)
    return nil if out.strip.empty?

    JSON.parse(out)['systemMessage']
  end

  def edit(path, old_string, new_string)
    JSON.generate('tool_name' => 'Edit',
                  'tool_input' => { 'file_path' => path,
                                    'old_string' => old_string, 'new_string' => new_string })
  end

  def write(path, content)
    JSON.generate('tool_name' => 'Write', 'tool_input' => { 'file_path' => path, 'content' => content })
  end

  def with_app(extra = {}, &) = with_repo(APP.merge(extra), &)

  # ------------------------------------------------------------------ warns

  def test_warns_when_an_association_joins_two_namespaced_domains
    with_app do |dir|
      msg = fire(dir, edit('app/models/billing/invoice.rb', 'class Invoice',
                           %(class Invoice\n    belongs_to :shipment, class_name: "Shipping::Shipment")))
      refute_nil msg
      assert_includes msg, 'Billing -> Shipping'
      assert_includes msg, 'belongs_to :shipment'
    end
  end

  def test_warns_on_a_newly_written_file
    with_app do |dir|
      msg = fire(dir, write('app/models/billing/refund.rb',
                            %(module Billing\n  class Refund\n    belongs_to :shipment, class_name: "Shipping::Shipment"\n  end\nend\n)))
      refute_nil msg
      assert_includes msg, 'Billing -> Shipping'
    end
  end

  # Without a boundary map the hook says so, so the reader knows the warning
  # rests on naming convention rather than a resolved boundary.
  def test_namespace_inferred_warning_is_labelled_as_such
    with_app do |dir|
      msg = fire(dir, edit('app/models/billing/invoice.rb', 'x',
                           %(belongs_to :shipment, class_name: "Shipping::Shipment")))
      assert_includes msg, 'inferred from namespaces'
    end
  end

  # ---------------------------------------------------------------- silence

  def test_silent_within_one_domain_via_lexical_scope
    with_app do |dir|
      # A bare :line_item inside Billing resolves to Billing::LineItem, not to
      # some top-level LineItem. Getting this wrong warns on a domain's own
      # internal associations -- the fastest way to get the hook switched off.
      assert_nil fire(dir, edit('app/models/billing/invoice.rb', 'x', 'belongs_to :line_item'))
    end
  end

  def test_silent_when_the_target_belongs_to_no_identified_domain
    with_app do |dir|
      assert_nil fire(dir, edit('app/models/billing/invoice.rb', 'x', 'belongs_to :order'))
    end
  end

  def test_silent_when_the_source_belongs_to_no_identified_domain
    with_app do |dir|
      assert_nil fire(dir, edit('app/models/ledger_entry.rb', 'x',
                                %(belongs_to :shipment, class_name: "Shipping::Shipment")))
    end
  end

  # Re-editing a file for an unrelated reason must not re-warn about an
  # association that was already reviewed and kept.
  def test_silent_when_the_association_was_already_there
    with_app do |dir|
      line = %(belongs_to :shipment, class_name: "Shipping::Shipment")
      assert_nil fire(dir, edit('app/models/billing/invoice.rb', line, "#{line}\n  # note"))
    end
  end

  def test_silent_without_an_association_macro
    with_app do |dir|
      assert_nil fire(dir, edit('app/models/billing/invoice.rb', 'x', 'def total; end'))
    end
  end

  def test_silent_for_non_ruby_files
    with_app do |dir|
      assert_nil fire(dir, edit('app/views/billing/show.erb', 'x', 'belongs_to :shipment'))
    end
  end

  def test_silent_outside_the_application_roots
    with_app do |dir|
      assert_nil fire(dir, edit('config/initializers/x.rb', 'x',
                                %(belongs_to :shipment, class_name: "Shipping::Shipment")))
    end
  end

  def test_silent_on_malformed_input
    with_app do |dir|
      assert_nil fire(dir, 'not json at all')
      assert_nil fire(dir, '')
      assert_nil fire(dir, JSON.generate('tool_name' => 'Edit'))
    end
  end

  def test_silent_for_tools_that_do_not_edit
    with_app do |dir|
      assert_nil fire(dir, JSON.generate('tool_name' => 'Read',
                                         'tool_input' => { 'file_path' => 'app/models/billing/invoice.rb' }))
    end
  end

  def test_env_switch_disables_the_hook_entirely
    with_app do |dir|
      payload = edit('app/models/billing/invoice.rb', 'x',
                     %(belongs_to :shipment, class_name: "Shipping::Shipment"))
      refute_nil fire(dir, payload)
      assert_nil fire(dir, payload, 'EXTRACT_SCOUT_HOOK' => 'off')
    end
  end

  # ------------------------------------------------------- with a boundary map

  # A deliberate decision: these two boundaries are meant to be defended.
  DOMAINS = JSON.generate(
    'domains' => {
      'Billing' => { 'enforce' => true,
                     'files' => ['app/models/ledger_entry.rb'], 'constants' => ['LedgerEntry'] },
      'Fulfillment' => { 'enforce' => true,
                         'files' => ['app/models/order.rb'], 'constants' => ['Order'] }
    },
    'ignore' => ['app/models/legacy/**']
  )

  # What a per-model sweep writes: every model recorded as its own "domain".
  # That is a measurement, not a decision, so nothing in it is enforced.
  SWEEP = JSON.generate(
    'domains' => {
      'Billing' => { 'files' => ['app/models/ledger_entry.rb'], 'constants' => ['LedgerEntry'] },
      'Fulfillment' => { 'files' => ['app/models/order.rb'], 'constants' => ['Order'] }
    },
    'ignore' => ['app/models/legacy/**']
  )

  # The map is what lets the hook see domains no naming convention reveals:
  # LedgerEntry and Order are both top-level constants.
  def test_map_catches_unnamespaced_domains
    with_app('.extract-scout/domains.json' => DOMAINS) do |dir|
      msg = fire(dir, edit('app/models/ledger_entry.rb', 'class LedgerEntry',
                           "class LedgerEntry\n  belongs_to :order"))
      refute_nil msg
      assert_includes msg, 'Billing -> Fulfillment'
    end
  end

  def test_map_backed_warning_drops_the_inference_caveat
    with_app('.extract-scout/domains.json' => DOMAINS) do |dir|
      msg = fire(dir, edit('app/models/ledger_entry.rb', 'x', 'belongs_to :order'))
      refute_includes msg, 'inferred from namespaces'
    end
  end

  def test_ignore_globs_are_honoured
    with_app('.extract-scout/domains.json' => DOMAINS) do |dir|
      assert_nil fire(dir, edit('app/models/legacy/thing.rb', 'x', 'belongs_to :order'))
    end
  end

  def test_a_malformed_map_falls_back_to_namespace_inference
    with_app('.extract-scout/domains.json' => '{ not json') do |dir|
      msg = fire(dir, edit('app/models/billing/invoice.rb', 'x',
                           %(belongs_to :shipment, class_name: "Shipping::Shipment")))
      refute_nil msg
      assert_includes msg, 'inferred from namespaces'
    end
  end
  # --------------------------------------------------- measured vs defended
  #
  # domains.json used to mean two different things at once: "what I measured"
  # and "what I want defended". A 34-model sweep writes 34 single-model domains,
  # which turned every ordinary belongs_to in the app into a boundary warning --
  # the hook's design constraint #1 broken by following the skill correctly.
  # Enforcement is now explicit, and unenforced entries fall back to the
  # conservative namespace inference the hook used before any sweep ran.

  def test_a_sweep_does_not_arm_the_hook
    with_app('.extract-scout/domains.json' => SWEEP) do |dir|
      # Ordinary Rails: LedgerEntry belongs_to :order. Both were "measured",
      # neither was defended, so this is schema, not an architecture violation.
      assert_nil fire(dir, edit('app/models/ledger_entry.rb', 'x', 'belongs_to :order'))
    end
  end

  def test_enforced_boundaries_still_warn
    with_app('.extract-scout/domains.json' => DOMAINS) do |dir|
      msg = fire(dir, edit('app/models/ledger_entry.rb', 'x', 'belongs_to :order'))
      refute_nil msg
      assert_includes msg, 'Billing -> Fulfillment'
    end
  end

  # Defending one side is not a decision about the pair.
  def test_a_half_enforced_pair_stays_silent
    half = JSON.generate(
      'domains' => {
        'Billing' => { 'enforce' => true,
                       'files' => ['app/models/ledger_entry.rb'], 'constants' => ['LedgerEntry'] },
        'Fulfillment' => { 'files' => ['app/models/order.rb'], 'constants' => ['Order'] }
      }
    )
    with_app('.extract-scout/domains.json' => half) do |dir|
      assert_nil fire(dir, edit('app/models/ledger_entry.rb', 'x', 'belongs_to :order'))
    end
  end

  # An unenforced map must not disable the namespace fallback -- that is the
  # near-zero-false-positive case and it worked before any sweep ran.
  def test_unenforced_map_leaves_namespace_inference_intact
    with_app('.extract-scout/domains.json' => SWEEP) do |dir|
      msg = fire(dir, edit('app/models/billing/invoice.rb', 'x',
                           %(belongs_to :shipment, class_name: "Shipping::Shipment")))
      refute_nil msg
      assert_includes msg, 'Billing -> Shipping'
      assert_includes msg, 'inferred from namespaces'
    end
  end

  # ignore is a statement about paths, not about enforcement.
  def test_ignore_globs_survive_an_unenforced_map
    with_app('.extract-scout/domains.json' => SWEEP) do |dir|
      assert_nil fire(dir, edit('app/models/legacy/thing.rb', 'x',
                                %(belongs_to :shipment, class_name: "Shipping::Shipment")))
    end
  end

  def test_explicit_enforce_false_is_honoured
    off = JSON.generate(
      'domains' => {
        'Billing' => { 'enforce' => false,
                       'files' => ['app/models/ledger_entry.rb'], 'constants' => ['LedgerEntry'] },
        'Fulfillment' => { 'enforce' => false,
                           'files' => ['app/models/order.rb'], 'constants' => ['Order'] }
      }
    )
    with_app('.extract-scout/domains.json' => off) do |dir|
      assert_nil fire(dir, edit('app/models/ledger_entry.rb', 'x', 'belongs_to :order'))
    end
  end
end
