# Install Silver

Choose the prebuilt Ubuntu archive for the native terminal app and daemon, or
build from source to get the app and the OCaml simulation provider SDK.
Neither installation provisions the toolchain of a project you open.

## Project prerequisites

- **Dune projects:** Dune and the dependencies of the project must be available
  in the environment running the Silver service, even for browsing. For local
  use, start Silver from your project's normal shell or opam environment.
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
4. Add the prefix's `bin` directory to `PATH` if needed. Run
   `command -v silver` to check which installation the shell will use.

## Build from source

1. Download `silver-vX.Y.Z-source.tar.gz` and `SHA256SUMS` from
   [GitHub Releases](https://github.com/bopurtell/silver/releases). From the
   download directory, verify it with
   `sha256sum --ignore-missing --check SHA256SUMS`, check that the source
   archive is reported as `OK`, then extract it. For a development build,
   clone the repository instead.
2. Activate a compatible OxCaml opam switch. If you don't already have one,
   install and initialize opam, then follow the
   [OxCaml switch setup](https://github.com/oxcaml/opam-repository#installation):

   ```sh
   opam switch create 5.2.0+ox --repos ox=git+https://github.com/oxcaml/opam-repository.git,default
   eval "$(opam env --switch=5.2.0+ox)"
   ```

   If the switch already exists, run only the `eval` command. To reproduce
   the release build environment, see the exact versions and repository
   revisions in [`scripts/release/toolchain.env`](../scripts/release/toolchain.env).
3. Make a compatible [Cobalt](https://github.com/bopurtell/cobalt) build available
   to Dune in that switch. Silver embeds `cobalt.hosted` and `cobalt.terminal`;
   a standalone Cobalt executable does not provide those libraries. For
   example, install Cobalt in the selected switch with:

   ```sh
   opam pin add cobalt git+https://github.com/bopurtell/cobalt.git#649485d702304babcf3554cd4c6eca0d352d503d
   ```
4. From the extracted Silver source directory, install the remaining OCaml
   dependencies and build:

   ```sh
   opam install --deps-only ./hardcaml_workbench_provider.opam ./hardcaml_workbench.opam
   ./install.sh
   ```

   Use `./install.sh --without-asic` if you do not want to check for an ASIC
   provider at install time. Use `--switch NAME` to select an existing switch,
   `--prefix DIR` for a different install location, or `--jobs N` to set
   build parallelism. The default user install is `~/.local`; no `sudo` is needed.
5. Add the prefix's `bin` directory to `PATH` if needed. Run
   `command -v silver` to confirm the installation you will use.

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
