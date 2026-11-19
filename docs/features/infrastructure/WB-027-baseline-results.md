# WB-027 — Synthetic baseline results

## Scope and provenance

Accepted evidence: `/tmp/opencode/workbench-performance-p8o3ek31/result.json`,
SHA-256 `a1cfa91b52e6c1b7d576a12a8305a355b5ecd712021cbcb3283d253bf7748fb3`.
This report retains all 16 latency distributions per cell, resource ranges and
fixture/binary/harness identities so the baseline remains useful after `/tmp`
expires. Raw traces and individual observations remain in that temporary tree.

**24/24 trials passed; 384/384 measurements successful; zero failures or
timeouts.** Eight cells: 256/1024 rows × 1/24 workspace timing tiles ×
local/synthetic-slow, three independent trials per cell. Cleanup audits recorded
all owned processes stopped and no cleanup errors in every trial. “Passed” is
the harness outcome, **not a performance acceptance claim**: this is an entirely
synthetic workload on a shared host, without an agreed SLO or confidence bounds.

Baseline supplied by the run owner: committed `oxcaml` revision `2b42815`;
binaries built beforehand with:

```sh
scripts/with-switch.sh dune build -j 3 daemon/main.exe terminal/main.exe
```

Command run from `/home/wayne/devel/jane/performance-baseline`:

```sh
python3 -B scripts/measure-workbench-performance.py --daemon _build/default/daemon/main.exe --client _build/default/terminal/main.exe --rows 256,1024 --tiles 1,24 --samples 3 --slow-delay 1 --budget 600
```

Defaults retained in evidence: 256 padding bytes per row, 200×60 direct PTY,
30 s operation timeout, 2 s standalone Escape timeout, 20 ms publication polling,
600 s overall budget. Trials ran serially in fresh private project/state/home/
config/cache/tmp directories. Private synthetic Dune metadata and a read-only,
allowlisted Python provider were used; no real project build, EDA or physical flow
was part of the measured workload. Fixture seeding is synthetic too.

Environment recorded at invocation:

- Linux `6.8.0-147-generic`, x86_64, glibc 2.39; Python 3.12.3
  (GCC 13.3.0, build Aug 31 2026).
- AMD Ryzen Threadripper PRO 5955WX 16-Cores, microcode `0xa00820d`;
  32 logical CPUs, affinity 0–31; no dedicated-core isolation recorded.
- Host load averages (1/5/15 min): 2.5498046875 / 3.51806640625 / 3.1474609375.
- `/proc/meminfo`: total 32,700,776 kB, available 21,989,556 kB,
  swap total 8,388,604 kB (invocation samples, not workload consumption).
- Evidence filesystem: 4,096-byte blocks/fragments, 735,092,801,536 available
  bytes. This is `statvfs` capacity, not device/cache-topology identification.
- Timing clock: `monotonic_ns`, reported resolution 1 ns.

## Latency results

Every entry below is **median / p95 in milliseconds**, rounded to 0.001 ms;
**n=3 for every metric in every cell**. Percentiles use nearest rank on successful
observations: with three samples p95 is simply the observed maximum, not a
reliable tail estimate. `L` = local (0 s provider pre-read sleep), `S` =
synthetic-slow (1 s pre-read sleep). These labels do not identify different disks.

Cold means empty Workbench caches, **not** evicted OS page caches. Cold index
loading made exactly one provider read and checked exact source digest/row count
in every trial; warm L1 loading returned an identical index without another read.
After a new daemon instance, L2 loading returned the identical saved payload with
`cached_unverified=true`, without provider calls; workspace restoration was also
identical. Loading timers span HTTP dispatch through observed publication,
including polling, transfer, parsing and logging, rather than just file I/O.
Tiles are created after cold/warm loading, before restart and PTY probes; the
tile column therefore does not imply cold/warm loading happened under tile load.

