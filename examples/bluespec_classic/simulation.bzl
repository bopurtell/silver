"""Compile Classic Bluespec and run the same bench under Bazel test and run."""

def _bluespec_rtl_impl(ctx):
    top = ctx.actions.declare_file(ctx.attr.top + ".v")
    modules = ctx.actions.declare_directory(ctx.label.name + "_modules")
    sources = depset(ctx.files.srcs + [ctx.file.top_source])
    packages = {}
    for src in sources.to_list():
        if src.extension not in ["bs", "bsv"]:
            fail("Expected a .bs or .bsv file in srcs, got {}".format(src.short_path))
        package = src.basename[:-(len(src.extension) + 1)]
        if package in packages:
            fail("Duplicate Bluespec package {}: {} and {}".format(
                package,
                packages[package],
                src.short_path,
            ))
        packages[package] = src.short_path

    source_args = ctx.actions.args()
    source_args.add_all(sources)
    ctx.actions.run_shell(
        inputs = sources,
        outputs = [top, modules],
        arguments = [
            ctx.attr.top,
            ctx.file.top_source.basename,
            top.path,
            modules.path,
            source_args,
        ],
        command = """
            set -eu
            work=$(mktemp -d)
            trap 'rm -rf "$work"' EXIT
            top=$1 entry=$2 output=$3 modules=$4
            shift 4
            mkdir -p "$modules" "$work/src" "$work/obj"
            # BSC imports by package name, not Bazel label. Stage exactly the
            # declared files so imports cannot pick up undeclared neighbors.
            for src in "$@"; do
                cp -- "$src" "$work/src/"
            done
            lib_opts=()
            if [[ -n "${BLUESPECDIR:-}" ]]; then
                lib_opts=(-i "$BLUESPECDIR")
            fi
            bsc "${lib_opts[@]}" -u -verilog -g "$top" -no-show-timestamps \\
                -p "$work/src:%/Libraries" -bdir "$work/obj" \\
                -vdir "$modules" -info-dir "$work/obj" "$work/src/$entry"
            cp "$modules/$top.v" "$output"
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
