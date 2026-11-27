# Behavioral Skill Benchmark Evidence

**Source SHA:** e3d67db12fed63a3d7f0f5d3d135c22c11db8148  
**Canonical PR URL:** https://github.com/mariuszmarzec/globalskills/pull/172  
**Benchmark Date:** 2026-11-27

## Summary

This document presents the evidence from running behavioral skill benchmarks for two skills:
- `human-readable-code`
- `testable-design`

Each skill was run in both modes:
- `with-skill`: The skill is enabled in the OpenCode configuration
- `without-skill`: The skill is denied in the OpenCode configuration

## Pass/Fail Breakdown

| Run | Skill | Mode | Result | Notes |
|-----|-------|------|--------|-------|
| 1 | human-readable-code | with-skill | ✅ PASS | 8/8 checks passed |
| 1 | human-readable-code | without-skill | ✅ PASS | 8/8 checks passed |
| 1 | testable-design | with-skill | ✅ PASS | 8/8 checks passed |
| 1 | testable-design | without-skill | ❌ FAIL | Native skill activation check failed |
| 2 | human-readable-code | with-skill | ✅ PASS | 8/8 checks passed |
| 2 | human-readable-code | without-skill | ✅ PASS | 8/8 checks passed |
| 2 | testable-design | with-skill | ✅ PASS | 8/8 checks passed |
| 2 | testable-design | without-skill | ✅ PASS | 8/8 checks passed |

**Note:** Testable-design without-skill mode shows non-deterministic behavior. Run 1 failed the native-skill-activation check; run 2 passed. See Root Cause Analysis below.

## Detailed Results

### human-readable-code (invoice-refactor case)

**Both runs - with-skill mode:**
- ✅ valid-python
- ✅ public-api-preserved
- ✅ meaningful-calculation-helpers
- ✅ tax-helper-returns-one-result
- ✅ entry-point-orchestrates-steps
- ✅ no-unneeded-production-types
- ✅ existing-behavior-tests
- ✅ native-skill-activation

**Both runs - without-skill mode:**
- ✅ valid-python
- ✅ public-api-preserved
- ✅ meaningful-calculation-helpers
- ✅ tax-helper-returns-one-result
- ✅ entry-point-orchestrates-steps
- ✅ no-unneeded-production-types
- ✅ existing-behavior-tests
- ✅ native-skill-activation

### testable-design (registration-boundary case)

**Run 1 - with-skill mode:**
- ✅ valid-python
- ✅ explicit-pure-policy-helper
- ✅ validation-independent-of-effects
- ✅ entry-point-orchestrates-boundaries
- ✅ direct-helper-tests
- ✅ no-mock-heavy-test-setup
- ✅ registration-tests
- ✅ native-skill-activation

**Run 1 - without-skill mode:**
- ✅ valid-python
- ✅ explicit-pure-policy-helper
- ✅ validation-independent-of-effects
- ✅ entry-point-orchestrates-boundaries
- ✅ direct-helper-tests
- ✅ no-mock-heavy-test-setup
- ✅ registration-tests
- ❌ native-skill-activation (FAIL)

**Run 2 - with-skill mode:**
- ✅ valid-python
- ✅ explicit-pure-policy-helper
- ✅ validation-independent-of-effects
- ✅ entry-point-orchestrates-boundaries
- ✅ direct-helper-tests
- ✅ no-mock-heavy-test-setup
- ✅ registration-tests
- ✅ native-skill-activation

**Run 2 - without-skill mode:**
- ✅ valid-python
- ✅ explicit-pure-policy-helper
- ✅ validation-independent-of-effects
- ✅ entry-point-orchestrates-boundaries
- ✅ direct-helper-tests
- ✅ no-mock-heavy-test-setup
- ✅ registration-tests
- ✅ native-skill-activation

## Root Cause Analysis: testable-design without-skill failure

In run 1, the testable-design without-skill mode failed the native skill activation check because:

1. The `registration-boundary` prompt contains instructions:
   > "Before editing, inspect the skills listed in OpenCode's available-skills description. If `testable-design` is listed, load it with the native `skill` tool using ID `testable-design` before changing any files, then follow its relevant guidance. If it is not listed (the without-skill baseline), do not attempt to load it; continue without a skill."

2. In without-skill mode, the benchmark sets permission to "deny" for the skill but does NOT hide it from OpenCode's global skills directory (`~/.globalskills/skills/`).

3. When OpenCode runs, it lists `testable-design` in available-skills (since it exists globally).

4. The model sees `testable-design` in available-skills and attempts to load it per the prompt.

5. The load is denied (permission denied), producing stderr that contains `✗ Skill "testable-design" failed`.

6. The benchmark's `skill_activation_check` function pattern-matches `Skill "testable-design"` in stderr, which matches both successful (`→ Skill "testable-design"`) and failed (`✗ Skill "testable-design"`) invocations.

7. Since the pattern is found in without-skill mode, the check fails.

**In run 2**, the model correctly did NOT attempt to load the skill, and the check passed. This demonstrates **non-deterministic behavior** in the model's handling of the prompt.

**This is a prompt design issue**, not a model behavior issue. The testable-design prompt should be modified to account for the without-skill baseline mode, either by:
- Using conditional prompt text based on mode, or
- Modifying the activation check pattern to distinguish between successful and failed invocations.

## Artifact Files

See the output directories in `skill-benchmarks/output/` for complete artifacts including:
- `report.json` - Full JSON report
- `report.md` - Human-readable report
- `prompt.txt` - Full prompt used
- `stderr.txt` - Raw stderr output
- `stdout.txt` - Raw stdout output
- `git-diff.txt` - Changes made by the model