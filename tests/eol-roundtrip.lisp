(defpackage :lem-tests/eol-roundtrip
  (:use :cl :rove)
  (:import-from :lem-fake-interface
                :with-fake-interface))
(in-package :lem-tests/eol-roundtrip)

;;; DS-6 regression corpus: opening a file and immediately saving it must never
;;; delete characters. Single-EOL files (LF, CRLF, CR, missing trailing newline)
;;; MUST round-trip byte-for-byte; mixed-EOL files MUST preserve every character
;;; (EOLs may be normalized to the detected dominant style, with a one-time
;;; notification).

(defun string->octets (string)
  "ASCII STRING to an (unsigned-byte 8) vector, byte-exact (no encoding layer)."
  (let ((octets (make-array (length string) :element-type '(unsigned-byte 8))))
    (dotimes (i (length string) octets)
      (setf (aref octets i) (char-code (char string i))))))

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

(defun strip-eol-bytes (octets)
  "Drop every CR (13) and LF (10) so only content characters remain."
  (remove-if (lambda (b) (or (= b 13) (= b 10))) octets))

(defmacro with-corpus-file ((path input-octets notified-p) &body body)
  "Bind PATH to a fresh temp file holding INPUT-OCTETS, open it, run the DS-6
round-trip (open -> save), and expose whether the mixed-EOL notification fired
via NOTIFIED-P. Cleans up the buffer and file."
  (let ((buffer (gensym "BUFFER")))
    `(let ((,path (namestring
                   (uiop:tmpize-pathname
                    (merge-pathnames "lem-ds6-eol" (uiop:temporary-directory)))))
           (,notified-p nil))
       (unwind-protect
            (let ((lem/buffer/file:*mixed-eol-notification-function*
                    (lambda (filename)
                      (declare (ignore filename))
                      (setf ,notified-p t))))
              (write-octets ,path ,input-octets)
              (with-fake-interface ()
                (let ((,buffer (lem:find-file-buffer ,path)))
                  (unwind-protect
                       (progn
                         (lem:write-to-file ,buffer ,path)
                         ,@body)
                    (lem:delete-buffer ,buffer)))))
         (uiop:delete-file-if-exists ,path)))))

(defun check-byte-identical (label input)
  (let ((in (string->octets input)))
    (with-corpus-file (path in notified-p)
      (ok (equalp in (read-octets path))
          (format nil "~A round-trips byte-for-byte" label))
      (ok (null notified-p)
          (format nil "~A is not reported as mixed" label)))))

(deftest single-eol-round-trips-byte-for-byte
  ;; A no-op open->save is byte-identical for every single-EOL style.
  (check-byte-identical "LF"                  (format nil "one~Ctwo~Cthree~C" #\Lf #\Lf #\Lf))
  (check-byte-identical "CRLF"                (format nil "one~C~Ctwo~C~Cthree~C~C"
                                                      #\Cr #\Lf #\Cr #\Lf #\Cr #\Lf))
  (check-byte-identical "CR"                  (format nil "one~Ctwo~Cthree~C" #\Cr #\Cr #\Cr))
  (check-byte-identical "LF-no-trailing-nl"   (format nil "one~Ctwo~Cthree" #\Lf #\Lf))
  (check-byte-identical "CRLF-no-trailing-nl" (format nil "one~C~Ctwo~C~Cthree" #\Cr #\Lf #\Cr #\Lf))
  (check-byte-identical "empty"               ""))

(deftest mixed-crlf-first-loses-no-characters
  ;; The empirically reproduced corruption: a CRLF file with an LF-only line
  ;; used to drop the last character of that line ("two" -> "tw").
  (let ((in (string->octets (format nil "one~C~Ctwo~Cthree~C~C"
                                    #\Cr #\Lf #\Lf #\Cr #\Lf))))
    (with-corpus-file (path in notified-p)
      (let ((out (read-octets path)))
        (ok (equalp (strip-eol-bytes in) (strip-eol-bytes out))
            "every content character survives the round-trip")
        (ok (search (string->octets "two") out)
            "the LF-only line keeps its final character")
        (ok notified-p
            "the file is reported as mixed (normalization is announced)")))))

(deftest mixed-lf-first-loses-no-characters
  ;; A CRLF line inside an LF file: content must survive; the stray CR is kept.
  (let ((in (string->octets (format nil "one~Ctwo~C~Cthree~C" #\Lf #\Cr #\Lf #\Lf))))
    (with-corpus-file (path in notified-p)
      (let ((out (read-octets path)))
        (ok (equalp (strip-eol-bytes in) (strip-eol-bytes out))
            "every content character survives the round-trip")))))
