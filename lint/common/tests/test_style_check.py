from __future__ import annotations

import shutil
import subprocess
import sys
import tempfile
import unittest
from dataclasses import dataclass
from pathlib import Path
from typing import override

BASELINE = Path(__file__).resolve().parents[2]
SCRIPT = BASELINE / "common" / ".github" / "lint" / "style_check.py"
MODULES = ("style_check.py", "style_configs.py", "style_scan.py", "style_sources.py")
VENDORED = SCRIPT.with_name("vendored-paths.txt")
LOCAL = ".github/lint/vendored-paths.local.txt"
GIT = shutil.which("git") or "git"


def lines(*rows: str) -> str:
    return "\n".join(rows) + "\n"


@dataclass(frozen=True, slots=True)
class CheckResult:
    code: int
    found: list[str]


class RepoCase(unittest.TestCase):
    @override
    def setUp(self) -> None:
        self.folder = tempfile.TemporaryDirectory(prefix="style-check-")
        self.root = Path(self.folder.name)
        subprocess.run([GIT, "init", "-q", str(self.root)], check=True, timeout=60)
        subprocess.run([GIT, "-C", str(self.root), "config", "core.autocrlf", "false"], check=True, timeout=60)

    @override
    def tearDown(self) -> None:
        self.folder.cleanup()

    def write(self, path: str, text: str) -> None:
        target = self.root / path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(text.encode("utf-8"))
        subprocess.run([GIT, "-C", str(self.root), "add", path], check=True, timeout=60)

    def run_check(self) -> CheckResult:
        result = subprocess.run(
            [sys.executable, "-B", str(SCRIPT), str(self.root)],
            capture_output=True,
            text=True,
            encoding="utf-8",
            check=False,
            timeout=120,
        )
        found = [line for line in result.stdout.splitlines() if not line.endswith(" findings")]
        return CheckResult(result.returncode, found)

    def assert_clean(self) -> None:
        result = self.run_check()
        self.assertEqual(result.found, [])
        self.assertEqual(result.code, 0)

    def assert_findings(self, expected: list[str]) -> None:
        result = self.run_check()
        self.assertEqual(result.found, expected)
        self.assertEqual(result.code, 1)


