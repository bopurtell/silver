"""Renderer test double for the service/CLI transport tests."""
import json
import sys


def flow_fixture():
    command = sys.argv[1]
    if command == "describe-flow-authoring":
        print(json.dumps({"schema_version": 1, "recipes": [
            {"id": "librelane_classic_v1", "endpoints": ["synthesis"]}]}))
        return True
    if command not in ("render-flow", "render-profile"):
        return False
    p = json.loads(sys.argv[2])
    assert p["owner"] == "asic_second"
    entry, = p["catalog"]["declaration"]["entries"]
    assert entry["methodology"]["id"] == "standard"
    if command == "render-profile":
        source, = entry["profiles"]
        assert p["source_profile"] == source["id"]
        explicit = {a["key"]: a["value"] for a in source["assignments"]}
        assert explicit == {"buffer": False}
        assert p["edits"] == {"buffer": True}
        path = "standard/profiles/" + p["profile_id"] + ".ml"
    else:
        assert p["recipe"] == "librelane_classic_v1" and p["endpoints"] == ["synthesis"]
        path = "flow_" + p["flow_id"] + ".ml"
    files = [{"path": "asic_second/flows/" + path, "contents": "(* fixture *)\n"}]
    print(json.dumps(dict(schema_version=1, provider="fixture", version="1",
                          manual_registration=not p["registered"], snippet="declaration",
                          files=files if p["registered"] else [])))
    return True


if __name__ == "__main__" and flow_fixture():
    sys.exit(0)