| Rows | Tiles | Mode | Index cold | Index warm L1 | Index restart L2 |
| ---: | ---: | :---: | ---: | ---: | ---: |
| 256 | 1 | L | 192.152 / 203.251 | 48.185 / 49.601 | 38.389 / 71.389 |
| 256 | 1 | S | 1195.711 / 1201.497 | 53.669 / 56.312 | 37.694 / 40.697 |
| 256 | 24 | L | 195.840 / 200.719 | 51.353 / 61.189 | 86.080 / 87.495 |
| 256 | 24 | S | 1201.154 / 1207.103 | 52.063 / 54.190 | 72.052 / 87.136 |
| 1024 | 1 | L | 327.458 / 399.717 | 167.711 / 212.554 | 122.561 / 166.746 |
| 1024 | 1 | S | 1350.174 / 1354.640 | 185.620 / 194.609 | 142.852 / 143.635 |
| 1024 | 24 | L | 341.133 / 359.856 | 175.471 / 180.477 | 141.712 / 141.864 |
| 1024 | 24 | S | 1356.655 / 1359.455 | 182.630 / 193.318 | 145.712 / 152.507 |

PTY input is a raw/noecho palette query (`WB027_NO_MATCH`) written to the real
terminal client and observed in reconstructed terminal output, not a local echo.
Escape is timed separately until the selected WB027 workspace is visible. This
is a host-visible upper bound, not physical display/compositor latency or
inspector row filtering/detail latency. The selected workspace had exactly 1/24
timing tiles; including built-ins there were 3/26 total tiles. At 200×60 the
24-tile geometry need not put every tile fully on screen simultaneously.

| Rows | Tiles | Mode | Idle input→visible | Stalled input→visible | Idle Escape→workspace | Stalled Escape→workspace |
| ---: | ---: | :---: | ---: | ---: | ---: | ---: |
| 256 | 1 | L | 12.746 / 16.522 | 15.551 / 17.667 | 4.745 / 5.488 | 4.955 / 5.786 |
| 256 | 1 | S | 15.077 / 15.568 | 14.951 / 15.891 | 4.475 / 7.715 | 2.277 / 3.825 |
| 256 | 24 | L | 34.251 / 34.757 | 23.007 / 27.354 | 23.697 / 28.944 | 8.484 / 12.465 |
| 256 | 24 | S | 24.330 / 25.685 | 30.096 / 34.152 | 13.378 / 13.425 | 8.399 / 10.357 |
| 1024 | 1 | L | 13.745 / 18.303 | 17.015 / 17.877 | 6.196 / 6.305 | 4.798 / 5.109 |
| 1024 | 1 | S | 13.870 / 14.572 | 19.273 / 23.203 | 5.114 / 5.256 | 6.212 / 12.336 |
| 1024 | 24 | L | 23.167 / 35.793 | 25.850 / 35.922 | 14.290 / 16.611 | 14.527 / 35.103 |
| 1024 | 24 | S | 24.822 / 33.103 | 24.136 / 34.410 | 16.602 / 34.894 | 14.357 / 26.907 |

For **both** L and S, a separate refresh injects a **15 s provider pre-read
hold** for the stalled PTY/query/cancel probes. The harness verified that this
read had entered the provider and remained pending at cancellation. Query values
are HTTP POST round trips including response decoding, without CLI launch cost.
Cancel acknowledgement is transport completion; terminal-state latency starts
before Cancel dispatch and ends at the observed failed operation with a
cancellation error, including acknowledgement and polling. It is not a client
screen-update or complete process-cleanup latency.

