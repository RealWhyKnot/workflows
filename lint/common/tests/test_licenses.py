from __future__ import annotations

import tomllib
import unittest

from lint.common.tests.test_style_check import BASELINE


class LicenseTests(unittest.TestCase):
    def test_mpl_is_allowed_without_gpl_exceptions(self) -> None:
        config = tomllib.loads((BASELINE / "rust/.github/lint/deny.toml").read_text(encoding="utf-8"))
        licenses = config["licenses"]
        self.assertIn("MPL-2.0", licenses["allow"])
        self.assertFalse(any("GPL" in license_id for license_id in licenses["allow"]))
        self.assertEqual(licenses["private"], {"ignore": True})


if __name__ == "__main__":
    _ = unittest.main()
