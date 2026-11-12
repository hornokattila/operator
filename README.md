# operator

A privileged systemd-based operations container. SSH is reachable only through a
TLS-masked tunnel (`stunnel` on port `8443`): on the wire the connection looks like
plain HTTPS to `outsideworx.net`. There is no raw SSH port published — recover via
`docker exec` from the host if the tunnel is ever unavailable.

The tunnel is also **port-knock gated**: before any SSH connection works you must
open it from a browser. Visit `https://outsideworx.net:8443/` (accept the
self-signed cert), enter the secret from `/etc/knock/secret` (retrieve it with
`cat /etc/knock/secret` over `docker exec` or an open session), and submit. The
tunnel is now armed for everyone until you visit `https://outsideworx.net:8443/logout`
or the `knock.service` is restarted.

All three operations below wrap SSH in TLS via `ProxyCommand`. They authenticate with
an SSH key present in the operator's `authorized_keys`; the `@host` after the user is
cosmetic because the `ProxyCommand` selects the destination. Open the knock gate in a
browser first, or these will hang/close.

## Useful Host Operations

Add these to your shell profile (e.g. `~/.zshrc` or `~/.bashrc`).

### Connect

```sh
alias ssh-operator="ssh -o ProxyCommand='openssl s_client -quiet -connect outsideworx.net:8443 -servername outsideworx.net' root@outsideworx.net"
```

### Connect (self-knocking)

> ⚠️ **`Work in progress`** — this self-knocking helper is **not finished yet** and may not work reliably.

Opens the knock gate, connects, and closes the gate again — no browser step
needed. It `POST`s the secret to the knock web view to arm the tunnel, opens the
SSH session, and `GET /logout`s afterwards (via a trap, so the gate is also
closed if the session is interrupted). The secret is percent-encoded before
submission, so arbitrary `openssl rand -base64` secrets work.

Set the secret in your profile (retrieve it in-container with
`cat /etc/knock/secret`). Remember that arming is **global** — this opens the
tunnel for everyone until logout, and anyone's `/logout` can close it mid-session.

```sh
export OPERATOR_KNOCK_SECRET="<the secret from /etc/knock/secret>"

ssh-operator() {
  local host="outsideworx.net"
  local port="8443"
  local secret="${OPERATOR_KNOCK_SECRET:?set OPERATOR_KNOCK_SECRET to the knock secret}"

  local enc
  enc=$(printf '%s' "$secret" | od -An -tx1 | tr ' ' '\n' | sed '/^$/d' | while read -r h; do
    d=$((16#$h))
    if { [ "$d" -ge 48 ] && [ "$d" -le 57 ]; } || { [ "$d" -ge 65 ] && [ "$d" -le 90 ]; } \
       || { [ "$d" -ge 97 ] && [ "$d" -le 122 ]; } \
       || [ "$d" -eq 45 ] || [ "$d" -eq 46 ] || [ "$d" -eq 95 ] || [ "$d" -eq 126 ]; then
      printf '%b' "\\x$h"
    else
      printf '%%%s' "$(printf '%s' "$h" | tr '[:lower:]' '[:upper:]')"
    fi
  done)

  _knock() {
    printf '%b' "$1" \
      | openssl s_client -quiet -no_ign_eof -connect "${host}:${port}" -servername "$host" 2>/dev/null >/dev/null
  }

  trap '_knock "GET /logout HTTP/1.1\r\nHost: '"$host"'\r\nConnection: close\r\n\r\n"' RETURN INT TERM

  _knock "POST / HTTP/1.1\r\nHost: ${host}\r\nContent-Type: application/x-www-form-urlencoded\r\nContent-Length: $((7 + ${#enc}))\r\nConnection: close\r\n\r\nsecret=${enc}"

  ssh -o ProxyCommand="openssl s_client -quiet -connect ${host}:${port} -servername ${host}" root@"$host"
}
```

### Seed SSH keys

Copies the local `~/.ssh/{authorized_keys,id_ecdsa,id_ecdsa.pub}` into the operator's
`/root/.ssh/`.

```sh
alias ini-operator="scp -o ProxyCommand='openssl s_client -quiet -connect outsideworx.net:8443 -servername outsideworx.net' ~/.ssh/authorized_keys ~/.ssh/id_ecdsa ~/.ssh/id_ecdsa.pub root@outsideworx.net:/root/.ssh/"
```

### Mount `/root/src` over sshfs

```sh
sshfs-operator() {
  local mnt="$HOME/src"
  mountpoint -q "$mnt" || sshfs root@outsideworx.net:/root/src "$mnt" \
    -o ProxyCommand="openssl s_client -quiet -connect outsideworx.net:8443 -servername outsideworx.net" \
    -o allow_other,reconnect,ServerAliveInterval=15
}
```

## Notes

- If `openssl s_client` stalls on an interactive session or a transfer, swap the
  `ProxyCommand` to `socat - OPENSSL:outsideworx.net:8443,snihost=outsideworx.net,verify=0`.
- If your default identity is not one of the operator's authorized keys, add
  `-i ~/.ssh/your_operator_key` (`ssh`/`scp`) or
  `-o IdentityFile=~/.ssh/your_operator_key` (`sshfs`).
- If `scp` errors over the tunnel, add `-O` to force the legacy transfer protocol.