| Rows | Tiles | Mode | Refresh dispatch ack | Get during hold | Cancel ack | Cancel→terminal state |
| ---: | ---: | :---: | ---: | ---: | ---: | ---: |
| 256 | 1 | L | 16.733 / 16.942 | 22.708 / 23.131 | 14.198 / 21.836 | 31.365 / 37.652 |
| 256 | 1 | S | 14.145 / 16.321 | 9.991 / 15.466 | 12.558 / 15.875 | 27.007 / 29.973 |
| 256 | 24 | L | 16.483 / 17.368 | 20.661 / 22.827 | 21.110 / 22.976 | 38.665 / 41.503 |
| 256 | 24 | S | 16.568 / 17.232 | 20.239 / 22.330 | 16.557 / 22.562 | 40.524 / 65.498 |
| 1024 | 1 | L | 57.531 / 69.508 | 42.577 / 47.857 | 48.719 / 49.290 | 115.955 / 125.700 |
| 1024 | 1 | S | 59.340 / 61.989 | 46.210 / 51.768 | 43.811 / 46.816 | 103.528 / 107.123 |
| 1024 | 24 | L | 57.415 / 57.423 | 41.797 / 43.358 | 63.534 / 66.089 | 107.563 / 110.629 |
| 1024 | 24 | S | 41.165 / 51.745 | 42.457 / 48.645 | 63.773 / 70.681 | 104.575 / 118.916 |

Remaining five metrics complete the 16-metric inventory (8 × 3 × 16 = 384).
No summary was preloaded at registration in any trial. Warm summary loading made
no extra report call; restarted L2 summaries had `Cached_unverified` freshness,
otherwise identical payloads, and no provider calls.

| Rows | Tiles | Mode | Daemon cold start/open | Daemon restart/open | Summary first explicit | Summary warm | Summary restart L2 |
| ---: | ---: | :---: | ---: | ---: | ---: | ---: | ---: |
| 256 | 1 | L | 61.923 / 74.052 | 60.299 / 60.959 | 427.531 / 445.459 | 6.599 / 6.677 | 2.393 / 2.816 |
| 256 | 1 | S | 61.047 / 61.841 | 60.039 / 60.883 | 430.386 / 432.732 | 6.436 / 6.978 | 2.698 / 2.845 |
| 256 | 24 | L | 59.804 / 60.867 | 60.711 / 62.077 | 430.131 / 433.454 | 5.691 / 6.447 | 2.726 / 3.360 |
| 256 | 24 | S | 61.356 / 64.389 | 61.508 / 63.770 | 427.239 / 429.757 | 6.020 / 6.529 | 2.714 / 2.773 |
| 1024 | 1 | L | 64.805 / 78.538 | 59.649 / 83.253 | 519.655 / 560.673 | 3.796 / 6.086 | 3.241 / 3.583 |
| 1024 | 1 | S | 60.182 / 61.270 | 60.297 / 62.634 | 427.730 / 432.098 | 6.681 / 6.720 | 2.925 / 3.432 |
| 1024 | 24 | L | 59.136 / 60.595 | 60.239 / 60.855 | 427.848 / 429.449 | 6.483 / 6.814 | 2.925 / 3.245 |
| 1024 | 24 | S | 60.213 / 62.180 | 60.857 / 61.139 | 428.238 / 454.888 | 6.293 / 6.346 | 2.804 / 3.397 |

## Resource samples

Memory ranges pool all 24 trials **within each named phase**; values are MiB
(2²⁰ bytes), min–max, rounded to 0.001. Each table row has 24 process samples.
Linux `/proc` RSS/PSS are point samples, not process-tree totals or sampled
peaks. HWM is the individual process lifetime high-water mark at that checkpoint;
restart resets the daemon lifetime. Provider and harness memory are not included.
The client was started only after L2 loading, so earlier phases have no client
sample. OCaml allocation/GC counts were unavailable in these binaries.

| Phase | Process | RSS | VmHWM | PSS |
| --- | --- | ---: | ---: | ---: |
| Opened empty | daemon | 52.230–52.926 | 52.230–52.926 | 49.860–50.510 |
| Cold + warm loaded | daemon | 60.984–78.531 | 60.984–78.531 | 58.564–76.043 |
| Tiles created | daemon | 61.125–78.672 | 61.125–78.672 | 58.757–76.184 |
| Restart L2 loaded | daemon | 58.945–77.430 | 58.945–77.430 | 56.500–75.076 |
| Client tiles rendered, after idle probe | daemon | 60.027–75.910 | 60.027–77.035 | 57.560–73.549 |
| Client tiles rendered, after idle probe | client | 82.934–89.984 | 82.934–90.203 | 80.651–87.615 |
| Cancelled, before shutdown | daemon | 61.238–76.863 | 61.238–77.664 | 58.808–74.486 |
| Cancelled, before shutdown | client | 84.008–91.598 | 84.008–91.598 | 81.699–89.227 |

