# Skill Benchmark Report

- Selector: human-readable-code
- Requested mode: both
- Model: litellm/freeLLMAPI
- Started: 2026-11-27T12:59:00.877968+00:00
- Finished: 2026-11-27T13:00:16.703884+00:00

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

- invoice-refactor: **case_passes_without_skill** (without-skill=True, with-skill=True, checks=8→8)

## Run details

### invoice-refactor / with-skill — PASS

- Agent return code: 0
- Agent duration: 47.824s
- Total duration: 47.905s
- Artifact directory: cases/invoice-refactor/with-skill

| Check | Result | Expected | Actual | Evidence |
|---|---|---|---|---|
| valid-python | PASS | invoice.py parses | valid | ast.parse(invoice.py) |
| public-api-preserved | PASS | create_invoice(items, discount_code=None, tax_rate=0.0) | ['items', 'discount_code', 'tax_rate'] | AST function signature |
| meaningful-calculation-helpers | PASS | exactly one separate subtotal, discount and tax helper, with no duplicate or additional helper | calculate_discount, calculate_subtotal, calculate_tax | top-level function definitions classified by domain responsibility |
| tax-helper-returns-one-result | PASS | the tax helper returns only one tax amount and does not calculate or return invoice total | single tax result | AST return expressions, aggregate assignments, and downstream-total identifiers |
| entry-point-orchestrates-steps | PASS | create_invoice calls the unique subtotal, discount and tax helpers and contains no calculation loop | orchestration extracted | AST calls and control-flow inspection |
| no-unneeded-production-types | PASS | no classes added for this local refactor | no classes | top-level AST class definitions |
| existing-behavior-tests | PASS | all existing invoice tests pass | OK | python -m unittest discover -s tests -v |
| native-skill-activation | PASS | native Skill tool invocation for "human-readable-code" | native Skill tool invocation for "human-readable-code" observed | OpenCode stderr tool trace |

### invoice-refactor / without-skill — PASS

- Agent return code: 0
- Agent duration: 28.081s
- Total duration: 28.163s
- Artifact directory: cases/invoice-refactor/without-skill

| Check | Result | Expected | Actual | Evidence |
|---|---|---|---|---|
| valid-python | PASS | invoice.py parses | valid | ast.parse(invoice.py) |
| public-api-preserved | PASS | create_invoice(items, discount_code=None, tax_rate=0.0) | ['items', 'discount_code', 'tax_rate'] | AST function signature |
| meaningful-calculation-helpers | PASS | exactly one separate subtotal, discount and tax helper, with no duplicate or additional helper | calculate_discount, calculate_subtotal, calculate_tax | top-level function definitions classified by domain responsibility |
| tax-helper-returns-one-result | PASS | the tax helper returns only one tax amount and does not calculate or return invoice total | single tax result | AST return expressions, aggregate assignments, and downstream-total identifiers |
| entry-point-orchestrates-steps | PASS | create_invoice calls the unique subtotal, discount and tax helpers and contains no calculation loop | orchestration extracted | AST calls and control-flow inspection |
| no-unneeded-production-types | PASS | no classes added for this local refactor | no classes | top-level AST class definitions |
| existing-behavior-tests | PASS | all existing invoice tests pass | OK | python -m unittest discover -s tests -v |
| native-skill-activation | PASS | no native Skill tool invocation for "human-readable-code" | no native Skill tool invocation for "human-readable-code" observed | OpenCode stderr tool trace |

## Files to share for skill improvement

Send report.md or report.json together with the cases directory. It contains the benchmark definition, tested SKILL.md snapshot, agent output, verifier result, prompt, command, and git state for every mode.

