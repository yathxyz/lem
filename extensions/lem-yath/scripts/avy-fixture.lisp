(in-package :lem-yath)

(defvar *avy-test-report* (uiop:getenv "LEM_YATH_AVY_REPORT"))
(defvar *avy-test-source* (uiop:getenv "LEM_YATH_AVY_SOURCE"))
(defvar *avy-test-snapshot* nil)
(defvar *avy-test-source-change-count* 0)

(defun avy-test-key-name (key)
  (cond ((match-key key :ctrl t :sym "g") "C-g")
        ((match-key key :sym "Escape") "Escape")
        ((key-to-char key) (string (key-to-char key)))
        (t (princ-to-string key))))

(defun avy-test-log (control &rest arguments)
  (with-open-file (stream *avy-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun avy-test-encode (string)
  (with-output-to-string (stream)
    (loop :for character :across (or string "")
          :do (case character
                (#\Newline (write-string "\\n" stream))
                (#\Return (write-string "\\r" stream))
                (#\Tab (write-string "\\t" stream))
                (#\\ (write-string "\\\\" stream))
                (otherwise (write-char character stream))))))

(defun avy-test-buffer-text (&optional (buffer (current-buffer)))
  (points-to-string (buffer-start-point buffer)
                    (buffer-end-point buffer)))

(defun avy-test-label-map ()
  (format nil "~{~a~^,~}"
          (mapcar (lambda (entry)
                    (format nil "~a@~d@~a@~d@~d"
                            (first entry)
                            (second entry)
                            (third entry)
                            (fourth entry)
                            (fifth entry)))
                  *avy-last-visible-labels*)))

(defun avy-test-before-selection-key (key)
  ;; READ-KEY runs the input hook after the production labels are visible but
  ;; before Avy consumes KEY.  This is the deterministic ncurses test seam for
  ;; both the full tree and each narrowed subtree.
  (when (and *avy-session-active* *avy-label-windows*)
    (avy-test-log
     "ACTIVE key=~a labels=~d buffers=~d frame-floats=~d map=~a stale=~a"
     (avy-test-key-name key)
     (length *avy-label-windows*)
     (length *avy-label-buffers*)
     (length (lem-core::frame-floating-windows (current-frame)))
     (avy-test-label-map)
     (if *avy-window-size-changed* "yes" "no"))))

(remove-hook *input-hook* 'avy-test-before-selection-key)
(add-hook *input-hook* 'avy-test-before-selection-key 1000)

(defun avy-test-key-command (keymap keys)
  (alexandria:when-let
      ((prefix (lem-core::keymap-find
                keymap
                (lem-core::parse-keyspec keys))))
    (lem-core::prefix-suffix prefix)))

(defun avy-test-leader-command (keymap keys)
  (leader-binding-command keymap keys))

(defun avy-test-bindings-ok-p ()
  (every
   #'identity
   (loop :for (keys command)
           :in '(("l" lem-yath-avy-goto-line)
                 ("a" lem-yath-avy-goto-char)
                 ("s" lem-yath-avy-goto-symbol-1))
         :append
         (list
          (eq command
              (avy-test-leader-command lem-vi-mode:*normal-keymap* keys))
          (eq command
              (avy-test-leader-command lem-vi-mode:*visual-keymap* keys))))))

(defun avy-test-motion-contracts-ok-p ()
  (every
   #'identity
   (loop :for (name type)
           :in '((lem-yath-avy-goto-line :line)
                 (lem-yath-avy-goto-char :inclusive)
                 (lem-yath-avy-goto-symbol-1 :exclusive))
         :for command := (get-command name)
         :collect
         (and (typep command 'lem-vi-mode/core:vi-motion)
              (eq type (lem-vi-mode/core:vi-motion-type command))
              (null (lem-vi-mode/core:vi-command-repeat command))))))

(defun avy-test-dummy-candidates (count)
  (loop :repeat count
        :collect
        (make-avy-candidate
         :point (copy-point (current-point) :temporary)
         :window (current-window)
         :screen-x 0
         :screen-y 0
         :target-width 1)))

(defun avy-test-tree-labels (count)
  (mapcar #'car
          (avy-tree-labels
           (avy-balanced-tree (avy-test-dummy-candidates count)))))

(defun avy-test-prefix-free-p (labels)
  (every
   (lambda (left)
     (every
      (lambda (right)
        (or (eq left right)
            (not (alexandria:starts-with-subseq left right))))
      labels))
   labels))

(defun avy-test-tree-contracts-ok-p ()
  (let ((one (avy-test-tree-labels 1))
        (nine (avy-test-tree-labels 9))
        (ten (avy-test-tree-labels 10))
        (eighty-one (avy-test-tree-labels 81))
        (eighty-two (avy-test-tree-labels 82)))
    (and (equal one '("a"))
         (equal nine '("a" "s" "d" "f" "g" "h" "j" "k" "l"))
         (equal ten '("a" "s" "d" "f" "g" "h" "j" "k" "la" "ls"))
         (= 81 (length eighty-one))
         (= 82 (length eighty-two))
         (every (lambda (label) (= 2 (length label))) eighty-one)
         (= 3 (reduce #'max eighty-two :key #'length))
         (avy-test-prefix-free-p eighty-two))))

(defun avy-test-dispatch-defaults-ok-p ()
  (equal *avy-dispatch-alist*
         '((#\x . :kill-move)
           (#\X . :kill-stay)
           (#\t . :teleport)
           (#\m . :mark)
           (#\n . :copy)
           (#\y . :yank)
           (#\Y . :yank-line)
           (#\i . :ispell)
           (#\z . :zap-to-char))))

(defun avy-test-spell-prompt-bindings-ok-p ()
  (every #'identity
         (list
          (eq (avy-test-key-command *avy-spell-prompt-keymap* "Space")
              'avy-spell-prompt-keep)
          (eq (avy-test-key-command *avy-spell-prompt-keymap* "a")
              'avy-spell-prompt-accept-session)
          (eq (avy-test-key-command *avy-spell-prompt-keymap* "i")
              'avy-spell-prompt-add-personal)
          (eq (avy-test-key-command *avy-spell-prompt-keymap* "r")
              'avy-spell-prompt-manual-replacement)
          (eq (avy-test-key-command *avy-spell-prompt-keymap* "0")
              'avy-spell-prompt-numbered-suggestion))))

(define-command lem-yath-test-avy-static () ()
  (let* ((bindings (avy-test-bindings-ok-p))
         (motions (avy-test-motion-contracts-ok-p))
         (tree (avy-test-tree-contracts-ok-p))
         (dispatch (avy-test-dispatch-defaults-ok-p))
         (spell (avy-test-spell-prompt-bindings-ok-p))
         (defaults (and (equal *avy-keys*
                               '(#\a #\s #\d #\f #\g #\h #\j #\k #\l))
                        *avy-case-fold-search*
                        *avy-single-candidate-jump*))
         (attribute (ensure-attribute 'lem-yath-avy-lead-attribute nil))
         (failures
           (count nil
                  (list bindings motions tree dispatch spell defaults attribute))))
    (avy-test-log
     (concatenate
      'string
      "STATIC bindings=~a motions=~a tree=~a dispatch=~a spell=~a defaults=~a "
      "attribute=~a failures=~d")
     (if bindings "yes" "no")
     (if motions "yes" "no")
     (if tree "yes" "no")
     (if dispatch "yes" "no")
     (if spell "yes" "no")
     (if defaults "yes" "no")
     (if attribute "yes" "no")
     failures)))

(define-command lem-yath-test-avy-spell-report () ()
  (avy-test-log
   "SPELL keep=~a session=~a personal=~a"
   (if (gethash "lemkeepword" *avy-spell-session-words*) "yes" "no")
   (if (gethash "lemsessionword" *avy-spell-session-words*) "yes" "no")
   (if (gethash "lempersonalword" *avy-spell-session-words*) "yes" "no")))

(define-command lem-yath-test-avy-record () ()
  (let* ((buffer (current-buffer))
         (mark (cursor-mark (current-point)))
         (mark-point (and (lem/buffer/internal:mark-active-p mark)
                          (lem/buffer/internal:mark-point mark)))
         (kill (ignore-errors
                 (lem/common/killring:peek-killring-item
                  (current-killring) 0)))
         (left-side
           (lem-core::frame-leftside-window (current-frame))))
    (avy-test-log
     (concatenate
      'string
      "STATE point=~d line=~d column=~d char=~a buffer=~a window=~d "
      "state=~a active=~a labels=~d label-buffers=~d frame-floats=~d left-side=~a "
      "visible=~d map=~a mark=~a:~a kill=~a "
      "read-only=~a modified=~a tick=~d history=~d changes=~d text=~a")
     (position-at-point (current-point))
     (line-number-at-point (current-point))
     (point-charpos (current-point))
     (or (character-at (current-point)) "none")
     (buffer-name buffer)
     (or (position (current-window) (window-list) :test #'eq) -1)
     (type-of (lem-vi-mode/core:current-state))
     (if *avy-session-active* "yes" "no")
     (length *avy-label-windows*)
     (length *avy-label-buffers*)
     (length (lem-core::frame-floating-windows (current-frame)))
     (cond ((null left-side) "none")
           ((deleted-window-p left-side) "deleted")
           ((eq (window-buffer left-side) buffer) "live-source")
           (t "live-other"))
     (length *avy-last-visible-labels*)
     (avy-test-label-map)
     (if mark-point "yes" "no")
     (if mark-point (position-at-point mark-point) -1)
     (avy-test-encode kill)
     (if (buffer-read-only-p buffer) "yes" "no")
     (if (buffer-modified-p buffer) "yes" "no")
     (lem/buffer/internal:buffer-modified-tick buffer)
     (count-if-not
      (lambda (entry) (eq entry :separator))
      (coerce (lem/buffer/internal::buffer-edit-history buffer) 'list))
     *avy-test-source-change-count*
     (avy-test-encode (avy-test-buffer-text buffer)))))

(define-command lem-yath-test-avy-goto-marker () ()
  (let ((point (current-point)))
    (buffer-start point)
    (unless (search-forward point "|")
      (editor-error "No Avy test marker"))
    (character-offset point -1)
    (window-see (current-window))
    (avy-test-log "MARKER point=~d" (position-at-point point))))

(define-command lem-yath-test-avy-goto-last-marker () ()
  (let ((point (current-point)))
    (buffer-end point)
    (unless (search-backward point "|")
      (editor-error "No Avy test marker"))
    (window-see (current-window))
    (avy-test-log "LAST-MARKER point=~d" (position-at-point point))))

(define-command lem-yath-test-avy-split () ()
  (split-window-horizontally (current-window))
  (avy-test-log "SPLIT windows=~d" (length (window-list))))

(define-command lem-yath-test-avy-side-window () ()
  (make-leftside-window (current-buffer) :width 20)
  (avy-test-log
   "SIDE ready=~a"
   (if (lem-core::frame-leftside-window (current-frame)) "yes" "no")))

(define-command lem-yath-test-avy-enable-wrap () ()
  (setf (variable-value 'line-wrap :buffer (current-buffer)) t)
  (window-see (current-window))
  (avy-test-log "WRAP enabled=yes"))

(defun avy-test-second-line-hidden-p (point)
  (= 2 (line-number-at-point point)))

(define-command lem-yath-test-avy-hide-second-line () ()
  (setf (variable-value 'lem-core::line-hidden-function
                        :buffer (current-buffer))
        'avy-test-second-line-hidden-p)
  (window-see (current-window))
  (avy-test-log "HIDDEN line=2"))

(define-command lem-yath-test-avy-read-only () ()
  (setf (buffer-read-only-p (current-buffer)) t)
  (avy-test-log "READ-ONLY enabled=yes"))

(defun avy-test-source-before-change (&rest arguments)
  (declare (ignore arguments))
  (incf *avy-test-source-change-count*))

(defun avy-test-edit-history (buffer)
  (remove :separator
          (coerce (lem/buffer/internal::buffer-edit-history buffer) 'list)
          :test #'eq))

(define-command lem-yath-test-avy-snapshot () ()
  (let ((buffer (current-buffer)))
    (setf *avy-test-source-change-count* 0
          *avy-test-snapshot*
          (list :buffer buffer
                :text (avy-test-buffer-text buffer)
                :modified (buffer-modified-p buffer)
                :tick (lem/buffer/internal:buffer-modified-tick buffer)
                :history (copy-list (avy-test-edit-history buffer))
                :overlays (copy-list (lem-core::buffer-overlays buffer))))
    (remove-hook (variable-value 'before-change-functions :buffer buffer)
                 'avy-test-source-before-change)
    (add-hook (variable-value 'before-change-functions :buffer buffer)
              'avy-test-source-before-change)
    (avy-test-log "SNAPSHOT ready=yes")))

(define-command lem-yath-test-avy-compare () ()
  (let* ((snapshot *avy-test-snapshot*)
         (buffer (getf snapshot :buffer))
         (same
           (and snapshot
                (eq buffer (current-buffer))
                (equal (getf snapshot :text) (avy-test-buffer-text buffer))
                (eq (getf snapshot :modified) (buffer-modified-p buffer))
                (= (getf snapshot :tick)
                   (lem/buffer/internal:buffer-modified-tick buffer))
                (equal (getf snapshot :history)
                       (avy-test-edit-history buffer))
                (equal (getf snapshot :overlays)
                       (lem-core::buffer-overlays buffer))
                (zerop *avy-test-source-change-count*)
                (null *avy-label-windows*)
                (null *avy-label-buffers*))))
    (avy-test-log
     "INVARIANTS same=~a changes=~d labels=~d buffers=~d"
     (if same "yes" "no")
     *avy-test-source-change-count*
     (length *avy-label-windows*)
     (length *avy-label-buffers*))))

(define-command lem-yath-test-avy-reload () ()
  (handler-case
      (progn
        (load (pathname *avy-test-source*))
        (avy-test-log
         "RELOAD bindings=~a motions=~a labels=~d buffers=~d"
         (if (avy-test-bindings-ok-p) "yes" "no")
         (if (avy-test-motion-contracts-ok-p) "yes" "no")
         (length *avy-label-windows*)
         (length *avy-label-buffers*)))
    (error (condition)
      (avy-test-log "RELOAD ERROR ~a" condition))))

(define-key *global-keymap* "F8" 'lem-yath-test-avy-compare)
(define-key *global-keymap* "F9" 'lem-yath-test-avy-snapshot)
(define-key *global-keymap* "F10" 'lem-yath-test-avy-reload)
(define-key *global-keymap* "F11" 'lem-yath-test-avy-static)
(define-key *global-keymap* "F12" 'lem-yath-test-avy-record)
(define-key *global-keymap* "F3" 'lem-yath-test-avy-read-only)
(define-key *global-keymap* "F2" 'lem-yath-test-avy-goto-last-marker)
(define-key *global-keymap* "F1" 'lem-yath-test-avy-side-window)
(define-key *global-keymap* "F4" 'lem-yath-test-avy-hide-second-line)
(define-key *global-keymap* "F5" 'lem-yath-test-avy-enable-wrap)
(define-key *global-keymap* "F6" 'lem-yath-test-avy-split)
(define-key *global-keymap* "F7" 'lem-yath-test-avy-goto-marker)
(define-key *global-keymap* "C-c S" 'lem-yath-test-avy-spell-report)

(avy-test-log "READY")
