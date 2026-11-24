# Terminal baseline captures

Generated files. Do not edit them by hand.

```sh
./scripts/capture-terminal-baseline.sh          # regenerate
./scripts/capture-terminal-baseline.sh --check  # confirm they still match a fresh capture
```

`<scenario>.<width>x<height>.txt` is the character-cell grid with all styling stripped.
`<scenario>.<width>x<height>.ansi` is the same frame with the terminal escape sequences
the client would actually emit.

The scenario names and dimensions come from the capture script. These outputs
check terminal layout and presentation; they do not establish provider behavior
or ASIC result correctness.
