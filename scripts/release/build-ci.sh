#!/usr/bin/env bash
# Run in a fresh Ubuntu 26.04 x86_64 container, from the Silver checkout.
set -euo pipefail
tag=${1:?expected a release tag}
output=${2:?expected an output directory}
jobs=${SILVER_BUILD_JOBS:-4}
source scripts/release/toolchain.env

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends \
  autoconf build-essential bzip2 ca-certificates curl git libgmp-dev libsqlite3-dev \
  opam pkg-config python3 rsync unzip xz-utils zlib1g-dev

git config --global --add safe.directory "$PWD"
git rev-parse --verify "refs/tags/${tag}^{commit}"
[[ $(git rev-parse HEAD) == "$(git rev-parse "refs/tags/${tag}^{commit}")" ]]
python3 scripts/test-installer.py
python3 -m unittest discover -s scripts/release -p 'test_*.py'

work=$(mktemp -d)
export OPAMROOT="$work/opam" OPAMROOTISOK=1

get_snapshot() {
  local repo=$1 revision=$2 dst=$3
  mkdir "$dst"
  curl -fsSL --retry 3 "https://codeload.github.com/$repo/tar.gz/$revision" -o "$dst.tar.gz"
  tar -xzf "$dst.tar.gz" --strip-components=1 -C "$dst"
  rm -- "$dst.tar.gz"
}

get_snapshot ocaml/opam-repository "$SILVER_OPAM_REPOSITORY" "$work/default"
get_snapshot oxcaml/opam-repository "$SILVER_OX_REPOSITORY" "$work/ox"
opam init --bare --disable-sandboxing --no-setup --yes default "$work/default"
opam repository add --dont-select --yes ox "$work/ox"
opam switch create --yes --jobs="$jobs" --repos=ox,default silver-release \
  --packages="ocaml-variants.5.2.0+ox,oxcaml-compiler.$SILVER_OXCAML"

git init --quiet "$work/cobalt"
git -C "$work/cobalt" fetch --quiet --depth=1 "$SILVER_COBALT_REPOSITORY" "$SILVER_COBALT_COMMIT"
git -C "$work/cobalt" checkout --quiet --detach FETCH_HEAD
opam pin add --switch=silver-release --yes --no-action cobalt "git+file://$work/cobalt#$SILVER_COBALT_COMMIT"
# Install the native stack only. The ASIC provider and optional web build are not
# dependencies; --deps-only keeps both Silver packages out of the switch.
opam install --switch=silver-release --yes --jobs="$jobs" \
  "dune.$SILVER_DUNE" "bonsai.$SILVER_JANE" "hardcaml.$SILVER_JANE"
opam install --switch=silver-release --yes --jobs="$jobs" --deps-only \
  ./hardcaml_workbench_provider.opam ./hardcaml_workbench.opam
python3 scripts/release/package.py --tag "$tag" --output "$output" \
  --switch silver-release --cobalt-repo "$work/cobalt" --jobs "$jobs"
