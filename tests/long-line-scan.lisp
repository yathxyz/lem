(defpackage :lem-tests/long-line-scan
  (:use :cl :rove))
(in-package :lem-tests/long-line-scan)

;;;; Tests for PI-1: long-line highlighting cap and interruptible syntax scan.
;;;;
;;;; Lines longer than the `long-line-scan-threshold` editor variable are
;;;; excluded from tmlanguage syntax scanning, and a pending C-g interrupt
;;;; aborts a scan via `editor-interrupt`.

(defun make-test-syntax-table (&rest patterns)
  (let ((table (lem:make-syntax-table))
        (tmlanguage (lem:make-tmlanguage
                     :patterns (apply #'lem:make-tm-patterns patterns))))
    (lem:set-syntax-parser table tmlanguage)
    table))

(defun make-test-buffer (name text &rest patterns)
  (let ((buffer (lem:make-buffer name
                                 :temporary t
                                 :enable-undo-p nil
                                 :syntax-table (apply #'make-test-syntax-table patterns))))
    ;; Insert before enabling highlighting so that the insertion itself
    ;; does not trigger a scan; tests call `scan-buffer` explicitly.
    (lem:insert-string (lem:buffer-point buffer) text)
    (setf (lem:variable-value 'lem:enable-syntax-highlight :buffer buffer) t)
    buffer))

(defun make-keyword-pattern ()
  (lem:make-tm-match "foo" :name 'lem:syntax-keyword-attribute))

(defun scan-buffer (buffer)
  (lem:syntax-scan-region (lem:buffer-start-point buffer)
                          (lem:buffer-end-point buffer)))

(defun attribute-at (buffer line charpos)
  (lem:with-point ((point (lem:buffer-point buffer)))
    (lem:move-to-line point line)
    (lem:line-offset point 0 charpos)
    (lem:text-property-at point :attribute)))

(deftest long-line-excluded-from-scan
  (let* ((long-line (concatenate 'string
                                 "foo "
                                 (make-string 10100 :initial-element #\a)))
         (buffer (make-test-buffer "*long-line-cap*"
                                   (format nil "foo bar~%~A~%foo baz" long-line)
                                   (make-keyword-pattern))))
    (scan-buffer buffer)
    (ok (eq 'lem:syntax-keyword-attribute (attribute-at buffer 1 0))
        "short line is scanned")
    (ok (null (attribute-at buffer 2 0))
        "over-threshold line gets no syntax properties")
    (ok (eq 'lem:syntax-keyword-attribute (attribute-at buffer 3 0))
        "short line after the long line is still scanned")))

(deftest long-line-threshold-configurable
  (ok (eql 10000 (lem:variable-value 'lem:long-line-scan-threshold :global))
      "default threshold is 10000")
  (let ((buffer (make-test-buffer "*long-line-threshold*"
                                  (format nil "foo bar~%foo")
                                  (make-keyword-pattern))))
    (scan-buffer buffer)
    (ok (eq 'lem:syntax-keyword-attribute (attribute-at buffer 1 0))
        "line is scanned with the default threshold")
    (setf (lem:variable-value 'lem:long-line-scan-threshold :buffer buffer) 5)
    (scan-buffer buffer)
    (ok (null (attribute-at buffer 1 0))
        "formerly scanned line is skipped after lowering the threshold")
    (ok (eq 'lem:syntax-keyword-attribute (attribute-at buffer 2 0))
        "line under the lowered threshold is still scanned")))

(deftest long-line-scan-bounded-time
  ;; A ~200KB single line: quadratic scanning previously took 30-60s;
  ;; with the cap it must complete well under 5 seconds.
  (let* ((text (with-output-to-string (out)
                 (dotimes (i 25000)
                   (write-string "foo bar " out))))
         (buffer (make-test-buffer "*long-line-timing*"
                                   (format nil "~A~%foo" text)
                                   (make-keyword-pattern)
                                   (lem:make-tm-region "\"" "\""
                                                       :name 'lem:syntax-string-attribute))))
    (let ((start-time (get-internal-real-time)))
      (scan-buffer buffer)
      (let ((elapsed (/ (- (get-internal-real-time) start-time)
                        internal-time-units-per-second)))
        (ok (< elapsed 5)
            (format nil "200KB single-line scan took ~,3Fs (bound: 5s)"
                    (float elapsed)))))
    (ok (null (attribute-at buffer 1 0))
        "the 200KB line is left unhighlighted")
    (ok (eq 'lem:syntax-keyword-attribute (attribute-at buffer 2 0))
        "the short line after it is still scanned")))

(deftest syntax-scan-aborts-on-pending-interrupt
  (let ((buffer (make-test-buffer "*interrupt-abort*"
                                  (format nil "foo~%foo")
                                  (make-keyword-pattern))))
    (unwind-protect
         (progn
           (setf lem/buffer/interrupt::*interrupted* t)
           (ok (signals (scan-buffer buffer) 'lem:editor-interrupt)
               "pending interrupt aborts the scan")
           (ng lem/buffer/interrupt::*interrupted*
               "interrupt flag is consumed by the abort")
           (ok (null (attribute-at buffer 1 0))
               "scan aborted before scanning any line"))
      (setf lem/buffer/interrupt::*interrupted* nil))))

(deftest syntax-scan-aborts-mid-scan
  ;; The "trip" pattern's move-action sets the interrupt flag while the
  ;; scan is running, simulating C-g arriving mid-scan.
  (let ((buffer (make-test-buffer "*interrupt-mid-scan*"
                                  (format nil "foo trip foo~%foo")
                                  (make-keyword-pattern)
                                  (lem:make-tm-match
                                   "trip"
                                   :name 'lem:syntax-constant-attribute
                                   :move-action (lambda (point)
                                                  (declare (ignore point))
                                                  (setf lem/buffer/interrupt::*interrupted* t)
                                                  nil)))))
    (unwind-protect
         (progn
           (ok (signals (scan-buffer buffer) 'lem:editor-interrupt)
               "interrupt arriving mid-scan aborts the scan")
           (ok (eq 'lem:syntax-keyword-attribute (attribute-at buffer 1 0))
               "tokens scanned before the interrupt keep their properties")
           (ok (null (attribute-at buffer 2 0))
               "lines after the interrupt point were not scanned"))
      (setf lem/buffer/interrupt::*interrupted* nil))))
