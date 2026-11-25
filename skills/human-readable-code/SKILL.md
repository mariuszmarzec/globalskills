---
name: human-readable-code
description: Language-agnostic guidance for code that is easy for people to read, understand, maintain, and change. Use when writing, reviewing, or refactoring software in any language.
license: MIT
---

# Human-Readable Code

## Goal

Optimize code for the next person who has to understand, debug, review, or change it. Readability is a practical engineering property: a developer should be able to follow the intent and important decisions without reconstructing the author's thought process.

Prefer clear, direct code over cleverness, architectural ceremony, or reducing line count. Preserve behavior and public contracts that the task does not ask you to change.

---

### ⚠️ CRITICAL RULES FOR EXTRACTION TASKS (READ FIRST)

When a task asks you to extract specific domain operations (e.g., "subtotal, discount, tax"):

1. **Extract EXACTLY ONE helper per named operation** — no more, no less.
2. **Do NOT create helpers for intermediate values** (e.g., `taxable_amount`, `running_total`) — these are single arithmetic expressions; keep them inline.
3. **Do NOT combine distinct operations** (e.g., tax calculation + total assembly) into one helper — they are separate domain operations.
4. **The public entry point should call ONLY the requested helpers** plus simple inline arithmetic for assembly (subtraction, addition, rounding).

**Concrete anti-patterns this task commonly produces — DO NOT DO THESE:**
- ❌ `_calculate_taxable_amount` — one-line subtraction, keep inline
- ❌ `_calculate_tax_and_total` — combines tax + total, two operations
- ❌ `_calculate_line_subtotal` + `_calculate_subtotal` — one operation (subtotal), don't split
- ✅ `_calculate_tax(taxable_amount, tax_rate)` — pure tax calculation only
- ✅ `total = round(taxable_amount + tax, 2)` — simple assembly stays inline

If you find yourself creating a helper for a single arithmetic expression, STOP and inline it instead.

---

## Working approach

1. Read the surrounding code before editing. Follow established naming, formatting, module boundaries, and local conventions unless they are actively harmful to the requested change.
2. Identify the behavior being changed and the smallest relevant area of the codebase.
3. Make the intent visible in names, function boundaries, and control flow.
4. Keep the change scoped. Do not use a small task as an excuse to reorganize neighboring code.
5. Verify behavior with relevant existing tests and add focused tests when the change needs them.

**For extraction tasks:** When the task names specific domain operations to extract (e.g., "subtotal, discount, tax"), extract EXACTLY ONE helper per named operation. Do not create additional helpers for intermediate values, sub-steps of a single operation, or derived calculations. The public entry point should call ONLY the requested helpers plus simple inline arithmetic for assembly.

## Functions: small, cohesive, meaningful

Prefer functions with one coherent responsibility and a name that communicates the operation.

Extract a function when it does at least one meaningful job:

- gives a multi-step operation a useful domain name;
- isolates a coherent responsibility or a distinct level of abstraction;
- removes distracting detail from a caller so its main flow becomes easier to follow;
- captures logic that has a clear, independently testable contract;
- removes genuinely shared behavior that has the same meaning and is likely to change together.

Prefer one helper per cohesive domain operation. Extract helpers for the meaningful operations the task explicitly requests (e.g., subtotal, discount, tax calculations). Do not split intermediate arithmetic or derived values (e.g., "taxable amount," "running total") into additional helpers unless they have independent domain meaning, non-trivial complexity, genuine reuse, or a separately testable contract. Keep simple follow-on calculations inline in the operation that owns them.

**Concrete rule:** If a derived value is computed by a single arithmetic expression (subtraction, multiplication, addition, rounding) immediately after another helper's result, keep it inline. Do not create helpers for intermediate values like `_calculate_taxable_amount` or `_calculate_total` when they are one-line derivations.

**Do not combine separately requested or domain-distinct operations into a single helper** merely because their calculations are adjacent (e.g., tax calculation vs. assembling the final total). Each distinct domain operation deserves its own helper.