class SourceTests(RepoCase):
    def test_clean_repo_passes(self) -> None:
        self.write(
            "src/main.rs", lines("fn main() {", '    let url = "http://example.com";', '    println!("{url}");', "}")
        )
        self.write("app.py", lines("import sys", "", 'sys.stdout.write("# not a comment\\n")'))
        self.write("Program.cs", lines('var path = @"C:\\temp\\";', 'var text = $"{path} // still a string";'))
        self.assert_clean()

    def test_rust_comments_are_found_outside_strings(self) -> None:
        self.write(
            "src/lib.rs",
            lines(
                "pub fn a() -> &'static str {",
                '    r#"// raw "quoted" text"#',
                "}",
                "pub fn b() {}",
                "// plain comment",
                "/* outer /* nested */ still */",
                "/// doc",
            ),
        )
        self.assert_findings(
            [
                "src/lib.rs:5: comment (GEN-29)",
                "src/lib.rs:6: comment (GEN-29)",
                "src/lib.rs:7: comment (GEN-29)",
            ]
        )

    def test_rust_safety_comment_is_allowed(self) -> None:
        self.write(
            "src/lib.rs",
            lines(
                "pub fn read(pointer: *const u8) -> u8 {",
                "    // SAFETY: the caller passes a valid pointer",
                "    unsafe { *pointer }",
                "}",
            ),
        )
        self.assert_clean()

    def test_rust_lifetime_and_raw_identifier_are_not_literals(self) -> None:
        self.write(
            "src/lib.rs",
            lines(
                "pub fn first<'a>(items: &'a [u8]) -> &'a u8 {",
                "    let r#type = 0;",
                "    &items[r#type]",
                "}",
                "// x",
            ),
        )
        self.assert_findings(["src/lib.rs:5: comment (GEN-29)"])

    def test_c_and_cpp_suppressions_are_found(self) -> None:
        self.write(
            "src/a.cpp",
            lines(
                "int a = b; // NOLINT(bugprone-x)",
                "// NOLINTNEXTLINE",
                "#pragma warning(disable: 4996)",
                '  #  pragma GCC diagnostic ignored "-Wunused"',
                '#pragma clang diagnostic ignored "-Wshadow"',
                "// clang-format off",
                "// cppcheck-suppress nullPointer",
                "#pragma system_header",
                "#pragma warning(push)",
                "#pragma once",
                "// a plain comment",
            ),
        )
        self.write("src/b.h", lines("/* NOLINTBEGIN */"))
        self.write("src/c.c", "int x;\n" * 700)
        self.assert_findings(
            [
                "src/a.cpp:1: lint suppression (GEN-4)",
                "src/a.cpp:2: lint suppression (GEN-4)",
                "src/a.cpp:3: lint suppression (GEN-4)",
                "src/a.cpp:4: lint suppression (GEN-4)",
                "src/a.cpp:5: lint suppression (GEN-4)",
                "src/a.cpp:6: lint suppression (GEN-4)",
                "src/a.cpp:7: lint suppression (GEN-4)",
                "src/a.cpp:8: lint suppression (GEN-4)",
                "src/b.h:1: lint suppression (GEN-4)",
            ],
        )

    def test_c_and_cpp_strings_are_not_suppressions(self) -> None:
        self.write(
            "src/a.cpp",
            lines(
                'const char* a = "NOLINT";',
                'puts("clang-format off \\" NOLINTNEXTLINE");',
                'const char* b = "x"; // NOLINT',
            ),
        )
        self.assert_findings(["src/a.cpp:3: lint suppression (GEN-4)"])

    def test_rust_suppressions_are_found(self) -> None:
        self.write(
            "src/lib.rs",
            lines(
                "#![allow(dead_code)]",
                '#[expect(clippy::unwrap_used, reason = "x")]',
                "pub fn a() {}",
                "#[cfg_attr(test, allow(unused))]",
                "pub fn b() {}",
                "#[derive(Debug)]",
                "pub struct C;",
                "#[rustfmt::skip]",
                "pub fn d() {}",
                "#[cfg_attr(rustfmt, rustfmt_skip)]",
                "pub fn e() {}",
                "#[cfg_attr(rustfmt, rustfmt::skip)]",
                "pub fn f() {}",
            ),
        )
        self.assert_findings(
            [
                "src/lib.rs:1: lint suppression (GEN-4)",
                "src/lib.rs:2: lint suppression (GEN-4)",
                "src/lib.rs:4: lint suppression (GEN-4)",
                "src/lib.rs:8: lint suppression (GEN-4)",
                "src/lib.rs:10: lint suppression (GEN-4)",
                "src/lib.rs:12: lint suppression (GEN-4)",
            ]
        )

    def test_rust_test_module_does_not_count_toward_lines(self) -> None:
        body = "pub fn a() {}\n" * 590
        tests = "#[cfg(test)]\nmod tests {\n" + "    fn t() {}\n" * 50 + "}\n"
        self.write("src/lib.rs", body + tests)
        self.assert_clean()
        self.write("src/other.rs", "pub fn a() {}\n" * 601)
        self.assert_findings(["src/other.rs: 601 lines, over 600 (GEN-15)"])

    def test_csharp_comments_and_suppressions(self) -> None:
        self.write(
            "src/App.cs",
            lines(
                'var raw = """',
                "  // inside raw",
                '  """;',
                'var nested = $"{(true ? "}" : "//")}";',
                "#pragma warning disable CA1031",
                "#region Setup",
                "// note",
                '[SuppressMessage("x", "y")]',
                "class A { }",
            ),
        )
        self.assert_findings(
            [
                "src/App.cs:5: lint suppression (GEN-4)",
                "src/App.cs:7: comment (GEN-29)",
                "src/App.cs:8: lint suppression (GEN-4)",
            ]
        )

    def test_licence_header_is_allowed(self) -> None:
        self.write("src/A.cs", lines("// SPDX-License-Identifier: GPL-3.0-or-later", "// Copyright me", "class A { }"))
        self.write("tool.py", lines("# Licensed under the GPL", "import sys"))
        self.assert_clean()

    def test_tool_directives_in_licence_header_fail(self) -> None:
        self.write("tool.py", lines("# Copyright me", "# pyright: basic", "# ruff: noqa", "import sys"))
        self.write("src/A.cs", lines("// SPDX-License-Identifier: MIT", "// <auto-generated/>", "class A { }"))
        self.write("src/lib.rs", lines("// Copyright me", "// Licensed under MIT", "pub fn a() {}"))
        self.assert_findings(
            [
                "src/A.cs:2: tool directive in the licence header (GEN-4)",
                "tool.py:2: tool directive in the licence header (GEN-4)",
                "tool.py:3: tool directive in the licence header (GEN-4)",
            ]
        )

    def test_installed_modules_pass_their_own_check(self) -> None:
        for name in MODULES:
            self.write(f".github/lint/{name}", SCRIPT.with_name(name).read_text(encoding="utf-8"))
        self.write(f".github/lint/{VENDORED.name}", VENDORED.read_text(encoding="utf-8"))
        self.assert_clean()

    def test_lint_files_at_the_root_belong_in_lint(self) -> None:
        self.write("style_check.py", SCRIPT.read_text(encoding="utf-8"))
        self.write("vendored-paths.txt", VENDORED.read_text(encoding="utf-8"))
        self.write("vendored-paths.local.txt", lines("upstream-lib/"))
        self.write("PSScriptAnalyzerSettings.psd1", lines("@{}"))
        self.write("tsconfig.base.json", lines("{}"))
        self.write("scripts/PSScriptAnalyzerSettings.psd1", lines("@{}"))
        self.write(".github/lint/PSScriptAnalyzerSettings.psd1", lines("@{}"))
        self.write(".github/lint/tsconfig.base.json", lines("{}"))
        self.write(".lint/style_scan.py", SCRIPT.with_name("style_scan.py").read_text(encoding="utf-8"))
        self.write(".lint/CSharpStyle/Program.cs", lines("return 0;"))
        self.assert_findings(
            [
                ".lint/CSharpStyle/Program.cs: belongs in .github/lint/ (GEN-5)",
                ".lint/style_scan.py: belongs in .github/lint/ (GEN-5)",
                "PSScriptAnalyzerSettings.psd1: belongs in .github/lint/ (GEN-5)",
                "scripts/PSScriptAnalyzerSettings.psd1: nested lint or format config overrides the baseline (GEN-5)",
                "style_check.py: belongs in .github/lint/ (GEN-5)",
                "tsconfig.base.json: belongs in .github/lint/ (GEN-5)",
                "vendored-paths.local.txt: belongs in .github/lint/ (GEN-5)",
                "vendored-paths.txt: belongs in .github/lint/ (GEN-5)",
            ]
        )

    def test_python_comments_docstrings_and_noqa(self) -> None:
        self.write(
            "tool.py",
            lines(
                "#!/usr/bin/env python3",
                "# -*- coding: utf-8 -*-",
                '"""Module docstring."""',
                "import os  # noqa: F401",
                "",
                "",
                "def f() -> str:",
                '    """Doc."""',
                '    return "#"',
            ),
        )
        self.assert_findings(
            [
                "tool.py:3: docstring or string used as a comment (GEN-29)",
                "tool.py:4: comment (GEN-29)",
                "tool.py:8: docstring or string used as a comment (GEN-29)",
            ]
        )

    def test_extensionless_scripts_are_classified_by_shebang(self) -> None:
        self.write(".githooks/pre-push", "#!/usr/bin/env bash\n" + "true\n" * 601)
        self.write("bin/run", lines("#!/usr/bin/env python3", "# comment"))
        self.write("deploy.sh.tpl", "#!/bin/sh\n" + "true\n" * 601)
        self.write("README", lines("# Title"))
        self.assert_findings(
            [
                ".githooks/pre-push: 602 lines, over 600 (GEN-15)",
                "bin/run:2: comment (GEN-29)",
                "deploy.sh.tpl: 602 lines, over 600 (GEN-15)",
            ]
        )

    def test_long_files_in_every_language(self) -> None:
        self.write("web/app.ts", "export {};\n" * 601)
        self.write("tools/Run.ps1", "$x = 1\n" * 601)
        self.write("web/page.astro", "---\n" * 601)
        self.write("web/theme.css", "a {}\n" * 601)
        self.assert_findings(
            [
                "tools/Run.ps1: 601 lines, over 600 (GEN-15)",
                "web/app.ts: 601 lines, over 600 (GEN-15)",
                "web/page.astro: 601 lines, over 600 (GEN-15)",
                "web/theme.css: 601 lines, over 600 (GEN-15)",
            ]
        )

    def test_preprocessor_files_fail(self) -> None:
        self.write("web/theme.scss", lines("a { b: c; }"))
        self.write("web/old.less", lines("a { b: c; }"))
        self.write("web/plain.css", lines("a { b: c; }"))
        self.assert_findings(
            [
                "web/old.less: Sass, Less or Stylus file; write plain CSS (CSS-10)",
                "web/theme.scss: Sass, Less or Stylus file; write plain CSS (CSS-10)",
            ]
        )


