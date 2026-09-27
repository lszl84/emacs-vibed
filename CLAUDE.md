# emacs-vibed: make pgtk Emacs pixel-scroll smoothly on a 4K Wayland screen

You are working on a patch to GNU Emacs' Wayland (pgtk) display backend. The goal is
**smooth touchpad pixel scrolling (`pixel-scroll-precision-mode`) on a 4K HiDPI panel**.
Read this whole file before doing anything.

## 1. The machine and the user's setup (don't break it)

- Laptop: ThinkPad X1 Yoga 4th / Carbon 7th, Intel i5-8365U, integrated Intel UHD 620
  (i915), 16 GB RAM.
- OS: Omarchy (Arch Linux + Hyprland 0.56, Lua config in `~/.config/hypr/`).
- Screens:
  - `eDP-1`: built-in 3840x2160 panel, **scale 2** (1920x1080 logical). **This is where
    the problem shows.**
  - `DP-2`: Apple Studio Display, running 2560x1440 at scale 1 (above the laptop). DP-1
    is its second 5K tile; leave the monitor config alone.
- Installed Emacs: Arch package `emacs-wayland` 31.1-2 (`/usr/bin/emacs`), a pgtk build.
  Configure options of the installed build:
  `--with-pgtk --with-cairo --with-harfbuzz --with-libsystemd --with-modules
  --with-native-compilation=aot --with-tree-sitter`
- The user's Emacs runs as a **systemd user daemon** (`~/.config/systemd/user/emacs.service`,
  `emacs --fg-daemon`, server name `server`). Frames are opened with
  `~/.local/bin/emacsclient-frame`, which is also `EDITOR`/`VISUAL`.
- User config: `~/.config/emacs/` (`early-init.el`, `init.el`; `omarchy.el` and the
  theme are managed by the `omarchy-emacs` package). `init.el` currently does **not**
  enable `pixel-scroll-precision-mode`; it was removed because it was too janky.

**Rules**
- Do **not** modify, restart or replace the user's running daemon, the installed
  `emacs-wayland` package, `~/.config/emacs/`, or the systemd unit. Build and run your
  own Emacs from this folder only.
- Do **not** `make install` system-wide. Run the built binary from the source tree.
- Test instances must not steal the user's server: run them as a plain GUI Emacs
  (`src/emacs -Q ...`), or as a daemon with a different name (`--daemon=vibed`, then
  `lib-src/emacsclient -s vibed ...`).
- Anything needing root (installing packages): ask the user first. `sudo` needs a
  password; when there's no terminal, use `pkexec`.
- The user wants **minimal, targeted changes**. Don't refactor unrelated code or change
  things they didn't ask for. Suggest extras and wait for a yes.
- Hyprland dispatch on this version uses Lua syntax, e.g.
  `hyprctl dispatch 'hl.dsp.focus({ workspace = "9" })'` and
  `hyprctl dispatch 'hl.dsp.window.close({ window = "address:0x..." })'`.
  The old `hyprctl dispatch workspace 9` form fails.

## 2. The problem

With `pixel-scroll-precision-mode` on, touchpad scrolling in a GUI frame on the 4K
panel feels laggy and jumpy, **especially scrolling up**. The same stack (GTK 3 +
cairo, software rendering) in the user's own app **gritcode** (`~/Developer/gritcode`,
wxWidgets on GTK 3) scrolls smoothly at 4K on the same laptop. So GTK 3 isn't the
limit; Emacs' pgtk drawing path is.

Upstream reports (all open, no fix as of Feb 2026):
- bug#72960 "PGTK Wayland exhibits more lag than X11 version": 4K at 2x scaling, pgtk
  scrolls at ~15 fps where the X11 build is smooth.
  https://lists.gnu.org/archive/html/bug-gnu-emacs/2024-09/msg00104.html
- bug#71591 "PGTK: Terrible input lag with display scaling": 4K at 150%; a smaller window helps.
  https://lists.gnu.org/archive/html/bug-gnu-emacs/2024-06/msg01717.html
