#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$project_dir/scripts/check-architecture.py"
python3 -m unittest discover -s "$project_dir/scripts/tests" -p 'test_*.py'
swift test --package-path "$project_dir" --build-system swiftbuild
python3 "$project_dir/scripts/localizations.py" check
python3 "$project_dir/scripts/update-third-party-notices.py" --check
swift build --package-path "$project_dir" --build-system swiftbuild -c release --product ASCBridge
python3 "$project_dir/scripts/smoke-mcp.py" "$project_dir/.build/debug/ASCBridge"

