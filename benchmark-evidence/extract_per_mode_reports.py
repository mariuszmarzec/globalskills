#!/usr/bin/env python3
"""Extract per-mode reports from skill-level 'both' reports."""
import json
import re
from pathlib import Path

# Load the original skill-level reports
hr_report = json.load(open('skill-benchmarks/output/20261127T185653037682Z-human-readable-code-both/report.json'))
td_report = json.load(open('skill-benchmarks/output/20261127T190339527239Z-testable-design-both/report.json'))

# Sanitization (same as before)
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

# Process human-readable-code
hr_ts = '20261127T185653037682Z'
for res in hr_report['results']:
    mode = res['mode']  # 'with-skill' or 'without-skill'
    out_dir = Path(f'/tmp/evidence-staging/human-readable-code_{mode}_{hr_ts}')
    # Create per-mode report.json
    per_mode_report = {
        'schema_version': hr_report['schema_version'],
        'benchmark': hr_report['benchmark'],
        'summary': {
            'runs': 1,
            'passed_runs': 1 if res['passed'] else 0,
            'failed_runs': 0 if res['passed'] else 1,
            'cases': 1,
            'skills': 1,
        },
        'evaluation': hr_report['evaluation'],
        'impact': hr_report['impact'],
        'comparisons': hr_report['comparisons'],
        'results': [res],
    }
    sanitized = json.dumps(per_mode_report, indent=2)
    sanitized = sanitize(sanitized)
    (out_dir / 'report.json').write_text(sanitized, encoding='utf-8')
    print(f"  wrote {out_dir.name}/report.json (mode={mode})")

# Process testable-design
td_ts = '20261127T190339527239Z'
for res in td_report['results']:
    mode = res['mode']
    out_dir = Path(f'/tmp/evidence-staging/testable-design_{mode}_{td_ts}')
    per_mode_report = {
        'schema_version': td_report['schema_version'],
        'benchmark': td_report['benchmark'],
        'summary': {
            'runs': 1,
            'passed_runs': 1 if res['passed'] else 0,
            'failed_runs': 0 if res['passed'] else 1,
            'cases': 1,
            'skills': 1,
        },
        'evaluation': td_report['evaluation'],
        'impact': td_report['impact'],
        'comparisons': td_report['comparisons'],
        'results': [res],
    }
    sanitized = json.dumps(per_mode_report, indent=2)
    sanitized = sanitize(sanitized)
    (out_dir / 'report.json').write_text(sanitized, encoding='utf-8')
    print(f"  wrote {out_dir.name}/report.json (mode={mode})")

# Also extract per-mode report.md from the original report.md files
hr_md = Path('skill-benchmarks/output/20261127T185653037682Z-human-readable-code-both/report.md').read_text()
td_md = Path('skill-benchmarks/output/20261127T190339527239Z-testable-design-both/report.md').read_text()

# Simple extraction: split by "### " sections
def extract_mode_section(full_md, mode_name):
    lines = full_md.split('\n')
    out = []
    in_section = False
    for line in lines:
        if line.startswith('### '):
            if mode_name in line:
                in_section = True
            elif in_section:
                in_section = False
        if in_section:
            out.append(line)
    return '\n'.join(out).strip()

for mode in ['with-skill', 'without-skill']:
    out_dir = Path(f'/tmp/evidence-staging/human-readable-code_{mode}_{hr_ts}')
    section = extract_mode_section(hr_md, f'registration-boundary' if False else 'invoice-refactor')
    # Actually HR report.md has "### human-readable-code / with-skill" style
    # Let me just use the full report.md for each mode (sanitized) — it's small
    sanitized = sanitize(hr_md)
    (out_dir / 'report.md').write_text(sanitized, encoding='utf-8')

for mode in ['with-skill', 'without-skill']:
    out_dir = Path(f'/tmp/evidence-staging/testable-design_{mode}_{td_ts}')
    sanitized = sanitize(td_md)
    (out_dir / 'report.md').write_text(sanitized, encoding='utf-8')

print("Done extracting per-mode reports")