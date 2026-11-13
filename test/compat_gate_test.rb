# frozen_string_literal: true

require_relative "test_helper"
require "rake"

load File.expand_path("../rakelib/compat.rake", __dir__)

# The `rake compat` gate compares test by test against COMPAT.md, so a
# new failure cannot hide behind a new pass.
class CompatGateTest < Minitest::Test
  REPORT = <<~MD
    **3 of 5 tests pass (60.0%)**

    | File | Pass | Runs | Fail | Error | Skip |
    |---|---:|---:|---:|---:|---:|
    | test/a_test.rb | 2 | 3 | 1 | 0 | 0 |
    | test/b_test.rb | 1 | 2 | 0 | 1 | 0 |
    | test/c_test.rb | — | load error | | | |

    ## Failing tests

    **test/a_test.rb**
    - `ATest#test_old`

    **test/b_test.rb**
    - `BTest#test_err:`
  MD

  def baseline
    compat_baseline(REPORT)
  end

  def test_the_report_is_read_back
    assert_equal({ passed: 2, load_error: false, failed: ["ATest#test_old"] }, baseline["test/a_test.rb"])
    assert_equal ["BTest#test_err"], baseline["test/b_test.rb"][:failed], "the stray colon is dropped"
    assert baseline["test/c_test.rb"][:load_error]
  end

  def test_a_new_failure_behind_a_new_pass_is_a_regression
    results = [
      { file: "test/a_test.rb", passed: 2, failed_tests: ["ATest#test_new"] },
      { file: "test/b_test.rb", passed: 2, failed_tests: [] }
    ]
    assert_equal ["test/a_test.rb: ATest#test_new now fails"], compat_regressions(baseline, results)
  end

  def test_fewer_passes_and_a_file_that_stops_loading_are_regressions
    results = [
      { file: "test/a_test.rb", passed: 1, failed_tests: ["ATest#test_old"] },
      { file: "test/b_test.rb", load_error: true, reason: "NameError", failed_tests: [] },
      { file: "test/c_test.rb", load_error: true, reason: "still", failed_tests: [] },
      { file: "test/new_test.rb", passed: 0, failed_tests: ["NewTest#test_x"] }
    ]
    assert_equal ["test/a_test.rb: 1 pass, COMPAT.md recorded 2", "test/b_test.rb no longer loads: NameError"],
                 compat_regressions(baseline, results)
  end

  def test_the_same_or_better_is_not
    results = [
      { file: "test/a_test.rb", passed: 3, failed_tests: [] },
      { file: "test/b_test.rb", passed: 1, failed_tests: ["BTest#test_err"] }
    ]
    assert_empty compat_regressions(baseline, results)
  end
end
