# Behavioral Skill Benchmark Evidence Report

**Source Repository:** mariuszmarzec/globalskills
**PR Under Test:** #172 - Make human-readable extraction boundaries explicit (iteration 2)
**Canonical PR URL:** https://github.com/mariuszmarzec/globalskills/pull/172
**Source SHA:** e3d67db12fed63a3d7f0f5d3d135c22c11db8148
**Benchmark Run Date:** 2026-11-27T13:10:15Z – 2026-11-27T13:12:46Z

---

## Executive Summary

| Skill | Case | With-Skill | Without-Skill | Native Activation Verified |
|-------|------|------------|---------------|---------------------------|
| human-readable-code | invoice-refactor | ✅ PASS | ✅ PASS | ✅ YES (both modes) |
| testable-design | registration-boundary | ✅ PASS | ✅ PASS | ✅ YES (both modes) |

**Overall Result:** ALL 4 RUNS PASSED — Native skill activation verified in all modes.

---

## human-readable-code / invoice-refactor

### With-Skill Run
- **Run ID:** 20261127T131015998356Z-invoice-refactor-both
- **Mode:** with-skill
- **Adapter:** opencode
- **Model:** OpenCode default (litellm/freeLLMAPI)
- **Duration:** 29.15s
- **Agent Return Code:** 0
- **Overall Passed:** ✅ YES

#### Individual Checks (8/8 passed)

| Check | Passed | Expected | Actual | Evidence |
|-------|--------|----------|--------|----------|
| valid-python | ✅ | invoice.py parses | valid | ast.parse(invoice.py) |
| public-api-preserved | ✅ | create_invoice(items, discount_code=None, tax_rate=0.0) | ['items', 'discount_code', 'tax_rate'] | AST function signature |
| meaningful-calculation-helpers | ✅ | exactly one separate subtotal, discount and tax helper, with no duplicate or additional helper | calculate_discount, calculate_subtotal, calculate_tax | top-level function definitions classified by domain responsibility |
| tax-helper-returns-one-result | ✅ | the tax helper returns only one tax amount and does not calculate or return invoice total | single tax result | AST return expressions, aggregate assignments, and downstream-total identifiers |
| entry-point-orchestrates-steps | ✅ | create_invoice calls the unique subtotal, discount and tax helpers and contains no calculation loop | orchestration extracted | AST calls and control-flow inspection |
| no-unneeded-production-types | ✅ | no classes added for this local refactor | no classes | top-level AST class definitions |
| existing-behavior-tests | ✅ | all existing invoice tests pass | OK | python -m unittest discover -s tests -v |
| **native-skill-activation** | ✅ | **native Skill tool invocation for "human-readable-code"** | **native Skill tool invocation for "human-readable-code" observed** | **OpenCode stderr tool trace** |

### Without-Skill Run
- **Mode:** without-skill
- **Duration:** 31.57s
- **Agent Return Code:** 0
- **Overall Passed:** ✅ YES

#### Individual Checks (8/8 passed)

| Check | Passed | Expected | Actual | Evidence |
|-------|--------|----------|--------|----------|
| valid-python | ✅ | invoice.py parses | valid | ast.parse(invoice.py) |
| public-api-preserved | ✅ | create_invoice(items, discount_code=None, tax_rate=0.0) | ['items', 'discount_code', 'tax_rate'] | AST function signature |
| meaningful-calculation-helpers | ✅ | exactly one separate subtotal, discount and tax helper, with no duplicate or additional helper | calculate_discount, calculate_subtotal, calculate_tax | top-level function definitions classified by domain responsibility |
| tax-helper-returns-one-result | ✅ | the tax helper returns only one tax amount and does not calculate or return invoice total | single tax result | AST return expressions, aggregate assignments, and downstream-total identifiers |
| entry-point-orchestrates-steps | ✅ | create_invoice calls the unique subtotal, discount and tax helpers and contains no calculation loop | orchestration extracted | AST calls and control-flow inspection |
| no-unneeded-production-types | ✅ | no classes added for this local refactor | no classes | top-level AST class definitions |
| existing-behavior-tests | ✅ | all existing invoice tests pass | OK | python -m unittest discover -s tests -v |
| **native-skill-activation** | ✅ | **no native Skill tool invocation for "human-readable-code"** | **no native Skill tool invocation for "human-readable-code" observed** | **OpenCode stderr tool trace** |

### Comparison
- **Impact Signal:** case_passes_without_skill
- **Without-Skill Checks Passed:** 8/8
- **With-Skill Checks Passed:** 8/8
- **Delta:** 0

---

## testable-design / registration-boundary

### With-Skill Run
- **Run ID:** 20261127T131121777729Z-registration-boundary-both
- **Mode:** with-skill
- **Adapter:** opencode
- **Model:** OpenCode default (litellm/freeLLMAPI)
- **Duration:** 32.36s
- **Agent Return Code:** 0
- **Overall Passed:** ✅ YES

#### Individual Checks (8/8 passed)

