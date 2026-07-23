(defpackage :lem-lsp-base/utils
  (:use :cl)
  (:import-from :quri)
  (:export :pathname-to-uri
           :uri-to-pathname
           :point-lsp-line-number
           :point-to-lsp-position
           :points-to-lsp-range
           :move-to-lsp-position
           :destructuring-lsp-range))
(in-package :lem-lsp-base/utils)

(defun encode-uri-path (path)
  (with-output-to-string (stream)
    (loop :with start := 0
          :for slash := (position #\/ path :start start)
          :do (write-string (quri:url-encode
                             (subseq path start (or slash (length path))))
                            stream)
          :when slash
            :do (write-char #\/ stream)
                (setf start (1+ slash))
          :unless slash
            :return nil)))

(defun decode-uri-path (path)
  ;; Quri's decoder follows form semantics and maps a raw + to a space.
  ;; A plus in a URI path is literal, so protect it before percent-decoding.
  (quri:url-decode
   (with-output-to-string (stream)
     (loop :for character :across path
           :do (if (char= character #\+)
                   (write-string "%2B" stream)
                   (write-char character stream))))))

(defun pathname-to-uri (pathname)
  (format nil "file://~A" (encode-uri-path (namestring pathname))))

(defun uri-to-pathname (uri)
  (let* ((parsed (quri:uri uri))
         (scheme (quri:uri-scheme parsed))
         (host (quri:uri-host parsed)))
    (unless (and (stringp scheme)
                 (string-equal scheme "file")
                 (or (null host)
                     (string= host "")
                     (string-equal host "localhost")))
      (error "Not a local file URI: ~S" uri))
    (pathname (decode-uri-path (quri:uri-path parsed)))))

(defun point-lsp-line-number (point)
  (1- (lem:line-number-at-point point)))

(defun point-to-lsp-position (point)
  (make-instance 'lsp:position
                 :line (point-lsp-line-number point)
                 :character (lem:point-charpos point)))

(defun points-to-lsp-range (start end)
  (make-instance 'lsp:range
                 :start (point-to-lsp-position start)
                 :end (point-to-lsp-position end)))

(defun move-to-lsp-position (point position)
  (check-type point lem:point)
  (check-type position lsp:position)
  (let ((line (lsp:position-line position))
        (character (lsp:position-character position)))
    (lem:move-to-line point (1+ line))
    (lem:character-offset (lem:line-start point) character)
    point))

(defun destructuring-lsp-range (start end range)
  (move-to-lsp-position start (lsp:range-start range))
  (move-to-lsp-position end (lsp:range-end range))
  (values))
