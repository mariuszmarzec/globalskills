# Redaction Procedure for Benchmark Evidence Artifacts

This document describes the deterministic redaction procedure applied to all benchmark evidence artifacts published in `benchmark-evidence/runs/`.

## Purpose

Raw benchmark artifacts contain:
- ANSI escape sequences from terminal output
- Local usernames (`marzec`) in file paths and `ls -la` listings
- Absolute home directory paths (`/home/marzec/...`)
- Ephemeral per-run workspace paths (`/tmp/skill-bench-<case>-<random>/workspace`)

These are sanitized to protect privacy while preserving the evidentiary value needed to distinguish:
- **Successful skill invocation** (`→ Skill "skill-id"` followed by continued execution)
- **Denied skill invocation** (`✗ Skill "skill-id" failed` + `Error: Permission denied: skill`)
- **No skill invocation** (no `Skill` lines in stderr)

## Redaction Script

The canonical redaction logic is implemented in `benchmark-evidence/redaction.py`. It is a pure Python 3 script with no external dependencies.

### Redaction Rules (applied in order)

1. **Strip ANSI escape sequences**
   - Pattern: `\x1b\[[0-9;]*m`
   - Rationale: Terminal color/style codes are not part of the logical trace.

2. **Replace username `marzec` → `<user>`**
   - Pattern: `\bmarzec\b` (word boundaries)
   - Applied to all text files.

3. **Replace home directory paths**
   - Pattern: `/home/marzec` → `/home/<user>`
   - Preserves path structure after the home directory.

4. **Normalize ephemeral workspace paths**
   - Pattern: `/tmp/skill-bench-<case>-<random>/workspace`
   - Replacement: `/tmp/skill-bench-<case>-<run>/workspace`
   - Where `<run>` is the timestamp prefix from the run directory name (e.g., `20261127T185653037682Z`).
   - Rationale: The random suffix is ephemeral and non-reproducible; the timestamp is stable and traceable to the run.

5. **Condense `ls -la ~/.globalskills/skills/` listing (testable-design without-skill only)**
   - The raw stderr contains a full directory listing of `~/.globalskills/skills/` showing all installed skills.
   - Only the line containing `testable-design` is retained (with username redacted).
   - Other skill directory lines are replaced with `[other skill directories redacted]`.
   - Rationale: The presence of `testable-design` in the listing is the key evidence that the skill was visible to OpenCode and the model attempted to load it per the prompt. The full skill list is not needed for the conclusion.

## Files NOT Redacted

- **Prompt/task text** (`prompt.txt`, `command.txt`): These are the test setup and contain no secrets.
- **Git diffs** (`git-diff.txt`, `git-log.txt`, etc.): Contain only repository-relative paths and code changes.
- **Manifest JSON** (`manifest.json`): Machine metadata with SHA256 checksums of input files.
- **Verifier output** (`verifier.json`, `report.json`, `report.md`): Structured results with no secrets.
- **run-metadata.json**: Per-run summary metadata.

## Deterministic Verification

To verify the redaction was applied correctly:

```bash
# For any sanitized file in benchmark-evidence/runs/<run_dir>/
python3 benchmark-evidence/redaction.py \
  <original-run-dir> \
  <output-dir>

# Then compare checksums with benchmark-evidence/runs/manifest.json
sha256sum <output-dir>/<file>
```

The redaction script is idempotent: running it on already-sanitized output produces identical output.

## Checksums

All published artifact checksums are recorded in `benchmark-evidence/runs/manifest.json` under `artifact_checksums`. The manifest itself is also checksummed implicitly by Git.