# Set up a project's simulation provider

Silver can generate a provider configuration and check discovery. Build and
install the provider executable using the project's own instructions first.
Silver never builds the provider or starts a test as part of setup.

## Preview and write the configuration

From a directory inside the project:

```sh
silver-simulation-setup init --discover-project \
  --provider-executable /absolute/path/to/test_provider.exe --dry-run
```

Use `--root /path/to/project` instead to name the root explicitly. The provider
path must be absolute; no `PATH` lookup is performed. If it takes arguments
before `discover` or `run`, repeat `--provider-arg ARG` in the order they are
needed. For example, a Python provider can use an absolute Python interpreter
path as the executable and pass the script's project-relative path as an
argument. Silver launches the provider from the project root.

The preview shows the destination, rendered fields, and whether the executable
is present. Remove `--dry-run` to write the file. Existing files and symlinks
are never overwritten. Discovery defaults to 10 seconds and runs to 300
seconds; override with `--discovery-timeout-seconds` and
`--run-timeout-seconds`. Set `--max-parallel-runs` above one only if the provider
isolates concurrent attempts. See the
[configuration contract](simulation_provider_contract.md#configuration-and-process-invocation)
for the file format and execution limits.

## Check discovery

```sh
silver-simulation-setup check --discover-project
```

Pass `--environment opam:SWITCH` to check in a particular switch. The default
`inherited` uses this command's environment; a separate daemon inherits its own
startup environment. A successful check reports the discovered suites and cases
or an empty catalog. Missing or invalid configuration and discovery failure are
errors, not empty catalogs.

The check invokes discovery, never runs cases, and does not update a daemon's
catalog. In Silver, open **Testing** and wait for discovery or press **d** in
the Catalog to refresh. For a complete small example, see the
[Cyclesim counter](../examples/cyclesim_counter/README.md).
