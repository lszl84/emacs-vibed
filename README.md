# emacs-vibed: smooth pixel scrolling for PGTK Emacs on HiDPI Wayland

Patches for GNU Emacs' pure-GTK (PGTK, `--with-pgtk`) Wayland backend that make
touchpad scrolling with `pixel-scroll-precision-mode` smooth on large, high-resolution
screens (4K at scale 2). Without them, scrolling runs at about 7–17 frames per second
there, and scrolling **up** lags up to a third of a second behind your fingers.

Related upstream reports: [bug#72960](https://debbugs.gnu.org/72960) (PGTK Wayland
lags more than X11), [bug#71591](https://debbugs.gnu.org/71591) (input lag with display
scaling), [bug#59134](https://debbugs.gnu.org/59134) (pixel scroll precision is CPU
intensive). The patches have not been sent upstream.

## Results

Laptop with an Intel i5-8365U and UHD 620 graphics, Hyprland, 3840x2160 panel at scale 2.
The test uses a synthetic touchpad sending 170 events per second, and an Org file with
`org-indent-mode` and larger headings.

| Frame | Build | frames/s scrolling down / up | keeps scrolling after you stop |
|---|---|---|---|
| full screen | unpatched | 17 / 7 | up to 320 ms |
| full screen | patched, `pgtk-pace-scroll-events` t | **28 / 27** | 10–31 ms |
| half width (tiled) | unpatched | 33 / 11 | up to 185 ms |
| half width (tiled) | patched, `pgtk-pace-scroll-events` t | **45 / 40** | ≤22 ms |

Mouse-wheel scrolling (with interpolation) goes from 27 to 35–37 frames/s. Rendering is
pixel-identical to the unpatched build. [NOTES.md](NOTES.md) has every measurement,
the profiles, and the correctness checks.

## What was wrong, and what the patches change

PGTK draws into a private cairo image surface (the "back buffer") and copies it into GTK's
buffer whenever GTK redraws the widget. At 3840x2160 a full copy is ~32 MB. Profiling
showed most of the time went to these copies, plus one Lisp command and one redisplay
per touchpad event. All changes are in `src/pgtkterm.c` and `src/pgtkterm.h`, ~330
lines in total.

1. **Copy only what changed**
   (`0001-Copy-only-the-damaged-part-of-the-back-buffer-to-the.patch`).
   After every redisplay PGTK called `gtk_widget_queue_draw`, so GTK cleared, repainted
   and composited the whole frame even for a cursor blink. Now `pgtk_end_cr_clip` records
   the clip area of each drawing operation as damage, and flips call
   `gtk_widget_queue_draw_region` with only that area. Drawing without a clip counts as
   the whole frame, so a missed case costs speed, never correctness.

2. **Copy instead of blend**
   (`0002-Copy-the-back-buffer-to-the-screen-instead-of-compos.patch`).
   `pgtk_handle_draw` painted the back buffer with cairo's default OVER operator, which
   blends every pixel. The buffer is opaque, or with `alpha-background` the window is
   already clear underneath, so `CAIRO_OPERATOR_SOURCE` gives the same pixels as a plain
   copy.

3. **Scroll in place**
   (`0003-Scroll-the-back-buffer-in-place-on-PGTK.patch`).
   `pgtk_copy_bits`, used by redisplay to scroll a window's contents, copied the area into
   a temporary surface and back: two near-full-screen copies per scroll step. It now
   `memmove`s the rows inside the image surface. The old code remains as a fallback for
   anything that isn't a plain 32-bit image surface.

4. **Pace touchpad scroll events to the display**
   (`0004-Optionally-pace-pixel-scroll-events-to-redisplay-on-.patch`), **opt-in**.
   A touchpad sends ~170 events per second. Emacs handled each with its own command and
   redisplay, so at 4K the events queued up. Up is worse because its command is slower.
   When the new variable **`pgtk-pace-scroll-events`** is non-nil, pixel scroll events
   that arrive before the previous one has been redisplayed and drawn by GTK are merged
   into one event (deltas summed). Emacs then redisplays once per frame GTK draws, and
   stops as soon as you stop. Events are never reordered: any other event (key, click,
   end of the scroll gesture) lets a held scroll event through first. A 50 ms timeout
   releases a held event if the frame is never drawn. It only affects the pixel scroll
   events of `pixel-scroll-precision-mode`, i.e. when `mwheel-coalesce-scroll-events` is
   nil.

**What's left** at 4K full screen is mostly GTK 3 itself: before Emacs copies its frame,
GDK clears the region and GtkWindow paints its CSS background, together ~8 ms per
frame. Plus Emacs' own redisplay layout, ~7 ms. [NOTES.md](NOTES.md) lists the ideas
not implemented.

## Building Emacs with the patches

These patches are against the `emacs-31` branch at commit
`b4fdff95b3e686130bd376b4eb43bb719280a4a3` (2026-09-26). They were also checked to apply
with `git am` on the branch tip as of that date. They only touch the PGTK backend; X11,
Cairo-on-X11 and terminal builds are unaffected.

### 1. Dependencies

On **Arch Linux**, installing `emacs-wayland` pulls in the runtime libraries. You also
need the build tools:

