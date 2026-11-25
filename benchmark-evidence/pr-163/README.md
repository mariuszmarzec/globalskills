# Benchmark Evidence for PR #163 — Fresh Reruns

**These are NEW benchmark executions, not recovery of the original lost runs.** The previous benchmark artifacts referenced in PR #163 description were stored in ephemeral workspaces and are no longer accessible. This report branch contains complete, durable evidence from fresh `--mode both` executions run against the exact PR #163 head commit.

## Source Commit

- **Repository**: mariuszmarzec/globalskills
- **PR**: #163 (skill-improvements-benchmark-findings)
- **Exact SHA**: `1110eac7bb2a716894d63cc2b03e35f88004df7d`
- **Branch**: skill-improvements-benchmark-findings

## Execution Environment

- **OpenCode version**: v2.4.1
- **Adapter**: opencode (non-interactive CLI, `opencode run --auto`)
- **Model**: OpenCode default (FreeLLMAPI via LiteLLM, model alias `freeLLMAPI`)
- **Provider**: LiteLLM (free-cloud chat group)
- **No fallback**: Used the currently configured OpenCode adapter/model without any provider/model fallback

## Benchmark Commands

```bash
# human-readable-code
cd skill-benchmarks && python3 benchmark.py run --skill human-readable-code --mode both

# testable-design
cd skill-benchmarks && python3 benchmark.py run --skill testable-design --mode both
```

## Run Timestamps

### human-readable-code
- **Started**: 2026-11-25T19:46:55.811691+00:00
- **Finished**: 2026-11-25T19:49:09.172875+00:00
- **Run directory**: `20261125T194655810901Z-human-readable-code-both`

### testable-design
- **Started**: 2026-11-25T19:49:14.242040+00:00
- **Finished**: 2026-11-25T19:52:07.323020+00:00
- **Run directory**: `20261125T194914241714Z-testable-design-both`

## Evidence Structure

```
benchmark-evidence/pr-163/
├── README.md                          # This file
├── human-readable-code/
│   ├── report.md                      # Full markdown report
│   ├── report.json                    # Full JSON report
│   └── cases/invoice-refactor/
│       ├── with-skill/                # All with-skill artifacts
│       │   ├── verifier.json
│       │   ├── stdout.txt
│       │   ├── stderr.txt
│       │   ├── command.txt
│       │   ├── prompt.txt
│       │   ├── git-status.txt
│       │   ├── git-log.txt
│       │   ├── git-diff.txt
│       │   └── git-show.txt
│       └── without-skill/             # All without-skill artifacts
│           ├── verifier.json
│           ├── stdout.txt
│           ├── stderr.txt
│           ├── command.txt
│           ├── prompt.txt
│           ├── git-status.txt
│           ├── git-log.txt
│           ├── git-diff.txt
│           └── git-show.txt
└── testable-design/
    ├── report.md                      # Full markdown report
    ├── report.json                    # Full JSON report
    └── cases/registration-boundary/
        ├── with-skill/                # All with-skill artifacts
        │   ├── verifier.json
        │   ├── stdout.txt
        │   ├── stderr.txt
        │   ├── command.txt
        │   ├── prompt.txt
        │   ├── git-status.txt
        │   ├── git-log.txt
        │   ├── git-diff.txt
        │   └── git-show.txt
        └── without-skill/             # All without-skill artifacts
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

## Validation

- **Unit tests**: `python3 -m unittest discover -s skill-benchmarks/tests` — PASSED (16 tests)
- **Benchmark validation**: `python3 -m skill-benchmarks.benchmark validate` — Returns 1 due to 15 known eligible skills without cases (expected, does not block the two explicit benchmark runs)
- **No changes** to skill files, benchmark cases, prompts, verifiers, thresholds, runner, configuration, model/provider, or PR #163 branch

## Summary of Results

### human-readable-code (invoice-refactor)
- **with-skill**: FAIL (0/6 checks passed) — 4 passed, 2 failed
  - Failed: `meaningful-calculation-helpers` (4 helpers created, expected 3 without proliferation), `entry-point-orchestrates-steps` (orchestration not extracted)
  - Passed: `valid-python`, `public-api-preserved`, `no-unneeded-production-types`, `existing-behavior-tests`
- **without-skill**: FAIL (0/6 checks passed) — 4 passed, 2 failed
  - Failed: `meaningful-calculation-helpers` (3 helpers but different naming), `entry-point-orchestrates-steps`
  - Passed: `valid-python`, `public-api-preserved`, `no-unneeded-production-types`, `existing-behavior-tests`
- **Impact**: `case_fails_with_and_without_skill` — Skill did not change outcome; both modes fail on the same two checks

### testable-design (registration-boundary)
- **with-skill**: FAIL (0/7 checks passed) — 6 passed, 1 failed
  - Failed: `direct-helper-tests` (no focused tests for `prepare_registration`)
  - Passed: `valid-python`, `explicit-pure-policy-helper`, `validation-independent-of-effects`, `entry-point-orchestrates-boundaries`, `no-mock-heavy-test-setup`, `registration-tests`
- **without-skill**: FAIL (0/7 checks passed) — 6 passed, 1 failed
  - Failed: `direct-helper-tests` (no focused tests for `prepare_registration`)
  - Passed: `valid-python`, `explicit-pure-policy-helper`, `validation-independent-of-effects`, `entry-point-orchestrates-boundaries`, `no-mock-heavy-test-setup`, `registration-tests`
- **Impact**: `case_fails_with_and_without_skill` — Skill did not change outcome; both modes fail on the same check

## Accessing the Evidence

All files in this branch are accessible via GitHub Contents API:
- Base URL: `https://api.github.com/repos/mariuszmarzec/globalskills/contents/benchmark-evidence/pr-163?ref=benchmark-evidence/pr-163-20261125`
- Raw file example: `https://raw.githubusercontent.com/mariuszmarzec/globalskills/benchmark-evidence/pr-163-20261125/benchmark-evidence/pr-163/human-readable-code/report.md`

## Note on PR #163

This report branch is separate from PR #163. PR #163 contains only the skill guidance changes (two SKILL.md files). This branch contains only the benchmark evidence artifacts. The report-only PR created from this branch should remain OPEN for ChatGPT to fetch and verify every file, then closed without merging so the evidence remains accessible.