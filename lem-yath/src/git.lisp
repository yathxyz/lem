;;;; Git/VCS: magit -> legit, plus the custom jj/git smart dispatch
;;;; (lem-yath-vcs-status) and git-gutter, mirroring init-evil.el.

(in-package :lem-yath)

(defun jj-root ()
  (find-up (or (ignore-errors (buffer-directory (current-buffer)))
               (uiop:getcwd))
           ".jj"))

(define-command lem-yath-jj-log () ()
  "Jujutsu status + log in a buffer (majutsu-lite)."
  (let ((root (jj-root)))
    (unless root
      (message "Not inside a jj repository")
      (return-from lem-yath-jj-log))
    (stream-to-buffer
     (list "sh" "-c" "jj st --color=never; echo; jj log --color=never -n 30")
     "*lem-yath-jj*"
     :directory root)))

(define-command lem-yath-legit-status () ()
  "Open the legit status window (magit-status equivalent)."
  (uiop:symbol-call :lem/legit :legit-status))

(define-command lem-yath-vcs-status () ()
  "Smart VCS dispatch: jj repo -> jj log view, otherwise legit (git)."
  (if (jj-root)
      (lem-yath-jj-log)
      (lem-yath-legit-status)))

;; Gutter diff indicators (git-gutter-mode on prog buffers in Emacs;
;; Lem's implementation is a global mode). The flake loads this config via
;; --eval after *after-init-hook* has run, so initialize immediately when the
;; editor frame already exists.
(defun enable-lem-yath-git-gutter ()
  (ignore-errors
    (uiop:symbol-call :lem-git-gutter :git-gutter-mode t)))

(initialize-editor-feature 'enable-lem-yath-git-gutter)
