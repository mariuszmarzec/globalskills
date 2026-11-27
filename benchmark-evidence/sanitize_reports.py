#!/usr/bin/env python3
import re
from pathlib import Path

ANSI_ESCAPE = re.compile(r'\x1b\[[0-9;]*m')
HOME_PATH = re.compile(r'/home/marzec([^\s"\']*)')
USERNAME = re.compile(r'\bmarzec\b')
TMP_WORKSPACE = re.compile(r'(/tmp/skill-bench-[^/\s]+)-[a-z0-9_]+(/workspace)')

def sanitize(text):
    text = ANSI_ESCAPE.sub('', text)
    text = USERNAME.sub('<user>', text)
    text = HOME_PATH.sub(r'/home/<user>\1', text)
    text = TMP_WORKSPACE.sub(r'\1-<run>\2', text)
    return text

runs = [
    ('20261127T185653037682Z-human-readable-code-both', 'human-readable-code'),
    ('20261127T190339527239Z-testable-design-both', 'testable-design'),
]

for run_dir_name, skill in runs:
    run_dir = Path(f'skill-benchmarks/output/{run_dir_name}')
    ts = run_dir_name.split('-')[0]
    for mode in ['with-skill', 'without-skill']:
        out_dir = Path(f'/tmp/evidence-staging/{skill}_{mode}_{ts}')
        out_dir.mkdir(parents=True, exist_ok=True)
        for f in ['report.json', 'report.md']:
            src = run_dir / f
            if src.exists():
                content = src.read_text(encoding='utf-8', errors='replace')
                sanitized = sanitize(content)
                dst = out_dir / f
                dst.write_text(sanitized, encoding='utf-8')
                print(f"  sanitized {skill}_{mode}_{ts}/{f}")
            else:
                print(f"  MISSING {skill}_{mode}_{ts}/{f}")