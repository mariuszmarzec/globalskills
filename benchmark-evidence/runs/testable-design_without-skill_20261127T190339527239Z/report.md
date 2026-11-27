# Skill Benchmark Report

- Selector: testable-design
- Requested mode: both
- Model: OpenCode default
- Started: 2026-11-27T19:03:39.527547+00:00
- Finished: 2026-11-27T19:10:43.736269+00:00

## Summary

- Cases: **1**
- Runs: **2**
- Passed: **1**
- Failed: **1**
- Skills: **1**

## Evaluation

- Target mode: **with-skill**
- Passed: **1/1**
- Status: **PASS**

## Impact

- Cases compared: **1**
- Skill helped: **1**
- Skill harmed: **0**
- Already passes without skill: **0**
- Fails with and without skill: **0**

## With-skill vs without-skill

- registration-boundary: **skill_helped** (without-skill=False, with-skill=True, checks=7→8)
  - Without skill failures: native-skill-activation
  - Changed check native-skill-activation: False → True

## Run details

### registration-boundary / with-skill — PASS

- Agent return code: 0
- Agent duration: 86.964s
- Total duration: 87.043s
- Artifact directory: cases/registration-boundary/with-skill

| Check | Result | Expected | Actual | Evidence |
|---|---|---|---|---|
| valid-python | PASS | production and test files parse | valid | ast.parse(registration.py, test_registration.py) |
| explicit-pure-policy-helper | PASS | prepare_registration(data) and register_user(data, database, mailer) exist | prepare_registration, register_user | top-level function definitions |
| validation-independent-of-effects | PASS | prepare_registration has no persistence, mail, time, filesystem, or output effects | no external-effect references | AST inspection of prepare_registration |
| entry-point-orchestrates-boundaries | PASS | register_user uses prepare_registration, then persists and sends welcome email | delegation present | AST calls and collaborator operations |
| direct-helper-tests | PASS | at least two distinct test methods directly call prepare_registration | test_normalizes_input_and_validates@46, test_valid_email_and_name@53, test_invalid_email_fails@60, test_email_starts_with_at_fails@65, test_email_ends_with_at_fails@70, test_empty_name_fails@75, test_whitespace_only_name_fails@80, test_missing_name_fails@85, test_missing_email_fails@90 | AST inspection of test method bodies, excluding nested scopes |
| no-mock-heavy-test-setup | PASS | use lightweight fakes rather than mocks | no mock framework usage | test source scan |
| registration-tests | PASS | all registration tests pass | OK | python -m unittest discover -s tests -v |
| native-skill-activation | PASS | native Skill tool invocation for "testable-design" | native Skill tool invocation for "testable-design" observed | OpenCode stderr tool trace |

### registration-boundary / without-skill — FAIL

- Agent return code: 0
- Agent duration: 338.397s
- Total duration: 338.485s
- Artifact directory: cases/registration-boundary/without-skill

| Check | Result | Expected | Actual | Evidence |
|---|---|---|---|---|
| valid-python | PASS | production and test files parse | valid | ast.parse(registration.py, test_registration.py) |
| explicit-pure-policy-helper | PASS | prepare_registration(data) and register_user(data, database, mailer) exist | prepare_registration, register_user | top-level function definitions |
| validation-independent-of-effects | PASS | prepare_registration has no persistence, mail, time, filesystem, or output effects | no external-effect references | AST inspection of prepare_registration |
| entry-point-orchestrates-boundaries | PASS | register_user uses prepare_registration, then persists and sends welcome email | delegation present | AST calls and collaborator operations |
| direct-helper-tests | PASS | at least two distinct test methods directly call prepare_registration | test_normalizes_name_and_email@23, test_empty_name_raises_error@30, test_missing_name_raises_error@35, test_missing_name_key_raises_error@40, test_invalid_email_no_at_sign_raises_error@45, test_invalid_email_starts_with_at_raises_error@50, test_invalid_email_ends_with_at_raises_error@55 | AST inspection of test method bodies, excluding nested scopes |
| no-mock-heavy-test-setup | PASS | use lightweight fakes rather than mocks | no mock framework usage | test source scan |
| registration-tests | PASS | all registration tests pass | OK | python -m unittest discover -s tests -v |
| native-skill-activation | FAIL | no native Skill tool invocation for "testable-design" | native Skill tool invocation for "testable-design" observed | OpenCode stderr tool trace |

## Files to share for skill improvement

Send report.md or report.json together with the cases directory. It contains the benchmark definition, tested SKILL.md snapshot, agent output, verifier result, prompt, command, and git state for every mode.

