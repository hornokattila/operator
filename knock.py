import hmac
import json
import logging
import os
import select
import socket
import threading
import time

logging.basicConfig(
    datefmt="%Y-%m-%d %H:%M:%S",
    format="%(asctime)s %(levelname)s --- app=knock: %(message)s",
    level=logging.INFO,
)

ARM_TTL = int(os.environ.get("KNOCK_ARM_TTL", "60"))
BUFFER_SIZE = 65536
CORS_HEADERS = [
    "Access-Control-Allow-Headers: Authorization, Content-Type",
    "Access-Control-Allow-Methods: POST, OPTIONS",
    "Access-Control-Allow-Origin: *",
    "Access-Control-Max-Age: 86400",
]
LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = int(os.environ.get("KNOCK_PORT", "22000"))
MAX_HEADER_BYTES = 16384
PEEK_BYTES = 8
PEEK_TIMEOUT = 10
SECRET_FILE = os.environ.get("KNOCK_SECRET_FILE", "/etc/knock/secret")
SSH_HOST = "127.0.0.1"
SSH_PORT = int(os.environ.get("KNOCK_SSH_PORT", "22"))

armed_lock = threading.Lock()
armed_until = 0.0


def arm():
    global armed_until
    with armed_lock:
        armed_until = time.monotonic() + ARM_TTL
    logging.info(f"Tunnel armed for [{ARM_TTL}] seconds")


def is_armed():
    with armed_lock:
        return time.monotonic() < armed_until


def load_secret():
    try:
        with open(SECRET_FILE) as f:
            return f.read().strip()
    except OSError as e:
        logging.error(f"Could not read secret file [{SECRET_FILE}]: [{e}]")
        return None


def is_authorized(headers):
    secret = load_secret()
    scheme, _, token = headers.get("authorization", "").partition(" ")
    if not secret or scheme.lower() != "bearer":
        return False
    return hmac.compare_digest(token.strip().encode(), secret.encode())


def read_request(conn):
    data = b""
    while b"\r\n\r\n" not in data and len(data) < MAX_HEADER_BYTES:
        chunk = conn.recv(BUFFER_SIZE)
        if not chunk:
            break
        data += chunk

    head = data.partition(b"\r\n\r\n")[0].decode("latin-1")
    request_line, *header_lines = head.split("\r\n")
    method, _, rest = request_line.partition(" ")
    path = rest.partition(" ")[0].partition("?")[0]

    headers = {}
    for line in header_lines:
        key, sep, value = line.partition(":")
        if sep:
            headers[key.strip().lower()] = value.strip()
    return method, path, headers


def send_response(conn, status, payload=None):
    body = json.dumps(payload).encode() if payload is not None else b""
    head = [f"HTTP/1.1 {status}", *CORS_HEADERS, f"Content-Length: {len(body)}", "Connection: close"]
    if payload is not None:
        head.append("Content-Type: application/json; charset=utf-8")
    conn.sendall(("\r\n".join(head) + "\r\n\r\n").encode() + body)


def handle_http(conn):
    method, path, headers = read_request(conn)

    if method == "OPTIONS":
        send_response(conn, "204 No Content")
    elif method != "POST" or path != "/login":
        send_response(conn, "404 Not Found", {"error": "not found"})
    elif not is_authorized(headers):
        logging.info(f"Rejected [{path}]: invalid bearer token")
        send_response(conn, "401 Unauthorized", {"error": "invalid token"})
    else:
        arm()
        send_response(conn, "200 OK", {"armed": True, "ttl": ARM_TTL})


def splice(client, upstream):
    sockets = [client, upstream]
    while True:
        readable, _, _ = select.select(sockets, [], [])
        for src in readable:
            dst = upstream if src is client else client
            data = src.recv(BUFFER_SIZE)
            if not data:
                return
            dst.sendall(data)


def handle_ssh(conn):
    if not is_armed():
        logging.info("Dropped SSH connection: tunnel not armed")
        return
    conn.settimeout(None)
    with socket.create_connection((SSH_HOST, SSH_PORT)) as upstream:
        splice(conn, upstream)


def handle_connection(conn, addr):
    with conn:
        try:
            conn.settimeout(PEEK_TIMEOUT)
            peeked = conn.recv(PEEK_BYTES, socket.MSG_PEEK)
            if peeked.startswith(b"SSH-"):
                handle_ssh(conn)
            elif peeked:
                handle_http(conn)
        except OSError as e:
            logging.error(f"Connection from [{addr[0]}:{addr[1]}] failed: [{e}]")


def serve():
    with socket.create_server((LISTEN_HOST, LISTEN_PORT)) as listener:
        logging.info(f"Listening on [{LISTEN_HOST}:{LISTEN_PORT}], upstream [{SSH_HOST}:{SSH_PORT}]")
        while True:
            conn, addr = listener.accept()
            threading.Thread(target=handle_connection, args=(conn, addr), daemon=True).start()


serve()
