;;; measure.el --- automated scroll measurement for emacs-vibed  -*- lexical-binding: t; -*-

;; Loaded by tools/run-bench.sh into a test Emacs built with the VIBED
;; instrumentation commit (provides `vibed-stats').  Scrolling is injected by
;; tools/vscroll (virtual touchpad); this file records what Emacs did.

(require 'pixel-scroll)
(require 'cl-lib)
(require 'org)

(defvar vibed-m--log nil)
(defvar vibed-m--cpu0 nil)

(defun vibed-m--cpu ()
  "Process CPU seconds (utime+stime) of this Emacs."
  (let* ((s (with-temp-buffer
              (insert-file-contents "/proc/self/stat")
              (buffer-string)))
         (f (split-string (substring s (1+ (string-match ")" s))))))
    (/ (+ (string-to-number (nth 11 f)) (string-to-number (nth 12 f))) 100.0)))

(defvar vibed-m--classes nil)

(defun vibed-m--advice (orig event &rest args)
  (cl-pushnew (list last-event-device (device-class last-event-frame last-event-device))
              vibed-m--classes :test #'equal)
  (let ((t0 (float-time))
        (delta (ignore-errors (nth 4 event))))
    (prog1 (apply orig event args)
      (push (list t0 (float-time) delta) vibed-m--log))))

(defun vibed-m-setup ()
  (pixel-scroll-precision-mode 1)
  ;; Hyprland drops the virtual pointer's axis source, so GTK reports the
  ;; events as "Wayland Wheel Scrolling", i.e. a mouse.  Take the same code
  ;; path as a real touchpad (no interpolation) unless VIBED_MOUSE is set.
  (unless (getenv "VIBED_MOUSE")
    (setq pixel-scroll-precision-interpolate-mice nil))
  (setq gc-cons-threshold (* 64 1024 1024))
  (dolist (f '((org-level-1 . 1.4) (org-level-2 . 1.25) (org-level-3 . 1.1)))
    (set-face-attribute (car f) nil :height (cdr f)))
  (when (derived-mode-p 'org-mode)
    (org-indent-mode 1)
    (org-fold-show-all))
  (goto-char (point-min)))

(defun vibed-m-start ()
  (goto-char (point-min))
  (forward-line 400)
  (set-window-start (selected-window) (point))
  (redisplay t)
  (setq vibed-m--log nil vibed-m--classes nil
        vibed-m--cpu0 (vibed-m--cpu))
  (advice-add 'pixel-scroll-precision :around #'vibed-m--advice)
  (vibed-stats t)
  "started")

(defun vibed-m--write-timeline (st)
  "Write C-level events and Lisp commands, time-ordered, to /tmp/vibed-timeline.txt.
S=scroll event from GTK, B=update begin, U=frame up to date (flip),
D=draw (present), C/E=scroll command start/end."
  (let* ((ev (append (mapcar (lambda (x) (cons (car x) (string (cdr x))))
                             (append (plist-get st :timeline) nil))
                     (mapcan (lambda (l) (list (cons (car l) "C") (cons (nth 1 l) "E")))
                             vibed-m--log)))
         (ev (sort ev (lambda (a b) (< (car a) (car b)))))
         (t0 (car (car ev))))
    (with-temp-file "/tmp/vibed-timeline.txt"
      (dolist (e ev)
        (insert (format "%9.2f %s\n" (* 1000 (- (car e) t0)) (cdr e)))))))

(defun vibed-m--pct (sorted p)
  (if sorted (nth (min (1- (length sorted)) (floor (* p (length sorted)))) sorted) 0))

(defun vibed-m-report (seg-ends seg-durs)
  "SEG-ENDS: realtime floats when each vscroll segment ended; SEG-DURS their lengths."
  (advice-remove 'pixel-scroll-precision #'vibed-m--advice)
  (let* ((st (vibed-stats t))
         (_ (vibed-m--write-timeline st))
         (cpu (- (vibed-m--cpu) vibed-m--cpu0))
         (log (reverse vibed-m--log))
         (t-first (car (car log)))
         (t-last (nth 1 (car (last log))))
         (active (- t-last t-first))
         (dts (seq-filter (lambda (x) (and (>= x t-first) (<= x t-last)))
                          (append (plist-get st :draw-times) nil)))
         (ivs (sort (cl-mapcar (lambda (a b) (* 1000 (- b a))) dts (cdr dts)) #'<))
         ;; only intervals while scrolling (drop the pauses between segments)
         (ivs (seq-filter (lambda (x) (< x 500)) ivs))
         (draws (plist-get st :draws))
         (lags
          (mapcar (lambda (e)
                    (let ((last-h (seq-reduce
                                   (lambda (acc x)
                                     (if (and (< (car x) (+ e 1.9))) (max acc (nth 1 x)) acc))
                                   log 0)))
                      (round (* 1000 (- last-h e)))))
                  seg-ends))
         (all-dts (append (plist-get st :draw-times) nil))
         (fps (cl-mapcar (lambda (e d lag)
                           (/ (seq-count (lambda (x) (and (>= x (- e d)) (<= x (+ e (/ lag 1000.0)))))
                                         all-dts)
                              (+ d (/ (max lag 0) 1000.0))))
                         seg-ends seg-durs lags))
         (pixels (apply #'+ (mapcar (lambda (x) (abs (or (cdr-safe (nth 2 x)) 0))) log))))
    (format
     (concat "devices: %S\n" "scroll commands=%d  |sum delta|=%.0f px  active=%.2fs  cpu=%.2fs (%.0f%%)\n"
             "lag after segment end (ms): %S\n"
             "presents/s per segment: %s\n"
             "presents(draw)=%d in active: %d (%.1f/s)  interval ms median=%.1f p90=%.1f p99=%.1f max=%.1f  >25ms: %d/%d\n"
             "draw: avg %.2f ms, avg area %.0f logical px^2 | updates=%d avg %.2f ms | copy_bits=%d avg %.2f ms | up_to_date=%d | surftype=%d")
     vibed-m--classes (length log) pixels active cpu (* 100 (/ cpu (max active 0.001)))
     lags (mapconcat (lambda (x) (format "%.1f" x)) fps " ")
     draws (length dts) (/ (length dts) (max active 0.001))
     (vibed-m--pct ivs 0.5) (vibed-m--pct ivs 0.9) (vibed-m--pct ivs 0.99)
     (or (car (last ivs)) 0) (seq-count (lambda (x) (> x 25)) ivs) (length ivs)
     (/ (plist-get st :draw-ms) (max draws 1))
     (/ (plist-get st :draw-area) (max draws 1))
     (plist-get st :updates) (/ (plist-get st :update-ms) (max 1 (plist-get st :updates)))
     (plist-get st :copies) (/ (plist-get st :copy-ms) (max 1 (plist-get st :copies)))
     (plist-get st :uptodate) (plist-get st :surftype))))

;;; measure.el ends here