Disk ranges below are exact **logical / allocated bytes**, min–max across 24
trials. Regular files only; allocated = `st_blocks × 512`, excluding directory
allocation. State is Workbench persistence; fixture is the whole seeded `results`
tree, not just the measured timing JSON. “Whole trial” includes state, fixture,
logs, PTY captures and harness files; it is **not additive** to state/fixture and
is not a pure instrumentation-overhead estimate.

| Phase | State logical / allocated | Whole trial logical / allocated |
| --- | ---: | ---: |
| Opened empty | 0 / 0 | 632816–1251163 / 851968–1466368 |
| Cold + warm loaded | 155474–603365 / 159744–610304 | 811584–1900286 / 1040384–2125824 |
| Tiles created | 157038–608669 / 163840–618496 | 815514–1922048 / 1044480–2150400 |
| Restart L2 loaded | 157038–608669 / 163840–618496 | 820036–1927047 / 1056768–2162688 |
| Client tiles rendered, after idle probe | 159839–611470 / 167936–618496 | 1063633–2228834 / 1331200–2494464 |
| Cancelled, before shutdown | 159839–611470 / 167936–618496 | 1151226–2333932 / 1425408–2605056 |
| After shutdown | 159839–611470 / 167936–618496 | 1174028–2357225 / 1454080–2633728 |

Fixture tree at every phase and after shutdown: **72 files**, logical
628646–1246812 bytes, allocated 806912–1421312 bytes. State file counts by phase:
1, 4, 5, 5, 5, 5, 5; whole-trial counts: 85, 90, 91, 94, 105, 107, 108.
The report's final root census recorded 2,618 files, 43,248,739 logical and
49,979,392 allocated bytes. That census precedes the final aggregate `result.json`
rewrite; it is not an exact post-write filesystem inventory.

## Instrumentation and interpretation

- Clock-pair calibration (n=100): min/median/p95/max =
  0.000090 / 0.000090 / 0.000120 / 0.000662 ms.
- Harness-process `/proc` probe calibration (n=10): min/median/p95/max =
  0.371304 / 0.469444 / 1.049037 / 1.049037 ms. Resource checkpoints are outside
  the measured actions; their activity can still perturb subsequent work.
- Publication polling is 20 ms; PTY select waits up to 10 ms. No fixed post-key
  sleep is included in input timers. No overhead was subtracted.
- HTTP/JSON/S-expression parsing, ANSI reconstruction, file logging and fixture
  Python startup remain included where on the timed path. Their individual costs
  were not calibrated; there was no paired uninstrumented run.

Observed findings: the injected 1 s sleep is reflected in cold index loading,
while L1/L2 reuse avoids provider reads. Larger row payloads still cost time on
cache hits (warm medians about 48–54 ms at 256 rows versus 168–186 ms at 1024),
so these results do not equate a cache hit with negligible end-to-end work.
The 24-tile cells show higher palette-input medians than the 1-tile cells;
stalled-input p95 values remain 15.891–35.922 ms across cells. Get-during-hold
medians are 9.991–46.210 ms; cancellation terminal-state medians are
27.007–115.955 ms. These are descriptive observations, not causal scaling fits
or responsiveness guarantees.

All evidence, rows, provider behavior, metadata and stalls are synthetic. There
is no physical slow device, remote-host test, OS-cold storage test, device I/O
latency attribution, process-tree peak-memory measurement, physical display
measurement, real user-session representativeness, DUT timing/area/power result,
or real physical-flow execution here. Inspection payloads beyond the production
2 MiB cap were not tested (harness enforces a conservative 1500 KiB row budget).
Serial, fixed-order n=3 cells on a shared host cannot establish tail confidence,
isolate host drift, or satisfy WB-044 acceptance by themselves.

## Retained identities (SHA-256)

