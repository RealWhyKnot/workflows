from __future__ import annotations

from lint.common.tests.test_style_check import BASELINE, RepoCase, lines


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
