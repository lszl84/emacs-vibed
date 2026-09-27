# emacs-vibed: engineering notes

Design, measurements and correctness checks behind the patches. For what they do and how
to build them, see [README.md](README.md). The original task brief and source analysis
are in [docs/task-brief.md](docs/task-brief.md).

## Base

- Source: `emacs-31` branch, GitHub mirror, commit
  `b4fdff95b3e686130bd376b4eb43bb719280a4a3` (2026-09-26, "; Fix last change").
- Configure (all trees): `--with-pgtk --with-cairo --with-harfbuzz --with-modules
  --with-tree-sitter --with-native-compilation=no CFLAGS='-O2 -g3 -fno-omit-frame-pointer'`.
- Measurement setup: three source trees built with the flags above.
  - "base": the base commit plus `tools/instrumentation.diff`'s instrumentation only
    (the "before" build).
  - "patched": the base commit plus the 4 patches plus the instrumentation (all
    measurements below).
  - "clean": the base commit plus the 4 patches only (for trying it out and for the
    compiler-warning check).
- Patches: `patches/0001..0005` (`git format-patch` of the clean tree). All scrolling
  measurements below were taken with patches 1–4; patch 5 (overlay scroll bars) came
  later and doesn't touch the scrolling path.
- Test machine: ThinkPad X1 Carbon 7th gen, Intel i5-8365U with UHD 620 graphics, 16 GB
  RAM, Arch Linux (Omarchy) with Hyprland 0.56, built-in 3840x2160 panel at scale 2.

## The patches

| # | Commit | Lines | What |
|---|---|---|---|
| 1 | Copy only the damaged part of the back buffer to the screen (step A) | +74 -3 | Damage tracking. `pgtk_end_cr_clip` records the clip extents of every drawing operation. Unclipped callers count as the whole frame, so a missed rectangle over-draws but never leaves stale pixels. `pgtk_fill_rectangle`, `pgtk_draw_rectangle` and `pgtk_clear_area` now clip to what they draw. Flips then `gtk_widget_queue_draw_region` only the damage. Flips to a new back buffer and the visible bell still redraw everything. |
| 2 | Copy the back buffer to the screen instead of compositing it | +18 | `pgtk_handle_draw` paints the image back buffer with `CAIRO_OPERATOR_SOURCE`, clipped to its size, instead of OVER, inside `cairo_save`/`cairo_restore`, since GTK goes on to draw the scroll bars with the same `cairo_t`; the scroll bars are pixel-identical to the unpatched build. The result is the same: the buffer is opaque, or, with `alpha-background`, the window is app-paintable and clear. It's a blit instead of a per-pixel blend. Not in the original A/B/C plan; kept separate so it can be dropped. |
| 3 | Scroll the back buffer in place (step B) | +70 | `pgtk_copy_bits` `memmove`s rows inside the image surface (device-scale aware, correct row order for overlap, `cairo_surface_mark_dirty_rectangle`) instead of copying through a temporary surface. Falls back to the old code for non-image surfaces, other formats, non-integral device coordinates or out-of-bounds rects. Verified at runtime: the back buffer is `CAIRO_SURFACE_TYPE_IMAGE`. |
| 4 | Optionally pace pixel scroll events to redisplay (step C) | +168 -2 | New variable **`pgtk-pace-scroll-events`** (default nil, opt-in because it changes how many events Lisp sees). When non-nil, pixel scroll events (the `(nil DX DY)` wheel events of `pixel-scroll-precision-mode`) that arrive before the previous one has been redisplayed and drawn by GTK are merged into one event (deltas summed), so Emacs runs one command and one redisplay per frame GTK draws. Details below. Includes a NEWS entry. |
| 5 | Add optional overlay scroll bars | +280 | New variable **`pgtk-overlay-scroll-bars`** (default nil). Vertical scroll bars take no room and float over the window's text in GTK's overlay style, shown while scrolling or when the pointer is near. Details below. |

Total +330/-5 lines in `src/pgtkterm.c`, `src/pgtkterm.h`, `etc/NEWS`. No warnings with
the git-checkout warning flags (`-Wall -Wextra ...`).

### How step C works

