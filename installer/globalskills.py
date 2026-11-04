#!/usr/bin/env python3
"""Install Globalskills skills and generated agents into native runtimes."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
import shutil
import subprocess
import sys
import time
import uuid
from pathlib import Path, PurePosixPath

RUNTIMES = ("opencode", "copilot")
REPOSITORY = "mariuszmarzec/globalskills"


class InstallerError(Exception):
    pass


def sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def git(source: Path, *args: str) -> str | None:
    try:
        result = subprocess.run(
            ["git", "-C", str(source), *args],
            check=True, capture_output=True, text=True
        )
        return result.stdout.strip()
    except (OSError, subprocess.CalledProcessError):
        return None


def source_commit(source: Path) -> str:
    return git(source, "rev-parse", "HEAD") or "unknown"


def refresh_source(source: Path, dry_run: bool) -> bool:
    branch = git(source, "symbolic-ref", "--short", "HEAD")
    remote = git(source, "config", "--get", f"branch.{branch or ''}.remote")
    if not branch or not remote or remote == ".":
        return False
    fetched = subprocess.run(
        ["git", "-C", str(source), "fetch", remote, branch, "--quiet"],
        capture_output=True, text=True
    )
    if fetched.returncode:
        raise InstallerError("Git fetch failed: " + fetched.stderr.strip())
    local = git(source, "rev-parse", "HEAD")
    upstream = git(source, "rev-parse", "FETCH_HEAD")
    if not local or not upstream or local == upstream:
        return False
    ancestor = subprocess.run(
        ["git", "-C", str(source), "merge-base", "--is-ancestor", local, upstream],
        capture_output=True
    )
    if ancestor.returncode:
        raise InstallerError("Globalskills checkout diverged from upstream; resolve Git state first.")
    if dry_run:
        return True
    merged = subprocess.run(
        ["git", "-C", str(source), "merge", "--ff-only", "FETCH_HEAD"],
        capture_output=True, text=True
    )
    if merged.returncode:
        raise InstallerError("Git fast-forward failed: " + merged.stderr.strip())
    return False


def parse_agent(path: Path):
    text = path.read_text(encoding="utf-8")
    if not text.startswith("+++\n"):
        raise InstallerError(f"{path}: expected TOML frontmatter delimited by +++")
    try:
        header, body = text[4:].split("\n+++\n", 1)
    except ValueError as exc:
        raise InstallerError(f"{path}: unterminated frontmatter") from exc
    metadata = {}
    current = metadata
    for line_no, raw in enumerate(header.splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("[") and line.endswith("]"):
            current = metadata
            for part in line[1:-1].split("."):
                current = current.setdefault(part, {})
                if not isinstance(current, dict):
                    raise InstallerError(f"{path}: invalid table at line {line_no}")
            continue
        if "=" not in line:
            raise InstallerError(f"{path}: invalid TOML assignment at line {line_no}")
        key, value = (part.strip() for part in line.split("=", 1))
        try:
            current[key] = json.loads(value)
        except json.JSONDecodeError as exc:
            raise InstallerError(f"{path}: use JSON-compatible TOML values at line {line_no}") from exc
    return metadata, body.lstrip("\n")


def yaml_value(value) -> str:
    if isinstance(value, str):
        return json.dumps(value, ensure_ascii=False)
    if value is True:
        return "true"
    if value is False:
        return "false"
    if value is None:
        return "null"
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, list):
        return "[" + ", ".join(yaml_value(item) for item in value) + "]"
    raise InstallerError(f"Unsupported agent metadata value: {type(value).__name__}")


def yaml_lines(mapping, indent=0):
    output = []
    pad = " " * indent
    for key, value in mapping.items():
        if isinstance(value, dict):
            output.append(f"{pad}{key}:")
            output.extend(yaml_lines(value, indent + 2))
        elif isinstance(value, list):
            output.append(f"{pad}{key}:")
            for item in value:
                if isinstance(item, dict):
                    entries = list(item.items())
                    if not entries:
                        output.append(f"{pad}  - {{}}")
                        continue
                    first_key, first_value = entries[0]
                    output.append(f"{pad}  - {first_key}: {yaml_value(first_value)}")
                    for nested_key, nested_value in entries[1:]:
                        output.append(f"{pad}    {nested_key}: {yaml_value(nested_value)}")
                else:
                    output.append(f"{pad}  - {yaml_value(item)}")
        else:
            output.append(f"{pad}{key}: {yaml_value(value)}")
    return output


def render_agent(path: Path, runtime: str):
    metadata, body = parse_agent(path)
    name = metadata.get("id")
    description = metadata.get("description")
    if name != path.stem or not isinstance(description, str) or not description.strip():
        raise InstallerError(f"{path}: id must match filename and description is required")
    config = metadata.get(runtime)
    if not isinstance(config, dict):
        raise InstallerError(f"{path}: missing [{runtime}] config")
    if runtime == "opencode":
        allowed = {"mode", "model", "steps", "permissions"}
        unsupported = set(config) - allowed
        if unsupported:
            raise InstallerError(
                f"{path}: unsupported OpenCode V2 agent fields: {', '.join(sorted(unsupported))}"
            )
        permissions = config.get("permissions", {})
        if not isinstance(permissions, dict):
            raise InstallerError(f"{path}: [opencode.permissions] must be a table")
        action_aliases = {"bash": "shell", "task": "subagent"}
        permission_rules = []
        for action, effect in permissions.items():
            if effect not in ("allow", "ask", "deny"):
                raise InstallerError(f"{path}: invalid OpenCode permission effect for {action}: {effect}")
            permission_rules.append({
                "action": action_aliases.get(action, action),
                "resource": "*",
                "effect": effect,
            })
        frontmatter = {
            "description": description,
            **{key: value for key, value in config.items() if key in ("mode", "model", "steps")},
            # The V2 field forces the current schema even for agents with no
            # explicit rules; legacy permission and temperature are not emitted.
            "permissions": permission_rules,
        }
        target = f"{name}.md"
    else:
        frontmatter = {
            "name": config.get("name", name),
            "description": description,
            "target": "github-copilot",
        }
        for key in ("model", "reasoning-effort", "tools"):
            if key in config:
                frontmatter[key] = config[key]
        access = metadata.get("globalskills", {}).get("access")
        if access in ("read-only", "review-before-edit") and "tools" not in frontmatter:
            # Copilot has no equivalent to OpenCode edit=ask; default to no write tools.
            frontmatter["tools"] = ["read", "search"]
        if "user_invocable" in config:
            frontmatter["user-invocable"] = config["user_invocable"]
        if "disable_model_invocation" in config:
            frontmatter["disable-model-invocation"] = config["disable_model_invocation"]
        target = f"{name}.agent.md"
    content = (
        "---\n" + "\n".join(yaml_lines(frontmatter)) +
        "\n---\n\n" + body
    ).encode("utf-8")
    return {
        "name": name, "target": target, "files": {target: content},
        "modes": {target: 0o644}, "digest": sha(content),
    }


def validate_skill(folder: Path):
    definition = folder / "SKILL.md"
    if not definition.is_file():
        raise InstallerError(f"{folder}: missing SKILL.md")
    text = definition.read_text(encoding="utf-8")
    if not text.startswith("---\n") or "\n---" not in text[4:]:
        raise InstallerError(f"{definition}: missing YAML frontmatter")
    fields = {}
    header = text[4:].split("\n---", 1)[0]
    for line in header.splitlines():
        if ":" in line and line[:1].isspace() is False:
            key, value = line.split(":", 1)
            fields[key.strip()] = value.strip().strip("'\"")
    if fields.get("name") != folder.name or not fields.get("description"):
        raise InstallerError(f"{definition}: name must match folder and description is required")


def inventory(source: Path, runtime: str):
    if not (source / "skills").is_dir() or not (source / "agents").is_dir():
        raise InstallerError(f"{source} is not a Globalskills checkout")
    skills, agents = {}, {}
    for folder in sorted((source / "skills").iterdir()):
        if folder.is_symlink():
            raise InstallerError(f"Skill directory is a symlink: {folder}")
        if not folder.is_dir() or folder.name.startswith("."):
            continue
        validate_skill(folder)
        files, modes = {}, {}
        for path in sorted(folder.rglob("*")):
            if path.is_symlink():
                raise InstallerError(f"Skill contains a symlink: {path}")
            if path.is_file():
                relative = path.relative_to(folder).as_posix()
                files[relative] = path.read_bytes()
                modes[relative] = path.stat().st_mode & 0o777
        digest = sha(json.dumps({key: sha(value) for key, value in files.items()}, sort_keys=True).encode())
        skills[folder.name] = {"name": folder.name, "target": folder.name, "files": files, "modes": modes, "digest": digest}
    for path in sorted((source / "agents").glob("*.md")):
        if path.is_symlink():
            raise InstallerError(f"Agent definition is a symlink: {path}")
        agent = render_agent(path, runtime)
        agents[agent["name"]] = agent
    return {"skills": skills, "agents": agents}


def runtime_roots(home: Path):
    return {
        "shared": {"skills": home / ".agents" / "skills"},
        "opencode": {"agents": home / ".config" / "opencode" / "agents"},
        "copilot": {"agents": home / ".copilot" / "agents"},
    }


def resource_base(root: Path, kind: str, item):
    if kind != "skills":
        return root
    target = safe_relative(item["target"])
    if len(target.parts) != 1:
        raise InstallerError(f"Unsafe skill destination name: {item['target']}")
    return root / target


def safe_relative(relative: str) -> Path:
    path = PurePosixPath(relative)
    if path.is_absolute() or not path.parts or any(part in ("", ".", "..") for part in path.parts):
        raise InstallerError(f"Unsafe relative resource path: {relative}")
    return Path(*path.parts)


def target_file(root: Path, kind: str, item, relative: str):
    return resource_base(root, kind, item) / safe_relative(relative)


def symlink_in_path(root: Path, path: Path):
    try:
        parts = path.relative_to(root).parts
    except ValueError:
        return path
    current = root
    for part in parts:
        current = current / part
        if current.is_symlink():
            return current
    return None


def file_hash(path: Path):
    if not path.is_file() or path.is_symlink():
        return None
    return sha(path.read_bytes())


def file_mode(path: Path):
    if not path.is_file() or path.is_symlink():
        return None
    return path.stat().st_mode & 0o777


def load_manifest(path: Path):
    empty = {
        "schemaVersion": 1, "source": {},
        "shared": {"skills": {}},
        "runtimes": {runtime: {"agents": {}} for runtime in RUNTIMES},
    }
    if not path.exists():
        return empty
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise InstallerError(f"Cannot read manifest: {exc}") from exc
    if data.get("schemaVersion") != 1:
        raise InstallerError("Unsupported manifest schema")
    data.setdefault("shared", {}).setdefault("skills", {})
    for runtime in RUNTIMES:
        runtime_data = data.setdefault("runtimes", {}).setdefault(runtime, {})
        runtime_data.setdefault("agents", {})
    return data


def save_manifest(path: Path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n", encoding="utf-8")
    os.replace(temporary, path)


def prepare_root(root: Path, source_root: Path, dry_run: bool):
    if root.is_symlink():
        if root.resolve(strict=False) != source_root.resolve(strict=False):
            raise InstallerError(f"Refusing unrelated destination symlink: {root} -> {os.readlink(root)}")
        if not dry_run:
            root.unlink()
    if root.exists() and not root.is_dir():
        raise InstallerError(f"Destination is not a directory: {root}")
    if not dry_run:
        root.mkdir(parents=True, exist_ok=True)


def classify(root: Path, kind: str, item, previous):
    paths = set(item["files"])
    if previous:
        paths.update(previous.get("files", {}))
    for relative in paths:
        link = symlink_in_path(root, target_file(root, kind, item, relative))
        if link:
            return "conflict", f"destination contains a symlink: {link}"
    previous_files = previous.get("files", {}) if previous else {}
    for relative, metadata in previous_files.items():
        installed = target_file(root, kind, item, relative)
        if (
            file_hash(installed) != metadata["sha256"]
            or file_mode(installed) != metadata.get("mode", 0o644)
        ):
            return "conflict", f"local modification, permission change, or deletion: {relative}"
    for relative, data in item["files"].items():
        if relative in previous_files:
            continue
        destination = target_file(root, kind, item, relative)
        if destination.exists() and (
            file_hash(destination) != sha(data)
            or file_mode(destination) != item["modes"].get(relative, 0o644)
        ):
            return "conflict", f"new upstream file collides with unmanaged local file: {destination}"
    changed = any(
        file_hash(target_file(root, kind, item, relative)) != sha(data)
        or file_mode(target_file(root, kind, item, relative)) != item["modes"].get(relative, 0o644)
        for relative, data in item["files"].items()
    )
    changed = changed or bool(previous and set(previous_files) != set(item["files"]))
    return ("update" if previous and changed else "install" if not previous else "current"), None


def backup_resource(state: Path, root: Path, kind: str, item, previous):
    backup_relative = (
        Path("backups") /
        (str(int(time.time())) + "-" + uuid.uuid4().hex[:8]) /
        (kind[:-1] + "-" + item["name"])
    )
    destination = state / backup_relative
    destination.mkdir(parents=True, exist_ok=True)
    for relative in previous.get("files", {}):
        source = target_file(root, kind, item, relative)
        output = destination / safe_relative(relative)
        output.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source, output)
    return backup_relative.as_posix()


def remove_old(root: Path, kind: str, item, previous, keep):
    for relative in previous.get("files", {}):
        if relative in keep:
            continue
        path = target_file(root, kind, item, relative)
        if path.is_file() or path.is_symlink():
            path.unlink()
        if kind == "skills":
            parent = path.parent
            stop = resource_base(root, kind, item)
            while parent != stop and parent.exists():
                try:
                    parent.rmdir()
                except OSError:
                    break
                parent = parent.parent


def install_item(root: Path, kind: str, item, previous, state: Path, commit: str):
    rollback = None
    backup = None
    if previous and previous.get("sourceDigest") is None and previous.get("previous"):
        rollback = previous["previous"]
    elif previous:
        backup = backup_resource(state, root, kind, item, previous)
        rollback = {
            "backup": backup, "files": previous.get("files", {}),
            "sourceDigest": previous.get("sourceDigest"),
            "sourceCommit": previous.get("sourceCommit"), "target": previous.get("target"),
        }
    try:
        if previous:
            remove_old(root, kind, item, previous, set(item["files"]))
        for relative, data in item["files"].items():
            destination = target_file(root, kind, item, relative)
            destination.parent.mkdir(parents=True, exist_ok=True)
            if symlink_in_path(root, destination):
                raise InstallerError(f"Refusing destination symlink: {destination}")
            temporary = destination.with_name(destination.name + ".globalskills-tmp-" + uuid.uuid4().hex)
            try:
                temporary.write_bytes(data)
                os.chmod(temporary, item["modes"].get(relative, 0o644))
                os.replace(temporary, destination)
            finally:
                temporary.unlink(missing_ok=True)
    except Exception:
        if previous and backup:
            for relative in item["files"]:
                destination = target_file(root, kind, item, relative)
                if destination.is_file() and relative not in previous.get("files", {}):
                    destination.unlink()
            for relative in previous.get("files", {}):
                destination = target_file(root, kind, item, relative)
                if destination.is_file():
                    destination.unlink()
            for relative in previous.get("files", {}):
                source_file = state / backup / safe_relative(relative)
                destination = target_file(root, kind, item, relative)
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(source_file, destination)
        raise
    result = {
        "target": item["target"], "sourceDigest": item["digest"], "sourceCommit": commit,
        "files": {
            relative: {"sha256": sha(data), "mode": item["modes"].get(relative, 0o644)}
            for relative, data in item["files"].items()
        },
    }
    if rollback:
        result["previous"] = rollback
    return result


def install_or_update(args):
    source = Path(args.source).expanduser().resolve()
    home = Path(args.home).expanduser().resolve()
    state = Path(args.state_dir).expanduser().resolve()
    selected = RUNTIMES if args.runtime == "all" else (args.runtime,)
    dry_run = args.check
    if args.command == "update" and refresh_source(source, dry_run):
        print("UPSTREAM: source checkout has updates; run globalskills update")
        return 1
    manifest = load_manifest(state / "manifest.json")
    roots = runtime_roots(home)
    commit = source_commit(source)
    processing = ("shared", *selected)
    inventories = {
        "shared": inventory(source, "opencode"),
        **{runtime: inventory(source, runtime) for runtime in selected},
    }
    changed = False
    conflict = False
    for runtime in processing:
        kinds = ("skills",) if runtime == "shared" else ("agents",)
        for kind in kinds:
            root = roots[runtime][kind]
            try:
                prepare_root(root, source / kind, dry_run)
            except InstallerError as exc:
                print(f"CONFLICT {runtime}/{kind}: {exc}")
                conflict = True
                continue
            records = (
                manifest["shared"]["skills"]
                if runtime == "shared"
                else manifest["runtimes"][runtime]["agents"]
            )
            available = inventories[runtime][kind]
            for name, item in sorted(available.items()):
                previous = records.get(name)
                action, reason = classify(root, kind, item, previous)
                if action == "conflict":
                    print(f"CONFLICT {runtime}/{kind}/{name}: {reason}")
                    conflict = True
                    continue
                if action == "current":
                    print(f"CURRENT {runtime}/{kind}/{name}")
                    continue
                print(("WOULD " if dry_run else "") + f"{action.upper()} {runtime}/{kind}/{name}")
                changed = True
                if not dry_run:
                    try:
                        records[name] = install_item(root, kind, item, previous, state, commit)
                    except Exception as exc:
                        print(f"CONFLICT {runtime}/{kind}/{name}: install failed: {exc}")
                        conflict = True
            for name, previous in list(records.items()):
                if name in available:
                    continue
                if previous.get("sourceDigest") is None and previous.get("previous"):
                    print(f"REMOVED-SOURCE {runtime}/{kind}/{name}")
                    continue
                item = {"name": name, "target": previous.get("target", name), "files": {}, "modes": {}}
                dirty = any(
                    file_hash(target_file(root, kind, item, relative)) != metadata["sha256"]
                    or file_mode(target_file(root, kind, item, relative)) != metadata.get("mode", 0o644)
                    for relative, metadata in previous.get("files", {}).items()
                )
                if dirty:
                    print(f"CONFLICT {runtime}/{kind}/{name}: locally modified removed resource")
                    conflict = True
                    continue
                print(("WOULD " if dry_run else "") + f"REMOVE {runtime}/{kind}/{name}")
                changed = True
                if not dry_run:
                    backup = backup_resource(state, root, kind, item, previous)
                    remove_old(root, kind, item, previous, set())
                    records[name] = {
                        "target": item["target"], "sourceDigest": None, "sourceCommit": commit, "files": {},
                        "previous": {
                            "backup": backup, "files": previous.get("files", {}),
                            "sourceDigest": previous.get("sourceDigest"),
                            "sourceCommit": previous.get("sourceCommit"), "target": item["target"],
                        },
                    }
    if not dry_run:
        manifest["source"] = {"repository": REPOSITORY, "commit": commit}
        save_manifest(state / "manifest.json", manifest)
    return 2 if conflict else 1 if dry_run and changed else 0

def rollback(args):
    home = Path(args.home).expanduser().resolve()
    state = Path(args.state_dir).expanduser().resolve()
    manifest = load_manifest(state / "manifest.json")
    selected = RUNTIMES if args.runtime == "all" else (args.runtime,)
    name = args.resource
    wanted = None
    if ":" in name:
        prefix, name = name.split(":", 1)
        wanted = {"skill": "skills", "agent": "agents"}.get(prefix)
        if not wanted:
            raise InstallerError("Use skill:name or agent:name")
    roots = runtime_roots(home)
    matches = []
    if not wanted or wanted == "skills":
        record = manifest["shared"]["skills"].get(name)
        if record and record.get("previous"):
            matches.append(("shared", "skills", record))
    if not wanted or wanted == "agents":
        for runtime in selected:
            record = manifest["runtimes"][runtime]["agents"].get(name)
            if record and record.get("previous"):
                matches.append((runtime, "agents", record))
    if not matches:
        raise InstallerError(f"No rollback available for {args.resource}")
    if len({kind for _, kind, _ in matches}) > 1:
        raise InstallerError(f"{name} is both a skill and an agent; add skill: or agent:")
    # Preflight every target before changing any runtime.
    for runtime, kind, record in matches:
        root = roots[runtime][kind]
        item = {"name": name, "target": record["target"], "files": {}, "modes": {}}
        for relative, metadata in record.get("files", {}).items():
            path = target_file(root, kind, item, relative)
            if (
                symlink_in_path(root, path)
                or file_hash(path) != metadata["sha256"]
                or file_mode(path) != metadata.get("mode", 0o644)
            ):
                raise InstallerError(f"Refusing to overwrite local change: {path}")
        backup = state / safe_relative(record["previous"]["backup"])
        if not backup.is_dir():
            raise InstallerError(f"Missing rollback backup: {backup}")
        for relative in record["previous"].get("files", {}):
            backup_file = backup / safe_relative(relative)
            if not backup_file.is_file():
                raise InstallerError(f"Incomplete rollback backup: {backup_file}")
    for runtime, kind, record in matches:
        root = roots[runtime][kind]
        item = {"name": name, "target": record["target"], "files": {}, "modes": {}}
        for relative in record.get("files", {}):
            path = target_file(root, kind, item, relative)
            if path.is_file():
                path.unlink()
        previous = record["previous"]
        backup = state / safe_relative(previous["backup"])
        for relative in previous.get("files", {}):
            source_file = backup / safe_relative(relative)
            destination = target_file(root, kind, item, relative)
            destination.parent.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source_file, destination)
        record["files"] = previous.get("files", {})
        record["sourceDigest"] = previous.get("sourceDigest")
        record["sourceCommit"] = previous.get("sourceCommit")
        record.pop("previous", None)
        print(f"ROLLED BACK {runtime}/{kind}/{name}")
    save_manifest(state / "manifest.json", manifest)
    return 0

def show_status(args):
    source = Path(args.source).expanduser().resolve()
    home = Path(args.home).expanduser().resolve()
    state = Path(args.state_dir).expanduser().resolve()
    manifest = load_manifest(state / "manifest.json")
    selected = RUNTIMES if args.runtime == "all" else (args.runtime,)
    roots = runtime_roots(home)
    dirty = False
    shared = inventory(source, "opencode")["skills"]
    records = manifest["shared"]["skills"]
    for name, item in sorted(shared.items()):
        status, reason = classify(roots["shared"]["skills"], "skills", item, records.get(name))
        print(f"{status.upper()} shared/skills/{name}" + (f": {reason}" if reason else ""))
        dirty |= status != "current"
    for name, record in sorted(records.items()):
        if name not in shared and record.get("sourceDigest") is not None:
            print(f"MISSING-SOURCE shared/skills/{name}")
            dirty = True
    for runtime in selected:
        available = inventory(source, runtime)["agents"]
        records = manifest["runtimes"][runtime]["agents"]
        for name, item in sorted(available.items()):
            status, reason = classify(roots[runtime]["agents"], "agents", item, records.get(name))
            print(f"{status.upper()} {runtime}/agents/{name}" + (f": {reason}" if reason else ""))
            dirty |= status != "current"
        for name, record in sorted(records.items()):
            if name not in available and record.get("sourceDigest") is not None:
                print(f"MISSING-SOURCE {runtime}/agents/{name}")
                dirty = True
    print(f"Source commit: {source_commit(source)}")
    print(f"Manifest: {state / 'manifest.json'}")
    return 1 if dirty else 0

def main(argv=None):
    parser = argparse.ArgumentParser(prog="globalskills", description="Install and update native Globalskills resources")
    parser.add_argument("--source", default=str(Path(__file__).resolve().parents[1]))
    parser.add_argument("--home", default=str(Path.home()), help=argparse.SUPPRESS)
    state_home = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local" / "state"))
    parser.add_argument("--state-dir", default=str(state_home / "globalskills"), help=argparse.SUPPRESS)
    sub = parser.add_subparsers(dest="command", required=True)
    for command in ("install", "update"):
        command_parser = sub.add_parser(command)
        command_parser.add_argument("--runtime", choices=(*RUNTIMES, "all"), default="all")
        command_parser.add_argument("--check", action="store_true")
        command_parser.set_defaults(handler=install_or_update)
    status_parser = sub.add_parser("status")
    status_parser.add_argument("--runtime", choices=(*RUNTIMES, "all"), default="all")
    status_parser.set_defaults(handler=show_status)
    rollback_parser = sub.add_parser("rollback")
    rollback_parser.add_argument("resource")
    rollback_parser.add_argument("--runtime", choices=(*RUNTIMES, "all"), default="all")
    rollback_parser.set_defaults(handler=rollback)
    args = parser.parse_args(argv)
    try:
        return args.handler(args)
    except InstallerError as exc:
        print(f"globalskills: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
