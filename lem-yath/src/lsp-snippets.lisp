;;;; Safe LSP completion snippets through the existing Yas-style session UI.
;;;;
;;;; Eglot in the configured Emacs passes insertTextFormat=Snippet payloads
;;;; directly to Yasnippet.  This adapter deliberately follows that behavior
;;;; for fields, mirrors, nesting, and exits, while the data-only renderer
;;;; keeps server-supplied backquotes inert.

(in-package :lem-yath)

(defun lsp-snippet-template (text label buffer)
  (make-snippet-template
   :name label
   :body text
   :table (snippet-file-table-name buffer)
   :supported-p t
   :fixed-indent-p nil
   :auto-indent-first-line-p nil))

(defun expand-lsp-snippet (text label start end)
  "Expand LSP snippet TEXT over START..END as a tracked field session.

Return true only after the snippet grammar has been validated.  Malformed
payloads leave the accepted range untouched."
  (let ((template (lsp-snippet-template text label (point-buffer start))))
    (handler-case
        (progn
          ;; Parse before any buffer mutation.  `snippet-expand-template'
          ;; renders again so its normal trigger-recovery contract is retained.
          (snippet-render-template template)
          (snippet-expand-template template start end))
      (error (condition)
        (message "Cannot expand LSP snippet ~a: ~a" label condition)
        nil))))

(setf (variable-value
       'lem/completion-mode:completion-snippet-expansion-function
       :global)
      #'expand-lsp-snippet)