- The pending pixel scroll event stays in pgtk's own event queue (`event_q`, which
  `mark_pgtkterm` already protects from GC). `evq_flush` leaves the *last* event in the
  queue if it is a pixel scroll event and its frame is still busy with the previous
  one. New pixel scroll events for the same frame, device and modifiers are merged into
  it. Any other event (key, button, the touch-end "scroll stop") arrives after it, so
  both are flushed in order. Nothing is ever reordered.
- Per frame, `scroll_pending` tracks the last released event: `REDISPLAY` (handed to
  Emacs), then `DRAW` (redisplay queued damage, `pgtk_queue_draw_damage`), then `NONE`
  (`pgtk_handle_draw` drew it; `raise (SIGIO)` so Emacs reads the held event). If the
  redisplay drew nothing, it is released right away.
- Fallback: a 50 ms GLib timeout releases a held event, e.g. if the frame isn't visible
  or redisplay didn't touch it. It never fired in the tests, including hundreds of no-op
  scrolls at the top of the buffer.
- Why not simply sync drawing to GTK's frame clock: GTK already paints at most once per
  frame-clock tick. The waste was on the Emacs side: one command plus one
  redisplay per touchpad event (170/s), and two redisplays per drawn frame. See
  "Findings".
- Two attempts that failed, for the record: holding events while `redisplaying_p` and
  raising SIGIO to re-check made Emacs spin inside redisplay (some loop in redisplay
  polls input). Releasing on *any* draw let the draw of the *previous* redisplay release
  the next event too early; hence the 3-state flag.

### How patch 5 (overlay scroll bars) works

- **No room.** With the variable set, `pgtk_set_scroll_bar_default_width` makes the frame's
  default scroll bar width 0 (and `pgtk_new_font` reserves 0 columns), so every layout
  macro (`WINDOW_SCROLL_BAR_AREA_WIDTH` etc.) collapses without touching generic code,
  while `WINDOW_HAS_VERTICAL_SCROLL_BAR` stays true so redisplay keeps calling
  `set_vertical_scroll_bar`. A variable watcher removes all scroll bars (condemn + judge)
  and resets each frame's `scroll-bar-width` parameter to nil, so switching takes
  effect at once in every frame, and redisplay recreates the bars in the new style.
- **Over the text.** `pgtk_set_vertical_scroll_bar` places the bar at
  `WINDOW_BOX_RIGHT_EDGE_X - width` (theme width) and skips the `pgtk_clear_area` calls;
  `xg_update_scrollbar_pos` skips clearing the old position, `gdk_window_lower` and
  `SET_FRAME_GARBAGED` for overlay bars (the back buffer is always complete, so GTK just
  redraws what the bar uncovers).
- **Look.** The event box gets no window of its own (`gtk_event_box_set_visible_window
  (FALSE)`) and no background; the scrollbar gets the `overlay-indicator` style class,
  plus `hovering`/`dragging` while hovered or dragged, which the theme (Adwaita is built
  into libgtk-3) styles as the thin indicator / wider slider of `GtkScrolledWindow`. The
  arrow cursor isn't set, as it would go on the frame's window.
- **Showing and hiding.** Shown when the thumb's value or range changes (the window
  scrolled), and from `motion_notify_event` when the pointer is within 24 px of the bar
  (`window_from_coordinates`). One second after the last activity it fades out in 10
  steps of 20 ms (`gtk_widget_set_opacity`) and is then hidden, so it doesn't take clicks
  meant for the text. Not while hovered or dragged. State per bar lives in GObject data
  on the widget, freed with it.
- **Tested:** screenshots of every state; `check-garbage.sh` with overlay bars on and
  `VIBED_SETTLE=1.8` (so the indicator has faded before the screenshot); dragging the
  slider with a virtual pointer scrolls the window; layout width 1864 → 1880 px; the
  `scroll-bar` face color reaches the slider.
- **Gotcha:** configs that disable scroll bars (Omarchy does, via `scroll-bar-mode -1`
  and `default-frame-alist`) need `(scroll-bar-mode 1)` after that, or there is nothing
  to overlay.

## Trying it without installing

