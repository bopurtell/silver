#!/usr/bin/env bash
# Entry point for a disposable Ubuntu container with /checkout mounted read-only.
set -euo pipefail
[[ $EUID == 0 && -f /.dockerenv ]] || {
  echo 'Run this entry point as root inside a fresh Docker container.' >&2
  exit 1
}

phase=${1:-all}
case $phase in setup|provision|test|all) ;; *) exit 2 ;; esac
TIMEFORMAT='Elapsed: %3R seconds'
source_dir=/home/silver-ci/source
if [[ $phase == setup || $phase == all ]]; then
  echo '=== Install Ubuntu build prerequisites ==='
  source scripts/release/host-deps.sh
  time install_ubuntu_build_deps
  apt-get clean
  df -h /

  # Fetch only the selected commit into a writable repository, leaving the
  # runner's checkout untouched and excluding any ignored/generated files.
  git config --global --add safe.directory "$PWD"
  revision=$(git rev-parse HEAD)
  # Match the runner's numerical IDs so the cache action can archive and
  # restore the bind-mounted state without sudo or recursive ownership changes.
  uid=${SILVER_CI_UID:-1001}
  gid=${SILVER_CI_GID:-1001}
  [[ $uid =~ ^[1-9][0-9]*$ && $gid =~ ^[1-9][0-9]*$ ]]
  if ! getent group "$gid" >/dev/null; then groupadd --gid "$gid" silver-ci; fi
  if existing=$(getent passwd "$uid"); then
    # Ubuntu's image reserves UID 1000 for its unused ubuntu account.
    [[ ${existing%%:*} == ubuntu ]] || {
      echo "Unexpected existing account for CI UID $uid" >&2
      exit 1
    }
    usermod --login silver-ci --gid "$gid" --groups '' \
      --home /home/silver-ci --shell /bin/bash ubuntu
  else
    useradd --uid "$uid" --gid "$gid" --create-home --shell /bin/bash silver-ci
  fi
  # Docker may have created the home and .local as root while mounting share.
  mkdir -p /home/silver-ci/.local
  chown "$uid:$gid" /home/silver-ci /home/silver-ci/.local
  git init --quiet "$source_dir"
  git -C "$source_dir" fetch --quiet --depth=1 "$PWD" HEAD
  git -C "$source_dir" checkout --quiet --detach FETCH_HEAD
  [[ $(git -C "$source_dir" rev-parse HEAD) == "$revision" ]]
  chown -R "$uid:$gid" "$source_dir"
  echo "=== Test revision $revision ==="
fi
[[ $phase != setup ]] || exit 0

# Run opam and tests without root (some filesystem-permission tests skip as
# root). The private home also prevents leakage from any pre-existing switch.
cd "$source_dir"
exec runuser -u silver-ci -- env HOME=/home/silver-ci \
  XDG_DATA_HOME=/home/silver-ci/.local/share \
  XDG_CONFIG_HOME=/home/silver-ci/.config \
  bash scripts/ci/check.sh "$phase"
