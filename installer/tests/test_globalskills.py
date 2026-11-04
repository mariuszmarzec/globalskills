import json
import shutil
import tempfile
import unittest
from pathlib import Path

from installer import globalskills


class GlobalskillsInstallerTest(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.source = self.root / "source"
        self.home = self.root / "home"
        self.state = self.root / "state"
        (self.source / "skills" / "sample-skill" / "scripts").mkdir(parents=True)
        (self.source / "agents").mkdir(parents=True)
        self.write_skill("first version")
        self.write_agent()

    def tearDown(self):
        self.temp.cleanup()

    def write_skill(self, body):
        (self.source / "skills" / "sample-skill" / "SKILL.md").write_text(
            "---\nname: sample-skill\ndescription: A fixture skill.\n---\n\n" + body + "\n",
            encoding="utf-8",
        )
        (self.source / "skills" / "sample-skill" / "scripts" / "run.sh").write_text(
            "#!/usr/bin/env bash\necho fixture\n", encoding="utf-8"
        )

    def write_agent(self, body="You are the Reviewer. Never modify code."):
        (self.source / "agents" / "reviewer.md").write_text(
            '''+++
id = "reviewer"
description = "Reviews code without changing it."

[globalskills]
model_tier = "strong"
access = "review-before-edit"

[opencode]
mode = "all"
model = "litellm/deepseek-v4-flash-free"
steps = 30
temperature = 0

[opencode.permissions]
edit = "deny"
bash = "deny"

[copilot]
user_invocable = true
disable_model_invocation = false
+++

''' + body + "\n",
            encoding="utf-8",
        )

    def run_cli(self, *args):
        return globalskills.main([
            "--source", str(self.source),
            "--home", str(self.home),
            "--state-dir", str(self.state),
            *args,
        ])

    def manifest(self):
        return json.loads((self.state / "manifest.json").read_text(encoding="utf-8"))

    def test_installs_one_shared_skill_copy_and_runtime_specific_agents(self):
        self.assertEqual(0, self.run_cli("install"))
        skill = self.home / ".agents" / "skills" / "sample-skill"
        self.assertTrue((skill / "SKILL.md").is_file())
        self.assertTrue((skill / "scripts" / "run.sh").is_file())
        self.assertFalse(skill.is_symlink())
        self.assertFalse((self.home / ".copilot" / "skills").exists())
        opencode = (self.home / ".config" / "opencode" / "agents" / "reviewer.md").read_text()
        copilot = (self.home / ".copilot" / "agents" / "reviewer.agent.md").read_text()
        self.assertIn('model: "litellm/deepseek-v4-flash-free"', opencode)
        self.assertIn('permissions:\n  - action: "edit"\n    resource: "*"\n    effect: "deny"\n  - action: "shell"\n    resource: "*"\n    effect: "deny"', opencode)
        self.assertNotIn("\npermission:", opencode)
        self.assertNotIn("\ntemperature:", opencode)
        self.assertIn('tools:\n  - "read"\n  - "search"', copilot)
        self.assertNotIn("litellm/", copilot)
        self.assertIn("Never modify code.", copilot)
        data = self.manifest()
        self.assertIn("sample-skill", data["shared"]["skills"])
        for runtime in ("opencode", "copilot"):
            self.assertIn("reviewer", data["runtimes"][runtime]["agents"])

    def test_install_is_idempotent_and_status_is_clean(self):
        self.assertEqual(0, self.run_cli("install"))
        self.assertEqual(0, self.run_cli("install"))
        self.assertEqual(0, self.run_cli("status"))

    def test_opencode_v2_permission_aliases_are_converted(self):
        rendered = globalskills.render_agent(self.source / "agents" / "reviewer.md", "opencode")
        output = rendered["files"]["reviewer.md"].decode()
        self.assertIn('action: "shell"', output)
        self.assertNotIn('action: "bash"', output)

    def test_opencode_v2_agents_without_rules_still_use_v2_frontmatter(self):
        self.write_agent()
        path = self.source / "agents" / "reviewer.md"
        text = path.read_text()
        text = text.replace('[opencode.permissions]\nedit = "deny"\nbash = "deny"\n', '')
        path.write_text(text, encoding="utf-8")
        rendered = globalskills.render_agent(path, "opencode")
        output = rendered["files"]["reviewer.md"].decode()
        self.assertIn("permissions: []", output)
        self.assertNotIn("temperature:", output)
        self.assertNotIn("\npermission:", output)

    def test_runtime_specific_install_still_installs_shared_skills(self):
        self.assertEqual(0, self.run_cli("install", "--runtime", "copilot"))
        self.assertTrue((self.home / ".agents" / "skills" / "sample-skill" / "SKILL.md").is_file())
        self.assertTrue((self.home / ".copilot" / "agents" / "reviewer.agent.md").is_file())
        self.assertFalse((self.home / ".config" / "opencode" / "agents" / "reviewer.md").exists())

    def test_status_detects_not_yet_installed_source_resources(self):
        self.assertEqual(1, self.run_cli("status"))

    def test_locally_modified_managed_file_is_not_overwritten(self):
        self.assertEqual(0, self.run_cli("install"))
        target = self.home / ".agents" / "skills" / "sample-skill" / "SKILL.md"
        target.write_text("local change\n", encoding="utf-8")
        self.write_skill("upstream change")
        self.assertEqual(2, self.run_cli("update"))
        self.assertEqual("local change\n", target.read_text(encoding="utf-8"))

    def test_unmanaged_local_files_are_preserved_and_previous_version_can_be_restored(self):
        self.assertEqual(0, self.run_cli("install"))
        base = self.home / ".agents" / "skills" / "sample-skill"
        (base / "LOCAL-NOTES.md").write_text("keep me\n", encoding="utf-8")
        self.write_skill("second version")
        self.assertEqual(0, self.run_cli("update"))
        self.assertEqual(0, self.run_cli("rollback", "skill:sample-skill"))
        self.assertIn("first version", (base / "SKILL.md").read_text())
        self.assertEqual("keep me\n", (base / "LOCAL-NOTES.md").read_text())

    def test_new_upstream_file_does_not_overwrite_unmanaged_collision(self):
        self.assertEqual(0, self.run_cli("install", "--runtime", "copilot"))
        target = self.home / ".agents" / "skills" / "sample-skill" / "scripts" / "new.sh"
        target.write_text("local version\n", encoding="utf-8")
        (self.source / "skills" / "sample-skill" / "scripts" / "new.sh").write_text("upstream\n")
        self.assertEqual(2, self.run_cli("update", "--runtime", "copilot"))
        self.assertEqual("local version\n", target.read_text())

    def test_migrates_only_legacy_skill_and_agent_symlinks_to_canonical_sources(self):
        legacy_skills = self.home / ".agents" / "skills"
        legacy_agents = self.home / ".config" / "opencode" / "agents"
        legacy_skills.parent.mkdir(parents=True)
        legacy_agents.parent.mkdir(parents=True)
        legacy_skills.symlink_to(self.source / "skills", target_is_directory=True)
        legacy_agents.symlink_to(self.source / "agents", target_is_directory=True)
        self.assertEqual(0, self.run_cli("install", "--runtime", "opencode"))
        self.assertFalse(legacy_skills.is_symlink())
        self.assertFalse(legacy_agents.is_symlink())
        self.assertTrue((legacy_skills / "sample-skill" / "SKILL.md").is_file())
        self.assertTrue((legacy_agents / "reviewer.md").is_file())

    def test_refuses_unrelated_destination_symlink(self):
        unrelated = self.root / "unrelated"
        unrelated.mkdir()
        legacy = self.home / ".agents" / "skills"
        legacy.parent.mkdir(parents=True)
        legacy.symlink_to(unrelated, target_is_directory=True)
        self.assertEqual(2, self.run_cli("install", "--runtime", "opencode"))
        self.assertTrue(legacy.is_symlink())

    def test_rollback_preflights_all_agent_runtimes_before_restoring_any(self):
        self.assertEqual(0, self.run_cli("install"))
        self.write_agent("Updated reviewer prompt.")
        self.assertEqual(0, self.run_cli("update"))
        changed = self.home / ".copilot" / "agents" / "reviewer.agent.md"
        changed.write_text("local change after update\n")
        self.assertEqual(2, self.run_cli("rollback", "agent:reviewer"))
        opencode = self.home / ".config" / "opencode" / "agents" / "reviewer.md"
        self.assertIn("Updated reviewer prompt.", opencode.read_text())
        self.assertEqual("local change after update\n", changed.read_text())

    def test_removed_skill_keeps_rollback_after_repeated_update(self):
        self.assertEqual(0, self.run_cli("install", "--runtime", "opencode"))
        shutil.rmtree(self.source / "skills" / "sample-skill")
        self.assertEqual(0, self.run_cli("update", "--runtime", "opencode"))
        self.assertEqual(0, self.run_cli("update", "--runtime", "opencode"))
        self.assertEqual(0, self.run_cli("rollback", "skill:sample-skill", "--runtime", "opencode"))
        restored = self.home / ".agents" / "skills" / "sample-skill" / "SKILL.md"
        self.assertIn("first version", restored.read_text())

    def test_source_permission_changes_are_installed_and_tracked(self):
        source_script = self.source / "skills" / "sample-skill" / "scripts" / "run.sh"
        source_script.chmod(0o755)
        self.assertEqual(0, self.run_cli("install"))
        installed = self.home / ".agents" / "skills" / "sample-skill" / "scripts" / "run.sh"
        self.assertEqual(0o755, installed.stat().st_mode & 0o777)
        source_script.chmod(0o644)
        self.assertEqual(0, self.run_cli("update"))
        self.assertEqual(0o644, installed.stat().st_mode & 0o777)

    def test_manifest_paths_cannot_escape_managed_directories(self):
        with self.assertRaises(globalskills.InstallerError):
            globalskills.safe_relative("../outside")
        with self.assertRaises(globalskills.InstallerError):
            globalskills.safe_relative("/absolute/path")

    def test_check_does_not_write_or_create_destinations(self):
        self.assertEqual(1, self.run_cli("update", "--check"))
        self.assertFalse(self.home.exists())
        self.assertFalse((self.state / "manifest.json").exists())


if __name__ == "__main__":
    unittest.main()
