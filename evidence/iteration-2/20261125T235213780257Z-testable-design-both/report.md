# Skill Benchmark Report

- Selector: testable-design
- Requested mode: both
- Model: OpenCode default
- Started: 2026-11-25T23:52:13.780619+00:00
- Finished: 2026-11-25T23:53:56.510692+00:00

## Summary

- Cases: **1**
- Runs: **2**
- Passed: **2**
- Failed: **0**
- Skills: **1**

## Evaluation

- Target mode: **with-skill**
- Passed: **1/1**
- Status: **PASS**

## Impact

- Cases compared: **1**
- Skill helped: **0**
- Skill harmed: **0**
- Already passes without skill: **1**
- Fails with and without skill: **0**

## With-skill vs without-skill

- registration-boundary: **case_passes_without_skill** (without-skill=True, with-skill=True, checks=7→7)

## Run details

### registration-boundary / with-skill — PASS

- Agent return code: 0
- Agent duration: 29.877s
- Total duration: 29.957s
- Artifact directory: cases/registration-boundary/with-skill

| Check | Result | Expected | Actual | Evidence |
|---|---|---|---|---|
| valid-python | PASS | production and test files parse | valid | ast.parse(registration.py, test_registration.py) |
| explicit-pure-policy-helper | PASS | a pure helper (one data arg, no effects) and register_user(data, database, mailer) exist | _normalize_and_validate, register_user | top-level function definitions |
| validation-independent-of-effects | PASS | _normalize_and_validate has no persistence, mail, time, filesystem, or output effects | no external-effect references | AST inspection of _normalize_and_validate |
| entry-point-orchestrates-boundaries | PASS | register_user uses _normalize_and_validate, then persists and sends welcome email | delegation present | AST calls and collaborator operations |
| direct-helper-tests | PASS | at least two distinct test functions directly call _normalize_and_validate | test_empty_name_raises, test_invalid_email_ends_with_at_raises, test_invalid_email_missing_at_raises, test_invalid_email_starts_with_at_raises, test_missing_name_raises, test_normalizes_name_and_email, test_whitespace_only_email_raises | AST inspection of test_* function bodies for direct Call(Name('_normalize_and_validate')) |
| no-mock-heavy-test-setup | PASS | use lightweight fakes rather than mocks | no mock framework usage | test source scan |
| registration-tests | PASS | all registration tests pass | OK | python -m unittest discover -s tests -v |

### registration-boundary / without-skill — PASS

- Agent return code: 0
- Agent duration: 72.726s
- Total duration: 72.806s
- Artifact directory: cases/registration-boundary/without-skill

| Check | Result | Expected | Actual | Evidence |
|---|---|---|---|---|
| valid-python | PASS | production and test files parse | valid | ast.parse(registration.py, test_registration.py) |
| explicit-pure-policy-helper | PASS | a pure helper (one data arg, no effects) and register_user(data, database, mailer) exist | normalize_and_validate, register_user | top-level function definitions |
| validation-independent-of-effects | PASS | normalize_and_validate has no persistence, mail, time, filesystem, or output effects | no external-effect references | AST inspection of normalize_and_validate |
| entry-point-orchestrates-boundaries | PASS | register_user uses normalize_and_validate, then persists and sends welcome email | delegation present | AST calls and collaborator operations |
| direct-helper-tests | PASS | at least two distinct test functions directly call normalize_and_validate | test_empty_name_raises, test_invalid_email_ends_with_at_raises, test_invalid_email_missing_at_raises, test_invalid_email_starts_with_at_raises, test_missing_email_raises, test_missing_name_raises, test_normalizes_name_and_email | AST inspection of test_* function bodies for direct Call(Name('normalize_and_validate')) |
| no-mock-heavy-test-setup | PASS | use lightweight fakes rather than mocks | no mock framework usage | test source scan |
| registration-tests | PASS | all registration tests pass | OK | python -m unittest discover -s tests -v |

## Files to share for skill improvement

Send report.md or report.json together with the cases directory. It contains the benchmark definition, tested SKILL.md snapshot, agent output, verifier result, prompt, command, and git state for every mode.

