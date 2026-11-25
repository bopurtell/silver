#!/usr/bin/env bash
# Run as the unprivileged CI user in a fresh checkout inside the container.
set -euo pipefail
die() { printf 'CI error: %s\n' "$*" >&2; exit 1; }

repo=$(git rev-parse --show-toplevel)
cd "$repo"
phase=${1:-all}
case $phase in provision|test|all) ;; *) die "unknown phase: $phase" ;; esac
[[ -z $(git status --porcelain --untracked-files=all --ignored) ]] ||
  die 'CI requires a clean checkout without existing build products'
state=${XDG_DATA_HOME:?}/silver
cache_hit=${SILVER_CACHE_HIT:-false}
cache_key=${SILVER_CACHE_KEY:-standalone}
[[ $cache_hit == true || $cache_hit == false ]] || die 'invalid cache hit flag'
[[ $EUID != 0 ]] || die 'CI must run as an unprivileged user'

jobs=${SILVER_BUILD_JOBS:-2}
test_jobs=${SILVER_TEST_JOBS:-1}
[[ $jobs =~ ^[1-9][0-9]*$ && $test_jobs =~ ^[1-9][0-9]*$ ]] ||
  die 'build and test job counts must be positive integers'
export SILVER_OPAM_DISABLE_SANDBOXING=1 LC_ALL=C.UTF-8
git config --global user.name 'Silver CI'
git config --global user.email 'silver-ci@example.invalid'

TIMEFORMAT='Elapsed: %3R seconds'
trap 'df -h "$repo"; du -sh "$repo/_build" "$state/opam" 2>/dev/null || true' EXIT
export OPAMROOT=$state/opam XDG_CACHE_HOME=$state/cache DUNE_CACHE=disabled

verify_toolchain() {
  [[ -f $state/ci-cache-key && $(cat "$state/ci-cache-key") == "$cache_key" ]] ||
    die 'managed toolchain has no matching successful provisioning marker'
  cmp -s "$repo/scripts/release/toolchain.env" "$state/toolchain.env" ||
    die 'managed toolchain pins do not match'
  [[ -w $state && -w $OPAMROOT && -w $OPAMROOT/silver ]] ||
    die 'managed toolchain is not writable by the CI user'
  [[ -z $(find "$state" ! -uid "$EUID" -print -quit) ]] ||
    die 'managed toolchain contains files owned by another user'
  local installed
  installed=$(opam list --switch=silver --installed --columns=package --short)
  [[ -n $installed && $installed == "$(cat "$state/ci-installed-packages")" ]] ||
    die 'managed installed package set does not match the provisioning record'
  opam exec --switch=silver -- ocamlc -version
  opam exec --switch=silver -- dune --version
}

if [[ $phase != test ]]; then
  if [[ $cache_hit == true ]]; then
    echo "=== Verify restored managed toolchain (exact hit: $cache_key; no provisioning) ==="
    time verify_toolchain
  else
    [[ ! -e $state || ( -d $state && -z $(ls -A "$state") ) ]] ||
      die 'cache miss requires an empty managed toolchain directory'
    echo "=== Provision managed native dependencies (cold, $jobs jobs) ==="
    # Do not present the new root as an inherited active opam environment.
    unset OPAMROOT
    source "$repo/scripts/release/managed-toolchain.sh"
    time prepare_managed_toolchain
    df -h "$repo"
    echo '=== Clean downloaded archives and unpacked opam build sources ==='
    time opam clean --switch=silver --download-cache --switch-cleanup
    opam list --switch=silver --installed --columns=package --short > "$state/ci-installed-packages"
    printf '%s\n' "$cache_key" > "$state/ci-cache-key"
    verify_toolchain
    df -h "$repo"
  fi
fi
[[ $phase != provision ]] || exit 0
[[ $phase != test ]] || verify_toolchain

# Nested Dune builds launched by tests should also use a bounded job count.
mkdir -p "$XDG_CONFIG_HOME/dune"
printf '(lang dune 3.0)\n(jobs %s)\n' "$test_jobs" > "$XDG_CONFIG_HOME/dune/config"
run=(opam exec --switch=silver --)
echo "=== Build native packages ($jobs jobs) ==="
time "${run[@]}" dune build -j "$jobs" -p silver_provider,silver @install
df -h "$repo"
echo "=== Run local tests ($test_jobs jobs) ==="
time "${run[@]}" dune build -j "$test_jobs" @test-local
df -h "$repo"
echo "=== Run API tests ($test_jobs jobs) ==="
time "${run[@]}" dune build -j "$test_jobs" @test-api
