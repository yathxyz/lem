;;;; The SPC leader map -- the muscle-memory core of the Emacs config
;;;; (general.el definitions from init-evil.el), bound via vi-mode's
;;;; Leader mechanism. Loaded last so every command already exists.
;;;; All leader chords are centralized here so normal and visual states stay
;;;; in sync.  Global delayed prefix guidance lives in prefix-help.lisp.

(in-package :lem-yath)

(defvar *evil-leader-bindings* nil)
(defvar *evil-leader-keymap* nil)

(defun leader-prefix (keymap keys)
  (lem-core::keymap-find keymap (lem-core::parse-keyspec keys)))

(defun make-evil-leader-keymap (bindings)
  "Build the one leader map shared by normal and visual states."
  (let ((keymap (lem-core::make-keymap)))
    (dolist (binding bindings)
      (destructuring-bind (keys command) binding
        (define-key keymap keys command)))
    keymap))

(defun bind-evil-leader-keymap (state-keymap leader-keymap)
  (define-key state-keymap "Leader" leader-keymap)
  ;; Replacing an existing prefix suffix does not register this back-pointer.
  ;; Keep command-to-key caches coherent when the shared tree changes later.
  (lem-core::link-keymap-parent state-keymap leader-keymap))

(defun rebuild-evil-leader-keymap ()
  "Replace the shared leader tree and discard obsolete popup state."
  (lem/transient::hide-transient)
  (setf *evil-leader-keymap*
        (make-evil-leader-keymap *evil-leader-bindings*))
  (bind-evil-leader-keymap lem-vi-mode:*normal-keymap*
                           *evil-leader-keymap*)
  (bind-evil-leader-keymap lem-vi-mode:*visual-keymap*
                           *evil-leader-keymap*)
  *evil-leader-keymap*)

