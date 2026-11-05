"""Exercise actual AnyTLS/TLS on loopback only, with an explicitly trusted test CA."""
import http.server
import json
import pathlib
import socket
import subprocess
import sys
import tempfile
import threading
import time

core, app, certificate = sys.argv[1], pathlib.Path(sys.argv[2]), sys.argv[3]
processes, logs = [], []
requests_seen = []


class Handler(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        requests_seen.append(self.path)
        body = b"anytls-loopback-ok"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *_):
        pass


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def launch(root, name, config, port):
    path = root / (name + ".json")
    path.write_text(json.dumps(config), encoding="utf-8")
    check = subprocess.run([core, "check", "-c", str(path)], capture_output=True, text=True)
    assert check.returncode == 0, check.stderr
    log = (root / (name + ".log")).open("w+", encoding="utf-8")
    logs.append(log)
    process = subprocess.Popen(
        [core, "run", "-c", str(path)], stdout=log, stderr=log,
        creationflags=getattr(subprocess, "CREATE_NO_WINDOW", 0),
    )
    processes.append(process)
    for _ in range(100):
        if process.poll() is not None:
            log.flush()
            log.seek(0)
            raise AssertionError(log.read())
        try:
            with socket.create_connection(("127.0.0.1", port), timeout=0.1):
                return process
        except OSError:
            time.sleep(0.05)
    raise AssertionError("Temporary core failed to listen")


def exact(sock, n):
    result = b""
    while len(result) < n:
        part = sock.recv(n - len(result))
        if not part:
            raise EOFError("Proxy disconnected")
        result += part
    return result


def fetch(socks_port, target_port):
    with socket.create_connection(("127.0.0.1", socks_port), timeout=5) as sock:
        sock.sendall(b"\x05\x01\x00")
        assert exact(sock, 2) == b"\x05\x00"
        sock.sendall(b"\x05\x01\x00\x01\x7f\x00\x00\x01" + target_port.to_bytes(2, "big"))
        header = exact(sock, 4)
        if header[1] != 0:
            raise ConnectionError("SOCKS request rejected")
        n = {1: 4, 4: 16}.get(header[3])
        if n is None:
            n = exact(sock, 1)[0]
        exact(sock, n + 2)
        sock.sendall(b"GET /verified HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
        result = b""
        while True:
            data = sock.recv(4096)
            if not data:
                return result
            result += data


target = http.server.ThreadingHTTPServer(("127.0.0.1", 0), Handler)
threading.Thread(target=target.serve_forever, daemon=True).start()
with tempfile.TemporaryDirectory(prefix="loopback-", dir=app) as temp:
    root = pathlib.Path(temp)
    try:
        server = json.loads((app / "anytls.json").read_text(encoding="utf-8"))
        inbound = server["inbounds"][0]
        inbound["listen"], inbound["listen_port"] = "127.0.0.1", free_port()
        launch(root, "server", server, inbound["listen_port"])
        for case in ("valid", "wrong-password", "wrong-sni", "untrusted"):
            socks_port = free_port()
            tls = {"enabled": True, "server_name": "at.example.test", "certificate_path": certificate}
            password = inbound["users"][0]["password"]
            if case == "wrong-password":
                password = "incorrect-password"
            elif case == "wrong-sni":
                tls["server_name"] = "wrong.example.test"
            elif case == "untrusted":
                tls.pop("certificate_path")
            client = {
                "log": {"level": "warn"},
                "inbounds": [{"type": "socks", "listen": "127.0.0.1", "listen_port": socks_port}],
                "outbounds": [{"type": "anytls", "server": "127.0.0.1", "server_port": inbound["listen_port"],
                               "password": password, "tls": tls}],
            }
            process = launch(root, case, client, socks_port)
            before = len(requests_seen)
            try:
                result = fetch(socks_port, target.server_port)
            except (OSError, EOFError):
                result = b""
            if case == "valid":
                assert b"200 OK" in result and b"anytls-loopback-ok" in result, result
                assert len(requests_seen) == before + 1
            else:
                assert b"anytls-loopback-ok" not in result and len(requests_seen) == before, case
            process.terminate()
            process.wait(timeout=5)
            print("Real AnyTLS:", case, "passed")
    finally:
        for process in reversed(processes):
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
        for log in logs:
            log.close()
        target.shutdown()
        target.server_close()
