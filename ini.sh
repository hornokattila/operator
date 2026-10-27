#!/usr/bin/env bash
#
# conf.sh — provision the "operator" container.
#
# Run as root inside the container (the host Docker socket must be mounted).
# Safe to re-run: each step checks whether its work is already done
# before acting (networks, unminimize, Kiro install, PATH, git checkouts).

set -euo pipefail
shopt -s inherit_errexit

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

readonly CONTAINER="operator"

readonly NETWORKS=(
  edge
  outsideworx
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

readonly SRC_DIR="$HOME/src"

# Outside Worx repos — cloned into $SRC_DIR/outsideworx
readonly OUTSIDEWORX_ORG="git@github.com:outsideworx"
readonly OUTSIDEWORX_DIR="$SRC_DIR/outsideworx"
readonly OUTSIDEWORX_REPOS=(
  sites
  services
  .kiro
  tunde-divat
  outsideworx
  thegreen
  soupkitchen
  soupart
  igli
  gaiapeeps
  duckumbrella
  come-in-and-find-out
  .github
)

# hornokattila repos — cloned straight into $SRC_DIR
readonly HORNOKATTILA_ORG="git@github.com:hornokattila"
readonly HORNOKATTILA_DIR="$SRC_DIR"
readonly HORNOKATTILA_REPOS=(
  .vscode
  operator
)

# Global git config — shared from the hornokattila .vscode repo.
# It references the repo's .gitignore in place via core.excludesFile.
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

# require_cmds <cmd>... — abort if any command is missing.
require_cmds() {
  local cmd
  for cmd in "$@"; do
    have "$cmd" || die "required command '$cmd' not found"
  done
}

# clone_repos <org> <dest_dir> <repo>...
# Clones each repo into dest_dir, skipping any that are already cloned.
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

  # Exact network names the container is attached to, one per line.
  local attached
  attached="$(docker inspect --format \
    '{{range $name, $_ := .NetworkSettings.Networks}}{{println $name}}{{end}}' \
    "$CONTAINER")"

  local net
  for net in "${NETWORKS[@]}"; do
    if grep -qxF -- "$net" <<<"$attached"; then
      info "already connected to '$net', skipping"
    else
      info "connecting to '$net'"
      docker network connect "$net" "$CONTAINER"
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
    # unminimize removes this file once it has run.
    info "system already unminimized, skipping"
  else
    # `yes` dies of SIGPIPE when unminimize exits; ignore only that side
    # so a real unminimize failure still aborts the script.
    { yes || true; } | unminimize
  fi
}

install_kiro() {
  log "Installing Kiro CLI"
  if have "$KIRO_BIN" || [[ -x "$LOCAL_BIN/$KIRO_BIN" ]]; then
    info "Kiro already installed, skipping"
  else
    # Download fully before executing, so a truncated transfer never runs.
    local installer
    installer="$(mktemp)"
    trap 'rm -f -- "$installer"' RETURN
    curl -fsSL --proto '=https' --tlsv1.2 -o "$installer" "$KIRO_INSTALL_URL"
    bash "$installer"
  fi

  # Written literally to ~/.profile; expanded at login, not here.
  # shellcheck disable=SC2016
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
  require_cmds docker curl apt-get

  connect_networks
  install_packages
  unminimize_system
  install_kiro
  clone_all_repos
  install_gitconfig

  log "Done."
}

main "$@"
