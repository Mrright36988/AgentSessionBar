"""Tests for install.py against temporary copies. Run: /usr/bin/python3 -m unittest discover -s scripts"""
import contextlib
import filecmp
import io
import json
import os
import shutil
import tempfile
import unittest

import install

CLAUDE = {"hooks": {"UserPromptSubmit": [{"hooks": [{"type": "command", "command": "python3 jev.py"}]}]},
          "permissions": {"allow": ["Bash(ls:*)"]}}
CODEX = {"description": "Advisory Jev preflight", "hooks": {"UserPromptSubmit": [{"hooks": [
    {"type": "command", "command": "/usr/bin/python3 /h/.codex/hooks/jev.py", "timeout": 8}]}]}}
LEGACY = {"type": "command", "command": "/usr/bin/python3 /h/.agent-deck/bin/deck-hook claude Stop", "timeout": 10, "async": True}


class InstallTest(unittest.TestCase):
    def setUp(self):
        d = tempfile.mkdtemp()
        self.paths = install.Paths(
            claude_settings=os.path.join(d, "settings.json"),
            codex_hooks=os.path.join(d, "hooks.json"),
            codex_config=os.path.join(d, "config.toml"),
            shim_src=install.DEFAULT.shim_src,
            shim_dst=os.path.join(d, ".agentsessionbar/bin/agentsessionbar-hook"),
            socket=os.path.join(d, "hook.sock"),
            legacy_shim=os.path.join(d, ".agent-deck/bin/deck-hook"),
        )
        for path, data in ((self.paths.claude_settings, CLAUDE), (self.paths.codex_hooks, CODEX)):
            with open(path, "w") as f:
                json.dump(data, f, indent=4)
            with open(path + ".orig", "w") as f:
                json.dump(data, f, indent=4)
        with open(self.paths.codex_config, "w") as f:
            f.write('model = "x"\n')

    def quiet(self, fn):
        with contextlib.redirect_stdout(io.StringIO()) as out:
            fn(self.paths)
        return out.getvalue()

    def install_legacy(self):
        """What an install from before the rename left behind: a backup, its hook, and the old shim."""
        shutil.copy(self.paths.claude_settings + ".orig", self.paths.claude_settings + ".bak.agent-deck-20261030000000")
        claude = install.load(self.paths.claude_settings)
        claude["hooks"]["Stop"] = [{"hooks": [LEGACY]}]
        install.save(self.paths.claude_settings, claude)
        os.makedirs(os.path.dirname(self.paths.legacy_shim))
        open(self.paths.legacy_shim, "w").close()

    def test_install_appends_without_touching_existing_hooks(self):
        self.quiet(install.install)
        claude = install.load(self.paths.claude_settings)
        self.assertEqual(claude["permissions"], CLAUDE["permissions"])
        self.assertEqual(claude["hooks"]["UserPromptSubmit"][0], CLAUDE["hooks"]["UserPromptSubmit"][0])
        self.assertEqual(sorted(install.installed(claude)), sorted(install.CLAUDE_EVENTS))
        self.assertNotIn("SessionEnd", claude["hooks"])  # Cursor would hold closing windows on it
        permission = claude["hooks"]["PermissionRequest"][0]["hooks"][0]
        self.assertEqual(permission["timeout"], 600)
        self.assertNotIn("async", permission)
        self.assertTrue(claude["hooks"]["Stop"][0]["hooks"][0]["async"])
        codex = install.load(self.paths.codex_hooks)
        self.assertEqual(codex["description"], CODEX["description"])
        self.assertEqual(sorted(install.installed(codex)), sorted(install.CODEX_EVENTS))
        self.assertTrue(os.access(self.paths.shim_dst, os.X_OK))

    def test_second_install_is_refused(self):
        self.quiet(install.install)
        with self.assertRaises(SystemExit):
            self.quiet(install.install)

    def test_uninstall_restores_files_byte_for_byte(self):
        self.quiet(install.install)
        self.quiet(install.uninstall)
        for path in (self.paths.claude_settings, self.paths.codex_hooks):
            self.assertTrue(filecmp.cmp(path, path + ".orig", shallow=False), path)
        self.assertFalse(os.path.exists(self.paths.shim_dst))

    def test_uninstall_keeps_edits_made_after_install(self):
        self.quiet(install.install)
        claude = install.load(self.paths.claude_settings)
        claude["permissions"]["allow"].append("Bash(git:*)")
        install.save(self.paths.claude_settings, claude)
        self.quiet(install.uninstall)
        after = install.load(self.paths.claude_settings)
        self.assertEqual(install.installed(after), [])
        self.assertIn("Bash(git:*)", after["permissions"]["allow"])

    def test_uninstall_removes_hooks_from_before_the_rename(self):
        self.install_legacy()
        self.assertEqual(install.installed(install.load(self.paths.claude_settings), install.is_legacy), ["Stop"])
        self.quiet(install.uninstall)
        self.assertTrue(filecmp.cmp(self.paths.claude_settings, self.paths.claude_settings + ".orig", shallow=False))
        self.assertFalse(os.path.exists(self.paths.legacy_shim))

    def test_uninstall_of_old_codex_hooks_asks_to_trust_again(self):
        codex = install.load(self.paths.codex_hooks)
        codex["hooks"]["Stop"] = [{"hooks": [dict(LEGACY, command=LEGACY["command"].replace("claude", "codex"))]}]
        install.save(self.paths.codex_hooks, codex)
        self.assertIn("trust the new entries again", self.quiet(install.uninstall))
        self.assertEqual(install.installed(install.load(self.paths.codex_hooks)), [])

    def test_install_waits_until_old_hooks_are_removed(self):
        self.install_legacy()
        self.assertIn("old agent-deck hooks", self.quiet(install.status))
        with self.assertRaises(SystemExit):
            self.quiet(install.install)
        self.assertFalse(os.path.exists(self.paths.shim_dst))

    def test_codex_trust_reads_hash_slots(self):
        self.quiet(install.install)
        self.assertEqual(set(install.codex_trust(self.paths).values()), {False})
        key = "%s:user_prompt_submit:1:0" % self.paths.codex_hooks  # slot 0 is the existing Jev hook
        with open(self.paths.codex_config, "a") as f:
            f.write('\n[hooks.state."%s"]\ntrusted_hash = "sha256:abc"\n' % key)
        trust = install.codex_trust(self.paths)
        self.assertTrue(trust["UserPromptSubmit"])
        self.assertFalse(trust["PermissionRequest"])


if __name__ == "__main__":
    unittest.main()
