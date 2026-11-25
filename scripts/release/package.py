"""Build both Silver release tarballs from the checked-out commit, not local edits."""

import argparse
import gzip
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tarfile
import tempfile


HERE = Path(__file__).resolve().parent
REPO = HERE.parents[1]
TARGET = "linux-x86_64-ubuntu-26.04"
SONAMES = {"libc.so.6", "libm.so.6", "libgmp.so.10", "libz.so.1", "ld-linux-x86-64.so.2"}
LOADER = "/lib64/ld-linux-x86-64.so.2"
VERSION = r"v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)"


def text(*args, **kwargs):
    return subprocess.check_output(args, text=True, **kwargs).strip()


def git(*args, repo=REPO):
    return text("git", "-C", repo, *args)


def names(tag):
    if not re.fullmatch(VERSION, tag):
        raise ValueError("release tag must be vMAJOR.MINOR.PATCH with no leading zeroes")
    return f"silver-{tag}-source", f"silver-{tag}-{TARGET}"


def assert_platform():
    release = dict(
        line.replace('"', "").split("=", 1)
        for line in Path("/etc/os-release").read_text().splitlines()
        if "=" in line and not line.startswith("#")
    )
    if (os.uname().sysname, os.uname().machine, release.get("ID"), release.get("VERSION_ID")) != (
        "Linux", "x86_64", "ubuntu", "26.04"
    ):
        raise ValueError(f"build the binary tarball on {TARGET}")


def archive(root, dest, epoch):
    # No checkout timestamps, umask-dependent modes, build host UID, or gzip filename.
    with dest.open("wb") as raw, gzip.GzipFile(
        filename="", mode="wb", fileobj=raw, mtime=epoch, compresslevel=6
    ) as zipped, tarfile.open(mode="w", fileobj=zipped, format=tarfile.PAX_FORMAT) as tar:
        for path in [root, *sorted(root.rglob("*"))]:
            info = tar.gettarinfo(str(path), str(path.relative_to(root.parent)))
            info.uid = info.gid = 0
            info.uname = info.gname = "root"
            info.mtime = epoch
            info.mode = 0o755 if info.isdir() or info.mode & 0o111 else 0o644
            if info.isfile():
                with path.open("rb") as source:
                    tar.addfile(info, source)
            else:
                tar.addfile(info)


def git_archive(commit, dest, scratch):
    # A git archive excludes untracked files, worktree edits and build products.
    staged_tar = scratch / "commit.tar"
    with staged_tar.open("wb") as out:
        subprocess.run(["git", "-C", REPO, "archive", "--format=tar", commit], stdout=out, check=True)
    dest.mkdir()
    with tarfile.open(staged_tar) as tar:
        tar.extractall(dest, filter="data")
    staged_tar.unlink()


def write_json(dest, data):
    dest.write_text(json.dumps(data, indent=2, sort_keys=True) + "\n")


def command_table(source):
    rows = [line.split() for line in
            (source / "scripts/release/commands.txt").read_text().splitlines()]
    entries = [name for row in rows for name in row]
    if (not rows or any(not 1 <= len(row) <= 2 for row in rows)
            or len(entries) != len(set(entries))
            or any(not re.fullmatch(r"ag|silver-[a-z-]+|hardcaml-workbench(?:-[a-z-]+)?", e)
                   for e in entries)
            or ["ag", "hardcaml-workbench"] not in rows):
        raise ValueError("invalid release command table")
    return rows


def audit_elf(path):
    headers = text("readelf", "-hW", path)
    program = text("readelf", "-lW", path)
    dynamic = text("readelf", "-dW", path)
    needed = set(re.findall(r"\(NEEDED\).*?\[([^]]+)\]", dynamic))
    if (not re.search(r"Class:\s+ELF64", headers)
            or not re.search(r"Machine:\s+Advanced Micro Devices X86-64", headers)
            or f"[Requesting program interpreter: {LOADER}]" not in program
            or re.search(r"\((RPATH|RUNPATH)\)", dynamic)
            or not needed or needed - SONAMES):
        raise ValueError(f"{path.name}: unsupported ELF architecture, loader or libraries: {sorted(needed)}")
    return sorted(needed)


def copy_cobalt_notices(repo, commit, dest):
    found = False
    for name in git("ls-tree", "-r", "--name-only", commit, repo=repo).splitlines():
        path = Path(name)
        if (path.name.startswith(("LICENSE", "COPYING"))
                or path.name in {"ASSETS.md", "NOTICES.md", "RUNTIME_AUDIT.md"}):
            out = dest / path
            out.parent.mkdir(parents=True, exist_ok=True)
            with out.open("wb") as dst:
                subprocess.run(["git", "-C", repo, "show", f"{commit}:{name}"], stdout=dst, check=True)
            found = True
    if not found:
        raise ValueError("pinned Cobalt source has no distribution notices")


def copy_opam_notices(opam_prefix, dest):
    for package in sorted((opam_prefix / "doc").glob("*")):
        if not package.is_dir():
            continue
        for notice in sorted(package.iterdir()):
            if notice.name.upper().startswith(("LICENSE", "COPYING", "NOTICE")) and notice.is_file():
                out = dest / package.name / notice.name
                out.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(notice, out)


