(defpackage :lem/common/osc52
  (:use :cl)
  (:export :*max-payload-octets*
           :base64-encode-octets
           :encode-clipboard-sequence)
  #+sbcl
  (:lock t))
(in-package :lem/common/osc52)

;;; OSC 52 clipboard-set encoding (pure, frontend-independent).
;;;
;;; The terminal control sequence to place text on the system clipboard is
;;;   ESC ] 52 ; c ; <base64-of-utf8> BEL
;;; When running inside tmux the whole sequence has to be wrapped in tmux's
;;; passthrough form so it reaches the outer terminal:
;;;   ESC P tmux ; <inner with every ESC doubled> ESC \
;;; (tmux must have `allow-passthrough on`).
;;;
;;; Paste (OSC 52 read) is deliberately not implemented here; most terminals
;;; disable it and paste is handled by the bracketed-paste path.

(defparameter *max-payload-octets* 99000
  "Maximum number of UTF-8 octets carried in a single OSC 52 sequence.
Kept below the ~100 KB payload limit common to terminal emulators. Text longer
than this is truncated at a character boundary before encoding.")

(defparameter +base64-alphabet+
  "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")

(defun base64-encode-octets (octets)
  "Return the standard (RFC 4648, padded) base64 encoding of OCTETS as a string.
OCTETS is a sequence of (unsigned-byte 8)."
  (let ((octets (coerce octets 'vector))
        (out (make-string-output-stream)))
    (loop :with len := (length octets)
          :for i :from 0 :below len :by 3
          :for b0 := (aref octets i)
          :for b1 := (if (< (+ i 1) len) (aref octets (+ i 1)) 0)
          :for b2 := (if (< (+ i 2) len) (aref octets (+ i 2)) 0)
          :for n := (logior (ash b0 16) (ash b1 8) b2)
          :do (write-char (char +base64-alphabet+ (ldb (byte 6 18) n)) out)
              (write-char (char +base64-alphabet+ (ldb (byte 6 12) n)) out)
              (write-char (if (< (+ i 1) len)
                              (char +base64-alphabet+ (ldb (byte 6 6) n))
                              #\=)
                          out)
              (write-char (if (< (+ i 2) len)
                              (char +base64-alphabet+ (ldb (byte 6 0) n))
                              #\=)
                          out))
    (get-output-stream-string out)))

(defun truncate-to-octets (text max-octets)
  "Return (values prefix truncated-p): the longest prefix of TEXT whose UTF-8
encoding is at most MAX-OCTETS octets. Truncation happens on a character
boundary so the payload is never a partial multi-byte character."
  (if (<= (babel:string-size-in-octets text) max-octets)
      (values text nil)
      (loop :with total := 0
            :for i :from 0 :below (length text)
            :for size := (babel:string-size-in-octets (string (char text i)))
            :when (> (+ total size) max-octets)
              :do (return (values (subseq text 0 i) t))
            :do (incf total size)
            :finally (return (values text nil)))))

(defun double-escapes (string)
  "Return STRING with every ESC byte duplicated, as tmux passthrough requires."
  (with-output-to-string (out)
    (loop :for ch :across string
          :do (write-char ch out)
              (when (char= ch #\Escape)
                (write-char ch out)))))

(defun encode-clipboard-sequence (text &key tmux (max-octets *max-payload-octets*))
  "Return (values sequence truncated-p) for placing TEXT on the system clipboard.
SEQUENCE is an OSC 52 clipboard-set escape string carrying TEXT as base64 of its
UTF-8 encoding. When TMUX is non-nil the sequence is wrapped in tmux's
passthrough form. TEXT is capped at MAX-OCTETS octets; TRUNCATED-P is true when
the payload was shortened to fit."
  (multiple-value-bind (payload truncated-p) (truncate-to-octets text max-octets)
    (let* ((base64 (base64-encode-octets
                    (babel:string-to-octets payload :encoding :utf-8)))
           (inner (format nil "~C]52;c;~A~C" #\Escape base64 #\Bel)))
      (values (if tmux
                  (format nil "~CPtmux;~A~C\\"
                          #\Escape
                          (double-escapes inner)
                          #\Escape)
                  inner)
              truncated-p))))
