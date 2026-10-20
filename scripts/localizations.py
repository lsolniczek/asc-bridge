#!/usr/bin/env python3
"""Check/sync Apple String Catalogs and configure the SwiftPM app's languages."""
from __future__ import annotations

import argparse
import json
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
from xml.parsers.expat import ExpatError

ROOT = Path(__file__).resolve().parents[1]
TARGETS = ("ASCBridge", "BridgeCore")
POLISH_LETTERS = re.compile("[ąćęłńóśźżĄĆĘŁŃÓŚŹŻ]")


class LocalizationError(Exception):
    pass


def catalog_path(root: Path, target: str) -> Path:
    return root / "Sources" / target / "Resources" / "Localizable.xcstrings"


def load_catalog(path: Path) -> dict:
    try:
        catalog = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError) as error:
        raise LocalizationError(f"Cannot read string catalog: {path.name}") from error
    if not isinstance(catalog, dict) or catalog.get("sourceLanguage") != "en":
        raise LocalizationError("String catalogs must use English as their source language.")
    strings = catalog.get("strings")
    if not isinstance(strings, dict) or not strings:
        raise LocalizationError("String catalogs must contain localizable text.")
    for key, entry in strings.items():
        if not isinstance(entry, dict) or not isinstance(entry.get("comment"), str) or not entry["comment"].strip():
            raise LocalizationError(f"Add translator context for catalog key: {key}")
        if POLISH_LETTERS.search(key):
            raise LocalizationError(f"Translate the source catalog key into English: {key}")
    return catalog


def stringsdata_paths(root: Path, target: str, configuration: str) -> list[Path]:
    intermediates = root / ".build" / "out" / "Intermediates.noindex"
    # Swift Build uses -p for products and -t for dependency targets.
    build_names = {f"{target}-p.build", f"{target}-t.build"}
    # Ignore generated catalog symbols and leftovers from removed source files.
    source_names = {path.with_suffix(".stringsdata").name for path in (root / "Sources" / target).rglob("*.swift")}
    paths = sorted(
        path for path in intermediates.rglob("*.stringsdata")
        if path.name in source_names and build_names.intersection(path.parts)
        and configuration.capitalize() in path.parts
    )
    if not paths:
        raise LocalizationError(
            f"No {target} compiler localization data. Build with --build-system swiftbuild first."
        )
    return paths


def synchronized_catalog(root: Path, target: str, configuration: str) -> dict:
    source = catalog_path(root, target)
    with tempfile.TemporaryDirectory(prefix="asc-catalog-sync-") as temporary:
        copy = Path(temporary) / "Localizable.xcstrings"
        shutil.copyfile(source, copy)
        command = [
            "xcrun", "xcstringstool", "sync", str(copy), "--stringsdata",
            *(str(path) for path in stringsdata_paths(root, target, configuration)),
            "--skip-marking-strings-stale",
        ]
        try:
            subprocess.run(command, capture_output=True, text=True, check=True)
        except FileNotFoundError as error:
            raise LocalizationError("Select a full Xcode installation to use xcstringstool.") from error
        except subprocess.CalledProcessError as error:
            raise LocalizationError(f"Apple string catalog sync failed for {target}: {error.stderr.strip()}") from error
        return json.loads(copy.read_text(encoding="utf-8"))


def check_sources(root: Path, configuration: str) -> None:
    for target in TARGETS:
        current = load_catalog(catalog_path(root, target))
        synced = synchronized_catalog(root, target, configuration)
        missing = set(synced["strings"]) - set(current["strings"])
        if missing:
            raise LocalizationError(
                f"{target} catalog is missing compiler-extracted keys: {sorted(missing)}. "
                "Run python3 scripts/localizations.py sync after building."
            )
        print(f"{target} catalog: {len(current['strings'])} English source keys, compiler coverage OK")


def sync_sources(root: Path, configuration: str) -> None:
    # Only replace source files after both Apple sync operations succeed.
    catalogs = {target: synchronized_catalog(root, target, configuration) for target in TARGETS}
    for target, catalog in catalogs.items():
        catalog_path(root, target).write_text(
            json.dumps(catalog, ensure_ascii=False, indent=2, sort_keys=True) + "\n", encoding="utf-8"
        )
        print(f"Synchronized {target}. Review new source strings, comments and translations in Xcode.")


