"""Independent 1RW memory check for the real development acceptance run."""
import hashlib
import json
from pathlib import Path
import re


def read_json(path):
    return json.loads(path.read_bytes())


def verify_trace(operations, expected, rows, raw, steps):
    """Compare the testbench stimulus and raw edges with a simple memory model."""
    assert len(operations) == len(expected) == len(rows) == len(raw) == len(steps)
    memory, output = {}, None
    reads = writes = defined = 0
    for i, (op, predicted, row, words, step) in enumerate(
        zip(operations, expected, rows, raw, steps, strict=True)
    ):
        assert len(words) == 3 and row['cycle'] == i == int(words[0]) == int(step[0])
        assert row['input'] == op
        assert (step[1] == '1', step[2] == '1', int(step[3]), int(step[4])) == (
            op['enable'], op['write'], op['address'], op['data'] & 255)
        before = output
        if op['enable']:
            if op['write']:
                memory[op['address']] = op['data']
                output = None
                writes += 1
            else:
                output = memory.get(op['address'])
                reads += 1
        assert predicted == {'before': before, 'after': output}
        for phase, value, word in zip(('before', 'after'), (before, output), words[1:], strict=True):
            observed = None if re.search(r'[xz]', word, re.IGNORECASE) else int(word, 16)
            assert row[phase] == observed
            if value is not None:
                assert observed == value
                defined += 1
    return reads, writes, defined


def verify_result(result_path, workbench_attempt, case, generation):
    directory = result_path.parent
    ledger = read_json(directory.parent / 'request.json')
    # The retained provider ledger uses this field for the Workbench attempt.
    assert ledger['fs2_attempt_id'] == workbench_attempt
    assert (ledger['case'], ledger['seed']) == (case, '34097')
    assert Path(ledger['generation']) == generation
    result = read_json(result_path)
    simulation = read_json(directory / result['simulation']['path'])
    assert simulation['attempt_id'] != workbench_attempt
    for ref in [result[k] for k in ('simulation', 'stimulus', 'trace')] + [
        x['source'] for x in simulation['artifacts']
    ]:
        data = (directory / ref['path']).read_bytes()
        assert hashlib.sha256(data).hexdigest() == ref['sha256'] and len(data) == ref['bytes']
    bundle = Path(result['bundle'])
    manifest = read_json(bundle / 'manifest.json')
    assert manifest['identity'] == simulation['bundle_identity']
    for source in manifest['synthesis_sources']:
        assert (bundle / source).read_bytes() == (directory / Path(source).name).read_bytes()
    workload = result['workload']
    rows = read_json(directory / result['trace']['path'])['rows']
    raw = [line.split()[1:] for line in (directory / 'execute/stdout.log').read_text().splitlines()
           if line.startswith('TRACE ')]
    steps = re.findall(r"step\((\d+), 1'b([01]), 1'b([01]), 8'd(\d+), 8'd(\d+)\);",
                       (directory / 'testbench.v').read_text())
    assert len(workload['operations']) == 1307
    assert verify_trace(workload['operations'], workload['expected'], rows, raw, steps) == (
        525, 262, 2083)
    return simulation['attempt_id']
