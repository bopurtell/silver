---
id: WB-070
title: Ctrl-Backspace word deletion in the palette and text inputs
category: workspaces
feature_sets: [FS5]
status: closed
kind: defect
priority: P2
severity: S3
requested_size: Unspecified
size: XS
points: 2
confidence: high
estimate_scope: incremental
origin: owner-intake
tags: [palette, input, keyboard]
depends_on: []
related: [WB-014, WB-067]
---

# WB-070 — Ctrl-Backspace word deletion in the palette and text inputs

## Request
Owner note, 2026-10-20: Ctrl+Backspace should work in the command palette.

## Current baseline
The Waveforms Signals filter already deletes a word on Ctrl-Backspace or Ctrl-W
(`Waveform_view.edit_key` / `delete_word`). It handles the encodings the native
decoder actually delivers (^H, ^W, Ctrl/Meta+Backspace). The command palette and the
other text inputs — Timing filter, inspector filter, simulation launch form,
synthesis filter — offer only Backspace and Ctrl-U.

## Scope
- Move the waveform word-deletion helper to a shared module and use it in the
  palette query and every other single-line text input.
- Mention `Ctrl-BS/Ctrl-W word` in each input's help line where it fits.

## Out of scope
Cursor movement inside inputs, Alt-word motions and configurable bindings (WB-014).

## Acceptance criteria
- [x] Ctrl-Backspace and Ctrl-W delete the previous word in the palette and all listed inputs.
- [x] Plain Backspace still deletes one code point; non-ASCII text is never split.
- [x] Terminals that send plain DEL for Ctrl-Backspace still have Ctrl-W.
- [x] Existing waveform filter tests keep passing against the shared helper.

## Dependencies
None.

## Estimate rationale
2 points, high confidence: the helper and its decoder tests already exist.

## Assumptions and decisions needed
None beyond confirming the input list.

## References
- [Word deletion helper](../../../terminal/waveform_view.ml)
- [Palette controls](../../frontend_composition.md)

## Delivery notes — 2026-11-05

Implementation was merged in PR #8. The owner requested closure on 2026-11-15;
the acceptance checklist is closed on that basis and the automated evidence below.

- Extracted the waveform helper into `terminal/text_edit.ml`, including native
  decoder handling for Ctrl-Backspace, Ctrl-W, and Meta-Backspace. Plain DEL remains
  single-code-point Backspace, with Ctrl-W available when a terminal cannot encode
  Ctrl-Backspace distinctly.
- Reused deletion in palette queries and argument forms (including simulation
  launch), synthesis/resource/hierarchy/catalog/log filters, inspector filters, and
  the shared Timing filter. Input help now mentions `Ctrl-BS/Ctrl-W word`.
- Preserved waveform word boundaries: ASCII alphanumeric/underscore and non-ASCII
  text form words; trailing ASCII separators are skipped before deleting a word.
  UTF-8 code points are not split. Backspace removes a code point, not an entire
  grapheme cluster. Paste guards and local editing behavior are retained.
- Waveform edits only extract/reuse the text helper; cursor behavior is outside this
  delivery and remains owned by the separate waveform session.

### Verification

Passed using `scripts/with-switch.sh` with builds limited to `-j 10`:

- `dune build -j 10 terminal/main.exe terminal/terminal_presentation.cma`
- `dune runtest -j 10 terminal`, including existing waveform tests and new native
  decoding, Unicode, palette/form, focused-filter and paste-isolation regressions.
- Focused `ocamlformat --check` and `git diff --check`.

Repository-wide `@fmt` did not pass because of formatting differences outside the
focused formatted files. At implementation verification, physical-terminal
gesture/help review and owner acceptance were pending. The owner's subsequent
closure request does not claim additional terminal testing was recorded.