def resource_bundle(app: Path, target: str) -> Path:
    bundle = app / "Contents" / "Resources" / f"ASCBridge_{target}.bundle"
    if not bundle.is_dir():
        raise LocalizationError(f"Missing packaged resource bundle for {target}.")
    return bundle


def bundle_languages(bundle: Path) -> list[str]:
    languages = sorted({path.stem for path in bundle.rglob("*.lproj") if path.is_dir() and path.stem != "Base"})
    if "en" not in languages:
        raise LocalizationError("Compiled English localization is missing from the resource bundle.")
    return ["en", *(language for language in languages if language != "en")]


def read_plist(path: Path) -> dict:
    try:
        data = path.read_bytes()
    except OSError as error:
        raise LocalizationError(f"Cannot read localization property list: {path.name}") from error
    try:
        value = plistlib.loads(data)
    except (ValueError, plistlib.InvalidFileException, ExpatError):
        # Apple's compiler also emits UTF-16 .strings files with an XML UTF-8
        # declaration, and older toolchains can emit OpenStep property lists.
        # Let Apple's own parser canonicalize those formats without editing them.
        try:
            converted = subprocess.run(
                ["/usr/bin/plutil", "-convert", "xml1", "-o", "-", "--", str(path)],
                capture_output=True, check=True,
            )
            value = plistlib.loads(converted.stdout)
        except (OSError, subprocess.CalledProcessError, ValueError, plistlib.InvalidFileException, ExpatError) as error:
            raise LocalizationError(f"Cannot read localization property list: {path.name}") from error
    if not isinstance(value, dict):
        raise LocalizationError(f"Expected a dictionary in {path.name}.")
    return value


def configure_app(app: Path) -> None:
    languages = bundle_languages(resource_bundle(app, "ASCBridge"))
    info_path = app / "Contents" / "Info.plist"
    info = read_plist(info_path)
    if info.get("CFBundleExecutable") != "ASCBridge":
        raise LocalizationError("The supplied bundle is not an ASC Bridge application.")
    info["CFBundleDevelopmentRegion"] = "en"
    info["CFBundleLocalizations"] = languages
    info_path.write_bytes(plistlib.dumps(info, sort_keys=False))
    print("App languages: " + ", ".join(languages))


def check_app(root: Path, app: Path) -> None:
    info = read_plist(app / "Contents" / "Info.plist")
    languages = bundle_languages(resource_bundle(app, "ASCBridge"))
    if info.get("CFBundleDevelopmentRegion") != "en" or info.get("CFBundleLocalizations") != languages:
        raise LocalizationError("The application does not advertise its compiled localizations correctly.")
    for target in TARGETS:
        bundle = resource_bundle(app, target)
        bundle_languages(bundle)
        compiled_keys: set[str] = set()
        for directory in bundle.rglob("en.lproj"):
            for filename in ("Localizable.strings", "Localizable.stringsdict"):
                table = directory / filename
                if table.is_file():
                    compiled_keys.update(read_plist(table))
        catalog = load_catalog(catalog_path(root, target))
        expected = {key for key, entry in catalog["strings"].items() if entry.get("shouldTranslate", True)}
        missing = expected - compiled_keys
        if missing:
            raise LocalizationError(f"Packaged {target} is missing English strings: {sorted(missing)}")
    print("Packaged string catalogs and language metadata: OK")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("check", "sync", "configure-app", "check-app"))
    parser.add_argument("--configuration", choices=("debug", "release"), default="debug")
    parser.add_argument("--app", type=Path)
    args = parser.parse_args()
    try:
        if args.command == "check":
            check_sources(ROOT, args.configuration)
        elif args.command == "sync":
            sync_sources(ROOT, args.configuration)
        elif args.app is None:
            parser.error("--app is required for application bundle commands")
        elif args.command == "configure-app":
            configure_app(args.app)
        else:
            check_app(ROOT, args.app)
        return 0
    except (LocalizationError, OSError) as error:
        print(f"Localization: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
