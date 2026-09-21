# Review budget and recovery

A complete candidate review exhausted the shared $1 default after 39 turns. The driver
saved error JSON but lost the first session identity and pinned base, preventing reply.

- [x] Give review a $5 default cap, retaining $1 for ask/plan and explicit overrides.
- [x] Preserve validated session identity and base on a structured budget error; remain incomplete.
- [x] Verify initial and resumed exhaustion, invalid/mismatched identity, mutation guard,
  explicit caps, mode defaults, and successful continuation with the mock CLI.
- [x] Run the full plugin test suite. No paid calls during validation. Release and local installation are authorized separately.

Evidence: `bash tests/run.sh` passed on the final code; the required-review suite
reported 73 PASS, 0 FAIL. `git diff --check` passed. The parser also recovered the
session ID from the actual saved `error_max_budget_usd` response without producing a
verdict. Claude was mocked throughout the test suite; no paid continuation was run.
