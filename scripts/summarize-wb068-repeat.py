#!/usr/bin/env python3
"""Print a compact durable comparison from retained WB-068 result.json files.

Reads only; does not build or launch clients. Accepts the original baseline schema
and the mode-aware probe schema. Paths are relative to the checkout so moving the
checkout preserves evidence references; historical absolute paths inside original
raw evidence remain unchanged. All latency values are host-observed upper bounds.
"""
import argparse
import json
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent


def summarize(path, mode):
    result = json.loads(path.read_text())
    if result['status'] != 'completed':
        raise ValueError('Incomplete evidence: ' + str(path))
    if result.get('step_mode', 'baseline') != mode:
        raise ValueError('Wrong step mode: ' + str(path))
    cases = []
    all_holds = []
    for case in result['cases']:
        holds = case['holds']
        all_holds.extend(holds)
        prefix = 'tick' if mode == 'baseline' else 'step'
        correlated = prefix + '_correlated_header_'
        latency_medians = [h[correlated + 'median_ms'] for h in holds]
        final_positions_match = all(
            h['final'] == h['expected_final'] if 'expected_final' in h else
            h['final']['tick'] == h['initial']['tick'] +
            (1 if h['key'].lower() == 'l' else -1) * h['sent'] for h in holds)
        cases.append(dict(
            fixture=case['fixture'], zoom=case['zoom'], scale=holds[0]['initial']['scale'],
            single_samples=case['summary']['samples'],
            single_header_median_ms=round(case['summary']['single_header_median_ms'], 3),
            single_header_max_ms=round(case['summary']['single_header_max_ms'], 3),
            same_column_single_moves=case['summary']['same_column'],
            held_header_median_range_ms=[round(min(latency_medians), 3), round(max(latency_medians), 3)],
            held_header_max_ms=round(max(h[correlated + 'max_ms'] for h in holds), 3),
            observed_step_headers=sum(h[correlated + 'observations'] for h in holds),
            sent_steps=sum(h['sent'] for h in holds),
            holds=len(holds), final_positions_match=final_positions_match,
            release_tail_max_ms=round(max(h['last_cursor_change_after_release_ms'] for h in holds), 3),
            holds_with_post_release_cursor_changes=sum(h['post_release_observed_changes'] > 0 for h in holds),
            censored_drains=sum(h['drain_censored'] for h in holds)))
    return dict(
        raw_evidence=str(path.parent.relative_to(ROOT)),
        binary_sha256={k: v['sha256'] for k, v in result['binaries'].items()},
        viewport=result['viewport'],
        fixtures={c['fixture']: c['metadata'] for c in result['cases']},
        total_holds=len(all_holds),
        max_sender_lateness_ms=round(max(h['max_sender_lateness_ms'] for h in all_holds), 3),
        cases=cases)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--column', type=Path, required=True)
    parser.add_argument('--tick', type=Path, required=True)
    parser.add_argument('--check-record', type=Path,
                        help='Validate the compact durable record against raw evidence instead of printing JSON')
    args = parser.parse_args()
    report = dict(
        ticket='WB-068', schema_version=1,
        settings=dict(single_samples_per_direction=8, hold_seconds=2, rates_hz=[30, 120],
                      after_release_tail_limit_ms=50, post_release_observation_min_ms=1000,
                      cursor_stability_required_ms=500, initial_selected_buses=8),
        limitations=[
            'Host PTY input-to-header upper bounds, not isolated render CPU or physical display frame timings.',
            'Columns inferred from the displayed integer raster; leftward holds include automatic panning.',
            'Periodic output-byte activity is not cursor backlog; last-output metrics are excluded.',
            'Expected-sequence correlation uses actual per-step grid and pan mapping; skipped headers are missing observations.',
            'The 50 ms diagnostic release threshold allows scheduling noise and is not a one-display-frame proof.',
            'Original baseline binary was built before implementation; baseline raw evidence was relocated without rewriting historical absolute paths.',
            'Synthetic 8-bit traces, one viewport, and default eight selected buses; no tmux or physical keyboard transport.',
        ])
    for mode in ('baseline', 'column', 'tick'):
        path = getattr(args, mode).resolve(strict=True)
        report[mode] = summarize(path, mode)
    if args.check_record:
        record = json.loads(args.check_record.read_text())
        for mode, key in [('baseline', 'baseline_h_l'), ('column', 'after_column_h_l'), ('tick', 'after_tick_H_L')]:
            measured = report[mode]
            retained = record[key]
            rows = [[c['fixture'], c['zoom'], c['single_header_median_ms'], c['single_header_max_ms'],
                     c['same_column_single_moves'], *c['held_header_median_range_ms'], c['held_header_max_ms'],
                     c['observed_step_headers'], c['release_tail_max_ms']] for c in measured['cases']]
            if rows != retained['cases'] or measured['total_holds'] != retained['holds']:
                raise ValueError('Durable case metrics differ: ' + mode)
            if not all(c['final_positions_match'] and c['censored_drains'] == 0 for c in measured['cases']):
                raise ValueError('Unexpected final position or censored drain: ' + mode)
            if sum(c['holds_with_post_release_cursor_changes'] for c in measured['cases']) != retained['holds_with_post_release_cursor_changes']:
                raise ValueError('Durable release counts differ: ' + mode)
            if record['raw_evidence'][mode] != measured['raw_evidence']:
                raise ValueError('Durable evidence path differs: ' + mode)
            hash_key = 'baseline_client' if mode == 'baseline' else 'after_client'
            if record['binary_sha256'][hash_key] != measured['binary_sha256']['client']:
                raise ValueError('Durable client digest differs: ' + mode)
            if record['binary_sha256']['daemon_both'] != measured['binary_sha256']['daemon']:
                raise ValueError('Durable daemon digest differs: ' + mode)
            for name, fixture in measured['fixtures'].items():
                if fixture['sha256'] != record['fixtures'][name]['sha256']:
                    raise ValueError('Durable fixture digest differs: ' + name)
        print('PASS: durable WB-068 metrics, final positions, release counts, paths and digests match raw evidence')
        return
    print(json.dumps(report, indent=2))


if __name__ == '__main__':
    main()
