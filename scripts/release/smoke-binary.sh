#!/usr/bin/env bash
# Feed to bash in a separate Ubuntu 26.04 x86_64 container with /assets mounted.
set -euo pipefail
tag=${1:?expected a release tag}
archive="silver-$tag-linux-x86_64-ubuntu-26.04"
dpkg-query -W libc6 libgmp10 zlib1g
for tool in opam dune python3; do
  if command -v "$tool"; then
    printf 'unexpected build/installer tool on runtime PATH: %s\n' "$tool" >&2
    exit 1
  fi
done

cd /assets
sha256sum --strict --check SHA256SUMS
work=$(mktemp -d)
tar -xzf "$archive.tar.gz" -C "$work"
cd "$work"
mkdir home
env -i PATH=/usr/bin:/bin HOME="$work/home" LC_ALL=C.UTF-8 \
  "./$archive/install.sh" --without-asic --prefix 'test install'
commands="$archive/scripts/release/commands.txt"
prefix="$work/test install"
cp "$commands" "$work/commands.txt"
mv "$archive" "$work/detached payload"
while read -r name alias; do
  env -i PATH=/usr/bin:/bin HOME="$work/home" LC_ALL=C.UTF-8 "$prefix/bin/$name" --help >/dev/null
  if [[ -n $alias ]]; then
    [[ $(readlink "$prefix/bin/$alias") == "$name" ]]
    env -i PATH=/usr/bin:/bin HOME="$work/home" LC_ALL=C.UTF-8 "$prefix/bin/$alias" --help >/dev/null
  fi
done < "$work/commands.txt"
[[ ! -e $prefix/lib ]]

# A usable installation must carry its editable template after archive detachment.
# A stand-in is sufficient here: initialization records Python's path but does
# not execute it or require a project toolchain.
mkdir tools
cat >tools/python3 <<'EOF'
#!/bin/sh
exit 97
EOF
chmod +x tools/python3
env -i PATH="$prefix/bin:$work/tools:/usr/bin:/bin" HOME="$work/home" LC_ALL=C.UTF-8 \
  silver init --bluespec 'classic project'
test -s 'classic project/.silver/project.json'
test -s 'classic project/.workbench/hardcaml-workbench-simulation.sexp'
test -s 'classic project/Counter.bs'
test -s 'classic project/simulation_provider.py'

# Discovery metadata is published only after the daemon's internal HTTP hello succeeds.
env -i PATH=/usr/bin:/bin HOME="$work/home" LC_ALL=C.UTF-8 \
  "$prefix/bin/silver-daemon" --discovery-dir "$work/discovery" >"$work/daemon.log" 2>&1 &
daemon=$!
trap 'kill "$daemon" 2>/dev/null || true' EXIT
for ((attempt=0; attempt<100; attempt++)); do
  [[ ! -s $work/discovery/daemon.sexp ]] || break
  kill -0 "$daemon" 2>/dev/null || break
  sleep 0.1
done
if [[ ! -s $work/discovery/daemon.sexp ]]; then
  cat "$work/daemon.log" >&2
  exit 1
fi
printf 'Installed Silver daemon passed its loopback readiness check.\n'
