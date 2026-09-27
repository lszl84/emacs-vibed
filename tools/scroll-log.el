;;; scroll-log.el --- log real touchpad scroll events for emacs-vibed  -*- lexical-binding: t; -*-

;; Usage, in the test Emacs:
;;   (load "~/Developer/emacs-vibed/tools/scroll-log.el")
;;   (vibed-scroll-log-start)
;;   ...the user scrolls up and down for ~10 s...
;;   (vibed-scroll-log-report)   ; also stops logging
;; Records, for every `pixel-scroll-precision' call: arrival time, handler time,
;; whether more input was already pending (i.e. Emacs is behind), pixel delta.

(require 'pixel-scroll)
(require 'cl-lib)

(defvar vibed--scroll-log nil)

(defun vibed--scroll-log-advice (orig event &rest args)
  (let* ((t0 (float-time))
         (pending (input-pending-p))
         (delta (ignore-errors (cdr (nth 4 event)))))
    (prog1 (apply orig event args)
      (push (list t0 (- (float-time) t0) pending delta) vibed--scroll-log))))

(defun vibed-scroll-log-start ()
  (interactive)
  (setq vibed--scroll-log nil)
  (advice-add 'pixel-scroll-precision :around #'vibed--scroll-log-advice)
  (message "vibed: logging scroll events"))

(defun vibed--pct (sorted p) (nth (min (1- (length sorted)) (floor (* p (length sorted)))) sorted))

(defun vibed-scroll-log-report ()
  (interactive)
  (advice-remove 'pixel-scroll-precision #'vibed--scroll-log-advice)
  (let* ((log (reverse vibed--scroll-log))
         (n (length log)))
    (if (< n 2)
        (message "vibed: no scroll events logged")
      (let* ((times (mapcar #'car log))
             (handler (sort (mapcar (lambda (e) (* 1000 (nth 1 e))) log) #'<))
             (gaps (sort (seq-filter (lambda (g) (< g 200))
                                     (cl-mapcar (lambda (a b) (* 1000 (- b a)))
                                                times (cdr times)))
                         #'<))
             (pending (seq-count (lambda (e) (nth 2 e)) log))
             (up (seq-count (lambda (e) (and (nth 3 e) (> (nth 3 e) 0))) log))
             (report
              (format (concat "events=%d over %.1fs (%d with delta>0, %d with delta<0)\n"
                              "handler ms: median=%.1f p90=%.1f max=%.1f\n"
                              "gap between events ms: median=%.1f p90=%.1f (~%.0f events/s)\n"
                              "input already pending: %d/%d (%.0f%%)")
                      n (- (car (last times)) (car times)) up (- n up)
                      (vibed--pct handler 0.5) (vibed--pct handler 0.9) (car (last handler))
                      (if gaps (vibed--pct gaps 0.5) 0) (if gaps (vibed--pct gaps 0.9) 0)
                      (if gaps (/ 1000.0 (max 0.1 (vibed--pct gaps 0.5))) 0)
                      pending n (* 100.0 (/ (float pending) n)))))
        (message "%s" report)
        report))))

;;; scroll-log.el ends here
