import json
import re
import subprocess
import tempfile
import textwrap
import unittest
from pathlib import Path

import pystyle


def run(files: dict[str, str]) -> list[str]:
    with tempfile.TemporaryDirectory() as folder:
        root = Path(folder)
        for name, text in files.items():
            path = root / name
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_text(textwrap.dedent(text), encoding="utf-8")
        sources = sorted(root.rglob("*.py"))
        projects = sorted(root.rglob("pyproject.toml"))
        found = sorted(
            (item.path.relative_to(root).as_posix(), item.line, item.rule)
            for item in pystyle.check_paths(sources, projects, root)
        )
        return [f"{path}:{line} {rule}" for path, line, rule in found]


def run_one(text: str, name: str = "tool.py") -> list[str]:
    return run({name: text})


class SuppressTest(unittest.TestCase):
    def test_broad_suppress_fails(self) -> None:
        text = """
        import contextlib
        from contextlib import suppress

        def main() -> int:
            with contextlib.suppress(Exception):
                pass
            with suppress(BaseException):
                pass
            with suppress(OSError, Exception):
                pass
            return 0
        """
        self.assertEqual(run_one(text), ["tool.py:6 PY-9", "tool.py:8 PY-9", "tool.py:10 PY-9"])

    def test_specific_suppress_passes(self) -> None:
        text = """
        import contextlib

        def main() -> int:
            with contextlib.suppress(FileNotFoundError):
                pass
            return 0
        """
        self.assertEqual(run_one(text), [])

    def test_catch_alls_that_log_or_raise_fail(self) -> None:
        text = """
        import logging

        log = logging.getLogger(__name__)

        class AppError(Exception):
            pass

        def main() -> int:
            try:
                pass
            except Exception:
                log.exception("failed")
            try:
                pass
            except (OSError, BaseException):
                log.warning("failed", exc_info=True)
            try:
                pass
            except Exception as error:
                raise AppError from error
            return 0
        """
        self.assertEqual(run_one(text), ["tool.py:12 PY-9", "tool.py:16 PY-9", "tool.py:20 PY-9"])

    def test_cleanup_that_reraises_passes(self) -> None:
        text = """
        import logging
        from pathlib import Path

        log = logging.getLogger(__name__)

        def main() -> int:
            try:
                pass
            except BaseException:
                Path("partial").unlink(missing_ok=True)
                raise
            try:
                pass
            except OSError:
                log.exception("failed")
            return 0
        """
        self.assertEqual(run_one(text), [])


class CallTest(unittest.TestCase):
    def test_text_subprocess_needs_encoding(self) -> None:
        text = """
        import io
        import subprocess

        def main() -> int:
            subprocess.run(["git"], text=True, check=True, timeout=5)
            subprocess.run(["git"], text=True, encoding="utf-8", check=True, timeout=5)
            io.open("a.txt")
            io.open("a.bin", "rb")
            return 0
        """
        self.assertEqual(run_one(text), ["tool.py:6 PY-2", "tool.py:8 PY-2"])

    def test_waits_need_timeouts(self) -> None:
        text = """
        import socket
        import subprocess
        from urllib.request import urlopen

        def main(options: dict[str, float]) -> int:
            subprocess.run(["git"], check=True)
            urlopen("https://example.com")
            urlopen("https://example.com", None, 5)
            socket.create_connection(("example.com", 443))
            socket.create_connection(("example.com", 443), 5)
            subprocess.run(["git"], check=True, **options)
            return 0
        """
        self.assertEqual(run_one(text), ["tool.py:7 PY-4", "tool.py:8 PY-4", "tool.py:10 PY-4"])

    def test_wall_clock_durations_fail(self) -> None:
        text = """
        import time

        def main() -> int:
            start = time.time()
            elapsed = time.time() - start
            stamp = time.time()
            later = time.monotonic() - time.monotonic()
            return int(elapsed + stamp + later)
        """
        self.assertEqual(run_one(text), ["tool.py:6 PY-5"])

    def test_clients_inside_loops_fail(self) -> None:
        text = """
        import requests

        def main(urls: list[str]) -> int:
            session = requests.Session()
            for url in urls:
                requests.get(url, timeout=5)
                session.get(url, timeout=5)
            return 0
        """
        self.assertEqual(run_one(text), ["tool.py:7 PY-18"])

    def test_growing_strings_in_loops_fail(self) -> None:
        text = """
        def main(names: list[str]) -> int:
            out = ""
            for name in names:
                out += f"{name},"
                line = name
                line += "!"
            return len(out)
        """
        self.assertEqual(run_one(text), ["tool.py:5 PY-16"])

    def test_stdlib_patches_fail(self) -> None:
        text = """
        import unittest
        from unittest.mock import patch

        class ClockTest(unittest.TestCase):
            def test_clock(self) -> None:
                with patch("time.monotonic"), patch("broker.manager.time.monotonic"):
                    pass
        """
        self.assertEqual(run({"tests/test_clock.py": text}), ["tests/test_clock.py:7 PY-21"])


