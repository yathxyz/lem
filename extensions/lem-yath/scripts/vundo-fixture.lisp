(in-package :lem-yath)

(defvar *vundo-test-report* (uiop:getenv "LEM_YATH_VUNDO_REPORT"))
(defvar *vundo-test-source* (uiop:getenv "LEM_YATH_VUNDO_SOURCE"))
(defvar *vundo-test-origin-buffer* nil)
(defvar *vundo-test-origin-window* nil)
(defvar *vundo-test-record-serial* 0)
(defvar *vundo-test-bottom-buffer* nil)
(defvar *vundo-test-bottom-window* nil)

(defun vundo-test-live-tree-buffers ()
  (remove-if-not
   (lambda (buffer)
     (and (not (deleted-buffer-p buffer))
          (eq (buffer-major-mode buffer) 'lem-yath-vundo-mode)))
   (buffer-list)))

(defun vundo-test-live-diff-buffers ()
  (remove-if-not
   (lambda (buffer)
     (and (not (deleted-buffer-p buffer))
          (search "*vundo diff*" (buffer-name buffer))))
   (buffer-list)))

(defun vundo-test-log (control &rest arguments)
  (with-open-file (stream *vundo-test-report*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun vundo-test-encode (string)
  (with-output-to-string (stream)
    (loop :for character :across string
          :do (case character
                (#\\ (write-string "\\\\" stream))
                (#\Newline (write-string "\\n" stream))
                (#\Return (write-string "\\r" stream))
                (#\Tab (write-string "\\t" stream))
                (otherwise (write-char character stream))))))

(defun vundo-test-line (buffer line-number)
  (with-point ((start (buffer-start-point buffer))
               (end (buffer-start-point buffer)))
    (line-offset start (1- line-number))
    (line-start start)
    (move-point end start)
    (line-end end)
    (points-to-string start end)))

(defun vundo-test-view-position (window)
  (handler-case
      (position-at-point (window-view-point window))
    (error () -1)))

(defun vundo-test-node (snapshot id)
  (find id (getf snapshot :nodes)
        :key (lambda (node) (getf node :id))
        :test #'eql))

(defun vundo-test-snapshot-valid-p (snapshot)
  (handler-case
      (let* ((nodes (getf snapshot :nodes))
             (ids (mapcar (lambda (node) (getf node :id)) nodes))
             (root (getf snapshot :root))
             (current (getf snapshot :current))
             (clean (getf snapshot :clean))
             (last-saved (getf snapshot :last-saved))
             (root-node (vundo-test-node snapshot root)))
        (and (integerp (getf snapshot :generation))
             (integerp (getf snapshot :node-count))
             (= (getf snapshot :node-count) (length nodes))
             (integerp (getf snapshot :payload-bytes))
             (<= 0 (getf snapshot :payload-bytes))
             (member (getf snapshot :truncated) '(nil t))
             (= (length ids) (length (remove-duplicates ids :test #'eql)))
             root-node
             (null (getf root-node :parent))
             (vundo-test-node snapshot current)
             (or (null clean) (vundo-test-node snapshot clean))
             (or (null last-saved) (vundo-test-node snapshot last-saved))
             (every
              (lambda (node)
                (let ((id (getf node :id))
                      (parent (getf node :parent))
                      (children (getf node :children))
                      (preferred (getf node :preferred))
                      (point-position (getf node :point-position)))
                  (and (integerp id)
                       (or (and (integerp point-position)
                                (plusp point-position))
                           (and (eql id root)
                                (= 1 (getf snapshot :node-count))
                                (null point-position)))
                       (listp children)
                       (= (length children)
                          (length (remove-duplicates children :test #'eql)))
                       (or (null preferred) (member preferred children :test #'eql))
                       (or (null parent)
                           (let ((parent-node (vundo-test-node snapshot parent)))
                             (and parent-node
                                  (member id (getf parent-node :children)
                                          :test #'eql))))
                       (every
                        (lambda (child)
                          (let ((child-node (vundo-test-node snapshot child)))
                            (and child-node
                                 (eql id (getf child-node :parent)))))
                        children)
                       ;; Walking parents must reach NIL within NODE-COUNT steps.
                       (loop :with cursor := id
                             :repeat (1+ (length nodes))
                             :for cursor-node := (vundo-test-node snapshot cursor)
                             :for next := (and cursor-node
                                              (getf cursor-node :parent))
                             :when (null next) :return t
                             :do (setf cursor next)
                             :finally (return nil)))))
              nodes)
             ;; Every node must be reachable from ROOT through child links.
             (let ((pending (list root))
                   (seen '()))
               (loop :while pending
                     :for id := (pop pending)
                     :unless (member id seen :test #'eql)
                       :do (push id seen)
                           (setf pending
                                 (nconc (copy-list
                                         (getf (vundo-test-node snapshot id)
                                               :children))
                                        pending))
                     :finally (return (= (length seen) (length nodes)))))))
    (error () nil)))

(defun vundo-test-snapshot-shape (snapshot)
  "Return topology/accounting while ignoring current and preferred branches."
  (list :generation (getf snapshot :generation)
        :root (getf snapshot :root)
        :clean (getf snapshot :clean)
        :last-saved (getf snapshot :last-saved)
        :truncated (getf snapshot :truncated)
        :node-count (getf snapshot :node-count)
        :payload-bytes (getf snapshot :payload-bytes)
        :nodes
        (mapcar (lambda (node)
                  (list :id (getf node :id)
                        :parent (getf node :parent)
                        :children (copy-list (getf node :children))
                        :saved-sequence (getf node :saved-sequence)))
                (getf snapshot :nodes))))

(defun vundo-test-command-binding (keymap keys)
  (alexandria:when-let
      ((prefix (lem-core::keymap-find keymap
                                     (lem-core::parse-keyspec keys))))
    (lem-core::prefix-suffix prefix)))

(defun vundo-test-private-temp-file-p ()
  #+sbcl
  (let ((pathname nil))
    (unwind-protect
         (progn
           (setf pathname
                 (vundo-write-private-temporary-file "mode-probe" "secret"))
           (let ((stat (sb-posix:lstat (uiop:native-namestring pathname))))
             (and (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
                     sb-posix:s-ifreg)
                  (= (logand (sb-posix:stat-mode stat) #o777) #o600)
                  (= (sb-posix:stat-uid stat) (sb-posix:getuid))
                  (string= "secret"
                           (uiop:read-file-string
                            pathname :external-format :utf-8)))))
      (when pathname (ignore-errors (delete-file pathname)))))
  #-sbcl nil)

(defun vundo-test-clean-is-not-saved-p ()
  (let ((buffer (make-buffer " *vundo-clean-not-saved*" :temporary t)))
    (unwind-protect
         (with-current-buffer buffer
           (insert-string (buffer-point buffer) "x")
           (buffer-undo-boundary buffer)
           (buffer-unmark buffer)
           (let* ((snapshot (lem:buffer-undo-tree-snapshot buffer))
                  (node (vundo-test-node snapshot (getf snapshot :current))))
             (and (eql (getf snapshot :clean) (getf snapshot :current))
                  (null (getf snapshot :last-saved))
                  (not (vundo-actually-saved-node-p node)))))
      (ignore-errors (delete-buffer buffer)))))

(defun vundo-test-counted-navigation-p ()
  (let* ((linear-nodes
           '((:id 0 :parent nil :children (1))
             (:id 1 :parent 0 :children (2))
             (:id 2 :parent 1 :children nil)))
         (linear-snapshot (list :nodes linear-nodes))
         (session
           (make-vundo-session
            :selected-id 1
            :snapshot linear-snapshot
            :node-table (vundo-node-table linear-snapshot)))
         (saved-snapshot
           '(:nodes ((:id 0 :parent nil :children (1) :saved-sequence 1)
                     (:id 1 :parent 0 :children (2) :saved-sequence 3)
                     (:id 2 :parent 1 :children (3) :saved-sequence nil)
                     (:id 3 :parent 2 :children (4) :saved-sequence 2)
                     (:id 4 :parent 3 :children nil :saved-sequence nil)))))
    (and (= 2 (vundo-linear-destination session 0 9))
         (= 0 (vundo-linear-destination session 2 -9))
         (= 1 (vundo-linear-destination session 1 0))
         (= 0 (vundo-find-saved-by-count saved-snapshot 4 2))
         (= 1 (vundo-find-saved-by-count saved-snapshot 0 -2))
         (= 3 (vundo-find-saved-by-count saved-snapshot 4 0))
         (null (vundo-find-saved-by-count saved-snapshot 0 -4)))))

(define-command lem-yath-test-vundo-static () ()
  (let ((failures 0))
    (flet ((check (condition label)
             (vundo-test-log "~a STATIC ~a"
                             (if condition "PASS" "FAIL") label)
             (unless condition (incf failures))))
      (check (eq 'lem-yath-vundo
                 (leader-binding-command lem-vi-mode:*normal-keymap* "u"))
             "normal-SPC-u")
      (check (eq 'lem-yath-vundo
                 (leader-binding-command lem-vi-mode:*visual-keymap* "u"))
             "visual-SPC-u")
      (check (eq 'lem-yath-project-grep-normal-undo
                 (vundo-test-command-binding
                  lem-vi-mode:*normal-keymap* "u"))
             "ordinary-u")
      (check (eq 'lem-vi-mode/commands:vi-redo
                 (vundo-test-command-binding
                  lem-vi-mode:*normal-keymap* "C-r"))
             "ordinary-C-r")
      (dolist (binding
               '(("f" lem-yath-vundo-forward)
                 ("Right" lem-yath-vundo-forward)
                 ("b" lem-yath-vundo-backward)
                 ("Left" lem-yath-vundo-backward)
                 ("n" lem-yath-vundo-next)
                 ("Down" lem-yath-vundo-next)
                 ("p" lem-yath-vundo-previous)
                 ("Up" lem-yath-vundo-previous)
                 ("a" lem-yath-vundo-stem-root)
                 ("w" lem-yath-vundo-next-root)
                 ("e" lem-yath-vundo-stem-end)
                 ("l" lem-yath-vundo-goto-last-saved)
                 ("r" lem-yath-vundo-goto-next-saved)
                 ("m" lem-yath-vundo-mark)
                 ("u" lem-yath-vundo-unmark)
                 ("d" lem-yath-vundo-diff)
                 ("q" lem-yath-vundo-quit)
                 ("C-g" lem-yath-vundo-quit)
                 ("Return" lem-yath-vundo-confirm)
                 ("C-x C-s" lem-yath-vundo-save)))
        (destructuring-bind (keys command) binding
          (check (eq command
                     (vundo-test-command-binding
                      *lem-yath-vundo-mode-keymap* keys))
                 (format nil "mode-key-~a" keys))))
      (check (and (fboundp 'lem:buffer-undo-tree-snapshot)
                  (fboundp 'lem:buffer-undo-tree-move))
             "public-snapshot-and-move-API")
      (check (vundo-test-private-temp-file-p) "private-diff-files")
      (check (vundo-test-clean-is-not-saved-p) "clean-is-not-saved")
      (check (vundo-test-counted-navigation-p) "counted-navigation")
      (vundo-test-log "SUMMARY STATIC ~a failures=~d"
                      (if (zerop failures) "PASS" "FAIL") failures))))

(define-command lem-yath-test-vundo-record-origin () ()
  (let* ((buffer *vundo-test-origin-buffer*)
         (snapshot (lem:buffer-undo-tree-snapshot buffer))
         (point (buffer-point buffer))
         (session *vundo-session*))
    (incf *vundo-test-record-serial*)
    (vundo-test-log
     (concatenate
      'string
      "ORIGIN serial=~d line40=~a point=~d:~d view=~d modified=~a "
      "read-only=~a tick=~d current=~a clean=~a saved=~a "
      "session=~a tree=~a diff=~a bottom=~a focus=~a")
     *vundo-test-record-serial*
     (vundo-test-encode (vundo-test-line buffer 40))
     (line-number-at-point point)
     (point-column point)
     (vundo-test-view-position *vundo-test-origin-window*)
     (if (buffer-modified-p buffer) "yes" "no")
     (if (buffer-read-only-p buffer) "yes" "no")
     (buffer-modified-tick buffer)
     (getf snapshot :current)
     (or (getf snapshot :clean) "none")
     (or (getf snapshot :last-saved) "none")
     (if session "open" "closed")
     (if (vundo-test-live-tree-buffers) "live" "none")
     (if (vundo-test-live-diff-buffers) "live" "none")
     (if (lem-core::frame-bottomside-window (current-frame)) "live" "none")
     (cond ((eq (current-buffer) buffer) "origin")
           ((eq (buffer-major-mode (current-buffer))
                'lem-yath-vundo-mode)
            "vundo")
           (t "other")))))

(define-command lem-yath-test-vundo-record-state () ()
  (let* ((session *vundo-session*)
         (diff-buffer (and session (vundo-session-diff-buffer session))))
    (vundo-test-log
     "VSTATE selected=~a marked=~a source=~a focus=~a diff=~a text=~a"
     (if session (vundo-session-selected-id session) "none")
     (or (and session (vundo-session-marked-id session)) "none")
     (if session
         (vundo-test-encode
          (vundo-test-line (vundo-session-origin-buffer session) 40))
         "none")
     (if (and session
              (eq (current-buffer) (vundo-session-tree-buffer session)))
         "vundo" "other")
     (if (vundo-live-buffer-p diff-buffer) "live" "none")
     (if (vundo-live-buffer-p diff-buffer)
         (vundo-test-encode (buffer-text diff-buffer))
         "none"))))

(define-command lem-yath-test-vundo-record-view () ()
  (let* ((buffer (current-buffer))
         (bottom (lem-core::frame-bottomside-window (current-frame))))
    (vundo-test-log
     "VIEW open=~a focus=~a mode=~a height=~d bottom=~a origin-read-only=~a"
     (if (eq (buffer-major-mode buffer) 'lem-yath-vundo-mode) "yes" "no")
     (if (eq buffer (window-buffer (current-window))) "yes" "no")
     (if (eq (buffer-major-mode buffer) 'lem-yath-vundo-mode) "yes" "no")
     (window-height (current-window))
     (if (eq bottom (current-window)) "yes" "no")
     (if (buffer-read-only-p *vundo-test-origin-buffer*) "yes" "no"))))

(define-command lem-yath-test-vundo-check-branch () ()
  (let* ((snapshot
           (lem:buffer-undo-tree-snapshot *vundo-test-origin-buffer*))
         (root (getf snapshot :root))
         (current (getf snapshot :current))
         (root-node (vundo-test-node snapshot root))
         (children (and root-node (getf root-node :children)))
         (pristine (copy-tree snapshot)))
    ;; Mutating a returned snapshot must not mutate live core state.
    (setf (getf snapshot :current) -1)
    (when (getf snapshot :nodes)
      (setf (getf (first (getf snapshot :nodes)) :children) '(-2)))
    (let ((fresh (lem:buffer-undo-tree-snapshot *vundo-test-origin-buffer*)))
      (vundo-test-log
       (concatenate
        'string
        "GRAPH valid=~a immutable=~a nodes=~d root-children=~d "
        "current-newest=~a preferred-current=~a clean-root=~a saved-root=~a")
       (if (vundo-test-snapshot-valid-p fresh) "yes" "no")
       (if (equal pristine fresh) "yes" "no")
       (getf fresh :node-count)
       (length children)
       (if (and children (eql current (first children))) "yes" "no")
       (if (and root-node (eql current (getf root-node :preferred)))
           "yes" "no")
       (if (eql root (getf fresh :clean)) "yes" "no")
       (if (eql root (getf fresh :last-saved)) "yes" "no")))))

(defun vundo-test-error-p (function)
  (handler-case (progn (funcall function) nil)
    (error () t)))

(defun vundo-test-run-probe (label function)
  (handler-case
      (let ((result (funcall function)))
        (vundo-test-log "PROBE ~a result=~a" label
                        (if result "pass" "fail"))
        result)
    (error (condition)
      (vundo-test-log "PROBE ~a error=~a" label
                      (vundo-test-encode (princ-to-string condition)))
      nil)))

(defvar *vundo-test-mutating-hook-active-p* nil)

(defun vundo-test-mutating-after-change (start end old-length)
  (declare (ignore end old-length))
  (unless *vundo-test-mutating-hook-active-p*
    (let ((*vundo-test-mutating-hook-active-p* t))
      (insert-string (buffer-end-point (point-buffer start)) "!"))))

(defun vundo-test-mutating-delete-after-change (start end old-length)
  (declare (ignore end old-length))
  (unless *vundo-test-mutating-hook-active-p*
    (let ((*vundo-test-mutating-hook-active-p* t))
      (delete-character (buffer-start-point (point-buffer start)) 1))))

(defun vundo-test-forward-mutating-insert-order-p ()
  "A same-buffer hook edit follows its triggering insertion in undo history."
  (let ((buffer (make-buffer " *vundo-forward-insert-hook*" :temporary t)))
    (unwind-protect
         (with-current-buffer buffer
           (let ((point (buffer-point buffer)))
             (add-hook (variable-value 'after-change-functions :buffer buffer)
                       'vundo-test-mutating-after-change)
             (unwind-protect
                  (insert-string point "A")
               (remove-hook
                (variable-value 'after-change-functions :buffer buffer)
                'vundo-test-mutating-after-change))
             (buffer-undo-boundary buffer)
             (let ((forward (buffer-text buffer))
                   (undone (and (buffer-undo point) (buffer-text buffer)))
                   (redone (and (buffer-redo point) (buffer-text buffer)))
                   (snapshot (lem:buffer-undo-tree-snapshot buffer)))
               (and (string= "A!" forward)
                    (stringp undone) (string= "" undone)
                    (stringp redone) (string= "A!" redone)
                    (not (getf snapshot :truncated))
                    (vundo-test-snapshot-valid-p snapshot)))))
      (ignore-errors
        (remove-hook (variable-value 'after-change-functions :buffer buffer)
                     'vundo-test-mutating-after-change))
      (ignore-errors (delete-buffer buffer)))))

(defun vundo-test-forward-mutating-delete-order-p ()
  "A same-buffer hook edit follows its triggering deletion in undo history."
  (let ((buffer (make-buffer " *vundo-forward-delete-hook*" :temporary t)))
    (unwind-protect
         (with-current-buffer buffer
           (let ((point (buffer-point buffer)))
             (insert-string point "AB")
             (buffer-undo-boundary buffer)
             (move-point point (buffer-start-point buffer))
             (add-hook (variable-value 'after-change-functions :buffer buffer)
                       'vundo-test-mutating-delete-after-change)
             (unwind-protect
                  (delete-character point 1)
               (remove-hook
                (variable-value 'after-change-functions :buffer buffer)
                'vundo-test-mutating-delete-after-change))
             (buffer-undo-boundary buffer)
             (let ((forward (buffer-text buffer))
                   (undone (and (buffer-undo point) (buffer-text buffer)))
                   (redone (and (buffer-redo point) (buffer-text buffer)))
                   (snapshot (lem:buffer-undo-tree-snapshot buffer)))
               (and (string= "" forward)
                    (stringp undone) (string= "AB" undone)
                    (stringp redone) (string= "" redone)
                    (not (getf snapshot :truncated))
                    (vundo-test-snapshot-valid-p snapshot)))))
      (ignore-errors
        (remove-hook (variable-value 'after-change-functions :buffer buffer)
                     'vundo-test-mutating-delete-after-change))
      (ignore-errors (delete-buffer buffer)))))

(defun vundo-test-mutating-throwing-after-change (start end old-length)
  (declare (ignore end old-length))
  (unless *vundo-test-mutating-hook-active-p*
    (let ((*vundo-test-mutating-hook-active-p* t))
      (insert-string (buffer-end-point (point-buffer start)) "!")
      (editor-error "test nested after-change failure"))))

(defun vundo-test-mutating-throwing-change-group-p ()
  "Cancel retains order when a hook mutates the buffer and then throws."
  (let ((buffer (make-buffer " *vundo-throwing-group-hook*" :temporary t)))
    (unwind-protect
         (with-current-buffer buffer
           (let ((point (buffer-point buffer)))
             (insert-string point "base")
             (buffer-undo-boundary buffer)
             (let* ((baseline (lem:buffer-undo-tree-snapshot buffer))
                    (group (buffer-prepare-change-group buffer)))
               (add-hook
                (variable-value 'after-change-functions :buffer buffer)
                'vundo-test-mutating-throwing-after-change)
               (let ((thrown
                       (unwind-protect
                            (vundo-test-error-p
                             (lambda () (insert-string point "A")))
                         (remove-hook
                          (variable-value 'after-change-functions
                                          :buffer buffer)
                          'vundo-test-mutating-throwing-after-change))))
                 (let ((live-text (buffer-text buffer))
                       (active-before-cancel
                         (buffer-change-group-active-p group)))
                   (let* ((cancelled (buffer-cancel-change-group group))
                          (snapshot (lem:buffer-undo-tree-snapshot buffer)))
                     (and thrown
                          (string= "baseA!" live-text)
                          active-before-cancel
                          cancelled
                          (string= "base" (buffer-text buffer))
                          (not (buffer-change-group-active-p group))
                          (not (getf snapshot :truncated))
                          (= (getf baseline :node-count)
                             (getf snapshot :node-count))
                          (= (getf baseline :payload-bytes)
                             (getf snapshot :payload-bytes))
                          (eql (getf baseline :current)
                               (getf snapshot :current))
                          (vundo-test-snapshot-valid-p snapshot))))))))
      (ignore-errors
        (remove-hook (variable-value 'after-change-functions :buffer buffer)
                     'vundo-test-mutating-throwing-after-change))
      (ignore-errors (delete-buffer buffer)))))

(defun vundo-test-mutating-replay-guard-p ()
  (let ((buffer (make-buffer " *vundo-hook-guard*" :temporary t)))
    (unwind-protect
         (with-current-buffer buffer
           (let ((point (buffer-point buffer)))
             (insert-string point "A")
             (buffer-undo-boundary buffer)
             (buffer-unmark buffer)
             (insert-string point "B")
             (buffer-undo-boundary buffer)
             (add-hook (variable-value 'after-change-functions :buffer buffer)
                       'vundo-test-mutating-after-change)
             (let ((rejected (vundo-test-error-p
                              (lambda () (buffer-undo point)))))
               (remove-hook
                (variable-value 'after-change-functions :buffer buffer)
                'vundo-test-mutating-after-change)
               (let* ((snapshot (lem:buffer-undo-tree-snapshot buffer))
                      (text (buffer-text buffer))
                      (modified (buffer-modified-p buffer))
                      (clean (getf snapshot :clean))
                      (truncated (getf snapshot :truncated))
                      (nodes (getf snapshot :node-count)))
                 (vundo-test-log
                  "HOOK rejected=~a text=~a modified=~a clean=~a truncated=~a nodes=~d"
                  (if rejected "yes" "no") (vundo-test-encode text)
                  (if modified "yes" "no") (or clean "none")
                  (if truncated "yes" "no") nodes)
                 (and rejected
                      (string= text "A!") modified (null clean)
                      truncated (= 1 nodes))))))
      (ignore-errors
        (remove-hook (variable-value 'after-change-functions :buffer buffer)
                     'vundo-test-mutating-after-change))
      (ignore-errors (delete-buffer buffer)))))

(defun vundo-test-throwing-after-change (start end old-length)
  (declare (ignore start end old-length))
  (editor-error "test after-change failure"))

(defun vundo-test-throwing-after-change-recovery-p ()
  "A replay edit followed by a throwing after-change hook must fail dirty."
  (let ((buffer (make-buffer " *vundo-throwing-hook*" :temporary t)))
    (unwind-protect
         (with-current-buffer buffer
           (let ((point (buffer-point buffer)))
             (insert-string point "A")
             (buffer-undo-boundary buffer)
             (insert-string point "B")
             (buffer-undo-boundary buffer)
             ;; Make the current AB node clean.  If replay deletes B and the
             ;; hook then throws, preserving this tree would incorrectly
             ;; report the now-A buffer as clean.
             (buffer-unmark buffer)
             (let ((tick (buffer-modified-tick buffer)))
               (add-hook
                (variable-value 'after-change-functions :buffer buffer)
                'vundo-test-throwing-after-change)
               (let ((rejected
                       (vundo-test-error-p (lambda () (buffer-undo point)))))
                 (remove-hook
                  (variable-value 'after-change-functions :buffer buffer)
                  'vundo-test-throwing-after-change)
                 (let* ((snapshot (lem:buffer-undo-tree-snapshot buffer))
                        (tick-after (buffer-modified-tick buffer))
                        (text (buffer-text buffer))
                        (modified (buffer-modified-p buffer))
                        (clean (getf snapshot :clean))
                        (truncated (getf snapshot :truncated))
                        (nodes (getf snapshot :node-count)))
                   (vundo-test-log
                    (concatenate
                     'string
                     "THROWING-HOOK rejected=~a tick-before=~d "
                     "tick-after=~d text=~a modified=~a clean=~a "
                     "truncated=~a nodes=~d")
                    (if rejected "yes" "no") tick tick-after
                    (vundo-test-encode text)
                    (if modified "yes" "no") (or clean "none")
                    (if truncated "yes" "no") nodes)
                   (and rejected
                        (< tick tick-after)
                        (string= "A" text)
                        modified (null clean) truncated (= 1 nodes)))))))
      (ignore-errors
        (remove-hook (variable-value 'after-change-functions :buffer buffer)
                     'vundo-test-throwing-after-change))
      (ignore-errors (delete-buffer buffer)))))

(defun vundo-test-bounded-pruning-p ()
  "Exercise many sibling leaves plus one protected command over the soft cap."
  (let ((buffer (make-buffer " *vundo-pruning*" :temporary t))
        (large (make-string 2100000 :initial-element #\x)))
    (unwind-protect
         (with-current-buffer buffer
           (let ((point (buffer-point buffer))
                 (root (lem/buffer/internal::ensure-buffer-undo-tree buffer)))
             ;; Reach the configured node cap with a wide root.  The final
             ;; protected edit forces all siblings through the batch-pruner;
             ;; an O(N^2) unlink implementation cannot finish this gate.
             (dotimes (index 65535)
               (declare (ignore index))
               (insert-string point "x")
               (buffer-undo-boundary buffer)
               ;; Public BUFFER-UNDO validates the complete growing graph on
               ;; every iteration and would make fixture setup quadratic.
               ;; Apply only the inverse character as a test replay, then put
               ;; the authoritative pointer back at the root.  The final
               ;; public snapshot validates the constructed graph in full.
               (let ((lem/buffer/internal::*undo-tree-replaying-p* buffer))
                 (delete-character (buffer-start-point buffer) 1))
               (setf (lem/buffer/internal::buffer-%undo-tree-current buffer)
                     root
                     (lem/buffer/internal::buffer-%undo-tree-pending-dirty-p
                      buffer)
                     nil))
             (insert-string point large)
             (buffer-undo-boundary buffer)
             (let* ((snapshot (lem:buffer-undo-tree-snapshot buffer))
                    (root (vundo-test-node snapshot (getf snapshot :root))))
               (and (getf snapshot :truncated)
                    (= 2 (getf snapshot :node-count))
                    (= (length large) (getf snapshot :payload-bytes))
                    (= 1 (length (getf root :children)))
                    (string= large (buffer-text buffer))
                    (vundo-test-snapshot-valid-p snapshot)))))
      (ignore-errors (delete-buffer buffer)))))

(defun vundo-test-read-only-refusal-preserves-p ()
  (let ((buffer (make-buffer " *vundo-read-only*" :temporary t)))
    (unwind-protect
         (with-current-buffer buffer
           (let ((point (buffer-point buffer)))
             (insert-string point "A")
             (buffer-undo-boundary buffer)
             (let ((before (lem:buffer-undo-tree-snapshot buffer))
                   (tick (buffer-modified-tick buffer)))
               (setf (buffer-read-only-p buffer) t)
               (let ((rejected
                       (vundo-test-error-p (lambda () (buffer-undo point)))))
                 (setf (buffer-read-only-p buffer) nil)
                 (and rejected
                      (= tick (buffer-modified-tick buffer))
                      (string= "A" (buffer-text buffer))
                      (buffer-modified-p buffer)
                      (equal before
                             (lem:buffer-undo-tree-snapshot buffer)))))))
      (ignore-errors (delete-buffer buffer)))))

(defun vundo-test-asymmetric-route-refusal-p ()
  "A cheap preview with an over-budget return route must not begin."
  (let ((buffer (make-buffer " *vundo-asymmetric-route*" :temporary t)))
    (unwind-protect
         (with-current-buffer buffer
           (let ((point (buffer-point buffer)))
             (insert-string point (make-string 20 :initial-element #\r))
             (buffer-undo-boundary buffer)
             (buffer-unmark buffer)
             (move-point point (buffer-end-point buffer))
             (insert-string point (make-string 15 :initial-element #\a))
             (buffer-undo-boundary buffer)
             (let* ((branch-snapshot (lem:buffer-undo-tree-snapshot buffer))
                    (large-branch (getf branch-snapshot :current)))
               (buffer-undo point)
               (move-point point (buffer-start-point buffer))
               (delete-character point 15)
               (buffer-undo-boundary buffer)
               (let* ((before (lem:buffer-undo-tree-snapshot buffer))
                      (current (getf before :current))
                      (generation (getf before :generation))
                      (tick (buffer-modified-tick buffer))
                      (text (buffer-text buffer))
                      (rejected
                        (let ((lem/buffer/internal::*undo-tree-route-work-limit*
                                60))
                          (vundo-test-error-p
                           (lambda ()
                             (lem:buffer-undo-tree-move
                              point large-branch generation current))))))
                 (and rejected
                      (= tick (buffer-modified-tick buffer))
                      (string= text (buffer-text buffer))
                      (equal before
                             (lem:buffer-undo-tree-snapshot buffer)))))))
      (ignore-errors (delete-buffer buffer)))))

(defun vundo-test-mutate-after-save (buffer)
  (insert-character (buffer-end-point buffer) #\!))

(defun vundo-test-after-save-descendant-p (path)
  "An after-save mutation must remain dirty below the node actually written."
  (let* ((save-path (format nil "~a.after-save" path))
         (buffer (find-file-buffer save-path)))
    (unwind-protect
         (with-current-buffer buffer
           (insert-string (buffer-point buffer) "S")
           (buffer-undo-boundary buffer)
           (add-hook (variable-value 'after-save-hook :buffer buffer)
                     'vundo-test-mutate-after-save)
           (save-buffer buffer)
           (remove-hook (variable-value 'after-save-hook :buffer buffer)
                        'vundo-test-mutate-after-save)
           (let* ((snapshot (lem:buffer-undo-tree-snapshot buffer))
                  (current (getf snapshot :current))
                  (saved (getf snapshot :last-saved))
                  (disk (uiop:read-file-string save-path)))
             (vundo-test-log
              "SAVE-HOOK disk=~a text=~a current=~a saved=~a modified=~a"
              (vundo-test-encode disk)
              (vundo-test-encode (buffer-text buffer))
              current (or saved "none")
              (if (buffer-modified-p buffer) "yes" "no"))
             (and (string= disk "S")
                  (string= (buffer-text buffer) "S!")
                  saved (not (eql current saved))
                  (buffer-modified-p buffer))))
      (ignore-errors
        (remove-hook (variable-value 'after-save-hook :buffer buffer)
                     'vundo-test-mutate-after-save))
      (ignore-errors (delete-buffer buffer)))))

(defun vundo-test-state-point-restoration-p ()
  "Restore the source position sealed with each text state, like Vundo 2.4."
  (let ((buffer (make-buffer " *vundo-state-points*" :temporary t)))
    (unwind-protect
         (with-current-buffer buffer
           (let ((point (buffer-point buffer)))
             (insert-string point "abcdef")
             (buffer-undo-boundary buffer)
             (move-to-position point 3)
             (insert-string point "X")
             (buffer-undo-boundary buffer)
             (let* ((snapshot (lem:buffer-undo-tree-snapshot buffer))
                    (current (getf snapshot :current))
                    (child (vundo-test-node snapshot current))
                    (parent (vundo-test-node snapshot (getf child :parent)))
                    (root (vundo-test-node snapshot (getf snapshot :root)))
                    (stored
                      (and (= 1 (getf root :point-position))
                           (= 7 (getf parent :point-position))
                           (= 4 (getf child :point-position)))))
               ;; Cursor-only movement after the edit must not overwrite the
               ;; position associated with the sealed child state.
               (move-point point (buffer-end-point buffer))
               (let ((backward
                       (and (buffer-undo point)
                            (string= "abcdef" (buffer-text buffer))
                            (= 7 (position-at-point point))))
                     (forward nil)
                     (transformed nil))
                 (setf forward
                       (and (buffer-redo point)
                            (string= "abXcdef" (buffer-text buffer))
                            (= 4 (position-at-point point))))
                 ;; Edits deliberately excluded from undo are applied to every
                 ;; retained state, so their point positions must move too.
                 (with-inhibit-undo ()
                   (insert-string (buffer-start-point buffer) "!"))
                 (let* ((shifted (lem:buffer-undo-tree-snapshot buffer))
                        (shifted-child
                          (vundo-test-node shifted (getf shifted :current)))
                        (shifted-parent
                          (vundo-test-node shifted
                                           (getf shifted-child :parent)))
                        (shifted-root
                          (vundo-test-node shifted (getf shifted :root))))
                   (setf transformed
                         (and (= 2 (getf shifted-root :point-position))
                              (= 8 (getf shifted-parent :point-position))
                              (= 5 (getf shifted-child :point-position))
                              (buffer-undo point)
                              (string= "!abcdef" (buffer-text buffer))
                              (= 8 (position-at-point point))
                              (buffer-redo point)
                              (string= "!abXcdef" (buffer-text buffer))
                              (= 5 (position-at-point point))
                              (vundo-test-snapshot-valid-p shifted))))
                 (and stored backward forward transformed)))))
      (ignore-errors (delete-buffer buffer)))))

(define-command lem-yath-test-vundo-core-probes () ()
  (let* ((path (uiop:getenv "LEM_YATH_VUNDO_DIRTY_FILE"))
         (buffer (find-file-buffer path))
         (other (make-buffer " *vundo-foreign*" :temporary t))
         (forward-insert-ordered
           (vundo-test-run-probe
            "forward-mutating-insert"
            #'vundo-test-forward-mutating-insert-order-p))
         (forward-delete-ordered
           (vundo-test-run-probe
            "forward-mutating-delete"
            #'vundo-test-forward-mutating-delete-order-p))
         (throwing-group-cancelled
           (vundo-test-run-probe
            "throwing-mutating-change-group"
            #'vundo-test-mutating-throwing-change-group-p))
         (hook-guard (vundo-test-mutating-replay-guard-p))
         (throwing-hook-recovered
           (vundo-test-run-probe
            "throwing-after-change"
            #'vundo-test-throwing-after-change-recovery-p))
         (pruning-bounded (vundo-test-bounded-pruning-p))
         (read-only-preserved (vundo-test-read-only-refusal-preserves-p))
         (asymmetric-refused
           (vundo-test-run-probe
            "asymmetric-route" #'vundo-test-asymmetric-route-refusal-p))
         (after-save-descendant
           (vundo-test-run-probe
            "after-save-descendant"
            (lambda () (vundo-test-after-save-descendant-p path))))
         (state-points-restored
           (vundo-test-run-probe
            "state-point-restoration"
            #'vundo-test-state-point-restoration-p))
         (failures 0))
    (unwind-protect
         (with-current-buffer buffer
           (let ((point (buffer-point buffer)))
             (insert-string point "A")
             (buffer-undo-boundary buffer)
             (let ((tick-edit (buffer-modified-tick buffer)))
               (save-buffer buffer)
               (let* ((tick-save (buffer-modified-tick buffer))
                      (saved-text (buffer-text buffer))
                      (saved-modified (buffer-modified-p buffer))
                      (saved-snapshot (lem:buffer-undo-tree-snapshot buffer))
                      (saved-id (getf saved-snapshot :current))
                      (saved-generation (getf saved-snapshot :generation))
                      (saved-ref (lem:buffer-undo-tree-current buffer))
                      (noop-clean nil))
                 ;; Empty insertions and deletion attempts at end-of-buffer
                 ;; must not advance the content tick, dirty the buffer, or
                 ;; create a phantom undo transaction.
                 (move-point point (buffer-end-point buffer))
                 (insert-string point "")
                 (delete-character point 1)
                 (buffer-undo-boundary buffer)
                 (let ((noop-snapshot
                         (lem:buffer-undo-tree-snapshot buffer)))
                   (setf noop-clean
                         (and (= tick-save (buffer-modified-tick buffer))
                              (not (buffer-modified-p buffer))
                              (string= saved-text (buffer-text buffer))
                              (= saved-generation
                                 (getf noop-snapshot :generation))
                              (= (getf saved-snapshot :node-count)
                                 (getf noop-snapshot :node-count)))))
                 (buffer-undo point)
                 (let ((tick-undo (buffer-modified-tick buffer))
                       (undo-text (buffer-text buffer))
                       (undo-modified (buffer-modified-p buffer)))
                   (insert-string point "B")
                   (buffer-undo-boundary buffer)
                   (let* ((tick-branch (buffer-modified-tick buffer))
                          (branch-text (buffer-text buffer))
                          (branch-modified (buffer-modified-p buffer))
                          (branch-snapshot
                            (lem:buffer-undo-tree-snapshot buffer))
                          (pristine (copy-tree branch-snapshot))
                          (foreign-error
                            (vundo-test-error-p
                             (lambda ()
                               (lem:buffer-undo-tree-move
                                (buffer-point other)
                                (lem:buffer-undo-tree-root buffer)))))
                          (stale-error
                            (vundo-test-error-p
                             (lambda ()
                               (lem:buffer-undo-tree-move
                                point saved-id saved-generation))))
                          (stale-ref-error
                            (vundo-test-error-p
                             (lambda ()
                               (lem:buffer-undo-tree-move point saved-ref))))
                          (invalid-error
                            (vundo-test-error-p
                             (lambda ()
                               (lem:buffer-undo-tree-move
                                point most-positive-fixnum
                                (getf branch-snapshot :generation))))))
                     (setf (getf branch-snapshot :current) -1)
                     (when (getf branch-snapshot :nodes)
                       (setf (getf (first (getf branch-snapshot :nodes))
                                   :children)
                             '(-2)))
                     (let ((immutable
                             (equal pristine
                                    (lem:buffer-undo-tree-snapshot buffer))))
                       (buffer-undo point)
                       (let ((tick-undo-branch (buffer-modified-tick buffer)))
                         (buffer-redo point)
                         (let ((tick-redo (buffer-modified-tick buffer)))
                           (flet ((check (condition)
                                    (unless condition (incf failures))))
                             (check (= tick-edit tick-save))
                             (check noop-clean)
                             (check forward-insert-ordered)
                             (check forward-delete-ordered)
                             (check throwing-group-cancelled)
                             (check hook-guard)
                             (check throwing-hook-recovered)
                             (check pruning-bounded)
                             (check read-only-preserved)
                             (check asymmetric-refused)
                             (check after-save-descendant)
                             (check state-points-restored)
                             (check (< tick-edit tick-undo tick-branch
                                       tick-undo-branch tick-redo))
                             (check (and (string= saved-text "A")
                                         (not saved-modified)))
                             (check (and (string= undo-text "")
                                         undo-modified))
                             (check (and branch-modified
                                         (string= branch-text "B")
                                         (= (length branch-text)
                                            (length saved-text))
                                         (not (string= branch-text
                                                       saved-text))))
                             (check (string= (buffer-text buffer) "B"))
                             (check (and (eql (getf pristine :clean) saved-id)
                                         (eql (getf pristine :last-saved)
                                              saved-id)))
                             (check (vundo-test-snapshot-valid-p pristine))
                             (check immutable)
                             (check foreign-error)
                             (check stale-error)
                             (check stale-ref-error)
                             (check invalid-error))
                           (vundo-test-log
                            (concatenate
                             'string
                             "CORE dirty-branch=~a tick-edit=~d tick-save=~d "
                             "tick-undo=~d tick-branch=~d tick-undo2=~d "
                             "tick-redo=~d increasing=~a no-op=~a hook=~a "
                             "forward-insert=~a forward-delete=~a "
                             "throwing-group=~a "
                             "throwing-hook=~a "
                             "prune=~a read-only=~a asymmetric=~a "
                             "after-save=~a "
                             "graph=~a immutable=~a "
                             "saved-clean=~a undo-dirty=~a equal-count=~a "
                             "foreign=~a stale=~a stale-ref=~a invalid=~a "
                             "text=~a")
                            (if branch-modified "yes" "no")
                            tick-edit tick-save tick-undo tick-branch
                            tick-undo-branch tick-redo
                            (if (< tick-edit tick-undo tick-branch
                                   tick-undo-branch tick-redo)
                                "yes" "no")
                            (if noop-clean "clean" "dirty")
                            (if hook-guard "guarded" "escaped")
                            (if forward-insert-ordered "ordered" "broken")
                            (if forward-delete-ordered "ordered" "broken")
                            (if throwing-group-cancelled "cancelled" "broken")
                            (if throwing-hook-recovered
                                "recovered" "escaped")
                            (if pruning-bounded "bounded" "failed")
                            (if read-only-preserved "preserved" "destroyed")
                            (if asymmetric-refused "rejected" "escaped")
                            (if after-save-descendant "dirty-child" "wrong")
                            (if (vundo-test-snapshot-valid-p pristine)
                                "yes" "no")
                            (if immutable "yes" "no")
                            (if (and (eql (getf pristine :clean) saved-id)
                                     (eql (getf pristine :last-saved)
                                          saved-id))
                                "yes" "no")
                            (if (and (string= undo-text "") undo-modified)
                                "yes" "no")
                            (if (and (= (length branch-text)
                                        (length saved-text))
                                     (not (string= branch-text saved-text)))
                                "yes" "no")
                            (if foreign-error "rejected" "accepted")
                            (if stale-error "rejected" "accepted")
                            (if stale-ref-error "rejected" "accepted")
                            (if invalid-error "rejected" "accepted")
                            (vundo-test-encode (buffer-text buffer))))))))))))
      (ignore-errors (delete-buffer other))
      (ignore-errors (delete-buffer buffer)))
    (vundo-test-log "SUMMARY CORE ~a failures=~d"
                    (if (zerop failures) "PASS" "FAIL") failures)))

(define-command lem-yath-test-vundo-reload () ()
  (let* ((view (current-buffer))
         (open (eq (buffer-major-mode view) 'lem-yath-vundo-mode))
         (entry-id (and open *vundo-session*
                        (vundo-session-entry-id *vundo-session*)))
         (before
           (lem:buffer-undo-tree-snapshot *vundo-test-origin-buffer*)))
    (load *vundo-test-source*)
    (load *vundo-test-source*)
    (let* ((after
             (lem:buffer-undo-tree-snapshot *vundo-test-origin-buffer*))
           (bottom (lem-core::frame-bottomside-window (current-frame))))
      (vundo-test-log
       (concatenate
        'string
        "RELOAD before=~a after=~a focus=~a graph-preserved=~a "
        "origin-read-only=~a bottom=~a old-view=~a")
       (if open "open" "closed")
       (if *vundo-session* "open" "closed")
       (if (eq *vundo-test-origin-buffer* (current-buffer))
           "origin" "other")
       (if (and (equal (vundo-test-snapshot-shape before)
                       (vundo-test-snapshot-shape after))
                (or (not open) (eql entry-id (getf after :current))))
           "yes" "no")
       (if (buffer-read-only-p *vundo-test-origin-buffer*) "yes" "no")
       (if bottom "live" "none")
       (cond ((not open) "n/a")
             ((deleted-buffer-p view) "deleted")
             (t "live"))))))

(defun vundo-test-refuse-before-change (point argument)
  (declare (ignore point argument))
  (editor-error "test rollback refusal"))

(define-command lem-yath-test-vundo-arm-rollback-refusal () ()
  (add-hook
   (variable-value 'before-change-functions :buffer *vundo-test-origin-buffer*)
   'vundo-test-refuse-before-change 20000)
  (vundo-test-log "ARM rollback-refusal=yes"))

(define-command lem-yath-test-vundo-remove-rollback-refusal () ()
  (remove-hook
   (variable-value 'before-change-functions :buffer *vundo-test-origin-buffer*)
   'vundo-test-refuse-before-change)
  (vundo-test-log "ARM rollback-refusal=no"))

(define-command lem-yath-test-vundo-reload-refused () ()
  (let* ((session *vundo-session*)
         (view (and session (vundo-session-tree-buffer session)))
         (buffer *vundo-test-origin-buffer*)
         (load-refused-p nil))
    (add-hook (variable-value 'before-change-functions :buffer buffer)
              'vundo-test-refuse-before-change 20000)
    (unwind-protect
         (handler-case (load *vundo-test-source*)
           (error () (setf load-refused-p t)))
      (remove-hook (variable-value 'before-change-functions :buffer buffer)
                   'vundo-test-refuse-before-change))
    (vundo-test-log
     (concatenate
      'string
      "RELOAD-REFUSED error=~a same-session=~a source=~a read-only=~a "
      "tree=~a bottom=~a focus=~a")
     (if load-refused-p "yes" "no")
     (if (and session (eq session *vundo-session*)) "yes" "no")
     (vundo-test-encode (vundo-test-line buffer 40))
     (if (buffer-read-only-p buffer) "yes" "no")
     (if (vundo-live-buffer-p view) "live" "none")
     (if (lem-core::frame-bottomside-window (current-frame)) "live" "none")
     (if (and session (eq (current-buffer) view)) "vundo" "other"))))

(define-command lem-yath-test-vundo-reopen-refused () ()
  (let* ((session *vundo-session*)
         (view (and session (vundo-session-tree-buffer session)))
         (buffer *vundo-test-origin-buffer*)
         (open-refused-p nil))
    (handler-case (lem-yath-vundo)
      (error () (setf open-refused-p t)))
    (vundo-test-log
     (concatenate
      'string
      "REOPEN-REFUSED error=~a same-session=~a source=~a read-only=~a "
      "tree=~a bottom=~a focus=~a")
     (if open-refused-p "yes" "no")
     (if (and session (eq session *vundo-session*)) "yes" "no")
     (vundo-test-encode (vundo-test-line buffer 40))
     (if (buffer-read-only-p buffer) "yes" "no")
     (if (vundo-live-buffer-p view) "live" "none")
     (if (lem-core::frame-bottomside-window (current-frame)) "live" "none")
     (if (and session (eq (current-buffer) view)) "vundo" "other"))))

(define-command lem-yath-test-vundo-kill-origin () ()
  (let ((view (current-buffer))
        (origin *vundo-test-origin-buffer*))
    (delete-buffer origin)
    (vundo-test-log
     "KILL origin=~a view=~a bottom=~a focus-left=~a"
     (if (deleted-buffer-p origin) "deleted" "live")
     (if (deleted-buffer-p view) "deleted" "live")
     (if (lem-core::frame-bottomside-window (current-frame)) "live" "none")
     (if (eq (current-buffer) view) "no" "yes"))))

(define-command lem-yath-test-vundo-kill-tree () ()
  (let ((view (current-buffer))
        (failure nil))
    (handler-case (delete-buffer view)
      (error (condition)
        (setf failure (princ-to-string condition))))
    (vundo-test-log
     "KILL-TREE view=~a session=~a bottom=~a focus=~a error=~a"
     (if (deleted-buffer-p view) "deleted" "live")
     (if *vundo-session* "open" "closed")
     (if (lem-core::frame-bottomside-window (current-frame)) "live" "none")
     (if (eq (current-buffer) *vundo-test-origin-buffer*)
         "origin" "other")
     (if failure (vundo-test-encode failure) "none"))))

(defun vundo-test-position (buffer line column)
  (with-point ((point (buffer-start-point buffer)))
    (move-to-line point line)
    (move-to-column point column)
    (position-at-point point)))

(define-command lem-yath-test-vundo-install-bottom () ()
  (when (lem-core::frame-bottomside-window (current-frame))
    (delete-bottomside-window))
  (when (vundo-live-buffer-p *vundo-test-bottom-buffer*)
    (delete-buffer *vundo-test-bottom-buffer*))
  (let ((buffer (make-buffer "*vundo prior bottom*" :enable-undo-p nil)))
    (buffer-disable-undo buffer)
    (with-buffer-read-only buffer nil
      (erase-buffer buffer)
      (dotimes (index 8)
        (insert-string
         (buffer-point buffer)
         (format nil "bottom-~d-abcdefghijklmnopqrstuvwxyz~%" (1+ index)))))
    (let ((window (make-bottomside-window buffer :height 5)))
      (vundo-reset-window-buffer
       window buffer
       (vundo-test-position buffer 4 12)
       (vundo-test-position buffer 2 3))
      (resize-bottomside-window window 5)
      (hide-cursor window)
      (setf (window-parameter window 'lem-core::horizontal-scroll-start) 7
            *vundo-test-bottom-buffer* buffer
            *vundo-test-bottom-window* window)
      (vundo-test-log "BOTTOM installed=yes"))))

(define-command lem-yath-test-vundo-record-bottom () ()
  (let ((window (lem-core::frame-bottomside-window (current-frame))))
    (vundo-test-log
     (concatenate
      'string
      "BOTTOM live=~a buffer=~a same-window=~a height=~a point=~a:~a "
      "view=~a:~a cursor-hidden=~a hscroll=~a session=~a tree=~a diff=~a")
     (if (and window (not (deleted-window-p window))) "yes" "no")
     (if (and window (eq (window-buffer window) *vundo-test-bottom-buffer*))
         "yes" "no")
     (if (and window (eq window *vundo-test-bottom-window*)) "yes" "no")
     (if window (window-height window) "none")
     (if window (line-number-at-point (lem-core::%window-point window)) "none")
     (if window (point-column (lem-core::%window-point window)) "none")
     (if window (line-number-at-point (window-view-point window)) "none")
     (if window (point-column (window-view-point window)) "none")
     (if (and window (window-cursor-invisible-p window)) "yes" "no")
     (or (and window
              (window-parameter window 'lem-core::horizontal-scroll-start))
         0)
     (if *vundo-session* "open" "closed")
     (if (vundo-test-live-tree-buffers) "live" "none")
     (if (vundo-test-live-diff-buffers) "live" "none"))))

(define-command lem-yath-test-vundo-clear-bottom () ()
  (when (lem-core::frame-bottomside-window (current-frame))
    (delete-bottomside-window))
  (when (vundo-live-buffer-p *vundo-test-bottom-buffer*)
    (delete-buffer *vundo-test-bottom-buffer*))
  (setf *vundo-test-bottom-buffer* nil
        *vundo-test-bottom-window* nil)
  (vundo-test-log "BOTTOM cleared=yes"))

(define-command lem-yath-test-vundo-delete-tree-window () ()
  (let* ((session *vundo-session*)
         (window (and session (vundo-session-tree-window session)))
         (failure nil))
    (when (and session
               (not (deleted-window-p (vundo-session-origin-window session))))
      (setf (current-window) (vundo-session-origin-window session)))
    (handler-case
        (when window (delete-window window))
      (error (condition)
        (setf failure (princ-to-string condition))))
    (vundo-test-log "DELETE-WINDOW error=~a"
                    (if failure (vundo-test-encode failure) "none"))))

(defun vundo-test-close-tree-on-change (start end old-length)
  (declare (ignore start end old-length))
  (remove-hook
   (variable-value 'after-change-functions :buffer *vundo-test-origin-buffer*)
   'vundo-test-close-tree-on-change)
  (when *vundo-session*
    (delete-buffer (vundo-session-tree-buffer *vundo-session*))))

(define-command lem-yath-test-vundo-arm-change-close () ()
  (add-hook
   (variable-value 'after-change-functions :buffer *vundo-test-origin-buffer*)
   'vundo-test-close-tree-on-change)
  (vundo-test-log "ARM change-close=yes"))

(defun vundo-test-close-tree-after-save (buffer)
  (remove-hook (variable-value 'after-save-hook :buffer buffer)
               'vundo-test-close-tree-after-save)
  (when *vundo-session*
    (delete-buffer (vundo-session-tree-buffer *vundo-session*))))

(define-command lem-yath-test-vundo-arm-save-close () ()
  (add-hook
   (variable-value 'after-save-hook :buffer *vundo-test-origin-buffer*)
   'vundo-test-close-tree-after-save)
  (vundo-test-log "ARM save-close=yes"))

(define-command lem-yath-test-vundo-make-generation-stale () ()
  (let ((buffer *vundo-test-origin-buffer*))
    (setf (buffer-read-only-p buffer) nil)
    (unwind-protect
         (with-point ((point (buffer-start-point buffer)))
           (move-to-line point 40)
           (line-end point)
           (insert-character point #\Z)
           (buffer-undo-boundary buffer))
      (when *vundo-session*
        (setf (buffer-read-only-p buffer) t)))
    (vundo-test-log "STALE line40=~a"
                    (vundo-test-encode (vundo-test-line buffer 40)))))

(define-command lem-yath-test-vundo-kill-diff () ()
  (let* ((session *vundo-session*)
         (buffer (and session (vundo-session-diff-buffer session)))
         (failure nil))
    (handler-case
        (when buffer (delete-buffer buffer))
      (error (condition)
        (setf failure (princ-to-string condition))))
    (vundo-test-log
     "KILL-DIFF session=~a buffers=~d windows=~d error=~a"
     (if *vundo-session* "open" "closed")
     (length (vundo-test-live-diff-buffers))
     (length (window-list))
     (if failure (vundo-test-encode failure) "none"))))

(define-key *global-keymap* "F1" 'lem-yath-test-vundo-static)
(define-key *global-keymap* "F2" 'lem-yath-test-vundo-record-origin)
(define-key *global-keymap* "F3" 'lem-yath-test-vundo-check-branch)
(define-key *global-keymap* "F4" 'lem-yath-test-vundo-record-view)
(define-key *global-keymap* "F5" 'lem-yath-test-vundo-reload)
(define-key *global-keymap* "F6" 'lem-yath-test-vundo-kill-origin)
(define-key *global-keymap* "F7" 'lem-yath-test-vundo-core-probes)
(define-key *global-keymap* "F8" 'lem-yath-test-vundo-install-bottom)
(define-key *global-keymap* "F9" 'lem-yath-test-vundo-record-bottom)
(define-key *global-keymap* "F10" 'lem-yath-test-vundo-clear-bottom)
(define-key *lem-yath-vundo-mode-keymap* "K"
  'lem-yath-test-vundo-kill-tree)
(define-key *lem-yath-vundo-mode-keymap* "T"
  'lem-yath-test-vundo-record-state)
(define-key *lem-yath-vundo-mode-keymap* "X"
  'lem-yath-test-vundo-delete-tree-window)
(define-key *lem-yath-vundo-mode-keymap* "H"
  'lem-yath-test-vundo-arm-change-close)
(define-key *lem-yath-vundo-mode-keymap* "J"
  'lem-yath-test-vundo-arm-save-close)
(define-key *lem-yath-vundo-mode-keymap* "G"
  'lem-yath-test-vundo-make-generation-stale)
(define-key *lem-yath-vundo-mode-keymap* "Y"
  'lem-yath-test-vundo-kill-diff)
(define-key *lem-yath-vundo-mode-keymap* "O"
  'lem-yath-test-vundo-reload-refused)
(define-key *lem-yath-vundo-mode-keymap* "N"
  'lem-yath-test-vundo-reopen-refused)
(define-key *lem-yath-vundo-mode-keymap* "P"
  'lem-yath-test-vundo-arm-rollback-refusal)
(define-key *lem-yath-vundo-mode-keymap* "I"
  'lem-yath-test-vundo-remove-rollback-refusal)

(setf *vundo-test-origin-buffer* (current-buffer)
      *vundo-test-origin-window* (current-window))
(vundo-test-log "READY")
