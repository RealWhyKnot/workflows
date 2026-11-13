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

    def test_acyclic_imports_do_not_expand_ancestors(self) -> None:
        program = lines(
            "import sys",
            f"sys.path.insert(0, {str(SCRIPT.parent)!r})",
            "from style_imports import Index, check_imports",
            "original = Index.spread",
            "visits = 0",
            "def counted(self, start):",
            "    global visits",
            "    result = original(self, start)",
            "    visits += len(result)",
            "    return result",
            "Index.spread = counted",
            "count = 2000",
            "target = sys.argv[1]",
            "sources = {f'm{i}.py': f'import m{i + 1}\\ndef run():\\n    import {target}\\n' for i in range(count)}",
            "sources[f'm{count}.py'] = ''",
            "sources['light.py'] = ''",
            "assert len(check_imports(sources)) == count",
            "assert visits <= count * 2, visits",
        )
        for target in ("json", "light"):
            with self.subTest(target=target):
                result = subprocess.run(
                    [sys.executable, "-B", "-c", program, target],
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
