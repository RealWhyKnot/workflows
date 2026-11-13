from __future__ import annotations

import re
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
        for content in [
            "let brace = '{';",
            "// {",
            "/* { */",
            'let raw = r#"{"#;',
            r"let byte = b'\x7b';",
            r"let character = '\u{7b}';",
            'let raw = br##"{"##;',
        ]:
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

    def test_inline_test_attribute_ends_before_body_brackets(self) -> None:
        result = self.check_rust(
            lines("#[cfg(test)] fn cases() { let v = [", '    value.expect("short");', "    1]; }")
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_inner_test_attribute_applies_to_its_module_only(self) -> None:
        for opening, ending in [("#![cfg(test)]", ""), ("mod cases { #![cfg(test)]", "}")]:
            with self.subTest(opening=opening):
                result = self.check_rust(lines(opening, 'fn check() { value.expect("short"); }', ending))
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.check_rust(
            lines(
                'mod cases { #![cfg(test)] fn check() { value.expect("short"); } }',
                'fn run() { value.expect("short"); }',
            )
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(len(result.stdout.splitlines()), 1)
        self.assertIn("src/lib.rs:2:", result.stdout)

    def test_stacked_attributes_keep_test_scope(self) -> None:
        result = self.check_rust(
            lines(
                '#[allow(dead_code)] #[cfg(test)] fn cases() { value.expect("short"); }',
                'fn run() { value.expect("short"); }',
            )
        )
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(len(result.stdout.splitlines()), 1)
        self.assertIn("src/lib.rs:2:", result.stdout)

    def test_long_line_work_scales_with_length(self) -> None:
        source = (BASELINE / "rust/.github/lint/rust-style.awk").read_text(encoding="utf-8")
        source = re.sub(r"(?m)^(\s*)(\w+) = \2 (.+)$", r"\1\2 = measured_join(\2, \3)", source)
        measured = source.replace("substr(", "measured_substr(").replace(
            "exit has_findings", 'print "copied=" copied; exit has_findings'
        ) + lines(
            "function measured_substr(text, start, size) {",
            '  if (size == "") size = length(text) - start + 1',
            "  copied += size",
            "  return substr(text, start, size)",
            "}",
            "function measured_join(left, right) {",
            "  copied += length(left) + length(right)",
            "  return left right",
            "}",
        )
        self.write("measured.awk", measured)
        self.write(".github/lint/vendored-paths.txt", "")
        costs: list[int] = []
        for size in (4000, 8000):
            self.write("src/lib.rs", "x" * size + "\n")
            result = subprocess.run(
                [AWK or "awk", "-f", "measured.awk", "src/lib.rs"],
                cwd=self.root,
                capture_output=True,
                text=True,
                encoding="utf-8",
                check=True,
                timeout=60,
            )
            costs.append(int(result.stdout.removeprefix("copied=")))
        self.assertLessEqual(costs[1], costs[0] * 2.1, costs)

    def test_strings_and_comments_do_not_report_code_findings(self) -> None:
        bad = 'pub unsafe fn run() { value.expect("short"); value.map_err(|e| e.to_string()); }'
        result = self.check_rust(lines(f"/* {bad} */", f"// {bad}", f'let text = r##"{bad}"##;'))
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        result = self.check_rust(lines(f"/* {bad} */ {bad}"))
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertEqual(len(result.stdout.splitlines()), 3, result.stdout)

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
