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
   :evaluation-policy :literal
   :condition-policy nil
   :supported-p t
   :fixed-indent-p nil
   :auto-indent-first-line-p nil))

(defun prepare-lsp-snippet (text label buffer)
  "Prepare LSP snippet TEXT and return a range installer.

Parsing and rendering finish before the returned function can mutate BUFFER.
Malformed payloads return NIL.  The installer accepts START and END points and
returns true only after installing the text and its tracked field session."
  (handler-case
      (let* ((template (lsp-snippet-template text label buffer))
             (rendering (snippet-render-template
                         template buffer (buffer-point buffer))))
        (lambda (start end)
          (handler-case
              (if (and (eq buffer (point-buffer start))
                       (eq buffer (point-buffer end)))
                  (snippet-install-rendering template rendering start end)
                  (progn
                    (message
                     "Cannot expand LSP snippet ~a: range belongs to another buffer"
                     label)
                    nil))
            (error (condition)
              (message "Cannot expand LSP snippet ~a: ~a" label condition)
              nil))))
    (error (condition)
      (message "Cannot expand LSP snippet ~a: ~a" label condition)
      nil)))

(defun expand-lsp-snippet (text label start end)
  "Expand LSP snippet TEXT over START..END as a tracked field session.

Return true only after successful installation.  Malformed payloads are
rejected during preparation and leave the accepted range untouched."
  (handler-case
      (alexandria:when-let ((installer
                             (prepare-lsp-snippet
                              text label (point-buffer start))))
        (funcall installer start end))
    (error (condition)
      (message "Cannot expand LSP snippet ~a: ~a" label condition)
      nil)))

(setf (variable-value
       'lem/completion-mode:completion-snippet-preparation-function
       :global)
      #'prepare-lsp-snippet)
