# Project workflows

## Open or set up a project

For a new Classic Bluespec design, run `silver init --bluespec` in an empty
directory. See [Build and simulate Classic Bluespec](bluespec_classic.md).

1. Run `silver` inside a configured Silver or Dune project to open the nearest project root. To
   specify another root, use `silver --project-root /path/to/project`.
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
3. Run `silver`. Open **Testing** and select the **Controlled FIFO** or
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
   silver --connect http://127.0.0.1:8080 --project-root /path/on/host
   ```

Quitting the attached client leaves the daemon and its jobs running.
Use `--environment opam:PROJECT_SWITCH` to select a switch on the daemon host.
The default inherited environment is the daemon's startup environment, not
necessarily the client's current shell.
