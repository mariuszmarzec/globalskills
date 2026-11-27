# Skill Benchmark Report

- Selector: human-readable-code
- Requested mode: both
- Model: OpenCode default
- Started: 2026-11-27T10:54:50.001104+00:00
- Finished: 2026-11-27T10:59:11.104133+00:00

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

- invoice-refactor: **case_fails_with_and_without_skill** (without-skill=False, with-skill=False, checks=4→4)
  - Without skill failures: entry-point-orchestrates-steps, meaningful-calculation-helpers, tax-helper-returns-one-result
  - Remaining with-skill failures: entry-point-orchestrates-steps, meaningful-calculation-helpers, tax-helper-returns-one-result

## Run details

### invoice-refactor / with-skill — FAIL

- Agent return code: 0
- Agent duration: 35.535s
- Total duration: 35.621s
- Artifact directory: cases/invoice-refactor/with-skill

| Check | Result | Expected | Actual | Evidence |
|---|---|---|---|---|
| valid-python | PASS | invoice.py parses | valid | ast.parse(invoice.py) |
| public-api-preserved | PASS | create_invoice(items, discount_code=None, tax_rate=0.0) | ['items', 'discount_code', 'tax_rate'] | AST function signature |
| meaningful-calculation-helpers | FAIL | exactly one separate subtotal, discount and tax helper, with no duplicate or additional helper | calculate_discount, calculate_subtotal, calculate_total_and_tax | top-level function definitions classified by domain responsibility |
| tax-helper-returns-one-result | FAIL | the tax helper returns only one tax amount and does not calculate or return invoice total | tax helper missing, multi-value result, or downstream total found | AST return expressions, aggregate assignments, and downstream-total identifiers |
| entry-point-orchestrates-steps | FAIL | create_invoice calls the unique subtotal, discount and tax helpers and contains no calculation loop | expected helper calls or loop-free orchestration missing | AST calls and control-flow inspection |
| no-unneeded-production-types | PASS | no classes added for this local refactor | no classes | top-level AST class definitions |
| existing-behavior-tests | PASS | all existing invoice tests pass | OK | python -m unittest discover -s tests -v |

### invoice-refactor / without-skill — FAIL

- Agent return code: 0
- Agent duration: 226.299s
- Total duration: 226.378s
- Artifact directory: cases/invoice-refactor/without-skill

| Check | Result | Expected | Actual | Evidence |
|---|---|---|---|---|
| valid-python | PASS | invoice.py parses | valid | ast.parse(invoice.py) |
| public-api-preserved | PASS | create_invoice(items, discount_code=None, tax_rate=0.0) | ['items', 'discount_code', 'tax_rate'] | AST function signature |
| meaningful-calculation-helpers | FAIL | exactly one separate subtotal, discount and tax helper, with no duplicate or additional helper | _apply_discount, _calculate_discount, _calculate_subtotal, _calculate_tax, _calculate_total | top-level function definitions classified by domain responsibility |
| tax-helper-returns-one-result | FAIL | the tax helper returns only one tax amount and does not calculate or return invoice total | tax helper missing, multi-value result, or downstream total found | AST return expressions, aggregate assignments, and downstream-total identifiers |
| entry-point-orchestrates-steps | FAIL | create_invoice calls the unique subtotal, discount and tax helpers and contains no calculation loop | expected helper calls or loop-free orchestration missing | AST calls and control-flow inspection |
| no-unneeded-production-types | PASS | no classes added for this local refactor | no classes | top-level AST class definitions |
| existing-behavior-tests | PASS | all existing invoice tests pass | OK | python -m unittest discover -s tests -v |

## Files to share for skill improvement

Send report.md or report.json together with the cases directory. It contains the benchmark definition, tested SKILL.md snapshot, agent output, verifier result, prompt, command, and git state for every mode.

