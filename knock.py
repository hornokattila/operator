import logging
import os
import re
import select
import socket
import threading
import urllib.parse

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

COOKIE_NAME = "knock"
COOKIE_VALUE = "open"
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


def has_open_cookie(headers):
    cookie = headers.get("cookie", "")
    return re.search(rf"\b{COOKIE_NAME}={COOKIE_VALUE}\b", cookie) is not None


def send_http(conn, status, body, extra_headers=None):
    payload = body.encode("utf-8")
    head = [
        f"HTTP/1.1 {status}",
        "Content-Type: text/html; charset=utf-8",
        f"Content-Length: {len(payload)}",
        "Connection: close",
    ]
    if extra_headers:
        head.extend(extra_headers)
    response = ("\r\n".join(head) + "\r\n\r\n").encode("utf-8") + payload
    try:
        conn.sendall(response)
    except OSError:
        pass


def login_page(message):
    message_html = ""
    if message:
        message_html = f'<p style="color:#c0392b">{message}</p>'
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Login - Outside Worx</title>
<style>
body{{display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0;background:#111;color:#eee;font-family:sans-serif}}
.card{{text-align:center;background:#1a1a1a;padding:2.5em;border-radius:8px;border:1px solid #333;min-width:300px}}
h1{{margin:0 0 .5em;font-size:1.5em;font-weight:600}}
p.hint{{color:#999;margin:0 0 1.5em;font-size:.9em}}
input[type=password]{{padding:.5em;font-size:1em;border:1px solid #555;border-radius:4px;background:#222;color:#eee;width:100%;box-sizing:border-box}}
button{{padding:.5em 1.5em;font-size:1em;border:none;border-radius:4px;background:#00b2ff;color:#111;cursor:pointer;margin-top:1em}}
</style>
</head>
<body>
<form method="POST" action="/" class="card">
<h1>Outside Worx</h1>
<p class="hint">Please provide the secret to open the tunnel.</p>
{message_html}
<input type="password" name="secret" autofocus>
<br>
<button type="submit">Enter</button>
</form>
</body>
</html>"""


def status_page(title, message):
    return f"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>{title} - Outside Worx</title>
<style>
body{{display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0;background:#111;color:#eee;font-family:sans-serif}}
.card{{text-align:center;background:#1a1a1a;padding:2.5em;border-radius:8px;border:1px solid #333;min-width:300px}}
h1{{margin:0 0 .5em;font-size:1.5em;font-weight:600}}
p{{color:#999;margin:0;font-size:.9em}}
a{{color:#00b2ff}}
</style>
</head>
<body>
<div class="card">
<h1>{title}</h1>
<p>{message}</p>
</div>
</body>
</html>"""


def parse_submitted_secret(body):
    fields = urllib.parse.parse_qs(body.decode("latin-1", "replace"))
    values = fields.get("secret", [])
    return values[0] if values else None


def handle_http(conn, method, target, headers, body):
    path = target.split("?", 1)[0]

    if path == "/logout":
        set_armed(False)
        expire = f"Set-Cookie: {COOKIE_NAME}=; Path=/; HttpOnly; SameSite=Strict; Max-Age=0"
        send_http(conn, "200 OK", status_page("Tunnel closed", "The tunnel has been closed. Reload to open it again."), [expire])
        return

    if method == "POST" and path == "/":
        secret = load_secret()
        submitted = parse_submitted_secret(body)
        if secret and submitted == secret:
            set_armed(True)
            cookie = f"Set-Cookie: {COOKIE_NAME}={COOKIE_VALUE}; Path=/; HttpOnly; SameSite=Strict"
            send_http(conn, "200 OK", status_page("Tunnel open", "The tunnel is open. You may connect now. Visit /logout to close it."), [cookie])
            return
        send_http(conn, "200 OK", login_page("Try again!"))
        return

    if is_armed() and has_open_cookie(headers):
        send_http(conn, "200 OK", status_page("Tunnel open", "The tunnel is open. You may connect now. Visit /logout to close it."))
        return

    send_http(conn, "200 OK", login_page(None))


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
        method, target, headers, body = recv_http_request(conn, initial)
        handle_http(conn, method, target, headers, body)
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