A patched build runs as an ordinary GUI Emacs next to an installed one or a running
daemon (as long as your config doesn't call `server-start`).

```bash
# patched
emacs-patched/src/emacs -Q --eval '(progn (pixel-scroll-precision-mode 1) (setq pgtk-pace-scroll-events t))' FILE &
# unpatched build of the same source and flags, for comparison
emacs-base/src/emacs -Q --eval '(pixel-scroll-precision-mode 1)' FILE &
```

`M-: (setq pgtk-pace-scroll-events nil)` switches patch 4 off at run time. Patches 1–3
are always on.

## Measuring tools (all in `tools/`)

- **`tools/instrumentation.diff`** (applies on top of the patches, not for daily use): counters
  and timings for update, `pgtk_copy_bits`, `pgtk_handle_draw`; a timeline (scroll event
  from GTK, update begin, flip, draw, frame-clock phases) returned by `(vibed-stats)`; and
  **`(vibed-inject-scroll RATE SEGS)`**, a synthetic touchpad (see below).
- `run-bench.sh TREE LABEL [FILE] [SEGS...]`: starts `TREE/src/emacs -Q` on workspace 9
  with `etc/ORG-NEWS` (`org-indent-mode`, headings 1.4/1.25/1.1 height,
  `pixel-scroll-precision-mode`, 64 MB GC threshold), scrolls, and prints presents/s per
  segment, present intervals, lag after each segment stops, CPU and per-operation times.
  Env: `VIBED_INJECT=1` (synthetic touchpad), `VIBED_HALF=1` (half-width tiled frame),
  `VIBED_MOUSE=1` (keep mouse interpolation), `VIBED_EXTRA_EVAL`, `VIBED_PROFILE=file`.
- `measure.el`: the Lisp side of that.
- `check-garbage.sh TREE`: correctness. After each action, screenshot the window
  (`grim`), `redraw-frame`, screenshot again, diff with ImageMagick. Any difference means
  stale pixels were left on screen. 25–29 actions; see "Correctness". `VIBED_DAEMON=1`
  runs it as `--fg-daemon` + `emacsclient -c`; `VIBED_MOVE_TO`/`VIBED_MOVE_BACK` move the
  frame between outputs.
- `vscroll/`: a `zwlr_virtual_pointer_v1` client for pointer motion and scrolling.
- `ptraceable` + `prof-report.py`: poor man's profiler. `perf` isn't installed (needs
  root) and `ptrace_scope` is 1, so Emacs is started through a wrapper that calls
  `prctl(PR_SET_PTRACER, ANY)`, and `eu-stack` samples it.

### Surprises about measuring

- **Hyprland turns virtual-pointer scrolling into mouse-wheel clicks.** It drops the
  axis source and accumulates the values: GTK sees `axis_source 0` (wheel), value 0 on 7 of
  8 events and `15.0` + `axis_discrete 1` on the 8th, from the "Wayland Wheel Scrolling"
  device (Emacs class `mouse`). So `vscroll` gives ~21 wheel clicks/s, not a touchpad
  stream, and `pixel-scroll-precision` takes the *interpolation* path for it. The first
  numbers taken were of that path. `/dev/uinput` needs root, so the real touchpad is emulated
  **inside Emacs**: a GLib timeout queues GDK smooth-scroll events with
  `gdk_display_put_event` at 170 Hz, catching up in bursts when Emacs was busy, like
  events piling up in the Wayland socket. It reproduces what was seen with the real touchpad (via
  `tools/scroll-log.el`): ~170 events/s, one command per event, and most events arriving
  while Emacs is still busy.
- GTK has no touchpad slave device here; injected events come from "Core Pointer"
  (class `core-pointer`), which takes the same non-interpolating path as a touchpad.

## Findings (before the patches)

Profile of the unpatched build while scrolling continuously (wheel path, 4K full-screen
frame): **63% of the main thread in GTK's frame paint**. Of the samples: `sse2_fill` 33%
(GDK clearing the paint region + GtkWindow's CSS background), `sse2_composite_over_8888`
31% (our OVER paint in `pgtk_handle_draw`), `sse2_blt` 16% (`pgtk_copy_bits` through the
temporary surface). Glyph drawing and layout were small.

Timeline of one scroll cycle, unpatched, synthetic touchpad: GTK hands over the queued
events, then Emacs runs **one command per event** (~8 per cycle, 1–2.5 ms each, ~5 ms
each when scrolling up), redisplays, sometimes runs another command and redisplays
*again* before GTK draws, then GTK draws (clear + CSS background + our 7.9 ms paint).
Scrolling up is slow because the up command costs ~5 ms of Lisp: at 170 events/s that
alone saturates Emacs, so events pile up and the view lags 200–300 ms behind the fingers.

The compositor is not the bottleneck: commit → `wl_callback.done` is ~6 ms, and shm
buffers are released ~5 ms after commit.

## Results

Scroll segments: 3 s down, 3 s up (10 px per event), 2 s down, 2 s up (25 px per event),
170 events/s, 2.5 s pauses. "Presents/s" = `pgtk_handle_draw` calls per second while
scrolling. "Lag" = how long Emacs kept scrolling after the fingers stopped (backlog).
Two runs each, both shown where they differ.

### Synthetic touchpad, full-screen frame on eDP-1 (1896x1026 logical = 3792x2052 px)

| Build | presents/s d10 / u10 / d25 / u25 | present interval median / p90 | lag after stop (ms) | commands |
|---|---|---|---|---|
| base | 17.5 / 7.5 / 17.7 / 6.9 ; 16.8 / 7.6 / 17.7 / 7.5 | 59–60 / 249–288 ms | 30, 206, 30, 317 ; 35, 161, 38, 274 | 1700 |
| + A (damage) | 17.1 / 8.3 / 18.2 / 7.8 ; 17.1 / 8.3 / 18.6 / 7.3 | 58 / 199–217 ms | 36–48, 137–142, 32–48, 185–200 | 1700 |
| + SOURCE paint | 17.5 / 8.3 / 18.1 / 7.3 ; 17.3 / 7.9 / 18.7 / 7.2 | 58 / 249–283 ms | 34–57, 144–178, 27–43, 202–211 | 1700 |
| + B (in-place scroll) | 20.8 / 9.9 / 21.7 / 8.3 ; 21.2 / 9.2 / 22.1 / 8.7 | 48–49 / 140–165 ms | 24–31, 133–141, 26–36, 164–181 | 1700 |
| + C, `pgtk-pace-scroll-events` nil | 21.5 / 9.5 / 22.0 / 7.7 ; 21.1 / 9.3 / 21.5 / 8.2 | 48–49 / 158–174 ms | 20–33, 132–145, 45–48, 206–216 | 1700 |
| **+ C, `pgtk-pace-scroll-events` t** | **28.8 / 27.1 / 28.3 / 26.6 ; 29.8 / 26.4 / 29.0 / 27.4** | **35.5 / 40 ms** | **16–18, 24–29, 11–31, 10–31** | 283 |

Per-operation averages (ms): `pgtk_handle_draw` 7.9 (base, area 1.79 M logical px²) →
5.5 (A, 1.46 M) → 4.65 (SOURCE) → 5.8 paced (1.58 M; more scrolled per frame).
`pgtk_copy_bits` 9.8 (base) → 3.7 (B). Update (glyph drawing incl. copy) 8.5 → 4.2.

### Synthetic touchpad, half-width tiled frame (typical tiling-WM layout)

| Build | presents/s d10 / u10 / d25 / u25 | interval median / p90 | lag after stop (ms) |
|---|---|---|---|
| base | 32.8 / 11.3 / 30.5 / 10.5 | 32 / 131 ms | 19, 97, 32, 185 |
| **all patches, paced** | **45.6 / 39.4 / 44.3 / 39.8** | **23.5 / 27.6 ms** | **7, 22, 9, 10** |

### Mouse wheel (Hyprland wheel clicks, interpolation on), full screen

| Build | presents/s per segment | interval median | lag after stop (ms) |
|---|---|---|---|
| base | 26.8 / 25.5 / 27.5 / 27.4 | 41.4 ms | 21, 19, 147, 150 |
| all patches, paced | 34.9 / 34.2 / 36.8 / 37.0 | 33.1 ms | 5, 11, 12, (−51) |

### `tools/bench.el` (per step, Lisp + `(redisplay t)`, full screen)

| | down median / p90 | up median / p90 | jumps |
|---|---|---|---|
| base | 16.8 / 20.1 ms | 20.9 / 26.9 ms | 0/80, 0/80 |
| patched | 9.6 / 11.6 ms | 13.8 / 15.9 ms | 0/80, 0/80 |

### Where the time goes now (paced, full screen, ~35 ms per frame)

Timeline: command ~1 ms, redisplay layout ~7 ms, update ~10 ms (6 ms of it the in-place
`memmove` of ~30 MB), frame clock → our draw handler 8.3 ms (GDK clearing the paint
region + GtkWindow painting its CSS background under our widget), our paint ~5.6 ms.
The frame clock itself starts painting 0.3 ms after the flip.

Profile (paced): GDK clear 33%, our paint 25%, GtkWindow CSS background 22%, Lisp 7.5%,
memmove 6%. So **more than half of what's left is GTK 3 filling the 4K buffer twice per
frame before Emacs copies into it.** All of that is memory bandwidth on the UHD 620 laptop.

## Correctness

`check-garbage.sh` (screenshot vs forced full redraw) passes on: initial display; wheel
scroll down/up/jiggle; synthetic touchpad down→up and fast reversals; `C-v`/`M-v`; split
windows (below + right, same buffer) and scrolling the top and bottom ones;
`display-line-numbers-mode` + `hl-line-mode` with both scroll kinds; region highlight
on/off; minibuffer quit; fullscreen / unfullscreen and scrolling while fullscreen;
scrolling with `pixel-scroll-precision-mode` off; mouse-face hover on an org link (and its
tooltip frame renders); `blink-cursor-mode` off for determinism.

Run in all of these configurations, with pacing on:
- plain GUI on eDP-1 (scale 2)
- daemon (`--fg-daemon=<private name>`) + `emacsclient -c`
- a temporary headless Hyprland output at **scale 1**
- moving the frame scale 1 → 2 → 1 and scrolling after each move (checked sharp at 2x)

Also:
- with `alpha-background` 60 (garbage check; plus a screenshot identical to the unpatched
  build, pixel for pixel)
- with the author's full personal config (Omarchy theme; via `--init-directory`): it
  loads without warnings, and a screenshot is identical to the unpatched build
- the GTK scroll bar is identical to the unpatched build (patch 2 no longer leaks cairo
  state to it)

The only failures are identical on the unpatched build, so they're pre-existing:
- **visible bell**: the flash stays on screen until the next redisplay (pgtk bug:
  `recover_from_visible_bell` doesn't queue a redraw).
- **minibuffer**: the tool bar's Undo button changes state later (GTK widget, not ours).
- (daemon run with a folded buffer) scrolling past the end of the buffer, then a full
  redisplay picks a new window start.

Not covered automatically: real touchpad hands, `visible-bell` beyond the above, images
(ORG-NEWS has none) and child frames other than tooltips.

## Ideas not implemented

1. **Skip GtkWindow's CSS background under the Emacs widget** (~22% of the remaining
   frame time at 4K, ~4 ms/frame). Make the toplevel app-paintable (pgtk already does that
   for `alpha-background`), and paint the theme background only outside the frame widget
   from a `draw` handler on the toplevel. Risk: client-side decorations on GNOME-like
   compositors (not Hyprland) would lose their shadow, and the menu/tool bar backgrounds
   need care.
2. **Default `pgtk-pace-scroll-events` to t.** It only merges events that Emacs would
   otherwise process late, but it is opt-in because Lisp then sees fewer, larger wheel
   events; an upstream default would be up to the Emacs maintainers.
3. GDK's clear of the paint region can't be avoided in GTK 3, and redisplay layout
   (~7 ms/frame) is Emacs core.

## Upstreaming

Not submitted yet. The natural place is bug#72960. Notes for whoever submits:

- The changes are ~330 lines, so the author needs an **FSF copyright assignment** before
  they can be accepted.
- New features (the variable and its NEWS entry) belong on `master`, not on the
  `emacs-31` release branch; the NEWS entry currently sits in the 31.2 section.
- The commit messages follow CONTRIBUTE (the Emacs commit-msg hook accepts them) and
  carry a `Co-Authored-By: Claude` trailer, since the patches were written with Claude
  Code.
