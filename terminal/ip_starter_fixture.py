"""Deterministic stand-in for the external renderer in the Silver runtest sandbox."""
import argparse
import json


def manifest():
    parser = argparse.ArgumentParser()
    commands = parser.add_subparsers(dest="command", required=True)
    ip = commands.add_parser("render-ip")
    ip.add_argument("--template", choices=("empty", "sample"), required=True)
    for command in (ip, commands.add_parser("render-module")):
        command.add_argument("--name", required=True)
    args = parser.parse_args()
    name = args.name
    if args.command == "render-module":
        files = {name + ".ml": "let width = 8\n"}
    else:
        width = 8 if args.template == "sample" else 0
        files = {
            f"ip/{name}/dune": f"(library (name ip_{name}))\n",
            f"ip/{name}/block.ml": f"let width = {width}\n",
            f"ip/{name}/test/dune": f"(test (name test_block) (libraries ip_{name}))\n",
            f"ip/{name}/test/test_block.ml": f"let () = assert (Ip_{name}.Block.width = {width})\n",
        }
    print(json.dumps(dict(schema_version=1, provider="hardcaml_asic", version="1",
                          files=[dict(path=k, contents=v) for k, v in files.items()])))


if __name__ == "__main__":
    manifest()