- bug#59134 "Pixel scroll precision mode is very CPU intensive and governor sensitive".
  https://lists.gnu.org/archive/html/bug-gnu-emacs/2022-11/msg00633.html

## 3. What was already measured (don't redo this)

Measured in the installed 31.1 on eDP-1, in an org file (larger headings, `org-indent-mode`):

| Measurement | Result |
|---|---|
| Real touchpad event rate | ~170 wheel events/s (one every ~6 ms) |
| Events arriving while Emacs was still busy | **91%**, so events queue up |
| `pixel-scroll-precision-scroll-down`, 30 px step | 1.0 ms Lisp / **8.5 ms** with `(redisplay t)` |
| `pixel-scroll-precision-scroll-up`, 30 px step | 4.9 ms Lisp / **12.1 ms** with `(redisplay t)` |
| Visual jumps (80 x 10 px steps, text position checked) | none in either direction |
| Default `gc-cons-threshold` (800 KB) | ~45 ms GC pauses; the user now runs 64 MB |

Also tried, with **no noticeable improvement** (so don't lead with it): an `:around`
advice on `pixel-scroll-precision` that merged queued wheel events (summed pixel
deltas) into one scroll.

Conclusion: the Lisp side and redisplay's layout work fit in a 60 Hz frame. The cost
is in **how pgtk moves pixels and when it presents them**, which Emacs can't time from
Lisp.

## 4. Why pgtk is slow here (source analysis)

Emacs' redisplay engine (`src/xdisp.c`, `src/dispnew.c`) was designed for X11: window
contents persist, you can draw at any time, and scrolling is a cheap `XCopyArea` done by
the server. GTK 3 on Wayland breaks both: you may only draw inside the widget's `draw`
signal, and buffer contents aren't guaranteed to persist. pgtk therefore **emulates an
X11 window** with a private, persistent cairo surface, and copies it to the screen
whenever GTK asks.

Key code in `src/pgtkterm.c` (emacs-31 branch; line numbers approximate):

- `pgtk_begin_cr_clip` (~7583): lazily creates the private surface with
  `gdk_window_create_similar_surface (..., CAIRO_CONTENT_COLOR_ALPHA, w, h)` and
  `FRAME_CR_CONTEXT (f) = cairo_create (surface)`. All glyph drawing goes here.
- `pgtk_scroll_run` (~3122): redisplay's `scroll_run_hook`. Called when a window's
  text moves vertically (pixel scrolling hits this almost every step). It calls:
- `pgtk_copy_bits` (~3087): creates a **temporary** similar surface, paints the source
  rect into it, then paints it back at the destination. That's **2 near-full-window
  copies per scroll step**. It's done this way because cairo doesn't guarantee a correct
  result for overlapping self-copies.
- `pgtk_frame_up_to_date` (~3452): after each redisplay, `flip_cr_context (f)` (only
  swaps a reference, no copy) then **`gtk_widget_queue_draw (FRAME_GTK_WIDGET (f))`**,
  which invalidates the **entire** widget, not the damaged area.
  `pgtk_buffer_flipping_unblocked_hook` (~4858) does the same.
- `pgtk_handle_draw` (~5093): the GTK `draw` handler. It paints the whole private
  surface (`cairo_set_source_surface` + `cairo_paint`) into GTK's Wayland shm buffer.
  Because the whole widget was invalidated, that's **1 more full-window copy**.
- Hyprland then uploads the shm buffer to the GPU (unavoidable without GPU rendering).

At 3840x2160 ARGB, one full copy is ~32 MB. Per scroll step that's ~3 Emacs-side
full-frame copies, plus the compositor upload: ~130 MB of memory traffic. Redisplay
also runs once per input event, **not paced to the display's frame callbacks**, so
several full redraws can happen per 16.7 ms refresh.

How gritcode differs, and why it's smooth: it paints directly into GTK's buffer inside
the `draw` handler (`wxAutoBufferedPaintDC`, `~/Developer/gritcode/src/chat_canvas.cpp`
~line 1390). GTK coalesces invalidations and paints **at most once per frame clock
tick**, however many scroll events arrive.

## 5. Getting the source and building

```bash
cd ~/Developer/emacs-vibed
git clone --branch emacs-31 --single-branch https://git.savannah.gnu.org/git/emacs.git emacs
# Mirror if savannah is slow: https://github.com/emacs-mirror/emacs.git
cd emacs
git log --oneline -1          # note the base commit in NOTES.md
```

Build dependencies: the installed `emacs-wayland` already pulls in the runtime libraries
(gtk3, cairo, harfbuzz, libgccjit, tree-sitter...). Headers ship with those Arch
packages. You also need `base-devel` and `autoconf`/`texinfo` for `autogen.sh`. Check
with `pacman -Qi base-devel autoconf texinfo`, and ask the user before installing
anything.

Configure for fast iteration, matching the installed build where it matters. Skip
native compilation; it only slows the build and is irrelevant to display code:

```bash
./autogen.sh
./configure --with-pgtk --with-cairo --with-harfbuzz --with-modules \
            --with-tree-sitter --with-native-compilation=no \
            CFLAGS='-O2 -g3 -fno-omit-frame-pointer'
make -j"$(nproc)"
```

Run a test instance on the 4K panel:

```bash
./src/emacs -Q --eval '(pixel-scroll-precision-mode 1)' ~/some/large-file.org &
# Move it to the laptop panel if it opened on the Studio Display; its window class is "emacs".
```

Keep an **unpatched build** too (e.g. a second worktree `emacs-base` built the same way).
Always compare patched against unpatched, not against `/usr/bin/emacs`, so the build
flags are identical.

## 6. Measuring (do this before and after every change)

Tools in `tools/`:
- `tools/bench.el`: synthetic per-step timing, both directions, with forced redisplay.
  Load it in the test instance and call `(vibed-bench)`. Restores the view afterwards.
- `tools/scroll-log.el`: logs **real** touchpad wheel events (arrival time, handler
  time, whether input was already pending). `(vibed-scroll-log-start)`, have the user
  scroll for ~10 s, then `(vibed-scroll-log-report)`.

These only see the Lisp and redisplay side. For the pixel-copy side, use `perf`:

```bash
# perf may need installing (ask the user): pacman -S perf
perf record -g --call-graph fp -p "$(pgrep -f 'src/emacs -Q' | head -1)" -- sleep 10
# ...the user scrolls up and down on the 4K panel meanwhile...
perf report --no-children --sort symbol | head -60
```

Look for time in `pixman_*` / `_cairo_*` composite and blit functions under
`pgtk_copy_bits`, `pgtk_handle_draw` and GTK's paint path, compared with glyph drawing
(`pgtk_draw_glyph_string`, harfbuzz/freetype). **Confirm the copies dominate before
optimising them.**

For presented frames per second (a rough end-to-end metric), run
`WAYLAND_DEBUG=client ./src/emacs -Q ... 2>&1 | grep -c 'wl_surface@.*commit'` over a
timed scroll. The logging itself slows things down, so only compare runs measured the
same way.

The real acceptance test is the user's hands: scrolling up and down on the 4K panel
should feel as smooth as gritcode or Firefox.

## 7. Fix plan (stepwise; measure after each step)

**Step A: stop the full-window redraw per refresh (damage tracking).**
Track the union of rectangles actually drawn or scrolled since the last flip (glyph
strings, clears, `pgtk_copy_bits` destination, cursor, fringes). In
`pgtk_frame_up_to_date` / `pgtk_buffer_flipping_unblocked_hook`, call
`gtk_widget_queue_draw_area` for that rect, or a `cairo_region_t` via
`gtk_widget_queue_draw_region`, instead of `gtk_widget_queue_draw`. GTK then clips the
`draw` callback to the damaged region, so `cairo_paint` in `pgtk_handle_draw` copies
only that. Coordinates: the private surface is in device pixels at the frame's scale.
Check how pgtk handles scale (`FRAME_CR_SURFACE_DESIRED_*`, `gdk_window_get_scale_factor`)
and convert to widget (logical) coordinates correctly. Cheap, low risk, helps
everything, not just scrolling. (While pixel scrolling, most of the window is damaged
anyway, so on its own this won't be enough.)

**Step B: scroll the private surface in place.**
In `pgtk_copy_bits`, when the surface is a plain image surface
(`cairo_surface_get_type (s) == CAIRO_SURFACE_TYPE_IMAGE`; verify at runtime what
`gdk_window_create_similar_surface` returns on Wayland here, probably an image
surface), do: `cairo_surface_flush`, get the pointer, stride and format with
`cairo_image_surface_get_data/_get_stride/_get_format`, `memmove` each row (source and
destination only differ in y for scroll_run, so iterate rows in the right order, or
`memmove` the whole band when x and width span full rows), then
`cairo_surface_mark_dirty_rectangle`. Keep the existing temp-surface path as the
fallback for other surface types. Mind device scale: the image data is in device
pixels, while `src_rect`/`dst_rect` are in the units pgtk passes; check whether the
cairo context has a scale matrix and convert. This halves the Emacs-side copy cost of
every scroll step.

**Step C: pace presentation to the frame clock (biggest win, hardest).**
Emacs currently finishes redisplay and requests a draw after every command. Goal: at
most one present per display refresh, like gritcode gets from GTK. Options to
investigate:
1. Hook the widget's `GdkFrameClock` (`gtk_widget_get_frame_clock`, signals
   `update`/`after-paint`, or `gtk_widget_add_tick_callback`) and only
   `queue_draw` once per tick, collapsing all flips requested in between. That's
   simple, but it doesn't reduce redisplay work between ticks.
2. Additionally throttle redisplay itself while a precision-scroll gesture is in
   progress: accumulate wheel deltas (see the tried advice in section 3) and apply them
   once per frame tick, so `pgtk_scroll_run` and glyph drawing also run at most
   ~60x/s. This touches `keyboard.c` / `pixel-scroll.el` interaction; keep it
   minimal and opt-in (a variable) if it changes semantics.
Beware of `buffer_flipping_blocked_p` and the `cr_surface_visible_bell` path in
`pgtk_handle_draw`; keep both working.

**Not in scope:** a GTK 4 port or GPU (GL) rendering of glyphs. The user decided
against these; the targeted fixes above are the plan.

## 8. Correctness checks for every change

Test on **both** screens (eDP-1 at scale 2, DP-2 at scale 1), in plain GUI and daemon +
emacsclient frames:
- scroll up and down (touchpad, and `C-v`/`M-v`), with `pixel-scroll-precision-mode` on and off
- split windows (vertical and horizontal), scrolling one window while another shows the same buffer
- mode line and header line, fringes, line numbers (`display-line-numbers-mode`)
- cursor blink, region highlight, `hl-line-mode`, mouse-face hover
- images and variable-height lines (org headings with `:height`), `org-indent-mode`
- frame resize, maximise/fullscreen, moving a frame between the two screens (scale change)
- `visible-bell` (uses `cr_surface_visible_bell`), child frames/tooltips
- no leftover garbage pixels after scrolling fast then stopping

## 9. Deliverables

- `NOTES.md` in this folder: base commit, measurements (before/after tables, perf
  summaries), decisions, and anything surprising.
- The patch as `git format-patch` output in `patches/`, one commit per step (A, B, C),
  each with a GNU-style ChangeLog commit message (see `CONTRIBUTE` in the Emacs tree).
- If the user wants it upstreamed: send it to bug#72960 (`debbugs.gnu.org`). Changes
  over ~15 lines need an FSF copyright assignment from the author, so flag that to the
  user before sending anything. **Never send email or post upstream without the user's
  explicit go-ahead.**
