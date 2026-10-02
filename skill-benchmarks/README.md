# Skill Benchmarks

Behavioral benchmarks for skills in `globalskills`.

The benchmark runner executes a real agent against a fresh fixture repository,
stages the skill under test into project-local `.opencode/skills/`, and checks
the resulting repository with a deterministic verifier. OpenCode is the current
backend, but the runner uses an adapter interface so the backend can be replaced
without changing benchmark cases.

## Run

List skills, exclusions, and cases:

```bash
python3 skill-benchmarks/benchmark.py list
```

Run a case with OpenCode:

```bash
python3 skill-benchmarks/benchmark.py run --case commit-trailer --model litellm/big-pickle
```

Compare the same case with and without the skill:

```bash
python3 skill-benchmarks/benchmark.py run --case commit-trailer --mode both --model litellm/big-pickle
```

Save stdout/stderr/verifier artifacts:

```bash
python3 skill-benchmarks/benchmark.py run --case commit-trailer \
  --artifacts /tmp/skill-benchmarks
```

The OpenCode adapter uses `opencode run` in non-interactive mode with an
isolated working directory. This matches OpenCode's scripting/automation mode
and its project-local skill precedence.

## Case layout

Each case lives under:

```text
skill-benchmarks/cases/<skill>/<case>/
├── case.json
├── prompt.md
├── verify.sh
└── fixture/
```

`verify.sh` (or `verify.py`) must emit JSON with a top-level `passed` boolean.
Individual checks should be deterministic and inspect the resulting workspace,
not the model's self-reported answer.

## Exclusions

Benchmark exclusions are explicit in `config.json`. They are for skills whose
execution boundary or complexity makes them unsuitable for the generic runner.
Exclusions should be reviewed when the excluded skill changes.

Current exclusions:
- `manul-github-bot`
- `setup-environment`

The runner does not add benchmarks to CI. The benchmark suite is intentionally
a developer-facing evaluation tool. Unit tests for the runner and adapters can
use mocks and are independent of live LLM execution.

## Adding a skill

Every new skill should ship with at least one benchmark case unless it is
explicitly excluded. When a skill changes materially, update its benchmark so
the benchmark continues to express the intended behavior.

Before merging a new skill locally:

```bash
python3 skill-benchmarks/benchmark.py run --skill <skill-name> --mode both
python3 -m unittest discover -s skill-benchmarks/tests
```

The second command tests the benchmark framework itself; it does not require an
LLM.
