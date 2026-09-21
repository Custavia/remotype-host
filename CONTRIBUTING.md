# Contributing

Thanks for looking. A few things that keep this codebase trustworthy:

## Ground rules

- **The specs are normative.** Anything that changes what goes over the wire
  starts as a change to [`docs/RT1.md`](docs/RT1.md) or
  [`docs/PROTOCOL.md`](docs/PROTOCOL.md) and, for RT1, to the vectors in
  `spec/rt1/` — then the implementations follow. Four implementations only
  agree if they are all measured against the same numbers.
- **The host never talks to the internet.** A change that adds an outbound
  connection of any kind will not be merged.
- **No secrets, ever.** No API keys, certificates, team identifiers or private
  keys in the tree. The `.gitignore` covers the obvious; please look anyway.
- **Every platform builds from a clean checkout** with the commands in the
  README. Debug builds must not require an Apple account or a signing identity.

## Making a change

1. Open an issue first for anything beyond a small fix, so the design can be
   discussed before the code exists.
2. Keep pull requests focused. Include the "why" in the commit message —
   comments in this codebase explain intent and the failure that motivated a
   line, not what the line does.
3. Run what applies:
   - macOS: `xcodegen generate && xcodebuild -scheme RemotypeHost -configuration Debug build`
   - Windows / Linux: `go vet ./... && go build ./...` (cross-compiling is fine)
   - RT1: `python3 spec/rt1/verify_vectors.py`, and `spec/rt1/interop_host.py`
     against a running host if you touched the trust layer.
4. Say how you tested on real hardware. Injection paths cannot be proven in a
   simulator, and the notes in each host's README record what has and has not
   been validated on devices.

## Style

- Swift: follow the surrounding code; no new dependencies without discussion.
- Go: `gofmt`, `go vet`, standard library first.
- Prose in comments and docs: full sentences, present tense, no filler.
