;;;; Orderless matching for ordinary in-buffer completion.
;;;;
;;;; This ports the configured portable subset of Orderless defaults: escaped
;;;; space components, whole-pattern smart case, literal-or-regexp matching,
;;;; and the ~ = ^ ! , affix dispatchers.  Emacs regexp syntax is broader than
;;;; CL-PPCRE, while the pinned package's % character-fold and & annotation
;;;; dispatchers need metadata Lem does not currently expose; those differences
;;;; are tracked explicitly in the parity ledger.

(in-package :lem-yath)

(defparameter *orderless-affix-dispatchers* "~=^!,")

(defun orderless-split-query (query)
  "Split QUERY on spaces, preserving spaces escaped by odd backslash runs."
  (let ((components '())
        (current (make-string-output-stream))
        (index 0)
        (query-length (length (or query ""))))
    (labels ((finish-component ()
               (let ((component (get-output-stream-string current)))
                 (unless (zerop (length component))
                   (push component components)))
               (setf current (make-string-output-stream)))
             (write-backslashes (count)
               (loop :repeat count :do (write-char #\\ current))))
      (loop :while (< index query-length)
            :for character := (char query index)
            :do
               (cond
                 ((char= character #\\)
                  (let ((run-start index))
                    (loop :while (and (< index query-length)
                                      (char= (char query index) #\\))
                          :do (incf index))
                    (let ((count (- index run-start)))
                      (if (and (< index query-length)
                               (char= (char query index) #\Space))
                          (progn
                            (write-backslashes
                             (if (oddp count) (1- count) count))
                            (if (oddp count)
                                (write-char #\Space current)
                                (finish-component))
                            (incf index))
                          (write-backslashes count)))))
                 ((char= character #\Space)
                  (finish-component)
                  (incf index))
                 (t
                  (write-char character current)
                  (incf index))))
      (finish-component)
      (nreverse components))))

(defun orderless-case-sensitive-p (query)
  (some #'upper-case-p (or query "")))

(defun orderless-character-test (case-sensitive-p)
  (if case-sensitive-p #'char= #'char-equal))

(defun orderless-literal-matcher (component case-sensitive-p)
  (let ((test (orderless-character-test case-sensitive-p)))
    (lambda (candidate)
      (not (null (search component candidate :test test))))))

(defun orderless-regexp-scanner (component case-sensitive-p)
  (handler-case
      (ppcre:create-scanner
       component :case-insensitive-mode (not case-sensitive-p))
    (error () nil)))

(defun orderless-default-matcher (component case-sensitive-p)
  (let ((literal (orderless-literal-matcher component case-sensitive-p))
        (scanner (orderless-regexp-scanner component case-sensitive-p)))
    (lambda (candidate)
      (or (funcall literal candidate)
          (and scanner (not (null (ppcre:scan scanner candidate))))))))

(defun orderless-prefix-matcher (component case-sensitive-p)
  (let ((test (orderless-character-test case-sensitive-p)))
    (lambda (candidate)
      (eql 0 (search component candidate :test test)))))

(defun orderless-flex-matcher (component case-sensitive-p)
  (let ((test (orderless-character-test case-sensitive-p)))
    (lambda (candidate)
      (loop :with candidate-index := 0
            :for component-character :across component
            :for match := (position component-character candidate
                                    :start candidate-index
                                    :test test)
            :unless match :do (return nil)
            :do (setf candidate-index (1+ match))
            :finally (return t)))))

(defun orderless-initials (candidate)
  (coerce
   (loop :for index :from 0 :below (length candidate)
         :for character := (char candidate index)
         :when (and (alphanumericp character)
                    (or (zerop index)
                        (not (alphanumericp
                              (char candidate (1- index))))))
           :collect character)
   'string))

(defun orderless-initialism-matcher (component case-sensitive-p)
  (let ((matcher (orderless-flex-matcher component case-sensitive-p)))
    (lambda (candidate)
      (funcall matcher (orderless-initials candidate)))))

(defun orderless-dispatcher-p (character)
  (find character *orderless-affix-dispatchers* :test #'char=))

(defun orderless-component-dispatch (component)
  "Return COMPONENT's dispatcher and body; prefix dispatch wins over suffix."
  (let ((component-length (length component)))
    (cond
      ((and (= component-length 1)
            (orderless-dispatcher-p (char component 0)))
       (values nil nil))
      ((and (plusp component-length)
            (orderless-dispatcher-p (char component 0)))
       (values (char component 0) (subseq component 1)))
      ((and (plusp component-length)
            (orderless-dispatcher-p
             (char component (1- component-length))))
       (values (char component (1- component-length))
               (subseq component 0 (1- component-length))))
      (t
       (values nil component)))))

(defun orderless-compile-component (component case-sensitive-p)
  (multiple-value-bind (dispatcher body)
      (orderless-component-dispatch component)
    (cond
      ((null body) nil)
      ((null dispatcher)
       (orderless-default-matcher body case-sensitive-p))
      ((char= dispatcher #\=)
       (orderless-literal-matcher body case-sensitive-p))
      ((char= dispatcher #\^)
       (orderless-prefix-matcher body case-sensitive-p))
      ((char= dispatcher #\~)
       (orderless-flex-matcher body case-sensitive-p))
      ((char= dispatcher #\,)
       (orderless-initialism-matcher body case-sensitive-p))
      ((char= dispatcher #\!)
       (let ((matcher (orderless-compile-component body case-sensitive-p)))
         (if matcher
             (lambda (candidate) (not (funcall matcher candidate)))
             (lambda (candidate)
               (declare (ignore candidate))
               nil)))))))

(defun orderless-filter (query candidates &key (key #'identity))
  "Return CANDIDATES matching every QUERY component, preserving their order."
  (let* ((case-sensitive-p (orderless-case-sensitive-p query))
         (matchers
           (remove nil
                   (mapcar
                    (lambda (component)
                      (orderless-compile-component
                       component case-sensitive-p))
                    (orderless-split-query query)))))
    (if (null matchers)
        candidates
        (remove-if-not
         (lambda (candidate)
           (let ((text (funcall key candidate)))
             (every (lambda (matcher) (funcall matcher text)) matchers)))
         candidates))))

(defun orderless-filter-completion-items (query items)
  (orderless-filter
   query items :key #'lem/completion-mode:completion-item-filter-text))
