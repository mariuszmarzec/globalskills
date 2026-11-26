# Skill Benchmark Report

- Selector: testable-design
- Requested mode: both
- Model: OpenCode default
- Started: 2026-11-26T13:05:19.931614+00:00
- Finished: 2026-11-26T13:09:16.154696+00:00

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
- Agent duration: 138.95s
- Total duration: 139.028s
- Artifact directory: cases/registration-boundary/with-skill

| Check | Result | Expected | Actual | Evidence |
|---|---|---|---|---|
| valid-python | PASS | production and test files parse | valid | ast.parse(registration.py, test_registration.py) |
| explicit-pure-policy-helper | PASS | prepare_registration(data) and register_user(data, database, mailer) exist | prepare_registration, register_user | top-level function definitions |
| validation-independent-of-effects | PASS | prepare_registration has no persistence, mail, time, filesystem, or output effects | no external-effect references | AST inspection of prepare_registration |
| entry-point-orchestrates-boundaries | PASS | register_user uses prepare_registration, then persists and sends welcome email | delegation present | AST calls and collaborator operations |
| direct-helper-tests | PASS | at least two distinct test methods directly call prepare_registration | test_normalizes_name_and_email@23, test_empty_name_raises@30, test_missing_name_raises@35, test_invalid_email_missing_at_raises@39, test_invalid_email_starts_with_at_raises@44, test_invalid_email_ends_with_at_raises@48, test_missing_email_raises@52 | AST inspection of test method bodies, excluding nested scopes |
| no-mock-heavy-test-setup | PASS | use lightweight fakes rather than mocks | no mock framework usage | test source scan |
| registration-tests | PASS | all registration tests pass | OK | python -m unittest discover -s tests -v |

### registration-boundary / without-skill — PASS

- Agent return code: 0
- Agent duration: 97.719s
- Total duration: 97.801s
- Artifact directory: cases/registration-boundary/without-skill

| Check | Result | Expected | Actual | Evidence |
|---|---|---|---|---|
| valid-python | PASS | production and test files parse | valid | ast.parse(registration.py, test_registration.py) |
| explicit-pure-policy-helper | PASS | prepare_registration(data) and register_user(data, database, mailer) exist | prepare_registration, register_user | top-level function definitions |
| validation-independent-of-effects | PASS | prepare_registration has no persistence, mail, time, filesystem, or output effects | no external-effect references | AST inspection of prepare_registration |
| entry-point-orchestrates-boundaries | PASS | register_user uses prepare_registration, then persists and sends welcome email | delegation present | AST calls and collaborator operations |
| direct-helper-tests | PASS | at least two distinct test methods directly call prepare_registration | test_normalizes_name_and_email@23, test_valid_email_with_subdomain@30, test_empty_name_raises@36, test_missing_name_raises@41, test_email_missing_at_raises@46, test_email_starts_with_at_raises@51, test_email_ends_with_at_raises@56, test_email_only_at_raises@61 | AST inspection of test method bodies, excluding nested scopes |
| no-mock-heavy-test-setup | PASS | use lightweight fakes rather than mocks | no mock framework usage | test source scan |
| registration-tests | PASS | all registration tests pass | OK | python -m unittest discover -s tests -v |

## Files to share for skill improvement

Send report.md or report.json together with the cases directory. It contains the benchmark definition, tested SKILL.md snapshot, agent output, verifier result, prompt, command, and git state for every mode.

