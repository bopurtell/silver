"""Compile Classic Bluespec and run the same bench under Bazel test and run."""

def _bluespec_rtl_impl(ctx):
    top = ctx.actions.declare_file(ctx.attr.top + ".v")
    modules = ctx.actions.declare_directory(ctx.label.name + "_modules")
    ctx.actions.run_shell(
        inputs = depset(ctx.files.srcs + [ctx.file.top_source]),
        outputs = [top, modules],
        arguments = [ctx.attr.top, ctx.file.top_source.path, top.path, modules.path],
        command = """
            set -eu
            work=$(mktemp -d)
            trap 'rm -rf "$work"' EXIT
            mkdir -p "$4"
            lib_opts=()
            if [[ -n "${BLUESPECDIR:-}" ]]; then
                lib_opts=(-i "$BLUESPECDIR")
            fi
            bsc "${lib_opts[@]}" -u -verilog -g "$1" -no-show-timestamps \\
                -bdir "$work" -vdir "$4" -info-dir "$work" "$2"
            cp "$4/$1.v" "$3"
        """,
        use_default_shell_env = True,
        execution_requirements = {"no-remote": "1"},
        mnemonic = "BluespecCompile",
    )
    return [
        DefaultInfo(files = depset([top])),
        OutputGroupInfo(generated_modules = depset([modules])),
    ]

bluespec_rtl = rule(
    implementation = _bluespec_rtl_impl,
    attrs = {
        "srcs": attr.label_list(allow_files = [".bs", ".bsv"]),
        "top": attr.string(mandatory = True),
        "top_source": attr.label(allow_single_file = [".bs", ".bsv"], mandatory = True),
    },
)

def _bench_test_impl(ctx):
    test = ctx.actions.declare_file(ctx.label.name)
    ctx.actions.symlink(output = test, target_file = ctx.file.bench, is_executable = True)
    return DefaultInfo(executable = test, runfiles = ctx.runfiles(files = [ctx.file.bench]))

bench_test = rule(
    implementation = _bench_test_impl,
    attrs = {"bench": attr.label(allow_single_file = True, mandatory = True)},
    test = True,
)
