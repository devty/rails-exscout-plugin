# frozen_string_literal: true

require_relative 'helper'

# Inflect is hand-rolled with a 15-entry irregular table, because ActiveSupport
# is not available without booting Rails. That is fine until a repo configures
# its own rules -- and then every constant carrying the acronym mis-resolves.
#
# `inflect.acronym 'API'` makes app/models/api_key.rb define APIKey, not ApiKey.
# Getting that wrong is the D1 failure mode exactly: a constant that resolves to
# nothing, dropped silently, understating coupling with no visible symptom.
class TestInflectionsConfig < Minitest::Test
  include FixtureRepo

  def setup = ExtractScout::Inflect.reset!
  def teardown = ExtractScout::Inflect.reset!

  I = ExtractScout::Inflect

  INFLECTIONS = <<~RB
    ActiveSupport::Inflector.inflections(:en) do |inflect|
      inflect.acronym 'API'
      inflect.acronym 'OAuth'
      inflect.irregular 'medium', 'media'
      inflect.uncountable 'equipment', 'fish'
      # inflect.acronym 'NOPE'
    end
  RB

  ZEITWERK = <<~RB
    Rails.autoloaders.each do |autoloader|
      autoloader.inflector.inflect(
        "html_parser" => "HTMLParser",
        "ssl_client" => "SSLClient"
      )
    end
  RB

  # ------------------------------------------------------------- extraction

  def test_reads_acronyms_from_the_initializer
    with_repo('config/initializers/inflections.rb' => INFLECTIONS) do |dir|
      rules = ExtractScout::InflectionRules.load(dir)
      assert_includes rules[:acronyms], 'API'
      assert_includes rules[:acronyms], 'OAuth'
    end
  end

  # A commented-out rule is not a rule. Regex over Ruby source would take it.
  def test_commented_out_rules_are_ignored
    with_repo('config/initializers/inflections.rb' => INFLECTIONS) do |dir|
      refute_includes ExtractScout::InflectionRules.load(dir)[:acronyms], 'NOPE'
    end
  end

  def test_reads_irregular_and_uncountable
    with_repo('config/initializers/inflections.rb' => INFLECTIONS) do |dir|
      rules = ExtractScout::InflectionRules.load(dir)
      assert_equal 'medium', rules[:irregular]['media']
      assert_includes rules[:uncountable], 'equipment'
      assert_includes rules[:uncountable], 'fish'
    end
  end

  def test_reads_zeitwerk_inflector_overrides
    with_repo('config/initializers/zeitwerk.rb' => ZEITWERK) do |dir|
      overrides = ExtractScout::InflectionRules.load(dir)[:overrides]
      assert_equal 'HTMLParser', overrides['html_parser']
      assert_equal 'SSLClient', overrides['ssl_client']
    end
  end

  def test_a_repo_with_no_inflection_config_yields_empty_rules
    with_repo('app/models/thing.rb' => "class Thing\nend\n") do |dir|
      rules = ExtractScout::InflectionRules.load(dir)
      assert_empty rules[:acronyms]
      assert_empty rules[:overrides]
    end
  end

  # ------------------------------------------------------------ application

  def test_acronyms_change_camelization
    I.configure(acronyms: %w[API OAuth])
    assert_equal 'APIKey', I.camelize('api_key')
    assert_equal 'OAuthToken', I.camelize('oauth_token')
    assert_equal 'Invoice', I.camelize('invoice')
  end

  def test_overrides_win_over_everything
    I.configure(acronyms: %w[API], overrides: { 'html_parser' => 'HTMLParser' })
    assert_equal 'HTMLParser', I.camelize('html_parser')
  end

  def test_custom_irregulars_extend_the_builtin_table
    I.configure(irregular: { 'media' => 'medium' })
    assert_equal 'medium', I.singularize('media')
    assert_equal 'person', I.singularize('people') # builtin still works
  end

  def test_uncountables_are_left_alone
    I.configure(uncountable: %w[equipment])
    assert_equal 'equipment', I.singularize('equipment')
  end

  def test_reset_restores_stock_behaviour
    I.configure(acronyms: %w[API])
    I.reset!
    assert_equal 'ApiKey', I.camelize('api_key')
  end

  # ---------------------------------------------------------- end to end

  def test_indexer_resolves_acronym_constants_using_repo_rules
    files = {
      'config/initializers/inflections.rb' => "ActiveSupport::Inflector.inflections do |inflect|\n  inflect.acronym 'API'\nend\n",
      'app/models/api_key.rb' => "class APIKey\nend\n",
      'app/models/account.rb' => "class Account\n  has_many :api_keys\nend\n"
    }
    with_repo(files) do |dir|
      idx = ExtractScout::Indexer.new(repo_root: dir).build
      # Path -> constant must agree with what the file actually declares.
      assert_includes idx['constants'].keys, 'APIKey'
      refute_includes idx['constants'].keys, 'ApiKey'
      # ...and the association must land on it rather than resolving to nothing.
      assert_equal 1.0, ExtractScout.diagnose(idx)['by_kind']['association']['rate']
    end
  end

  # The premise that looks obvious is wrong, and the wrong version is worth
  # recording: without the rules the tool derives ApiKey from the *path* and
  # ApiKey from the *association*, so they agree and the edge resolves. Both are
  # wrong together, which is why an association-rate check does not catch it.
  #
  # What breaks is an explicit reference. The file declares APIKey; the index
  # registered ApiKey; nothing reconciles them, and the edge is dropped.
  ACRONYM_APP = {
    'app/models/api_key.rb' => "class APIKey\nend\n",
    'app/services/rotator.rb' => "class Rotator\n  def call\n    APIKey.find(1)\n  end\nend\n"
  }.freeze

  RULES = "ActiveSupport::Inflector.inflections do |inflect|\n  inflect.acronym 'API'\nend\n"

  def test_without_the_rules_an_explicit_reference_is_dropped
    with_repo(ACRONYM_APP) do |dir|
      idx = ExtractScout::Indexer.new(repo_root: dir).build
      assert_includes idx['constants'].keys, 'ApiKey'
      refute_includes idx['constants'].keys, 'APIKey'
      assert_equal 0.0, ExtractScout.diagnose(idx)['by_kind']['reference']['rate']
    end
  end

  def test_with_the_rules_the_explicit_reference_resolves
    with_repo(ACRONYM_APP.merge('config/initializers/inflections.rb' => RULES)) do |dir|
      idx = ExtractScout::Indexer.new(repo_root: dir).build
      assert_includes idx['constants'].keys, 'APIKey'
      # Not an overall rate: the initializer itself references
      # ActiveSupport::Inflector, which correctly does not resolve. Framework
      # and gem constants are exactly why the floor applies to associations
      # and not to bare references.
      unresolved = ExtractScout.diagnose(idx)['by_kind']['reference']['examples'].map { |e| e['const'] }
      refute_includes unresolved, 'APIKey'
    end
  end

  # Detectable with no references in the repo at all: under Zeitwerk a booting
  # app guarantees the path-derived name is one the file declares, so a mismatch
  # is proof of an inflection rule the tool does not know about.
  def test_a_missing_inflection_rule_is_reported_even_with_no_references
    with_repo('app/models/api_key.rb' => "class APIKey\nend\n") do |dir|
      d = ExtractScout.diagnose(ExtractScout::Indexer.new(repo_root: dir).build)
      mismatch = d['name_mismatches'].first
      assert_equal 'app/models/api_key.rb', mismatch['file']
      assert_equal 'ApiKey', mismatch['path_implies']
      assert_includes mismatch['file_declares'], 'APIKey'
      assert(d['warnings'].any? { |w| w.include?('inflection') })
    end
  end

  def test_no_mismatch_reported_when_the_rules_are_known
    with_repo('app/models/api_key.rb' => "class APIKey\nend\n",
              'config/initializers/inflections.rb' => RULES) do |dir|
      d = ExtractScout.diagnose(ExtractScout::Indexer.new(repo_root: dir).build)
      assert_empty d['name_mismatches']
    end
  end

  def test_namespaced_files_are_not_false_mismatches
    with_repo('app/models/billing/invoice.rb' => "module Billing\n  class Invoice\n  end\nend\n") do |dir|
      d = ExtractScout.diagnose(ExtractScout::Indexer.new(repo_root: dir).build)
      assert_empty d['name_mismatches']
    end
  end
end
