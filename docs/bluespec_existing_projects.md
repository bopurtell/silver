# Update an existing Classic Bluespec project for reusable IP

If your project was created with an older `silver init --bluespec`, keep the
project and update its Bazel rules in place. Installing a newer Silver does
not change those rules. Do not run `silver init` again in your project or copy
a fresh starter over it.

## Update the compile rule once

Start from a version-control checkpoint or back up the files you edit. For a
reference that matches your upgraded Silver, generate a **separate** starter:

```sh
reference="$(mktemp -d)"
silver init --bluespec "$reference/classic"
diff -u simulation.bzl "$reference/classic/simulation.bzl"
```

The diff should show changes if you have the old rule; it does not modify
either project.

If your `_bluespec_rtl_impl` still passes `ctx.file.top_source.path` straight
to `bsc` without a package search path, merge the new `_bluespec_rtl_impl`
from the reference into your `simulation.bzl`. For the stock old rule,
replace just that function, from `def _bluespec_rtl_impl(ctx):` up to (not
including) `bluespec_rtl = rule(`. Leave `bluespec_rtl`, `bench_test`, and any
other rules alone. You can also compare with the
[current starter rule](../examples/bluespec_classic/simulation.bzl).

If you customized the compile rule, carry those edits forward rather than
replacing the function wholesale. The new rule stages only the declared
`.bs` and `.bsv` inputs in a temporary directory, rejects duplicate package
basenames, and passes that directory plus the BSC standard library to `-p`.
Keep your existing top, compiler flags and generated-Verilog outputs. Adding a
source label alone cannot fix a rule that still looks for imports only at the
project root.

## Connect the library to the design

1. Create `ip/foo` via **Project → New IP Library…**, or use an existing
   library. Its `BUILD.bazel` must expose a `sources` filegroup visible to the
   consumer. Silver's preview shows the generated package and label. If the
   menu is missing, see [the manifest note below](#if-the-authoring-menu-is-missing).
2. In your root `BUILD.bazel`, add `"//ip/foo:sources"` to the existing
   `bluespec_rtl` target's `srcs`. If you have an `IP_SOURCES` list, add it
   there instead. A stock older target can use:

   ```python
   srcs = glob(["*.bs", "*.bsv"], allow_empty = True) + [
       "//ip/foo:sources",
   ],
   ```

   Keep any other dependencies already in `srcs`. A root `glob` does not
   cross into `ip/foo` once that directory has its own `BUILD.bazel`. Add
   source labels for any additional libraries that the design imports,
   including those used by `Foo` itself if they are not already included.
3. In your consumer `.bs`, add `import Foo` (use the exact name from the
   source's `package` declaration, not its directory name). Use an exported
   function or instantiate the block as needed. Package names and source
   basenames must match in case. Adding the import alone does not instantiate
   hardware.
4. Verify from the project root, using your configured labels if different:

   ```sh
   bazel build //:rtl
   bazel test //:simulation
   ```

   A “cannot find package” error usually means the consuming rule is missing
   a `sources` label, the wrong package name was imported, or the old search
   rule is still active. If you changed the top's Verilog ports or output
   behavior, update the bench and checker intentionally; the migration itself
   does not change them.

## If the authoring menu is missing

An unchanged older starter is recognized without a manifest edit. If you
renamed or removed its starter files and the upgraded Silver does not show
**New IP Library…**, add the optional field `"language": "bluespec-classic"`
to the existing `.silver/project.json`, then reopen the project. Keep
`"schema_version": 1`, your project name, and your build/test labels.
Older Silver releases may reject the new field, so leave it out if you
still use those releases and do not need it.

This field only enables Classic Bluespec authoring. Import resolution is
owned by Bazel and BSC; leave the `.workbench/` simulation configuration
unchanged.
