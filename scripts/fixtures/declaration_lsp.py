"""Minimal LSP peer for the real Cobalt PTY test; no project indexing required."""
import json
import os
import sys


def main():
    stdin, stdout = sys.stdin.buffer, sys.stdout.buffer
    # Record only messages that prove attachment and declaration-key delivery.
    with open(os.environ["WB088_LSP_LOG"], "a", encoding="utf-8", buffering=1) as log:
        while header := stdin.readline():
            headers = {}
            while header not in (b"\r\n", b"\n", b""):
                name, value = header.split(b":", 1)
                headers[name.lower()] = value.strip()
                header = stdin.readline()
            request = json.loads(stdin.read(int(headers[b"content-length"])))
            method = request.get("method")
            if method in ("textDocument/didOpen", "textDocument/declaration"):
                log.write(json.dumps(request) + "\n")
            if method == "exit":
                return
            if "id" not in request:
                continue
            result = None
            if method == "initialize":
                result = {"capabilities": {"declarationProvider": True, "textDocumentSync": 1}}
            elif method == "textDocument/declaration":
                result = []
            body = json.dumps({"jsonrpc": "2.0", "id": request["id"], "result": result}).encode()
            stdout.write(f"Content-Length: {len(body)}\r\n\r\n".encode() + body)
            stdout.flush()


if __name__ == "__main__":
    main()
