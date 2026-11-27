# Behavioral Skill Benchmark Evidence

**Source SHA:** e3d67db12fed63a3d7f0f5d3d135c22c11db8148  
**Canonical PR URL:** https://github.com/mariuszmarzec/globalskills/pull/172  
**Benchmark Date:** 2026-11-27  
**Evidence PR:** https://github.com/mariuszmarzec/globalskills/pull/182  
**Evidence Branch:** evidence/benchmark-run-e3d67db (head: 0dd853d4fbcf47225b7fa135b58ab71756042c01)

## Summary

This document presents auditable, sanitized evidence from running behavioral skill benchmarks for two skills against the source PR #172 at commit e3d67db:

- `human-readable-code` (invoice-refactor case)
- `testable-design` (registration-boundary case)

Each skill was run in both modes **once** (4 runs total):
- `with-skill`: The skill is enabled in the OpenCode configuration (permission: allow)
- `without-skill`: The skill is denied in the OpenCode configuration (permission: deny)

> **Important:** The prior version of this README claimed a second invocation (Run 2) for testable-design without-skill showing PASS. **No artifacts for a second invocation exist** in the permitted workspace boundary and it cannot be recovered. Per the evidence recovery policy, no rerun was performed. This evidence package contains only the 4 runs that were actually executed and whose artifacts were saved.

## Pass/Fail Results (4 Recovered Runs)

| Skill | Mode | Result | Native Skill Activation |
|-------|------|--------|-------------------------|
| human-readable-code | with-skill | ✅ PASS (8/8) | ✅ Observed (`→ Skill "human-readable-code"`) |
| human-readable-code | without-skill | ✅ PASS (8/8) | ✅ No invocation (no Skill lines in stderr) |
| testable-design | with-skill | ✅ PASS (8/8) | ✅ Observed (`→ Skill "testable-design"`) |
| testable-design | without-skill | ❌ FAIL (7/8) | ❌ Denied invocation (`✗ Skill "testable-design" failed`) |

## Detailed Results

### human-readable-code (invoice-refactor case)

**With-skill mode — PASS (8/8)**
- ✅ valid-python
- ✅ public-api-preserved
- ✅ meaningful-calculation-helpers
- ✅ tax-helper-returns-one-result
- ✅ entry-point-orchestrates-steps
- ✅ no-unneeded-production-types
- ✅ existing-behavior-tests
- ✅ native-skill-activation (successful invocation observed)

**Without-skill mode — PASS (8/8)**
- ✅ valid-python
- ✅ public-api-preserved
- ✅ meaningful-calculation-helpers
- ✅ tax-helper-returns-one-result
- ✅ entry-point-orchestrates-steps
- ✅ no-unneeded-production-types
- ✅ existing-behavior-tests
- ✅ native-skill-activation (no invocation observed)

### testable-design (registration-boundary case)

**With-skill mode — PASS (8/8)**
- ✅ valid-python
- ✅ explicit-pure-policy-helper
- ✅ validation-independent-of-effects
- ✅ entry-point-orchestrates-boundaries
- ✅ direct-helper-tests
- ✅ no-mock-heavy-test-setup
- ✅ registration-tests
- ✅ native-skill-activation (successful invocation observed)

**Without-skill mode — FAIL (7/8)**
- ✅ valid-python
- ✅ explicit-pure-policy-helper
- ✅ validation-independent-of-effects
- ✅ entry-point-orchestrates-boundaries
- ✅ direct-helper-tests
- ✅ no-mock-heavy-test-setup
- ✅ registration-tests
- ❌ native-skill-activation (DENIED invocation observed)

## Root Cause Analysis: testable-design without-skill FAIL

The failure is **not** non-deterministic behavior. The single recovered run for testable-design without-skill shows a **permission-denied attempted invocation**, which constitutes a FAIL per the evidence criteria ("permission-denied attempted invocation is a failure").

### Evidence from sanitized stderr (benchmark-evidence/runs/testable-design_without-skill_20261127T190339527239Z/stderr.txt):

```
> orchestrator · freeLLMAPI
→ ls -la /home/<user>/.globalskills/skills/ 2>/dev/null || echo "No globalskills directory"
... (listing showing testable-design directory exists) ...
> orchestrator · freeLLMAPI
✗ Skill "testable-design" failed
Error: Permission denied: skill
> orchestrator · freeLLMAPI
→ Edit registration.py
...
```

### Why this is a FAIL:

