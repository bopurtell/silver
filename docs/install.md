# Install Silver

Choose the prebuilt Ubuntu archive for the native terminal app and daemon, or
build from source to get the app and the OCaml simulation provider SDK.
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
  provider may need the `hardcaml_workbench_provider` SDK.
- **ASIC:** Install [hardcaml_asic](https://github.com/LeEmperor/hardcaml_asic#install-the-provider)
  on the service host. Silver calls it as a separate process; a design that
  imports `Hardcaml_asic` also needs its compiled libraries in the project's
  build environment. Follow the [provider's bootstrap guide](https://github.com/LeEmperor/hardcaml_asic/blob/main/docs/guides/bootstrap.md)
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

1. Follow [Set up OxCaml](../README.md#set-up-oxcaml) if you don't already
   have a compatible switch. If the switch already exists, activate it:

   ```sh
   eval "$(opam env --switch=5.2.0+ox --set-switch)"
   ```

   To reproduce the release build environment, see the exact versions and repository
   revisions in [`scripts/release/toolchain.env`](../scripts/release/toolchain.env).
2. [Download the source tarball](#download-the-source-tarball) or clone
   the development checkout:

   ```sh
   git clone https://github.com/bopurtell/silver.git && cd silver
   ```

3. Make a compatible [Cobalt](https://github.com/bopurtell/cobalt) build available
   to Dune in that switch. Silver embeds `cobalt.hosted` and `cobalt.terminal`;
   a standalone Cobalt executable does not provide those libraries. For
   example, install Cobalt and the remaining Silver dependencies with:

   ```sh
   opam pin add --yes cobalt 'git+https://github.com/bopurtell/cobalt.git#649485d702304babcf3554cd4c6eca0d352d503d' &&
     opam install --yes --deps-only ./hardcaml_workbench_provider.opam ./hardcaml_workbench.opam
   ```
4. Build and install from the source directory:

   ```sh
   ./install.sh --without-asic
   ```

   Omit `--without-asic` to check for a compatible ASIC provider at install
   time. Use `--switch NAME` to select an existing switch,
   `--prefix DIR` for a different install location, or `--jobs N` to set
   build parallelism. Installing Silver into the default user prefix (`~/.local`)
   does not require `sudo`.
5. Add the default prefix to `PATH` and verify the installed command:

   ```sh
   export PATH="$HOME/.local/bin:$PATH"
   command -v ag
   ```

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