class RecordTest(unittest.TestCase):
    def test_records_are_dataclasses(self) -> None:
        text = """
        def version(tag: str) -> tuple[int, int, int]:
            return (1, 2, 3)

        def parts(tag: str) -> tuple[int, ...]:
            return (1, 2)

        def stats(level: float) -> dict[str, float]:
            return {"peak": level, "rms": level}

        def counts(names: list[str]) -> dict[str, int]:
            return {name: 1 for name in names}
        """
        self.assertEqual(run_one(text), ["tool.py:2 PY-3", "tool.py:8 PY-3"])


class ModuleTest(unittest.TestCase):
    def test_guard_must_exit_with_main(self) -> None:
        text = """
        def main() -> int:
            return 0

        if __name__ == "__main__":
            main()
        """
        self.assertEqual(run_one(text), ["tool.py:5 PY-8"])

    def test_exact_guard_passes(self) -> None:
        text = """
        import logging

        log = logging.getLogger(__name__)

        def main() -> int:
            return 0

        if __name__ == "__main__":
            raise SystemExit(main())
        """
        self.assertEqual(run_one(text), [])

    def test_import_time_work_fails(self) -> None:
        text = """
        import sys

        sys.path.insert(0, "lib")
        try:
            import tomllib
        except ImportError:
            tomllib = None
        """
        self.assertEqual(run_one(text), ["tool.py:4 PY-8"])

    def test_test_files_use_unittest_main(self) -> None:
        text = """
        import unittest

        if __name__ == "__main__":
            unittest.main()
        """
        self.assertEqual(run({"tests/test_tool.py": text}), [])

    def test_firmware_may_run_at_boot(self) -> None:
        text = """
        import asyncio

        async def main() -> None:
            await asyncio.sleep(1)

        asyncio.run(main())
        """
        self.assertEqual(run({"firmware/main.py": text}), [])

    def test_ble_waits_need_timeout_ms(self) -> None:
        text = """
        import aioble

        async def pair(device: aioble.Device) -> None:
            await device.connect()
            await device.connect(timeout_ms=10000)
        """
        self.assertEqual(run({"firmware/link.py": text}), ["firmware/link.py:5 PY-30"])


class LayoutTest(unittest.TestCase):
    def test_module_names_are_lowercase(self) -> None:
        self.assertEqual(
            run({"make-report.py": "", "Tools/__init__.py": ""}),
            [
                "Tools/__init__.py:1 PY-27",
                "make-report.py:1 PY-27",
            ],
        )

    def test_test_cases_live_in_test_files(self) -> None:
        text = """
        import unittest

        class HelperTest(unittest.TestCase):
            pass
        """
        self.assertEqual(run({"tests/helpers.py": text}), ["tests/helpers.py:1 PY-25"])

    def test_installable_packages_use_src(self) -> None:
        files = {
            "pyproject.toml": "[build-system]\nrequires = []\n",
            "app/__init__.py": "",
            "src/tool/core.py": "",
        }
        self.assertEqual(run(files), ["app/__init__.py:1 PY-24", "src/tool:1 PY-24"])

    def test_package_has_one_base_error(self) -> None:
        files = {
            "broker/__init__.py": "",
            "broker/pool.py": "class PoolError(Exception):\n    pass\n",
            "broker/service.py": "class ServiceError(Exception):\n    pass\n",
        }
        self.assertEqual(run(files), ["broker/pool.py:1 PY-10", "broker/service.py:1 PY-10"])

    def test_tracked_vendored_files_are_skipped(self) -> None:
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "vendor").mkdir()
            (root / "vendor" / "Bad-Name.py").write_text("", encoding="utf-8")
            (root / "good.py").write_text("", encoding="utf-8")
            (root / "untracked-file.py").write_text("", encoding="utf-8")
            git = ["git", "-C", folder]
            subprocess.run([*git, "init", "-q"], check=True, timeout=30)
            subprocess.run([*git, "add", "vendor", "good.py"], check=True, timeout=30)
            sources = pystyle.walk(root).sources
            self.assertEqual([path.relative_to(root).as_posix() for path in sources], ["good.py"])

    def test_lint_excludes_match_the_vendored_list(self) -> None:
        entries = pystyle.vendored_entries()
        here = Path(pystyle.__file__).resolve().parent
        ruff = (here / "ruff.toml").read_text(encoding="utf-8")
        block = re.search(r"extend-exclude = \[(.*?)\]", ruff, re.DOTALL)
        ruff_excludes = re.findall(r'"([^"]+)"', block.group(1) if block else "")
        pyright = json.loads((here / "pyrightconfig.json").read_text(encoding="utf-8"))
        pyright_excludes = [entry for entry in pyright["exclude"] if entry != "**/firmware"]
        rooted = [entry.startswith("/") for entry in entries]
        names = [entry.strip("/") for entry in entries]
        self.assertEqual(
            ruff_excludes,
            [f"./{name}" if root else name for name, root in zip(names, rooted, strict=True)],
        )
        self.assertEqual(
            pyright_excludes,
            [name if root else f"**/{name}" for name, root in zip(names, rooted, strict=True)],
        )


if __name__ == "__main__":
    unittest.main()
