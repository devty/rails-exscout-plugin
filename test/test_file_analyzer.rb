# frozen_string_literal: true

require_relative 'helper'

# The token walker is where the whole analysis can go quietly wrong: a missed
# edge understates coupling, a phantom edge overstates it, and both look like
# confident output. These tests pin the behaviour Rails code actually produces.
class TestFileAnalyzer < Minitest::Test
  include FixtureRepo

  # ------------------------------------------------------------- definitions

  def test_records_class_and_module_definitions
    a = ExtractScout::FileAnalyzer.new('t.rb', "module Billing\n  class Invoice\n  end\nend\n").analyze
    assert_equal %w[Billing Invoice], a.defines.map { |d| d['const'] }
  end

  def test_records_compact_style_definition_whole
    a = ExtractScout::FileAnalyzer.new('t.rb', "class Billing::Invoice\nend\n").analyze
    assert_equal ['Billing::Invoice'], a.defines.map { |d| d['const'] }
  end

  def test_singleton_class_defines_nothing
    a = ExtractScout::FileAnalyzer.new('t.rb', "class << self\n  def x; end\nend\n").analyze
    assert_empty a.defines
  end

  def test_superclass_is_its_own_edge_kind
    assert_equal [['ApplicationRecord', 'superclass']],
                 kinds_for("class Invoice < ApplicationRecord\nend\n")
  end

  def test_namespaced_superclass_is_read_whole
    assert_equal [['Billing::Base', 'superclass']],
                 kinds_for("class Invoice < Billing::Base\nend\n")
  end

  # ------------------------------------------------------------------ mixins

  def test_all_three_mixin_macros
    assert_equal [['A', 'mixin']], kinds_for("include A\n")
    assert_equal [['B', 'mixin']], kinds_for("extend B\n")
    assert_equal [['C', 'mixin']], kinds_for("prepend C\n")
  end

  # A method call on a receiver is not a mixin. The constant is still a genuine
  # reference -- it just must not feed the shared_mixin seam, which exists to
  # find modules the domain mixes in, not every object it talks to.
  def test_receiver_calls_are_references_not_mixins
    assert_equal [['Foo', 'reference']], kinds_for("x.include Foo\n")
    assert_equal [['Foo', 'reference']], kinds_for("x&.include Foo\n")
    assert_equal [['Helpers', 'reference']], kinds_for("obj.extend Helpers\n")
  end

  def test_include_as_a_hash_key_is_not_a_mixin
    assert_empty kinds_for("scope :with, -> { joins(include: 1) }\n")
  end

  def test_include_as_a_symbol_is_not_a_mixin
    assert_empty kinds_for("a = :include\n")
  end

  # ------------------------------------------------------------ associations

  def test_belongs_to_and_has_one_are_singular
    assert_equal [['Order', 'association']],   kinds_for("belongs_to :order\n")
    assert_equal [['Profile', 'association']], kinds_for("has_one :profile\n")
  end

  def test_has_many_and_habtm_are_singularized
    assert_equal [['LineItem', 'association']], kinds_for("has_many :line_items\n")
    assert_equal [['Tag', 'association']],      kinds_for("has_and_belongs_to_many :tags\n")
  end

  # An explicit class_name is the whole point of the macro -- inferring from the
  # symbol here would point the edge at a constant that does not exist.
  def test_class_name_string_overrides_the_inferred_constant
    assert_equal [['Billing::LineItem', 'association']],
                 kinds_for(%(has_many :line_items, class_name: "Billing::LineItem"\n))
  end

  def test_class_name_constant_overrides_the_inferred_constant
    assert_equal [['Ledger::Entry', 'association']],
                 kinds_for("has_many :entries, class_name: Ledger::Entry\n")
  end

  # The README states this explicitly: one relationship, one edge. Counting the
  # symbol AND the string doubles every explicitly-classed association.
  def test_class_name_association_is_exactly_one_edge
    assert_equal 1, refs_for(%(has_many :items, class_name: "Billing::Item"\n)).size
  end

  def test_other_options_do_not_disturb_inference
    assert_equal [['Order', 'association']],
                 kinds_for("belongs_to :order, optional: true, touch: true\n")
  end

  # Rails associations wrap across lines constantly, and the override is the
  # whole reason the macro was written. Reading only the macro's own line
  # invented a constant that does not exist -- and the orphaned string was then
  # re-detected as a phantom dsl_string edge, so one miss corrupted the count in
  # both directions at once. See docs/postmortem-docuseal-sweep.md (D1).
  def test_class_name_on_a_continuation_line_overrides_the_inferred_constant
    src = "has_many :entries,\n  class_name: \"Ledger::Entry\"\n"
    assert_equal [['Ledger::Entry', 'association']], kinds_for(src)
  end

  def test_multiline_class_name_association_is_exactly_one_edge
    src = "has_many :entries,\n  class_name: \"Ledger::Entry\"\n"
    assert_equal 1, refs_for(src).size
  end

  # The shape that actually appears in the wild: a scope lambda, trailing
  # options, and the override two lines down.
  def test_class_name_survives_a_lambda_and_trailing_options
    src = <<~RUBY
      has_many :account_testing_accounts, -> { testing }, dependent: :destroy,
               class_name: 'AccountLinkedAccount',
               inverse_of: :account
    RUBY
    assert_equal [['AccountLinkedAccount', 'association']], kinds_for(src)
  end

  # A newline inside a brace-delimited option is :on_nl, not :on_ignored_nl, so
  # newline classification alone is not enough -- bracket depth decides.
  def test_class_name_after_a_multiline_hash_option_is_still_found
    src = "has_many :a, opts: {\n  b: 1\n}, class_name: \"Ledger::Entry\"\n"
    assert_equal [['Ledger::Entry', 'association']], kinds_for(src)
  end

  # The scan must stop at the end of the statement. Reading on would attribute
  # the NEXT association's class_name to this one.
  def test_class_name_does_not_leak_from_the_following_statement
    src = "has_many :entries\nhas_many :others, class_name: \"Ledger::Other\"\n"
    assert_equal [['Entry', 'association'], ['Ledger::Other', 'association']],
                 kinds_for(src)
  end

  # `lambda { |e| ... }` opens with :on_lbrace, not the :on_tlambeg of `-> { }`.
  # Both are closed by :on_rbrace, so an opener set that missed one would leave
  # depth unbalanced and run the scan off the end of the statement. Pre-fix this
  # source produced the fabricated constant `SchemaDynamicDocument`.
  def test_class_name_after_a_multiline_lambda_keyword_block
    src = <<~RUBY
      has_many :schema_dynamic_documents, lambda { |e|
        where(uuid: e.schema.pluck('attachment_uuid'))
      }, class_name: 'DynamicDocument', dependent: :destroy
    RUBY
    assert_includes kinds_for(src), ['DynamicDocument', 'association']
    refute_includes consts_for(src), 'SchemaDynamicDocument'
  end

  # Scanning ahead for the override must not swallow real constants in between.
  def test_constants_inside_the_association_lambda_remain_references
    src = "has_one :default_folder, -> { where(name: TemplateFolder::DEFAULT_NAME) },\n" \
          "  class_name: 'TemplateFolder'\n"
    assert_equal [['TemplateFolder', 'association'],
                  ['TemplateFolder::DEFAULT_NAME', 'reference']],
                 kinds_for(src).sort
  end

  # ------------------------------------------------------ through associations
  #
  # `has_many :through` carries TWO real dependencies: on the join model, which
  # this file always names, and on the far-end model, which is decided by the
  # `source:` association on the join and so needs cross-file resolution.
  # Inferring only the far end from the association name fabricated a constant
  # that resolved to nothing, so the join dependency vanished too. The join is
  # the half that is always knowable here -- record it.

  def test_through_records_the_join_model
    src = "has_many :account_linked_accounts\n" \
          "has_many :linked_accounts, through: :account_linked_accounts\n"
    assert_includes consts_on_line(src, 2), 'AccountLinkedAccount'
  end

  # The join's own class_name is in this file, so the join is resolvable even
  # when its name does not inflect to its class.
  def test_through_resolves_the_join_via_its_explicit_class_name
    src = "has_many :account_testing_accounts, class_name: 'AccountLinkedAccount'\n" \
          "has_many :testing_accounts, through: :account_testing_accounts, source: :linked_account\n"
    assert_includes consts_on_line(src, 2), 'AccountLinkedAccount'
    refute_includes consts_for(src), 'AccountTestingAccount'
  end

  # A through: pointing at another through: must follow the chain to the base.
  def test_chained_through_resolves_to_the_base_association
    src = "belongs_to :template\n" \
          "has_many :versions, through: :template\n" \
          "has_many :attachments, through: :versions\n"
    assert_equal 3, consts_for(src).count('Template')
  end

  def test_through_on_a_continuation_line_is_found
    src = "has_many :dynamic_documents\n" \
          "has_many :versions,\n  through: :dynamic_documents,\n  source: :versions\n"
    assert_includes consts_on_line(src, 2), 'DynamicDocument'
  end

  # The name-inferred far end is still worth emitting: when it is right it is
  # the class the caller actually receives, and when it is wrong it resolves to
  # nothing and is dropped downstream. Both edges are real.
  def test_through_also_keeps_the_name_inferred_target
    src = "has_many :dynamic_documents\n" \
          "has_many :dynamic_document_versions, through: :dynamic_documents, source: :versions\n"
    assert_equal %w[DynamicDocument DynamicDocumentVersion], consts_on_line(src, 2).sort
  end

  def test_through_falls_back_to_inflection_when_the_join_is_not_in_this_file
    assert_includes consts_for("has_many :tags, through: :taggings\n"), 'Tagging'
  end

  # Termination guard for the chain-following recursion, not a behaviour
  # assertion -- it passes either way, and fails by hanging the suite.
  def test_self_referential_through_terminates
    assert_includes consts_for("has_many :a, through: :a\n"), 'A'
  end

  # ------------------------------------------------- polymorphic associations
  #
  # A polymorphic belongs_to has no single target class: the target set is
  # whatever declares `as:` against it, and that lives in other files. Inferring
  # a class from the association name produced `Record` and `Emailable` --
  # constants that do not exist -- so the edge resolved to nothing and the
  # hardest association type to extract became invisible. See docs (D2).

  def test_polymorphic_belongs_to_infers_no_constant
    assert_empty consts_for("belongs_to :record, polymorphic: true\n")
  end

  def test_polymorphic_belongs_to_is_recorded_as_an_interface
    a = ExtractScout::FileAnalyzer.new('t.rb', "belongs_to :record, polymorphic: true\n").analyze
    assert_equal [{ 'name' => 'record', 'line' => 1 }], a.polymorphic
  end

  def test_polymorphic_on_a_continuation_line_is_found
    assert_empty consts_for("belongs_to :record,\n  polymorphic: true,\n  optional: true\n")
  end

  # `as:` is the other half of the interface: it says which polymorphic slot
  # this model plugs into, and the association's own target names the owner.
  def test_as_option_records_which_interface_this_model_implements
    a = ExtractScout::FileAnalyzer.new('t.rb', "has_one :search_entry, as: :record\n").analyze
    assert_equal [{ 'interface' => 'record', 'const' => 'SearchEntry', 'line' => 1 }],
                 a.polymorphic_impls
  end

  def test_as_option_still_records_the_ordinary_association_edge
    assert_equal [['SearchEntry', 'association']],
                 kinds_for("has_one :search_entry, as: :record\n")
  end

  def test_non_polymorphic_belongs_to_is_unchanged
    assert_equal [['Order', 'association']], kinds_for("belongs_to :order, optional: true\n")
  end

  # ------------------------------------------------------------ dsl strings
  #
  # Rails does hide constant names in strings, but most capitalised strings are
  # just words. Firing on shape alone made 94% of recorded dsl_string refs
  # unresolvable noise, and left the survivors untrustworthy. Require a
  # syntactic reason. (D5)

  def test_a_bare_capitalised_string_is_not_a_constant_reference
    assert_empty consts_for("attribute :timezone, :string, default: 'UTC'\n")
    assert_empty consts_for("label = 'Checkbox'\n")
    # The constant being assigned to is a real token and still an edge; the
    # string on the right is the part that must not be one.
    refute_includes consts_for("PRODUCT_NAME = 'DocuSeal'\n"), 'DocuSeal'
  end

  # `::` is evidence on its own -- prose almost never carries a scope operator,
  # so a namespaced string needs no surrounding DSL. Single-segment strings do.
  def test_a_namespaced_string_needs_no_surrounding_dsl
    assert_equal [['Billing::Job', 'dsl_string']], kinds_for(%(x = "Billing::Job"\n))
  end

  def test_constantize_makes_a_string_a_reference
    assert_equal [['BillingJob', 'dsl_string']], kinds_for("'BillingJob'.constantize\n")
    assert_equal [['BillingJob', 'dsl_string']], kinds_for("'BillingJob'.safe_constantize\n")
  end

  def test_routing_targets_are_still_read
    assert_equal [['Billing::InvoicesController', 'dsl_string']],
                 kinds_for(%(get '/x', to: 'billing/invoices#show'\n))
  end

  def test_known_const_bearing_labels_are_read
    assert_equal [['BillingJob', 'dsl_string']], kinds_for("perform(job_class: 'BillingJob')\n")
  end

  # A string compared against a *_type column is a polymorphic discriminator,
  # not a generic DSL string. It belongs with the polymorphic seam, which is the
  # problem it is actually part of. (D2, loose end)

  def test_type_discriminator_label_is_a_polymorphic_reference
    assert_equal [['Submission', 'polymorphic_ref']],
                 kinds_for("where(record_type: 'Submission')\n")
  end

  def test_type_discriminator_comparison_is_a_polymorphic_reference
    assert_equal [['Submitter', 'polymorphic_ref']],
                 kinds_for("x.record_type == 'Submitter'\n")
    assert_equal [['Submitter', 'polymorphic_ref']],
                 kinds_for("attachment.record_type != 'Submitter'\n")
  end

  def test_a_comparison_against_an_ordinary_ident_is_not_a_discriminator
    assert_empty consts_for("x.name == 'Submitter'\n")
  end

  # ------------------------------------------------------------- delegation

  def test_delegate_to_a_constant_is_an_edge
    assert_equal [['Billing::Invoice', 'delegation']],
                 kinds_for("delegate :total, to: Billing::Invoice\n")
  end

  def test_delegate_to_a_method_is_not_a_constant_edge
    assert_empty kinds_for("delegate :total, to: :invoice\n")
  end

  # ------------------------------------------------------------ dsl strings

  def test_constant_shaped_strings_are_recorded
    assert_equal [['BillingJob', 'dsl_string']], kinds_for(%(x = "BillingJob".constantize\n))
  end

  def test_namespaced_constant_shaped_strings_are_recorded
    assert_equal [['Billing::Job', 'dsl_string']], kinds_for(%(x = "Billing::Job"\n))
  end

  def test_routing_targets_become_controller_constants
    assert_equal [['Billing::InvoicesController', 'dsl_string']],
                 kinds_for(%(get "/x", to: "billing/invoices#show"\n))
  end

  def test_prose_strings_are_ignored
    assert_empty kinds_for(%(x = "hello world"\n))
    assert_empty kinds_for(%(x = "Ab"\n))
  end

  # ------------------------------------------------------- dedupe and lines

  def test_line_numbers_are_recorded_per_reference
    src = "class Invoice < ApplicationRecord\n  include Auditable\n  belongs_to :order\nend\n"
    assert_equal [['ApplicationRecord', 1], ['Auditable', 2], ['Order', 3]],
                 refs_for(src).map { |r| [r.const, r.line] }
  end

  def test_same_constant_on_different_lines_is_kept_twice
    src = "Order.find(1)\nOrder.find(2)\n"
    assert_equal 2, refs_for(src).size
  end

  def test_refs_are_sorted_by_line
    src = "class A < Zed\n  include Alpha\nend\n"
    lines = refs_for(src).map(&:line)
    assert_equal lines.sort, lines
  end

  # ---------------------------------------------------------------- comments

  def test_commented_out_code_is_not_an_edge
    assert_empty kinds_for("# belongs_to :order\n# include Auditable\n")
  end

  # -------------------------------------------------------------- resilience

  def test_unparseable_source_does_not_raise
    a = ExtractScout::FileAnalyzer.new('t.rb', "class Foo\n  def bar(\n").analyze
    assert_kind_of Array, a.refs
  end

  def test_empty_source_is_inert
    a = ExtractScout::FileAnalyzer.new('t.rb', '').analyze
    assert_empty a.refs
    assert_empty a.defines
  end
end
