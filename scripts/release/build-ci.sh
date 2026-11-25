#!/usr/bin/env bash
# Run in a fresh Ubuntu 26.04 x86_64 container, from the Silver checkout.
set -euo pipefail
tag=${1:?expected a release tag}
output=${2:?expected an output directory}
jobs=${SILVER_BUILD_JOBS:-4}

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  autoconf build-essential bzip2 ca-certificates curl git gzip libgmp-dev libsqlite3-dev \
  opam pkg-config python3 rsync unzip xz-utils zlib1g-dev

git config --global --add safe.directory "$PWD"
git rev-parse --verify "refs/tags/${tag}^{commit}"
[[ $(git rev-parse HEAD) == "$(git rev-parse "refs/tags/${tag}^{commit}")" ]]
python3 scripts/test-installer.py
python3 -m unittest discover -s scripts/release -p 'test_*.py'

work=$(mktemp -d)
# The checkout is mounted read-only. Exercise the real default installer on
# a writable archive of the tag, with no existing compiler or opam root.
mkdir "$work/managed-source" "$work/home"
git archive HEAD | tar -x -C "$work/managed-source"
# Docker cannot provide the namespaces required by opam's sandbox.
unset OPAMROOT OPAMSWITCH OPAM_SWITCH
(
  cd "$work/managed-source"
  HOME="$work/home" XDG_DATA_HOME="$work/data" SILVER_OPAM_DISABLE_SANDBOXING=1 \
    ./install.sh --without-asic --jobs "$jobs" --prefix "$work/managed-prefix"
)
state="$work/data/silver"
for file in META dune-package silver_provider.cmxa; do
  [[ -f $state/sdk/lib/silver_provider/$file ]]
done
[[ ! -e $work/managed-prefix/lib/silver_provider ]]
[[ ! -e $work/home/.opam ]]
rm -rf -- "$work/managed-source"
env -i PATH=/usr/bin:/bin HOME="$work/home" LC_ALL=C.UTF-8 \
  "$work/managed-prefix/bin/ag" --help >/dev/null

# Reuse that provisioned toolchain for the explicit --switch source-archive
# installation and native release packaging; no second cold compiler build.
export OPAMROOT="$state/opam" OPAMROOTISOK=1
python3 scripts/release/package.py --tag "$tag" --output "$output" \
  --switch silver --cobalt-repo "$state/cobalt" --jobs "$jobs"
