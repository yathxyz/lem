(in-package :lem-yath)

(define-command lem-yath-test-report-prompt-focus () ()
  (alexandria:when-let* ((context lem/completion-mode::*completion-context*)
                         (popup
                          (lem/completion-mode::context-popup-menu context))
                         (item (lem/popup-menu:get-focus-item popup)))
    (with-open-file (stream (uiop:getenv "LEM_YATH_COMPLETION_REPORT")
                            :direction :output
                            :if-exists :append
                            :if-does-not-exist :create)
      (format stream "FOCUS ~a INPUT ~s~%"
              (lem/completion-mode:completion-item-label item)
              (lem/prompt-window::get-input-string)))))

(define-key lem/completion-mode::*completion-mode-keymap*
  "F5" 'lem-yath-test-report-prompt-focus)

(define-command lem-yath-test-vertico-shared-prefix-prompt () ()
  "Open a prompt whose initial candidates share a nonempty prefix."
  (prompt-for-string
   "Shared prefix: "
   :completion-function
   (lambda (input)
     (declare (ignore input))
     '("common-alpha" "common-beta"))))

(define-command lem-yath-test-vertico-singleton-prompt () ()
  "Open a prompt whose initial completion batch contains one candidate."
  (prompt-for-string
   "Singleton: "
   :completion-function
   (lambda (input)
     (declare (ignore input))
     '("singleton-value"))))
