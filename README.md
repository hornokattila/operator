# operator

A privileged systemd-based operations container. SSH is reachable only through a
TLS-masked tunnel (`stunnel` on port `8443`): on the wire the connection looks like
plain HTTPS to `outsideworx.net`. There is no raw SSH port published — recover via
`docker exec` from the host if the tunnel is ever unavailable.

The tunnel is also **port-knock gated**: before any SSH connection works you must
open it with a `Bearer`-token knock. The knock gatekeeper exposes a tiny JSON API
over the same TLS front — there is **no web UI**:

- `POST https://outsideworx.net:8443/login` with header
  `Authorization: Bearer <secret>` arms the tunnel (responds `{"armed": true}`).
- `POST https://outsideworx.net:8443/logout` with the same header disarms it
  (responds `{"armed": false}`).

The `<secret>` is the contents of `/etc/knock/secret` (retrieve it with
`cat /etc/knock/secret` over `docker exec` or an open session). A wrong or missing
token gets `401`. The gate is read fresh on every request, so rotating the secret
takes effect immediately. Arming is **global and in-memory** — once opened the
tunnel is open for everyone until a `/logout` or a `knock.service` restart.

The `services` admin portal (`clients/outsideworx`) has a dedicated **Open tunnel /
Close tunnel** button pair that performs these two calls for you; it reads the token
from its key-value store (key `operator-knock-token`). You can also drive the gate
from the shell (see below).

All three SSH operations below wrap SSH in TLS via `ProxyCommand`. They authenticate
with an SSH key present in the operator's `authorized_keys`; the `@host` after the
user is cosmetic because the `ProxyCommand` selects the destination. Open the knock
gate first (portal buttons, the `curl` calls below, or the self-knocking helper), or
these will hang/close.

### Open / close the gate (curl)

```sh
export OPERATOR_KNOCK_SECRET="$(: set to the contents of /etc/knock/secret)"

# open
curl -sk -X POST -H "Authorization: Bearer $OPERATOR_KNOCK_SECRET" https://outsideworx.net:8443/login
# close
curl -sk -X POST -H "Authorization: Bearer $OPERATOR_KNOCK_SECRET" https://outsideworx.net:8443/logout
```

## Useful Host Operations

Add these to your shell profile (e.g. `~/.zshrc` or `~/.bashrc`).

### Connect

```sh
alias ssh-operator="ssh -o ProxyCommand='openssl s_client -quiet -connect outsideworx.net:8443 -servername outsideworx.net' root@outsideworx.net"
```

### Connect (self-knocking)

Opens the knock gate, connects, and closes the gate again — no portal step
needed. It `POST`s the `Bearer` token to `/login` to arm the tunnel, opens the SSH
session, and `POST`s `/logout` afterwards (via a trap, so the gate is also closed if
the session is interrupted). Because the token travels in the `Authorization`
header, arbitrary `openssl rand -base64` secrets work without encoding.

Set the secret in your profile (retrieve it in-container with
`cat /etc/knock/secret`). Remember that arming is **global** — this opens the
tunnel for everyone until logout, and anyone's `/logout` can close it mid-session.

```sh
export OPERATOR_KNOCK_SECRET="<the secret from /etc/knock/secret>"

ssh-operator() {
  local host="outsideworx.net"
  local port="8443"
  local secret="${OPERATOR_KNOCK_SECRET:?set OPERATOR_KNOCK_SECRET to the knock secret}"

  _knock() {
    curl -sk -X POST -H "Authorization: Bearer ${secret}" "https://${host}:${port}/$1" >/dev/null
  }

  trap '_knock logout' RETURN INT TERM
  _knock login

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
