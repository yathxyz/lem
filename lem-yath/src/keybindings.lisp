;;;; The SPC leader map -- the muscle-memory core of the Emacs config
;;;; (general.el definitions from init-evil.el), bound via vi-mode's
;;;; Leader mechanism. Loaded last so every command already exists.
;;;; All leader chords are centralized here so normal and visual states stay
;;;; in sync.

(in-package :lem-yath)

(defparameter *leader-help-delay* 1000
  "Milliseconds to wait before showing leader continuations.")

(defparameter *evil-leader-group-descriptions*
  '(("f" . "files")
    ("b" . "buffers")
    ("p" . "project")
    ("g" . "git and LLM")
    ("n" . "notes")
    ("n r" . "roam")
    ("n r d" . "dailies")
    ("n j" . "journal")
    ("m" . "mode")
    ("m e" . "evaluation")
    ("c" . "compile")
    ("e" . "actions")
    ("h" . "help")
    ("y" . "display"))
  "Descriptions shown for nested leader prefixes.")

(defvar *evil-leader-bindings* nil)
(defvar *evil-leader-keymap* nil)

(defun leader-help-keymap-p (keymap)
  (getf (lem-core::keymap-properties keymap) 'leader-help-keymap-p))

(defun leader-prefix (keymap keys)
  (lem-core::keymap-find keymap (lem-core::parse-keyspec keys)))

(defun configure-transient-keymap-tree (keymap)
  "Mark KEYMAP and every prefixed child as transient continuation menus."
  (setf (lem/transient::keymap-show-p keymap) t
        (getf (lem-core::keymap-properties keymap)
              'leader-help-keymap-p)
        t)
  (dolist (prefix (lem-core::keymap-prefixes keymap))
    (let ((suffix (lem-core::prefix-suffix prefix)))
      (when (typep suffix 'lem-core::keymap)
        (configure-transient-keymap-tree suffix))))
  keymap)

(defmethod keymap-activate :around ((keymap lem-core::keymap))
  "Use the which-key delay only for the described leader tree."
  (if (leader-help-keymap-p keymap)
      (let ((lem/transient:*transient-popup-delay* *leader-help-delay*))
        (call-next-method))
      (call-next-method)))

(defun make-evil-leader-keymap (bindings)
  "Build the one described leader map shared by normal and visual states."
  (let ((keymap (lem-core::make-keymap :description "Leader")))
    (dolist (binding bindings)
      (destructuring-bind (keys command description) binding
        (declare (ignore description))
        (define-key keymap keys command)))
    (dolist (binding bindings)
      (destructuring-bind (keys command description) binding
        (declare (ignore command))
        (setf (lem-core::prefix-description (leader-prefix keymap keys))
              description)))
    (dolist (group *evil-leader-group-descriptions*)
      (destructuring-bind (keys . description) group
        (alexandria:when-let* ((prefix (leader-prefix keymap keys))
                               (child (lem-core::prefix-suffix prefix)))
          (when (typep child 'lem-core::keymap)
            (setf (lem-core::keymap-description child)
                  (format nil "Leader ~a: ~a" keys description))))))
    (configure-transient-keymap-tree keymap)))

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
          (loop :for (keys command-form description) :in bindings
                :collect
                (list keys
                      (if (and (consp command-form)
                               (eq (first command-form) 'quote))
                          (second command-form)
                          command-form)
                      description))))
    `(progn
       (defparameter *evil-leader-bindings* ',normalized)
       (rebuild-evil-leader-keymap))))

(define-evil-leader-keys
  ;; files / buffers
  ("f f" 'find-file "find file")                          ; SPC f f
  ("<" 'select-buffer "switch buffer")                    ; SPC <
  ("Space" 'lem-yath-project-buffers "project buffers")   ; SPC SPC
  ("b k" 'lem-yath-kill-current-buffer "kill buffer")     ; SPC b k
  ("b f" 'lem-yath-format-buffer "format buffer")         ; SPC b f
  ("b m" 'lem-bookmark::bookmark-set "set bookmark")      ; SPC b m
  ("Return" 'lem-bookmark::bookmark-jump "jump bookmark") ; SPC RET

  ;; project (project.el / consult)
  ("p f" 'lem-yath-project-find-file "find project file") ; SPC p f
  ("p g" 'lem-yath-project-grep "grep project")           ; SPC p g
  ("p p" 'lem-yath-project-switch "switch project")       ; SPC p p
  ("p s" 'lem-yath-workspace-symbol "workspace symbols")       ; SPC p s

  ;; git (magit / majutsu dispatch)
  ("g g" 'lem-yath-vcs-status "VCS status")       ; SPC g g
  ("g G" 'lem-yath-legit-status "Git status")     ; SPC g G
  ("g J" 'lem-yath-jj-log "Jujutsu log")          ; SPC g J
  ("g t" 'lem-yath-git-timemachine "Git history") ; SPC g t

  ;; LLM (gptel)
  ("g j" 'lem-yath-llm-send "send to LLM")        ; SPC g j
  ("g l" 'lem-yath-llm-ask "ask LLM")             ; SPC g l
  ("g L" 'lem-yath-llm-set-model "choose LLM model") ; SPC g L
  ("g b" 'lem-yath-llm-set-backend "choose LLM backend") ; SPC g b

  ;; notes (org-roam / org-journal / org-capture)
  ("n r f" 'lem-yath-roam-find "find roam note")        ; SPC n r f
  ("n r i" 'lem-yath-roam-insert "insert roam link")    ; SPC n r i
  ("n r a" 'lem-yath-roam-random "random roam note")    ; SPC n r a
  ("n r d t" 'lem-yath-dailies-today "today's daily")   ; SPC n r d t
  ("n r d d" 'lem-yath-dailies-date "daily by date")    ; SPC n r d d
  ("n j j" 'lem-yath-journal-new-entry "new journal entry") ; SPC n j j
  ("m I" 'lem-yath-org-id-get-create "create Org ID")    ; SPC m I
  ("m a" 'lem-yath-agenda "agenda")                      ; SPC m a
  ("o" 'lem-yath-capture "capture note")                 ; SPC o

  ;; compile / eval
  ("c c" 'lem-yath-compile "compile")                    ; SPC c c
  ("m e e" 'lem-lisp-mode:lisp-eval-last-expression
   "evaluate last expression")                            ; SPC m e e

  ;; context-sensitive actions (Embark-style)
  ("e a" 'lem-yath-act "act on target")                  ; SPC e a

  ;; help (helpful)
  ("h k" 'apropos-command "describe command")       ; SPC h k
  ("h v" 'lem-yath-describe-variable "describe variable") ; SPC h v
  ("h K" 'describe-key "describe key")              ; SPC h K
  ("h d" 'lem-yath-devdocs-lookup "DevDocs lookup") ; SPC h d
  ("h b" 'describe-bindings "describe bindings")

  ;; citations / display
  ("y o" 'lem-yath-citar-open "open citation")       ; SPC y o
  ("y a" 'lem-yath-toggle-auto-fill "toggle auto-fill") ; SPC y a
  ("y v" 'toggle-line-wrap "toggle visual lines")    ; SPC y v
  ("y w" 'lem-yath-fill-paragraph "fill paragraph")  ; SPC y w

  ;; navigation (avy / isearch)
  ("l" 'goto-line "go to line")                         ; SPC l
  ("a" 'lem-yath-snipe-forward "jump to characters")    ; SPC a
  ("s" 'lem/isearch:isearch-forward-symbol "jump to symbol") ; SPC s
  ("v" 'lem-yath-expand-region "expand region"))         ; SPC v

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
           (destructuring-bind (keys command description) binding
             (declare (ignore description))
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

(defun transient-keymap-tree-p (keymap)
  (and (leader-help-keymap-p keymap)
       (lem/transient::keymap-show-p keymap)
       (every (lambda (prefix)
                (let ((suffix (lem-core::prefix-suffix prefix)))
                  (or (not (typep suffix 'lem-core::keymap))
                      (transient-keymap-tree-p suffix))))
              (lem-core::keymap-prefixes keymap))))

(defun evil-leader-help-ok-p ()
  "Whether both Vi states share the fully described transient leader tree."
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
       (transient-keymap-tree-p *evil-leader-keymap*)
       (every (lambda (binding)
                (destructuring-bind (keys command description) binding
                  (declare (ignore command))
                  (let ((actual
                          (lem-core::prefix-description
                           (leader-prefix *evil-leader-keymap* keys))))
                    (and (stringp actual)
                         (string= description actual)))))
              *evil-leader-bindings*)))

;;; --- non-leader bindings ----------------------------------------------------

;; insert state: C-c i sends to the LLM (gptel-send from insert state)
(define-key lem-vi-mode:*insert-keymap* "C-c i" 'lem-yath-llm-send)
(define-key lem-vi-mode:*insert-keymap* "C-u" 'lem-yath-delete-back-to-indentation)
(define-key lem-vi-mode:*insert-keymap* "M-Backspace"
  'lem-yath-structural-kill-last-word)
(define-key lem-vi-mode:*insert-keymap* "C-w"
  'lem-yath-structural-kill-last-word)

;; The Emacs config unbinds Evil's C-n/C-p overrides so they retain ordinary
;; line movement (and completion keymaps can take precedence when active).
(define-key lem-vi-mode:*normal-keymap* "C-n" 'next-line)
(define-key lem-vi-mode:*normal-keymap* "C-p" 'previous-line)
(define-key lem-vi-mode:*insert-keymap* "C-n" 'next-line)
(define-key lem-vi-mode:*insert-keymap* "C-p" 'previous-line)

;; normal state: C-c c opens Claude Code (claude-code-transient)
(define-key lem-vi-mode:*normal-keymap* "C-c c" 'lem-claude-code::claude-code)

;; globals from the `use-package emacs` block
(define-key *global-keymap* "M-o" 'next-window)        ; other-window
(define-key *global-keymap* "M-j" 'lem-yath-duplicate-dwim) ; duplicate-dwim
(define-key *global-keymap* "M-g r"
  'lem-core/commands/file:find-recent-file)             ; recentf
(define-key *global-keymap* "M-s f" 'lem-yath-find-name) ; find-name-dired
(define-key *global-keymap* "M-s g" 'lem/grep:grep)    ; M-s g grep

;; keybindings.lisp is the system's last component; reaching here means the
;; whole port loaded.
(setf *boot-ok* t)
