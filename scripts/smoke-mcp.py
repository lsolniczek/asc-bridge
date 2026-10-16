#!/usr/bin/env python3
"""Exercise the real loopback transport with synthetic ASC and no Keychain access."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import json
import os
import select
import subprocess
import sys
import tempfile
import time
from urllib.error import HTTPError
from urllib.request import Request, urlopen

ENDPOINT = "http://127.0.0.1:43130/mcp"
TOKEN = "asc-bridge-smoke-token"  # Only the explicit --smoke-server fixture accepts this.


def exchange(payload=None, *, method="POST", headers=None, raw=None, authorize=True):
    request_headers = {"Accept": "application/json, text/event-stream", "Content-Type": "application/json",
                       "MCP-Protocol-Version": "2025-11-25"}
    if authorize:
        request_headers["Authorization"] = f"Bearer {TOKEN}"
    request_headers.update(headers or {})
    body = raw if raw is not None else (json.dumps(payload).encode() if payload is not None else None)
    request = Request(ENDPOINT, data=body, headers=request_headers, method=method)
    try:
        with urlopen(request, timeout=10) as response:
            return response.status, response.read()
    except HTTPError as error:
        return error.code, error.read()


def rpc(method, params=None, request_id=1):
    payload = {"jsonrpc": "2.0", "id": request_id, "method": method}
    if params is not None:
        payload["params"] = params
    status, data = exchange(payload)
    assert status == 200, (method, status, data[:200])
    message = json.loads(data)
    assert message.get("id") == request_id, message
    return message


def synthetic_result(name, arguments, request_id=1):
    message = rpc("tools/call", {"name": name, "arguments": arguments}, request_id)
    assert "error" not in message, message
    result = message["result"]
    assert not result.get("isError", False), result
    value = json.loads(result["content"][0]["text"])
    assert value["synthetic"] is True and value["operation"] == name, value
    assert value["arguments"] == arguments, value


def main():
    executable = Path(sys.argv[1] if len(sys.argv) > 1 else ".build/debug/ASCBridge").resolve()
    assert executable.is_file(), f"Build the app first: {executable}"
    with tempfile.TemporaryDirectory(prefix="asc-bridge-smoke-") as directory:
        audit_file = Path(directory) / "history.jsonl"
        with tempfile.TemporaryFile(mode="w+b") as stderr:
            process = subprocess.Popen([str(executable), "--smoke-server", "--audit-file", str(audit_file)],
                                       stdout=subprocess.PIPE, stderr=stderr)
            try:
                ready, _, _ = select.select([process.stdout], [], [], 30)
                assert ready and process.stdout.readline().strip() == b"SMOKE_READY", "MCP server did not bind"
                initialized = rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                    "clientInfo": {"name": "asc-bridge-smoke", "version": "1.0"}})
                assert "tools" in initialized["result"]["capabilities"]
                status, _ = exchange({"jsonrpc": "2.0", "method": "notifications/initialized"})
                assert status == 202, status
                tools = rpc("tools/list")["result"]["tools"]
                names = {tool["name"] for tool in tools}
                expected = {"asc_list_apps", "asc_list_versions", "asc_list_localizations", "asc_create_version",
                            "asc_create_localization", "asc_update_localization"}
                assert names == expected, names
                for tool in tools:
                    assert tool["inputSchema"].get("additionalProperties") is False, tool["name"]
                rpc("ping")
                calls = [
                    ("asc_list_apps", {"limit": 1}),
                    ("asc_list_versions", {"appId": "fixture-app", "platform": "IOS"}),
                    ("asc_list_localizations", {"versionId": "fixture-version"}),
                    ("asc_create_version", {"appId": "fixture-app", "platform": "IOS", "versionString": "1.2.0"}),
                    ("asc_create_localization", {"versionId": "fixture-version", "locale": "pl", "description": "Opis"}),
                    ("asc_update_localization", {"localizationId": "fixture-locale", "whatsNew": "Nowości", "promotionalText": "Promocja"}),
                ]
                for index, (name, arguments) in enumerate(calls, 10):
                    synthetic_result(name, arguments, index)

                # Independent clients commonly reuse JSON-RPC IDs. Each response
                # must correspond to its own arguments, even while calls overlap.
                with ThreadPoolExecutor(max_workers=8) as executor:
                    futures = [executor.submit(synthetic_result, "asc_list_versions", {"appId": f"fixture-{i}"}, 77)
                               for i in range(16)]
                    for future in futures:
                        future.result()

                status, _ = exchange({"jsonrpc": "2.0", "id": 4, "method": "ping"}, authorize=False)
                assert status == 401, status
                status, _ = exchange({"jsonrpc": "2.0", "id": 4, "method": "ping"}, headers={"Origin": "https://hostile.example"})
                assert status == 403, status
                status, _ = exchange({"jsonrpc": "2.0", "id": 4, "method": "ping"}, headers={"Host": "hostile.example"})
                assert status == 403, status
                status, _ = exchange(method="GET")
                assert status == 405, status
                status, _ = exchange(raw=b"{malformed json")
                assert status == 400, status
                unknown = rpc("tools/call", {"name": "unknown_tool", "arguments": {
                    "privateKey": "-----BEGIN PRIVATE KEY-----\nsynthetic-secret-marker\n-----END PRIVATE KEY-----",
                    "token": TOKEN}})
                assert "error" in unknown or unknown.get("result", {}).get("isError") is True, unknown
                time.sleep(0.1)
            finally:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)
            text = audit_file.read_text()
            records = [json.loads(line) for line in text.splitlines() if line]
            assert len(records) >= 30, f"Incomplete audit: {len(records)} records"
            for method in ["initialize", "notifications/initialized", "tools/list", "tools/call", "ping"]:
                assert method in text, f"Missing audit method: {method}"
            assert "synthetic-secret-marker" not in text and TOKEN not in text, "Secret leaked into audit"
            assert "-----BEGIN PRIVATE KEY-----" not in text, "PEM leaked into audit"
            assert os.stat(audit_file).st_mode & 0o777 == 0o600, "Audit must be owner-only"
            print(f"MCP HTTP smoke: OK (six tools, concurrent IDs, auth/Origin/Host, errors, {len(records)} audit records)")


if __name__ == "__main__":
    main()