class VendoredPathTests(RepoCase):
    def test_vendored_paths_are_skipped(self) -> None:
        self.write("vendor/lib.rs", lines("// upstream"))
        self.write("deep/third_party/x.py", lines("# upstream"))
        self.write(".yarn/releases/yarn-4.cjs", "x;\n" * 700)
        self.write("src/lib/own.py", lines("# own code"))
        self.assert_findings(["src/lib/own.py:1: comment (GEN-29)"])

    def test_local_list_adds_the_repo_s_own_folders(self) -> None:
        self.write(LOCAL, lines("upstream-lib/", "", "/Packages/com.example.upstream/"))
        self.write("upstream-lib/src/a.cs", lines("// upstream"))
        self.write("deep/upstream-lib/x.py", lines("# upstream"))
        self.write("Packages/com.example.upstream/Runtime/A.cs", lines("// upstream"))
        self.write("pkg/Packages/com.example.upstream/a.py", lines("# own code"))
        self.assert_findings(["pkg/Packages/com.example.upstream/a.py:1: comment (GEN-29)"])

    def test_local_list_can_name_single_files(self) -> None:
        self.write(LOCAL, lines("/docs/NOTICE.py"))
        self.write("docs/NOTICE.py", lines("# upstream"))
        self.write("docs/NOTICE.py.bak.py", lines("# own code"))
        self.write("other/docs/NOTICE.py", lines("# own code"))
        self.assert_findings(
            [
                "docs/NOTICE.py.bak.py:1: comment (GEN-29)",
                "other/docs/NOTICE.py:1: comment (GEN-29)",
            ],
        )

    def test_folder_entry_without_slash_is_reported(self) -> None:
        self.write(LOCAL, lines("/external"))
        self.write("external/a.py", lines("x = 1"))
        self.assert_findings([f"{LOCAL}:1: /external is a folder; end it with /"])

    def test_bad_local_entry_is_a_setup_error(self) -> None:
        for entry in ("*.cs", "upstream-lib", "a/b/", "/../x/", '"x"/', "/docs/..", "/a//b"):
            with self.subTest(entry=entry):
                self.write(LOCAL, lines(entry))
                result = self.run_check()
                self.assertEqual(result.code, 2)

    def test_installed_list_must_hold_every_local_entry(self) -> None:
        lint = self.root / ".github" / "lint"
        lint.mkdir(parents=True)
        for name in (*MODULES, VENDORED.name):
            shutil.copy(SCRIPT.with_name(name), lint / name)
        self.write(LOCAL, lines("upstream-lib/", "vendor/"))
        self.write("upstream-lib/a.py", lines("# upstream"))
        installed = [sys.executable, "-B", str(lint / SCRIPT.name), str(self.root)]
        result = subprocess.run(installed, capture_output=True, text=True, encoding="utf-8", check=False, timeout=120)
        self.assertEqual(result.returncode, 1)
        self.assertEqual(
            result.stdout.splitlines()[0],
            f"{LOCAL}: upstream-lib/ isn't in {VENDORED.name} yet. Run Install-Lint again (GEN-1)",
        )
        folded = lint / VENDORED.name
        folded.write_text(folded.read_text(encoding="utf-8") + "upstream-lib/\n", encoding="utf-8")
        result = subprocess.run(installed, capture_output=True, text=True, encoding="utf-8", check=False, timeout=120)
        self.assertEqual((result.returncode, result.stdout), (0, ""))


