(in-package :lem-yath)

(defvar *lsp-snippet-test-report-path*
  (uiop:getenv "LEM_YATH_LSP_SNIPPET_TEST_REPORT"))

(defvar *lsp-snippet-test-pwned* nil)

(defun lsp-snippet-test-report (control &rest arguments)
  (with-open-file (stream *lsp-snippet-test-report-path*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun lsp-snippet-test-buffer-text ()
  (points-to-string (buffer-start-point (current-buffer))
                    (buffer-end-point (current-buffer))))

(defun lsp-snippet-test-hex (string)
  (with-output-to-string (stream)
    (loop :for character :across string
          :do (format stream "~2,'0x" (char-code character)))))

(defun lsp-snippet-test-focus-label ()
  (alexandria:when-let*
      ((context lem/completion-mode::*completion-context*)
       (popup (lem/completion-mode::context-popup-menu context))
       (item (lem/popup-menu:get-focus-item popup)))
    (lem/completion-mode:completion-item-label item)))

(defun lsp-snippet-test-reset (label text point-offset)
  (lem/completion-mode:completion-end)
  (auto-completion-cancel-timer)
  (setf *auto-completion-context* nil)
  (when (mode-active-p (current-buffer) 'lem-yath-snippet-mode)
    (lem-yath-snippet-mode nil))
  (unless (eq (buffer-major-mode (current-buffer))
              'lem/buffer/fundamental-mode:fundamental-mode)
    (change-buffer-mode
     (current-buffer) 'lem/buffer/fundamental-mode:fundamental-mode))
  (setf (variable-value 'lem/language-mode:completion-spec
                        :buffer (current-buffer))
        nil)
  (erase-buffer (current-buffer))
  (insert-string (current-point) text)
  (buffer-start (current-point))
  (character-offset (current-point) point-offset)
  (clear-buffer-edit-history (current-buffer))
  (setf (buffer-value (current-buffer) :lsp-snippet-test-label) label
        *lsp-snippet-test-pwned* nil
        (lem-vi-mode/core:buffer-state (current-buffer))
        'lem-vi-mode:normal)
  (lem-yath-snippet-mode t)
  (lsp-snippet-test-report "SETUP label=~a" label))

(defun lsp-snippet-test-position (character)
  (make-instance 'lsp:position :line 0 :character character))

(defun lsp-snippet-test-range (start end)
  (make-instance 'lsp:range
                 :start (lsp-snippet-test-position start)
                 :end (lsp-snippet-test-position end)))

(defun lsp-snippet-test-convert-items (items)
  (lem-lsp-mode::convert-completion-items (current-point) items))

(defun lsp-snippet-test-open-items (items)
  (let ((converted (lsp-snippet-test-convert-items items)))
    (lem/completion-mode:run-completion
     (lem/completion-mode:make-completion-spec
      (lambda (point then)
        (declare (ignore point))
        (funcall then converted))
      :async t))))

(defun lsp-snippet-test-item (label text &key filter-text text-edit)
  (apply #'make-instance
         'lsp:completion-item
         :label label
         :filter-text (or filter-text label)
         :insert-text text
         :insert-text-format lsp:insert-text-format-snippet
         (when text-edit (list :text-edit text-edit))))

(define-command lem-yath-test-lsp-snippet-insert-setup () ()
  (lsp-snippet-test-reset "insert" "pri" 3)
  (lsp-snippet-test-open-items
   (list (lsp-snippet-test-item
          "INSERT-SNIPPET" "print(${1:value})$0"
          :filter-text "pri"))))

(define-command lem-yath-test-lsp-snippet-text-edit-setup () ()
  (lsp-snippet-test-reset "text-edit" "foTAIL" 2)
  (lsp-snippet-test-open-items
   (list
    (lsp-snippet-test-item
     "FUNCTION-SNIPPET"
     "ignored"
     :filter-text "fo"
     :text-edit
     (make-instance 'lsp:text-edit
                    :range (lsp-snippet-test-range 0 6)
                    :new-text "fn(${1:name}, $1)$0")))))

(define-command lem-yath-test-lsp-snippet-insert-replace-setup () ()
  (lsp-snippet-test-reset "insert-replace" "foTAIL" 2)
  (lsp-snippet-test-open-items
   (list
    (lsp-snippet-test-item
     "INSERT-REPLACE-SNIPPET"
     "ignored"
     :filter-text "fo"
     :text-edit
     (make-instance 'lsp:insert-replace-edit
                    :new-text "ir(${1:x})$0"
                    :insert (lsp-snippet-test-range 0 2)
                    :replace (lsp-snippet-test-range 0 6))))))

(define-command lem-yath-test-lsp-snippet-plain-setup () ()
  (lsp-snippet-test-reset "plain" "pla" 3)
  (lsp-snippet-test-open-items
   (list
    (make-instance 'lsp:completion-item
                   :label "PLAIN-ITEM"
                   :filter-text "pla"
                   :insert-text "plain$1${2:x}"
                   :insert-text-format lsp:insert-text-format-plain-text))))

(define-command lem-yath-test-lsp-snippet-multiple-setup () ()
  (lsp-snippet-test-reset "multiple" "f" 1)
  (lsp-snippet-test-open-items
   (list (lsp-snippet-test-item "A-FOO" "foo(${1:x})$0"
                                :filter-text "f")
         (lsp-snippet-test-item "B-FAR" "far(${1:y})$0"
                                :filter-text "f"))))

(define-command lem-yath-test-lsp-snippet-malformed-setup () ()
  (lsp-snippet-test-reset "malformed" "bad" 3)
  (lsp-snippet-test-open-items
   (list (lsp-snippet-test-item "BROKEN-SNIPPET" "oops(${1:broken"
                                :filter-text "bad"))))

(define-command lem-yath-test-lsp-snippet-inert-setup () ()
  (lsp-snippet-test-reset "inert" "evil" 4)
  (lsp-snippet-test-open-items
   (list
    (lsp-snippet-test-item
     "INERT-SNIPPET"
     "`(progn (setf *lsp-snippet-test-pwned* t) \"BAD\")`-${1:safe}$0"
     :filter-text "evil"))))

(defun lsp-snippet-test-capability-value ()
  (let* ((capabilities (lem-lsp-mode::client-capabilities))
         (text-document
           (lsp:client-capabilities-text-document capabilities))
         (completion
           (lsp:text-document-client-capabilities-completion text-document))
         (completion-item
           (lsp:completion-client-capabilities-completion-item completion)))
    (gethash "snippetSupport" completion-item)))

(define-command lem-yath-test-lsp-snippet-static-checks () ()
  (let ((failures 0))
    (labels ((check (condition label)
               (lsp-snippet-test-report
                "~a STATIC ~a"
                (if condition "PASS" "FAIL") label)
               (unless condition
                 (incf failures)))
             (converted (item)
               (first (lsp-snippet-test-convert-items (list item)))))
      (handler-case
          (progn
            (check (lsp-snippet-test-capability-value)
                   "capability-enabled-with-handler")
            (let ((saved
                    (variable-value
                     'lem/completion-mode:completion-snippet-expansion-function
                     :global)))
              (unwind-protect
                   (progn
                     (setf (variable-value
                            'lem/completion-mode:completion-snippet-expansion-function
                            :global)
                           nil)
                     (check (not (lsp-snippet-test-capability-value))
                            "capability-disabled-without-handler"))
                (setf (variable-value
                       'lem/completion-mode:completion-snippet-expansion-function
                       :global)
                      saved)))
            (let* ((plain
                     (converted
                      (make-instance
                       'lsp:completion-item
                       :label "PLAIN"
                       :insert-text "literal$1"
                       :insert-text-format lsp:insert-text-format-plain-text)))
                   (snippet
                     (converted
                      (lsp-snippet-test-item "SNIPPET" "${1:value}$0"))))
              (check
               (null
                (lem/completion-mode:completion-item-final-insert-action plain))
               "plain-format-has-default-inserter")
              (check
               (functionp
                (lem/completion-mode:completion-item-final-insert-action
                 snippet))
               "snippet-format-has-final-inserter"))
            (lsp-snippet-test-reset "static-range" "foTAIL" 2)
            (let* ((item
                     (lsp-snippet-test-item
                      "RANGE" "ignored"
                      :text-edit
                      (make-instance 'lsp:text-edit
                                     :range (lsp-snippet-test-range 0 6)
                                     :new-text "${1:x}$0")))
                   (converted (converted item)))
              (lsp-snippet-test-report
               "DETAIL range start=~d end=~d"
               (position-at-point
                (lem/completion-mode::completion-item-start converted))
               (position-at-point
                (lem/completion-mode::completion-item-end converted)))
              (check
               (and (= 1 (position-at-point
                          (lem/completion-mode::completion-item-start
                           converted)))
                    (= 7 (position-at-point
                          (lem/completion-mode::completion-item-end
                           converted))))
               "text-edit-preserves-full-range"))
            (lsp-snippet-test-reset "static-success" "token" 5)
            (let ((insert-count 0)
                  (accept-count 0))
              (lem/completion-mode:run-completion
               (lambda (point)
                 (declare (ignore point))
                 (list
                  (lem/completion-mode:make-completion-item
                   :label "CUSTOM"
                   :filter-text "token"
                   :final-insert-action
                   (lambda (point start end)
                     (incf insert-count)
                     (delete-between-points start end)
                     (move-point point start)
                     (insert-string point "custom")
                     t)
                   :accept-action (lambda () (incf accept-count))))))
              (lsp-snippet-test-report
               "DETAIL custom insert-count=~d accept-count=~d text-hex=~a"
               insert-count accept-count
               (lsp-snippet-test-hex (lsp-snippet-test-buffer-text)))
              (check (and (= insert-count 1) (= accept-count 1)
                          (string= "custom"
                                   (lsp-snippet-test-buffer-text)))
                     "custom-insert-and-post-actions-once"))
            (lsp-snippet-test-reset "static-failure" "keep" 4)
            (let ((accept-count 0))
              (lem/completion-mode:run-completion
               (lambda (point)
                 (declare (ignore point))
                 (list
                  (lem/completion-mode:make-completion-item
                   :label "FAIL"
                   :filter-text "keep"
                   :final-insert-action
                   (lambda (point start end)
                     (declare (ignore point start end))
                     nil)
                   :accept-action (lambda () (incf accept-count))))))
              (check (and (zerop accept-count)
                          (string= "keep" (lsp-snippet-test-buffer-text)))
                     "failed-custom-insert-preserves-text-and-skips-post")))
        (error (condition)
          (lsp-snippet-test-report "FAIL STATIC unhandled-error=~a" condition)
          (incf failures)))
      (ignore-errors (lem/completion-mode:completion-end))
      (lsp-snippet-test-report
       "SUMMARY STATIC ~a failures=~d"
       (if (zerop failures) "PASS" "FAIL") failures))))

(define-command lem-yath-test-lsp-snippet-record-state () ()
  (lsp-snippet-test-report
   (concatenate
    'string
    "STATE label=~a text-hex=~a point=~d active=~a field=~a "
    "completion=~a focus=~a pwned=~a")
   (buffer-value (current-buffer) :lsp-snippet-test-label)
   (lsp-snippet-test-hex (lsp-snippet-test-buffer-text))
   (position-at-point (current-point))
   (if (snippet-active-session-p) "yes" "no")
   (or (snippet-current-field-number) "none")
   (if lem/completion-mode::*completion-context* "yes" "no")
   (or (lsp-snippet-test-focus-label) "none")
   (if *lsp-snippet-test-pwned* "yes" "no")))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*insert-keymap*
                      lem-vi-mode:*visual-keymap*
                      lem/completion-mode::*completion-mode-keymap*))
  (define-key keymap "F12" 'lem-yath-test-lsp-snippet-record-state))

(pushnew 'lem-yath-test-lsp-snippet-record-state
         *auto-completion-continue-commands*)

(lsp-snippet-test-report "READY")
