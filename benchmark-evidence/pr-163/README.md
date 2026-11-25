# Benchmark Evidence for PR #163

**IMPORTANT**: These are **NEW fresh reruns** executed on 2026-11-25. The original benchmark artifacts referenced in PR #163 description were from ephemeral workspaces and are no longer available. These runs were executed specifically for durable evidence delivery.

## Source Information

- **Repository**: mariuszmarzec/globalskills
- **PR**: #163 (skill-improvements-benchmark-findings)
- **Source SHA**: `1110eac7bb2a716894d63cc2b03e35f88004df7d`
- **Base Branch**: master (`6843e36`)
- **Run Date**: 2026-11-25

## Benchmark Configuration

- **OpenCode Version**: 2.4.1
- **Adapter**: opencode (non-interactive CLI)
- **Model**: OpenCode default (free-cloud via LiteLLM, model ID: freeLLMAPI)
- **Timeout**: 600 seconds per run
- **Mode**: `--mode both` (with-skill and without-skill)

## Commands Executed

### human-readable-code
```bash
python3 benchmark.py run --skill human-readable-code --mode both
```
- Started: 2026-11-25T19:28:24.958882+00:00
- Finished: 2026-11-25T19:30:36.748805+00:00
- Total duration: ~132 seconds

### testable-design
```bash
python3 benchmark.py run --skill testable-design --mode both
```
- Started: 2026-11-25T19:30:47.820916+00:00
- Finished: 2026-11-25T19:34:27.624088+00:00
- Total duration: ~220 seconds

## Results Summary

### human-readable-code (invoice-refactor case)

| Mode | Passed | Key Failures |
|------|--------|--------------|
| with-skill | ❌ FAIL | meaningful-calculation-helpers (no private helpers extracted), entry-point-orchestrates-steps |
| without-skill | ❌ FAIL | meaningful-calculation-helpers (_calculate_tax_and_total combines tax+total), entry-point-orchestrates-steps |

**Impact Signal**: `case_fails_with_and_without_skill` — Both runs fail the same two checks. The with-skill run extracted **no helpers at all**, while the without-skill run extracted three helpers but incorrectly combined tax and total into `_calculate_tax_and_total` instead of separate `_calculate_tax`.

### testable-design (registration-boundary case)

| Mode | Passed | Key Failures |
|------|--------|--------------|
| with-skill | ❌ FAIL | direct-helper-tests (no focused tests for prepare_registration) |
| without-skill | ❌ FAIL | direct-helper-tests (no focused tests for prepare_registration) |

**Impact Signal**: `case_fails_with_and_without_skill` — Both runs fail the same check. Both correctly extracted the pure `prepare_registration` helper and orchestrated it from `register_user`, but **neither wrote direct unit tests** for the helper as explicitly requested in the prompt.

## Verification

- Unit tests: `python3 -m unittest discover -s skill-benchmarks/tests` — **16 tests PASS**
- Benchmark validation: `python3 benchmark.py validate` — Returns 1 (expected: 15 skills without benchmark cases, documented in config.json exclusions)

## File Structure

```
benchmark-evidence/pr-163/
├── README.md                          # This file
├── human-readable-code/
│   ├── report.md                      # Full markdown report
│   ├── report.json                    # Full JSON report
│   ├── with-skill/                    # All artifacts from with-skill run
│   │   ├── verifier.json
│   │   ├── stdout.txt
│   │   ├── stderr.txt
│   │   ├── command.txt
│   │   ├── prompt.txt
│   │   ├── git-status.txt
│   │   ├── git-log.txt
│   │   ├── git-diff.txt
│   │   └── git-show.txt
│   └── without-skill/                 # All artifacts from without-skill run
│       ├── verifier.json
│       ├── stdout.txt
│       ├── stderr.txt
│       ├── command.txt
│       ├── prompt.txt
│       ├── git-status.txt
│       ├── git-log.txt
│       ├── git-diff.txt
│       └── git-show.txt
└── testable-design/
    ├── report.md
    ├── report.json
    ├── with-skill/
    │   ├── verifier.json
    │   ├── stdout.txt
│   │   ├── stderr.txt
│   │   ├── command.txt
│   │   ├── prompt.txt
│   │   ├── git-status.txt
│   │   ├── git-log.txt
│   │   ├── git-diff.txt
│   │   └── git-show.txt
    └── without-skill/
        ├── verifier.json
        ├── stdout.txt
        ├── stderr.txt
        ├── command.txt
        ├── prompt.txt
        ├── git-status.txt
        ├── git-log.txt
        ├── git-diff.txt
        └── git-show.txt
```

## Notes

- These benchmarks were run on a clean isolated checkout of the exact PR #163 head commit (1110eac7bb2a716894d63cc2b03e35f88004df7d).
- No skill files, benchmark cases, prompts, verifiers, thresholds, runner, configuration, or model/provider were modified.
- The PR #163 branch was not merged.
- All artifacts are committed to this branch for durable GitHub-accessible evidence.
- This report-only PR will remain OPEN for ChatGPT to fetch and verify. It should be closed without merging to preserve the evidence branch.