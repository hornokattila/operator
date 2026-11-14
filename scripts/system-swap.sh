#!/usr/bin/env bash
set -euo pipefail

SWAPFILE=/swapfile
SWAPSIZE=2G

if [[ $EUID -ne 0 ]]; then
  echo "error: must be run as root" >&2
  exit 1
fi

if swapon --show | grep -q "^$SWAPFILE "; then
  echo "swap already active at $SWAPFILE — nothing to do"
  swapon --show
  free -h
  exit 0
fi

if [[ -f $SWAPFILE ]]; then
  echo "error: $SWAPFILE already exists but is not active — remove it manually before running this script" >&2
  exit 1
fi

echo "--- creating ${SWAPSIZE} swap file at ${SWAPFILE}"
fallocate -l $SWAPSIZE $SWAPFILE
chmod 600 $SWAPFILE
mkswap $SWAPFILE
swapon $SWAPFILE

echo "--- persisting to /etc/fstab"
if grep -q "^$SWAPFILE " /etc/fstab; then
  echo "fstab entry already present — skipping"
else
  echo "$SWAPFILE none swap sw 0 0" | tee -a /etc/fstab
fi

echo "--- tuning kernel parameters"
sysctl vm.swappiness=60
sysctl vm.vfs_cache_pressure=100

if grep -q 'vm.swappiness' /etc/sysctl.conf; then
  echo "vm.swappiness already in /etc/sysctl.conf — skipping"
else
  echo 'vm.swappiness=60' | tee -a /etc/sysctl.conf
fi

if grep -q 'vm.vfs_cache_pressure' /etc/sysctl.conf; then
  echo "vm.vfs_cache_pressure already in /etc/sysctl.conf — skipping"
else
  echo 'vm.vfs_cache_pressure=100' | tee -a /etc/sysctl.conf
fi

echo "--- verification"
swapon --show
free -h
grep -E 'swappiness|vfs_cache_pressure' /etc/sysctl.conf
grep swapfile /etc/fstab
