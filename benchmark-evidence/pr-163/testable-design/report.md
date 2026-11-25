# Skill Benchmark Report

- Selector: testable-design
- Requested mode: both
- Model: OpenCode default
- Started: 2026-11-25T19:30:47.820916+00:00
- Finished: 2026-11-25T19:34:27.624088+00:00

## Summary

- Cases: **1**
- Runs: **2**
- Passed: **0**
- Failed: **2**
- Skills: **1**

## Evaluation

- Target mode: **with-skill**
- Passed: **0/1**
- Status: **FAIL**

## Impact

- Cases compared: **1**
- Skill helped: **0**
- Skill harmed: **0**
- Already passes without skill: **0**
- Fails with and without skill: **1**

## With-skill vs without-skill

- registration-boundary: **case_fails_with_and_without_skill** (without-skill=False, with-skill=False, checks=6→6)
  - Without skill failures: direct-helper-tests
  - Remaining with-skill failures: direct-helper-tests

## Run details

### registration-boundary / with-skill — FAIL

- Agent return code: 0
- Agent duration: 120.539s
- Total duration: 120.618s
- Artifact directory: cases/registration-boundary/with-skill

| Check | Result | Expected | Actual | Evidence |
|---|---|---|---|---|
| valid-python | PASS | production and test files parse | valid | ast.parse(registration.py, test_registration.py) |
| explicit-pure-policy-helper | PASS | prepare_registration(data) and register_user(data, database, mailer) exist | prepare_registration, register_user | top-level function definitions |
| validation-independent-of-effects | PASS | prepare_registration has no persistence, mail, time, filesystem, or output effects | no external-effect references | AST inspection of prepare_registration |
| entry-point-orchestrates-boundaries | PASS | register_user uses prepare_registration, then persists and sends welcome email | delegation present | AST calls and collaborator operations |
| direct-helper-tests | FAIL | at least two focused tests exercise prepare_registration directly | no direct helper tests | test function names |
| no-mock-heavy-test-setup | PASS | use lightweight fakes rather than mocks | no mock framework usage | test source scan |
| registration-tests | PASS | all registration tests pass | OK | python -m unittest discover -s tests -v |

### registration-boundary / without-skill — FAIL

- Agent return code: 0
- Agent duration: 99.321s
- Total duration: 99.4s
- Artifact directory: cases/registration-boundary/without-skill

| Check | Result | Expected | Actual | Evidence |
|---|---|---|---|---|
| valid-python | PASS | production and test files parse | valid | ast.parse(registration.py, test_registration.py) |
| explicit-pure-policy-helper | PASS | prepare_registration(data) and register_user(data, database, mailer) exist | prepare_registration, register_user | top-level function definitions |
| validation-independent-of-effects | PASS | prepare_registration has no persistence, mail, time, filesystem, or output effects | no external-effect references | AST inspection of prepare_registration |
| entry-point-orchestrates-boundaries | PASS | register_user uses prepare_registration, then persists and sends welcome email | delegation present | AST calls and collaborator operations |
| direct-helper-tests | FAIL | at least two focused tests exercise prepare_registration directly | no direct helper tests | test function names |
| no-mock-heavy-test-setup | PASS | use lightweight fakes rather than mocks | no mock framework usage | test source scan |
| registration-tests | PASS | all registration tests pass | OK | python -m unittest discover -s tests -v |

## Files to share for skill improvement

Send report.md or report.json together with the cases directory. It contains the benchmark definition, tested SKILL.md snapshot, agent output, verifier result, prompt, command, and git state for every mode.

