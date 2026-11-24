# Project workflows

## Open or set up a project

For a new design, start `ag` outside a project and choose **New Project…**.
From an open local project use **Project → New Project…**. Choose a starter
and destination. The choice sets up the initial files and tools; it does not
restrict the languages you can use inside the design. To script creation of
the Classic Bluespec starter, use `ag init --bluespec` instead. See
[Build and simulate Classic Bluespec](bluespec_classic.md).

1. Run `ag` inside a configured Silver or Dune project to open the nearest project root. To
   specify another root, use `ag --project-root /path/to/project`.
2. For an unconfigured project, open the command palette with **Space c c**
   and choose **Set up project…**. Choose **Add ASIC starter…** to add design
   files without replacing existing sources, or **Import existing ASIC design…**
   to connect a built design executable by reference.
3. Review the preview before applying. Neither action launches an ASIC run.

Outside a recognized project, Silver opens a project setup dialog. It can open an
existing Dune project or create a project with its first chip target. Press
**Esc** to dismiss it or **p** to reopen it. Creating an ASIC starter requires
`hardcaml-asic-starter` on `PATH`; importing an existing design does not.
The **Project** menu also offers **New Project…**, **Open Project…** and
**New Chip Target…** when a local project is open.

Project state is stored under
`${XDG_STATE_HOME:-$HOME/.local/state}/silver/projects`. Only one local
standalone session can own the same project state at a time. If `TMPDIR` is
unset, Silver creates private per-session scratch space under
`${XDG_CACHE_HOME:-$HOME/.cache}/silver-runtime` and removes it on clean
shutdown. The project's Dune build and configured results paths are separate.

If opening a project reports that its state is in use, return to the other
Silver terminal, save any edits, and press **q** from the workbench. Then
reopen the project. This can happen even after deleting and recreating the
project directory: the state belongs to the canonical project **path**.
On Linux, `lslocks -o PID,COMMAND,PATH` shows which process holds the
`lifetime.lock` shown in the error; `ps -p PID -o tty,args` identifies its
terminal. The kernel releases the lock when that process exits. Don't delete
the lock file: its presence alone doesn't mean it's locked.

## Mixed-language designs

Choose the starter for the **top-level workflow**, not for every IP block.
The [mixed Hardcaml/Bluespec example](../examples/mixed_hardcaml_bluespec/README.md)
exercises this path from Silver's ordinary Build and Test actions.
For example, a Dune project can run BSC on a Classic Bluespec block and
instantiate the emitted Verilog module from a Hardcaml top using
`Hardcaml.Instantiation.create`. Match the emitted port names, widths,
clock/reset polarity and any method ready/enable signals. The build rule
for a whole-chip simulation must supply *both* the Hardcaml-generated RTL
and the child RTL (plus any BSC primitives) to Verilator.

One build system can own that dependency graph; a Bluespec file does not
require a second Silver project or even a Bazel workspace. Conversely,
instantiating an external module does not give Cyclesim a behavioral model
or add its HDL to an ASIC implementation bundle. A verification suite may
use a different host language from the design. SystemVerilog sources can
participate where the project's toolchain accepts them; this wizard does
not currently generate a standalone SystemVerilog starter.

## Edit project files

1. Select the **Editor** tab to open the project's embedded Cobalt session.
   To jump to a FIFO test's declaration, select it in **Testing** / **Catalog**
   and press **gd**.
2. Press **Alt+Left** to return to that case without closing the editor buffer.
   **Ctrl+O** navigates Cobalt's own jump history.
3. To switch to Overview from the editor, press **Space c c**, type `ov`,
   and press **Enter**.

Silver creates `~/.config/silver/editor.sexp` on first use (or uses
`XDG_CONFIG_HOME`). See the [embedded editor settings](cobalt_editor.md#embedded-editor-layout-and-theme)
for layout and theme options. Restart Silver after editing the configuration.

## Share a project with standalone Cobalt

1. Open the command palette and choose **Share with Cobalt…**.
2. Press **Enter** to share for this session. To remember the choice for the
   project, press **r** before confirming.
3. To stop advertising the project, reopen the wizard and choose **Stop
   sharing**. This does not disconnect existing clients or interrupt jobs.

Sharing advertises only the active project to your local user account.
An attached project must use a verified local daemon; SSH forwards and other
unverified endpoints cannot be shared.

## Author IP, chip targets, and flows

1. Open **Project** and choose **New IP Library…**, **New Module…**,
   **New Chip Target…**, **New Flow…**, or **Duplicate Profile…**.
2. Review the proposed files and the owning chip or library. For a new chip,
   **r** at the preview toggles registration. Registering does not make the new
   chip the default; select it explicitly when you want it as a launch target.
3. Apply the changes. If you added a flow or profile, build the owning chip's
   executable before discovering it in Silver. Authoring does not launch a run.

The same service is available from `silver-author`. By default it previews
changes; `--apply` writes them. For example:

```sh
silver-author new-ip accum --template sample
silver-author new-ip accum --template sample --apply
silver-author new-module helper --library ip/accum --apply
```

## Configure the ASIC example simulation suites

1. Install the [hardcaml_asic provider](https://github.com/LeEmperor/hardcaml_asic#install-the-provider)
   and the Silver OCaml provider SDK. A [Silver source install](install.md#build-from-source)
   installs the SDK as `hardcaml_workbench_provider`; use a switch compatible
   with the SDK build when compiling the example.
2. In a checkout of [hardcaml_asic_example](https://github.com/LeEmperor/hardcaml_asic_example),
   run `./bootstrap.sh` in that environment. It provisions the flow tools and
   configures the example's ASIC and simulation providers.
3. Run `ag`. Open **Testing** and select the **Controlled FIFO** or
   **Memory workloads** suite when discovery completes. See the
   [Testing workspace guide](testing_workspace.md) for running and inspecting
   individual cases.

## Attach to a persistent daemon

1. On the project host, start `silver-daemon --port 8080` in the environment
   that should run builds and tools.
2. For a remote host, open a loopback SSH tunnel from the client machine:

   ```sh
   ssh -N -L 8080:127.0.0.1:8080 HOST
   ```

3. In another terminal, connect to the daemon using the project path as it
   appears on the daemon host:

   ```sh
   ag --connect http://127.0.0.1:8080 --project-root /path/on/host
   ```

Quitting the attached client leaves the daemon and its jobs running.
Use `--environment opam:PROJECT_SWITCH` to select a switch on the daemon host.
The default inherited environment is the daemon's startup environment, not
necessarily the client's current shell.
