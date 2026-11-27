#!/usr/bin/env python3
"""
Deterministic redaction for benchmark evidence artifacts.

Redaction rules (applied in order):
1. Strip ANSI escape sequences (ESC [ ... m) from all text.
2. Replace username 'marzec' with '<user>'.
3. Replace absolute home paths '/home/marzec/...' with '/home/<user>/...'.
4. Replace ephemeral workspace paths '/tmp/skill-bench-<case>-<rand>/workspace'
   with '/tmp/skill-bench-<case>-<run>/workspace' where <run> is a stable token
   derived from the run directory name.
5. For the 'ls -la ~/.globalskills/skills/' listing in testable-design without-skill:
   keep only the line containing 'testable-design' plus surrounding context,
   with usernames redacted; drop the full listing to minimize exposure.
6. Do NOT redact prompt/task text — these are the test setup and contain no secrets.

Usage:
    python3 redaction.py <run-dir> <output-dir>
"""

import re
import sys
from pathlib import Path

ANSI_ESCAPE = re.compile(r'\x1b\[[0-9;]*m')
HOME_PATH = re.compile(r'/home/marzec([^\s"\']*)')
USERNAME = re.compile(r'\bmarzec\b')
TMP_WORKSPACE = re.compile(r'(/tmp/skill-bench-[^/\s]+)-[a-z0-9_]+(/workspace)')
SKILLS_LS_HEADER = re.compile(r'^drwxr-xr-x\s+\d+\s+\S+\s+\S+\s+\d+\s+\S+\s+\d+\s+\S+\s+\S+\s+testable-design\b')

def strip_ansi(text: str) -> str:
    return ANSI_ESCAPE.sub('', text)

def redact_username(text: str) -> str:
    return USERNAME.sub('<user>', text)

def redact_home_paths(text: str) -> str:
    return HOME_PATH.sub(r'/home/<user>\1', text)

def redact_tmp_workspace(text: str, run_token: str) -> str:
    def repl(m):
        return f'{m.group(1)}-{run_token}{m.group(2)}'
    return TMP_WORKSPACE.sub(repl, text)

def sanitize_skills_listing(text: str, run_token: str) -> str:
    """For TD without-skill stderr: keep only the testable-design line from ls -la output."""
    lines = text.split('\n')
    out = []
    in_listing = False
    for line in lines:
        # Detect the ls -la listing block (after "ls -la ~/.globalskills/skills/")
        if 'ls -la ~/.globalskills/skills/' in line:
            in_listing = True
            out.append(line)
            continue
        if in_listing:
            if line.strip() == '' or line.startswith('>') or line.startswith('^[') or line.startswith('\x1b'):
                # End of listing block or continuation
                out.append(line)
                in_listing = False
                continue
            # Only keep the testable-design line
            if 'testable-design' in line:
                out.append(redact_username(line))
            else:
                out.append('[other skill directories redacted]')
                in_listing = False
        else:
            out.append(line)
    return '\n'.join(out)

def sanitize_text(text: str, run_token: str, is_td_without_skill: bool = False) -> str:
    text = strip_ansi(text)
    text = redact_username(text)
    text = redact_home_paths(text)
    text = redact_tmp_workspace(text, run_token)
    if is_td_without_skill:
        text = sanitize_skills_listing(text, run_token)
    return text

def sanitize_file(src: Path, dst: Path, run_token: str, is_td_without_skill: bool = False) -> None:
    content = src.read_text(encoding='utf-8', errors='replace')
    sanitized = sanitize_text(content, run_token, is_td_without_skill)
    dst.write_text(sanitized, encoding='utf-8')

def main():
    if len(sys.argv) != 3:
        print(f"Usage: {sys.argv[0]} <run-dir> <output-dir>", file=sys.stderr)
        sys.exit(1)
    run_dir = Path(sys.argv[1])
    out_dir = Path(sys.argv[2])
    out_dir.mkdir(parents=True, exist_ok=True)

    # Derive run token from directory name (timestamp-skill-mode)
    run_token = run_dir.name.split('-')[0]  # e.g., "20261127T185653037682Z"

    is_td_without = 'testable-design' in run_dir.name and 'without-skill' in run_dir.name

    # Files to sanitize and copy
    files = [
        'stderr.txt',
        'stdout.txt',
        'command.txt',
        'prompt.txt',
        'git-diff.txt',
        'git-log.txt',
        'git-status.txt',
        'git-show.txt',
        'verifier.json',
        'report.json',
        'report.md',
    ]

    for f in files:
        src = run_dir / f
        if src.exists():
            dst = out_dir / f
            sanitize_file(src, dst, run_token, is_td_without)
            print(f"  sanitized: {f}")
        else:
            print(f"  missing: {f}")

    # Also copy manifest.json (if exists) without redaction (it's machine metadata)
    manifest_src = run_dir.parent / 'input' / 'manifest.json'
    if manifest_src.exists():
        import shutil
        shutil.copy2(manifest_src, out_dir / 'manifest.json')
        print(f"  copied: manifest.json")

if __name__ == '__main__':
    main()