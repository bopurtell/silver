# Install Silver

Choose the prebuilt Ubuntu archive for the native terminal app and daemon, or
build from source in a private OxCaml environment managed by the installer.
Neither installation provisions the toolchain of a project you open.

## Project prerequisites

- **Dune projects:** Dune and the dependencies of the project must be available
  in the environment running the Silver service, even for browsing. For local
  use, start Silver from your project's normal shell or opam environment.
- **Classic Bluespec starter:** install Bazel, `bsc`, Verilator, the native C++
  build tools and Rust on the service host. See the
  [front-end workflow](bluespec_classic.md). Choose `--without-asic` for a
  front-end-only Silver installation.
- **Simulation:** The project must supply a compatible simulation provider, and
  any simulators or libraries it requires. Projects that compile an OCaml
  provider may need the `silver_provider` SDK.
- **ASIC:** Install [hardcaml_asic](https://github.com/bopurtell/hardcaml_asic/tree/oxcaml)
  on the service host. Silver calls it as a separate process; a design that
  imports `Hardcaml_asic` also needs its compiled libraries in the project's
  build environment. Follow the [provider's bootstrap guide](https://github.com/bopurtell/hardcaml_asic/blob/oxcaml/docs/guides/bootstrap.md)
  to provision the flow's PDK and EDA tools. A daemon on another host uses
  that host's dependencies, not the client's.

## Install the Ubuntu binary

The archive targets Ubuntu 26.04 LTS on x86-64. It does not need opam to
install the app. Ubuntu supplies `libc6`; the other runtime packages are
`zlib1g` and `libgmp10`.

For copy-and-paste commands that download the latest release, see the
[README binary walkthrough](../README.md#install-the-ubuntu-binary).
To install a specific version manually:

1. Download `silver-vX.Y.Z-linux-x86_64-ubuntu-26.04.tar.gz` and `SHA256SUMS` from
   [GitHub Releases](https://github.com/bopurtell/silver/releases).
2. In the download directory, verify the archive. Check that your archive is
   reported as `OK`, then extract and install it. Replace `vX.Y.Z` with the
   version you downloaded:

   ```sh
   sha256sum --ignore-missing --check SHA256SUMS
   tar -xzf silver-vX.Y.Z-linux-x86_64-ubuntu-26.04.tar.gz
   cd silver-vX.Y.Z-linux-x86_64-ubuntu-26.04
   ./install.sh --without-asic
   ```

3. To check for an ASIC provider during installation, run `./install.sh`
   without `--without-asic`; the check needs Python 3. Use `--prefix DIR` to
   select a prefix other than `~/.local`.
4. Add the default prefix to `PATH` and check which installation the shell
   will use:

   ```sh
   export PATH="$HOME/.local/bin:$PATH"
   command -v ag
   ```

   `ag` is also the executable name of The Silver Searcher. If the shell
   resolves that program instead of Silver, launch Silver by its absolute
   path (`$HOME/.local/bin/ag` for the default prefix) or intentionally
   adjust your `PATH` ordering.

## Build from source

1. Install the host build dependencies. On Ubuntu:

   ```sh
   sudo apt update &&
     sudo apt install -y autoconf bubblewrap build-essential bzip2 ca-certificates curl git gzip \
       libgmp-dev libsqlite3-dev opam pkg-config python3 rsync unzip xz-utils zlib1g-dev
   ```

2. [Download the source tarball](#download-the-source-tarball) or clone
   the development checkout:

   ```sh
   git clone https://github.com/bopurtell/silver.git && cd silver
   ```

3. Run the source installer:

   ```sh
   ./install.sh --without-asic
   ```

   Omit `--without-asic` to check for a compatible ASIC provider at install
   time. Use `--switch NAME` to [select an existing switch](#use-an-existing-switch),
   `--prefix DIR` for a different install location, or `--jobs N` to set
   build parallelism. Installing Silver into the default user prefix (`~/.local`)
   does not require `sudo`.
4. Add the default prefix to `PATH` and verify the installed command:

   ```sh
   export PATH="$HOME/.local/bin:$PATH"
   command -v ag
   ```

The installer prepares OxCaml, Cobalt and the native build dependencies
using the versions and repository revisions in
[`scripts/release/toolchain.env`](../scripts/release/toolchain.env).
It does not need your project switch to be active. The first build involves
compiling the compiler and libraries, so allow time and disk space.
Rerunning the installer with matching toolchain pins reuses the private
toolchain. Launch `ag` directly
from your project's usual shell; the private compiler is not required to
run Silver.

The managed opam root is separate from `~/.opam`; by default it lives under
`${XDG_DATA_HOME:-$HOME/.local/share}/silver`. Silver's managed SDK also stays
in that private area, rather than replacing any project SDK under `~/.local/lib`.

When an update changes the toolchain pins, the installer reports the private
directory that needs to be moved aside before rebuilding. This avoids mixing
compiler or library versions. You can retain the old directory as a backup.

## Set up OxCaml

Hardware projects that use OCaml need their own project switch, separate from
Silver's build switch. If you already have a compatible switch, activate it
instead of creating another.

1. Install the host build dependencies listed above, then initialize your
   normal opam root:

   ```sh
   opam init --yes --no-setup
   ```

2. Create and activate an OxCaml switch for your projects:

   ```sh
   (opam switch list --short | grep -Fxq '5.2.0+ox' ||
     opam switch create 5.2.0+ox --repos ox=git+https://github.com/oxcaml/opam-repository.git,default) &&
     eval "$(opam env --switch=5.2.0+ox --set-switch)"
   ```

## Use an existing switch

Developers working on Silver or Cobalt can skip provisioning and use a
prepared compatible switch.

1. Activate your switch. From the Silver source directory, make Cobalt and
   the remaining native dependencies available:

   ```sh
   eval "$(opam env --switch=5.2.0+ox --set-switch)"
   . scripts/release/toolchain.env
   opam pin add --yes cobalt "git+${SILVER_COBALT_REPOSITORY}#${SILVER_COBALT_COMMIT}" &&
     opam install --yes --deps-only ./silver_provider.opam ./silver.opam
   ```

   For local Cobalt development, see [building both checkouts](cobalt_editor.md#build-and-verify)
   instead of pinning the release revision.
2. Run the installer explicitly with that switch:

   ```sh
   ./install.sh --without-asic --switch 5.2.0+ox
   ```

The explicit-switch route builds with the dependencies already available to
that switch rather than provisioning or upgrading it. Setting `OPAM_SWITCH`
explicitly is another way to select that route; merely activating a project
switch does not change the installer's managed default.

## Install the OCaml provider SDK

The SDK is independent of the Silver application. If your hardware project
compiles a native simulation provider, install the SDK with the project's
compiler and libraries, not Silver's private application build switch.
This is optional for ordinary Silver use and works with the binary install too.

From the Silver source checkout or extracted source tarball, with the project's
compatible opam switch active:

```sh
opam install ./silver_provider.opam
```

This installs only the provider package and its dependencies into the selected
project switch. It does not require Cobalt or rebuild Silver. For an isolated
SDK prefix instead, see [the provider library guide](../provider/README.md#building-and-checking).

### Download the source tarball

Use this in place of `git clone` once there is a published release. The
commands leave you in the extracted source directory.

1. Install the download tools on Ubuntu if needed:

   ```sh
   sudo apt update && sudo apt install -y curl jq
   ```

2. Download, verify, and extract the latest source archive:

   ```sh
   repo=https://github.com/bopurtell/silver
   tag=$(curl -fsSL https://api.github.com/repos/bopurtell/silver/releases/latest | jq -er '.tag_name') &&
     workdir=$(mktemp -d) && cd "$workdir" &&
     archive="silver-${tag}-source.tar.gz" &&
     curl -fsSLO "$repo/releases/download/$tag/$archive" &&
     curl -fsSLO "$repo/releases/download/$tag/SHA256SUMS" &&
     sha256sum --ignore-missing --check SHA256SUMS &&
     tar -xzf "$archive" && cd "${archive%.tar.gz}"
   ```

## ASIC provider selection

The provider must advertise CLI contract 4 and `namedflow1`. The source
installer can check a specific executable with
`--asic-provider /absolute/path/to/hardcaml_asic`; that check does not pin a
project to the executable.

At runtime, an absolute `provider_executable` in project configuration takes
precedence. Without a pin, Silver uses `SILVER_ASIC_PROVIDER` if set or
discovers a compatible `hardcaml-asic-flow` or `hardcaml_asic` on the service
host's `PATH`. Updating the provider does not by itself require rebuilding
Silver.
