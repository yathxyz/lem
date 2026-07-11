(in-package :lem-yath)

(defvar *completion-lifecycle-callbacks* (make-hash-table :test 'equal))

(defun completion-lifecycle-report (control &rest arguments)
  (with-open-file (stream (uiop:getenv "LEM_YATH_COMPLETION_LIFECYCLE_REPORT")
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun completion-lifecycle-buffer-text ()
  (points-to-string (buffer-start-point (current-buffer))
                    (buffer-end-point (current-buffer))))

(defun completion-lifecycle-clear-buffer ()
  (delete-between-points (buffer-start-point (current-buffer))
                         (buffer-end-point (current-buffer))))

(defun completion-lifecycle-with-function-overrides (bindings function)
  (let ((saved
          (mapcar (lambda (binding)
                    (let ((name (first binding)))
                      (list name
                            (fboundp name)
                            (when (fboundp name)
                              (fdefinition name)))))
                  bindings)))
    (unwind-protect
         (progn
           (dolist (binding bindings)
             (setf (fdefinition (first binding)) (second binding)))
           (funcall function))
      (dolist (entry saved)
        (destructuring-bind (name was-bound definition) entry
          (if was-bound
              (setf (fdefinition name) definition)
              (fmakunbound name)))))))

(defun completion-lifecycle-malformed-lsp-result
    (response &key simulate-conversion-error)
  (let ((workspace (make-instance 'lem-lsp-mode::workspace :state :ready))
        (success-callback nil)
        (provider-results '())
        (context nil)
        (pending-before nil)
        (callback-safe nil)
        (callback-error nil)
        (closed-after nil))
    (completion-lifecycle-with-function-overrides
     (append
      (list
       (list 'lem-lsp-mode::buffer-workspace
             (lambda (buffer &optional errorp)
               (declare (ignore buffer errorp))
               workspace))
       (list 'lem-lsp-mode::workspace-response-current-p
             (lambda (candidate buffer)
               (declare (ignore candidate buffer))
               t))
       (list 'lem-lsp-mode::provide-completion-p
             (lambda (workspace)
               (declare (ignore workspace))
               t))
       (list 'lem-lsp-mode::workspace-client
             (lambda (workspace)
               (declare (ignore workspace))
               :completion-lifecycle-client))
       (list 'lem-lsp-mode::make-text-document-position-arguments
             (lambda (point &optional workspace)
               (declare (ignore point workspace))
               (list
                :text-document
                (make-instance 'lsp:text-document-identifier
                               :uri "file:///completion-lifecycle")
                :position
                (make-instance 'lsp:position :line 0 :character 0))))
       (list 'lem-lsp-mode::async-request
             (lambda (client request params &key then error)
               (declare (ignore client request params error))
               (setf success-callback then))))
      (when simulate-conversion-error
        (list
         (list 'lem-lsp-mode::convert-completion-response
               (lambda (&rest arguments)
                 (declare (ignore arguments))
                 (error "simulated asynchronous completion conversion failure"))))))
     (lambda ()
       (unwind-protect
            (progn
              (completion-lifecycle-clear-buffer)
              (setf context
                    (lem/completion-mode:run-completion
                     (lem/completion-mode:make-completion-spec
                      (lambda (point then)
                        (lem-lsp-mode::text-document/completion
                         point
                         (lambda (items)
                           (push items provider-results)
                           (funcall then items))))
                      :async t)))
              (setf pending-before
                    (and success-callback
                         (eq context
                             lem/completion-mode::*completion-context*)
                         (lem/completion-mode::context-request-pending-p
                          context)))
              (handler-case
                  (progn
                    (funcall success-callback response)
                    (setf callback-safe t))
                (error (condition)
                  (setf callback-error condition)))
              (setf closed-after
                    (and
                     (null lem/completion-mode::*completion-context*)
                     (null
                      (lem/completion-mode::context-spinner context))
                     (not
                      (lem/completion-mode::context-request-pending-p
                       context)))))
         (ignore-errors (lem/completion-mode:completion-end)))))
    (list :pending-before pending-before
          :callback-safe callback-safe
          :callback-error callback-error
          :provider-results (reverse provider-results)
          :closed-after closed-after)))

(defun completion-lifecycle-request-callback-result
    (&key coerce-error success-error)
  "Exercise the language-client response boundary without a live transport."
  (let ((transport-callback nil)
        (success-count 0)
        (success-value nil)
        (error-count 0)
        (error-message nil)
        (error-code :unset)
        (escaped-error nil))
    (cl-package-locks:without-package-locks
      (completion-lifecycle-with-function-overrides
       (list
        (list 'lem-language-client/client:client-connection
              (lambda (client)
                (declare (ignore client))
                :completion-lifecycle-connection))
        (list 'lem-language-client/request::jsonrpc-call-async
              (lambda (connection method params callback
                       &optional transport-error-callback)
                (declare
                 (ignore connection method params transport-error-callback))
                (setf transport-callback callback)
                :completion-lifecycle-request))
        (list 'lem-language-client/request::coerce-response
              (lambda (request response)
                (declare (ignore request response))
                (if coerce-error
                    (error "simulated response coercion failure")
                    :decoded-response))))
       (lambda ()
         (lem-language-client/request:request-async
          :completion-lifecycle-client
          (make-instance 'lsp:completion-item/resolve)
          nil
          (lambda (value)
            (incf success-count)
            (setf success-value value)
            (when success-error
              (error "simulated success callback failure")))
          (lambda (message code)
            (incf error-count)
            (setf error-message message
                  error-code code)))
         (handler-case
             (funcall transport-callback :wire-response)
           (error (condition)
             (setf escaped-error condition))))))
    (list :success-count success-count
          :success-value success-value
          :error-count error-count
          :error-message error-message
          :error-code error-code
          :escaped-error escaped-error)))

(defun completion-lifecycle-item (name label insert-text &optional filter-text)
  (lem/completion-mode:make-completion-item
   :label label
   :filter-text (or filter-text name)
   :insert-text insert-text
   :focus-action (lambda (context)
                   (declare (ignore context))
                   (completion-lifecycle-report "FOCUS ~a" name))
   :accept-action (lambda ()
                    (completion-lifecycle-report
                     "ACCEPT ~a buffer=~a"
                     name
                     (completion-lifecycle-buffer-text)))))

(define-command lem-yath-test-completion-metadata () ()
  (completion-lifecycle-clear-buffer)
  (lem/completion-mode:run-completion
   (lambda (point)
     (declare (ignore point))
     (list (completion-lifecycle-item
            "alpha" "ALPHA(value) [function]" "alpha_insert")
           (completion-lifecycle-item
            "beta" "BETA(value) [function]" "beta_insert")))))

(defun completion-lifecycle-async-provider (point then)
  (let ((query (or (symbol-string-at-point point) "")))
    (completion-lifecycle-report "REQUEST ~a" query)
    (if (string= query "a")
        (funcall then
                 (list (completion-lifecycle-item
                        "initial" "INITIAL-A" "initial_insert")))
        (setf (gethash query *completion-lifecycle-callbacks*) then))))

(define-command lem-yath-test-completion-async () ()
  (completion-lifecycle-clear-buffer)
  (clrhash *completion-lifecycle-callbacks*)
  (insert-string (current-point) "a")
  (lem/completion-mode:run-completion
   (lem/completion-mode:make-completion-spec
    #'completion-lifecycle-async-provider
    :async t)))

(define-command lem-yath-test-deliver-fresh-completion () ()
  (alexandria:when-let ((callback
                         (gethash "abc" *completion-lifecycle-callbacks*)))
    (completion-lifecycle-report "DELIVER fresh")
    (funcall callback
             (list (completion-lifecycle-item
                    "fresh" "FRESH-ABC" "fresh_insert" "abc")))))

(define-command lem-yath-test-deliver-stale-completion () ()
  (alexandria:when-let ((callback
                         (gethash "ab" *completion-lifecycle-callbacks*)))
    (completion-lifecycle-report "DELIVER stale")
    (funcall callback
             (list (completion-lifecycle-item
                    "stale" "STALE-AB" "stale_insert" "ab")))))

(define-key lem/completion-mode::*completion-mode-keymap*
  "F5" 'lem-yath-test-deliver-fresh-completion)
(define-key lem/completion-mode::*completion-mode-keymap*
  "F6" 'lem-yath-test-deliver-stale-completion)

(define-command lem-yath-test-completion-static-checks () ()
  (let ((failures 0))
    (labels ((check (condition label)
               (completion-lifecycle-report
                "~a STATIC ~a"
                (if condition "PASS" "FAIL")
                label)
               (unless condition
                 (incf failures)))
             (buffer-is (expected)
               (string= expected (completion-lifecycle-buffer-text)))
             (converted (item)
               (first (lem-lsp-mode::convert-completion-items
                       (current-point)
                       (list item))))
             (lsp-position (character)
               (make-instance 'lsp:position :line 0 :character character))
             (range (start end)
               (make-instance 'lsp:range
                              :start (lsp-position start)
                              :end (lsp-position end))))
      (handler-case
          (progn
            (let ((fallback
                    (lem/completion-mode:make-completion-item
                     :label "fallback")))
              (check (string= "fallback"
                              (lem/completion-mode:completion-item-filter-text
                               fallback))
                     "label-is-filter-fallback")
              (check (string= "fallback"
                              (lem/completion-mode:completion-item-insert-text
                               fallback))
                     "label-is-insert-fallback"))

            (let ((item (lem/completion-mode:make-completion-item
                         :label "DISPLAY"
                         :filter-text "needle"
                         :insert-text "inserted")))
              (check (string= "DISPLAY"
                              (lem/completion-mode:completion-item-label item))
                     "display-label-is-distinct")
              (check (string= "needle"
                              (lem/completion-mode:completion-item-filter-text item))
                     "filter-text-is-distinct")
              (completion-lifecycle-clear-buffer)
              (lem/completion-mode::completion-insert (current-point) item)
              (check (buffer-is "inserted") "insertion-uses-insert-text"))

            (let* ((accept-count 0)
                   (item (lem/completion-mode:make-completion-item
                          :label "SINGLE"
                          :insert-text "single_insert"
                          :accept-action (lambda () (incf accept-count)))))
              (completion-lifecycle-clear-buffer)
              (lem/completion-mode:run-completion
               (lambda (point)
                 (declare (ignore point))
                 (list item)))
              (check (buffer-is "single_insert")
                     "singleton-uses-final-acceptance")
              (check (= accept-count 1) "singleton-accept-action-once")
              (check (null lem/completion-mode::*completion-context*)
                     "singleton-closes-context"))

            (let* ((accept-count 0)
                   (item (lem/completion-mode:make-completion-item
                          :label "PARTIAL"
                          :insert-text "partial_insert"
                          :accept-action (lambda () (incf accept-count)))))
              (completion-lifecycle-clear-buffer)
              (lem/completion-mode::completion-insert (current-point) item 3)
              (check (buffer-is "par") "partial-insert-uses-insert-text")
              (check (zerop accept-count)
                     "partial-insert-does-not-accept"))

            (let* ((callbacks '())
                   (spec (lem/completion-mode:make-completion-spec
                          (lambda (point then)
                            (declare (ignore point))
                            (push then callbacks))
                          :async t))
                   (context (make-instance
                             'lem/completion-mode::completion-context
                             :spec spec))
                   (fresh (lem/completion-mode:make-completion-item
                           :label "FRESH"))
                   (stale (lem/completion-mode:make-completion-item
                           :label "STALE")))
              (setf lem/completion-mode::*completion-context* context)
              (lem/completion-mode::continue-completion context)
              (funcall (first callbacks) (list stale))
              (check (eq stale
                         (first
                          (lem/completion-mode::context-last-items context)))
                     "first-async-generation-applied")
              (lem/completion-mode::continue-completion context)
              (check (= 2 (length callbacks))
                     "async-refresh-issued-two-requests")
              (check (null
                      (lem/completion-mode::context-last-items context))
                     "pending-generation-invalidates-old-items")
              (funcall (first callbacks) (list fresh))
              (check (eq fresh
                         (first
                          (lem/completion-mode::context-last-items context)))
                     "newest-async-result-applied")
              (funcall (second callbacks) (list stale))
              (check (eq fresh
                         (first
                          (lem/completion-mode::context-last-items context)))
                     "older-async-result-rejected")
              (lem/completion-mode:completion-end)
              (funcall (first callbacks) (list stale))
              (check (eq fresh
                         (first
                          (lem/completion-mode::context-last-items context)))
                     "result-after-completion-end-rejected"))

            (let* ((callback nil)
                   (spec (lem/completion-mode:make-completion-spec
                          (lambda (point then)
                            (declare (ignore point))
                            (setf callback then))
                          :async t))
                   (context (make-instance
                             'lem/completion-mode::completion-context
                             :spec spec))
                   (item (lem/completion-mode:make-completion-item
                          :label "REFRESH-STALE")))
              (completion-lifecycle-clear-buffer)
              (setf lem/completion-mode::*completion-context* context)
              (lem/completion-mode::continue-completion context)
              (insert-string (current-point) "background-edit")
              (funcall callback (list item))
              (check
               (and (null lem/completion-mode::*completion-context*)
                    (null
                     (lem/completion-mode::context-last-items context)))
               "edited-buffer-rejects-delayed-refresh-result"))

            (let ((callback nil)
                  (item (lem/completion-mode:make-completion-item
                         :label "DELAYED"
                         :insert-text "delayed_insert")))
              (completion-lifecycle-clear-buffer)
              (lem/completion-mode:run-completion
               (lem/completion-mode:make-completion-spec
                (lambda (point then)
                  (declare (ignore point))
                  (setf callback then))
                :async t))
              (insert-string (current-point) "changed")
              (funcall callback (list item))
              (check (and
                      (null lem/completion-mode::*completion-context*)
                      (buffer-is "changed"))
                     "edited-buffer-rejects-delayed-initial-result"))

            (let* ((callback nil)
                   (origin (current-buffer))
                   (other (make-buffer "*completion-lifecycle-other*"))
                   (item (lem/completion-mode:make-completion-item
                          :label "OTHER-BUFFER"))
                   (safe nil))
              (lem/completion-mode:run-completion
               (lem/completion-mode:make-completion-spec
                (lambda (point then)
                  (declare (ignore point))
                  (setf callback then))
                :async t))
              (switch-to-buffer other)
              (setf safe
                    (handler-case
                        (progn (funcall callback (list item)) t)
                      (error () nil)))
              (check (and safe
                          (null lem/completion-mode::*completion-context*))
                     "buffer-switch-rejects-delayed-result-safely")
              (switch-to-buffer origin)
              (delete-buffer other))

            (let* ((origin (current-buffer))
                   (other
                     (make-buffer
                      "*completion-lifecycle-accept-other*"))
                   (accept-count 0)
                   (item
                     (lem/completion-mode:make-completion-item
                      :label "WRONG-BUFFER-ACCEPT"
                      :filter-text "origin"
                      :insert-text "must-not-insert"
                      :accept-action (lambda () (incf accept-count))))
                   (context nil)
                   (selection-callback nil)
                   (safe nil)
                   (accept-error nil)
                   (origin-preserved nil)
                   (other-preserved nil)
                   (closed nil))
              (unwind-protect
                   (progn
                     (completion-lifecycle-clear-buffer)
                     (insert-string (current-point) "origin")
                     (setf context
                           (lem/completion-mode:run-completion
                            (lambda (point)
                              (declare (ignore point))
                              (list item))
                            :automatic t))
                     (alexandria:when-let
                         ((popup
                            (lem/completion-mode::context-popup-menu
                             context)))
                       (setf selection-callback
                             (lem/popup-menu::popup-menu-action-callback
                              popup)))
                     (switch-to-buffer other)
                     (completion-lifecycle-clear-buffer)
                     (insert-string (current-point) "other")
                     (setf safe
                           (handler-case
                               (progn
                                 (when selection-callback
                                   (funcall selection-callback item))
                                 t)
                             (error (condition)
                               (setf accept-error condition)
                               nil))
                           other-preserved (buffer-is "other")
                           closed
                           (null lem/completion-mode::*completion-context*))
                     (with-current-buffer origin
                       (setf origin-preserved (buffer-is "origin"))))
                (ignore-errors (lem/completion-mode:completion-end))
                (ignore-errors (switch-to-buffer origin))
                (ignore-errors (completion-lifecycle-clear-buffer))
                (ignore-errors (delete-buffer other)))
              (completion-lifecycle-report
               "SWITCHED-ACCEPT callback=~s safe=~s closed=~s origin=~s other=~s count=~d error=~a"
               (not (null selection-callback)) safe closed origin-preserved
               other-preserved accept-count accept-error)
              (check (and selection-callback
                          safe
                          closed
                          origin-preserved
                          other-preserved
                          (zerop accept-count))
                     "buffer-switch-cancels-acceptance-without-mutation"))

            (let* ((callbacks '())
                   (spec (lem/completion-mode:make-completion-spec
                          (lambda (point then)
                            (declare (ignore point))
                            (push then callbacks))
                          :async t))
                   (old-context (make-instance
                                 'lem/completion-mode::completion-context
                                 :spec spec))
                   (new-context (make-instance
                                 'lem/completion-mode::completion-context
                                 :spec spec))
                   (old-item (lem/completion-mode:make-completion-item
                              :label "OLD-CONTEXT")))
              (setf lem/completion-mode::*completion-context* old-context)
              (lem/completion-mode::continue-completion old-context)
              (setf lem/completion-mode::*completion-context* new-context)
              (funcall (first callbacks) (list old-item))
              (check (and
                      (null (lem/completion-mode::context-last-items old-context))
                      (null (lem/completion-mode::context-last-items new-context)))
                     "old-context-result-cannot-update-new-context")
              (lem/completion-mode:completion-end))

            (let* ((label-only
                     (converted
                      (make-instance 'lsp:completion-item
                                     :label "LABEL-ONLY")))
                   (insert-item
                     (converted
                      (make-instance 'lsp:completion-item
                                     :label "INSERT-DISPLAY"
                                     :filter-text "filter-needle"
                                     :insert-text "insert-wins")))
                   (text-edit-item
                     (converted
                      (make-instance
                       'lsp:completion-item
                       :label "EDIT-DISPLAY"
                       :filter-text "edit-filter"
                       :insert-text "ignored-insert"
                       :text-edit (make-instance
                                   'lsp:text-edit
                                   :range (range 0 0)
                                   :new-text "edit-wins"))))
                   (insert-replace-item
                     (converted
                      (make-instance
                       'lsp:completion-item
                       :label "REPLACE-DISPLAY"
                       :text-edit (make-instance
                                   'lsp:insert-replace-edit
                                   :new-text "replace-wins"
                                   :insert (range 0 0)
                                   :replace (range 0 0))))))
              (check (string= "LABEL-ONLY"
                              (lem/completion-mode:completion-item-insert-text
                               label-only))
                     "lsp-label-final-insert-fallback")
              (check (and
                      (string= "INSERT-DISPLAY"
                               (lem/completion-mode:completion-item-label
                                insert-item))
                      (string= "filter-needle"
                               (lem/completion-mode:completion-item-filter-text
                                insert-item))
                      (string= "insert-wins"
                               (lem/completion-mode:completion-item-insert-text
                                insert-item)))
                     "lsp-preserves-display-filter-insert")
              (check (and
                      (string= "EDIT-DISPLAY"
                               (lem/completion-mode:completion-item-label
                                text-edit-item))
                      (string= "edit-wins"
                               (lem/completion-mode:completion-item-insert-text
                                text-edit-item)))
                     "lsp-text-edit-precedes-insert-text")
              (check (string= "replace-wins"
                              (lem/completion-mode:completion-item-insert-text
                               insert-replace-item))
                     "lsp-insert-replace-new-text-precedence")
              (check (member insert-item
                             (completion-strings
                              "filter-needle"
                              (list label-only insert-item text-edit-item)
                              :key #'lem/completion-mode:completion-item-filter-text))
                     "lsp-filtering-uses-filter-text"))

            (let ((malformed
                    (make-instance 'lsp:completion-list
                                   :is-incomplete nil
                                   :items #())))
              (slot-makunbound malformed 'lsp::items)
              (let ((result
                      (completion-lifecycle-malformed-lsp-result
                       malformed)))
                (check
                 (and (getf result :pending-before)
                      (getf result :callback-safe)
                      (null (getf result :callback-error))
                      (equal '(nil) (getf result :provider-results))
                      (getf result :closed-after))
                 "malformed-typed-lsp-response-closes-pending-context")))

            (let ((result
                    (completion-lifecycle-malformed-lsp-result
                     (make-instance 'lsp:completion-list
                                    :is-incomplete nil
                                    :items #())
                     :simulate-conversion-error t)))
              (check
               (and (getf result :pending-before)
                    (getf result :callback-safe)
                    (null (getf result :callback-error))
                    (equal '(nil) (getf result :provider-results))
                    (getf result :closed-after))
               "async-lsp-conversion-error-closes-pending-context"))

            (let ((result
                    (completion-lifecycle-request-callback-result
                     :coerce-error t)))
              (check
               (and (zerop (getf result :success-count))
                    (= 1 (getf result :error-count))
                    (null (getf result :error-code))
                    (search "simulated response coercion failure"
                            (getf result :error-message))
                    (null (getf result :escaped-error)))
               "response-coercion-error-invokes-error-callback-once"))

            (let ((result
                    (completion-lifecycle-request-callback-result
                     :success-error t)))
              (check
               (and (= 1 (getf result :success-count))
                    (eq :decoded-response (getf result :success-value))
                    (zerop (getf result :error-count))
                    (typep (getf result :escaped-error) 'error)
                    (search "simulated success callback failure"
                            (princ-to-string
                             (getf result :escaped-error))))
               "success-callback-error-does-not-invoke-error-callback")))
        (error (condition)
          (completion-lifecycle-report "FAIL STATIC unhandled-error=~a" condition)
          (incf failures)))
      (ignore-errors (lem/completion-mode:completion-end))
      (completion-lifecycle-clear-buffer)
      (completion-lifecycle-report
       "SUMMARY STATIC ~a failures=~d"
       (if (zerop failures) "PASS" "FAIL")
       failures))))
