;;;; bench-edit.lisp -- VK-4 edit-latency benchmark (before/after the shell swap).
;;;; Measures insert-char / delete-char / newline split+join on
;;;;   (A) a normal multi-line buffer (2000 lines x 60 chars)
;;;;   (B) a 200KB single-line buffer
;;;; via the buffer-insert primitives with undo enabled and extra registered
;;;; points present (marker relocation active).

(in-package :cl-user)

(defun bench-run (name thunk n)
  (sb-ext:gc :full t)
  (let ((t0 (get-internal-real-time)))
    (dotimes (i n) (funcall thunk))
    (let ((us (/ (* (- (get-internal-real-time) t0) 1000000.0)
                 internal-time-units-per-second n)))
      (format t "~a: ~,2f us/op  (n=~d)~%" name us n)
      (finish-output))))

(defun make-bench-buffer (name lines-count line-len single-line-len)
  (let* ((buffer (lem:make-buffer name :temporary t :enable-undo-p t))
         (point (lem:buffer-point buffer)))
    (lem/buffer/internal::with-inhibit-undo ()
      (if single-line-len
          (lem/buffer/internal::insert-string/point
           point (make-string single-line-len :initial-element #\a))
          (dotimes (i lines-count)
            (lem/buffer/internal::insert-string/point
             point (make-string line-len :initial-element #\a))
            (lem/buffer/internal::insert-string/point point (string #\newline)))))
    buffer))

(defun spread-points (buffer positions)
  (loop :for pos :in positions
        :for kind := :left-inserting :then (if (eq kind :left-inserting)
                                               :right-inserting
                                               :left-inserting)
        :collect (let ((p (lem:copy-point (lem:buffer-point buffer) kind)))
                   (lem:move-to-position p pos)
                   p)))

(defun bench-scenario (label buffer mid-position n)
  (let ((point (lem:buffer-point buffer)))
    (lem:move-to-position point mid-position)
    ;; insert char xN
    (bench-run (format nil "~a insert-char" label)
               (lambda () (lem/buffer/internal::insert-string/point point "x"))
               n)
    ;; delete the same N chars back
    (lem:character-offset point (- n))
    (bench-run (format nil "~a delete-char" label)
               (lambda () (lem/buffer/internal::delete-char/point point 1))
               n)
    ;; newline split + join, per pair
    (bench-run (format nil "~a newline-split+join" label)
               (lambda ()
                 (lem/buffer/internal::insert-string/point point (string #\newline))
                 (lem:character-offset point -1)
                 (lem/buffer/internal::delete-char/point point 1))
               n)))

(defun run-bench ()
  (let ((mode-sym (find-symbol "*EDIT-ENGINE-MODE*" "LEM/BUFFER/INTERNAL")))
    (format t "mode: ~a~%"
            (if (and mode-sym (boundp mode-sym))
                (symbol-value mode-sym)
                :pre-swap)))
  ;; (A) normal multi-line buffer: 2000 lines x 60 chars, edit at line 1000.
  (let* ((buffer (make-bench-buffer "bench-normal" 2000 60 nil))
         (mid (+ 1 (* 1000 61) 30))
         (extras (spread-points buffer (list 200 5000 30000 60000
                                             (+ mid 100) (+ mid 2000)
                                             100000 120000))))
    (declare (ignore extras))
    (bench-scenario "normal " buffer mid 1000)
    (lem:delete-buffer buffer))
  ;; (B) 200KB single-line buffer, edit at char 100000.
  (let* ((buffer (make-bench-buffer "bench-longline" nil nil 200000))
         (mid 100000)
         (extras (spread-points buffer (list 100 50000 99000 100500
                                             150000 199000 20000 180000))))
    (declare (ignore extras))
    (bench-scenario "200KB-1line" buffer mid 200)
    (lem:delete-buffer buffer)))

(run-bench)
