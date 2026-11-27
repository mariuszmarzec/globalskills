#!/usr/bin/env python3
import hashlib, json, os
from pathlib import Path

# Load run metadata from each run dir to build the runs array
runs = []
for run_dir in sorted(Path('benchmark-evidence/runs').iterdir()):
    if not run_dir.is_dir(): continue
    meta = json.load(open(run_dir / 'run-metadata.json'))
    runs.append({
        "skill": meta['skill'],
        "mode": meta['mode'],
        "case": meta['case'],
        "timestamp": meta['timestamp'],
        "run_dir": meta['run_dir'],
        "overall_passed": meta['overall_passed'],
        "agent_returncode": meta['agent_returncode'],
        "verifier_returncode": meta['verifier_returncode'],
        "native_skill_activation_check": meta['native_skill_activation_check'],
    })

# Compute all file checksums.
# The top-level manifest.json is EXCLUDED: a file cannot contain its own hash.
# Per-run input manifest.json files (input snapshots) ARE included.
checksums = {}
for root, dirs, files in os.walk('benchmark-evidence/runs'):
    for f in files:
        p = os.path.join(root, f)
        if p == 'benchmark-evidence/runs/manifest.json':
            continue
        h = hashlib.sha256(open(p, 'rb').read()).hexdigest()
        checksums[p] = h

manifest = {
    "schema_version": 1,
    "source_sha": "e3d67db12fed63a3d7f0f5d3d135c22c11db8148",
    "source_pr": "https://github.com/mariuszmarzec/globalskills/pull/172",
    "benchmark_date": "2026-11-27",
    "benchmark_config": "skill-benchmarks/config.json",
    "adapter": "opencode",
    "model": "litellm/freeLLMAPI (OpenCode default)",
    "runs": runs,
    "note": "Only one invocation per skill was recovered (4 runs total). The prior README claimed a second invocation (Run 2) for testable-design without-skill showing PASS; no artifacts for such a second invocation exist in the permitted workspace boundary and it cannot be recovered. Per the evidence recovery policy, no rerun was performed. The single testable-design without-skill run is correctly recorded as FAIL (permission-denied attempted invocation).",
    "artifact_checksums": checksums,
    "redaction_procedure": "benchmark-evidence/redaction.py",
    "total_files": len(checksums),
    "total_runs": len(runs),
}

Path('benchmark-evidence/runs/manifest.json').write_text(json.dumps(manifest, indent=2))
print(f"Manifest written with {len(checksums)} file checksums and {len(runs)} runs")