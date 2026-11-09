from __future__ import annotations

import shutil
import subprocess
import sys
import unittest

from lint.common.tests.test_style_check import BASELINE, MODULES, SCRIPT, VENDORED, RepoCase, lines


class ConfigTests(RepoCase):
    def test_every_package_inherits_workspace_lints(self) -> None:
        self.write(
            "Cargo.toml",
            lines(
                "[workspace]",
                'members = ["*"]',
                "[workspace.lints.clippy]",
                "unwrap_used = 'deny'",
                "[package]",
                "name = 'r'",
            ),
        )
        self.write("bare/Cargo.toml", lines("[package]", "name = 'bare'"))
        self.write("good/Cargo.toml", lines("[package]", "name = 'good'", "[lints]", "workspace = true"))
        self.write("tools/Cargo.toml", lines("[workspace]", "[package]", "name = 'tools'"))
        self.write("tools/sub/Cargo.toml", lines("[package]", "name = 'sub'"))
        self.assert_findings(
            [
                "Cargo.toml: [package] lacks [lints] workspace = true, so workspace lints don't apply (GEN-5)",
                "bare/Cargo.toml: [package] lacks [lints] workspace = true, so workspace lints don't apply (GEN-5)",
            ]
        )

    def test_nested_configs_are_rejected(self) -> None:
        self.write("eslint.config.mjs", lines("export default [];"))
        self.write("edge/eslint.config.mjs", lines("export default [];"))
        self.write("api/.eslintrc.json", lines("{}"))
        self.write("crate/rustfmt.toml", lines("max_width = 200"))
        self.write("crate/clippy.toml", lines("too-many-lines-threshold = 900"))
        self.write("svc/pyproject.toml", lines("[project]", 'name = "svc"', "[tool.ruff]", "line-length = 200"))
        self.write("web/package.json", lines('{"name": "web", "eslintConfig": {}}'))
        self.write("site/package.json", lines('{"name": "site", "prettier": {}}'))
        self.write("styles/package.json", lines('{"name": "styles", "stylelint": {}}'))
        self.write("site/stylelint.config.mjs", lines("export default {};"))
        self.write("site/.stylelintrc.json", lines("{}"))
        self.assert_findings(
            [
                "api/.eslintrc.json: lint or format config the baseline doesn't use (GEN-5)",
                "crate/clippy.toml: nested lint or format config overrides the baseline (GEN-5)",
                "crate/rustfmt.toml: nested lint or format config overrides the baseline (GEN-5)",
                "edge/eslint.config.mjs: nested lint or format config overrides the baseline (GEN-5)",
                "site/.stylelintrc.json: lint or format config the baseline doesn't use (GEN-5)",
                "site/package.json: eslintConfig, prettier or stylelint key overrides the baseline (GEN-5)",
                "site/stylelint.config.mjs: nested lint or format config overrides the baseline (GEN-5)",
                "styles/package.json: eslintConfig, prettier or stylelint key overrides the baseline (GEN-5)",
                "svc/pyproject.toml: [tool.ruff] or [tool.pyright] overrides the baseline (GEN-5)",
                "web/package.json: eslintConfig, prettier or stylelint key overrides the baseline (GEN-5)",
            ]
        )

    def test_unity_props_pass_beside_headless_and_lint_projects(self) -> None:
        merge = BASELINE / "csharp" / "merge" / "unity"
        props = (merge / "Directory.Build.props").read_text(encoding="utf-8")
        targets = (merge / "Directory.Build.targets").read_text(encoding="utf-8")
        self.write("ProjectSettings/ProjectVersion.txt", lines("m_EditorVersion: 6000.7.0b7"))
        self.write("headless/Directory.Build.props", props)
        self.write("headless/Directory.Build.targets", targets)
        self.write(".github/lint/unity/Directory.Build.props", props)
        self.assert_clean()

    def test_unity_props_fail_deeper_or_under_a_root_baseline(self) -> None:
        merge = BASELINE / "csharp" / "merge" / "unity"
        props = (merge / "Directory.Build.props").read_text(encoding="utf-8")
        self.write("Directory.Build.props", props)
        self.write("headless/Directory.Build.props", props)
        self.write(".github/lint/unity/App/Directory.Build.props", props)
        self.write(".github/lint/Directory.Build.props", props)
        self.write("tools/Directory.Build.props", props)
        self.write(
            ".github/lint/unity/Directory.Build.targets",
            lines("<Project>", "  <PropertyGroup>", "    <NoWarn>CA1000</NoWarn>", "  </PropertyGroup>", "</Project>"),
        )
        self.assert_findings(
            [
                ".github/lint/Directory.Build.props: nested lint or format config overrides the baseline (GEN-5)",
                (
                    ".github/lint/unity/App/Directory.Build.props: "
                    "nested lint or format config overrides the baseline (GEN-5)"
                ),
                (".github/lint/unity/Directory.Build.targets:3: project setting loosens the baseline (GEN-4)"),
                "headless/Directory.Build.props: nested lint or format config overrides the baseline (GEN-5)",
                "tools/Directory.Build.props: nested lint or format config overrides the baseline (GEN-5)",
            ]
        )

    def test_old_unity_lint_folder_belongs_in_lint(self) -> None:
        props = (BASELINE / "csharp" / "merge" / "unity" / "Directory.Build.props").read_text(encoding="utf-8")
        self.write("ProjectSettings/ProjectVersion.txt", lines("m_EditorVersion: 6000.7.0b7"))
        self.write("lint/Directory.Build.props", props)
        self.write("lint/App.Editor.csproj", lines("<Project />"))
        self.assert_findings(
            [
                "lint/App.Editor.csproj: Unity lint projects belong in .github/lint/unity/ (GEN-5)",
                "lint/Directory.Build.props: Unity lint projects belong in .github/lint/unity/ (GEN-5)",
            ]
        )

    def test_cargo_and_csproj_overrides(self) -> None:
        self.write("Cargo.toml", lines("[workspace]", "members = []", "[workspace.lints.clippy]", "all = 'deny'"))
        self.write("good/Cargo.toml", lines("[package]", "name = 'good'", "[lints]", "workspace = true"))
        self.write("bad/Cargo.toml", lines("[package]", "name = 'bad'", "[lints.clippy]", "unwrap_used = 'allow'"))
        self.write("App/App.csproj", lines("<Project>", "  <PropertyGroup>", "    <NoWarn>CA1031</NoWarn>"))
        self.write("Lib/Lib.csproj", lines("<Project>", "  <PropertyGroup>", "    <Nullable>enable</Nullable>"))
        self.assert_findings(
            [
                "App/App.csproj:3: project setting loosens the baseline (GEN-4)",
                "bad/Cargo.toml: [lints] other than workspace = true overrides the baseline (GEN-5)",
            ]
        )

    def test_vendored_configs_are_ignored(self) -> None:
        self.write("vendor/thing/.eslintrc.json", lines("{}"))
        self.write("vendor/thing/rustfmt.toml", lines("max_width = 200"))
        self.assert_clean()

    def test_missing_vendored_list_is_a_setup_error(self) -> None:
        copy = self.root / "copy"
        copy.mkdir()
        for name in MODULES:
            shutil.copy(SCRIPT.with_name(name), copy / name)
        result = subprocess.run(
            [sys.executable, "-B", str(copy / SCRIPT.name), str(self.root)],
            capture_output=True,
            text=True,
            encoding="utf-8",
            check=False,
            timeout=120,
        )
        self.assertEqual(result.returncode, 2)
        self.assertIn(VENDORED.name, result.stderr)


if __name__ == "__main__":
    unittest.main()
