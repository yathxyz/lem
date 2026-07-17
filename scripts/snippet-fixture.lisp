(in-package :lem-yath)

(defvar *snippet-test-report-path*
  (uiop:getenv "LEM_YATH_SNIPPET_TEST_REPORT"))

(defvar *snippet-test-org-buffer* nil)

(declaim (ftype function snippet-test-report snippet-test-hex))

(defun snippet-test-format-table-vector (tables)
  (format nil "(~{~a~^ ~})" tables))

(defun snippet-test-ancestry-case (label mode expected &optional filename)
  (let ((buffer
          (make-buffer (format nil " *snippet-ancestry-~a*" label)
                       :temporary t)))
    (unwind-protect
         (progn
           (when filename
             (setf (buffer-filename buffer)
                   (merge-pathnames
                    filename
                    (uiop:ensure-directory-pathname
                     (uiop:getenv "WORKDIR")))))
           (change-buffer-mode buffer mode)
           (let* ((actual (snippet-table-names buffer))
                  (matches-p (equal actual expected)))
             (snippet-test-report
              "ANCESTRY label=~a actual=~a expected=~a ok=~a"
              label
              (snippet-test-format-table-vector actual)
              (snippet-test-format-table-vector expected)
              (if matches-p "yes" "no"))
             matches-p))
      (delete-buffer buffer))))

