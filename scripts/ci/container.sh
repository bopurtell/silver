#!/usr/bin/env bash
# Entry point for a disposable Ubuntu container with /checkout mounted read-only.
set -euo pipefail
[[ $EUID == 0 && -f /.dockerenv ]] || {
  echo 'Run this entry point as root inside a fresh Docker container.' >&2
  exit 1
}

TIMEFORMAT='Elapsed: %3R seconds'
echo '=== Install Ubuntu build prerequisites ==='
source scripts/release/host-deps.sh
time install_ubuntu_build_deps
apt-get clean
df -h /

# Fetch only the selected commit into a writable repository, leaving the
# runner's checkout untouched and excluding any ignored/generated files.
git config --global --add safe.directory "$PWD"
revision=$(git rev-parse HEAD)
useradd --create-home --shell /bin/bash silver-ci
source_dir=/home/silver-ci/source
git init --quiet "$source_dir"
git -C "$source_dir" fetch --quiet --depth=1 "$PWD" HEAD
git -C "$source_dir" checkout --quiet --detach FETCH_HEAD
[[ $(git -C "$source_dir" rev-parse HEAD) == "$revision" ]]
chown -R silver-ci:silver-ci "$source_dir"
echo "=== Test revision $revision ==="

# Run opam and tests without root (some filesystem-permission tests skip as
# root). The private home also prevents leakage from any pre-existing switch.
cd "$source_dir"
exec runuser -u silver-ci -- env HOME=/home/silver-ci \
  XDG_DATA_HOME=/home/silver-ci/.local/share \
  XDG_CONFIG_HOME=/home/silver-ci/.config \
  bash scripts/ci/check.sh
