;;;; Native editable Org major mode and `.org' association.

(in-package :lem-yath)

(pushnew '("LEM-YATH" . "ORG-MODE")
         *non-programming-language-mode-classes*
         :test #'equal)

(defun org-mode-kill-buffer-cleanup (&optional (buffer (current-buffer)))
  (org-clear-folds buffer))

(define-major-mode org-mode lem/language-mode:language-mode
    (:name "Org"
     :description "Native Org document editing"
     :keymap *org-mode-keymap*
     :syntax-table *org-syntax-table*
     :mode-hook *org-mode-hook*)
  (setf (variable-value 'enable-syntax-highlight) t
        (variable-value 'indent-tabs-mode) nil
        (variable-value 'tab-width) 4
        ;; The current Emacs terminal profile truncates Org lines on ex44.
        (variable-value 'line-wrap) nil
        (variable-value 'lem/language-mode:line-comment) "# "
        (variable-value 'lem/language-mode:insertion-line-comment) "# "
        (variable-value 'lem-core::line-hidden-function) 'org-line-hidden-p)
  (setf (org-global-cycle-state (current-buffer)) nil)
  (add-hook (variable-value 'after-change-functions :buffer (current-buffer))
            'org-clear-folds-after-change)
  (add-hook (variable-value 'kill-buffer-hook :buffer (current-buffer))
            'org-mode-kill-buffer-cleanup))

(define-file-type ("org") org-mode)