1. The `registration-boundary` prompt instructs: "If `testable-design` is listed, load it with the native `skill` tool using ID `testable-design` before changing any files... If it is not listed (the without-skill baseline), do not attempt to load it."

2. In without-skill mode, the benchmark sets permission to "deny" for the skill but does **not** hide it from OpenCode's global skills directory (`~/.globalskills/skills/`).

3. The model sees `testable-design` in available-skills (confirmed by the `ls -la` output in stderr) and attempts to load it per the prompt.

4. The load is denied, producing stderr containing `✗ Skill "testable-design" failed` + `Error: Permission denied: skill`.

5. The benchmark's `skill_activation_check` pattern-matches `Skill "testable-design"` in stderr, which matches **both** successful (`→ Skill "testable-design"`) and failed (`✗ Skill "testable-design" failed`) invocations.

6. Since the pattern is found in without-skill mode, the check fails.

### Why this is NOT "non-deterministic":

- Only **one** testable-design without-skill run was recovered.
- That run **did** attempt invocation (denied).
- The prior README claimed a second run where the model "correctly did NOT attempt to load the skill." **No artifacts for such a second run exist.** The claim was based on a misinterpretation of the benchmark harness's "runs: 2" (which counts the two modes within a single invocation, not two separate invocations).

## Artifact Tree

```
benchmark-evidence/
├── README.md                      # This file
├── redaction.py                   # Deterministic redaction script
├── redaction-procedure.md         # Documented redaction procedure
└── runs/
    ├── manifest.json              # Top-level manifest with all checksums
    ├── human-readable-code_with-skill_20261127T185653037682Z/
    │   ├── report.json            # Per-mode JSON report
    │   ├── report.md              # Full human-readable report (both modes)
    │   ├── run-metadata.json      # Per-run metadata + checksums
    │   ├── prompt.txt             # Full prompt sent to model
    │   ├── command.txt            # Sanitized command (opencode run --auto + prompt)
    │   ├── git-diff.txt           # Git diff of changes made
    │   ├── git-log.txt            # Git log (baseline commit)
    │   ├── git-show.txt           # Git show of baseline
    │   ├── git-status.txt         # Git status before run
    │   ├── verifier.json          # Raw verifier output
    │   ├── stderr.txt             # Sanitized stderr (activation proof)
    │   ├── stdout.txt             # Sanitized stdout (model narration)
    │   └── manifest.json          # Input snapshot checksums (prompt/verifier/skill)
    ├── human-readable-code_without-skill_20261127T185653037682Z/
    │   ├── ... (same structure)
    ├── testable-design_with-skill_20261127T190339527239Z/
    │   ├── ... (same structure)
    └── testable-design_without-skill_20261127T190339527239Z/
        ├── ... (same structure)
```

## SHA/Checksums

All artifact SHA256 checksums are recorded in `benchmark-evidence/runs/manifest.json` under `artifact_checksums`. Key checksums for activation evidence files:

| Run | stderr.txt SHA256 | report.json SHA256 | run-metadata.json SHA256 |
|-----|-------------------|---------------------|---------------------------|
| human-readable-code / with-skill | 2db4ce33c95a43b9b241c2608814b77adbb9ddd75a679ab1711da06cf4af0a42 | b54cccb2464f8d3c38fafff45adb715febd263fec00fad23e75990da557f580b | a4c8a5d93c9d3340a6350866ff68f50aa4370f5d40aa2b1586c9535addd9698d |
| human-readable-code / without-skill | 94c5d3068130215b3bd7ef9a997efe77ebc4a97a688574d64597b21413dcbe98 | 2dbe28ae42847abc673d9a91cb98ade807e0f9545c02412809802c1d87b1333e | 3baaea43318bed2f525dee6206b359795a0859c7ff0c1973a1207ec4dc85f62a |
| testable-design / with-skill | 580ece041704cc05d097568cc3a171afa326329c1018840ccba51eaa03e62618 | d9b13d0289838ee167b7de14f58b814ed43b91f5f0067963247c0c50bda0c4e8 | 3212598cd55e6611824d508ff08046e654cccaead32396a1e88f4f7265850e78 |
| testable-design / without-skill | 595935a35fed000b8733fe8217552fe39121aba5b83b8f4ef10dc7e63adcc461 | 538f0e34498d35d1378648059c492f0a03db0d439ef428041221faeb0e596643 | 4acc793a0edf163131d7827c4a1022adfe9b9e4e89b60215044840a5a6427229 |

## Per-Run Source SHA and Command/Exit Status