| Check | Passed | Expected | Actual | Evidence |
|-------|--------|----------|--------|----------|
| valid-python | ✅ | production and test files parse | valid | ast.parse(registration.py, test_registration.py) |
| explicit-pure-policy-helper | ✅ | prepare_registration(data) and register_user(data, database, mailer) exist | prepare_registration, register_user | top-level function definitions |
| validation-independent-of-effects | ✅ | prepare_registration has no persistence, mail, time, filesystem, or output effects | no external-effect references | AST inspection of prepare_registration |
| entry-point-orchestrates-boundaries | ✅ | register_user uses prepare_registration, then persists and sends welcome email | delegation present | AST calls and collaborator operations |
| direct-helper-tests | ✅ | at least two distinct test methods directly call prepare_registration | 6 test methods (test_prepare_registration_valid_input@46, test_prepare_registration_normalizes_whitespace_and_case@53, test_prepare_registration_empty_name_raises@58, test_prepare_registration_missing_name_raises@63, test_prepare_registration_invalid_email_no_at_raises@68, test_prepare_registration_invalid_email_starts_with_at_raises@73, test_prepare_registration_invalid_email_ends_with_at_raises@78) | AST inspection of test method bodies, excluding nested scopes |
| no-mock-heavy-test-setup | ✅ | use lightweight fakes rather than mocks | no mock framework usage | test source scan |
| registration-tests | ✅ | all registration tests pass | OK | python -m unittest discover -s tests -v |
| **native-skill-activation** | ✅ | **native Skill tool invocation for "testable-design"** | **native Skill tool invocation for "testable-design" observed** | **OpenCode stderr tool trace** |

### Without-Skill Run
- **Mode:** without-skill
- **Duration:** 52.26s
- **Agent Return Code:** 0
- **Overall Passed:** ✅ YES

#### Individual Checks (8/8 passed)

| Check | Passed | Expected | Actual | Evidence |
|-------|--------|----------|--------|----------|
| valid-python | ✅ | production and test files parse | valid | ast.parse(registration.py, test_registration.py) |
| explicit-pure-policy-helper | ✅ | prepare_registration(data) and register_user(data, database, mailer) exist | prepare_registration, register_user | top-level function definitions |
| validation-independent-of-effects | ✅ | prepare_registration has no persistence, mail, time, filesystem, or output effects | no external-effect references | AST inspection of prepare_registration |
| entry-point-orchestrates-boundaries | ✅ | register_user uses prepare_registration, then persists and sends welcome email | delegation present | AST calls and collaborator operations |
| direct-helper-tests | ✅ | at least two distinct test methods directly call prepare_registration | 8 test methods (test_normalizes_name_and_email@46, test_strips_and_lowercases_email@53, test_raises_value_error_for_empty_name@57, test_raises_value_error_for_whitespace_only_name@62, test_raises_value_error_for_missing_name_key@67, test_raises_value_error_for_email_without_at@72, test_raises_value_error_for_email_starting_with_at@77, test_raises_value_error_for_email_ending_with_at@82) | AST inspection of test method bodies, excluding nested scopes |
| no-mock-heavy-test-setup | ✅ | use lightweight fakes rather than mocks | no mock framework usage | test source scan |
| registration-tests | ✅ | all registration tests pass | OK | python -m unittest discover -s tests -v |
| **native-skill-activation** | ✅ | **no native Skill tool invocation for "testable-design"** | **no native Skill tool invocation for "testable-design" observed** | **OpenCode stderr tool trace** |

### Comparison
- **Impact Signal:** case_passes_without_skill
- **Without-Skill Checks Passed:** 8/8
- **With-Skill Checks Passed:** 8/8
- **Delta:** 0

---

## Native Skill Activation Verification Summary

The benchmark runner's mandatory native-skill-activation check **PASSED for all 4 runs**:

| Skill | With-Skill (must observe) | Without-Skill (must NOT observe) |
|-------|---------------------------|----------------------------------|
| human-readable-code | ✅ Observed in stderr tool trace | ✅ Not observed in stderr tool trace |
| testable-design | ✅ Observed in stderr tool trace | ✅ Not observed in stderr tool trace |

**Verification Method:** The benchmark runner inspects OpenCode stderr for the pattern `Skill "skill-id"` (with ANSI normalization). With-skill runs require the pattern to be present; without-skill runs require it to be absent. Both conditions were met.

---

## Artifacts

Complete per-run artifacts are preserved under:
- `benchmark-evidence/20261127T131015998356Z-invoice-refactor-both/`
- `benchmark-evidence/20261127T131121777729Z-registration-boundary-both/`

Each contains:
- `report.md` / `report.json` — full benchmark report
- `cases/<case>/input/` — snapshots of case definition, fixture, skill, and manifest
- `cases/<case>/with-skill/` — prompt, command, stdout, stderr, verifier.json, git status/log/diff/show
- `cases/<case>/without-skill/` — same artifacts for baseline run

---

## Conclusion

All behavioral benchmarks for PR #172 executed successfully against the exact source SHA `e3d67db12fed63a3d7f0f5d3d135c22c11db8148` using the configured OpenCode provider and default model (litellm/freeLLMAPI) with no fallback or configuration changes.

- **human-readable-code**: Both with-skill and without-skill modes pass all verifier checks. Native skill activation verified.
- **testable-design**: Both with-skill and without-skill modes pass all verifier checks. Native skill activation verified.

The benchmark evidence demonstrates that the current skill implementations produce correct behavioral outcomes for both skills under test.