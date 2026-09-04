"""End-to-end protocol regressions against a strict local upstream, no real keys.

Usage: python scripts/verify_compatibility.py [path/to/freepro-gui.exe]
"""
import json
import os
from pathlib import Path
import socket
import subprocess
import sys
import tempfile
import threading
import time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.error import HTTPError
from urllib.request import Request, urlopen


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


seen = []


class Upstream(BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def reply(self, status, body):
        raw = json.dumps(body).encode()
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def capture(self, body):
        assert self.headers.get_all("User-Agent") == ["compat-test/1.0"]
        assert self.headers.get_all("Authorization") == ["Bearer test-only"]
        assert self.headers.get_all("X-Custom") == ["preserved"]
        seen.append((self.path, self.headers, body))

    def do_GET(self):
        self.capture(None)
        self.reply(200, {"object": "list", "data": [{"id": "thinking"}]})

    def do_POST(self):
        body = json.loads(self.rfile.read(int(self.headers["Content-Length"])))
        self.capture(body)
        if body["model"] == "bad":
            return self.reply(400, {"error": {"message": "Invalid request"}})
        if body["model"] == "thinking" and body.get("reasoning_effort") != "low":
            # json.dumps deliberately escapes Unicode; repair must decode it.
            return self.reply(400, {"error": {"message": "该模型始终思考，不支持关闭思考；请使用 low、 high 或 max。"}})
        if body["model"] == "wrapped" and body.get("reasoning_effort") != "low":
            return self.reply(500, {"error": "Upstream 400: Reasoning is mandatory for this endpoint and cannot be disabled."})
        if body["model"] == "wrapped":
            return self.reply(200, {"data": {"id": "wrapped", "object": "chat.completion", "choices": [{"index": 0, "message": {"role": "assistant", "content": "OK"}, "finish_reason": "stop"}]}})
        if self.path.endswith("/responses"):
            for message in body["input"]:
                if message.get("role") == "assistant":
                    assert all(part["type"] == "output_text" for part in message["content"])
            assert body["tools"][0]["name"] == "ping"
            assert "function" not in body["tools"][0]
            if body.get("tool_choice"):
                assert body["tool_choice"] == {"type": "function", "name": "ping"}
            if len(body["input"]) > 1:
                assert body["input"][-1]["type"] == "function_call_output"
                assert body["input"][-1]["call_id"] == "call_1"
            return self.reply(200, {"id": "resp_test", "output": [{"type": "function_call", "call_id": "call_1", "name": "ping", "arguments": "{}"}], "usage": {"input_tokens": 10, "output_tokens": 3}})
        self.reply(200, {"id": "chat_test", "object": "chat.completion", "choices": [{"index": 0, "message": {"role": "assistant", "content": "OK"}, "finish_reason": "stop"}], "usage": {"prompt_tokens": 10, "completion_tokens": 3}})


def run(binary):
    upstream = ThreadingHTTPServer(("127.0.0.1", 0), Upstream)
    threading.Thread(target=upstream.serve_forever, daemon=True).start()
    port = free_port()
    base = f"http://127.0.0.1:{port}"

    def request(path, body=None, method=None):
        req = Request(base + path, json.dumps(body).encode() if body is not None else None,
                      {"Content-Type": "application/json"}, method=method)
        try:
            with urlopen(req, timeout=12) as r:
                return r.status, r.read().decode()
        except HTTPError as e:
            return e.code, e.read().decode()

    with tempfile.TemporaryDirectory(prefix="freepro-test-") as tmp:
        root = Path(tmp)
        config_dir = root / ("Library/Application Support/freepro" if sys.platform == "darwin" else "freepro")
        config_dir.mkdir(parents=True)
        providers = []
        for prefix, wire in [("chat/", "chat_completions"), ("resp/", "openai_responses")]:
            providers.append({"display_name": prefix, "base_url": f"http://127.0.0.1:{upstream.server_port}/v1",
                              "prefix": prefix, "description": "test fixture", "wire_api": wire,
                              "keys": [{"key": "test-only", "enabled": True}],
                              "headers": [{"key": "User-Agent", "value": "compat-test/1.0"},
                                          {"key": "X-Custom", "value": "preserved"}]})
        (config_dir / "freepro_config.json").write_text(json.dumps({"port": port, "providers": providers}), encoding="utf-8")
        env = dict(os.environ, APPDATA=tmp, XDG_CONFIG_HOME=tmp, HOME=tmp, USERPROFILE=tmp, FREEPRO_NO_BROWSER="1")
        with (root / "server.log").open("w") as log:
            process = subprocess.Popen([str(binary)], stdin=subprocess.PIPE, stdout=log, stderr=log,
                                       env=env, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
            try:
                for _ in range(80):
                    try:
                        if request("/api/status")[0] == 200:
                            break
                    except OSError:
                        time.sleep(.1)
                else:
                    raise AssertionError("Test server did not start")

                body = {"model": "chat/thinking", "messages": [{"role": "user", "content": "OK"}],
                        "reasoning_effort": "none", "thinking": {"type": "disabled"}}
                code, raw = request("/v1/chat/completions", body)
                assert code == 200, raw
                attempts = [b for _, _, b in seen if b and b["model"] == "thinking"]
                assert len(attempts) == 2
                assert attempts[-1]["thinking"]["type"] == "enabled"
                print("PASS explicit always-thinking rejection repairs once on the same key")
                code, raw = request("/v1/chat/completions", dict(body, model="chat/wrapped"))
                assert code == 200 and json.loads(raw)["choices"][0]["message"]["content"] == "OK", raw
                print("PASS wrapped mandatory-thinking 500 repaired and data envelope removed")

                for _ in range(4):
                    code, raw = request("/v1/chat/completions", dict(body, model="chat/bad"))
                    assert code == 400, raw
                body["reasoning_effort"] = "low"
                assert request("/v1/chat/completions", body)[0] == 200
                assert len([b for _, _, b in seen if b and b["model"] == "bad"]) == 4
                print("PASS deterministic 400s neither retry nor poison healthy keys")

                tool = {"type": "function", "function": {"name": "ping", "parameters": {"type": "object"}}}
                body = {"model": "resp/tool", "messages": [{"role": "user", "content": "ping"}],
                        "tools": [tool], "tool_choice": {"type": "function", "function": {"name": "ping"}}}
                code, raw = request("/v1/chat/completions", body)
                assert code == 200, raw
                choice = json.loads(raw)["choices"][0]
                assert choice["finish_reason"] == "tool_calls"
                assert choice["message"]["tool_calls"][0]["function"]["name"] == "ping"
                choice["message"]["content"] = "Checking the file."
                body["messages"] += [choice["message"], {"role": "tool", "tool_call_id": "call_1", "content": "pong"}]
                assert request("/v1/chat/completions", body)[0] == 200
                print("PASS Responses tool schema, forced choice, output and conversation round-trip")

                code, raw = request("/v1/chat/completions", dict(body, stream=True))
                assert code == 200, raw
                frames = [json.loads(line[6:]) for line in raw.splitlines() if line.startswith("data: ") and line != "data: [DONE]"]
                assert frames[0]["choices"][0]["delta"]["tool_calls"][0]["index"] == 0
                assert frames[-1]["choices"][0]["finish_reason"] == "tool_calls"
                assert "data: [DONE]" in raw
                print("PASS synthesized SSE preserves indexed calls and final reason")

                code, raw = request("/api/providers/0/ping/0", {})
                assert code == 200 and json.loads(raw)["ok"], raw
                assert any(b is None for _, _, b in seen)
                print("PASS custom User-Agent, Authorization and headers on POST and catalog GET")
                before = json.loads(request("/api/status")[1])
                for _ in range(8):
                    request("/api/status")
                after = json.loads(request("/api/status")[1])
                assert after["total_served"] == before["total_served"]
                assert after["avg_latency_ms"] == before["avg_latency_ms"]
                assert after["in_flight"] == 0
                print("PASS dashboard polling leaves request counts and latency unchanged")
                usage = json.loads(request("/api/usage")[1])
                assert usage["models"] and all(m["requests"] > 0 for m in usage["models"])
                assert sum(m["input"] for m in usage["models"]) == usage["total_in"]
                assert sum(m["output"] for m in usage["models"]) == usage["total_out"]
                assert any(m["model"] == "chat/thinking" and m["days"] for m in usage["models"])
                process.communicate(b"quit\n", timeout=20)
                saved = json.loads((config_dir / "freepro_config.json").read_text(encoding="utf-8"))
                assert saved["usage_models"] and saved["usage_in"] == usage["total_in"]
                process = subprocess.Popen([str(binary)], stdin=subprocess.PIPE, stdout=log, stderr=log,
                                           env=env, creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0))
                for _ in range(80):
                    try:
                        restored = json.loads(request("/api/usage")[1])
                        if "models" in restored: break
                    except OSError: pass
                    time.sleep(.1)
                else: raise AssertionError("Restart failed")
                assert restored == usage, (restored, usage)
                print("PASS per-model/day usage reconciles with totals and survives a real process restart")

            finally:
                try:
                    process.communicate(b"quit\n", timeout=20)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
                upstream.shutdown()


if __name__ == "__main__":
    run(Path(sys.argv[1] if len(sys.argv) > 1 else ("zig-out/bin/freepro-gui.exe" if os.name == "nt" else "zig-out/bin/freepro-gui")).resolve())
