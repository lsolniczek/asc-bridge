import importlib.util
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path


SCRIPT = Path(__file__).resolve().parents[1] / "update-third-party-notices.py"
SPEC = importlib.util.spec_from_file_location("update_third_party_notices", SCRIPT)
NOTICES = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(NOTICES)


class ThirdPartyNoticesTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.root = Path(self.temp.name)
        self.checkout_root = self.root / "checkouts"
        self.checkout_root.mkdir()
        self.checkout = self.checkout_root / "example"
        self.checkout.mkdir()
        self._init_git(self.checkout)
        self._write(self.checkout, "LICENSE.txt", "Example root license.\n")
        self._write(self.checkout, "NOTICE.txt", "Example root notice.\n")
        self._write(
            self.checkout,
            "Sources/Vendor/LICENSE.BoringSSL.txt",
            "Vendored BoringSSL license.\n",
        )
        self._commit(self.checkout)
        self.revision = self._git(self.checkout, "rev-parse", "HEAD")
        self.lock = self.root / "Package.resolved"
        self.output = self.root / "THIRD_PARTY_NOTICES.md"
        self._write_lock(
            self.lock,
            identity="example",
            location="https://user:secret@example.test/acme/example.git?token=secret",
            revision=self.revision,
        )

    def tearDown(self):
        self.temp.cleanup()

    @staticmethod
    def _git(directory, *args):
        result = subprocess.run(
            ["git", "-c", "commit.gpgsign=false", "-c", "core.hooksPath=/dev/null", "-C", str(directory), *args],
            check=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        return result.stdout.strip()

    @classmethod
    def _init_git(cls, directory):
        subprocess.run(["git", "init", "-q", str(directory)], check=True)
        cls._git(directory, "config", "user.name", "Notice Fixture")
        cls._git(directory, "config", "user.email", "notices@example.test")

    @staticmethod
    def _write(root, relative_path, contents):
        path = root / relative_path
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(contents, encoding="utf-8")

    @classmethod
    def _commit(cls, directory):
        cls._git(directory, "add", "--all")
        cls._git(directory, "commit", "-q", "-m", "license fixture")

    @staticmethod
    def _write_lock(path, *, identity, location, revision, version="1.2.3"):
        document = {
            "version": 3,
            "pins": [
                {
                    "identity": identity,
                    "kind": "remoteSourceControl",
                    "location": location,
                    "state": {"revision": revision, "version": version},
                }
            ],
        }
        path.write_text(json.dumps(document), encoding="utf-8")

    def test_output_is_deterministic_and_contains_root_and_vendored_notices(self):
        first = NOTICES.generate_notices(self.lock, self.checkout_root)
        second = NOTICES.generate_notices(self.lock, self.checkout_root)

        self.assertEqual(first, second)
        self.assertIn("https://example.test/acme/example.git", first)
        self.assertNotIn("secret", first)
        self.assertIn("Example root license.", first)
        self.assertIn("Example root notice.", first)
        self.assertIn("Sources/Vendor/LICENSE.BoringSSL.txt", first)
        self.assertIn("Vendored BoringSSL license.", first)
        self.assertNotIn(str(self.root), first)
        self.assertNotIn("Generated at", first)

    def test_missing_dependency_checkout_fails(self):
        missing_lock = self.root / "missing.resolved"
        self._write_lock(
            missing_lock,
            identity="missing",
            location="https://example.test/acme/missing.git",
            revision=self.revision,
        )

        with self.assertRaisesRegex(NOTICES.NoticeError, "Missing dependency checkout"):
            NOTICES.generate_notices(missing_lock, self.checkout_root)

    def test_fixture_commits_do_not_sign_or_execute_configured_hooks(self):
        self._git(self.checkout, "config", "commit.gpgsign", "true")
        self._git(self.checkout, "config", "gpg.program", str(self.root / "missing-signing-program"))
        hooks = self.root / "hooks"
        hooks.mkdir()
        hook = hooks / "pre-commit"
        hook.write_text("#!/bin/sh\nexit 99\n", encoding="utf-8")
        hook.chmod(0o755)
        self._git(self.checkout, "config", "core.hooksPath", str(hooks))
        self._write(self.checkout, "README.md", "isolated fixture commit\n")
        self._commit(self.checkout)
        self.assertNotEqual(self._git(self.checkout, "rev-parse", "HEAD"), self.revision)

    def test_checkout_revision_must_match_lock(self):
        self._write(self.checkout, "README.md", "advance the fixture revision\n")
        self._commit(self.checkout)

        with self.assertRaisesRegex(NOTICES.NoticeError, "revision does not match"):
            NOTICES.generate_notices(self.lock, self.checkout_root)

    def test_missing_license_files_fail_closed(self):
        empty_checkout = self.checkout_root / "unlicensed"
        empty_checkout.mkdir()
        self._init_git(empty_checkout)
        self._write(empty_checkout, "README.md", "No license file.\n")
        self._commit(empty_checkout)
        revision = self._git(empty_checkout, "rev-parse", "HEAD")
        unlicensed_lock = self.root / "unlicensed.resolved"
        self._write_lock(
            unlicensed_lock,
            identity="unlicensed",
            location="https://example.test/acme/unlicensed.git",
            revision=revision,
        )

        with self.assertRaisesRegex(NOTICES.NoticeError, "No license"):
            NOTICES.generate_notices(unlicensed_lock, self.checkout_root)

    def test_check_mode_detects_drift(self):
        self.output.write_text(NOTICES.generate_notices(self.lock, self.checkout_root), encoding="utf-8")
        base_command = [
            sys.executable,
            str(SCRIPT),
            "--checkout-root",
            str(self.checkout_root),
            "--package-resolved",
            str(self.lock),
            "--output",
            str(self.output),
            "--check",
        ]

        current = subprocess.run(base_command, capture_output=True, text=True)
        self.assertEqual(current.returncode, 0, current.stderr)

        self.output.write_text("drift\n", encoding="utf-8")
        drifted = subprocess.run(base_command, capture_output=True, text=True)
        self.assertNotEqual(drifted.returncode, 0)
        self.assertIn("out of date", drifted.stderr)

    def test_identity_cannot_escape_checkout_root(self):
        unsafe_lock = self.root / "unsafe.resolved"
        self._write_lock(
            unsafe_lock,
            identity="../outside",
            location="https://example.test/acme/outside.git",
            revision=self.revision,
        )

        with self.assertRaisesRegex(NOTICES.NoticeError, "invalid dependency identity"):
            NOTICES.generate_notices(unsafe_lock, self.checkout_root)

    def test_license_symlink_cannot_escape_checkout(self):
        outside_license = self.root / "outside-license.txt"
        outside_license.write_text("outside text\n", encoding="utf-8")
        (self.checkout / "LICENSE.external").symlink_to(outside_license)

        with self.assertRaisesRegex(NOTICES.NoticeError, "escapes the dependency checkout"):
            NOTICES._license_files(self.checkout.resolve(), "example")


if __name__ == "__main__":
    unittest.main()
