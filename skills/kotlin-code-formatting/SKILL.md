---
name: kotlin-code-formatting
description: Code formatting and style rules for Kotlin. Use when writing, editing, or reviewing Kotlin code in an Android/Gradle project that enforces these rules via detekt (config/detekt/detekt.yml) and Kotlin official style. Run ./gradlew detekt to verify.
license: MIT
---

# Kotlin Code Formatting

Formatting and style rules extracted from the CheatDay Android project (`config/detekt/detekt.yml`, `gradle.properties`, `.idea/codeStyles/Project.xml`). These rules are enforced by `./gradlew detekt` (`maxIssues: 0`, so any finding fails the build).

**Verify:** after any Kotlin change, run `./gradlew detekt` and fix all findings until it passes with zero issues.

## Style basis

- Kotlin **official** code style (`kotlin.code.style=official`, `CODE_STYLE_DEFAULTS=KOTLIN_OFFICIAL`).
- Indentation: 4 spaces.
- Max line length: **150** characters (`MaximumLineLength`, `MaxLineLength`). Long argument/parameter lists may wrap at 120.
- UTF-8, LF line endings, final newline at end of every file.

## Formatting rules (detekt `formatting`, active)

All `autoCorrect: true` — apply them manually when editing.

- **Line breaks / wrapping**
  - Wrap chained calls: continuation lines of a chain start with the operator (`.`, `?., ::`) — `ChainWrapping`.
  - No blank line before `}` (`NoBlankLineBeforeRbrace`), no more than one consecutive blank line (`NoConsecutiveBlankLines`).
  - `if`/`else` each on their own line when multiline (`MultiLineIfElse`); no line break directly after `else` (`NoLineBreakAfterElse`).
  - No line break before `=` (`NoLineBreakBeforeAssignment`).
  - Wrap parameter lists with 4-space continuation indent, keep lines ≤ 120 chars (`ParameterListWrapping`).
  - If a function signature doesn't fit on one line, put each parameter on its own line.
- **Spacing**
  - Single space around `:` (unless `::`), `,`, `{`, `}`, keywords (`if`, `else`, `for`, `while`, `return`, etc.), binary operators (`+`, `-`, `==`, `&&`, `?:`, etc.), `(`/`)`, and range operators (`..`, `..<`).
  - Single space around dots in qualified names / calls (`SpacingAroundDot`).
  - No multiple spaces (`NoMultipleSpaces`), no trailing whitespace (`NoTrailingSpaces`).
  - Comments: single space after `//` (`CommentSpacing`).
  - String templates: single space not needed, but no redundant braces — `"$name"` not `"${name}"` where possible (`StringTemplate`).
- **Semicolons**: never use them (`NoSemicolons`).
- **Imports**
  - No unused imports (`NoUnusedImports`).
  - No wildcard imports (`NoWildcardImports`, style rule `WildcardImport`).
- **Modifiers**: order per Kotlin official convention, e.g. `public`, `internal`, `protected`, `private` before `open`/`abstract`/`suspend`/`inline`; `override` first (`ModifierOrdering` / `ModifierOrder`).
- **Return types**: omit explicit `Unit` return type (`NoUnitReturn`).
- **Files**: filename must match the top-level declaration (`MatchingDeclarationName`, must be first), package name matches directory structure (`PackageName`), no empty class bodies (`NoEmptyClassBody`).

## Style rules (detekt `style`)

- Use `== null` / `!= null`, never `.equals(null)` (`EqualsNullCall`).
- No `FIXME:`, `STOPSHIP:`, or `TODO:` comments (`ForbiddenComment`).
- Constants: use `const val` when the value is a compile-time constant (`MayBeConst`).
- Use `val` unless reassignment is required (`VarCouldBeVal`).
- Prefer safe cast `as?` over plain `as` unless the cast must not fail (`SafeCast`).
- Keep function `return` count ≤ 2 (`ReturnCount`, guard clauses excluded via `excludeGuardClauses: false`), throw count ≤ 2 (`ThrowsCount`).
- No more than 1 jump statement in a loop (`LoopWithTooManyJumpStatements`).
- Don't call `toString()`/`let`/`apply` on a non-null receiver unnecessarily (`UselessCallOnNotNull`, `UnnecessaryApply`).
- Don't use `private` visibility on top-level declarations in this app module; don't make abstract classes without abstract members (`UnnecessaryAbstractClass`, `UtilityClassWithPublicConstructor`).
- Magic numbers: only `-1`, `0`, `1`, `2` allowed bare; constants, property declarations, named arguments, and extension functions are exempt (`MagicNumber`).
- No unused private classes/members (`UnusedPrivateClass`, `UnusedPrivateMember`).
- Serializable classes declare `serialVersionUID` (`SerialVersionUIDInSerializableClass`).
- Don't shadow/break naming for protected members in final classes (`ProtectedMemberInFinalClass`), keep nested classes visible (`NestedClassesVisibility`), abstract keyword optional (`OptionalAbstractKeyword`).

## Naming conventions

- Classes: `PascalCase` — `[A-Z][a-zA-Z0-9]*`.
- Functions and variables: `camelCase` — `[a-z][A-Za-z0-9]*` (private variables may be prefixed with `_`).
- Constants (top-level `const val` or companion): `UPPER_SNAKE_CASE` — `[A-Z][_A-Z0-9]*`.
- Packages: lowercase `[a-z]+(\.[a-z][A-Za-z0-9]*)*`.
- A member may not share its enclosing class's name (`MemberNameEqualsClassName`).
- `@Composable` functions are exempt from the function-naming pattern check.

## Complexity limits

Keep within these thresholds (all enforced by detekt):

- `ComplexCondition` ≤ 4 conditions
- `ComplexMethod` ≤ 15 branches
- `LongMethod` ≤ 60 lines (exempt `@Composable`)
- `LongParameterList` ≤ 6 function params / ≤ 12 constructor params
- `NestedBlockDepth` ≤ 4
- `LargeClass` ≤ 600 lines
- `TooManyFunctions` ≤ 31 per file/class/interface/object

## Disabled rules (do not worry about these)

These detekt rules are disabled in this project — do not "fix" code to satisfy them, and do not add them back:

- `ImportOrdering` — do not reorder imports.
- `Indentation` / `ArgumentListWrapping` / `NoEmptyFirstLineInMethodBlock` / `AnnotationOnSeparateLine` / `AnnotationSpacing` / `EnumEntryNameCase`.
- `SpacingAroundAngleBrackets` / `SpacingAroundDoubleColon` / `SpacingAroundUnaryOperator`.
- `StringLiteralDuplication` / `MagicNumber` test files / `ForbiddenComment` allowed patterns.

## Checking the style

```bash
./gradlew detekt
```

Pass criteria: zero findings (`maxIssues: 0`). Fix any reported issue and re-run until green. `detektPlugins(libs.detekt.formatting)` is configured, so formatting rules auto-correct when run with `autoCorrect: true`.
