# operator

A privileged systemd-based operations container. SSH is reachable only through a
TLS-masked tunnel (`stunnel` on port `8443`): on the wire the connection looks like
plain HTTPS to `outsideworx.net`. There is no raw SSH port published — recover via
`docker exec` from the host if the tunnel is ever unavailable.

All three operations below wrap SSH in TLS via `ProxyCommand`. They authenticate with
an SSH key present in the operator's `authorized_keys`; the `@host` after the user is
cosmetic because the `ProxyCommand` selects the destination.

## Useful Host Operations

Add these to your shell profile (e.g. `~/.zshrc` or `~/.bashrc`).

### Connect

```sh
alias ssh-operator="ssh -o ProxyCommand='openssl s_client -quiet -connect outsideworx.net:8443 -servername outsideworx.net' root@outsideworx.net"
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
