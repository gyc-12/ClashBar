#!/usr/bin/env python3
"""Loopback-only probe for an independently started test core. Never discovers live cores."""
import json
import pathlib
import socket
import struct
import sys
import threading
import time

proxy_port, ready_path, done_path = int(sys.argv[1]), pathlib.Path(sys.argv[2]), pathlib.Path(sys.argv[3])
stop = threading.Event()
results = {"tcp_echoes": 0, "tcp_errors": [], "udp_echoes": 0, "udp_timeouts": 0}


def exact(sock, length):
    data = b""
    while len(data) < length:
        chunk = sock.recv(length - len(data))
        if not chunk:
            raise RuntimeError("TCP connection closed")
        data += chunk
    return data


def socks_command(command, port):
    sock = socket.create_connection(("127.0.0.1", proxy_port), timeout=1)
    sock.settimeout(1)
    sock.sendall(b"\x05\x01\x00")
    if exact(sock, 2) != b"\x05\x00":
        raise RuntimeError("SOCKS authentication failed")
    sock.sendall(bytes([5, command, 0, 1]) + socket.inet_aton("127.0.0.1") + struct.pack("!H", port))
    response = exact(sock, 4)
    if response[3] == 1:
        address = socket.inet_ntoa(exact(sock, 4))
    elif response[3] == 4:
        address = socket.inet_ntop(socket.AF_INET6, exact(sock, 16))
    else:
        address = exact(sock, exact(sock, 1)[0]).decode()
    bound_port = struct.unpack("!H", exact(sock, 2))[0]
    return sock, response[1], (address, bound_port)


tcp_server = socket.socket()
tcp_server.bind(("127.0.0.1", 0))
tcp_server.listen()
tcp_server.settimeout(0.1)
tcp_port = tcp_server.getsockname()[1]
udp_server = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
udp_server.bind(("127.0.0.1", 0))
udp_server.settimeout(0.1)
udp_port = udp_server.getsockname()[1]


def serve_connection(connection):
    with connection:
        connection.settimeout(0.1)
        while not stop.is_set():
            try:
                data = connection.recv(1024)
                if not data:
                    break
                connection.sendall(data)
            except socket.timeout:
                continue
            except OSError:
                break


def tcp_echo():
    while not stop.is_set():
        try:
            connection, _ = tcp_server.accept()
        except socket.timeout:
            continue
        threading.Thread(target=serve_connection, args=(connection,), daemon=True).start()


def udp_echo():
    while not stop.is_set():
        try:
            data, address = udp_server.recvfrom(2048)
            udp_server.sendto(data, address)
        except socket.timeout:
            continue


threads = [threading.Thread(target=tcp_echo, daemon=True), threading.Thread(target=udp_echo, daemon=True)]
for thread in threads:
    thread.start()
tcp, status, _ = socks_command(1, tcp_port)
if status:
    raise RuntimeError("Initial DIRECT TCP route rejected")
udp_control, status, relay = socks_command(3, 0)
if status:
    raise RuntimeError("UDP association rejected")
udp = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
udp.settimeout(0.08)
header = b"\x00\x00\x00\x01" + socket.inet_aton("127.0.0.1") + struct.pack("!H", udp_port)


def tcp_traffic():
    sequence = 0
    while not stop.is_set():
        try:
            message = struct.pack("!I", sequence)
            tcp.sendall(message)
            if exact(tcp, 4) != message:
                raise RuntimeError("TCP echo differs")
            results["tcp_echoes"] += 1
            sequence += 1
            time.sleep(0.005)
        except Exception as error:
            results["tcp_errors"].append(str(error))
            break


def udp_traffic():
    sequence = 0
    while not stop.is_set():
        message = struct.pack("!I", sequence)
        sequence += 1
        udp.sendto(header + message, ("127.0.0.1", relay[1]))
        try:
            response, _ = udp.recvfrom(2048)
            if response.endswith(message):
                results["udp_echoes"] += 1
        except socket.timeout:
            results["udp_timeouts"] += 1
        time.sleep(0.002)


traffic_threads = [threading.Thread(target=tcp_traffic, daemon=True), threading.Thread(target=udp_traffic, daemon=True)]
for thread in traffic_threads:
    thread.start()
try:
    deadline = time.monotonic() + 12
    while results["tcp_echoes"] < 5 or results["udp_echoes"] < 5:
        if time.monotonic() > deadline:
            raise RuntimeError("Initial traffic did not reach echo servers")
        time.sleep(0.01)
    before = results["tcp_echoes"]
    ready_path.write_text("ready")
    while not done_path.exists():
        if time.monotonic() > deadline:
            raise RuntimeError("Test reload did not finish")
        time.sleep(0.005)
    time.sleep(0.3)
    after = results["tcp_echoes"]
    fresh, status, _ = socks_command(1, tcp_port)
    rejected = status != 0
    if not rejected:
        try:
            fresh.sendall(b"new!")
            rejected = fresh.recv(4) == b""
        except ConnectionResetError:
            rejected = True
    fresh.close()
    results["new_tcp_rejected"] = rejected
    results["tcp_echoes_after_reload"] = after - before
finally:
    stop.set()
    for thread in traffic_threads:
        thread.join(timeout=1)
    for sock in [tcp, udp, udp_control, tcp_server, udp_server]:
        sock.close()
print(json.dumps(results))
if results["tcp_errors"] or results["tcp_echoes_after_reload"] < 5 or not results["new_tcp_rejected"]:
    sys.exit(1)
