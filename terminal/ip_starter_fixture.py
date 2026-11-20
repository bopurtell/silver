"""Deterministic stand-in for the external renderer in the Silver runtest sandbox."""
import argparse
import json


def manifest():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    ip = commands.add_parser("render-ip")
    ip.add_argument("--template", choices=("empty", "sample"), required=True)
    target = commands.add_parser("render-target", aliases=["render-existing"])
    target.add_argument("--library")
    target.add_argument("--mapping", choices=["ui_in:uo_out:comb8"])
    for command in (ip, commands.add_parser("render-module"), target, commands.add_parser("render")):
        command.add_argument("--name", required=True)
    args = parser.parse_args()
    name = args.name
    if args.command == "render-module":
        files = {name + ".ml": "let width = 8\n"}
    elif args.command == "render-ip":
        width = 8 if args.template == "sample" else 0
        files = {
            f"ip/{name}/dune": f"(library (name ip_{name}) (libraries hardcaml))\n",
            f"ip/{name}/block.ml": f"let width = {width}\n",
            f"ip/{name}/test/dune": f"(test (name test_block) (libraries ip_{name}))\n",
            f"ip/{name}/test/test_block.ml": f"let () = assert (Ip_{name}.Block.width = {width})\n",
        }
        if args.template == "sample":
            files[f"ip/{name}/block.ml"] += "let create (x : Hardcaml.Signal.t) = Hardcaml.Signal.(~:x)\n"
            files[f"ip/{name}/chip-interface.json"] = json.dumps(dict(
                schema_version=1, library=f"ip_{name}", entrypoint="Block.create",
                mapping="ui_in:uo_out:comb8", clock="unused", reset="unused"))
    else:
        files = {f"asic_{name}/project.ml": "let () = ()\n",
                 f"asic_{name}/chip.ml": "let width = 8\n",
                 f"asic_{name}/dune": "(executable (name project))\n"}
        if args.command == "render":
            files["dune-project"] = f"(lang dune 3.17)\n(name {name})\n"
    print(json.dumps(dict(schema_version=1, provider="hardcaml_asic", version="1",
                          files=[dict(path=k, contents=v) for k, v in files.items()])))


if __name__ == "__main__":
    manifest()
