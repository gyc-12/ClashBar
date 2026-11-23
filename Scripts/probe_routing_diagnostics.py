"""Loopback-only HTTP fixture and a held SOCKS connection for isolated tests."""
import http.server
import pathlib
import socket
import struct
import sys
import threading
import time

http_port, proxy_port = map(int, sys.argv[1:3])
ready_path, done_path = map(pathlib.Path, sys.argv[3:5])


class Handler(http.server.BaseHTTPRequestHandler):
    def do_HEAD(self):
        time.sleep(0.03)
        self.send_response(204)
        self.end_headers()

    def do_GET(self):
        if self.path == "/hold":
            self.send_response(200)
            self.send_header("Content-Length", "1")
            self.end_headers()
            self.wfile.flush()
            for _ in range(300):
                if done_path.exists():
                    break
                time.sleep(0.1)
            self.wfile.write(b"a")
        else:
            time.sleep(0.03)  # Avoid a legitimate sub-millisecond result of zero.
            self.send_response(204)
            self.end_headers()

    def log_message(self, *_):
        pass


server = http.server.ThreadingHTTPServer(("127.0.0.1", http_port), Handler)
threading.Thread(target=server.serve_forever, daemon=True).start()


def receive_exact(client, count):
    result = b""
    while len(result) < count:
        part = client.recv(count - len(result))
        if not part:
            raise EOFError("SOCKS connection closed")
        result += part
    return result


with socket.create_connection(("127.0.0.1", proxy_port), timeout=5) as client:
    client.sendall(b"\x05\x01\x00")
    assert receive_exact(client, 2) == b"\x05\x00"
    client.sendall(b"\x05\x01\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack("!H", http_port))
    reply = receive_exact(client, 10)
    assert reply[1] == 0, reply
    client.sendall(b"GET /hold HTTP/1.1\r\nHost: localhost\r\nConnection: close\r\n\r\n")
    headers = b""
    while b"\r\n\r\n" not in headers:
        headers += client.recv(4096)
    assert b"200" in headers
    ready_path.write_text("ready")
    for _ in range(300):
        if done_path.exists():
            break
        time.sleep(0.1)

server.shutdown()
