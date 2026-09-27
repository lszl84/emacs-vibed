#!/bin/bash
# usage: run-bench.sh TREE LABEL [FILE] [SEGMENTS...]
# Launches TREE/src/emacs -Q on (empty) workspace 9, injects touchpad scrolling
# with tools/vscroll and prints the measure.el report.  Needs the VIBED
# instrumentation commit in TREE.
set -e
TREE=$1; LABEL=$2; FILE=${3:-$1/etc/ORG-NEWS}; shift 3 || shift $#
SEGS=("$@")
[ ${#SEGS[@]} -eq 0 ] && SEGS=(d:3:170:1 p:2.5 u:3:170:1 p:2.5 d:2:170:2.5 p:2.5 u:2:170:2.5 p:2.5)
T=$(cd "$(dirname "$0")" && pwd)
SRV=vibed-$LABEL-$$
OUT=/tmp/vibed-report-$SRV.txt
PREV_WS=$(hyprctl activeworkspace -j | jq -r .id)
hyprctl -q dispatch "hl.dsp.focus({ workspace = \"${VIBED_WS:-9}\" })"
if [ -n "$VIBED_HALF" ]; then
  # filler window so the test frame is tiled at half width
  "$TREE/src/emacs" -Q >/dev/null 2>&1 &
  FILLER=$!; sleep 1.5
fi
${VIBED_PROFILE:+$T/ptraceable} "$TREE/src/emacs" -Q -l "$T/measure.el" "$FILE" \
  --eval "(progn (vibed-m-setup) (setq server-name \"$SRV\") (server-start))" \
  ${VIBED_EXTRA_EVAL:+--eval "$VIBED_EXTRA_EVAL"} >/tmp/vibed-$SRV.log 2>&1 &
EPID=$!
trap 'kill $EPID $FILLER 2>/dev/null; hyprctl -q dispatch "hl.dsp.focus({ workspace = \"$PREV_WS\" })"' EXIT
for i in $(seq 100); do [ -S "$XDG_RUNTIME_DIR/emacs/$SRV" ] && break; sleep 0.1; done
sleep 1.5
EC() { "$TREE/lib-src/emacsclient" -s "$SRV" --eval "$1" >/dev/null; }
read X Y < <(hyprctl clients -j | jq -r ".[] | select(.pid==$EPID) | \"\(.at[0]+.size[0]/2|floor) \(.at[1]+.size[1]/2|floor)\"")
# warm-up
if [ -n "$VIBED_INJECT" ]; then
  EC "(vibed-inject-scroll 170.0 '((0.1 1) (0 0.5) (-0.1 1) (0 0.5)))"; sleep 3.5
else
  "$T/vscroll/vscroll" "$X" "$Y" d:1:170:1 p:0.5 u:1:170:1 p:1 >/dev/null 2>&1
fi
EC "(vibed-m-start)"
if [ -n "$VIBED_PROFILE" ]; then
  ( end=$((SECONDS+${VIBED_PROFILE_SECS:-12})); while [ $SECONDS -lt $end ]; do
      eu-stack -1 -p $EPID 2>/dev/null; echo "=====SAMPLE"; sleep 0.03; done ) > "$VIBED_PROFILE" &
  PROF=$!
fi
if [ -n "$VIBED_INJECT" ]; then
  # in-Emacs synthetic touchpad (GDK smooth scroll events)
  RATE=170; LSEGS=""
  for s in "${SEGS[@]}"; do IFS=: read dir sec hz val <<<"$s"
    case $dir in p) LSEGS+="(0 $sec) ";; d) RATE=$hz; LSEGS+="($(awk "BEGIN{print $val/10}") $sec) ";; u) RATE=$hz; LSEGS+="(-$(awk "BEGIN{print $val/10}") $sec) ";; esac; done
  SRC=$("$TREE/lib-src/emacsclient" -s "$SRV" --eval "(vibed-inject-scroll $RATE.0 '($LSEGS))")
  while :; do R=$("$TREE/lib-src/emacsclient" -s "$SRV" --eval "(vibed-inject-scroll nil nil)"); case $R in "(t"*) break;; esac; sleep 0.5; done
  ENDS=$(sed 's/^(t *//; s/)$//' <<<"$R")
else
ENDS=$("$T/vscroll/vscroll" "$X" "$Y" "${SEGS[@]}" 2>/dev/null)
fi
[ -n "$PROF" ] && wait $PROF
sleep 0.5
DURS=$(for s in "${SEGS[@]}"; do case $s in p:*) ;; *) echo -n "$(cut -d: -f2 <<<"$s") ";; esac; done)
EC "(with-temp-file \"$OUT\" (insert (vibed-m-report '($ENDS) '($DURS))))"
echo "== $LABEL ($(hyprctl clients -j | jq -r ".[] | select(.pid==$EPID) | \"\(.size[0])x\(.size[1]) logical\"")) segs: ${SEGS[*]}"
[ -n "$SRC" ] && echo "injected via device $SRC"
cat "$OUT"; echo
EC "(kill-emacs)" 2>/dev/null || kill $EPID
wait $EPID 2>/dev/null || true
hyprctl -q dispatch "hl.dsp.focus({ workspace = \"$PREV_WS\" })"