class CSharpTests(RepoCase):
    def test_nullable_annotations_and_generated_code_attribute(self) -> None:
        self.write(
            "src/App.cs",
            lines(
                "#nullable enable annotations",
                "#nullable enable",
                '[GeneratedCode("tool", "1.0")]',
                "class A { }",
                '[Serializable, System.CodeDom.Compiler.GeneratedCodeAttribute("tool", "1.0")]',
                "class B { }",
                'var text = "[GeneratedCode(";',
                "class GeneratedCodeHelper { }",
            ),
        )
        self.assert_findings(
            [
                "src/App.cs:1: lint suppression (GEN-4)",
                "src/App.cs:3: GeneratedCode attribute hides the type from analyzers (GEN-4)",
                "src/App.cs:5: GeneratedCode attribute hides the type from analyzers (GEN-4)",
            ]
        )

    def test_generated_file_names(self) -> None:
        for name in ("A.g.cs", "B.g.i.cs", "C.Generated.cs", "obj/TemporaryGeneratedFile_1.cs"):
            self.write(name, lines("class X { }"))
        self.write("Forms/Main.cs", lines("partial class Main { }"))
        self.write("Forms/Main.Designer.cs", lines("partial class Main { }"))
        self.write("Properties/Resources.Designer.cs", lines("class Resources { }"))
        self.write("Properties/Resources.resx", lines("<root />"))
        self.assert_findings(
            [
                "A.g.cs: generated C# file is committed, and analyzers skip it (GEN-4)",
                "B.g.i.cs: generated C# file is committed, and analyzers skip it (GEN-4)",
                "C.Generated.cs: generated C# file is committed, and analyzers skip it (GEN-4)",
                "Properties/Resources.Designer.cs: Designer.cs with no same-name .cs, so analyzers skip it (GEN-4)",
                "obj/TemporaryGeneratedFile_1.cs: generated C# file is committed, and analyzers skip it (GEN-4)",
            ]
        )

    def test_project_settings_that_turn_checks_off(self) -> None:
        self.write(
            "App/App.csproj",
            lines(
                "<Project>",
                "  <PropertyGroup>",
                "    <WarningLevel>0</WarningLevel>",
                "    <GenerateDocumentationFile>false</GenerateDocumentationFile>",
                "    <Features>strict;run-nullable-analysis=never</Features>",
                "    <WarningLevel>4</WarningLevel>",
                "  </PropertyGroup>",
                "  <ItemGroup>",
                '    <EditorConfigFiles Remove="../.editorconfig" />',
                '    <GlobalAnalyzerConfigFiles Include="quiet.globalconfig" />',
                "  </ItemGroup>",
                "</Project>",
            ),
        )
        self.write("build/common.props", lines("<Project>", "  <PropertyGroup>", "    <NoWarn>CA1031</NoWarn>"))
        self.assert_findings(
            [
                "App/App.csproj:3: project setting loosens the baseline (GEN-4)",
                "App/App.csproj:4: project setting loosens the baseline (GEN-4)",
                "App/App.csproj:5: project setting loosens the baseline (GEN-4)",
                "App/App.csproj:9: project setting loosens the baseline (GEN-4)",
                "App/App.csproj:10: project setting loosens the baseline (GEN-4)",
                "build/common.props:3: project setting loosens the baseline (GEN-4)",
            ]
        )

    def test_baseline_props_pass_and_lower_analysis_fails(self) -> None:
        baseline = BASELINE / "csharp" / "Directory.Build.props"
        props = baseline.read_text(encoding="utf-8")
        self.assertIn("<GenerateDocumentationFile>true</GenerateDocumentationFile>", props)
        self.assertIn("<PublishDocumentationFiles>false</PublishDocumentationFiles>", props)
        self.write("Directory.Build.props", props)
        self.write(
            "App/App.csproj",
            lines(
                "<Project>",
                "  <PropertyGroup>",
                "    <AnalysisLevel>latest-recommended</AnalysisLevel>",
                "    <AnalysisModeSecurity>None</AnalysisModeSecurity>",
                "    <AnalysisMode>All</AnalysisMode>",
                "  </PropertyGroup>",
                "</Project>",
            ),
        )
        self.assert_findings(
            [
                "App/App.csproj:3: project setting loosens the baseline (GEN-4)",
                "App/App.csproj:4: project setting loosens the baseline (GEN-4)",
            ]
        )


if __name__ == "__main__":
    unittest.main()
