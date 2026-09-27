;;; bench.el --- synthetic pixel-scroll timing for emacs-vibed  -*- lexical-binding: t; -*-

;; Usage, in the test Emacs (on the 4K panel, with a large file open):
;;   (load "~/Developer/emacs-vibed/tools/bench.el")
;;   (vibed-bench)          ; 120 steps of 30 px each way
;;   (vibed-bench 200 10)   ; custom step count and size
;; Restores the window's start and point afterwards.  Only measures Lisp +
;; redisplay (layout, glyph drawing, pgtk_scroll_run); the GTK draw copy and the
;; compositor upload happen later, outside `redisplay', and need perf.

(require 'pixel-scroll)

(defun vibed--bench-dir (fn n step)
  (let (lisp total)
    (dotimes (_ n)
      (let ((t0 (float-time)))
        (condition-case nil (funcall fn step) (error nil))
        (let ((t1 (float-time)))
          (redisplay t)
          (push (* 1000 (- t1 t0)) lisp)
          (push (* 1000 (- (float-time) t0)) total))))
    (let ((l (sort lisp #'<)) (tt (sort total #'<)))
      (format "lisp median=%.1f p90=%.1f | lisp+redisplay median=%.1f p90=%.1f max=%.1f ms"
              (nth (/ n 2) l) (nth (floor (* n 0.9)) l)
              (nth (/ n 2) tt) (nth (floor (* n 0.9)) tt) (car (last tt))))))

(defun vibed--jumps (fn step n)
  "Scroll N times by STEP px; count steps where text didn't move exactly STEP px."
  (let (moves)
    (dotimes (_ n)
      (redisplay t)
      (let* ((w (selected-window))
             (ref (save-excursion (goto-char (window-start w)) (forward-line 3) (point)))
             (y0 (cdr (posn-x-y (posn-at-point ref w)))))
        (condition-case nil (funcall fn step) (error nil))
        (redisplay t)
        (let ((p (posn-at-point ref w)))
          (when (and p y0) (push (- (cdr (posn-x-y p)) y0) moves)))))
    (let ((bad (seq-filter (lambda (m) (/= (abs m) step)) moves)))
      (format "%d/%d steps off (values %S)" (length bad) (length moves)
              (seq-take (seq-uniq bad) 10)))))

(defun vibed-bench (&optional n step)
  "Time pixel scrolling in the selected window, both directions."
  (interactive)
  (let* ((n (or n 120)) (step (or step 30))
         (w (selected-window)) (start (window-start w)) (pt (window-point w))
         (gc0 gcs-done)
         out)
    (goto-char (point-min)) (set-window-start w (point-min)) (redisplay t)
    (push (format "down (text moves up):   %s"
                  (vibed--bench-dir #'pixel-scroll-precision-scroll-down n step)) out)
    (push (format "up   (text moves down): %s"
                  (vibed--bench-dir #'pixel-scroll-precision-scroll-up n step)) out)
    (goto-char (point-min)) (set-window-start w (point-min)) (redisplay t)
    (push (format "jumps down: %s" (vibed--jumps #'pixel-scroll-precision-scroll-down 10 80)) out)
    (push (format "jumps up:   %s" (vibed--jumps #'pixel-scroll-precision-scroll-up 10 80)) out)
    (set-window-start w start) (goto-char pt) (redisplay t)
    (push (format "GCs during bench: %d; monitor: %s scale %s"
                  (- gcs-done gc0)
                  (frame-monitor-attribute 'name) (frame-monitor-attribute 'scale-factor))
          out)
    (let ((report (string-join (nreverse out) "\n")))
      (message "%s" report)
      report)))

;;; bench.el ends here