def stage_payload(source, installed, binary):
    rows = command_table(source)
    installed_bin = installed / "bin"
    expected = {entry for row in rows for entry in row}
    actual = {p.name for p in installed_bin.iterdir()}
    if expected != actual:
        raise ValueError(f"release command table mismatch: missing={expected - actual}; extra={actual - expected}")
    for required in ("META", "dune-package", "silver_provider.cmxa"):
        if not (installed / "lib" / "silver_provider" / required).is_file():
            raise ValueError(f"source installer did not install SDK {required}")
    for relative in (
        "README.md", "install.sh", "scripts/installer-provider.py", "scripts/release/commands.txt",
    ):
        out = binary / relative
        out.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / relative, out)
    shutil.copyfile(source / "scripts/release/BINARY-NOTICE.txt", binary / "BINARY-RELEASE")
    payload = binary / "payload" / "bin"
    payload.mkdir(parents=True)
    needed = {}
    for name, *aliases in rows:
        for alias in aliases:
            if not (installed_bin / alias).samefile(installed_bin / name) and (
                digest(installed_bin / alias) != digest(installed_bin / name)
            ):
                raise ValueError(f"{alias}: source installation differs from {name}")
        out = payload / name
        shutil.copyfile(installed_bin / name, out)
        out.chmod(0o755)
        subprocess.run(["strip", "--strip-debug", out], check=True)
        needed[name] = audit_elf(out)
    return needed


def digest(path):
    with path.open("rb") as f:
        return hashlib.file_digest(f, "sha256").hexdigest()


def package(args):
    # Do not let localized binutils output or Dune's workspace override the build.
    os.environ["LC_ALL"] = "C"
    os.environ.pop("DUNE_WORKSPACE", None)
    source_name, binary_name = names(args.tag)
    assert_platform()
    commit = git("rev-parse", "HEAD")
    if not args.untagged and git("rev-parse", "--verify", f"refs/tags/{args.tag}^{{commit}}") != commit:
        raise ValueError("checked out HEAD is not the version tag's commit")
    epoch = int(git("show", "-s", "--format=%ct", commit))
    output = args.output.resolve()
    output.mkdir(parents=True, exist_ok=True)
    source_asset, binary_asset = (name + ".tar.gz" for name in (source_name, binary_name))
    assets = [source_asset, binary_asset, "SHA256SUMS"]
    if any((output / name).exists() or (output / name).is_symlink() for name in assets):
        raise ValueError(f"release assets already exist in {output}; choose a fresh output directory")

    with tempfile.TemporaryDirectory(prefix=".silver-release-", dir=output) as tmp:
        scratch = Path(tmp)
        source, binary = scratch / source_name, scratch / binary_name
        git_archive(commit, source, scratch)
        toolchain = dict(line.split("=", 1) for line in
                         (source / "scripts/release/toolchain.env").read_text().splitlines()
                         if line and not line.startswith("#"))
        cobalt_commit = toolchain["SILVER_COBALT_COMMIT"]
        if git("rev-parse", "HEAD", repo=args.cobalt_repo) != cobalt_commit or git(
            "status", "--porcelain", "--untracked-files=no", repo=args.cobalt_repo
        ):
            raise ValueError("use a clean Cobalt checkout at the pinned release commit")
        metadata = {
            "schema": 1,
            "project": "Silver",
            "version": args.tag[1:],
            "tag": args.tag,
            "tag_verified": not args.untagged,
            "commit": commit,
            "source_date_epoch": epoch,
            "toolchain_pins": toolchain,
        }
        write_json(source / "RELEASE.json", {**metadata, "kind": "source"})
        archive(source, scratch / source_asset, epoch)

        # Build and test the extracted source asset using the public installer.
        shutil.rmtree(source)
        with tarfile.open(scratch / source_asset) as tar:
            tar.extractall(scratch, filter="data")
        installed = scratch / "source prefix"
        subprocess.run(
            [source / "install.sh", "--without-asic", "--switch", args.switch,
             "--jobs", str(args.jobs), "--prefix", installed],
            cwd=scratch, check=True,
        )
        needed = stage_payload(source, installed, binary)
        copy_cobalt_notices(args.cobalt_repo, cobalt_commit, binary / "notices" / "cobalt")
        opam_prefix = Path(text("opam", "var", f"--switch={args.switch}", "prefix"))
        copy_opam_notices(opam_prefix, binary / "notices" / "opam")
        packages = text("opam", "list", f"--switch={args.switch}", "--installed",
                        "--short", "--columns=name,version")
        (binary / "opam-packages.txt").write_text(packages + "\n")
        write_json(binary / "RELEASE.json", {
            **metadata, "kind": "binary", "platform": TARGET, "elf_needed": needed,
            "ubuntu_runtime_packages": ["libc6", "libgmp10", "zlib1g"],
            "includes_ocaml_sdk": False,
            "redistribution_reviewed": False,
        })
        archive(binary, scratch / binary_asset, epoch)
        (scratch / "SHA256SUMS").write_text(
            "".join(f"{digest(scratch / name)}  {name}\n" for name in (binary_asset, source_asset))
        )
        for name in assets:
            (scratch / name).rename(output / name)
            print(output / name)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--tag", required=True, help="release tag, vMAJOR.MINOR.PATCH")
    parser.add_argument("--untagged", action="store_true", help="locally stage an untagged HEAD for testing")
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--switch", required=True, help="prepared opam switch")
    parser.add_argument("--cobalt-repo", required=True, type=Path, help="clean checkout of the pinned Cobalt source")
    parser.add_argument("--jobs", default=4, type=int)
    args = parser.parse_args()
    if args.jobs < 1:
        parser.error("--jobs must be positive")
    try:
        package(args)
    except (OSError, ValueError, subprocess.CalledProcessError) as e:
        parser.exit(1, f"package.py: {e}\n")


if __name__ == "__main__":
    main()
