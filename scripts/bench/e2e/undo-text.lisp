;;;; Exact undo validation and replay on a 10,000-line buffer.
;;;; Run after loading the project's Qlot setup. One warmup, three trials,
;;;; twenty exact comparisons and twenty undo/redo pairs per trial.
(defpackage :lem-bench/undo-text (:use :cl))
(in-package :lem-bench/undo-text)

(ql:quickload :lem/core :silent t)

(defun undo-bench-ms (function)
  (let ((start (get-internal-real-time)))
    (funcall function)
    (* 1000d0 (/ (- (get-internal-real-time) start)
                internal-time-units-per-second))))

(let* ((buffer (lem:make-buffer "undo-text-bench" :temporary t :enable-undo-p nil))
       (point (lem:buffer-point buffer))
       (text (with-output-to-string (out)
               (dotimes (i 10000)
                 (write-line "A reproducible line of text for the undo benchmark." out))))
       (comparisons nil)
       (replays nil))
  (unwind-protect
       (progn
         (lem:insert-string point text)
         (lem:buffer-enable-undo buffer)
         (lem:insert-character point #\x)
         (lem:buffer-undo-boundary buffer)
         (lem:buffer-undo point)
         (dotimes (round 4)
           (sb-ext:gc :full t)
           (let ((ms (undo-bench-ms
                      (lambda ()
                        (dotimes (i 20)
                          ;; Direct access isolates the production integrity check.
                          (assert (lem/buffer/internal::buffer-text-equal-p buffer text)))))))
             (when (plusp round) (push (/ ms 20) comparisons)))
           (let ((ms (undo-bench-ms
                      (lambda ()
                        (dotimes (i 20)
                          (lem:buffer-redo point)
                          (lem:buffer-undo point))))))
             (assert (string= text (lem:buffer-text buffer)))
             (when (plusp round) (push (/ ms 20) replays))))
         (format t "~&500 KB exact comparison median ms: ~,3f~%Undo/redo pair median ms: ~,3f~%"
                 (second (sort comparisons #'<)) (second (sort replays #'<))))
    (lem:delete-buffer buffer)))
