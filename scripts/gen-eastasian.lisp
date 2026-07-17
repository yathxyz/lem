;;;; gen-eastasian.lisp -- regenerate src/common/character/eastasian.lisp
;;;;
;;;; Parses the Unicode Character Database into the character-width tables
;;;; consumed by lem/common/character/string-width-utils.
;;;;
;;;; Usage:
;;;;   sbcl --script scripts/gen-eastasian.lisp
;;;;
;;;; The three UCD source files are downloaded with curl into a temporary
;;;; directory (override with the UCD_DIR environment variable to reuse a
;;;; local mirror).  The output is written to src/common/character/eastasian.lisp
;;;; relative to this script.  Regeneration is reproducible for a fixed
;;;; Unicode version; the version string is captured from EastAsianWidth.txt
;;;; and embedded in the generated file's header comment.
;;;;
;;;; Width classification (see string-width-utils:char-width):
;;;;   *eastasian-full*      East_Asian_Width W or F, plus Emoji_Presentation -> 2
;;;;   *eastasian-ambiguous* East_Asian_Width A -> configurable (default 1)
;;;;   *zero-width*          general category Mn or Me, plus ZWJ (U+200D) -> 0

(require :uiop)

(defparameter *urls*
  '(:eaw "https://www.unicode.org/Public/UCD/latest/ucd/EastAsianWidth.txt"
    :dgc "https://www.unicode.org/Public/UCD/latest/ucd/extracted/DerivedGeneralCategory.txt"
    :emoji "https://www.unicode.org/Public/UCD/latest/ucd/emoji/emoji-data.txt"))

(defun ucd-dir ()
  (let ((env (uiop:getenv "UCD_DIR")))
    (if (and env (plusp (length env)))
        (uiop:ensure-directory-pathname env)
        (uiop:ensure-directory-pathname "/tmp/lem-ucd/"))))

(defun local-path (key)
  (merge-pathnames (format nil "~(~A~).txt" key) (ucd-dir)))

(defun ensure-file (key)
  (let ((path (local-path key)))
    (unless (probe-file path)
      (ensure-directories-exist path)
      (format *error-output* "downloading ~A~%" (getf *urls* key))
      (uiop:run-program (list "curl" "-fsSL" "-o" (namestring path)
                              (getf *urls* key))
                        :output t :error-output t))
    path))

