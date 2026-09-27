#!/bin/bash
# usage: check-garbage.sh TREE [FILE]
# Correctness check for damage tracking / in-place scrolling: after each
# action, screenshot the Emacs window, force a full redraw (redraw-frame),
# screenshot again and count differing pixels.  Any difference means the
# screen was left with stale pixels.  Screenshots go to /tmp/vibed-garbage/.
TREE=$1; FILE=${2:-$HOME/Developer/emacs-vibed/emacs/etc/ORG-NEWS}
T=$HOME/Developer/emacs-vibed/tools
SRV=vibed-garbage-$$
D=/tmp/vibed-garbage; rm -rf $D; mkdir -p $D
PREV_WS=$(hyprctl activeworkspace -j | jq -r .id)
hyprctl -q dispatch "hl.dsp.focus({ workspace = \"${VIBED_WS:-9}\" })"
if [ -n "$VIBED_DAEMON" ]; then
  # daemon + emacsclient frame, like the user's setup (private server name)
  "$TREE/src/emacs" -Q --fg-daemon="$SRV" -l "$T/measure.el" \
    ${VIBED_EXTRA_EVAL:+--eval "$VIBED_EXTRA_EVAL"} >$D/emacs.log 2>&1 &
  EPID=$!
  for i in $(seq 100); do [ -S "$XDG_RUNTIME_DIR/emacs/$SRV" ] && break; sleep 0.1; done
  "$TREE/lib-src/emacsclient" -s "$SRV" -c -n "$FILE"
  sleep 1
  "$TREE/lib-src/emacsclient" -s "$SRV" --eval "(let ((f (seq-find #'display-graphic-p (frame-list)))) (select-frame-set-input-focus f) (with-selected-window (frame-selected-window f) (vibed-m-setup) (blink-cursor-mode -1)))" >/dev/null
else
"$TREE/src/emacs" -Q -l "$T/measure.el" "$FILE" \
  --eval "(progn (vibed-m-setup) (blink-cursor-mode -1) (setq server-name \"$SRV\") (server-start))" \
  ${VIBED_EXTRA_EVAL:+--eval "$VIBED_EXTRA_EVAL"} >$D/emacs.log 2>&1 &