Each run's `run-metadata.json` contains:
- `source_sha`: e3d67db12fed63a3d7f0f5d3d135c22c11db8148 (globalskills PR #172 head)
- `agent_returncode`: 0 (all runs)
- `verifier_returncode`: 0 (PASS runs), 1 (FAIL run)
- `native_skill_activation_check`: {passed, expected, actual, evidence_file}

The input snapshots (prompt.md, verify.py, SKILL.md) in each run's `manifest.json` have checksums matching the worktree files at the source SHA (line endings note: worktree files have CRLF, git blobs have LF; manifest records worktree bytes used).

## Redaction Procedure

See `benchmark-evidence/redaction-procedure.md` for the full documented procedure. In summary:

1. Strip ANSI escape sequences
2. Replace username `marzec` → `<user>`
3. Replace `/home/marzec/...` → `/home/<user>/...`
4. Normalize `/tmp/skill-bench-<case>-<random>/workspace` → `/tmp/skill-bench-<case>-<run>/workspace`
5. For testable-design without-skill: condense `ls -la` listing to only the `testable-design` line

The script `benchmark-evidence/redaction.py` is deterministic and idempotent.

## How to Reproduce / Verify the Evidence

### 1. Verify Artifact Integrity
```bash
# From repository root (keys are repo-root-relative)
sha256sum -c <(jq -r '.artifact_checksums | to_entries[] | "\(.value)  \(.key)"' benchmark-evidence/runs/manifest.json)
```

### 2. Verify Native Skill Activation (from sanitized stderr)
```bash
# With-skill: should show "→ Skill <id>" (U+2192)
grep "→ Skill" human-readable-code_with-skill_20261127T185653037682Z/stderr.txt
grep "→ Skill" testable-design_with-skill_20261127T190339527239Z/stderr.txt

# Without-skill (human-readable-code): should show NO Skill lines
grep "Skill" human-readable-code_without-skill_20261127T185653037682Z/stderr.txt

# Without-skill (testable-design): should show "✗ Skill failed" + "Permission denied"
grep "Skill" testable-design_without-skill_20261127T190339527239Z/stderr.txt
```

### 3. Verify Per-Run Results
```bash
jq '.results[0] | {mode, passed, activation: .skill_activation.passed}' \
  human-readable-code_with-skill_20261127T185653037682Z/report.json
jq '.results[0] | {mode, passed, activation: .skill_activation.passed}' \
  human-readable-code_without-skill_20261127T185653037682Z/report.json
jq '.results[0] | {mode, passed, activation: .skill_activation.passed}' \
  testable-design_with-skill_20261127T190339527239Z/report.json
jq '.results[0] | {mode, passed, activation: .skill_activation.passed}' \
  testable-design_without-skill_20261127T190339527239Z/report.json
```

### 4. Verify Input Snapshots Match Source SHA
```bash
# At the globalskills repo root:
git show e3d67db:skill-benchmarks/cases/human-readable-code/invoice-refactor/prompt.md | sha256sum
# Compare with benchmark-evidence/runs/human-readable-code_with-skill_20261127T185653037682Z/manifest.json "prompt_sha256"
# (The per-run manifest.json contains input snapshots; note: line endings may differ — manifest records worktree bytes used at runtime)
```

### 5. Re-run Benchmark (if desired, with same config)
```bash
cd skill-benchmarks
python3 benchmark.py --selector human-readable-code --mode both
python3 benchmark.py --selector testable-design --mode both
# Uses config.json, adapter=opencode, model=OpenCode default (litellm/freeLLMAPI)
# Output will appear in skill-benchmarks/output/ with new timestamped directories
```

## Recoverable vs. Missing Runs

| Skill | Mode | Runs Recovered | Status |
|-------|------|----------------|--------|
| human-readable-code | with-skill | 1 | ✅ Complete |
| human-readable-code | without-skill | 1 | ✅ Complete |
| testable-design | with-skill | 1 | ✅ Complete |
| testable-design | without-skill | 1 | ✅ Complete (FAIL) |
| **Any skill** | **any mode** | **Run 2 (claimed)** | ❌ **No artifacts — cannot be recovered** |

**Conclusion:** The evidence package contains complete, verifiable artifacts for the 4 runs that were actually executed. The claimed "Run 2" second invocation does not exist in the recoverable artifact set. No rerun was performed per policy. The testable-design without-skill run is correctly recorded as a single FAIL due to a permission-denied attempted skill invocation.