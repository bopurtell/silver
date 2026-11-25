#!/usr/bin/env bash
# Run as the unprivileged CI user in a fresh checkout inside the container.
set -euo pipefail
die() { printf 'CI error: %s\n' "$*" >&2; exit 1; }

repo=$(git rev-parse --show-toplevel)
cd "$repo"
[[ -z $(git status --porcelain --untracked-files=all --ignored) ]] ||
  die 'CI requires a clean checkout without existing build products'
[[ ! -e ${XDG_DATA_HOME:?}/silver ]] ||
  die 'CI requires a fresh managed toolchain'

jobs=${SILVER_BUILD_JOBS:-2}
test_jobs=${SILVER_TEST_JOBS:-1}
[[ $jobs =~ ^[1-9][0-9]*$ && $test_jobs =~ ^[1-9][0-9]*$ ]] ||
  die 'build and test job counts must be positive integers'
export SILVER_OPAM_DISABLE_SANDBOXING=1 LC_ALL=C.UTF-8
git config --global user.name 'Silver CI'
git config --global user.email 'silver-ci@example.invalid'

TIMEFORMAT='Elapsed: %3R seconds'
trap 'df -h "$repo"; du -sh "$repo/_build" "$XDG_DATA_HOME/silver/opam" 2>/dev/null || true' EXIT
echo "=== Provision managed native dependencies ($jobs jobs) ==="
source "$repo/scripts/release/managed-toolchain.sh"
time prepare_managed_toolchain
df -h "$repo"
echo '=== Clean downloaded archives and unpacked opam build sources ==='
time opam clean --switch=silver --download-cache --switch-cleanup
df -h "$repo"

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