EPID=$!
fi
trap 'kill $EPID 2>/dev/null; hyprctl -q dispatch "hl.dsp.focus({ workspace = \"$PREV_WS\" })"' EXIT
for i in $(seq 100); do [ -S "$XDG_RUNTIME_DIR/emacs/$SRV" ] && break; sleep 0.1; done
sleep 1.5
EC() { "$TREE/lib-src/emacsclient" -s "$SRV" --eval "$1" >/dev/null; }
geom() { hyprctl clients -j | jq -r ".[] | select(.pid==$EPID) | \"\(.at[0]),\(.at[1]) \(.size[0])x\(.size[1])\""; }
center() { hyprctl clients -j | jq -r ".[] | select(.pid==$EPID) | \"\(.at[0]+.size[0]/2|floor) \(.at[1]+.size[1]/2|floor)\""; }
FAIL=0; N=0
check() {  # NAME
  N=$((N+1)); local n=$(printf %02d $N)-$1
  sleep 0.4; grim -g "$(geom)" $D/$n-a.png
  EC "(redraw-frame)"; sleep 0.4; grim -g "$(geom)" $D/$n-b.png
  local ae=$(compare -metric AE $D/$n-a.png $D/$n-b.png $D/$n-diff.png 2>&1 | cut -d' ' -f1)
  if [ "$ae" != "0" ]; then FAIL=$((FAIL+1)); echo "FAIL $n: $ae px differ"; else echo "ok   $n"; rm -f $D/$n-diff.png; fi
}
read X Y < <(center)
check initial
"$T/vscroll/vscroll" $X $Y d:1.5:170:2 >/dev/null 2>&1; check scroll-down
"$T/vscroll/vscroll" $X $Y u:1:170:2 >/dev/null 2>&1; check scroll-up
"$T/vscroll/vscroll" $X $Y d:0.3:170:3 u:0.3:170:3 d:0.2:170:1 >/dev/null 2>&1; check scroll-jiggle
inj() { [ "$("$TREE/lib-src/emacsclient" -s "$SRV" --eval "(fboundp 'vibed-inject-scroll)")" = t ] || { echo "(no synthetic touchpad in this build; using wheel)"; "$T/vscroll/vscroll" $X $Y d:0.6:170:2 u:0.3:170:2 >/dev/null 2>&1; return; }
  EC "(vibed-inject-scroll 170.0 '($1))"; while [ "$("$TREE/lib-src/emacsclient" -s "$SRV" --eval "(car (vibed-inject-scroll nil nil))")" != t ]; do sleep 0.2; done; }
inj "(0.2 1) (-0.3 0.4)"; check touchpad-down-up
inj "(0.5 0.5) (-0.5 0.2) (0.1 0.3)"; check touchpad-fast-reverse
wtype -M ctrl v -m ctrl; check C-v
wtype -M alt v -m alt; check M-v
EC "(progn (split-window-below) (split-window-right))"; check split
"$T/vscroll/vscroll" $X $((Y-200)) d:1:170:2 u:0.5:170:1 >/dev/null 2>&1; check scroll-split-top
"$T/vscroll/vscroll" $((X+300)) $((Y+200)) d:1:170:2 >/dev/null 2>&1; check scroll-split-bottom
EC "(progn (delete-other-windows) (global-display-line-numbers-mode 1) (global-hl-line-mode 1))"; check linum-hl
"$T/vscroll/vscroll" $X $Y d:1:170:2 u:0.4:170:2 >/dev/null 2>&1; check scroll-linum
inj "(0.3 0.6) (-0.1 0.3)"; check touchpad-linum
wtype -M ctrl -k space -m ctrl; wtype -M ctrl n n n n n -m ctrl; check region
wtype -M ctrl g -m ctrl; wtype -M ctrl n -m ctrl; check region-off
EC "(progn (setq visible-bell t) (ding))"; sleep 0.5; check visible-bell
wtype -M alt x -m alt; sleep 0.3; wtype 'emacs-v'; check minibuffer
wtype -M ctrl g -m ctrl; check minibuffer-quit
EC "(set-frame-parameter nil 'fullscreen 'fullboth)"; sleep 0.8; check fullscreen
"$T/vscroll/vscroll" $X $Y d:1:170:2 >/dev/null 2>&1; check scroll-fullscreen
EC "(set-frame-parameter nil 'fullscreen nil)"; sleep 0.8; check unfullscreen
EC "(progn (global-display-line-numbers-mode -1) (global-hl-line-mode -1) (pixel-scroll-precision-mode -1))"
read X Y < <(center)
"$T/vscroll/vscroll" $X $Y d:1:170:2 u:0.5:170:2 >/dev/null 2>&1; check no-precision-scroll
EC "(with-selected-window (frame-selected-window) (pixel-scroll-precision-mode 1) (goto-char (point-min)) (search-forward \"[[\") (recenter 5))"; check before-hover
MP=$("$TREE/lib-src/emacsclient" -s "$SRV" --eval "(with-selected-window (frame-selected-window) (let* ((p (window-absolute-pixel-position (point)))) (format \"%s %s %s\" (car p) (cdr p) (nth 3 (frame-edges nil 'native-edges)))))" | tr -d '"')
read PX PY NH <<<"$MP"; read GX GY GH < <(hyprctl clients -j | jq -r ".[] | select(.pid==$EPID) | \"\(.at[0]) \(.at[1]) \(.size[1])\"")
# GTK menu bar and tool bar are above the native frame
"$T/vscroll/vscroll" $((GX+PX+8)) $((GY+GH-NH+PY+8)) p:0.3 >/dev/null 2>&1; sleep 1.5; check mouse-hover
if [ -n "$VIBED_MOVE_TO" ]; then
  # move the frame to a workspace on another output (scale change) and back
  hyprctl -q dispatch "hl.dsp.window.move({ $VIBED_MOVE_TO })"; sleep 1.5; check moved
  inj "(0.2 0.6) (-0.2 0.3)"; check moved-touchpad
  hyprctl -q dispatch "hl.dsp.window.move({ $VIBED_MOVE_BACK })"; sleep 1.5; check moved-back
  inj "(0.2 0.6) (-0.2 0.3)"; check moved-back-touchpad
fi
echo "== $FAIL failures out of $N checks; screenshots in $D"
EC "(kill-emacs)"
