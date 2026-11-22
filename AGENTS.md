# Repository rules

- This plugin knows no other plugin. Outside `docs/ARCHIVE/`, no file names another plugin or uses its identifiers, environment variables or scripts; `tests/structure-regression.sh` enforces this.
- The `review-state.sh` verbs, their exit codes and the `CODEX_CC_REQUIRED_REVIEW APPROVE` marker line are a public contract, listed in the README under "Contract for callers". Other tools depend on them without this repository knowing those tools, so a change to them is a documented breaking change.
