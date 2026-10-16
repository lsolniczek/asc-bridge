#!/usr/bin/env python3
"""Keep the documented dependency direction mechanically checkable."""
from pathlib import Path
import re

root = Path(__file__).resolve().parents[1]
allowed = {
    "BridgeCore": {"Foundation", "Security", "CryptoKit"},
    "BridgeMCP": {"Foundation", "BridgeCore", "MCP", "Hummingbird", "HTTPTypes", "Logging", "NIOCore", "ServiceLifecycle", "CryptoKit"},
    "ASCBridge": {"AppKit", "SwiftUI", "Foundation", "BridgeCore", "BridgeMCP", "UniformTypeIdentifiers"},
}
failures = []
for target, imports in allowed.items():
    for source in (root / "Sources" / target).rglob("*.swift"):
        for module in re.findall(r"^import (\w+)", source.read_text(), flags=re.MULTILINE):
            if module not in imports:
                failures.append(f"{source.relative_to(root)}: unexpected dependency {module}")
for required in ["AGENTS.md", "ARCHITECTURE.md", "docs/product.md", "docs/security.md", "docs/references.md"]:
    if not (root / required).is_file():
        failures.append(f"Missing repository reference: {required}")
if failures:
    raise SystemExit("\n".join(failures))
print("Architecture and repository map: OK")

