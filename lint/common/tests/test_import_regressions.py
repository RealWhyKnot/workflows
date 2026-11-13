from __future__ import annotations

import subprocess
import sys
import unittest

from lint.common.tests.test_style_check import SCRIPT, RepoCase, lines


class ImportRegressionTests(RepoCase):
    def test_namespace_below_src_keeps_heavy_dependency(self) -> None:
        self.write("src/app/__init__.py", "")
        self.write("src/app/sub/heavy.py", "import numpy\n")
        self.write("src/app/main.py", lines("def run():", "    from app.sub import heavy"))
        self.assert_clean()

    def test_relative_import_without_init_is_local(self) -> None:
        self.write("scripts/helper.py", "VALUE = 1\n")
        self.write("scripts/run.py", lines("def run():", "    from . import helper"))
        self.assert_findings(["scripts/run.py:2: import of helper inside a function; it's light (PY-14)"])

    def test_bare_import_uses_the_importers_folder(self) -> None:
        self.write("app_a/helper.py", "import numpy\n")
        self.write("scripts/helper.py", "VALUE = 1\n")
        self.write("scripts/run.py", lines("def run():", "    import helper"))
        self.assert_findings(["scripts/run.py:2: import of helper inside a function; it's light (PY-14)"])

    def test_package_initializer_does_not_make_a_submodule_cycle(self) -> None:
        self.write("app/__init__.py", "from app import main\n")
        self.write("app/light.py", "VALUE = 1\n")
        self.write("app/main.py", lines("def run():", "    from app import light"))
        self.assert_findings(["app/main.py:2: import of light inside a function; it's light (PY-14)"])

    def test_package_root_survives_hyphenated_ancestors(self) -> None:
        self.write("packages/my-lib/src/mylib/__init__.py", "")
        self.write("packages/my-lib/src/mylib/light.py", "VALUE = 1\n")
        self.write("packages/my-lib/src/mylib/main.py", lines("def run():", "    from mylib import light"))
        self.assert_findings(
            ["packages/my-lib/src/mylib/main.py:2: import of light inside a function; it's light (PY-14)"]
        )

    def test_relative_import_in_hyphenated_folder_is_local(self) -> None:
        self.write("other-tools/helper.py", "import numpy\n")
        self.write("my-tools/helper.py", "VALUE = 1\n")
        self.write("my-tools/run.py", lines("def run():", "    from . import helper"))
        self.assert_findings(["my-tools/run.py:2: import of helper inside a function; it's light (PY-14)"])

    def test_parent_reexport_does_not_make_a_submodule_cycle(self) -> None:
        self.write("app/__init__.py", "from app.main import run\n")
        self.write("app/main.py", lines("def run():", "    from app.light import VALUE"))
        self.write("app/light.py", "from app import config\n")
        expected = ["app/main.py:2: import of VALUE inside a function; it's light (PY-14)"]
        self.assert_findings(expected)
        self.write("app/config.py", "VALUE = 1\n")
        self.assert_findings(expected)

    def test_import_graph_work_scales_with_size(self) -> None:
        program = lines(
            "import sys",
            f"sys.path.insert(0, {str(SCRIPT.parent)!r})",
            "from style_imports import check_imports",
            "def work(count, cyclic):",
            "    visits = 0",
            "    def trace(frame, event, arg):",
            "        nonlocal visits",
            "        if event == 'line' and frame.f_code.co_filename.endswith('style_imports.py'):",
            "            visits += 1",
            "        return trace",
            "    sources = {f'm{i}.py': f'import m{(i + 1) % count}\\ndef run():\\n    import m0\\n'",
            "               for i in range(count)}",
            "    if not cyclic:",
            "        sources[f'm{count - 1}.py'] = 'def run():\\n    import m0\\n'",
            "    sys.settrace(trace)",
            "    try:",
            "        assert not check_imports(sources)",
            "    finally:",
            "        sys.settrace(None)",
            "    return visits",
            "for cyclic in (False, True):",
            "    small, large = work(150, cyclic), work(300, cyclic)",
            "    assert large <= small * 2.5, (cyclic, small, large)",
        )
        result = subprocess.run(
            [sys.executable, "-B", "-c", program],
            capture_output=True,
            text=True,
            encoding="utf-8",
            check=False,
            timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stderr)

    def test_lazy_imports_alone_do_not_justify_a_cycle(self) -> None:
        self.write("first.py", lines("def run():", "    import second"))
        self.write("second.py", lines("def run():", "    import first"))
        self.assert_findings(
            [
                "first.py:2: import of second inside a function; it's light (PY-14)",
                "second.py:2: import of first inside a function; it's light (PY-14)",
            ]
        )


if __name__ == "__main__":
    _ = unittest.main()
