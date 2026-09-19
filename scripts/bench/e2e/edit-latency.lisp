;;;; Run with the repo's .qlot/setup.lisp loaded. Optional LEM_EDIT_SOURCE
;;;; loads an older buffer-insert.lisp for an otherwise identical comparison.
(ql:quickload :lem/core :silent t)
(defpackage :lem-bench/edit-latency (:use :cl))
(in-package :lem-bench/edit-latency)

(when (uiop:getenv "LEM_EDIT_SOURCE")
  (load (uiop:getenv "LEM_EDIT_SOURCE")))

(defun elapsed-ms (function)
  (let ((start (get-internal-real-time)))
    (funcall function)
    (* 1000d0 (/ (- (get-internal-real-time) start)
                internal-time-units-per-second))))

(defun run-benchmark ()
  "Measure file loading and undo-enabled edits at both ends of a buffer."
  (uiop:with-temporary-file (:pathname path :stream stream)
    (dotimes (i 10000) (write-line "A reproducible line of text for the edit benchmark." stream))
    (finish-output stream)
    (let ((loads '()) (starts '()) (ends '()))
      (dotimes (round 4)
        (let ((buffer nil))
          (unwind-protect
               (progn
                 (sb-ext:gc :full t)
                 (let ((ms (elapsed-ms (lambda () (setf buffer (lem:find-file-buffer path))))))
                   (when (plusp round) (push ms loads)))
                 (let ((point (lem:buffer-point buffer)))
                   (dolist (end-p '(nil t))
                     (if end-p (lem:buffer-end point) (lem:buffer-start point))
                     (let ((ms
                             (elapsed-ms
                              (lambda ()
                                (dotimes (i 200)
                                  (lem:insert-character point #\x)
                                  (lem:buffer-undo-boundary buffer)
                                  (lem:character-offset point -1)
                                  (lem:delete-character point 1)
                                  (lem:buffer-undo-boundary buffer))))))
                       (when (plusp round)
                         (if end-p (push (/ ms 200) ends) (push (/ ms 200) starts)))))))
            (when buffer (lem:delete-buffer buffer)))))
      (flet ((median (values) (second (sort values #'<))))
        (format t "~&10000-line load median ms: ~,3f~%" (median loads))
        (format t "Insert/delete pair with undo boundaries median ms/op: start=~,3f end=~,3f~%"
                (median starts) (median ends))))))

(run-benchmark)
