import importlib.util
import json
import plistlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

SCRIPT = Path(__file__).resolve().parents[1] / "localizations.py"
SPEC = importlib.util.spec_from_file_location("localizations", SCRIPT)
LOCALIZATIONS = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LOCALIZATIONS)


class LocalizationTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.root = Path(self.temporary.name)
        self.app = self.root / "ASC Bridge.app"
        self.resources = self.app / "Contents" / "Resources"
        self.resources.mkdir(parents=True)
        self.info = self.app / "Contents" / "Info.plist"
        self.info.write_bytes(plistlib.dumps({"CFBundleExecutable": "ASCBridge"}))
        for target in LOCALIZATIONS.TARGETS:
            source = LOCALIZATIONS.catalog_path(self.root, target)
            source.parent.mkdir(parents=True)
            source.write_text(json.dumps(self.catalog()), encoding="utf-8")
            english = self.resources / f"ASCBridge_{target}.bundle" / "en.lproj"
            english.mkdir(parents=True)
            (english / "Localizable.strings").write_bytes(plistlib.dumps({"Connection": "Connection"}))

    def tearDown(self):
        self.temporary.cleanup()

    @staticmethod
    def catalog():
        return {
            "sourceLanguage": "en",
            "strings": {"Connection": {"comment": "Sidebar navigation title.", "localizations": {
                "en": {"stringUnit": {"state": "translated", "value": "Connection"}}
            }}},
            "version": "1.0",
        }

    def test_configure_app_advertises_compiled_languages_and_english_default(self):
        french = self.resources / "ASCBridge_ASCBridge.bundle" / "fr.lproj"
        french.mkdir()
        LOCALIZATIONS.configure_app(self.app)
        info = plistlib.loads(self.info.read_bytes())
        self.assertEqual(info["CFBundleDevelopmentRegion"], "en")
        self.assertEqual(info["CFBundleLocalizations"], ["en", "fr"])
        LOCALIZATIONS.check_app(self.root, self.app)

    def test_missing_english_resource_is_not_masked_by_source_key_fallback(self):
        (self.resources / "ASCBridge_ASCBridge.bundle" / "en.lproj" / "Localizable.strings").unlink()
        LOCALIZATIONS.configure_app(self.app)
        with self.assertRaisesRegex(LOCALIZATIONS.LocalizationError, "missing English strings"):
            LOCALIZATIONS.check_app(self.root, self.app)

    @unittest.skipUnless(Path("/usr/bin/plutil").is_file(), "Apple property-list parser requires macOS")
    def test_apple_compiled_utf16_table_with_utf8_xml_declaration(self):
        table = self.resources / "ASCBridge_ASCBridge.bundle" / "en.lproj" / "Localizable.strings"
        xml = plistlib.dumps({"Connection": "Connection"}).decode("utf-8")
        table.write_bytes(xml.encode("utf-16"))
        original = table.read_bytes()
        LOCALIZATIONS.configure_app(self.app)
        LOCALIZATIONS.check_app(self.root, self.app)
        self.assertEqual(table.read_bytes(), original)

    def test_missing_bundle_and_main_language_metadata_fail(self):
        with self.assertRaisesRegex(LOCALIZATIONS.LocalizationError, "advertise"):
            LOCALIZATIONS.check_app(self.root, self.app)
        LOCALIZATIONS.configure_app(self.app)
        (self.resources / "ASCBridge_BridgeCore.bundle").rename(self.resources / "missing.bundle")
        with self.assertRaisesRegex(LOCALIZATIONS.LocalizationError, "Missing packaged resource"):
            LOCALIZATIONS.check_app(self.root, self.app)

    def test_catalog_rejects_non_english_source_and_missing_translator_context(self):
        path = LOCALIZATIONS.catalog_path(self.root, "ASCBridge")
        invalid = self.catalog()
        invalid["sourceLanguage"] = "pl"
        path.write_text(json.dumps(invalid), encoding="utf-8")
        with self.assertRaisesRegex(LOCALIZATIONS.LocalizationError, "English"):
            LOCALIZATIONS.load_catalog(path)
        invalid = self.catalog()
        del invalid["strings"]["Connection"]["comment"]
        path.write_text(json.dumps(invalid), encoding="utf-8")
        with self.assertRaisesRegex(LOCALIZATIONS.LocalizationError, "translator context"):
            LOCALIZATIONS.load_catalog(path)

    def test_typed_compiler_key_missing_from_catalog_fails_without_editing_source(self):
        path = LOCALIZATIONS.catalog_path(self.root, "ASCBridge")
        before = path.read_bytes()
        extracted = self.catalog()
        extracted["strings"]["Duration: %lld ms"] = {"comment": "Elapsed request duration."}
        with patch.object(LOCALIZATIONS, "synchronized_catalog", return_value=extracted):
            with self.assertRaisesRegex(LOCALIZATIONS.LocalizationError, "missing compiler-extracted keys"):
                LOCALIZATIONS.check_sources(self.root, "debug")
        self.assertEqual(path.read_bytes(), before)

    def test_sync_failure_does_not_partially_replace_catalogs(self):
        originals = {target: LOCALIZATIONS.catalog_path(self.root, target).read_bytes() for target in LOCALIZATIONS.TARGETS}
        with patch.object(LOCALIZATIONS, "synchronized_catalog", side_effect=[self.catalog(), LOCALIZATIONS.LocalizationError("tool failure")]):
            with self.assertRaisesRegex(LOCALIZATIONS.LocalizationError, "tool failure"):
                LOCALIZATIONS.sync_sources(self.root, "debug")
        for target, original in originals.items():
            self.assertEqual(LOCALIZATIONS.catalog_path(self.root, target).read_bytes(), original)

    def test_compiler_data_is_scoped_to_the_target_and_build_configuration(self):
        base = self.root / ".build/out/Intermediates.noindex/ASCBridge.build"
        for configuration, target, kind in [("Debug", "ASCBridge", "p"), ("Release", "ASCBridge", "p"), ("Debug", "BridgeCore", "t")]:
            (self.root / "Sources" / target / "Main.swift").touch()
            path = base / configuration / f"{target}-{kind}.build/Objects-normal/arm64/Main.stringsdata"
            path.parent.mkdir(parents=True)
            path.write_text("{}", encoding="utf-8")
            # Incremental build artifacts must not invent source catalog entries.
            for ignored in ("GeneratedStringSymbols_Localizable", "RemovedSource"):
                path.with_name(f"{ignored}.stringsdata").write_text("{}", encoding="utf-8")
        actual = LOCALIZATIONS.stringsdata_paths(self.root, "ASCBridge", "debug")
        self.assertEqual(len(actual), 1)
        self.assertIn("Debug/ASCBridge-p.build", actual[0].as_posix())
        dependency = LOCALIZATIONS.stringsdata_paths(self.root, "BridgeCore", "debug")
        self.assertEqual(len(dependency), 1)
        self.assertIn("Debug/BridgeCore-t.build", dependency[0].as_posix())


if __name__ == "__main__":
    unittest.main()
