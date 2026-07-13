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
      (let ((input (lem/prompt-window::get-input-string)))
        (format stream "FOCUS=~a INPUT-LENGTH=~d INPUT=~a~%"
                (lem/completion-mode:completion-item-label item)
                (length input)
                input)))))

(define-key lem/completion-mode::*completion-mode-keymap*
  "F5" 'lem-yath-test-report-prompt-focus)
(pushnew 'lem-yath-test-report-prompt-focus
         *auto-completion-continue-commands*)

(define-command lem-yath-test-marginalia-command () ()
  "Zyzzyva-annotation-only-token proves command documentation is display-only."
  (message "Marginalia command fixture invoked"))

(define-key *global-keymap* "F6" 'lem-yath-test-marginalia-command)

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

(defun lem-yath-test-grouped-prompt-item (label group)
  "Return a grouped completion item spanning the live prompt input."
  (with-point ((start (lem/prompt-window::current-prompt-start-point))
               (end (lem/prompt-window::current-prompt-start-point)))
    (lem/completion-mode:make-completion-item
     :label label
     :insert-text label
     :group group
     :start start
     :end (line-end end))))

(define-command lem-yath-test-vertico-grouped-prompt () ()
  "Open a prompt with two non-selectable completion group headings."
  (prompt-for-string
   "Grouped: "
   :completion-function
   (lambda (input)
     (declare (ignore input))
     (list
      (lem-yath-test-grouped-prompt-item "group-alpha" "First Group")
      (lem-yath-test-grouped-prompt-item "group-beta" "First Group")
      (lem-yath-test-grouped-prompt-item "group-gamma" "Second Group")
      (lem-yath-test-grouped-prompt-item "group-delta" "Second Group")))))
