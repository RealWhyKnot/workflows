from __future__ import annotations

import tomllib
import unittest

from lint.common.tests.test_style_check import BASELINE


class LicenseTests(unittest.TestCase):
    def test_unused_allowed_licenses_are_quiet(self) -> None:
        config = tomllib.loads((BASELINE / "rust/.github/lint/deny.toml").read_text(encoding="utf-8"))
        self.assertEqual(config["licenses"].get("unused-allowed-license"), "allow")

    def test_boost_and_jpeg_licenses_are_allowed(self) -> None:
        config = tomllib.loads((BASELINE / "rust/.github/lint/deny.toml").read_text(encoding="utf-8"))
        for license_id in ("BSL-1.0", "IJG"):
            with self.subTest(license_id=license_id):
                self.assertIn(license_id, config["licenses"]["allow"])

    def test_mpl_is_allowed_without_gpl_exceptions(self) -> None:
        config = tomllib.loads((BASELINE / "rust/.github/lint/deny.toml").read_text(encoding="utf-8"))
        licenses = config["licenses"]
        self.assertIn("MPL-2.0", licenses["allow"])
        self.assertFalse(any("GPL" in license_id for license_id in licenses["allow"]))
        self.assertEqual(licenses["private"], {"ignore": True})


if __name__ == "__main__":
    _ = unittest.main()