(defun strip-comment (line)
  (let ((hash (position #\# line)))
    (string-trim " " (if hash (subseq line 0 hash) line))))

(defun parse-code-range (field)
  "FIELD is either \"XXXX\" or \"XXXX..YYYY\"; return (values start end)."
  (let ((dots (search ".." field)))
    (if dots
        (values (parse-integer field :end dots :radix 16)
                (parse-integer field :start (+ dots 2) :radix 16))
        (let ((n (parse-integer field :radix 16)))
          (values n n)))))

(defun collect-ranges (path predicate)
  "Walk the UCD file at PATH.  For every data line whose (code-range . value)
splits pass PREDICATE (called with the string VALUE), collect its (start end)."
  (let ((ranges '()))
    (uiop:with-input-file (in path)
      (loop :for line := (read-line in nil nil)
            :while line
            :for body := (strip-comment line)
            :when (plusp (length body))
            :do (let ((semi (position #\; body)))
                  (when semi
                    (let ((code (string-trim " " (subseq body 0 semi)))
                          (value (string-trim " " (subseq body (1+ semi)))))
                      (when (funcall predicate value)
                        (multiple-value-bind (start end) (parse-code-range code)
                          (push (list start end) ranges))))))))
    ranges))

(defun unicode-version (path)
  "Extract e.g. 17.0.0 from the first header line of PATH."
  (uiop:with-input-file (in path)
    (let ((line (read-line in nil "")))
      (let ((start (position-if #'digit-char-p line)))
        (if start
            (string-right-trim
             "."
             (subseq line start
                     (position-if-not (lambda (c) (or (digit-char-p c) (char= c #\.)))
                                      line :start start)))
            "unknown")))))

(defun merge-ranges (ranges)
  "Sort and coalesce a list of (start end) into non-overlapping, adjacent-merged
ascending ranges."
  (let ((sorted (sort (copy-list ranges) #'< :key #'first))
        (result '()))
    (dolist (r sorted)
      (destructuring-bind (start end) r
        (if (and result (<= start (1+ (second (first result)))))
            (setf (second (first result)) (max end (second (first result))))
            (push (list start end) result))))
    (nreverse result)))

(defun format-table (stream ranges)
  "Write RANGES as the body of a (vector ...) form, four ranges per line."
  (format stream "  (vector")
  (loop :for r :in ranges
        :for i :from 0
        :do (when (zerop (mod i 4))
              (format stream "~%   "))
            (format stream " '(#x~x #x~x)" (first r) (second r)))
  (format stream ")"))

(defun main ()
  (let* ((eaw-path (ensure-file :eaw))
         (dgc-path (ensure-file :dgc))
         (emoji-path (ensure-file :emoji))
         (version (unicode-version eaw-path))
         ;; East_Asian_Width W or F -> wide
         (wide-raw (collect-ranges eaw-path
                                   (lambda (v) (or (string= v "W") (string= v "F")))))
         ;; Emoji_Presentation=Yes -> wide
         (emoji-raw (collect-ranges emoji-path
                                    (lambda (v) (string= v "Emoji_Presentation"))))
         ;; East_Asian_Width A -> ambiguous
         (ambiguous-raw (collect-ranges eaw-path
                                        (lambda (v) (string= v "A"))))
         ;; general category Mn or Me -> zero width
         (zero-raw (collect-ranges dgc-path
                                   (lambda (v) (or (string= v "Mn") (string= v "Me")))))
         (wide (merge-ranges (append wide-raw emoji-raw)))
         (ambiguous (merge-ranges ambiguous-raw))
         ;; ZERO WIDTH JOINER (U+200D, category Cf) must be width 0 for emoji ZWJ
         ;; sequences to align; add it explicitly since it is not Mn/Me.
         (zero (merge-ranges (cons (list #x200d #x200d) zero-raw)))
         (out (merge-pathnames "../src/common/character/eastasian.lisp"
                               (or *load-pathname* *default-pathname-defaults*))))
    (with-open-file (s out :direction :output :if-exists :supersede
                           :if-does-not-exist :create)
      (format s ";;;; This file is GENERATED by scripts/gen-eastasian.lisp -- do not edit by hand.~%")
      (format s ";;;; Unicode Character Database version ~A.~%" version)
      (format s ";;;; Regenerate with: sbcl --script scripts/gen-eastasian.lisp~%")
      (format s ";;;; *eastasian-full*: East_Asian_Width W/F plus Emoji_Presentation (width 2).~%")
      (format s ";;;; *eastasian-ambiguous*: East_Asian_Width A (configurable width).~%")
      (format s ";;;; *zero-width*: general category Mn/Me plus ZWJ U+200D (width 0).~%")
      (format s "(defpackage :lem/common/character/eastasian~%")
      (format s "  (:use :cl)~%")
      (format s "  (:export :eastasian-code-p~%")
      (format s "           :ambiguous-code-p~%")
      (format s "           :zero-width-code-p))~%")
      (format s "(in-package :lem/common/character/eastasian)~%~%")
      (format s "(eval-when (:compile-toplevel :load-toplevel :execute)~%")
      (format s "  (defparameter *eastasian-full*~%")
      (format-table s wide)
      (format s ")~%~%")
      (format s "  (defparameter *eastasian-ambiguous*~%")
      (format-table s ambiguous)
      (format s ")~%~%")
      (format s "  (defparameter *zero-width*~%")
      (format-table s zero)
      (format s ")~%~%")
      (format s "  (defun gen-binary-search-function (vector code)~%")
      (format s "    (declare (optimize (speed 0) (safety 3) (debug 3)))~%")
      (format s "    (labels ((rec (begin end)~%")
      (format s "               (when (<= begin end)~%")
      (format s "                 (let* ((i (floor (+ end begin) 2))~%")
      (format s "                        (elt (aref vector i))~%")
      (format s "                        (a (car elt))~%")
      (format s "                        (b (cadr elt))~%")
      (format s "                        (then (rec begin (1- i)))~%")
      (format s "                        (else (rec (1+ i) end)))~%")
      (format s "                   `(if (<= ,a ,code ,b)~%")
      (format s "                        t~%")
      (format s "                        ,(if (or then else)~%")
      (format s "                             `(if (< ,code ,a)~%")
      (format s "                                  ,then~%")
      (format s "                                  ,else)))))))~%")
      (format s "      (rec 0 (1- (length vector))))))~%~%")
      (dolist (spec '((%eastasian-code-p *eastasian-full* eastasian-code-p
                       "Return true when CODE has East_Asian_Width W or F (display width 2).")
                      (%ambiguous-code-p *eastasian-ambiguous* ambiguous-code-p
                       "Return true when CODE has East_Asian_Width A (ambiguous width).")
                      (%zero-width-code-p *zero-width* zero-width-code-p
                       "Return true when CODE is a combining mark (Mn/Me) or ZWJ (display width 0).")))
        (destructuring-bind (macro table fn doc) spec
          (format s "(defmacro ~(~A~) (code)~%" macro)
          (format s "  (let ((g-code (gensym \"CODE\")))~%")
          (format s "    `(let ((,g-code ,code))~%")
          (format s "       (declare (optimize (speed 3) (safety 0) (debug 0))~%")
          (format s "                (fixnum ,g-code ,code))~%")
          (format s "       ,(gen-binary-search-function ~(~A~) g-code))))~%~%" table)
          (format s "(defun ~(~A~) (code)~%" fn)
          (format s "  ~S~%" doc)
          (format s "  (~(~A~) code))~%~%" macro))))
    (format t "wrote ~A (Unicode ~A): ~D wide, ~D ambiguous, ~D zero-width ranges~%"
            (namestring out) version (length wide) (length ambiguous) (length zero))))

(main)