```bash
sudo pacman -S --needed base-devel git autoconf texinfo \
  gtk3 cairo harfbuzz libgccjit tree-sitter gnutls libxml2 giflib libwebp librsvg
```

On **Debian/Ubuntu**, `sudo apt build-dep emacs` (with deb-src enabled) plus
`libgtk-3-dev` covers it. Other distributions: install the development packages for
GTK 3, cairo, harfbuzz, gnutls, libxml2 and tree-sitter, plus autoconf, make, a C
compiler and texinfo.

### 2. Get the source and apply the patches

```bash
git clone https://github.com/lszl84/emacs-vibed.git
git clone --branch emacs-31 https://git.savannah.gnu.org/git/emacs.git
# mirror if savannah is slow: https://github.com/emacs-mirror/emacs.git
cd emacs
git checkout -b vibed b4fdff95b3e686130bd376b4eb43bb719280a4a3
git am ../emacs-vibed/patches/*.patch        # needs git user.name/user.email set
git log --oneline -5                          # the 4 patch commits on top of b4fdff9
```

Without git: `patch -p1 < ../emacs-vibed/patches/000N-*.patch` for N = 1..4, in order.

### 3. Configure and build

```bash
./autogen.sh
./configure --with-pgtk --with-cairo --with-harfbuzz --with-modules --with-tree-sitter \
            --with-native-compilation=aot          # or =no for a much faster build
make -j"$(nproc)"
```

Add `--prefix=...` if you plan to install. The results above were measured with
`--with-native-compilation=no CFLAGS='-O2 -g3 -fno-omit-frame-pointer'`. Native
compilation doesn't affect this display code.

### 4. Run it (without installing)

```bash
src/emacs --eval '(progn (pixel-scroll-precision-mode 1) (setq pgtk-pace-scroll-events t))' FILE
```

This runs as an ordinary GUI Emacs with your normal config, next to any installed Emacs
or running daemon, as long as your config doesn't call `server-start`. Use `-Q` to
leave your config out. `M-: (setq pgtk-pace-scroll-events nil)` switches patch 4 off at
run time, for comparison.

To use it permanently, `sudo make install` (or build a distro package from this tree)
and add this to your `init.el`:

```elisp
(pixel-scroll-precision-mode 1)
(when (boundp 'pgtk-pace-scroll-events)
  (setq pgtk-pace-scroll-events t))
```

## Repository layout

| Path | What |
|---|---|
| `patches/` | The 4 patches (`git format-patch`, GNU ChangeLog-style messages, NEWS entry). |
| `NOTES.md` | Base commit, method, all measurements (per patch), profiles, correctness checks, known pre-existing bugs, ideas not done. |
| `CLAUDE.md` | The original task brief: machine, constraints, source analysis, plan. |
| `tools/instrumentation.diff` | **Measurement-only** Emacs changes, applied on top of the patches: timings, a draw/event timeline `(vibed-stats)`, and a synthetic touchpad `(vibed-inject-scroll RATE SEGS)`. Not for daily use. |
| `tools/run-bench.sh` | Benchmark: launches an instrumented Emacs on Hyprland workspace 9, scrolls, prints frames/s, lag, CPU and per-operation times. |
| `tools/check-garbage.sh` | Correctness: after ~25 actions, compares a screenshot with one taken after `redraw-frame`, to catch stale pixels. |
| `tools/measure.el`, `bench.el`, `scroll-log.el` | Lisp side of the benchmarks; per-step timing; real-touchpad event log. |
| `tools/vscroll/` | Wayland virtual-pointer client for moving the pointer and scrolling. |
| `tools/ptraceable.c`, `tools/prof-report.py` | Sampling profiler without root (`prctl(PR_SET_PTRACER)` + `eu-stack`). |

## Notes for agents working on this

- Measure before and after every change, and compare against an **unpatched build with
  the same configure flags**, not against a distro Emacs. The instrumented "before" tree
  is the base commit plus `tools/instrumentation.diff`; that diff is against the
  *patched* tree, so for an unpatched tree apply only its instrumentation hunks.
- The scripts assume Hyprland (`hyprctl`, Lua dispatch syntax such as
  `hl.dsp.focus({ workspace = "9" })`), plus `grim`, `jq`, ImageMagick and `wtype`.
  Build `vscroll` with:
  ```bash
  cd tools/vscroll && cc -O2 -o vscroll vscroll.c wlr-virtual-pointer-unstable-v1-protocol.c -lwayland-client -lm
  ```
- **Hyprland turns virtual-pointer scrolling into mouse-wheel clicks**, so
  `pixel-scroll-precision` takes the mouse interpolation path. To reproduce a touchpad,
  use the in-Emacs injector (`VIBED_INJECT=1 tools/run-bench.sh ...`).
- `check-garbage.sh` has 2 known failures that also happen unpatched: the visible-bell
  flash stays until the next redisplay, and the tool bar's Undo button updates late.
  Anything else is a regression.
- Emacs' commit-msg hook (installed by `autogen.sh`) enforces the CONTRIBUTE format: first
  line ≤ 68 characters, and files named in the ChangeLog must be in the diff.
- Upstreaming: changes over ~15 lines need an FSF copyright assignment from the author.
  New variables and NEWS entries belong on `master`, not a release branch.
