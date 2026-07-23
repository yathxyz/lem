(in-package :lem-yath)

(define-major-mode lem-yath-orderless-test-mode ()
    (:name "OrderlessTest"))

(defvar *orderless-test-request-count* 0)
(defvar *orderless-test-callbacks* (make-hash-table :test 'equal))

(defun orderless-test-report (control &rest arguments)
  (with-open-file (stream (uiop:getenv "LEM_YATH_ORDERLESS_COMPLETION_REPORT")
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun orderless-test-buffer-text ()
  (points-to-string (buffer-start-point (current-buffer))
                    (buffer-end-point (current-buffer))))

(defun orderless-test-reset-current-buffer ()
  (lem/completion-mode:completion-end)
  (auto-completion-cancel-timer)
  (setf *auto-completion-context* nil
        *orderless-test-request-count* 0)
  (clrhash *orderless-test-callbacks*)
  (change-buffer-mode (current-buffer) 'lem-yath-orderless-test-mode)
  (setf (variable-value 'lem/language-mode:completion-spec
                        :buffer (current-buffer))
        nil)
  (erase-buffer (current-buffer)))

(defun orderless-test-range (point)
  (multiple-value-list (auto-completion-symbol-bounds point)))

(defun orderless-test-item (label filter-text insert-text start end)
  (lem/completion-mode:make-completion-item
   :label label
   :filter-text filter-text
   :insert-text insert-text
   :detail "Orderless fixture"
   :start start
   :end end
   :accept-action
   (lambda ()
     (orderless-test-report "ACCEPT label=~a buffer=~a"
                            label
                            (orderless-test-buffer-text)))))

(defun orderless-test-large-batch (point)
  (destructuring-bind (start end input)
      (orderless-test-range point)
    (declare (ignore input))
    (loop :for index :from 0 :below 120
          :collect
          (if (= index 119)
              (orderless-test-item
               "TARGET-BEYOND-100"
               "alpha special target ("
               "accepted_beyond_cap"
               start end)
              (orderless-test-item
               (format nil "CANDIDATE-~3,'0d" index)
               (format nil "alpha ordinary filler ~3,'0d" index)
               (format nil "alpha_candidate_~3,'0d" index)
               start end)))))

(defun orderless-test-sync-provider (point)
  (destructuring-bind (start end input)
      (orderless-test-range point)
    (declare (ignore start end))
    (incf *orderless-test-request-count*)
    (orderless-test-report "REQUEST sync input=~s count=~d"
                           input *orderless-test-request-count*))
  (orderless-test-large-batch point))

(define-command lem-yath-test-orderless-sync-setup () ()
  (orderless-test-reset-current-buffer)
  (setf (variable-value 'lem/language-mode:completion-spec
                        :buffer (current-buffer))
        #'orderless-test-sync-provider)
  (orderless-test-report "SETUP sync"))

(defun orderless-test-character-fold-provider (point)
  (destructuring-bind (start end input)
      (orderless-test-range point)
    (incf *orderless-test-request-count*)
    (orderless-test-report "REQUEST fold input=~s count=~d"
                           input *orderless-test-request-count*)
    (list
     (orderless-test-item
      "CAFÉ-TARGET" "café résumé" "folded_identity" start end)
     (orderless-test-item
      "CAFE-DECOY" "cafe ordinary" "plain_decoy" start end))))

(define-command lem-yath-test-orderless-character-fold-setup () ()
  (orderless-test-reset-current-buffer)
  (setf (variable-value 'lem/language-mode:completion-spec
                        :buffer (current-buffer))
        #'orderless-test-character-fold-provider)
  (orderless-test-report "SETUP fold"))

(defun orderless-test-async-items (point)
  (destructuring-bind (start end input)
      (orderless-test-range point)
    (declare (ignore input))
    (list
     (orderless-test-item
      "ASYNC-FROZEN"
      "asyn frozen target"
      "async_frozen_insert"
      start end)
     (orderless-test-item
      "ASYNC-OTHER"
      "asyn ordinary candidate"
      "async_other_insert"
      start end))))

(defun orderless-test-async-provider (point then)
  (destructuring-bind (start end input)
      (orderless-test-range point)
    (declare (ignore start end))
    (incf *orderless-test-request-count*)
    (orderless-test-report "REQUEST async input=~s count=~d"
                           input *orderless-test-request-count*)
    (if (string= input "asy")
        (funcall then (orderless-test-async-items point))
        (setf (gethash input *orderless-test-callbacks*) then))))

(define-command lem-yath-test-orderless-async-setup () ()
  (orderless-test-reset-current-buffer)
  (setf (variable-value 'lem/language-mode:completion-spec
                        :buffer (current-buffer))
        (lem/completion-mode:make-completion-spec
         #'orderless-test-async-provider :async t))
  (orderless-test-report "SETUP async"))

(define-command lem-yath-test-orderless-deliver-stale () ()
  (alexandria:when-let ((callback
                         (gethash "asyn" *orderless-test-callbacks*)))
    (orderless-test-report "DELIVER stale input=asyn")
    (funcall
     callback
     (list
      (lem/completion-mode:make-completion-item
       :label "ASYNC-STALE-RESPONSE"
       :filter-text "asyn stale target"
       :insert-text "async_stale_insert")))))

(defun orderless-test-manual-provider (point)
  (destructuring-bind (start end input)
      (orderless-test-range point)
    (incf *orderless-test-request-count*)
    (orderless-test-report "REQUEST manual input=~s count=~d"
                           input *orderless-test-request-count*)
    (list
     (orderless-test-item
      "MANUAL-SPECIAL" "manual special" "manA" start end)
     (orderless-test-item
      "MANUAL-OTHER" "manual ordinary" "manB" start end))))

(define-command lem-yath-test-orderless-manual-setup () ()
  (orderless-test-reset-current-buffer)
  (insert-string (current-point) "man")
  (lem/completion-mode:run-completion #'orderless-test-manual-provider)
  (orderless-test-report "SETUP manual"))

(defun orderless-test-range-provider (point)
  (incf *orderless-test-request-count*)
  (orderless-test-report "REQUEST range count=~d"
                         *orderless-test-request-count*)
  (with-point ((explicit-start (buffer-start-point (point-buffer point)))
               (explicit-end (buffer-end-point (point-buffer point))))
    (character-offset explicit-start 2)
    (list
     (orderless-test-item
      "RANGE-EXPLICIT"
      "token first"
      "first_explicit"
      explicit-start explicit-end)
     (orderless-test-item
      "RANGE-NIL"
      "token second"
      "nil_second"
      nil nil))))

(define-command lem-yath-test-orderless-range-setup () ()
  (orderless-test-reset-current-buffer)
  (insert-string (current-point) "XXtoken SUFFIX")
  (buffer-start (current-point))
  (character-offset (current-point) 7)
  (lem/completion-mode:run-completion #'orderless-test-range-provider)
  (orderless-test-report "SETUP range"))

(defun orderless-test-lisp-provider (point)
  (destructuring-bind (start end input)
      (orderless-test-range point)
    (incf *orderless-test-request-count*)
    (orderless-test-report "REQUEST lisp input=~s count=~d"
                           input *orderless-test-request-count*)
    (list
     (orderless-test-item
      "LISP-FIRST" "alp first" "alp-one" start end)
     (orderless-test-item
      "LISP-SECOND" "alp second" "alp-two" start end))))

(define-command lem-yath-test-orderless-lisp-close-setup () ()
  (orderless-test-reset-current-buffer)
  (change-buffer-mode (current-buffer) 'lem-lisp-mode:lisp-mode)
  (lem-paredit-mode:paredit-mode t)
  (insert-string (current-point) "(alpX)")
  (buffer-start (current-point))
  (character-offset (current-point) 4)
  (lem/completion-mode:run-completion #'orderless-test-lisp-provider)
  (orderless-test-report
   "SETUP lisp-close paredit=~s"
   (mode-active-p (current-buffer) 'lem-paredit-mode:paredit-mode)))

(define-command lem-yath-test-report-orderless-lisp-state () ()
  (orderless-test-report
   "LISP-STATE buffer=~a point=~d paredit=~s context=~s requests=~d"
   (orderless-test-buffer-text)
   (position-at-point (current-point))
   (mode-active-p (current-buffer) 'lem-paredit-mode:paredit-mode)
   (not (null lem/completion-mode::*completion-context*))
   *orderless-test-request-count*))

(define-command lem-yath-test-orderless-category-setup () ()
  (orderless-test-reset-current-buffer)
  (alexandria:when-let ((directory
                         (uiop:getenv "LEM_YATH_ORDERLESS_FILE_DIR")))
    (setf (buffer-directory) directory))
  (let ((source
          (or (get-buffer "*orderless-category-source*")
              (make-buffer "*orderless-category-source*"))))
    (change-buffer-mode source 'lem-yath-orderless-test-mode)
    (with-current-buffer source
      (erase-buffer source)
      (insert-string (buffer-point source)
                     (format nil "abcDabbrevCandidate~%"))))
  (orderless-test-report "SETUP category directory=~a" (buffer-directory)))

(define-command lem-yath-test-orderless-file-setup () ()
  (orderless-test-reset-current-buffer)
  (alexandria:when-let ((directory
                         (uiop:getenv "LEM_YATH_ORDERLESS_FILE_DIR")))
    (setf (buffer-directory) directory))
  (orderless-test-report "SETUP file directory=~a" (buffer-directory)))

(define-command lem-yath-test-orderless-prompt () ()
  (dolist (name '("orderless-prompt-alpha" "orderless-prompt-beta"))
    (unless (get-buffer name)
      (make-buffer name)))
  (let ((choice (prompt-for-buffer "Orderless prompt: " :existing t)))
    (orderless-test-report "PROMPT result=~s" choice)))

(define-command lem-yath-test-report-orderless-state () ()
  (let ((context lem/completion-mode::*completion-context*))
    (if context
        (let* ((popup (lem/completion-mode::context-popup-menu context))
               (focus (and popup (lem/popup-menu:get-focus-item popup))))
          (orderless-test-report
           "STATE local=~s filter=~s separator=~s raw=~d items=~d popup=~s input=~a buffer=~a requests=~d focus=~a"
           (lem/completion-mode::context-local-filtering-p context)
           (not (null (lem/completion-mode::context-filter-function context)))
           (not (null (lem/completion-mode::context-separator context)))
           (length (lem/completion-mode::context-raw-items context))
           (length (lem/completion-mode::context-last-items context))
           (not (null popup))
           (or (lem/completion-mode::completion-context-input context) "")
           (orderless-test-buffer-text)
           *orderless-test-request-count*
           (if focus
               (lem/completion-mode:completion-item-label focus)
               "NONE")))
        (orderless-test-report
         "STATE none buffer=~a requests=~d"
         (orderless-test-buffer-text)
         *orderless-test-request-count*))))

(define-command lem-yath-test-orderless-static-checks () ()
  (let ((failures 0))
    (labels ((check (condition label)
               (orderless-test-report "~a STATIC ~a"
                                      (if condition "PASS" "FAIL")
                                      label)
               (unless condition
                 (incf failures)))
             (same (expected actual label)
               (check (equal expected actual) label)))
      (handler-case
          (progn
            (same '("FooBar" "foobar" "barfoo")
                  (orderless-filter
                   "foo" '("FooBar" "foobar" "barfoo"))
                  "smart-case-lower-is-folded")
            (same '("FooBar" "barFoo")
                  (orderless-filter
                   "Foo" '("FooBar" "foobar" "barFoo"))
                  "smart-case-uppercase-is-sensitive")
            (same '("alpha-beta" "beta-alpha")
                  (orderless-filter
                   "beta alpha"
                   '("alpha-beta" "beta-alpha" "alpha-only"))
                  "components-match-in-any-order")
            (same '("alpha" "alphabet")
                  (orderless-filter
                   "alp pha" '("alpha" "alphabet" "alpine"))
                  "components-may-overlap")
            (same '("item42")
                  (orderless-filter
                   "item[0-9]+" '("item42" "itemx"))
                  "valid-regexp-alternative")
            (same '("left[bracket")
                  (orderless-filter "[" '("left[bracket" "plain"))
                  "invalid-regexp-falls-back-to-literal")
            (let ((query (format nil "foo~c bar baz" #\\)))
              (same '("foo bar" "baz")
                    (orderless-split-query query)
                    "escaped-space-remains-in-component")
              (same '("foo bar baz")
                    (orderless-filter
                     query '("foo bar baz" "foo-bar-baz"))
                    "escaped-space-matches-literally"))
            (let ((query (format nil "foo~c~c bar baz" #\\ #\\)))
              (same (list (format nil "foo~c~c" #\\ #\\) "bar" "baz")
                    (orderless-split-query query)
                    "paired-backslashes-preserved-before-separator"))
            (let ((query
                    (format nil "foo~c~c~c bar baz" #\\ #\\ #\\)))
              (same (list (format nil "foo~c~c bar" #\\ #\\) "baz")
                    (orderless-split-query query)
                    "paired-backslashes-preserved-before-escaped-space"))
            (same '("foo-bar" "fiber")
                  (orderless-filter
                   "~fbr" '("foo-bar" "fiber" "far"))
                  "flex-dispatch")
            (same '("café" "cafe" "CAFÉ" "cafeteria")
                  (orderless-filter
                   "%cafe" '("café" "cafe" "CAFÉ" "cafeteria"))
                  "character-fold-diacritics")
            (same '("Café" "Cafe")
                  (orderless-filter
                   "%Cafe" '("Café" "CAFÉ" "café" "Cafe" "cafe"))
                  "character-fold-preserves-smart-case")
            (let ((decomposed (format nil "cafe~c" (code-char #x301))))
              (same (list decomposed "café")
                    (orderless-filter
                     "%café" (list decomposed "café" "cafe"))
                    "character-fold-preserves-query-diacritics"))
            (same '("Ångström" "angstrom" "Angstrom" "ångström")
                  (orderless-filter
                   "angstrom%"
                   '("Ångström" "angstrom" "Angstrom" "ångström"))
                  "character-fold-suffix-dispatch")
            (same '("ﬂower" "flower")
                  (orderless-filter "%flower" '("ﬂower" "flower"))
                  "character-fold-compatibility")
            (same '("café")
                  (orderless-filter "%café" '("café" "cafe"))
                  "character-fold-is-directional")
            (same '("aether")
                  (orderless-filter "%aether" '("Æther" "aether"))
                  "character-fold-does-not-invent-ae")
            (same '("strasse")
                  (orderless-filter "%strasse" '("Straße" "strasse"))
                  "character-fold-does-not-invent-ss")
            (same '("a.b")
                  (orderless-filter "%." '("a.b" "axb"))
                  "character-fold-is-literal")
            (same '("\"hello" "“hello”" "«hello»")
                  (orderless-filter
                   "%\"hello"
                   '("\"hello" "“hello”" "'hello'" "«hello»"))
                  "character-fold-double-quotes")
            (same '("'hello'" "‘hello’" "‹hello›")
                  (orderless-filter
                   "%'hello"
                   '("\"hello" "'hello'" "‘hello’" "‹hello›"))
                  "character-fold-single-quotes")
            (same '("‘hello’" "`hello")
                  (orderless-filter
                   "%`hello" '("'hello'" "‘hello’" "`hello"))
                  "character-fold-backtick")
            (same '("“hello”")
                  (orderless-filter "%“hello" '("\"hello" "“hello”"))
                  "character-fold-punctuation-is-directional")
            (same '("f.o")
                  (orderless-filter "=f.o" '("f.o" "fao"))
                  "literal-dispatch")
            (same '("foobar")
                  (orderless-filter "^foo" '("foobar" "afoo"))
                  "prefix-dispatch")
            (same '("foo-bar" "fizz_buzz")
                  (orderless-filter
                   ",fb" '("foo-bar" "fizz_buzz" "foobar"))
                  "initialism-dispatch")
            (same '("alpha-beta-charlie")
                  (orderless-filter
                   ",ac"
                   '("alpha-beta-charlie" "alpha-beta" "beta-charlie"))
                  "initialism-is-subsequence-of-word-initials")
            (same '("alpha" "gamma")
                  (orderless-filter
                   "!beta" '("alpha" "beta-value" "gamma"))
                  "negation-dispatch")
            (same '("beta-value")
                  (orderless-filter
                   "!!beta" '("alpha" "beta-value" "gamma"))
                  "recursive-negation-dispatch")
            (same '("foobar")
                  (orderless-filter "foo^" '("foobar" "afoo"))
                  "suffix-dispatch")
            (let* ((target
                     (lem/completion-mode:make-completion-item
                      :label "DISPLAY-NO-MATCH"
                      :filter-text "alpha special target"
                      :insert-text "insert_identity"))
                   (label-decoy
                     (lem/completion-mode:make-completion-item
                      :label "special-label"
                      :filter-text "irrelevant"
                      :insert-text "decoy"))
                   (matches
                     (orderless-filter-completion-items
                      "special" (list target label-decoy))))
              (check (equal matches (list target))
                     "filtering-uses-filter-text-not-label")
              (check
               (string= "insert_identity"
                        (lem/completion-mode:completion-item-insert-text
                         (first matches)))
               "filtering-preserves-item-insertion-identity")))
        (error (condition)
          (orderless-test-report "FAIL STATIC unhandled-error=~a" condition)
          (incf failures)))
      (orderless-test-report "SUMMARY STATIC ~a failures=~d"
                             (if (zerop failures) "PASS" "FAIL")
                             failures))))

(define-key lem/completion-mode::*completion-mode-keymap*
  "F5" 'lem-yath-test-report-orderless-state)
(define-key lem/completion-mode::*completion-mode-keymap*
  "F6" 'lem-yath-test-orderless-deliver-stale)
(define-key lem/completion-mode::*completion-mode-keymap*
  "F7" 'lem-yath-test-report-orderless-lisp-state)
(define-key lem-vi-mode:*insert-keymap*
  "F5" 'lem-yath-test-report-orderless-state)
(define-key lem-vi-mode:*insert-keymap*
  "F6" 'lem-yath-test-orderless-deliver-stale)
(define-key lem-vi-mode:*insert-keymap*
  "F7" 'lem-yath-test-report-orderless-lisp-state)
(define-key lem-vi-mode:*normal-keymap*
  "F5" 'lem-yath-test-report-orderless-state)
(define-key lem-vi-mode:*normal-keymap*
  "F7" 'lem-yath-test-report-orderless-lisp-state)
(define-key lem/prompt-window::*prompt-mode-keymap*
  "F5" 'lem-yath-test-report-orderless-state)
(pushnew 'lem-yath-test-report-orderless-state
         *auto-completion-continue-commands*)
(pushnew 'lem-yath-test-orderless-deliver-stale
         *auto-completion-continue-commands*)
(pushnew 'lem-yath-test-report-orderless-lisp-state
         *auto-completion-continue-commands*)
