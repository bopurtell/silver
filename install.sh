#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: ./install.sh [--prefix DIR] [--switch NAME] [--jobs N] [--asic-provider PATH | --without-asic]

Build and install native Silver using an existing opam switch.
  --prefix DIR   Installation directory (default: $SILVER_PREFIX, $PREFIX, or ~/.local)
  --switch NAME  Existing switch (default: $OPAM_SWITCH or opam's current switch)
  --jobs N       Parallel build jobs (default: $SILVER_BUILD_JOBS, $HCW_BUILD_JOBS, or 4)

  --asic-provider PATH   Require this absolute executable for install preflight
  --without-asic         Skip provider preflight for a generic Silver installation

Standard installation requires CLI contract 4 with namedflow1=true. The check
uses --asic-provider, then $SILVER_ASIC_PROVIDER, then hardcaml-asic-flow or
hardcaml_asic in absolute PATH directories. No selection is written to disk.
At runtime a project's provider_executable takes precedence; if omitted, Silver
uses $SILVER_ASIC_PROVIDER or PATH. A project without ASIC config stays generic.
EOF
}

die() { printf 'install.sh: %s\n' "$*" >&2; exit 1; }
prefix=${SILVER_PREFIX:-${PREFIX:-}}
switch=${OPAM_SWITCH:-}
jobs=${SILVER_BUILD_JOBS:-${HCW_BUILD_JOBS:-4}}
without_asic=false
asic_provider=
while (($#)); do
  case $1 in
    -h|--help) usage; exit 0 ;;
    --without-asic) without_asic=true; shift ;;
    --prefix|--switch|--jobs|--asic-provider)
      [[ $# -ge 2 && -n $2 && $2 != --* ]] || die "$1 requires a value (see --help)"
      case $1 in
        --prefix) prefix=$2 ;;
        --switch) switch=$2 ;;
        --jobs) jobs=$2 ;;
        --asic-provider) asic_provider=$2 ;;
      esac
      shift 2 ;;
    *) die "unknown argument: $1 (see --help)" ;;
  esac
done
[[ $jobs =~ ^[1-9][0-9]*$ ]] || die '--jobs must be a positive integer'
[[ $without_asic == false || -z $asic_provider ]] || die '--without-asic conflicts with --asic-provider'
repo=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
if [[ $without_asic == false ]]; then
  command -v python3 >/dev/null || die 'python3 is needed for ASIC provider preflight'
  provider=$(python3 "$repo/scripts/installer-provider.py" "$asic_provider") ||
    die 'install a compatible hardcaml_asic CLI, pass --asic-provider /absolute/path, or use --without-asic'
  printf 'Compatible ASIC provider: %s\n' "$provider"
  if [[ -n $asic_provider ]]; then
    printf 'To select it at runtime for projects without a provider pin:\n  export SILVER_ASIC_PROVIDER=%q\n' "$provider"
  fi
fi
if [[ -z $prefix ]]; then
  [[ -n ${HOME:-} ]] || die 'HOME is unset; supply --prefix DIR'
  prefix=$HOME/.local
fi
[[ $prefix == /* ]] || prefix=$PWD/$prefix
command -v opam >/dev/null || die 'opam is missing from PATH; install opam and select an existing OCaml switch'
if [[ -z $switch ]]; then
  switch=$(opam switch show) && [[ -n $switch ]] ||
    die 'no selected opam switch; list existing switches with "opam switch list" and pass --switch NAME'
fi
# Relative local switch names, like relative prefixes, are relative to the caller.
case $switch in .|..|./*|../*) switch=$PWD/$switch ;; esac
run=(opam exec "--switch=$switch" --)
"${run[@]}" ocamlc -version >/dev/null ||
  die "cannot use OCaml in switch '$switch'; check 'opam switch list' and pass --switch NAME"

cd -- "$repo"
packages=(hardcaml_workbench_provider hardcaml_workbench)
deps_hint() {
  printf 'If build dependencies are missing, install them in the selected switch with:\n  cd %q && opam install --switch=%q --deps-only ./hardcaml_workbench_provider.opam ./hardcaml_workbench.opam\n' \
    "$repo" "$switch" >&2
  printf 'For cobalt.hosted, see docs/features/workspaces/WB-087-cobalt-editor.md#build-and-verify.\n' >&2
}
"${run[@]}" dune --version >/dev/null || { deps_hint; die "dune is unavailable in switch '$switch'"; }
printf 'Building native Silver in switch %s for %s\n' "$switch" "$prefix"
"${run[@]}" dune build -j "$jobs" -p hardcaml_workbench_provider,hardcaml_workbench @install ||
  { deps_hint; die 'native build failed; see the Dune diagnostic above'; }
"${run[@]}" dune install --root . -j "$jobs" --prefix "$prefix" "${packages[@]}" ||
  die "install failed; check the diagnostic above and choose a writable --prefix"
printf 'Installed Silver. From a Dune project, run: %q\n' "$prefix/bin/silver"
if [[ $(type -P silver || :) != "$prefix/bin/silver" ]]; then
  printf 'To launch this installation by name, put its bin directory first on PATH:\n  export PATH=%q:"$PATH"\n' "$prefix/bin"
fi
