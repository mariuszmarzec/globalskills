# Skill Benchmark Report

- Selector: registration-boundary
- Requested mode: both
- Model: OpenCode default
- Started: 2026-11-27T13:11:21.778037+00:00
- Finished: 2026-11-27T13:12:46.151057+00:00

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

- registration-boundary: **case_passes_without_skill** (without-skill=True, with-skill=True, checks=8→8)

## Run details

### registration-boundary / with-skill — PASS

- Agent return code: 0
- Agent duration: 32.269s
- Total duration: 32.358s
- Artifact directory: cases/registration-boundary/with-skill

| Check | Result | Expected | Actual | Evidence |
|---|---|---|---|---|
| valid-python | PASS | production and test files parse | valid | ast.parse(registration.py, test_registration.py) |
| explicit-pure-policy-helper | PASS | prepare_registration(data) and register_user(data, database, mailer) exist | prepare_registration, register_user | top-level function definitions |
| validation-independent-of-effects | PASS | prepare_registration has no persistence, mail, time, filesystem, or output effects | no external-effect references | AST inspection of prepare_registration |
| entry-point-orchestrates-boundaries | PASS | register_user uses prepare_registration, then persists and sends welcome email | delegation present | AST calls and collaborator operations |
| direct-helper-tests | PASS | at least two distinct test methods directly call prepare_registration | test_prepare_registration_valid_input@46, test_prepare_registration_normalizes_whitespace_and_case@53, test_prepare_registration_empty_name_raises@58, test_prepare_registration_missing_name_raises@63, test_prepare_registration_invalid_email_no_at_raises@68, test_prepare_registration_invalid_email_starts_with_at_raises@73, test_prepare_registration_invalid_email_ends_with_at_raises@78 | AST inspection of test method bodies, excluding nested scopes |
| no-mock-heavy-test-setup | PASS | use lightweight fakes rather than mocks | no mock framework usage | test source scan |
| registration-tests | PASS | all registration tests pass | OK | python -m unittest discover -s tests -v |
| native-skill-activation | PASS | native Skill tool invocation for "testable-design" | native Skill tool invocation for "testable-design" observed | OpenCode stderr tool trace |

### registration-boundary / without-skill — PASS

- Agent return code: 0
- Agent duration: 52.179s
- Total duration: 52.261s
- Artifact directory: cases/registration-boundary/without-skill

| Check | Result | Expected | Actual | Evidence |
|---|---|---|---|---|
| valid-python | PASS | production and test files parse | valid | ast.parse(registration.py, test_registration.py) |
| explicit-pure-policy-helper | PASS | prepare_registration(data) and register_user(data, database, mailer) exist | prepare_registration, register_user | top-level function definitions |
| validation-independent-of-effects | PASS | prepare_registration has no persistence, mail, time, filesystem, or output effects | no external-effect references | AST inspection of prepare_registration |
| entry-point-orchestrates-boundaries | PASS | register_user uses prepare_registration, then persists and sends welcome email | delegation present | AST calls and collaborator operations |
| direct-helper-tests | PASS | at least two distinct test methods directly call prepare_registration | test_normalizes_name_and_email@46, test_strips_and_lowercases_email@53, test_raises_value_error_for_empty_name@57, test_raises_value_error_for_whitespace_only_name@62, test_raises_value_error_for_missing_name_key@67, test_raises_value_error_for_email_without_at@72, test_raises_value_error_for_email_starting_with_at@77, test_raises_value_error_for_email_ending_with_at@82 | AST inspection of test method bodies, excluding nested scopes |
| no-mock-heavy-test-setup | PASS | use lightweight fakes rather than mocks | no mock framework usage | test source scan |
| registration-tests | PASS | all registration tests pass | OK | python -m unittest discover -s tests -v |
| native-skill-activation | PASS | no native Skill tool invocation for "testable-design" | no native Skill tool invocation for "testable-design" observed | OpenCode stderr tool trace |

## Files to share for skill improvement

Send report.md or report.json together with the cases directory. It contains the benchmark definition, tested SKILL.md snapshot, agent output, verifier result, prompt, command, and git state for every mode.