**Anti-patterns to avoid for this task:**
- ❌ Creating `_calculate_taxable_amount` — this is a one-line subtraction, keep it inline in the caller
- ❌ Creating `_calculate_tax_and_total` — this combines tax calculation with total assembly, two distinct operations
- ❌ Splitting the subtotal loop into `_calculate_line_subtotal` + `_calculate_subtotal` — the validation and summation are ONE cohesive domain operation (calculating the subtotal)
- ✅ Creating `_calculate_tax(taxable_amount, tax_rate)` — pure tax calculation only
- ✅ Keeping `total = round(taxable_amount + tax, 2)` inline in the orchestrator — simple assembly

### Illustrative example: extracting tax calculation

If the original code computes tax and total together:

```python
# Before (inline or combined)
taxable_amount = max(subtotal - discount, 0.0)
tax = round(taxable_amount * tax_rate, 2)
total = round(taxable_amount + tax, 2)
```

Extract a **pure tax calculation** helper only; keep total assembly inline:

```python
def _calculate_tax(taxable_amount, tax_rate):
    return round(taxable_amount * tax_rate, 2)

def create_invoice(items, discount_code=None, tax_rate=0.0):
    subtotal = _calculate_subtotal(items)
    discount = _calculate_discount(subtotal, discount_code)
    taxable_amount = max(subtotal - discount, 0.0)
    tax = _calculate_tax(taxable_amount, tax_rate)
    total = round(taxable_amount + tax, 2)  # simple assembly stays inline
    return {"subtotal": subtotal, "discount": discount, "tax": tax, "total": total}
```

Do NOT create a combined helper:

```python
# ❌ Wrong: combines tax calculation with total assembly
def _calculate_tax_and_total(taxable_amount, tax_rate):
    tax = round(taxable_amount * tax_rate, 2)
    total = round(taxable_amount + tax, 2)
    return tax, total
```

When extracting helpers for a multi-step calculation, make the entry point a clear orchestration that calls each helper in sequence. The main function should read like an outline: call helper A, call helper B, call helper C, combine results. Avoid leaving loops or detailed calculation logic in the entry point.

Keep code inline when extraction would only create a forwarding wrapper, hide a simple expression, force readers to jump between locations, or introduce a name that adds no information. A helper for a single arithmetic expression or trivial derivation is not justified.

**Do not use an arbitrary line limit as an extraction rule.** A longer function can be easy to read when its steps form one clear sequence. A short function can be hard to understand when it hides important behavior behind vague names or unnecessary indirection. Optimize for cognitive load and cohesion, not a target line count.

A useful high-level function often reads like a short outline: validate input, calculate a result, persist it, return it. Details can live in named helpers when those helpers represent real operations.

## Names and intent

- Prefer specific names that describe domain concepts and observable behavior.
- Name booleans as questions or states (is_valid, has_access, should_retry) and actions as verbs.
- Avoid vague names such as data, value, manager, handler, process, or helper when a domain-specific name is available.
- Avoid abbreviations unless they are established in the codebase or universally understood in the domain.
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
- Did I avoid arbitrary line-count rules and unnecessary forwarding wrappers?
- Did I extract helpers for the meaningful domain operations the task requests?
- Did I avoid creating helpers for intermediate arithmetic or derived values that lack independent domain meaning?
- **Did I create EXACTLY ONE helper per explicitly requested domain operation (no more, no less)?**
- **Did I keep simple assembly arithmetic (subtraction, addition, rounding) inline in the orchestrator?**
- Did I follow the task's requested extraction boundaries without adding extra helpers?
- Did I introduce any abstraction that costs more than it simplifies?
- Are similar-looking pieces actually the same rule, or merely coincidental duplication?
- Is the change limited to what the task requires?
- Did I preserve behavior and relevant public contracts?

When a trade-off is subjective, prefer the option that makes current behavior easiest to explain and change, and briefly document a consequential choice.
