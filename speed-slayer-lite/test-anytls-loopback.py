"""Exercise actual AnyTLS/TLS on loopback only, with an explicitly trusted test CA."""
import http.server
import json
import pathlib
import select
import socket
import socketserver
import subprocess
import sys
import tempfile
import threading
import time

core, app, certificate = sys.argv[1], pathlib.Path(sys.argv[2]), sys.argv[3]
processes, logs = [], []
requests_seen = []
hello_sni = []
pinned_client = json.loads(pathlib.Path(sys.argv[4]).read_text(encoding='utf-8')) if len(sys.argv) > 4 else None


def parse_sni(record):
    """Inspect a complete TLS ClientHello record forwarded unchanged to sing-box."""
    assert record[0] == 22 and record[5] == 1, 'Expected ClientHello'
    body = record[9:]
    i = 34
    i += 1 + body[i]  # session id
    i += 2 + int.from_bytes(body[i:i+2], 'big')  # cipher suites
    i += 1 + body[i]  # compression methods
    end = i + 2 + int.from_bytes(body[i:i+2], 'big')
    i += 2
    while i < end:
        kind, length = int.from_bytes(body[i:i+2], 'big'), int.from_bytes(body[i+2:i+4], 'big')
        i += 4
        if kind == 0:
            return body[i:i+length]
        i += length
    return None


class Relay(socketserver.BaseRequestHandler):
    def handle(self):
        with socket.create_connection(('127.0.0.1', self.server.destination), timeout=5) as upstream:
            client = self.request
            captured = b''
            parsed = False
            try:
                while True:
                    readable, _, _ = select.select([client, upstream], [], [], 10)
                    if not readable:
                        return
                    for source in readable:
                        data = source.recv(65536)
                        if not data:
                            return
                        if source is client and not parsed:
                            captured += data
                            if len(captured) >= 5 and len(captured) >= 5 + int.from_bytes(captured[3:5], 'big'):
                                hello_sni.append(parse_sni(captured))
                                parsed = True
                        (upstream if source is client else client).sendall(data)
            except OSError:
                return


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
relay = None
with tempfile.TemporaryDirectory(prefix="loopback-", dir=app) as temp:
    root = pathlib.Path(temp)
    try:
        server = json.loads((app / "anytls.json").read_text(encoding="utf-8"))
        inbound = server["inbounds"][0]
        inbound["listen"], inbound["listen_port"] = "127.0.0.1", free_port()
        launch(root, "server", server, inbound["listen_port"])
        destination = inbound['listen_port']
        if pinned_client:
            installer = pathlib.Path(sys.argv[5]).read_text(encoding='utf-8')
            verifier = installer.split('verify_anytls_tls() {', 1)[1].split("<<'PY'\n", 1)[1].split('\nPY\n', 1)[0]
            result = subprocess.run([sys.executable, '-c', verifier, str(destination),
                                     pinned_client['outbounds'][0]['server'], 'selfsigned', certificate],
                                    capture_output=True, text=True, timeout=25)
            assert result.returncode == 0, result.stderr
            print('Real AnyTLS: installer TLS verifier passed')
            relay = socketserver.ThreadingTCPServer(('127.0.0.1', 0), Relay)
            relay.daemon_threads = True
            relay.destination = destination
            threading.Thread(target=relay.serve_forever, daemon=True).start()
            destination = relay.server_address[1]
        cases = ('pin-valid', 'pem-valid', 'wrong-pin', 'wrong-password', 'untrusted') if pinned_client else ('valid', 'wrong-password', 'wrong-sni', 'untrusted')
        for case in cases:
            socks_port = free_port()
            tls = dict(pinned_client['outbounds'][0]['tls']) if pinned_client else {"enabled": True, "server_name": "at.example.test", "certificate_path": certificate}
            password = inbound["users"][0]["password"]
            if case == 'pem-valid':
                tls.pop('certificate_public_key_sha256')
                tls['certificate'] = pathlib.Path(certificate).read_text(encoding='utf-8').splitlines()
                # Match v2rayN: an empty SNI falls back to the IP address. For this
                # loopback test the remote certificate's IP remains server_name.
            elif case == 'wrong-pin':
                tls['certificate_public_key_sha256'] = ['AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=']
            if case == "wrong-password":
                password = "incorrect-password"
            elif case == "wrong-sni":
                tls["server_name"] = "wrong.example.test"
            elif case == "untrusted":
                tls.pop("certificate_path", None)
                tls.pop('certificate_public_key_sha256', None)
            client = {
                "log": {"level": "warn"},
                "inbounds": [{"type": "socks", "listen": "127.0.0.1", "listen_port": socks_port}],
                "outbounds": [{"type": "anytls", "server": "127.0.0.1", "server_port": destination,
                               "password": password, "tls": tls}],
            }
            process = launch(root, case, client, socks_port)
            before = len(requests_seen)
            try:
                result = fetch(socks_port, target.server_port)
            except (OSError, EOFError):
                result = b""
            if case in ('valid', 'pin-valid', 'pem-valid'):
                assert b"200 OK" in result and b"anytls-loopback-ok" in result, result
                assert len(requests_seen) == before + 1
            else:
                assert b"anytls-loopback-ok" not in result and len(requests_seen) == before, case
            process.terminate()
            process.wait(timeout=5)
            print("Real AnyTLS:", case, "passed")
        if pinned_client:
            assert len(hello_sni) >= len(cases) and all(value is None for value in hello_sni), 'ClientHello must not contain SNI'
            print('Real AnyTLS: ClientHello without SNI verified')
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
        if relay:
            relay.shutdown()
            relay.server_close()
        target.shutdown()
        target.server_close()
