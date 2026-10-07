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
python3 skill-benchmarks/benchmark.py run --case commit-trailer
```

Compare the same case with and without the skill:

```bash
python3 skill-benchmarks/benchmark.py run --case commit-trailer --mode both
```

Run every non-excluded benchmark and produce one aggregate report:

```bash
python3 skill-benchmarks/benchmark.py run-all --mode both
```

The `run-all` command runs every discovered case belonging to a non-excluded
skill in one run directory. The resulting report aggregates all runs and
classifies each case as `skill_helped`, `skill_harmed`,
`case_passes_without_skill`, or `case_fails_with_and_without_skill`.

Every live run writes a self-contained diagnostic report under
`skill-benchmarks/output/<run-id>/`:

```text
output/<run-id>/
├── report.md
├── report.json
└── cases/
    └── <case>/
        ├── input/
        │   ├── case/       # benchmark definition + fixture
        │   ├── skill/      # exact tested skill snapshot
        │   └── manifest.json
        ├── with-skill/
        │   └── agent/verifier/git artifacts
        └── without-skill/
            └── agent/verifier/git artifacts
```

`report.json` is intended for automated analysis; `report.md` is the human
summary. The run also stores the prompt, command, raw agent stdout/stderr,
verifier JSON, git status/log/diff/show, and exact skill/case snapshots. Run
benchmarks with `--mode both` when you want the report to show what the skill
changed relative to the same task without it.

To use a different output directory:

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

For useful diagnosis, checks should preferably include `expected`, `actual`, and
`evidence` fields in addition to `name` and `passed`. The report renders
these fields and the JSON preserves them for later analysis.

Example:

```json
{
  "name": "commit-message",
  "passed": false,
  "expected": "benchmark: update hello",
  "actual": "wrong message",
  "evidence": "git log -1 --pretty=%s"
}
```


## Exclusions

Benchmark exclusions are explicit in `config.json`. They are for skills whose
execution boundary or complexity makes them unsuitable for the generic runner.
Exclusions should be reviewed when the excluded skill changes.

Current exclusions:
- `manul-github-bot`
- `setup-environment`
- `wsl-ai-dev-autopilot-multi-device`
- `android-clean-architecture`
- `agent-orchestration`
- `review-strategy`

The runner does not add benchmarks to CI. The benchmark suite is intentionally
a developer-facing evaluation tool. Unit tests for the runner and adapters can
use mocks and are independent of live LLM execution.

## Adding a skill

Every new skill should ship with at least one benchmark case unless it is
explicitly excluded. When a skill changes materially, update its benchmark so
the benchmark continues to express the intended behavior.

Before considering a new or materially changed skill complete:

```bash
python3 skill-benchmarks/benchmark.py validate
python3 skill-benchmarks/benchmark.py run --skill <skill-name> --mode both
python3 -m unittest discover -s skill-benchmarks/tests
```

The third command tests the benchmark framework itself; it does not require an
LLM.
