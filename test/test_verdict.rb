# frozen_string_literal: true

require_relative 'helper'

# Score and severity answer different questions and must not be collapsed.
# These lock in the split; test/verdict_matrix.rb shows the wording in one pass.
class TestVerdict < Minitest::Test
  V = ExtractScout::Verdict

  def metrics(**over)
    {
      'cycle_units' => 0, 'exposed_constants' => 0, 'inbound_units' => 0,
      'boundary_assocs' => 0, 'outbound_units' => 0, 'string_couplings' => 0
    }.merge(over.transform_keys(&:to_s))
  end

  def seams(*severities) = severities.map { |s| { 'severity' => s } }

  # ------------------------------------------------------------------ score

  def test_score_is_bounded
    assert_equal 0.0, V.score(metrics)
    assert_operator V.score(metrics(cycle_units: 99, exposed_constants: 99, inbound_units: 99,
                                    boundary_assocs: 99, outbound_units: 99, string_couplings: 99)),
                    :<=, 10.0
  end

  # Deliberate: magnitude saturates, so cycles alone cannot drive the number.
  # That is exactly why blocking has to be carried separately -- this assertion
  # documents the design rather than a defect.
  def test_score_alone_never_expresses_blocking
    assert_equal V.score(metrics(cycle_units: 3)), V.score(metrics(cycle_units: 10))
    assert_operator V.score(metrics(cycle_units: 10)), :<,
                    V.score(metrics(exposed_constants: 99, inbound_units: 99, boundary_assocs: 99))
  end

  def test_magnitude_thresholds
    assert_equal 'Clean',     V.magnitude(0.0)
    assert_equal 'Clean',     V.magnitude(1.9)
    assert_equal 'Moderate',  V.magnitude(2.0)
    assert_equal 'Hard',      V.magnitude(4.5)
    assert_equal 'Very hard', V.magnitude(7.0)
  end

  # --------------------------------------------------------- max_severity

  def test_max_severity_picks_the_worst_present
    assert_equal 'blocker',  V.max_severity(seams('moderate', 'blocker', 'major'))
    assert_equal 'major',    V.max_severity(seams('moderate', 'major'))
    assert_equal 'moderate', V.max_severity(seams('moderate'))
  end

  def test_max_severity_is_nil_without_seams
    assert_nil V.max_severity([])
    assert_nil V.max_severity(nil)
  end

  def test_unknown_severities_are_ignored_rather_than_ranked
    assert_equal 'major', V.max_severity(seams('major', 'catastrophic'))
  end

  def test_blocked_predicate
    assert V.blocked?(seams('blocker', 'major'))
    refute V.blocked?(seams('major', 'moderate'))
    refute V.blocked?([])
  end

  # --------------------------------------------------------------- verdict

  # The rule the skills state outright: "Do not soften a blocker."
  def test_a_blocker_is_distinguishable_at_every_magnitude
    [0.5, 1.1, 3.2, 6.8, 9.9].each do |score|
      blocked = V.verdict(score, 'blocker')
      refute_equal blocked, V.verdict(score, nil),     "score #{score}: blocker reads as no-seams"
      refute_equal blocked, V.verdict(score, 'major'), "score #{score}: blocker reads as major"
      assert_includes blocked, 'BLOCKED'
    end
  end

  # Blocking qualifies magnitude rather than replacing it: a blocked domain may
  # still be small and cheap, and that is decision-relevant.
  def test_blocking_qualifies_rather_than_replaces_the_magnitude
    assert_includes V.verdict(1.1, 'blocker'), 'Clean'
    assert_includes V.verdict(9.9, 'blocker'), 'Very hard'
  end

  # "Very hard, but BLOCKED" implies a contrast that isn't there.
  def test_connective_matches_the_magnitude
    assert_includes V.verdict(1.1, 'blocker'), 'Clean, but BLOCKED'
    assert_includes V.verdict(9.9, 'blocker'), 'Very hard, and BLOCKED'
  end

  def test_major_has_its_own_reading
    assert_includes V.verdict(6.8, 'major'), 'preparatory work'
    refute_includes V.verdict(6.8, 'major'), 'BLOCKED'
  end

  def test_moderate_has_its_own_reading
    assert_includes V.verdict(1.0, 'moderate'), 'mechanical'
  end

  # No seams is not a clean bill of health -- the constant graph is one surface
  # of several, and the rest were never read.
  def test_no_seams_points_at_the_unexamined_surfaces
    text = V.verdict(0.0, nil)
    assert_includes text, 'further investigation'
    assert_includes text, 'schema'
    assert_includes text, 'transaction'
    refute_includes text, 'extractable as-is'
  end
end