(defun snippet-test-verify-ancestry ()
  ;; Construct the result list eagerly so every mismatch is reported instead
  ;; of stopping at the first false value.
  (every
   #'identity
   (list
    (snippet-test-ancestry-case
     "c" 'lem-c-mode:c-mode
     '("c-mode" "prog-mode" "cc-mode" "c-lang-common"
       "fundamental-mode"))
    (snippet-test-ancestry-case
     "typescript" 'lem-typescript-mode:typescript-mode
     '("typescript-mode" "js-mode" "prog-mode" "fundamental-mode"))
    (snippet-test-ancestry-case
     "html" 'lem-html-mode:html-mode
     '("html-mode" "nxml-mode" "text-mode" "fundamental-mode"))
    (snippet-test-ancestry-case
     "xml" 'lem-xml-mode:xml-mode
     '("nxml-mode" "text-mode" "fundamental-mode"))
    (snippet-test-ancestry-case
     "makefile" 'lem-makefile-mode:makefile-mode
     '("makefile-gmake-mode" "makefile-mode" "prog-mode"
       "fundamental-mode")
     "Makefile")
    (snippet-test-ancestry-case
     "cpp-filename" 'lem/buffer/fundamental-mode:fundamental-mode
     '("c++-mode" "prog-mode" "cc-mode" "c-lang-common"
       "fundamental-mode")
     "fixture.cpp")
    (snippet-test-ancestry-case
     "bib-filename" 'lem/buffer/fundamental-mode:fundamental-mode
     '("bibtex-mode" "fundamental-mode")
     "fixture.bib")
    (snippet-test-ancestry-case
     "tex-filename" 'lem/buffer/fundamental-mode:fundamental-mode
     '("latex-mode" "tex-mode" "text-mode" "fundamental-mode")
     "fixture.tex")
    (snippet-test-ancestry-case
     "run-shell" 'lem-shell-mode::run-shell-mode
     '("run-shell-mode" "fundamental-mode")))))

(defun snippet-test-audit-community-corpus ()
  (let* ((fixture-root
           (uiop:ensure-directory-pathname
            (first (uiop:split-string (uiop:getenv "LEM_YATH_SNIPPET_DIRS")
                                      :separator '(#\:)))))
         (templates
           (loop :with largest = nil
                 :for root :in (snippet-root-directories)
                 :unless (uiop:pathname-equal root fixture-root)
                   :do (let ((parsed
                               (remove nil
                                       (mapcar
                                        (lambda (pathname)
                                          (snippet-parse-definition
                                           pathname "audit"))
                                        (snippet-directory-files-recursively
                                         root)))))
                         (when (> (length parsed) (length largest))
                           (setf largest parsed)))
                 :finally (return largest)))
         (supported (count-if #'snippet-template-supported-p templates))
         (unsupported (- (length templates) supported))
         (choice-templates
           (remove-if-not
            (lambda (template)
              (search "yas-choose-value" (snippet-template-body template)))
            templates)))
    (snippet-test-report
     "CORPUS total=~d supported=~d unsupported=~d safe-backquote=~d safe-condition=~d safe-choice=~d"
     (length templates) supported unsupported
     (count-if
      (lambda (template)
        (and (snippet-template-supported-p template)
             (find #\` (snippet-template-body template))))
      templates)
     (count-if
      (lambda (template)
        (and (snippet-template-supported-p template)
             (snippet-template-condition-policy template)))
      templates)
     (count-if #'snippet-template-supported-p choice-templates))
    (dolist (template choice-templates)
      (snippet-test-report
       "CORPUS-CHOICE name=~a supported=~a reason=~a path=~a"
       (snippet-template-name template)
       (if (snippet-template-supported-p template) "yes" "no")
       (or (snippet-template-unsupported-reason template) "none")
       (snippet-template-pathname template)))
    (dolist (reason (remove-duplicates
                     (remove nil
                             (mapcar #'snippet-template-unsupported-reason
                                     templates))
                     :test #'string=))
      (snippet-test-report
       "CORPUS-REASON count=~d reason=~a"
       (count reason templates :key #'snippet-template-unsupported-reason
                                :test #'equal)
       reason))
    (dolist (template templates)
      (when (equal (snippet-template-unsupported-reason template)
                   "unsupported backquoted Emacs Lisp")
        (snippet-test-report "CORPUS-UNSUPPORTED name=~a path=~a"
                             (snippet-template-name template)
                             (snippet-template-pathname template))))))

(defun snippet-test-safe-dynamic-oracle ()
  (let ((buffer (make-buffer " *snippet-dynamic-oracle*" :temporary t)))
    (unwind-protect
         (handler-case
             (let* ((root (uiop:ensure-directory-pathname
                           (merge-pathnames "components/"
                                            (uiop:ensure-directory-pathname
                                             (uiop:getenv "WORKDIR")))))
                    (filename (merge-pathnames "index.js" root)))
               (ensure-directories-exist filename)
               (setf (buffer-filename buffer) filename)
               (change-buffer-mode buffer 'lem-c-mode:c-mode)
               (insert-string (buffer-point buffer)
                              "using namespace std;\n")
               (let* ((point (buffer-end-point buffer))
                      (jsx (snippet-evaluate-backquote
                            "(yas-jsx-get-class-name-by-file-name)"
                            buffer point))
                      (comment (snippet-evaluate-backquote
                                "comment-start" buffer point))
                      (std-prefix (snippet-evaluate-backquote
                                   "(progn (goto-char (point-min)) (unless (re-search-forward \"^using\\\\s-+namespace std;\" nil 'no-error) \"std::\"))"
                                   buffer point))
                      (uuid (snippet-uuid-v4))
                      (clojure-buffer
                        (make-buffer " *snippet-clojure-oracle*"
                                     :temporary t)))
                 (unwind-protect
                      (progn
                        (let ((clojure-file
                                (merge-pathnames
                                 "project/src/clj/foo_bar/core.clj"
                                 (uiop:ensure-directory-pathname
                                  (uiop:getenv "WORKDIR")))))
                          (ensure-directories-exist clojure-file)
                          (setf (buffer-filename clojure-buffer)
                                clojure-file))
                        (let ((ok
                                (and
                                 (string= jsx "components")
                                 (string= comment "// ")
                                 (string= std-prefix "")
                                 (string= (snippet-clojure-namespace
                                           clojure-buffer)
                                          "foo-bar.core")
                                 (cl-ppcre:scan
                                  "^[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$"
                                  uuid)
                                 (string= (snippet-apply-transform
                                           :upcase "mixed") "MIXED")
                                 (string= (snippet-apply-transform
                                           :before-colon "Child : Parent")
                                          "Child")
                                 (string= (snippet-apply-transform
                                           :increment "9") "10")
                                 (string= (snippet-apply-transform
                                           :private-field "Title")
                                          "_title"))))
                          (snippet-test-report
                           "DYNAMIC-ORACLE ok=~a jsx=~a comment=~a clojure=~a uuid=~a std=~a upcase=~a before=~a increment=~a private=~a"
                           (if ok "yes" "no") jsx
                           (snippet-test-hex comment)
                           (snippet-clojure-namespace clojure-buffer)
                           uuid
                           (snippet-test-hex std-prefix)
                           (snippet-apply-transform :upcase "mixed")
                           (snippet-apply-transform
                            :before-colon "Child : Parent")
                           (snippet-apply-transform :increment "9")
                           (snippet-apply-transform :private-field "Title"))
                          ok))
                   (delete-buffer clojure-buffer))))
           (error (condition)
             (snippet-test-report "DYNAMIC-ORACLE ok=no error=~a" condition)
             nil))
      (delete-buffer buffer))))

(defun snippet-test-literal-choice-oracle ()
  (labels ((parse (expression)
             (multiple-value-list
              (snippet-parse-literal-choice-expression expression)))
           (refused-p (result)
             (null (first result))))
    (let* ((listed
             (parse "(yas-choose-value '(\"alpha\" \"beta\" \"\"))"))
           (flat (parse "(yas-choose-value \"one\" \"two\")"))
           (automatic
             (parse
              "(yas-auto-next (yas-choose-value '(\"first\" \"second\")))"))
           (computed
             (parse
              "(yas-choose-value (progn (touch-file) '(\"unsafe\")))"))
           (trailing
             (parse "(yas-choose-value '(\"unsafe\")) (touch-file)"))
           (unknown-escape
             (parse "(yas-choose-value '(\"bad\\q\"))"))
           (multiline
             (parse (format nil "(yas-choose-value '(\"bad~%line\"))")))
           (empty (parse "(yas-choose-value '())"))
           (oversized
             (parse
              (concatenate
               'string "(yas-choose-value '(\""
               (make-string (* 64 1024) :initial-element #\a)
               "\"))")))
           (misplaced-auto-next
             (snippet-safe-transform-reason
              "${2:$$(yas-auto-next (yas-choose-value '(\"one\" \"two\")))}"))
           (ok
             (and (equal listed '(("alpha" "beta" "") nil))
                  (equal flat '(("one" "two") nil))
                  (equal automatic '(("first" "second") t))
                  (refused-p computed)
                  (refused-p trailing)
                  (refused-p unknown-escape)
                  (refused-p multiline)
                  (refused-p empty)
                  (refused-p oversized)
                  (string= misplaced-auto-next
                           "an unsupported yas-auto-next field"))))
      (snippet-test-report
       "CHOICE-ORACLE ok=~a listed=~a flat=~a automatic=~a computed=~a trailing=~a escape=~a multiline=~a empty=~a oversized=~a misplaced-auto=~a"
       (if ok "yes" "no") (first listed) (first flat) (first automatic)
       (if (refused-p computed) "refused" "accepted")
       (if (refused-p trailing) "refused" "accepted")
       (if (refused-p unknown-escape) "refused" "accepted")
       (if (refused-p multiline) "refused" "accepted")
       (if (refused-p empty) "refused" "accepted")
       (if (refused-p oversized) "refused" "accepted")
       (or misplaced-auto-next "accepted"))
      ok)))

(defun snippet-test-switch-to-plain-buffer ()
  (let ((buffer (or (get-buffer "*snippet-test-fundamental*")
                    (make-buffer "*snippet-test-fundamental*"))))
    (unless (eq buffer (current-buffer))
      (switch-to-buffer buffer))
    buffer))

(defun snippet-test-report (control &rest arguments)
  (with-open-file (stream *snippet-test-report-path*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun snippet-test-buffer-text ()
  (points-to-string (buffer-start-point (current-buffer))
                    (buffer-end-point (current-buffer))))

(defun snippet-test-hex (string)
  (with-output-to-string (stream)
    (loop :for character :across string
          :do (format stream "~2,'0x" (char-code character)))))

(defun snippet-test-vi-state-name ()
  (let ((state (lem-vi-mode/core:current-state)))
    (cond
      ((typep state 'lem-vi-mode:insert) "insert")
      ((typep state 'lem-vi-mode:normal) "normal")
      ((typep state 'lem-vi-mode:visual) "visual")
      (t "other"))))

(defun snippet-test-current-focus-label ()
  (alexandria:when-let*
      ((context lem/completion-mode::*completion-context*)
       (popup (lem/completion-mode::context-popup-menu context))
       (item (lem/popup-menu:get-focus-item popup)))
    (lem/completion-mode:completion-item-label item)))

(defun snippet-test-end-session ()
  ;; Disabling the mode is part of its public lifecycle contract and avoids
  ;; relying on an implementation-only session destructor between scenarios.
  (when (mode-active-p (current-buffer) 'lem-yath-snippet-mode)
    (lem-yath-snippet-mode nil)))

(defun snippet-test-reset (label mode &optional text)
  (lem/completion-mode:completion-end)
  (auto-completion-cancel-timer)
  (setf *auto-completion-context* nil)
  (snippet-test-end-session)
  (when (mode-active-p (current-buffer) 'lem-paredit-mode:paredit-mode)
    (lem-paredit-mode:paredit-mode nil))
  (unless (eq (buffer-major-mode (current-buffer)) mode)
    (change-buffer-mode (current-buffer) mode))
  (setf (variable-value 'lem/language-mode:completion-spec
                        :buffer (current-buffer))
        nil)
  (setf (buffer-read-only-p (current-buffer)) nil)
  (buffer-mark-cancel (current-buffer))
  (erase-buffer (current-buffer))
  (when text
    (insert-string (current-point) text))
  (clear-buffer-edit-history (current-buffer))
  (setf (buffer-value (current-buffer) :snippet-test-label) label)
  (lem-yath-snippet-mode t)
  ;; M-x temporarily stores Vi's COMMAND state on the originating buffer.
  ;; Most setup cases change major mode and incidentally restore NORMAL; the
  ;; already-Python community buffer does not, so restore its durable state.
  (setf (lem-vi-mode/core:buffer-state (current-buffer))
        'lem-vi-mode:normal)
  (snippet-test-report "SETUP label=~a" label))

(defun snippet-test-reset-fundamental (label &optional text)
  ;; Generic fixtures must not inherit the .org filename alias from the real
  ;; private-snippet buffer used by the first scenario.
  (snippet-test-switch-to-plain-buffer)
  (snippet-test-reset
   label 'lem/buffer/fundamental-mode:fundamental-mode text))

(define-command lem-yath-test-snippet-private-setup () ()
  ;; Deliberately force Fundamental mode while retaining the real .org path so
  ;; this case continues to verify the filename fallback to org-mode snippets.
  (unless *snippet-test-org-buffer*
    (setf *snippet-test-org-buffer* (current-buffer)))
  (switch-to-buffer *snippet-test-org-buffer*)
  (snippet-test-reset
   "private-org" 'lem/buffer/fundamental-mode:fundamental-mode))

(define-command lem-yath-test-snippet-backtrack-setup () ()
  (snippet-test-reset-fundamental "backtrack"))

(define-command lem-yath-test-snippet-mirror-setup () ()
  (snippet-test-reset-fundamental "mirror"))

(define-command lem-yath-test-snippet-repeated-setup () ()
  (snippet-test-reset-fundamental "repeated"))

(define-command lem-yath-test-snippet-nested-setup () ()
  (snippet-test-reset-fundamental "nested"))

(define-command lem-yath-test-snippet-escaped-setup () ()
  (snippet-test-reset-fundamental "escaped"))

(define-command lem-yath-test-snippet-python-setup () ()
  (unless (eq (buffer-major-mode (current-buffer))
              'lem-python-mode:python-mode)
    (error "Community fixture must run in a real Python buffer"))
  (snippet-test-reset "community-python" 'lem-python-mode:python-mode))

(define-command lem-yath-test-snippet-fallback-setup () ()
  (snippet-test-reset-fundamental "fallback"))

(define-command lem-yath-test-snippet-selector-setup () ()
  (snippet-test-reset-fundamental "selector"))

(define-command lem-yath-test-snippet-dynamic-date-setup () ()
  (snippet-test-reset-fundamental "dynamic-date")
  (setf *snippet-time-function*
        (lambda () (encode-universal-time 56 34 12 9 2 2031))))

(define-command lem-yath-test-snippet-dynamic-file-setup () ()
  (snippet-test-reset-fundamental "dynamic-file")
  (setf (buffer-filename (current-buffer))
        (merge-pathnames "widget-card.js"
                         (uiop:ensure-directory-pathname
                          (uiop:getenv "WORKDIR")))))

(define-command lem-yath-test-snippet-unsafe-setup () ()
  (snippet-test-reset-fundamental "unsafe"))

(define-command lem-yath-test-snippet-transform-setup () ()
  (snippet-test-reset-fundamental "transform"))

(define-command lem-yath-test-snippet-choice-setup () ()
  (snippet-test-reset-fundamental "literal-choice"))

(define-command lem-yath-test-snippet-choice-abort-setup () ()
  (snippet-test-reset-fundamental "choice-abort"))

(define-command lem-yath-test-snippet-auto-choice-setup () ()
  (snippet-test-reset-fundamental "auto-choice"))

(define-command lem-yath-test-snippet-unsafe-choice-setup () ()
  (snippet-test-reset-fundamental "unsafe-choice"))

(define-command lem-yath-test-snippet-condition-true-setup () ()
  (switch-to-buffer
   (or (get-buffer "*snippet-test-condition-true*")
       (make-buffer "*snippet-test-condition-true*")))
  (snippet-test-reset "condition-true" 'lem-c-mode:c-mode))

(define-command lem-yath-test-snippet-condition-false-setup () ()
  (switch-to-buffer
   (or (get-buffer "*snippet-test-condition-false*")
       (make-buffer "*snippet-test-condition-false*")))
  (snippet-test-reset
   "condition-false" 'lem-posix-shell-mode:posix-shell-mode))

(defun snippet-test-completion-items (input)
  (list
   (lem/completion-mode:make-completion-item
    :label "CMP-FIRST"
    :filter-text "cmp value first"
    :insert-text (concatenate 'string input "A"))
   (lem/completion-mode:make-completion-item
    :label "CMP-SECOND"
    :filter-text "cmp value second"
    :insert-text (concatenate 'string input "B"))))

(defun snippet-test-open-completion ()
  (lem/completion-mode:run-completion
   (lambda (point)
     (multiple-value-bind (start end input)
         (auto-completion-symbol-bounds point)
       (declare (ignore start end))
       (snippet-test-completion-items input)))))

(define-command lem-yath-test-snippet-ordinary-popup-setup () ()
  (snippet-test-reset-fundamental "ordinary-popup"))

(define-command lem-yath-test-snippet-active-popup-setup () ()
  (snippet-test-reset-fundamental "active-popup"))

(define-command lem-yath-test-snippet-open-popup () ()
  (snippet-test-open-completion))

(define-command lem-yath-test-snippet-escape-setup () ()
  (snippet-test-reset-fundamental "escape"))

(define-command lem-yath-test-snippet-paredit-setup () ()
  (snippet-test-switch-to-plain-buffer)
  (snippet-test-reset "paredit" 'lem-lisp-mode:lisp-mode)
  (lem-paredit-mode:paredit-mode t))

(define-command lem-yath-test-snippet-undo-setup () ()
  ;; Keeping the trigger outside undo history isolates the expansion's undo
  ;; unit: one normal-state `u' must restore this exact text and end tracking.
  (snippet-test-reset-fundamental "undo" "und"))

(define-command lem-yath-test-snippet-zero-default-setup () ()
  (snippet-test-reset-fundamental "zero-default"))

(define-command lem-yath-test-snippet-middle-insert-setup () ()
  (snippet-test-reset-fundamental "middle-insert"))

(define-command lem-yath-test-snippet-middle-backspace-setup () ()
  (snippet-test-reset-fundamental "middle-backspace"))

(define-command lem-yath-test-snippet-pair-backspace-setup () ()
  (snippet-test-reset-fundamental "pair-backspace"))

(define-command lem-yath-test-snippet-mode-change-setup () ()
  (snippet-test-reset-fundamental "mode-change"))

(define-command lem-yath-test-snippet-fixed-indent-setup () ()
  ;; Keep the trigger out of undo history and place it at column four.
  (snippet-test-reset-fundamental "fixed-indent" "pre fixmark"))

(define-command lem-yath-test-snippet-f6-dispatch () ()
  (if (string= (buffer-value (current-buffer) :snippet-test-label)
               "mode-change")
      (change-buffer-mode (current-buffer) 'lem-lisp-mode:lisp-mode)
      (snippet-test-open-completion)))

(define-command lem-yath-test-snippet-record-state () ()
  (snippet-test-report
   (concatenate
    'string
    "STATE label=~a text-hex=~a point=~d active=~a field=~a "
    "completion=~a focus=~a paredit=~a vi=~a snippet-mode=~a "
    "before-hook=~a after-hook=~a")
   (or (buffer-value (current-buffer) :snippet-test-label) "none")
   (snippet-test-hex (snippet-test-buffer-text))
   (position-at-point (current-point))
   (if (snippet-active-session-p) "yes" "no")
   (or (snippet-current-field-number) "none")
   (if lem/completion-mode::*completion-context* "yes" "no")
   (or (snippet-test-current-focus-label) "none")
   (if (mode-active-p (current-buffer) 'lem-paredit-mode:paredit-mode)
       "yes"
       "no")
   (snippet-test-vi-state-name)
   (if (mode-active-p (current-buffer) 'lem-yath-snippet-mode) "yes" "no")
   (if (snippet-hook-installed-p
        'before-change-functions 'snippet-before-change (current-buffer))
       "yes"
       "no")
   (if (snippet-hook-installed-p
        'after-change-functions 'snippet-after-change (current-buffer))
       "yes"
       "no")))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*insert-keymap*
                      lem-vi-mode:*visual-keymap*))
  (define-key keymap "F6" 'lem-yath-test-snippet-f6-dispatch)
  (define-key keymap "F12" 'lem-yath-test-snippet-record-state))

;; Completion owns ordinary Tab dispatch.  These fixture keys let us observe
;; that state without dismissing the popup as a side effect of the probe.
(define-key lem/completion-mode::*completion-mode-keymap*
  "F6" 'lem-yath-test-snippet-open-popup)
(define-key lem/completion-mode::*completion-mode-keymap*
  "F12" 'lem-yath-test-snippet-record-state)
(pushnew 'lem-yath-test-snippet-open-popup
         *auto-completion-continue-commands*)
(pushnew 'lem-yath-test-snippet-record-state
         *auto-completion-continue-commands*)

(setf *snippet-test-org-buffer* (current-buffer))
(snippet-reload)
(let ((ancestry-ok-p (snippet-test-verify-ancestry)))
  (snippet-test-audit-community-corpus)
  (snippet-test-safe-dynamic-oracle)
  (snippet-test-literal-choice-oracle)
  (snippet-test-report "ANCESTRY-SUMMARY ok=~a"
                       (if ancestry-ok-p "yes" "no"))
  (snippet-test-report "READY roots=~d ancestry=~a"
                       (length (snippet-root-directories))
                       (if ancestry-ok-p "yes" "no")))
