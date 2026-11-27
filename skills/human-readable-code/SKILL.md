---
name: human-readable-code
description: Required guidance for code changes and refactoring. Load with the native skill tool before inspecting or editing code; then choose cohesive function boundaries, preserve behavior, and avoid unnecessary abstractions.
license: MIT
---

# Human-Readable Code

## Priority rule: one requested operation, one result

When a task explicitly names the operations to extract, treat that list as closed and exhaustive—not as a starting point or suggestion. Before editing, map each named operation to one helper and one result owned by that helper.

- Create exactly one helper for each named operation that has meaningful behavior.
- Each helper performs only its named operation and returns exactly that operation's result.
- A helper must not return a tuple, list, dictionary, or object that bundles its result with a downstream result owned by another step.
- Do not combine a named operation with a downstream result, even when the calculations share inputs or seem closely related.
- Do not put downstream calculations inside a helper just to make the entry point shorter.
- Do not add helpers for simple intermediate or derived values.
- Keep downstream arithmetic and final result assembly inline in the entry point.
- Do not add further production helpers beyond the named operations unless the task separately requests another independent domain responsibility.

For a request that names subtotal, discount, and tax, the operation/result map is:

| Requested operation | Helper | The helper returns | Keep in the caller |
|---|---|---|---|
| Subtotal | `calculate_subtotal(items)` | Subtotal amount only | — |
| Discount | `calculate_discount(subtotal, discount_code)` | Discount amount only | — |
| Tax | `calculate_tax(taxable_amount, tax_rate)` | Tax amount only | Derive taxable amount and calculate final total |

Use three separate helpers. The caller owns the sequence and the intermediate/final arithmetic:

```python
def calculate_subtotal(items):
    ...

def calculate_discount(subtotal, discount_code):
    ...

def calculate_tax(taxable_amount, tax_rate):
    return round(taxable_amount * tax_rate, 2)


def create_invoice(items, discount_code=None, tax_rate=0.0):
    subtotal = calculate_subtotal(items)
    discount = calculate_discount(subtotal, discount_code)
    taxable_amount = max(subtotal - discount, 0.0)
    tax = calculate_tax(taxable_amount, tax_rate)
    total = round(taxable_amount + tax, 2)
    return {
        "subtotal": round(subtotal, 2),
        "discount": round(discount, 2),
        "tax": tax,
        "total": total,
    }
```

**This is not an interchangeable naming preference; it is a responsibility boundary.** The tax helper returns one tax amount. It does not calculate or return the invoice total.

Never do this—even if the helper name sounds cohesive or the caller becomes shorter:

```python
def calculate_tax_and_total(taxable_amount, tax_rate):
    tax = round(taxable_amount * tax_rate, 2)
    total = round(taxable_amount + tax, 2)
    return tax, total
```

Also do not hide the same combination behind a generic name such as `calculate_tax` while returning both values. A helper's name, body, and return contract must all describe the same single operation. Do not add `calculate_taxable_amount` or `calculate_total` helpers for these simple expressions.

If a task explicitly defines one operation as producing multiple related values, preserve that domain contract. Do not invent a multi-result helper by combining two separately named steps.

## Goal

Optimize code for the next person who has to understand, debug, review, or change it. Readability is a practical engineering property: a developer should be able to follow the intent and important decisions without reconstructing the author's thought process.

Prefer clear, direct code over cleverness, architectural ceremony, or reducing line count. Preserve behavior and public contracts that the task does not ask you to change.

## Working approach

1. Read the surrounding code before editing. Follow established naming, formatting, module boundaries, and local conventions unless they are actively harmful to the requested change.
2. Identify the behavior being changed and the smallest relevant area of the codebase.
3. For an explicitly enumerated extraction task, write down the operation-to-helper-to-result map before editing. Keep intermediate values and downstream result assembly with the caller.
4. Make the intent visible in names, function boundaries, and control flow.
5. Keep the change scoped. Do not use a small task as an excuse to reorganize neighboring code.
6. Verify behavior with relevant existing tests and add focused tests when the change needs them.

## Functions: small, cohesive, meaningful

Prefer functions with one coherent responsibility and a name that communicates the operation.

Extract a function when it does at least one meaningful job:

- gives a multi-step operation a useful domain name;
- isolates a coherent responsibility or a distinct level of abstraction;
- removes distracting detail from a caller so its main flow becomes easier to follow;
- captures logic that has a clear, independently testable contract;
- removes genuinely shared behavior that has the same meaning and is likely to change together.