Trial directories are named `rows-{rows}-tiles-{tiles}-{local|synthetic-slow}-{00|01|02}`
under the evidence root. Each contains `fixture-identity.json`; measured evidence
is `results/synthetic-reference/inspection-timing-signoff.json`, with execution
metadata at `results/synthetic-reference/execution.json`. The reference stream
ID is `synthetic-reference`; finalization is
`results/synthetic-reference/finalizations/synthetic-collection-synthetic-reference`.
All 24 execution and evidence files were hash-checked against their identity
records during this report's read-only analysis.

| Rows | Trials sharing exact evidence | Padding bytes/row | Evidence bytes | Evidence SHA-256 |
| ---: | ---: | ---: | ---: | --- |
| 256 | 12 | 256 | 204717 | `2217b018032e480919017cc6179fc1b88c7d373498792b94b27fa4b2d371fbd1` |
| 1024 | 12 | 256 | 819055 | `94b357c80dd7fb293aa2da5d6cdfdc7be1929d5a720914e41d13dd0fefa0701f` |

Rows have unique `wb027-path-%06d` IDs, category `timing_path`, producer
`SYNTHETIC.wb027`, synthetic endpoints/startpoints and 256 `x` padding characters
in each source JSON. The byte counts above are the full pretty-printed evidence
files, not just padding or rows in memory. Execution metadata includes private
paths, so execution identities differ per trial:

| Trial directory | Execution bytes | Execution SHA-256 |
| --- | ---: | --- |
| rows-256-tiles-1-local-00 | 3801 | `c84e63f161998fe8fe58fcdb950a9a508f14153d4d92465381ae558c1d7a412a` |
| rows-256-tiles-1-local-01 | 3801 | `5f160823fba9df9a8074ad5cbd01daffda06d3284f24671044235dd303820b78` |
| rows-256-tiles-1-local-02 | 3801 | `299f672b3c6a0628c3239fd73fc1634aa2629909e1975b05091987c34c91b8e1` |
| rows-256-tiles-1-synthetic-slow-00 | 3873 | `55f3bd4e252154bf5d3f48116c8f45ee362d157986ecc96fffd1931118f103e2` |
| rows-256-tiles-1-synthetic-slow-01 | 3873 | `2d6eb059316859a3a826b680e830cda1db8febc4bac702e23cba9c8089f33967` |
| rows-256-tiles-1-synthetic-slow-02 | 3873 | `ea28d1414d67edeaa36d725903ab58e6b6ca04797e69597bb65035d2a15c2a62` |
| rows-256-tiles-24-local-00 | 3809 | `426188fd3c2732c887d185a1b6a54dc4ea3caa544a4266f01d9b7c9c13c35c4f` |
| rows-256-tiles-24-local-01 | 3809 | `f1dc5a024753888fc14dc6697104a7d2a348bbc976e847597645a821d5683e57` |
| rows-256-tiles-24-local-02 | 3809 | `1d27bf55f3a3f5ce90e14c310e1e8a07eedefbdb44af3ba43ab3476bf3e558ca` |
| rows-256-tiles-24-synthetic-slow-00 | 3881 | `703ce096d026a00375edec470fe02bcf94b96d6b02653ef5e515589c9cd0558f` |
| rows-256-tiles-24-synthetic-slow-01 | 3881 | `f8a9622d5d628d28edbcaceeb654a0a59eec359649d8884b645b795bea66c901` |
| rows-256-tiles-24-synthetic-slow-02 | 3881 | `3b878acc75777dca582e3952d0c3934eee010e2d02fee79d5c34d07c16b1ab90` |
| rows-1024-tiles-1-local-00 | 3809 | `8c14a2a235d4912f115c6cd4b657475db593c3a95a9ccff5577ba94762c74ff2` |
| rows-1024-tiles-1-local-01 | 3809 | `03b787944a69a808e14c04f71d0c064f3ac109b6b1d7250f85da9343a3764ff7` |
| rows-1024-tiles-1-local-02 | 3809 | `383168294d0d33779e868bcc3123cae2c846c1994d7fb675b7783790f3ff8c2e` |
| rows-1024-tiles-1-synthetic-slow-00 | 3881 | `138dca7befddeffc87c9c6e1e87f008e85d55ef8958fb35452da381ea494b8b9` |
| rows-1024-tiles-1-synthetic-slow-01 | 3881 | `f7ebf8408d1dfaa124a19315a3f1d3e9ad4c00fe60277d3790e1ad4f4e2910cc` |
| rows-1024-tiles-1-synthetic-slow-02 | 3881 | `e72808dbab80fee9ed7e189d722b9b62d7dd712f9b2486732413bb45c007108b` |
| rows-1024-tiles-24-local-00 | 3817 | `ec7f38d8d4ed6fe8926c514befbb7123c47a69c7c3f89ffeae8bcecae704f105` |
| rows-1024-tiles-24-local-01 | 3817 | `b604cb50378267cebf00b8ecf6d260b31b085bb923d35cffd92581c049593c36` |
| rows-1024-tiles-24-local-02 | 3817 | `9145e2af9ce675ec8c1aa16d2fc668a8b031e258b34226f1e11fc55499a5230b` |
| rows-1024-tiles-24-synthetic-slow-00 | 3889 | `e2bc808d7f820d9bc619de1a6f910c619f50fe52e45865fe6906efdd972c5772` |
| rows-1024-tiles-24-synthetic-slow-01 | 3889 | `b4513c58efc2c6bb417aed9e4593b3730d139b20491d67d4d91584948252b43d` |
| rows-1024-tiles-24-synthetic-slow-02 | 3889 | `5af3d758cba0133d955ec40caf01812d5793aeafb6cf7809abaefbb4a2d9a403` |

