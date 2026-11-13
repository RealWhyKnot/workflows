from __future__ import annotations

import shutil
import subprocess
import unittest

from lint.common.tests.test_style_check import BASELINE, VENDORED, RepoCase, lines

AWK = shutil.which("awk")


@unittest.skipUnless(AWK, "awk is required")
class RustStyleTests(RepoCase):
    def check_rust(self, text: str) -> subprocess.CompletedProcess[str]:
        self.write(".github/lint/vendored-paths.txt", VENDORED.read_text(encoding="utf-8"))
        self.write("src/lib.rs", text)
        return subprocess.run(
            [AWK or "awk", "-f", str(BASELINE / "rust/.github/lint/rust-style.awk"), "src/lib.rs"],
            cwd=self.root,
            capture_output=True,
            text=True,
            encoding="utf-8",
            check=False,
            timeout=60,
        )

    def test_char_and_comment_braces_do_not_hide_production(self) -> None:
        for content in ["let brace = '{';", "// {", "/* { */", 'let raw = r#"{"#;']:
            with self.subTest(content=content):
                result = self.check_rust(
                    lines("#[cfg(test)]", "mod checks {", content, "}", 'fn run() { value.expect("short"); }')
                )
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
                self.assertIn("src/lib.rs:5:", result.stdout)

    def test_array_semicolon_does_not_end_test_function(self) -> None:
        result = self.check_rust(
            lines("#[cfg(test)]", "fn check(value: [u8; 4])", "{", '    value.expect("short");', "}")
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_multiline_cfg_and_following_production_on_same_line(self) -> None:
        result = self.check_rust(
            lines(
                "#[cfg(all(",
                "    test, unix",
                "))]",
                'fn check() { value.expect("short"); }',
                '#[cfg(test)] mod checks {} fn run() { value.expect("short"); }',
            )
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(len(result.stdout.splitlines()), 1, result.stdout)
        self.assertIn("src/lib.rs:5:", result.stdout)

    def test_compound_cfg_requires_test(self) -> None:
        for predicate in [
            'all(test, feature = "extra")',
            'all(feature = "extra", test)',
            "all(any(unix, windows), test)",
        ]:
            with self.subTest(predicate=predicate):
                result = self.check_rust(lines(f"#[cfg({predicate})]", 'fn check() { value.expect("short"); }'))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_optional_or_negated_test_does_not_hide_production(self) -> None:
        for predicate in ["any(test, unix)", "not(test)", "all(not(test), unix)"]:
            with self.subTest(predicate=predicate):
                result = self.check_rust(lines(f"#[cfg({predicate})]", 'fn run() { value.expect("short"); }'))
                self.assertEqual(result.returncode, 1, result.stdout + result.stderr)


if __name__ == "__main__":
    _ = unittest.main()
