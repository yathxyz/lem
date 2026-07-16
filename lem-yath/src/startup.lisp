;;;; Match the configured Emacs no-file startup: one empty Org scratch buffer.

(in-package :lem-yath)

(defun open-initial-scratch ()
  "Present an empty Org LLM conversation instead of Lem's welcome dashboard."
  (let ((buffer (current-buffer)))
    (buffer-rename buffer "*scratch*")
    (change-buffer-mode buffer 'org-mode)
    (lem-yath-llm-conversation-mode t)))

(setf *splash-function* #'open-initial-scratch)
