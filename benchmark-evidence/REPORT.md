# Behavioral Skill Benchmark Evidence

**Source SHA:** e3d67db12fed63a3d7f0f5d3d135c22c11db8148  
**Canonical PR URL:** https://github.com/mariuszmarzec/globalskills/pull/172  
**Model Used:** `litellm/freeLLMAPI`

## Executive Summary

| Skill | Mode | Result | Native Skill Activation Verified |
|-------|------|--------|----------------------------------|
| human-readable-code | with-skill | ✅ PASS | ✅ PASS |
| human-readable-code | without-skill | ✅ PASS | ✅ PASS |
| testable-design | with-skill | ✅ PASS | ✅ PASS |
| testable-design | without-skill | ✅ PASS | ✅ PASS |

**Overall Result: ALL RUNS PASSED**

---

## Detailed Results

### 1. human-readable-code / invoice-refactor

#### with-skill mode
- **Agent duration:** 47.824s
- **All 8 checks passed:**
  - ✅ valid-python
  - ✅ public-api-preserved
  - ✅ meaningful-calculation-helpers
  - ✅ tax-helper-returns-one-result
  - ✅ entry-point-orchestrates-steps
  - ✅ no-unneeded-production-types
  - ✅ existing-behavior-tests
  - ✅ native-skill-activation

#### without-skill mode
- **Agent duration:** 28.081s
- **All 8 checks passed:**
  - ✅ valid-python
  - ✅ public-api-preserved
  - ✅ meaningful-calculation-helpers
  - ✅ tax-helper-returns-one-result
  - ✅ entry-point-orchestrates-steps
  - ✅ no-unneeded-production-types
  - ✅ existing-behavior-tests
  - ✅ native-skill-activation (verified: no skill invocation)

#### Impact Signal: case_passes_without_skill

### 2. testable-design / registration-boundary

#### with-skill mode
- **Agent duration:** 34.498s
- **All 8 checks passed:**
  - ✅ valid-python
  - ✅ explicit-pure-policy-helper
  - ✅ validation-independent-of-effects
  - ✅ entry-point-orchestrates-boundaries
  - ✅ direct-helper-tests (10+ test methods directly call prepare_registration)
  - ✅ no-mock-heavy-test-setup
  - ✅ registration-tests
  - ✅ native-skill-activation

#### without-skill mode
- **Agent duration:** 50.491s
- **All 8 checks passed:**
  - ✅ valid-python
  - ✅ explicit-pure-policy-helper
  - ✅ validation-independent-of-effects
  - ✅ entry-point-orchestrates-boundaries
  - ✅ direct-helper-tests (9+ test methods directly call prepare_registration)
  - ✅ no-mock-heavy-test-setup
  - ✅ registration-tests
  - ✅ native-skill-activation (verified: no skill invocation)

#### Impact Signal: case_passes_without_skill

---

## Native Skill Activation Verification

The benchmark runner enforces a mandatory native-skill-activation check:

- **with-skill mode:** The OpenCode stderr/tool trace proves the native `skill` tool was invoked with the requested skill ID (either `human-readable-code` or `testable-design`)
- **without-skill mode:** The OpenCode stderr/tool trace proves NO invocation of the native `skill` tool for the requested skill ID

This verification is performed by the `skill_activation_check()` function which:
1. Normalizes ANSI escape codes from stderr
2. Searches for the pattern `Skill '<skill_id>'` in the normalized stderr
3. Passes when the pattern is found in with-skill mode, or absent in without-skill mode

---

## Evidence Directory Structure

```
benchmark-evidence/
├── REPORT.md
├── SOURCE_INFO.txt
├── human-readable-code/
│   ├── report.json
│   ├── report.md
│   └── cases/
│       └── invoice-refactor/
│           ├── with-skill/
│           │   ├── stdout.txt
│           │   ├── stderr.txt
│           │   ├── verifier.json
│           │   ├── prompt.txt
│           │   └── git-*.txt
│           └── without-skill/
│               ├── stdout.txt
│               ├── stderr.txt
│               ├── verifier.json
│               ├── prompt.txt
│               └── git-*.txt
└── testable-design/
    ├── report.json
    ├── report.md
    └── cases/
        └── registration-boundary/
            ├── with-skill/
            │   ├── stdout.txt
            │   ├── stderr.txt
            │   ├── verifier.json
            │   ├── prompt.txt
            │   └── git-*.txt
            └── without-skill/
                ├── stdout.txt
                ├── stderr.txt
                ├── verifier.json
                ├── prompt.txt
                └── git-*.txt
```

---

## Pass/Fail Breakdown

| Metric | Count |
|--------|-------|
| Total runs | 4 |
| Passed runs | 4 |
| Failed runs | 0 |
| Cases compared | 2 |
| Skill helped | 0 |
| Skill harmed | 0 |
| Already passes without skill | 2 |
| Fails with and without skill | 0 |
| Invalid runs (missing activation verification) | 0 |

---

## Conclusion

Both skill benchmarks passed with verified native skill activation:
- `human-readable-code`: **PASS** (both modes)
- `testable-design`: **PASS** (both modes)

The PR HEAD (e3d67db12fed63a3d7f0f5d3d135c22c11db8148) is ready for behavior-based benchmarking verification.