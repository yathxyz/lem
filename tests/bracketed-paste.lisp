(defpackage :lem-tests/bracketed-paste
  (:use :cl
        :lem
        :rove)
  (:import-from :lem-fake-interface
                :with-fake-interface))
(in-package :lem-tests/bracketed-paste)

(defparameter +payload+
  (format nil "(defun foo ()~%  (let ((x 1))~%    ~C  (+ x 2)))" #\Esc)
  "A multi-line Lisp snippet with leading whitespace and an embedded ESC byte.")

(deftest insert-bracketed-paste-is-literal
  (with-fake-interface ()
    (let* ((buffer (current-buffer))
           (point (buffer-point buffer)))
      (erase-buffer buffer)
      (insert-bracketed-paste point +payload+)
      ;; Byte-identical: auto-indent did not touch the leading whitespace and
      ;; the embedded ESC is preserved verbatim rather than acted on as a key.
      (ok (equal +payload+ (buffer-text buffer))))))

(deftest normalize-bracketed-paste-newlines-cr-and-crlf
  ;; Terminals deliver pasted line breaks as CR; CR and CRLF must become LF.
  (ok (equal (format nil "a~%b~%c")
             (lem-core/commands/edit::normalize-bracketed-paste-newlines
              (format nil "a~Cb~C~Cc" #\Return #\Return #\Newline))))
  ;; A lone LF is left untouched.
  (ok (equal (format nil "x~%y")
             (lem-core/commands/edit::normalize-bracketed-paste-newlines
              (format nil "x~%y")))))

(deftest insert-bracketed-paste-normalizes-cr
  (with-fake-interface ()
    (let* ((buffer (current-buffer))
           (point (buffer-point buffer)))
      (erase-buffer buffer)
      ;; CR-separated payload (as a terminal delivers it) becomes LF lines.
      (insert-bracketed-paste point (format nil "one~Ctwo~Cthree" #\Return #\Return))
      (ok (equal (format nil "one~%two~%three") (buffer-text buffer))))))

(deftest insert-bracketed-paste-is-single-undo
  (with-fake-interface ()
    (let* ((buffer (current-buffer))
           (point (buffer-point buffer)))
      (erase-buffer buffer)
      (let ((before (buffer-text buffer)))
        (insert-bracketed-paste point +payload+)
        (ok (equal +payload+ (buffer-text buffer)))
        ;; A single undo removes the whole paste.
        (buffer-undo point)
        (ok (equal before (buffer-text buffer)))))))
