# Agent notes

This repository holds patches for GNU Emacs' PGTK (pure GTK, Wayland) backend that make
`pixel-scroll-precision-mode` smooth on high-resolution screens, plus the tools used to
measure them. Nothing here is built directly: the patches apply to an Emacs source tree.

- Start with [README.md](README.md) (what, why, how to build; see "Notes for agents").
- [NOTES.md](NOTES.md) has the design, all measurements and the correctness checks.
- [docs/task-brief.md](docs/task-brief.md) is the original task brief and source
  analysis. Its machine-specific rules applied to the author's setup, not to yours.

Rules of thumb:
- Measure before and after every change, against an unpatched build with the same
  configure flags (`tools/run-bench.sh`), and run `tools/check-garbage.sh` for stale
  pixels.
- Keep patches minimal and in GNU style (see `CONTRIBUTE` in the Emacs tree); one commit
  per logical change, regenerated with `git format-patch` into `patches/`. If you change
  a patch, update `arch/PKGBUILD` checksums (`updpkgsums`).
