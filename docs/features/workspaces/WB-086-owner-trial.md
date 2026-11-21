# Manage This Project…: owner trial

Open a disposable, bound project with a compiled FIFO and SRAM target, and an IP library. Start in **Testing**, with a case selected. On a normal Silver launch choose **Project ▾ → Manage This Project…**. The initial trial surface is the dedicated workspace. Click **Try window** (or press `v` outside filter entry) to compare the window without restarting. **Try workspace** switches back. The captured object, filter, command focus and underlying inspection stay in place.

```sh
silver --project-root "$project"
# Optional: open in the other host first
SILVER_PROJECT_BROWSER=window silver --project-root "$project"
```

The menu and palette entry are available when bound authoring is available. `SILVER_PROJECT_BROWSER=workspace|window` sets the initial host; `off` hides the trial entry. These are temporary terminal surfaces, not persisted workspaces or operating-system windows. The full-screen Project workspace borrows the viewport; the management window occupies the right side of the live inspection. Neither adds an Overview toolbar.

| Task | Try in each host |
|---|---|
| Find New IP Library | Click **Project ▾**, **Manage This Project…**, **New IP Library…**. Cancel the template picker. |
| Create a module | F2, `/Manage This Project`, Enter. Type `/controlled_fifo`, Tab, Enter. Confirm the library directory; give the module a fresh name, preview, then apply. |
| Cancel a new chip | Click the library then **New Chip Target…**. For the sample starter IP, type `ui_in:uo_out:comb8`, Enter, a fresh chip name, Enter. Click **Cancel**, then **Done**. Try moving the original Testing case highlight. |
| Browse SRAM while FIFO is staged | Select **Chip: sram**, **New Flow…**. The wizard should highlight **Owner: sram**. Enter reads that owner's recipes. Esc returns to inspection. The browser never selects a launch target. |
| Inspect and copy a profile | Filter `/fifo_demo/standard/balanced`, Tab, Enter. Check the copy wizard's source. To inspect another chip's profiles, select its chip row, choose **Browse flows and profiles…**, then select a profile. This uses the author's read-only owner catalog. |

Tab/Shift-Tab alternate between **Objects** and **Commands**. Use arrows or counted `j`/`k` within either list; `/` filters object names and destination paths. When editing the filter, letters are literal and the arrows still move the selection. Enter on an object focuses its commands; Enter on a command invokes it. Esc clears a filter first, otherwise closes the browser. **Back to inspection** closes directly. Starting an authoring wizard releases the browser: its cancel/done returns to the inspection, not another layer of browser navigation.

In compact mode (such as 80×24), Silver may show just the focused tile. Press **F2** when the Project button is outside that tile. The same browser buttons remain clickable.

## Reproduce the comparison

```sh
export TMPDIR="$HOME/.cache/silver-dune-tmp"   # disk-backed location on this machine
mkdir -p "$TMPDIR"
dune build terminal/main.exe daemon/main.exe
python3 -B terminal/test_project_browser_pty.py \
  --client _build/default/terminal/main.exe --daemon _build/default/daemon/main.exe \
  --evidence "$HOME/.cache/wb086-owner-$(date +%s)"
```

Each host gets a new disposable project. The script builds both generated chip executables, discovers the project library, and uses the actual Silver client, daemon, and authoring RPCs. Simulated Testing cases and the slow run use the FS2 provider fixture. For an older starter without `describe-flow-authoring`, add `--recipe-fixture` to supply that one recipe descriptor; chip selection, compiled flow/profile catalogs, wizard dispatch, module apply, and chip preview/cancel are still real. Evidence includes screen text, raw PTY bytes, and daemon replies for the launch target and staged intent.

**Owner feedback:** pending. Which host made the destination clearest before you chose a command? Was seeing only part of Testing useful while a run was active? Did cancel return you where you expected?

## What to compare at 80 columns

| Observation | Project workspace | Management window |
|---|---|---|
| Discoverability | Three mouse clicks from Testing to the template picker: Project, Manage, New IP Library. | Same three clicks. No separate menu to learn. |
| Destination | Full width for library names, `For:` path and commands. | The 42-column window fits `ip/controlled_fifo` and `fifo_demo/standard/balanced`. Longer library names have less room; check `For:` before acting. |
| Keyboard travel | After the same filtered F2 entry, `/controlled_fifo`, Tab, Enter reaches module naming. | Identical keys and region order. |
| Resume | Esc closes the browser; cancel/done in the wizard goes straight to the original case. | Identical focus restoration. The visible background is inspection-only while the window is open. |
| Live inspection | The browser replaces it; Esc is necessary to see the job again. | Part of the Testing case list and execution tile remain exposed. The window can cover other panes, so it is not a substitute for the whole inspection. |

**Provisional recommendation:** prefer the window when monitoring a job; it buys visibility without an extra command or focus transition. Compare the workspace on a larger catalog with long paths before choosing. No permanent host has been selected.

### PTY observations, 2026-11-20

The 80×32 runs used the installed starter (no recipe fixture). In **both** hosts:

- Clicking **New IP Library…** opened the existing template picker. The keyboard module task wrote `ip/controlled_fifo/trial_module.ml`; `dune runtest ip/controlled_fifo` passed in both generated projects. Cancelling the chip preview left `asic_cancelled_chip/` absent.
- The selected SRAM row displayed `For: sram`; the wizard showed `> Owner: sram`, then `Choose methodology recipe · owner: sram`. Selecting FIFO's balanced profile opened `Copy explicit settings · fifo_demo/standard/balanced`. Loading SRAM's profile tree also exposed `For: sram/standard/balanced`.
- Daemon `Get` replies before and after those actions had identical FIFO chip/variant and complete staged fresh-intent records. After each exit the second Testing case remained selected and pressing `k` moved the original catalog highlight to the first case.
- In the full-screen host the running job was hidden until Esc. In the window the `Running` execution row, selected `second` case and browser commands appeared in the same frame. In both cases the job was still running on return.

Representative rows from the real window capture (the divider between inspection and browser is column 39):

```text
╰──────────────────────╯│  [x] first —▣ Management window
╭ project-tests ───────╮│> [x] second [Back to inspection]
│⣾  3603…ob-2  Running ││              › New IP Library…
```

The full raw/text captures for that comparison are in `~/.cache/wb086-real-03/{workspace,window}/` on the trial machine. See `live-browser.txt`, `flow-destination.txt`, `sram-wizard.txt`, `chip-focus.txt`, and the numbered `*-asic.stdout` files.

The installed `silver` was also launched by name, with no arguments or browser override, from a bound project. Clicking Project → Manage opened the workspace; clicking **Try window** opened the window. See `~/.cache/wb086-installed-launch/`. Host-switch focus captures are in `~/.cache/wb086-owner-default/{workspace,window}/switch-*.txt`.
