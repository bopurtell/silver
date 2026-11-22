"""Exercise real Dune build and source emission through a private daemon."""

import json
import os
from pathlib import Path
import re
import selectors
import stat
import subprocess
import sys
import tempfile
import time
from urllib.error import HTTPError
from urllib.request import Request, urlopen


def rpc(endpoint, path, body=None):
    request = Request(
        endpoint + path,
        data=None if body is None else body.encode(),
        headers={"Content-Type": "application/sexp", "X-Workbench-Protocol": "1"},
    )
    try:
        with urlopen(request, timeout=3) as response:
            return response.read().decode()
    except HTTPError as error:
        raise AssertionError((body, error.read().decode())) from error


def exercise(daemon, fixture, *, explicit):
    fixture.mkdir()
    project = fixture / "project"
    project.mkdir()
    (project / "dune-project").write_text("(lang dune 3.22)\n")
    (project / "dune").write_text(
        """(rule
 (target project.exe)
 (action
  (run sh -c "printf '#!/bin/sh\\n#%s\\nprintf \\"%%s\\" \\"$TMPDIR\\" > emit-tmp\\nexit 2\\n' \\"$TMPDIR\\" > project.exe; chmod +x project.exe")))
"""
    )
    (project / "hardcaml-workbench-preparation.sexp").write_text(
        f'((schema_version 1)(build_target project.exe)'
        f'(results_root {json.dumps(str(fixture / "results"))})(timeout_seconds 20))'
    )
    env = dict(os.environ, XDG_CACHE_HOME=str(fixture / "cache"))
    runtime = fixture / "cache" / "silver-runtime"
    (fixture / "discovery").mkdir(mode=0o700)
    if explicit:
        scratch = fixture / "chosen-tmp"
        scratch.mkdir()
        env["TMPDIR"] = str(scratch)
    else:
        env.pop("TMPDIR", None)
    with subprocess.Popen(
        [daemon, "--state-dir", str(fixture / "state"), "--discovery-dir",
         str(fixture / "discovery")],
        text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, env=env,
    ) as proc:
        try:
            with selectors.DefaultSelector() as events:
                events.register(proc.stdout, selectors.EVENT_READ)
                assert events.select(8), "no daemon readiness message"
            ready = proc.stdout.readline()
            if not ready and proc.poll() is not None:
                raise AssertionError(proc.stderr.read())
            assert ready.startswith("silver-daemon listening on "), ready
            endpoint = ready.split()[-1]
            if explicit:
                assert not runtime.exists()
                (log_dir,) = scratch.glob("*logs")
            else:
                (session,) = runtime.iterdir()
                scratch = session / "tmp"
                log_dir = session / "logs"
                for path in [runtime, session, scratch, log_dir]:
                    assert stat.S_IMODE(path.stat().st_mode) == 0o700, path
            hello = rpc(endpoint, "/api/hello")
            instance = re.search(r"\(instance_id ([^)]+)\)", hello)[1]
            opened = rpc(
                endpoint, "/api/v1/open-project",
                f"((instance_id {instance})(root {json.dumps(str(project))})"
                "(environment Inherit_daemon))",
            )
            project_id = re.search(r"\(id ([^()]+-project-\d+)\)", opened)[1]
            scope = f"(instance_id {instance})(project {project_id})"
            request = (
                f"({scope}(operation(Prepare(submission_key test-temp)"
                "(selection((flow example)(profile default)(endpoint synthesis)"
                "(assignments())(chip_target())))(expected_plan_identity()))))"
            )
            started = rpc(endpoint, "/api/v1/preparation", request)
            assert started.startswith("(Ok"), started
            deadline = time.monotonic() + 12
            while time.monotonic() < deadline:
                status = rpc(endpoint, "/api/v1/preparation", f"({scope}(operation Get))")
                if "(outcome Emission_failed)" in status or "(outcome Build_failed)" in status:
                    break
                time.sleep(0.05)
            assert "(outcome Emission_failed)" in status, status
            build_tmp = (project / "_build/default/project.exe").read_text().splitlines()[1]
            build_tmp = Path(build_tmp.removeprefix("#"))
            assert build_tmp == scratch or build_tmp.is_relative_to(scratch), (build_tmp, scratch)
            assert (project / "emit-tmp").read_text() == str(scratch)
            assert list(log_dir.glob("*.log"))
        finally:
            proc.terminate()
            try:
                _, err = proc.communicate(timeout=8)
            except subprocess.TimeoutExpired:
                proc.kill()
                proc.communicate()
                raise
    assert proc.returncode in (0, -15, 143), err
    assert not log_dir.exists()
    if explicit:
        assert scratch.exists()
    else:
        assert not scratch.parent.exists()


if __name__ == "__main__":
    with tempfile.TemporaryDirectory(prefix="silver-runtime-test-") as tmp:
        fixture = Path(tmp)
        for explicit in [False, True]:
            exercise(str(Path(sys.argv[1]).resolve()), fixture / str(explicit), explicit=explicit)
