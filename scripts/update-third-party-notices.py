#!/usr/bin/env python3
"""Generate or verify the third-party license notices from SwiftPM checkouts."""

from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit


PROJECT_ROOT = Path(__file__).resolve().parent.parent
IDENTITY_PATTERN = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
LICENSE_PREFIXES = ("license", "licence", "copying", "notice")


class NoticeError(Exception):
    """An input cannot safely produce a complete notices document."""


def _inside(path: Path, root: Path) -> bool:
    try:
        path.relative_to(root)
        return True
    except ValueError:
        return False


def _safe_repository_url(location: str) -> str:
    """Keep repository identity while dropping URL credentials and query data."""
    parsed = urlsplit(location)
    if parsed.scheme.casefold() == "file":
        return "(local dependency; repository URL omitted)"
    if parsed.scheme and parsed.netloc:
        hostname = parsed.hostname or ""
        if ":" in hostname and not hostname.startswith("["):
            hostname = f"[{hostname}]"
        try:
            port = parsed.port
        except ValueError as exc:
            raise NoticeError("A dependency has an invalid repository URL") from exc
        netloc = f"{hostname}:{port}" if port is not None else hostname
        return urlunsplit((parsed.scheme, netloc, parsed.path, "", ""))

    # SwiftPM also accepts scp-style SSH locations such as git@host:owner/repo.git.
    if ":" in location and not Path(location).is_absolute():
        host_part, repository_path = location.split(":", 1)
        if "@" in host_part and repository_path and "/" in repository_path:
            host = host_part.rsplit("@", 1)[-1]
            return f"ssh://{host}/{repository_path}"

    if (
        Path(location).is_absolute()
        or location.startswith(("/", "\\"))
        or re.match(r"^[A-Za-z]:[\\/]", location)
    ):
        return "(local dependency; repository URL omitted)"
    return location


def _load_pins(package_resolved: Path) -> list[dict[str, str]]:
    try:
        data = json.loads(package_resolved.read_text(encoding="utf-8"))
    except (OSError, UnicodeError, json.JSONDecodeError) as exc:
        raise NoticeError("Could not read Package.resolved") from exc

    pins = data.get("pins") if isinstance(data, dict) else None
    if not isinstance(pins, list):
        raise NoticeError("Package.resolved does not contain a pins array")

    result: list[dict[str, str]] = []
    seen: set[str] = set()
    for pin in pins:
        if not isinstance(pin, dict):
            raise NoticeError("Package.resolved contains an invalid pin")
        identity = pin.get("identity")
        location = pin.get("location")
        state = pin.get("state")
        if (
            not isinstance(identity, str)
            or not IDENTITY_PATTERN.fullmatch(identity)
            or not isinstance(location, str)
            or not location.strip()
            or not isinstance(state, dict)
        ):
            raise NoticeError("Package.resolved contains an invalid dependency identity or location")
        if any(ord(character) < 32 for character in location):
            raise NoticeError(f"Dependency {identity} has an invalid repository URL")

        normalized_identity = identity.casefold()
        if normalized_identity in seen:
            raise NoticeError(f"Package.resolved contains duplicate dependency identity: {identity}")
        seen.add(normalized_identity)

        revision = state.get("revision")
        version = state.get("version")
        branch = state.get("branch")
        if not isinstance(revision, str) or not re.fullmatch(r"[0-9a-fA-F]{40}|[0-9a-fA-F]{64}", revision):
            raise NoticeError(f"Dependency {identity} has no locked revision")
        if isinstance(version, str) and version:
            locked_version = version
        elif isinstance(branch, str) and branch:
            locked_version = f"branch {branch}"
        else:
            raise NoticeError(f"Dependency {identity} has no locked version or branch")
        if any(ord(character) < 32 for character in locked_version):
            raise NoticeError(f"Dependency {identity} has an invalid locked version")

        result.append(
            {
                "identity": identity,
                "location": _safe_repository_url(location),
                "version": locked_version,
                "revision": revision,
            }
        )

    return sorted(result, key=lambda pin: (pin["identity"].casefold(), pin["identity"]))


def _checkout_for(identity: str, checkout_root: Path) -> Path:
    checkout = checkout_root / identity
    try:
        resolved = checkout.resolve(strict=True)
    except OSError as exc:
        raise NoticeError(f"Missing dependency checkout: {identity}") from exc
    if not resolved.is_dir() or not _inside(resolved, checkout_root):
        raise NoticeError(f"Dependency checkout is missing or outside the checkout root: {identity}")
    return resolved


def _verify_revision(checkout: Path, identity: str, locked_revision: str) -> None:
    try:
        result = subprocess.run(
            ["git", "-C", str(checkout), "rev-parse", "HEAD"],
            check=True,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
        )
    except FileNotFoundError as exc:
        raise NoticeError("git is required to validate dependency revisions") from exc
    except subprocess.CalledProcessError as exc:
        raise NoticeError(f"Dependency checkout is not a Git revision: {identity}") from exc

    actual_revision = result.stdout.strip()
    if actual_revision.casefold() != locked_revision.casefold():
        raise NoticeError(f"Dependency checkout revision does not match Package.resolved: {identity}")


def _is_license_filename(filename: str) -> bool:
    folded = filename.casefold()
    return folded.startswith(LICENSE_PREFIXES)


