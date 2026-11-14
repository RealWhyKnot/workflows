from __future__ import annotations

import json
import os
import shutil
import subprocess
import unittest
from pathlib import Path
from typing import override

from lint.common.tests.test_style_check import SCRIPT, VENDORED, RepoCase, lines

BASH = shutil.which("bash")


@unittest.skipIf(os.name == "nt" or not BASH, "Linux Bash is required")
class RepoChecksTests(RepoCase):
    bin = Path()
    log = Path()

    def __init__(self, method_name: str = "runTest") -> None:
        super().__init__(method_name)
        self.environment: dict[str, str] = {}

    @override
    def setUp(self) -> None:
        super().setUp()
        self.write(
            ".github/lint/vendored-paths.txt",
            VENDORED.read_text(encoding="utf-8") + "/external/source/\n/docs/NOTICE.md\n",
        )
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.log = self.root / "calls.jsonl"
        self.environment = dict(os.environ, PATH=str(self.bin), CALL_LOG=str(self.log), CI="false")
        for name in ("git", "mktemp", "rm", "cp", "timeout"):
            executable = shutil.which(name)
            self.assertIsNotNone(executable)
            (self.bin / name).symlink_to(executable or name)
        program = lines(
            "#!/usr/bin/python3",
            "import json, os, pathlib, sys",
            "name = pathlib.Path(sys.argv[0]).name",
            "args = sys.argv[1:]",
            "record = [name, *args]",
            "if name == 'gitleaks' and args[0] == 'dir':",
            "    folder = pathlib.Path(args[-1])",
            "    record.append(sorted(str(p.relative_to(folder)) for p in folder.rglob('*') if p.is_file()))",
            "with open(os.environ['CALL_LOG'], 'a') as log:",
            "    log.write(json.dumps(record) + '\\n')",
            "if name == 'cargo' and args[0] == 'locate-project':",
            "    manifest = pathlib.Path(args[-1])",
            "    if manifest.parts[0] in ('rs', 'apex'):",
            "        manifest = pathlib.Path(manifest.parts[0]) / 'Cargo.toml'",
            "    print(manifest.resolve())",
            "sys.exit(1 if name == os.environ.get('FAIL_TOOL') else 0)",
        )
        for name in ("typos", "gitleaks", "actionlint", "zizmor", "cargo", "cargo-deny"):
            tool = self.bin / name
            _ = tool.write_text(program, encoding="utf-8")
            tool.chmod(0o755)

    def run_runner(self) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [BASH or "bash", str(SCRIPT.with_name("repo_checks.sh"))],
            cwd=self.root,
            env=self.environment,
            capture_output=True,
            text=True,
            encoding="utf-8",
            check=False,
            timeout=60,
        )

    def calls(self) -> list[list[str]]:
        return [json.loads(line) for line in self.log.read_text(encoding="utf-8").splitlines()]

    def test_ci_scans_only_tracked_nonvendored_files(self) -> None:
        for name in (
            "source.txt",
            "with spaces.txt",
            "vendor/skip.txt",
            "nested/vendor/skip.txt",
            "external/source/skip.txt",
            "docs/NOTICE.md",
        ):
            self.write(name, "text\n")
        _ = (self.root / "junk.txt").write_text("untracked", encoding="utf-8")
        self.environment["CI"] = "true"
        result = self.run_runner()
        self.assertEqual(result.returncode, 0, result.stderr)
        scan = next(call for call in self.calls() if call[0] == "gitleaks")
        self.assertEqual(scan[-1], [".github/lint/vendored-paths.txt", "source.txt", "with spaces.txt"])
        self.assertFalse(Path(scan[-2]).exists())

    def test_hook_scans_unpushed_branches(self) -> None:
        result = self.run_runner()
        self.assertEqual(result.returncode, 0, result.stderr)
        scan = next(call for call in self.calls() if call[0] == "gitleaks")
        self.assertIn("--log-opts=--branches --not --remotes", scan)
        self.assertIn("--ignore-gitleaks-allow", scan)

    def test_missing_vendored_list_explains_setup(self) -> None:
        (self.root / ".github/lint/vendored-paths.txt").unlink()
        result = self.run_runner()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stderr, ".github/lint/vendored-paths.txt is missing. Run Install-Lint again.\n")

    def test_tools_for_missing_file_kinds_are_optional(self) -> None:
        for name in ("actionlint", "zizmor", "cargo", "cargo-deny"):
            (self.bin / name).unlink()
        result = self.run_runner()
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_action_only_repo_needs_zizmor_but_not_actionlint(self) -> None:
        self.write("action.yml", "name: check\n")
        (self.bin / "actionlint").unlink()
        self.assertEqual(self.run_runner().returncode, 0)
        (self.bin / "zizmor").unlink()
        result = self.run_runner()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("zizmor is missing", result.stderr)

    def test_missing_tool_fails_with_its_name(self) -> None:
        self.write(".github/workflows/check.yml", "name: check\n")
        self.write("Cargo.toml", "[workspace]\n")
        for name in ("typos", "gitleaks", "actionlint", "zizmor", "cargo", "cargo-deny"):
            with self.subTest(name=name):
                tool = self.bin / name
                content = tool.read_bytes()
                tool.unlink()
                result = self.run_runner()
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"{name} is missing", result.stderr)
                _ = tool.write_bytes(content)
                tool.chmod(0o755)

    def test_findings_fail_the_runner(self) -> None:
        self.write(".github/workflows/check.yml", "name: check\n")
        self.write("Cargo.toml", "[workspace]\n")
        for tool in ("typos", "actionlint", "zizmor", "gitleaks", "cargo"):
            with self.subTest(tool=tool):
                self.environment["FAIL_TOOL"] = tool
                self.assertNotEqual(self.run_runner().returncode, 0)

    def test_root_and_nested_workspaces_are_checked_once(self) -> None:
        for name in ("Cargo.toml", "rs/Cargo.toml", "rs/member/Cargo.toml", "apex/Cargo.toml", "vendor/Cargo.toml"):
            self.write(name, "[workspace]\n")
        result = self.run_runner()
        self.assertEqual(result.returncode, 0, result.stderr)
        scans = [call for call in self.calls() if call[:2] == ["cargo", "deny"]]
        manifests = {call[call.index("--manifest-path") + 1] for call in scans}
        expected = {str(self.root / name) for name in ("Cargo.toml", "rs/Cargo.toml", "apex/Cargo.toml")}
        self.assertEqual(manifests, expected)
        self.assertEqual(len(scans), len(expected))

    def test_actions_are_checked_without_workflows(self) -> None:
        self.write("custom/action.yml", "name: custom\n")
        result = self.run_runner()
        self.assertEqual(result.returncode, 0, result.stderr)
        scan = next(call for call in self.calls() if call[0] == "zizmor")
        self.assertIn("custom/action.yml", scan)
        self.assertIn("--offline", scan)

    def test_windows_delegates_to_the_named_distro(self) -> None:
        _ = (self.bin / "wsl").write_bytes((self.bin / "typos").read_bytes())
        (self.bin / "wsl").chmod(0o755)
        self.environment["LINT_WSL_DISTRO"] = "lint-test"
        program = 'OSTYPE=msys; pwd() { printf "%s\\n" "C:/test repo"; }; source "${1}"'
        result = subprocess.run(
            [BASH or "bash", "-c", program, "bash", str(SCRIPT.with_name("repo_checks.sh"))],
            cwd=self.root,
            env=self.environment,
            capture_output=True,
            text=True,
            encoding="utf-8",
            check=False,
            timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(
            self.calls(),
            [
                [
                    "wsl",
                    "--distribution",
                    "lint-test",
                    "--cd",
                    "C:/test repo",
                    "--",
                    "bash",
                    ".github/lint/repo_checks.sh",
                ]
            ],
        )


if __name__ == "__main__":
    _ = unittest.main()
