(defpackage :lem-tests/encoding-fallback
  (:use :cl :rove)
  (:import-from :lem-fake-interface
                :with-fake-interface))
(in-package :lem-tests/encoding-fallback)

;;; DS-7: a file whose detected encoding cannot decode it (Latin-1, invalid
;;; UTF-8, ...) must open under the latin-1 fallback -- byte-preserving, never
;;; failing -- instead of the buffer being deleted and the file refused. An
;;; explicit `revert-buffer-with-encoding' lets the user override the encoding,
;;; and plain UTF-8 files must still auto-detect. Detection is forced to :jp
;;; (upstream default) so the misdetection that triggers the fallback is
;;; deterministic regardless of the fork's default scheme.

(defun write-octets (path octets)
  (with-open-file (stream path :direction :output
                               :element-type '(unsigned-byte 8)
                               :if-exists :supersede
                               :if-does-not-exist :create)
    (write-sequence octets stream)))

(defun read-octets (path)
  (with-open-file (stream path :direction :input
                               :element-type '(unsigned-byte 8))
    (let ((octets (make-array (file-length stream) :element-type '(unsigned-byte 8))))
      (read-sequence octets stream)
      octets)))

(defun octets (&rest bytes)
  (make-array (length bytes) :element-type '(unsigned-byte 8)
                             :initial-contents bytes))

(defun buffer-string (buffer)
  (lem:points-to-string (lem:buffer-start-point buffer)
                        (lem:buffer-end-point buffer)))

;; "caf" + 0xE9 + LF: valid Latin-1 (0xE9 = LATIN SMALL LETTER E WITH ACUTE),
;; but invalid UTF-8 and undecodable under the encodings :jp guesses for it.
(defparameter +latin1-octets+ (octets #x63 #x61 #x66 #xE9 #x0A))
(defparameter +latin1-text+
  (coerce (list #\c #\a #\f (code-char #xE9)) 'string))

;; "A" + 0xFF + "B" + LF: 0xFF is invalid UTF-8 and not a valid Shift_JIS lead.
(defparameter +bad-utf8-octets+ (octets #x41 #xFF #x42 #x0A))
(defparameter +bad-utf8-text+
  (coerce (list #\A (code-char #xFF) #\B) 'string))

;; "hi" + U+00E9 as UTF-8 (0xC3 0xA9) + LF: genuinely UTF-8.
(defparameter +utf8-octets+ (octets #x68 #x69 #xC3 #xA9 #x0A))
(defparameter +utf8-text+
  (coerce (list #\h #\i (code-char #xE9)) 'string))

(defmacro with-jp-detection (&body body)
  "Force encoding detection to the upstream :jp scheme for BODY."
  `(lem:with-global-variable-value (lem-core:detect-encoding-scheme :jp)
     ,@body))

(defmacro with-message-support (&body body)
  "Let `message' run under the bare fake interface. A non-nil message timeout
schedules a popup timer that needs the editor's *TIMER-MANAGER* (unbound in
tests); nil disables the timer so the message displays without one."
  `(let ((lem-core::*message-timeout* nil))
     ,@body))

(defmacro with-input-file ((path octets) &body body)
  `(let ((,path (namestring
                 (uiop:tmpize-pathname
                  (merge-pathnames "lem-ds7-enc" (uiop:temporary-directory))))))
     (unwind-protect
          (progn (write-octets ,path ,octets) ,@body)
       (uiop:delete-file-if-exists ,path))))

(defun open-and-collect (path)
  "Open PATH via find-file-buffer, returning (values buffer content notified-p).
NOTIFIED-P is true when the latin-1 fallback fired."
  (let ((notified nil))
    (let ((lem/buffer/file:*encoding-fallback-notification-function*
            (lambda (filename external-format)
              (declare (ignore filename external-format))
              (setf notified t))))
      (let ((buffer (lem:find-file-buffer path)))
        (values buffer (buffer-string buffer) notified)))))

(deftest latin1-file-opens-via-fallback
  (with-fake-interface ()
    (with-jp-detection
      (with-input-file (path +latin1-octets+)
        (multiple-value-bind (buffer content notified) (open-and-collect path)
          (unwind-protect
               (progn
                 (ok (member buffer (lem:buffer-list))
                     "buffer is not deleted")
                 (ok notified "the latin-1 fallback fired")
                 (ok (search +latin1-text+ content)
                     "the Latin-1 bytes decode to café under the fallback"))
            (lem:delete-buffer buffer)))))))

(deftest invalid-utf8-file-opens-via-fallback
  (with-fake-interface ()
    (with-jp-detection
      (with-input-file (path +bad-utf8-octets+)
        (multiple-value-bind (buffer content notified) (open-and-collect path)
          (unwind-protect
               (progn
                 (ok (member buffer (lem:buffer-list))
                     "buffer is not deleted")
                 (ok notified "the latin-1 fallback fired")
                 (ok (search +bad-utf8-text+ content)
                     "the invalid-UTF-8 bytes decode losslessly under the fallback"))
            (lem:delete-buffer buffer)))))))

(deftest utf8-file-auto-detects
  (with-fake-interface ()
    (with-jp-detection
      (with-input-file (path +utf8-octets+)
        (multiple-value-bind (buffer content notified) (open-and-collect path)
          (unwind-protect
               (progn
                 (ok (not notified) "no fallback for a genuine UTF-8 file")
                 (ok (search +utf8-text+ content)
                     "UTF-8 is decoded correctly by auto-detection"))
            (lem:delete-buffer buffer)))))))

(deftest fallback-open-round-trips-bytes
  ;; A no-op open (via fallback) -> save must reproduce the original bytes.
  (with-fake-interface ()
    (with-jp-detection
      ;; Suppress the fallback notification so the round-trip does not depend on
      ;; the message/timer machinery.
      (let ((lem/buffer/file:*encoding-fallback-notification-function* nil))
        (dolist (in (list +latin1-octets+ +bad-utf8-octets+))
          (with-input-file (path in)
            (let ((buffer (lem:find-file-buffer path)))
              (unwind-protect
                   (progn
                     (lem:write-to-file buffer path)
                     (ok (equalp in (read-octets path))
                         "fallback-opened file round-trips byte-for-byte"))
                (lem:delete-buffer buffer)))))))))

(deftest revert-buffer-with-encoding-decodes-latin1
  (with-fake-interface ()
    (with-message-support
     (with-jp-detection
      (with-input-file (path +latin1-octets+)
        (let ((buffer (lem:find-file-buffer path))
              (previous-buffer (lem:current-buffer)))
          (unwind-protect
               (progn
                 (setf (lem:current-buffer) buffer)
                 ;; Explicit latin-1 decodes the file correctly.
                 (lem-core/commands/file:revert-buffer-with-encoding :latin-1)
                 (ok (search +latin1-text+ (buffer-string buffer))
                     "explicit latin-1 decodes the Latin-1 file")
                 (ok (not (lem:buffer-modified-p buffer))
                     "reverted buffer is unmodified")
                 ;; A wrong explicit encoding must not empty the buffer: it
                 ;; reports the miss and recovers under latin-1.
                 (ok (signals (lem-core/commands/file:revert-buffer-with-encoding :utf-8)
                              'lem:editor-error)
                     "a wrong encoding signals an editor-error")
                 (ok (search +latin1-text+ (buffer-string buffer))
                     "the buffer is recovered as latin-1 after a failed encoding"))
            ;; Restore the global current-buffer before deleting ours so we do
            ;; not leave a dead buffer current for later tests.
            (setf (lem:current-buffer) previous-buffer)
            (lem:delete-buffer buffer))))))))
