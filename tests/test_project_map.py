"""Run with: python3 -m unittest discover -s tests -v"""

import json
import os
from pathlib import Path
import re
import subprocess
import tempfile
import unittest


PLUGIN = Path(__file__).resolve().parents[1]
GROUP = json.loads((PLUGIN / "hooks/hooks.json").read_text())["hooks"]["SessionStart"][0]
POWERSHELL = os.environ.get("PROJECT_MAP_SHELL") == "pwsh"
COMMAND = GROUP["hooks"][0]["commandWindows" if POWERSHELL else "command"]


class ProjectMapTest(unittest.TestCase):
    def invoke(self, cwd, source="startup"):
        self.assertIsNotNone(re.fullmatch(GROUP["matcher"], source))
        return subprocess.run(
            COMMAND, shell=True,
            input=json.dumps({"cwd": str(cwd), "hook_event_name": "SessionStart", "source": source}),
            text=True, capture_output=True, cwd=cwd,
            env={**os.environ, "PLUGIN_ROOT": str(PLUGIN)},
            timeout=15,
        )

    def context(self, cwd, source="startup"):
        result = self.invoke(cwd, source)
        self.assertEqual(result.returncode, 0, result.stderr)
        if POWERSHELL:
            output = json.loads(result.stdout)["hookSpecificOutput"]
            self.assertEqual(output["hookEventName"], "SessionStart")
            return output["additionalContext"]
        return result.stdout

    def test_map_and_refresh_from_git_subdirectory(self):
        with tempfile.TemporaryDirectory(prefix="map project ") as temp:
            root = Path(temp)
            subprocess.run(["git", "init", "-q", str(root)], check=True)
            names = ["AGENTS.md", "README.md", "src/AGENTS.md", ".hidden/readme.md", '中文 space/line\nbreak/README.md']
            excluded = ["node_modules/pkg/README.md", ".git/README.md", ".venv/AGENTS.md"]
            for name in names + excluded:
                path = root / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text("BODY_MUST_NOT_BE_INJECTED")
            (root / "linked").symlink_to(root / "src", target_is_directory=True)
            (root / "src/README.md").symlink_to(root / "README.md")
            context = self.context(root / "src")
            for name in names[:-1]:
                self.assertIn(json.dumps(name) if POWERSHELL else name, context)
            self.assertIn('line\\nbreak/README.md', context)
            self.assertNotIn('line\nbreak', context)
            for name in excluded + ["linked/AGENTS.md", "src/README.md"]:
                self.assertNotIn(name, context)
            self.assertNotIn("BODY_MUST_NOT_BE_INJECTED", context)
            (root / "new").mkdir()
            (root / "new/README.md").touch()
            for source in ("compact", "resume", "clear"):
                self.assertIn('new/README.md', self.context(root / "src", source))

    def test_non_git_and_empty_project(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.assertIn("Project documentation map", self.context(root))
            (root / "README.md").touch()
            self.assertIn('README.md', self.context(root))

    def test_newlines_in_repository_root_and_named_pipe(self):
        with tempfile.TemporaryDirectory() as temp:
            for name in ("root\nname", "root\n"):
                root = Path(temp) / name
                (root / "src").mkdir(parents=True)
                subprocess.run(["git", "init", "-q", str(root)], check=True)
                (root / "README.md").touch()
                os.mkfifo(root / "src/AGENTS.md")
                context = self.context(root / "src")
                self.assertIn('"README.md"' if POWERSHELL else '\nREADME.md\n', context)
                self.assertNotIn('src/AGENTS.md', context)

    @unittest.skipUnless(POWERSHELL, "Bash uses the hook process cwd without parsing stdin")
    def test_invalid_cwd_is_reported_without_context(self):
        # Use the real command, but supply a bad event without scanning the filesystem.
        result = subprocess.run(
            COMMAND, shell=True, input='{"cwd": 42}',
            text=True, capture_output=True,
            env={**os.environ, "PLUGIN_ROOT": str(PLUGIN)}, timeout=15,
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")
        self.assertIn("cwd", result.stderr)
