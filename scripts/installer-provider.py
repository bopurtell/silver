"""Pre-build equivalent of backend/asic_provider_discovery.ml (no switch needed)."""

import json
import math
import os
import resource
import subprocess
import sys
import tempfile


def unique(pairs):
    obj = dict(pairs)
    if len(obj) != len(pairs):
        raise ValueError("duplicate metadata key")
    return obj


def finite(text):
    value = float(text)
    if not math.isfinite(value):
        raise ValueError("non-finite metadata number")
    return value


def compatible(path):
    if not os.path.isfile(path) or not os.access(path, os.X_OK):
        return False
    limit = 1024 * 1024
    try:
        with tempfile.TemporaryFile() as output:
            subprocess.run([path, "--version", "--json"], cwd="/", timeout=3, check=True,
                           stdin=subprocess.DEVNULL, stderr=subprocess.DEVNULL, stdout=output,
                           preexec_fn=lambda: resource.setrlimit(resource.RLIMIT_FSIZE,
                                                                  (limit + 1, limit + 1)))
            if os.fstat(output.fileno()).st_size > limit:
                return False
            output.seek(0)
            contract = json.load(output, object_pairs_hook=unique, parse_float=finite,
                                 parse_constant=finite)["cli_contract"]
            return (type(contract["version"]) is int and contract["version"] == 4
                    and contract["capabilities"]["namedflow1"] is True)
    except (OSError, subprocess.SubprocessError, ValueError, KeyError, TypeError, RecursionError):
        return False


def main(override):
    if override is not None:
        if not os.path.isabs(override):
            sys.exit("ASIC provider override must be an absolute executable path")
        paths = [override]
    else:
        paths = (os.path.join(directory, name)
                 for directory in dict.fromkeys(os.environ.get("PATH", "").split(os.pathsep))
                 if os.path.isabs(directory)
                 for name in ("hardcaml-asic-flow", "hardcaml_asic"))
    for path in paths:
        if compatible(path):
            print(path)
            return
    sys.exit("No compatible ASIC CLI (requires CLI4 + namedflow1=true): "
             + (override if override is not None else "checked PATH"))


if __name__ == "__main__":
    main(sys.argv[1] or os.environ.get("SILVER_ASIC_PROVIDER"))
