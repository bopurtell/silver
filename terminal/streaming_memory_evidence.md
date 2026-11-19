# WB-040 terminal export memory evidence

## Reproduce

From `/home/wayne/devel/jane/bpurtell-feature4`:

```sh
dune build -j 2 --build-dir /tmp/opencode/wb040-memory-build terminal/streaming_memory_probe.exe
python3 terminal/test_streaming_memory.py /tmp/opencode/wb040-memory-build/default/terminal/streaming_memory_probe.exe
```

Requires Linux, Python 3 and GNU `/usr/bin/time`. The runner defaults to three
fresh processes per size; `--repetitions N` changes the sample count. This is an
opt-in measurement rather than a default `runtest` dependency. No forced GC or
heap tuning is applied. Recorded environment: Linux 6.8.0-147-generic x86_64,
OCaml 5.2.0+ox, Dune 3.24.2.

## Scope and verification

The native probe calls actual `Simulation_export.run`, including identity and hex
page validation, then actual `Streaming_export.run`, including incremental writes,
SHA256, bounded disk readback and atomic publication. It does not use the embedded
chunk-accumulation exporter. A synthetic binary trace has byte `offset % 251` at
every position. The source generates only the requested 64 KiB page and its hex
encoding; it never creates a whole trace, page list or source file.

Python independently calculates the declared digest in constant space before
starting the measured child. Each child independently reads the published file
with one 64 KiB buffer, checks every byte, byte count and SHA256, verifies registered
metadata equality and the verified publication suffix, then deletes artifact,
metadata and directory in a finalizer. Python checks page count and result identity
and that its private TMPDIR is empty. A TemporaryDirectory also cleans up on child
failure. All recorded runs passed these checks. No viewer is launched.

GNU time's `%M` records child lifetime peak RSS in KiB, including native runtime,
synthetic-page generation, export and independent validation. Build and Python
digest generation are outside the measurement. Separate processes avoid carrying
over a prior run's heap/high-water mark. Filesystem cache is not a child RSS charge.

## Recorded results

| Sample | 1 MiB: 1,048,576 bytes / 16 pages | 64 MiB: 67,108,864 bytes / 1,024 pages |
| --- | ---: | ---: |
| 1 peak RSS (KiB) | 52,716 | 55,936 |
| 2 peak RSS (KiB) | 52,716 | 55,712 |
| 3 peak RSS (KiB) | 52,972 | 56,088 |

Worst-large minus best-small: **3,372 KiB (3.29 MiB)** for **64,512 KiB (63 MiB)**
additional trace data, approximately 5.23% of payload growth. The regression check
requires growth below 24,576 KiB (24 MiB): generous runtime/GC headroom while still
rejecting retention of the additional 63 MiB. This is an empirical envelope at
the declared maximum, not a proof of asymptotic memory behavior or a portable
absolute RSS ceiling. The source and verification loops themselves are bounded.

Validated SHA256 values:

- 1 MiB: `631b84027d6b9e52b539c4e8373622d23032dfadc64d60af87339c9037e4f769`
- 64 MiB: `98dc891b284e4d84ac25b0c0a24fdbe39a7f0dbd643ad5e8aa06e02fc6258254`

## Backend/provider review and subsequent implementation

- `provider/wire.ml:8-27`: shared simulation limits remain 64 MiB per artifact,
  64 KiB per byte page, 256 MiB artifacts per attempt and 512 MiB history artifacts.
  `protocol/simulation.ml` includes that wire module. The probe explicitly asserts
  that terminal streaming size/page limits match the shared limits.
- `provider/validation.ml:141-178` and `provider/runner.ml:130-197`: provider events
  retain version/attempt/sequence framing, normalized relative artifact paths,
  duplicate artifact rejection, artifact count caps and event-stream bounds.
  The provider declaration does not supply the authoritative size/digest; the
  backend derives those from captured bytes (`backend/simulation_service.ml:437-480`).
- `backend/simulation_service.ml:766-834`: byte requests fence the registered
  artifact's digest, bound offset/limit, check current bytes against registered
  size/digest and check attempt eviction after asynchronous IO. Responses retain
  attempt/artifact/hash/offset/total/EOF identity. Terminal validation checks these
  fields again and final streaming verification checks the full digest.
- The initial review found whole-file allocation in capture and page serving.
  Subsequent implementation uses `backend/artifact_file.ml` with a 64 KiB scan
  buffer, incremental capture and bounded requested-page storage. Backend tests
  check under 2 MiB OCaml allocation for maximum-size page/capture operations.
  Every page still rehashes the entire artifact: at 64 MiB / 64 KiB this is 1,024
  passes, roughly 64 GiB logical hashing/read work. The RSS probe measures the
  terminal exporter, not the HTTP/backend process or end-to-end latency.
- ASIC identity remains fenced by exact listed reference, run, terminal attempt,
  digest, offset and page limit (`backend/asic_artifacts.ml:367-405` and
  `terminal/artifact_binary_export.ml:48-92`). Its external export cap stays 16 MiB,
  below the shared streaming core's 64 MiB. ASIC byte reads now use the bounded
  scanner too. Catalog listing and text viewing retain their bounded whole-file
  allocation; they are not measured by this probe.
- The streaming core additionally caps exports at 4,096 fetches, metadata at 64 KiB,
  timeout at 120 seconds, and one active export. A maximum-size artifact succeeds
  with full pages (1,024 calls); sufficiently short valid pages can exhaust the
  page budget. Published exports are retained in normal use with no automatic
  pruning; probe output is explicitly removed. These are additional policies,
  not increases in protocol size limits.

## Probe files

- `terminal/streaming_memory_probe.ml`: actual exporter probe.
- `terminal/test_streaming_memory.py`: isolated RSS measurements and regression check.
- `terminal/streaming_memory_evidence.md`: this evidence/handoff report.
- `terminal/dune`: the `streaming_memory_probe` executable stanza.
