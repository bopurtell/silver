# Sourced by install.sh, only for the default source installation.
# The repository snapshots and package versions are the same inputs used by
# release CI; keep the version selections in toolchain.env.

prepare_managed_toolchain() {
  local state inherited_root entry old_bin clean_path= var snapshot name revision
  local -a path_entries init_options
  [[ -n ${HOME:-} || -n ${XDG_DATA_HOME:-} ]] ||
    die 'HOME or XDG_DATA_HOME is required for the managed toolchain'
  state=${XDG_DATA_HOME:-$HOME/.local/share}/silver
  [[ $state == /* ]] || die 'XDG_DATA_HOME must be an absolute path'
  inherited_root=${OPAMROOT:-${HOME:-}/.opam}
  old_bin=${OPAM_SWITCH_PREFIX:+$OPAM_SWITCH_PREFIX/bin}
  # Remove inherited switch-specific PATH entries before initializing a
  # compiler. opam exec later adds the managed switch's own directories.
  IFS=: read -r -a path_entries <<< "$PATH"
  for entry in "${path_entries[@]}"; do
    [[ -n $entry && $entry == /* ]] || continue
    case $entry in
      "$old_bin"|"$inherited_root"/*/bin|"${HOME:-}/.opam"/*/bin|*/_opam/bin) continue ;;
    esac
    clean_path=${clean_path:+$clean_path:}$entry
  done
  export PATH=$clean_path
  # Do not inherit opam's switch selection, solver/config overrides, or
  # compiler/library search paths from an activated development switch.
  while read -r var; do
    case $var in OPAM*|OCAML*|CAML_*|DUNE_*|OCAMLFIND*|DESTDIR) unset "$var" ;; esac
  done < <(compgen -e)
  command -v opam >/dev/null ||
    die 'opam must be available outside your activated switch for a managed installation'
  for var in curl tar git flock realpath; do
    command -v "$var" >/dev/null || die "$var is needed for the managed source toolchain"
  done

  export OPAMROOT=$state/opam
  local canonical_state canonical_root previous
  canonical_state=$(realpath -m -- "$state")
  canonical_root=$(realpath -m -- "$OPAMROOT")
  [[ ! -L $OPAMROOT ]] || die "managed root must not be a symlink: $OPAMROOT"
  for previous in "$inherited_root" "${HOME:-}/.opam"; do
    previous=$(realpath -m -- "$previous")
    if [[ $previous == "$canonical_root" && -f $state/toolchain.env ]]; then
      continue # The active opam root is already the managed root.
    fi
    if [[ $canonical_state == "$previous" || $canonical_state == "$previous/"* ||
          $previous == "$canonical_state/"* ]]; then
      die "managed root $OPAMROOT overlaps an existing user opam root"
    fi
  done
  mkdir -p -- "$state"
  export XDG_CACHE_HOME=$state/cache DUNE_CACHE=disabled
  managed_sdk=$state/sdk
  # Serialize installations through finishing Dune install, not just opam's
  # individual commands. A failed or interrupted process releases the lock.
  exec {managed_lock}>"$state/install.lock"
  flock "$managed_lock"
  local pins=$repo/scripts/release/toolchain.env
  source "$pins"
  if [[ -f $state/toolchain.env ]]; then
    cmp -s -- "$pins" "$state/toolchain.env" ||
      die "managed toolchain pins changed; move $state aside before installing this release (the old compiler and SDK are not reused across pin changes)"
  else
    [[ ! -e $OPAMROOT ]] ||
      die "refusing to take ownership of an existing opam root: $OPAMROOT"
    cp -- "$pins" "$state/toolchain.env"
  fi

  for name in default ox; do
    if [[ $name == default ]]; then
      snapshot=ocaml/opam-repository
      revision=$SILVER_OPAM_REPOSITORY
    else
      snapshot=oxcaml/opam-repository
      revision=$SILVER_OX_REPOSITORY
    fi
    if [[ ! -d $state/$name ]]; then
      local staging
      staging=$(mktemp -d "$state/snapshot.XXXXXXXX")
      if ! curl -fsSL --retry 3 "https://codeload.github.com/$snapshot/tar.gz/$revision" \
           -o "$staging/archive.tar.gz" ||
         ! mkdir "$staging/repo" ||
         ! tar -xzf "$staging/archive.tar.gz" --strip-components=1 -C "$staging/repo"; then
        die "could not fetch pinned $snapshot at $revision (staging files in $staging)"
      fi
      mv -- "$staging/repo" "$state/$name"
      rm -- "$staging/archive.tar.gz"
      rmdir -- "$staging"
    fi
  done
  if [[ ! -f $OPAMROOT/config ]]; then
    init_options=(--bare --no-setup --no-opamrc --yes)
    # The release container cannot run bubblewrap; ordinary installations
    # keep opam's default sandboxing enabled.
    if [[ ${SILVER_OPAM_DISABLE_SANDBOXING:-0} == 1 ]]; then
      init_options+=(--disable-sandboxing)
    fi
    opam init "${init_options[@]}" default "$state/default" ||
      die "could not initialize the managed opam root at $OPAMROOT"
  fi
  opam repository add --dont-select --yes ox "$state/ox" ||
    die 'could not add the pinned OxCaml repository'
  local switches
  switches=$(opam switch list --short)
  if ! grep -Fxq silver <<< "$switches"; then
    opam switch create --no-switch --yes --jobs="$jobs" --repos=ox,default silver \
      --packages="ocaml-variants.5.2.0+ox,oxcaml-compiler.$SILVER_OXCAML" ||
      die 'could not build the managed OxCaml compiler'
  fi
  if [[ ! -d $state/cobalt ]]; then
    local cobalt_stage
    cobalt_stage=$(mktemp -d "$state/cobalt.XXXXXXXX")
    git init --quiet "$cobalt_stage"
    git -C "$cobalt_stage" fetch --quiet --depth=1 "$SILVER_COBALT_REPOSITORY" "$SILVER_COBALT_COMMIT" ||
      die "could not fetch pinned Cobalt commit $SILVER_COBALT_COMMIT"
    git -C "$cobalt_stage" checkout --quiet --detach "$SILVER_COBALT_COMMIT"
    mv -- "$cobalt_stage" "$state/cobalt"
  fi
  opam pin add --switch=silver --yes --no-action cobalt "git+file://$state/cobalt#$SILVER_COBALT_COMMIT"
  # Pin the selected versions as well as installing them so the following
  # deps-only solver invocation cannot silently choose another version.
  opam pin add --switch=silver --yes --no-action --kind=version dune "$SILVER_DUNE"
  opam pin add --switch=silver --yes --no-action --kind=version bonsai "$SILVER_JANE"
  opam pin add --switch=silver --yes --no-action --kind=version hardcaml "$SILVER_JANE"
  opam install --switch=silver --yes --jobs="$jobs" \
    "dune.$SILVER_DUNE" "bonsai.$SILVER_JANE" "hardcaml.$SILVER_JANE" ||
    die 'could not install the pinned native stack in the managed switch'
  ( cd -- "$repo"
    opam install --switch=silver --yes --jobs="$jobs" --deps-only \
      ./hardcaml_workbench_provider.opam ./hardcaml_workbench.opam
  ) || die 'could not install Silver dependencies in the managed switch'
}
