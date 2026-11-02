from __future__ import annotations

import subprocess
import sys
import unittest

from lint.common.tests.test_style_check import BASELINE, SCRIPT, RepoCase, lines


class ConfigErrorTests(RepoCase):
    def test_unreadable_config_reports_a_finding(self) -> None:
        script = lines(
            "import sys",
            "from pathlib import Path",
            "from unittest.mock import patch",
            "import style_configs",
            'with patch("style_configs.read_json", side_effect=PermissionError("denied")):',
            '    findings = style_configs.check_config("package.json", Path(sys.argv[1]))',
            '    sys.stdout.write("\\n".join(finding.render() for finding in findings))',
        )
        result = subprocess.run(
            [sys.executable, "-B", "-c", script, str(self.root)],
            cwd=SCRIPT.parent,
            capture_output=True,
            text=True,
            encoding="utf-8",
            check=True,
            timeout=30,
        )
        self.assertIn("package.json:", result.stdout)
        self.assertIn("denied", result.stdout)
        self.assertIn("GEN-19", result.stdout)

    def install_distribution(self) -> None:
        self.write("lint/Install-Lint.ps1", "#!/usr/bin/env pwsh\n")
        self.write(
            "lint/common/.github/lint/style_configs.py",
            SCRIPT.with_name("style_configs.py").read_text(encoding="utf-8"),
        )

    def test_distribution_templates_keep_source_checks(self) -> None:
        self.install_distribution()
        self.write("lint/python/ruff.toml", "line-length = 120\n")
        self.write("lint/typescript/eslint.config.mjs", "export default [];\n")
        self.write("lint/csharp/install.psd1", (BASELINE / "csharp/install.psd1").read_text(encoding="utf-8"))
        self.write("lint/csharp/merge/unity/Directory.Build.props", "<Project />\n")
        self.assert_clean()
        self.write("lint/python/tool.py", "# ordinary comment\n")
        result = self.run_check()
        self.assertEqual(result.code, 1)
        self.assertTrue(any("GEN-29" in line for line in result.found))

    def test_distribution_does_not_hide_nested_configs(self) -> None:
        self.install_distribution()
        self.write("lint/typescript/app/eslint.config.mjs", "export default [];\n")
        self.write("app/ruff.toml", "line-length = 200\n")
        self.assert_findings(
            [
                "app/ruff.toml: nested lint or format config overrides the baseline (GEN-5)",
                "lint/typescript/app/eslint.config.mjs: nested lint or format config overrides the baseline (GEN-5)",
            ]
        )

    def test_normal_repo_lint_folder_is_not_a_distribution(self) -> None:
        self.write("lint/python/ruff.toml", "line-length = 200\n")
        self.assert_findings(["lint/python/ruff.toml: nested lint or format config overrides the baseline (GEN-5)"])

    def test_malformed_json_reports_a_finding(self) -> None:
        self.write("package.json", "{broken")
        result = self.run_check()
        self.assertEqual(result.code, 1)
        self.assertTrue(any("package.json:" in line and "GEN-19" in line for line in result.found))

    def test_malformed_toml_reports_a_finding(self) -> None:
        self.write("pyproject.toml", "[broken")
        result = self.run_check()
        self.assertEqual(result.code, 1)
        self.assertTrue(any("pyproject.toml:" in line and "GEN-19" in line for line in result.found))

    def test_missing_parent_manifest_is_not_a_parse_failure(self) -> None:
        self.write("nested/Cargo.toml", '[package]\nname = "nested"\n')
        self.assert_clean()

    def test_non_object_package_reports_a_finding(self) -> None:
        self.write("package.json", "[]")
        result = self.run_check()
        self.assertEqual(result.code, 1)
        self.assertTrue(any("GEN-19" in line for line in result.found))


if __name__ == "__main__":
    unittest.main()