Prefer one helper per cohesive domain operation. Extract helpers for the meaningful operations the task explicitly requests (e.g., subtotal, discount, tax calculations). Do not split intermediate arithmetic or derived values (e.g., "taxable amount," "running total") into additional helpers unless they have independent domain meaning, non-trivial complexity, genuine reuse, or a separately testable contract. Keep simple follow-on calculations inline in the operation that owns them.

When extracting helpers for a multi-step calculation, make the entry point a clear orchestration that calls each helper in sequence. The main function should read like an outline: call helper A, call helper B, call helper C, combine results. The helper calls return their own operation results; the entry point performs downstream calculations and final assembly. Avoid leaving loops or detailed calculation logic in the entry point.

Keep code inline when extraction would only create a forwarding wrapper, hide a simple expression, force readers to jump between locations, or introduce a name that adds no information. A helper for a single arithmetic expression or trivial derivation is not justified.

**Do not use an arbitrary line limit as an extraction rule.** A longer function can be easy to read when its steps form one clear sequence. A short function can be hard to understand when it hides important behavior behind vague names or unnecessary indirection. Optimize for cognitive load and cohesion, not a target line count.

A useful high-level function often reads like a short outline: validate input, calculate a result, persist it, return it. Details can live in named helpers when those helpers represent real operations.

## Names and intent

- Prefer specific names that describe domain concepts and observable behavior.
- Name booleans as questions or states (is_valid, has_access, should_retry) and actions as verbs.
- Avoid vague names such as data, value, manager, handler, process, or helper when a domain-specific name is available.
- Avoid abbreviations unless they are established in the codebase or universally understood.
- Do not encode implementation details in names when the name should describe the responsibility.

A reader should not need to inspect a function merely to discover what a clearly named call is intended to do.

## Control flow

- Prefer straightforward, visible control flow.
- Reduce nesting when guard clauses or early returns make the happy path easier to follow.
- Keep related conditions together and make important branches explicit.
- Avoid clever expressions, deeply nested ternaries, dense chaining, and compressed one-liners when they make behavior harder to scan.
- Do not split a simple linear sequence into many tiny functions merely to make the main function look short.
- Keep error handling close to the operation that can fail, while preserving the project's established error model.

## Abstractions and reuse

An abstraction must earn its place by making a real concept, variation, boundary, or repeated responsibility easier to understand or change.

Before introducing a class, interface, generic helper, wrapper, factory, strategy, builder, or additional layer, ask:

- Does this represent a concept that exists in the problem domain?
- Does it remove meaningful duplication or isolate a real change boundary?
- Does it simplify the callers, or does it merely move complexity elsewhere?
- Is the indirection worth the extra navigation and concepts a maintainer must learn?

Prefer the simplest design that meets current requirements. Do not build speculative extension points for hypothetical future needs. Do not add an interface solely to mock one implementation in a unit test.

Apply DRY to shared meaning, not just similar syntax. Two blocks that look alike but represent different business rules may be clearer when kept separate. Avoid premature generalization, configuration-heavy helpers, and abstractions with only one trivial forwarding implementation.

Reuse existing project primitives when they already express the concept. Do not introduce a new mini-framework for a local problem.

## Comments and formatting

- Use formatting and whitespace to reveal structure, not to decorate it.
- Comments should explain why a non-obvious decision exists, a constraint that is not visible in code, or a surprising trade-off.
- Do not add comments that merely narrate each statement or repeat a clear function name.
- Prefer removing confusing code over adding a comment that explains avoidable complexity.
- Keep related operations close together and separate distinct phases with meaningful structure.

## Review checklist

Before finishing, ask:

- Can a developer understand the main flow by reading the entry point?
- Do names communicate intent without requiring implementation details?
- Does each extracted function represent a meaningful operation or boundary?
- Does each helper return only the result of its own named operation?
- Did I avoid tuples or other multi-result returns that bundle separate sequential operations?
- Did I avoid arbitrary line-count rules and unnecessary forwarding wrappers?
- Did I extract helpers for the meaningful domain operations the task requests?
- Did I avoid creating helpers for intermediate arithmetic or derived values that lack independent domain meaning?
- Did I follow the task's requested extraction boundaries without adding extra helpers?
- Did I introduce any abstraction that costs more than it simplifies?
- Are similar-looking pieces actually the same rule, or merely coincidental duplication?
- Is the change limited to what the task requires?
- Did I preserve behavior and relevant public contracts?

When a trade-off is subjective, prefer the option that makes current behavior easiest to explain and change, and briefly document a consequential choice.