def _license_files(checkout: Path, identity: str) -> list[tuple[str, str]]:
    found: list[tuple[str, str]] = []
    walk_errors: list[OSError] = []

    def record_walk_error(error: OSError) -> None:
        walk_errors.append(error)

    for current, directories, filenames in os.walk(checkout, topdown=True, followlinks=False, onerror=record_walk_error):
        current_path = Path(current)
        directories[:] = sorted(
            directory
            for directory in directories
            if directory.casefold() not in {".git", ".build"}
            and not (current_path / directory).is_symlink()
        )
        for filename in sorted(filenames, key=lambda value: (value.casefold(), value)):
            if not _is_license_filename(filename):
                continue
            candidate = current_path / filename
            try:
                resolved = candidate.resolve(strict=True)
            except OSError as exc:
                raise NoticeError(f"Could not read a license file for dependency {identity}") from exc
            if not _inside(resolved, checkout) or not resolved.is_file():
                raise NoticeError(f"License file escapes the dependency checkout: {identity}")
            try:
                license_text = resolved.read_bytes().decode("utf-8")
            except (OSError, UnicodeError) as exc:
                raise NoticeError(f"Could not decode a license file for dependency {identity} as UTF-8") from exc

            # Canonicalize checkout line endings so generated artifacts are stable
            # across platforms with different Git checkout settings.
            license_text = license_text.replace("\r\n", "\n").replace("\r", "\n")
            relative_path = candidate.relative_to(checkout).as_posix()
            if any(ord(character) < 32 for character in relative_path):
                raise NoticeError(f"License file has an invalid path for dependency {identity}")
            if not license_text.strip():
                raise NoticeError(f"License file is empty for dependency {identity}")
            found.append((relative_path, license_text))

    if walk_errors:
        raise NoticeError(f"Could not inspect all license files for dependency {identity}")
    if not found:
        raise NoticeError(f"No license, copying, or notice files found for dependency {identity}")
    return sorted(found, key=lambda item: (item[0].casefold(), item[0]))


def _fence_for(text: str) -> str:
    longest = 0
    for match in re.finditer(r"`+", text):
        longest = max(longest, len(match.group(0)))
    return "`" * max(3, longest + 1)


def _inline_code(text: str) -> str:
    longest = 0
    for match in re.finditer(r"`+", text):
        longest = max(longest, len(match.group(0)))
    fence = "`" * (longest + 1)
    return f"{fence}{text}{fence}"


def generate_notices(package_resolved: Path, checkout_root: Path) -> str:
    try:
        resolved_checkout_root = checkout_root.resolve(strict=True)
    except OSError as exc:
        raise NoticeError("SwiftPM checkout root does not exist") from exc
    if not resolved_checkout_root.is_dir():
        raise NoticeError("SwiftPM checkout root is not a directory")

    pins = _load_pins(package_resolved)
    sections = [
        "# Third-party notices\n\n",
        "Generated from `Package.resolved` and the matching SwiftPM checkouts by `scripts/update-third-party-notices.py`. License text line endings are normalized to LF.\n\n",
    ]

    for pin in pins:
        checkout = _checkout_for(pin["identity"], resolved_checkout_root)
        _verify_revision(checkout, pin["identity"], pin["revision"])
        licenses = _license_files(checkout, pin["identity"])

        sections.append(
            f"## {pin['identity']}\n\n"
            f"Repository: {_inline_code(pin['location'])}\n"
            f"Locked version: {_inline_code(pin['version'])}\n"
            f"Locked revision: {_inline_code(pin['revision'])}\n\n"
        )
        for path, license_text in licenses:
            fence = _fence_for(license_text)
            sections.append(f"### {_inline_code(path)}\n\n{fence}text\n")
            sections.append(license_text)
            if not license_text.endswith("\n"):
                sections.append("\n")
            sections.append(f"{fence}\n\n")

    return "".join(sections)


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--checkout-root",
        type=Path,
        default=PROJECT_ROOT / ".build" / "checkouts",
        help="SwiftPM resolved checkout directory (default: .build/checkouts)",
    )
    parser.add_argument(
        "--package-resolved",
        type=Path,
        default=PROJECT_ROOT / "Package.resolved",
        help="lockfile to read (default: Package.resolved)",
    )
    parser.add_argument(
        "--output",
        type=Path,
        default=PROJECT_ROOT / "THIRD_PARTY_NOTICES.md",
        help="notices file to generate or verify (default: THIRD_PARTY_NOTICES.md)",
    )
    parser.add_argument("--check", action="store_true", help="fail if the output is missing or out of date")
    args = parser.parse_args(argv)

    try:
        generated = generate_notices(args.package_resolved, args.checkout_root)
        expected = generated.encode("utf-8")
        if args.check:
            try:
                current = args.output.read_bytes()
            except OSError as exc:
                raise NoticeError("Third-party notices file is missing or unreadable") from exc
            if current != expected:
                raise NoticeError("Third-party notices are out of date; regenerate them with the script")
            return 0

        try:
            args.output.parent.mkdir(parents=True, exist_ok=True)
            args.output.write_bytes(expected)
        except OSError as exc:
            raise NoticeError("Could not write the third-party notices file") from exc
        return 0
    except NoticeError as exc:
        print(f"update-third-party-notices.py: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
