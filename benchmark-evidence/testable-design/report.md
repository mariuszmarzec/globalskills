# Skill Benchmark Report

- Selector: testable-design
- Requested mode: both
- Model: OpenCode default
- Started: 2026-11-26T20:24:22.604178+00:00
- Finished: 2026-11-26T20:26:54.613105+00:00

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
- Agent duration: 71.511s
- Total duration: 71.588s
- Artifact directory: cases/registration-boundary/with-skill

| Check | Result | Expected | Actual | Evidence |
|---|---|---|---|---|
| valid-python | PASS | production and test files parse | valid | ast.parse(registration.py, test_registration.py) |
| explicit-pure-policy-helper | PASS | prepare_registration(data) and register_user(data, database, mailer) exist | prepare_registration, register_user | top-level function definitions |
| validation-independent-of-effects | PASS | prepare_registration has no persistence, mail, time, filesystem, or output effects | no external-effect references | AST inspection of prepare_registration |
| entry-point-orchestrates-boundaries | PASS | register_user uses prepare_registration, then persists and sends welcome email | delegation present | AST calls and collaborator operations |
| direct-helper-tests | PASS | at least two distinct test methods directly call prepare_registration | test_normalizes_whitespace_and_lowercases_email@7, test_raises_for_empty_name@14, test_raises_for_missing_at_symbol@19, test_raises_for_email_starting_with_at@24, test_raises_for_email_ending_with_at@29 | AST inspection of test method bodies, excluding nested scopes |
| no-mock-heavy-test-setup | PASS | use lightweight fakes rather than mocks | no mock framework usage | test source scan |
| registration-tests | PASS | all registration tests pass | OK | python -m unittest discover -s tests -v |

### registration-boundary / without-skill — PASS

- Agent return code: 0
- Agent duration: 80.747s
- Total duration: 80.825s
- Artifact directory: cases/registration-boundary/without-skill

| Check | Result | Expected | Actual | Evidence |
|---|---|---|---|---|
| valid-python | PASS | production and test files parse | valid | ast.parse(registration.py, test_registration.py) |
| explicit-pure-policy-helper | PASS | prepare_registration(data) and register_user(data, database, mailer) exist | prepare_registration, register_user | top-level function definitions |
| validation-independent-of-effects | PASS | prepare_registration has no persistence, mail, time, filesystem, or output effects | no external-effect references | AST inspection of prepare_registration |
| entry-point-orchestrates-boundaries | PASS | register_user uses prepare_registration, then persists and sends welcome email | delegation present | AST calls and collaborator operations |
| direct-helper-tests | PASS | at least two distinct test methods directly call prepare_registration | test_normalizes_name_and_email@23, test_raises_for_empty_name@30, test_raises_for_missing_at_in_email@35, test_raises_for_email_starting_with_at@40, test_raises_for_email_ending_with_at@45 | AST inspection of test method bodies, excluding nested scopes |
| no-mock-heavy-test-setup | PASS | use lightweight fakes rather than mocks | no mock framework usage | test source scan |
| registration-tests | PASS | all registration tests pass | OK | python -m unittest discover -s tests -v |

## Files to share for skill improvement

Send report.md or report.json together with the cases directory. It contains the benchmark definition, tested SKILL.md snapshot, agent output, verifier result, prompt, command, and git state for every mode.

