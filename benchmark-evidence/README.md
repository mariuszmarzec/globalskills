# Benchmark Evidence — Final Iteration (SHA efea344)

This directory contains the complete benchmark evidence for the final code iteration tracked in globalskills issue #166.

**Source Repository:** `mariuszmarzec/globalskills`
**Source Commit:** `efea3440ca503e66a3f6b13df5b645c4576d1464` (branch `fix/skill-benchmark-iteration-1`)
**Benchmark Date:** 2026-11-25
**OpenCode Version:** v2.4.1
**Model:** freeLLMAPI/free-cloud (OpenCode default)
**Adapter:** opencode

## Skills Benchmarked

### 1. human-readable-code — invoice-refactor
- **Run Directory:** `human-readable-code/20261125T234850124316Z-human-readable-code-both/`
- **Mode:** `--mode both` (with-skill and without-skill)
- **With-skill Result:** FAIL (agent returncode=0, 210.3s, 4/6 checks passed)
- **Without-skill Result:** FAIL (agent returncode=0, 21.6s, 4/6 checks passed)
- **Impact:** `case_fails_with_and_without_skill` (skill_helped=0, skill_harmed=0, delta=0)

**Failed Checks (both modes):**
- `meaningful-calculation-helpers`: Expected exactly one separate subtotal, discount and tax helper with no duplicates. With-skill created `calculate_discount, calculate_subtotal, calculate_tax_and_total`; without-skill created `_calculate_discount, _calculate_subtotal, _calculate_tax_and_total`.
- `entry-point-orchestrates-steps`: Expected `create_invoice` to call the unique subtotal, discount and tax helpers with no calculation loop. Both modes missing expected helper calls or loop-free orchestration.

**Passed Checks (both modes):**
- `valid-python`
- `public-api-preserved`
- `no-unneeded-production-types`
- `existing-behavior-tests`

### 2. testable-design — registration-boundary
- **Run Directory:** `testable-design/20261125T235243898411Z-testable-design-both/`
- **Mode:** `--mode both` (with-skill and without-skill)
- **With-skill Result:** PASS (agent returncode=0, 25.3s, 7/7 checks passed)
- **Without-skill Result:** PASS (agent returncode=0, 27.2s, 7/7 checks passed)
- **Impact:** `case_passes_with_and_without_skill` (skill_helped=0, skill_harmed=0, delta=0)

**All Checks Passed (both modes):**
- `valid-python`
- `explicit-pure-policy-helper`
- `validation-independent-of-effects`
- `entry-point-orchestrates-boundaries`
- `direct-helper-tests`
- `no-mock-heavy-test-setup`
- `registration-tests`

## Artifact Structure

Each run directory contains:
- `report.md` / `report.json` — Complete benchmark report
- `cases/<case-id>/input/` — Snapshots of case fixture, skill, prompt, verifier, and manifest with SHA256 hashes
- `cases/<case-id>/with-skill/` — With-skill mode artifacts (prompt.txt, command.txt, stdout.txt, stderr.txt, verifier.json, git diagnostics)
- `cases/<case-id>/without-skill/` — Without-skill mode artifacts (same structure)

## Verification

- No source, skill, prompt, verifier, test, config, or runtime files were modified.
- The checkout remained clean throughout benchmark execution.
- Both benchmarks ran with `--mode both` as required.
- Heartbeat wrapper was used to avoid the 900-second no-progress watchdog.
- OpenCode v2.4.1 confirmed to not have `--dir` flag; adapter uses `cwd=workspace` correctly.
- No `provider.auth` errors observed.
- Model: freeLLMAPI/free-cloud (OpenCode default, no fallback used).

## Related

- Issue: #153 (benchmark execution)
- Issue: #166 (final iteration tracking)
- PR: #158 (OpenCode adapter --dir fix)
- CI Run: #45721500897 (all three GitHub CI jobs passed on SHA efea344)