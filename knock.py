import json
import logging
import os
import select
import socket
import threading

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s --- app=knock: %(message)s",
    datefmt="%Y-%m-%d %H:%M:%S",
)

LISTEN_HOST = "127.0.0.1"
LISTEN_PORT = int(os.environ.get("KNOCK_PORT", "22000"))
SSH_HOST = "127.0.0.1"
SSH_PORT = int(os.environ.get("KNOCK_SSH_PORT", "22"))
SECRET_FILE = os.environ.get("KNOCK_SECRET_FILE", "/etc/knock/secret")

PEEK_BYTES = 8
PEEK_TIMEOUT = 10
SPLICE_BUFFER = 65536

ARMED = False
ARMED_LOCK = threading.Lock()


def load_secret():
    try:
        with open(SECRET_FILE) as f:
            return f.read().strip()
    except OSError as e:
        logging.error(f"could not read secret file [{SECRET_FILE}]: [{e}]")
        return None


def is_armed():
    with ARMED_LOCK:
        return ARMED


def set_armed(value):
    global ARMED
    with ARMED_LOCK:
        ARMED = value
    logging.info(f"tunnel armed state set to [{value}]")


def recv_http_request(conn, initial):
    data = initial
    while b"\r\n\r\n" not in data:
        try:
            chunk = conn.recv(SPLICE_BUFFER)
        except OSError:
            break
        if not chunk:
            break
        data += chunk
    header_blob, _, rest = data.partition(b"\r\n\r\n")
    header_text = header_blob.decode("latin-1", "replace")
    lines = header_text.split("\r\n")
    request_line = lines[0] if lines else ""
    parts = request_line.split(" ")
    method = parts[0] if len(parts) > 0 else ""
    target = parts[1] if len(parts) > 1 else "/"
    headers = {}
    for line in lines[1:]:
        key, sep, value = line.partition(":")
        if sep:
            headers[key.strip().lower()] = value.strip()
    body = rest
    length = int(headers.get("content-length", "0") or "0")
    while len(body) < length:
        try:
            chunk = conn.recv(SPLICE_BUFFER)
        except OSError:
            break
        if not chunk:
            break
        body += chunk
    return method, target, headers, body


def bearer_token(headers):
    value = headers.get("authorization", "")
    prefix = "bearer "
    if value.lower().startswith(prefix):
        return value[len(prefix):].strip()
    return None


def send_json(conn, status, payload):
    body = json.dumps(payload).encode("utf-8")
    head = [
        f"HTTP/1.1 {status}",
        "Content-Type: application/json; charset=utf-8",
        f"Content-Length: {len(body)}",
        "Access-Control-Allow-Origin: *",
        "Access-Control-Allow-Methods: POST, OPTIONS",
        "Access-Control-Allow-Headers: Authorization, Content-Type",
        "Access-Control-Max-Age: 86400",
        "Connection: close",
    ]
    response = ("\r\n".join(head) + "\r\n\r\n").encode("utf-8") + body
    try:
        conn.sendall(response)
    except OSError:
        pass


def send_no_content(conn):
    head = [
        "HTTP/1.1 204 No Content",
        "Access-Control-Allow-Origin: *",
        "Access-Control-Allow-Methods: POST, OPTIONS",
        "Access-Control-Allow-Headers: Authorization, Content-Type",
        "Access-Control-Max-Age: 86400",
        "Content-Length: 0",
        "Connection: close",
    ]
    response = ("\r\n".join(head) + "\r\n\r\n").encode("utf-8")
    try:
        conn.sendall(response)
    except OSError:
        pass


def handle_http(conn, method, target, headers):
    path = target.split("?", 1)[0]

    if method == "OPTIONS":
        send_no_content(conn)
        return

    if method != "POST" or path not in ("/login", "/logout"):
        send_json(conn, "404 Not Found", {"error": "not found"})
        return

    secret = load_secret()
    token = bearer_token(headers)
    if not secret or token != secret:
        logging.info(f"rejected [{path}]: invalid bearer token")
        send_json(conn, "401 Unauthorized", {"error": "invalid token"})
        return

    if path == "/login":
        set_armed(True)
        send_json(conn, "200 OK", {"armed": True})
        return

    set_armed(False)
    send_json(conn, "200 OK", {"armed": False})


def splice(client, upstream):
    sockets = [client, upstream]
    try:
        while True:
            readable, _, errored = select.select(sockets, [], sockets)
            if errored:
                break
            for src in readable:
                dst = upstream if src is client else client
                data = src.recv(SPLICE_BUFFER)
                if not data:
                    return
                dst.sendall(data)
    except OSError:
        return


def handle_ssh(conn):
    if not is_armed():
        logging.info("dropped SSH connection: tunnel not armed")
        return
    upstream = socket.create_connection((SSH_HOST, SSH_PORT))
    try:
        splice(conn, upstream)
    finally:
        upstream.close()


def handle_connection(conn, addr):
    try:
        conn.settimeout(PEEK_TIMEOUT)
        try:
            peeked = conn.recv(PEEK_BYTES, socket.MSG_PEEK)
        except OSError:
            return
        if not peeked:
            return

        if peeked.startswith(b"SSH-"):
            conn.settimeout(None)
            handle_ssh(conn)
            return

        initial = conn.recv(SPLICE_BUFFER)
        method, target, headers, _ = recv_http_request(conn, initial)
        handle_http(conn, method, target, headers)
    except Exception as e:
        logging.error(f"error handling connection from [{addr}]: [{e}]")
    finally:
        try:
            conn.shutdown(socket.SHUT_RDWR)
        except OSError:
            pass
        conn.close()


def serve():
    logging.info(f"listening on [{LISTEN_HOST}:{LISTEN_PORT}], upstream [{SSH_HOST}:{SSH_PORT}]")
    listener = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    listener.bind((LISTEN_HOST, LISTEN_PORT))
    listener.listen(128)
    while True:
        conn, addr = listener.accept()
        thread = threading.Thread(target=handle_connection, args=(conn, addr), daemon=True)
        thread.start()


serve()
