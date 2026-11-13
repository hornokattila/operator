# operator

A privileged systemd-based operations container. SSH is reachable only through a
TLS-masked tunnel (`stunnel` on port `8443`): on the wire the connection looks like
plain HTTPS to `outsideworx.net`. There is no raw SSH port published — recover via
`docker exec` from the host if the tunnel is ever unavailable.

The tunnel is also **port-knock gated**: before any SSH connection works the tunnel
must be armed. Use the **`services` admin portal** (`clients/outsideworx`), which has
a single **Open tunnel** button — it arms the tunnel for **60 seconds** (shown as a
live countdown), the window in which to establish the SSH connection. The portal holds
the knock token in its key-value store (key `operator-knock-token`), so there is
nothing to copy or paste.

Arming is **global and in-memory** — once opened the tunnel is open for everyone for
60 seconds, then it re-closes on its own (there is no logout; a `knock.service` restart
also closes it immediately). Open again to extend the window. Already-established SSH
sessions survive expiry — the countdown only bounds when a *new* connection can be
opened.

All three SSH operations below wrap SSH in TLS via `ProxyCommand`. They authenticate
with an SSH key present in the operator's `authorized_keys`; the `@host` after the
user is cosmetic because the `ProxyCommand` selects the destination. Open the tunnel
from the portal first, or these will hang/close.

## Useful Host Operations

Add these to your shell profile (e.g. `~/.zshrc` or `~/.bashrc`).

### Connect

```sh
alias ssh-operator="ssh -o ProxyCommand='openssl s_client -quiet -connect outsideworx.net:8443 -servername outsideworx.net' root@outsideworx.net"
```

### Seed SSH keys

Copies the local `~/.ssh/{id_ecdsa,id_ecdsa.pub}` into the operator's
`/root/.ssh/`.

```sh
alias ini-operator="scp -o ProxyCommand='openssl s_client -quiet -connect outsideworx.net:8443 -servername outsideworx.net' ~/.ssh/id_ecdsa ~/.ssh/id_ecdsa.pub root@outsideworx.net:/root/.ssh/"
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
