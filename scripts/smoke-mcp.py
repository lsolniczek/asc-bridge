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
                deadline = time.monotonic() + 30
                bound = False
                while time.monotonic() < deadline:
                    ready, _, _ = select.select([process.stdout], [], [], max(0, deadline - time.monotonic()))
                    if not ready:
                        break
                    line = process.stdout.readline()
                    if line.strip() == b"SMOKE_READY":
                        bound = True
                        break
                    if not line:
                        break
                assert bound, "MCP server did not bind"
                initialized = rpc("initialize", {"protocolVersion": "2025-11-25", "capabilities": {},
                    "clientInfo": {"name": "asc-bridge-smoke", "version": "1.0"}})
                assert "tools" in initialized["result"]["capabilities"]
                status, _ = exchange({"jsonrpc": "2.0", "method": "notifications/initialized"})
                assert status == 202, status
                tools = rpc("tools/list")["result"]["tools"]
                names = {tool["name"] for tool in tools}
                expected = {"asc_list_apps", "asc_list_versions", "asc_list_localizations", "asc_create_version",
                            "asc_create_localization", "asc_update_localization", "asc_get_app", "asc_get_version",
                            "asc_list_app_infos", "asc_list_app_info_localizations", "asc_create_app_info_localization",
                            "asc_update_app_info_localization", "asc_list_builds", "asc_get_build", "asc_get_version_build",
                            "asc_set_version_build", "asc_list_beta_groups", "asc_list_beta_build_localizations",
                            "asc_create_beta_build_localization", "asc_update_beta_build_localization",
                            "asc_list_customer_reviews", "asc_get_customer_review_response",
                            "asc_upsert_customer_review_response"}
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
                    ("asc_update_localization", {"localizationId": "fixture-locale", "whatsNew": "Nowości", "promotionalText": "Promocja",
                                                 "keywords": "aplikacja,test", "supportUrl": "https://example.com/support",
                                                 "marketingUrl": "https://example.com"}),
                    ("asc_get_app", {"appId": "fixture-app"}),
                    ("asc_get_version", {"versionId": "fixture-version"}),
                    ("asc_list_app_infos", {"appId": "fixture-app"}),
                    ("asc_list_app_info_localizations", {"appInfoId": "fixture-info"}),
                    ("asc_create_app_info_localization", {"appInfoId": "fixture-info", "locale": "pl", "name": "Aplikacja",
                                                          "subtitle": "Polski podtytuł", "privacyPolicyUrl": "https://example.com/privacy"}),
                    ("asc_update_app_info_localization", {"appInfoLocalizationId": "fixture-info-locale", "subtitle": "Nowy podtytuł"}),
                    ("asc_list_builds", {"appId": "fixture-app", "platform": "IOS", "processingState": "VALID", "sort": "-uploadedDate"}),
                    ("asc_get_build", {"buildId": "fixture-build"}),
                    ("asc_get_version_build", {"versionId": "fixture-version"}),
                    ("asc_set_version_build", {"versionId": "fixture-version", "buildId": "fixture-build"}),
                    ("asc_list_beta_groups", {"appId": "fixture-app"}),
                    ("asc_list_beta_build_localizations", {"buildId": "fixture-build"}),
                    ("asc_create_beta_build_localization", {"buildId": "fixture-build", "locale": "pl", "whatsNew": "Sprawdź nowy ekran"}),
                    ("asc_update_beta_build_localization", {"betaBuildLocalizationId": "fixture-beta-locale", "whatsNew": "Sprawdź poprawkę"}),
                    ("asc_list_customer_reviews", {"appId": "fixture-app", "territory": "POL", "rating": 5, "sort": "-createdDate"}),
                    ("asc_get_customer_review_response", {"reviewId": "fixture-review"}),
                    ("asc_upsert_customer_review_response", {"reviewId": "fixture-review", "responseBody": "Dziękujemy za opinię."}),
                ]
                assert {name for name, _ in calls} == expected, "Every advertised tool needs an HTTP smoke call"
                for index, (name, arguments) in enumerate(calls, 10):
                    synthetic_result(name, arguments, index)

                for name, arguments in [
                    ("asc_list_customer_reviews", {"appId": "fixture-app", "rating": 6}),
                    ("asc_list_builds", {"appId": "fixture-app", "processingState": "UNKNOWN"}),
                    ("asc_update_app_info_localization", {"appInfoLocalizationId": "fixture-locale"}),
                    ("asc_upsert_customer_review_response", {"reviewId": "fixture-review", "responseBody": "  "}),
                    ("asc_update_localization", {"localizationId": "fixture-locale", "keywords": "ą" * 51}),
                ]:
                    invalid = rpc("tools/call", {"name": name, "arguments": arguments})
                    assert invalid.get("result", {}).get("isError") is True, invalid

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
                assert status in (403, 421), status
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
            for name in expected:
                assert any(record.get("toolName") == name for record in records), f"Missing tool audit: {name}"
            assert "synthetic-secret-marker" not in text and TOKEN not in text, "Secret leaked into audit"
            assert "-----BEGIN PRIVATE KEY-----" not in text, "PEM leaked into audit"
            assert os.stat(audit_file).st_mode & 0o777 == 0o600, "Audit must be owner-only"
            print(f"MCP HTTP smoke: OK ({len(expected)} tools, concurrent IDs, auth/Origin/Host, errors, {len(records)} audit records)")


if __name__ == "__main__":
    main()