Binary and harness identities below are recorded by the accepted run (paths
relative to `/home/wayne/devel/jane/performance-baseline`):

| File | SHA-256 |
| --- | --- |
| `_build/default/daemon/main.exe` | `d8f08e4de5c19aaa764566d4c9894b2bb7c94b534151cff7b16a0cdd940e4a4c` |
| `_build/default/terminal/main.exe` | `cf6815f3f6a78f85d4f42fbc33661fca26a6ca85e5c517a0228e24bb7a1b85e3` |
| `scripts/measure-workbench-performance.py` | `55b669f665f850b31916177209cc77f22225ecf844cb22418635598b7a60e10a` |
| `demo/synthetic_flow/provider.py` | `f152c1c087b52e99190df3b47b86b18bb8910b745dca2349b384d879097084e7` |
| `demo/synthetic_flow/scenarios.json` | `8d9a458db140c84c4461ff21fabbd7d520e792a9137461509ddc127cae717a1f` |
| `demo/synthetic_flow/http_client.py` | `2b43247a85b89c7b3cd007c5844d53d7405e5f13ea18bde9747681cf6cc9c3a6` |
| `scripts/test-inspector-latency.py` | `02c586c8e92ab4e0e57cb9190642a38331a320e72fbd4fd42c57ebedda3d1b85` |
| `scripts/test-fs1-investigation.py` | `44132125b29b2a53f233cf5e77a62bbf413e8a471418ccd24b3a7b327b5b7501` |
| `scripts/test-fs1-lifecycle.py` | `065a5b4472dfad0bc092a8cdf59c7ad57c12ee833f811ba71d8c257e164edf08` |
| `scripts/test-fs1-terminal-results.py` | `ba681ac69881b8c07beab823b4fd959338da4bc59b58db56cb42aab2efdb22f7` |
| `scripts/test-fs1-metrics.py` | `e26224ce3c7092ff2dd583984403ef5adda4cc14f655ef878dc04b2f47b9368d` |
| `scripts/test-fs0-dashboard.py` | `529ca6aff0d622277628fa3ef17c1701ff2a84d5ce5ebc91dd424f8129b3c7f0` |
| `scripts/test-fs0.py` | `1385826cb8d4254c4b177a7f653c397a50c4d86c44c66783c317b5f7abeb32f5` |
