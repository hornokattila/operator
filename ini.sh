#!/bin/bash

set -euo pipefail
shopt -s inherit_errexit

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

readonly CONTAINER="operator"

readonly NETWORKS=(
  edge
)

readonly PACKAGES=(
  git
  maven
  npm
  openjdk-25-jdk
)

readonly KIRO_INSTALL_URL="https://cli.kiro.dev/install"
readonly KIRO_BIN="kiro-cli"
readonly LOCAL_BIN="$HOME/.local/bin"
readonly PROFILE="$HOME/.profile"

readonly STUNNEL_DIR="/etc/stunnel"
readonly STUNNEL_PEM="$STUNNEL_DIR/stunnel.pem"
readonly STUNNEL_CN="ops.outsideworx.net"
readonly STUNNEL_SERVICE="stunnel.service"

readonly SRC_DIR="$HOME/src"

readonly OUTSIDEWORX_ORG="git@github.com:outsideworx"
readonly OUTSIDEWORX_DIR="$SRC_DIR/outsideworx"
readonly OUTSIDEWORX_REPOS=(
  .github
  .kiro
  come-in-and-find-out
  duckumbrella
  gaiapeeps
  igli
  outsideworx
  services
  sites
  soupart
  soupkitchen
  thegreen
  tunde-divat
)

readonly HORNOKATTILA_ORG="git@github.com:hornokattila"
readonly HORNOKATTILA_DIR="$SRC_DIR"
readonly HORNOKATTILA_REPOS=(
  .vscode
  operator
)

readonly GITCONFIG_SOURCE="$HORNOKATTILA_DIR/.vscode/.gitconfig"
readonly GITCONFIG_TARGET="$HOME/.gitconfig"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

log() {
  printf '\n\033[1;34m==>\033[0m %s\n' "$*"
}

info() {
  printf '  %s\n' "$*"
}

die() {
  printf '\033[1;31mError:\033[0m %s\n' "$*" >&2
  exit 1
}

have() {
  command -v "$1" >/dev/null 2>&1
}

require_cmds() {
  local cmd
  for cmd in "$@"; do
    have "$cmd" || die "required command '$cmd' not found"
  done
}

clone_repos() {
  local org="$1" dest="$2"
  shift 2
  mkdir -p -- "$dest"
  local repo
  for repo in "$@"; do
    if [[ -d "$dest/$repo/.git" ]]; then
      info "'$repo' already cloned, skipping"
    else
      info "cloning '$repo'"
      git -C "$dest" clone -- "$org/$repo.git"
    fi
  done
}

# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

connect_networks() {
  log "Connecting '$CONTAINER' to Docker networks"

  local attached
  attached="$(docker inspect --format \
    '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' \
    "$CONTAINER")"

  local net
  for net in "${NETWORKS[@]}"; do
    if grep -qxF -- "$net" <<<"$attached"; then
      info "already connected to '$net', skipping"
    elif ! docker network inspect "$net" >/dev/null 2>&1; then
      info "network '$net' does not exist, skipping"
    elif docker network connect "$net" "$CONTAINER"; then
      info "connecting to '$net'"
    else
      info "failed to connect to '$net', skipping"
    fi
  done
}

install_packages() {
  log "Installing system packages"
  export DEBIAN_FRONTEND=noninteractive
  apt-get update
  apt-get upgrade -y
  apt-get install -y --no-install-recommends "${PACKAGES[@]}"
}

unminimize_system() {
  log "Restoring full system (unminimize)"
  if ! have unminimize; then
    info "unminimize not available, skipping"
  elif [[ ! -e /etc/dpkg/dpkg.cfg.d/excludes ]]; then
    info "system already unminimized, skipping"
  else
    { yes || true; } | unminimize
  fi
}

install_kiro() {
  log "Installing Kiro CLI"
  if have "$KIRO_BIN" || [[ -x "$LOCAL_BIN/$KIRO_BIN" ]]; then
    info "Kiro already installed, skipping"
  else
    local installer
    installer="$(mktemp)"
    trap 'rm -f -- "$installer"' RETURN
    curl -fsSL --proto '=https' --tlsv1.2 -o "$installer" "$KIRO_INSTALL_URL"
    bash "$installer"
  fi

  local path_line='export PATH="$HOME/.local/bin:$PATH"'
  if grep -qF -- '.local/bin' "$PROFILE" 2>/dev/null; then
    info "${LOCAL_BIN} already on PATH in ${PROFILE}, skipping"
  else
    info "adding ${LOCAL_BIN} to PATH in ${PROFILE}"
    printf '%s\n' "$path_line" >>"$PROFILE"
  fi
}

clone_all_repos() {
  log "Cloning Outside Worx repositories into $OUTSIDEWORX_DIR"
  clone_repos "$OUTSIDEWORX_ORG" "$OUTSIDEWORX_DIR" "${OUTSIDEWORX_REPOS[@]}"

  log "Cloning hornokattila repositories into $HORNOKATTILA_DIR"
  clone_repos "$HORNOKATTILA_ORG" "$HORNOKATTILA_DIR" "${HORNOKATTILA_REPOS[@]}"
}

install_stunnel_cert() {
  log "Generating self-signed TLS certificate for stunnel"
  if [[ -f "$STUNNEL_PEM" ]]; then
    info "certificate '$STUNNEL_PEM' already exists, skipping"
  else
    info "creating '$STUNNEL_PEM' (CN=$STUNNEL_CN)"
    install -d -m 700 -- "$STUNNEL_DIR"
    local key cert
    key="$(mktemp)"
    cert="$(mktemp)"
    trap 'rm -f -- "$key" "$cert"' RETURN
    openssl req -x509 -newkey rsa:4096 -nodes -days 3650 \
      -subj "/CN=$STUNNEL_CN" -keyout "$key" -out "$cert"
    cat -- "$cert" "$key" >"$STUNNEL_PEM"
    chmod 600 -- "$STUNNEL_PEM"
  fi

  info "restarting '$STUNNEL_SERVICE'"
  systemctl restart "$STUNNEL_SERVICE"
}

install_gitconfig() {
  log "Installing global git config"
  info "copying '$GITCONFIG_SOURCE' to '$GITCONFIG_TARGET'"
  cp -- "$GITCONFIG_SOURCE" "$GITCONFIG_TARGET"
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  ((EUID == 0)) || die "must be run as root"
  require_cmds docker curl apt-get openssl systemctl

  connect_networks
  install_packages
  install_stunnel_cert
  unminimize_system
  install_kiro
  clone_all_repos
  install_gitconfig

  log "Done."
}

main "$@"
