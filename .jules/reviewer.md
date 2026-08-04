## 2024-08-04 - Test Runner Improvement
**Learning:** Adding test suites to `run_tests.sh` must format output matching `── N passed, M failed ──` for the harness to tally them, and the script needs to propagate the actual test command's exit code so the CI harness knows it failed. The file should be `bash mirzabot/run_tests.sh` to work.
**Action:** Always test running the harness after adding or editing a test script.
