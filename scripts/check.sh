#!/bin/bash
set -euo pipefail
project_dir="$(cd "$(dirname "$0")/.." && pwd)"
python3 "$project_dir/scripts/check-architecture.py"
swift test --package-path "$project_dir"
swift build --package-path "$project_dir" -c release --product ASCBridge
python3 "$project_dir/scripts/smoke-mcp.py" "$project_dir/.build/debug/ASCBridge"