(defmacro define-evil-leader-keys (&body bindings)
  "Define BINDINGS in both normal and visual states, like general.el."
  (let ((normalized
          (loop :for (keys command-form) :in bindings
                :collect
                (list keys
                      (if (and (consp command-form)
                               (eq (first command-form) 'quote))
                          (second command-form)
                          command-form)))))
    `(progn
       (defparameter *evil-leader-bindings* ',normalized)
       (rebuild-evil-leader-keymap))))

(define-evil-leader-keys
  ;; files / buffers
  ("f f" 'find-file)                          ; SPC f f
  ("<" 'select-buffer)                        ; SPC <
  ("Space" 'lem-yath-project-buffers)         ; SPC SPC
  ("b k" 'lem-yath-kill-current-buffer)       ; SPC b k
  ("b f" 'lem-yath-format-buffer)             ; SPC b f
  ("b m" 'lem-bookmark::bookmark-set)         ; SPC b m
  ("Return" 'lem-bookmark::bookmark-jump)     ; SPC RET
  ("u" 'lem-yath-vundo)                       ; SPC u

  ;; project (project.el / consult)
  ("p f" 'lem-yath-project-find-file)        ; SPC p f
  ("p g" 'lem-yath-project-grep)             ; SPC p g
  ("p p" 'lem-yath-project-switch)           ; SPC p p
  ("p s" 'lem-yath-workspace-symbol)         ; SPC p s

  ;; git (magit / majutsu dispatch)
  ("g g" 'lem-yath-vcs-status)               ; SPC g g
  ("g G" 'lem-yath-legit-status)             ; SPC g G
  ("g B" 'lem-yath-git-blame)                ; SPC g B
  ("g J" 'lem-yath-jj-log)                   ; SPC g J
  ("g t" 'lem-yath-git-timemachine)          ; SPC g t

  ;; LLM (gptel)
  ("g j" 'lem-yath-llm-send)                ; SPC g j
  ("g l" 'lem-yath-llm-menu)                ; SPC g l
  ("g L" 'lem-yath-llm-full-menu)           ; SPC g L
  ("g i" 'lem-yath-llm-ask)                 ; additional ad-hoc instruction
  ("g b" 'lem-yath-llm-set-backend)         ; SPC g b
  ("g n" 'lem-yath-llm-new-session)          ; SPC g n
  ("g a" 'lem-yath-llm-abort)                ; SPC g a

  ;; notes (org-roam / org-journal / org-capture)
  ("n r f" 'lem-yath-roam-find)              ; SPC n r f
  ("n r i" 'lem-yath-roam-insert)            ; SPC n r i
  ("n r a" 'lem-yath-roam-random)            ; SPC n r a
  ("n r d t" 'lem-yath-dailies-today)        ; SPC n r d t
  ("n r d d" 'lem-yath-dailies-date)         ; SPC n r d d
  ("n j j" 'lem-yath-journal-new-entry)      ; SPC n j j
  ("m I" 'lem-yath-org-id-get-create)        ; SPC m I
  ("m a" 'lem-yath-agenda)                   ; SPC m a
  ("o" 'lem-yath-capture)                    ; SPC o

  ;; compile / eval
  ("c c" 'lem-yath-compile)                   ; SPC c c
  ("m e e" 'lem-yath-lisp-eval-last-expression) ; SPC m e e

  ;; context-sensitive actions (Embark-style)
  ("e a" 'lem-yath-act)                       ; SPC e a

  ;; help (helpful)
  ("h k" 'lem-yath-describe-callable)       ; SPC h k
  ("h v" 'lem-yath-describe-variable)       ; SPC h v
  ("h K" 'lem-yath-describe-key)            ; SPC h K
  ("h d" 'lem-yath-devdocs-lookup)          ; SPC h d
  ("h b" 'describe-bindings)                ; SPC h b

  ;; citations / display
  ("y o" 'lem-yath-citar-open)                       ; SPC y o
  ("y a" 'lem-yath-toggle-auto-fill)                 ; SPC y a
  ("y c" 'centered-view-mode)                        ; SPC y c
  ("y v" 'lem-core/commands/window::toggle-line-wrap) ; SPC y v
  ("y w" 'lem-yath-fill-paragraph)                   ; SPC y w

  ;; navigation (Avy)
  ("l" 'lem-yath-avy-goto-line)                 ; SPC l
  ("a" 'lem-yath-avy-goto-char)                 ; SPC a
  ("s" 'lem-yath-avy-goto-symbol-1)             ; SPC s
  ("v" 'lem-yath-expand-region))                ; SPC v

(defun leader-binding-command (keymap keys)
  (alexandria:when-let
      ((prefix (lem-core::keymap-find
                keymap
                (lem-core::parse-keyspec
                 (concatenate 'string "Leader " keys)))))
    (lem-core::prefix-suffix prefix)))

(defun evil-leader-bindings-ok-p ()
  "Whether every declared leader binding matches in normal and visual states."
  (every (lambda (binding)
           (destructuring-bind (keys command) binding
             (and (eq command
                      (leader-binding-command lem-vi-mode:*normal-keymap* keys))
                  (eq command
                      (leader-binding-command lem-vi-mode:*visual-keymap* keys)))))
         *evil-leader-bindings*))

(defun state-leader-keymap (keymap)
  (alexandria:when-let
      ((prefix
         (lem-core::first-prefix-match
          keymap
          (first (lem-core::parse-keyspec "Leader")))))
    (lem-core::prefix-suffix prefix)))

(defun evil-leader-help-ok-p ()
  "Whether both Vi states share one raw leader tree under global Which-Key."
  (and (eq *evil-leader-keymap*
           (state-leader-keymap lem-vi-mode:*normal-keymap*))
       (eq *evil-leader-keymap*
           (state-leader-keymap lem-vi-mode:*visual-keymap*))
       (member lem-vi-mode:*normal-keymap*
               (lem-core::keymap-parents *evil-leader-keymap*)
               :test #'eq)
       (member lem-vi-mode:*visual-keymap*
               (lem-core::keymap-parents *evil-leader-keymap*)
               :test #'eq)
       (which-key-mode-enabled-p)
       (not (lem/transient::keymap-show-p *evil-leader-keymap*))
       (every (lambda (binding)
                (destructuring-bind (keys command) binding
                  (declare (ignore command))
                  (null (lem-core::prefix-description
                         (leader-prefix *evil-leader-keymap* keys)))))
              *evil-leader-bindings*)))

;;; --- non-leader bindings ----------------------------------------------------

;; Lem enters VISUAL as soon as a Vi buffer gains an active mark, so keep the
;; same chord available there for gptel-send's selected-region path.
(define-key lem-vi-mode:*insert-keymap* "C-c i" 'lem-yath-llm-send)
(define-key lem-vi-mode:*visual-keymap* "C-c i" 'lem-yath-llm-send)
(define-key lem-vi-mode:*insert-keymap* "C-u" 'lem-yath-delete-back-to-indentation)
(define-key lem-vi-mode:*insert-keymap* "C-d" 'lem-yath-evil-shift-left-line)
(define-key lem-vi-mode:*insert-keymap* "C-t" 'lem-yath-evil-shift-right-line)
(define-key lem-vi-mode:*insert-keymap* "C-v" 'quoted-insert)
(define-key lem-vi-mode:*insert-keymap* "C-a"
  'lem-yath-evil-paste-last-insertion)
(define-key lem-vi-mode:*insert-keymap* "C-r"
  'lem-yath-evil-paste-from-register)
(define-key lem-vi-mode:*insert-keymap* "C-o"
  'lem-yath-evil-execute-one-normal-command)
(define-key lem-vi-mode:*insert-keymap* "C-y" 'lem-yath-evil-copy-from-above)
(define-key lem-vi-mode:*insert-keymap* "C-e" 'lem-yath-evil-copy-from-below)
(define-key lem-vi-mode:*motion-keymap* "C-u"
  'lem/universal-argument:universal-argument)
(define-key lem-vi-mode:*insert-keymap* "M-Backspace"
  'lem-yath-structural-kill-last-word)
(define-key lem-vi-mode:*insert-keymap* "C-w"
  'lem-yath-structural-kill-last-word)

;; The Emacs config unbinds Evil's C-n/C-p overrides in motion, insert, and
;; Emacs states, but its authored loop omits Normal state.  Preserve that live
;; split explicitly so reloading after another config cannot change it.
(define-key lem-vi-mode:*normal-keymap* "C-n" 'yank-pop-next)
(define-key lem-vi-mode:*normal-keymap* "C-p" 'yank-pop)
(define-key lem-vi-mode:*insert-keymap* "C-n" 'next-line)
(define-key lem-vi-mode:*insert-keymap* "C-p" 'previous-line)
(define-key lem-vi-mode:*visual-keymap* "C-n" 'next-line)
(define-key lem-vi-mode:*visual-keymap* "C-p" 'previous-line)

;; normal state: C-c c opens the project-aware Claude Code query buffer
(define-key lem-vi-mode:*normal-keymap* "C-c c" 'lem-yath-claude-code)

;; Magit's default file dispatch is global in Emacs.  Vi state already owns a
;; C-c prefix, so install the same prefix in every state as well as globally.
(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*visual-keymap*
                      lem-vi-mode:*insert-keymap*))
  (define-key keymap "C-c M-g" *git-file-dispatch-keymap*))

(defun install-magit-file-dispatch-in-mode (mode)
  "Merge Magit's file prefix into MODE without replacing occupied bindings."
  (alexandria:when-let ((keymap (mode-keymap mode)))
    (let ((prefix
            (lem-core::keymap-find
             keymap (lem-core::parse-keyspec "C-c M-g"))))
      (cond
        ((null prefix)
         (define-key keymap "C-c M-g" *git-file-dispatch-keymap*))
        ((typep (lem-core::prefix-suffix prefix) 'lem-core::keymap)
         (let ((suffix (lem-core::prefix-suffix prefix)))
           (unless (lem-core::keymap-find suffix
                                          (lem-core::parse-keyspec "b"))
             (define-key suffix "b" 'lem-yath-git-blame))))))))

;; Lem chooses one C-c subtree before it has read the later M-g b suffix.
;; Merge into every already-registered major-mode subtree at this final load
;; stage; a mode that owns C-c M-g or its b suffix keeps that binding.
(dolist (mode (major-modes))
  (install-magit-file-dispatch-in-mode mode))

;; globals from the `use-package emacs` block
(define-key *global-keymap* "M-o" 'next-window)        ; other-window
(define-key *global-keymap* "M-j" 'lem-yath-duplicate-dwim) ; duplicate-dwim
(define-key *global-keymap* "M-g r"
  'lem-yath-find-recent-file)                           ; recentf + Marginalia
(define-key *global-keymap* "M-s f" 'lem-yath-find-name) ; find-name-dired
(define-key *global-keymap* "M-s g" 'lem-yath-grep)   ; M-s g grep
(define-key *global-keymap* "C-x C-b" 'lem-yath-list-buffers) ; grouped ibuffer
(define-key *global-keymap* "M-g n" 'lem-yath-next-error) ; next-error
(define-key *global-keymap* "M-g p" 'lem-yath-previous-error) ; previous-error

;; keybindings.lisp is the system's last component; reaching here means the
;; whole port loaded.
(setf *boot-ok* t)
