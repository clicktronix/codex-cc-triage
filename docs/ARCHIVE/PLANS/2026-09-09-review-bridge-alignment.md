# Review bridge alignment

[PR #8](https://github.com/clicktronix/codex-cc-triage/pull/8) brings the Claude bridge's
existing review-integrity fixes in line with the continuous-flow lessons from
cc-codex-triage PR #7. Keep this bridge's Git-only context, capability-based CLI checks
and fingerprinted result protocol; parity does not require duplicating runtime machinery.

- [x] Replace cap/reset shortcuts with budget-aware recovery and continued safe work.
- [x] Allow autonomous owned idle thread maintenance and expose retained archives.
- [x] Validate Python before dispatch can revoke approval or create state.
- [x] Reproduce regressions and run the full offline suite.
- [x] Update the existing release notes. Publish this alignment as one follow-up commit in PR #8.

Local validation: `bash tests/run.sh` passed, including 72 required-review checks,
12 product-route tests and three timeout-runner unit tests. Documentation targets and
`git diff --check` passed. Publication and final-head CI evidence belong in PR #8,
so this file does not claim a hosted result before its own commit exists.

No new ledger, automatic archive deletion, paid model evaluation, research/debate skill
or standalone-context implementation is part of this alignment. Those are separate
capabilities, not required to fix the shared lifecycle defects. Model/effort defaults
and the per-call budget remain unchanged; validation spends no model tokens.
