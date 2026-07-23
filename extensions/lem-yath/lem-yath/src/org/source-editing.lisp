;;;; Dedicated source-block editing with the configured preserved indentation.

(in-package :lem-yath)

(when (fboundp 'org-source-edit-cleanup-for-reload)
  (org-source-edit-cleanup-for-reload))

(defvar *org-source-edit-keymap*
  (make-keymap :description '*org-source-edit-keymap*))

(define-minor-mode org-source-edit-mode
    (:name "OrgSrc"
     :description "Edit one Org source block in its language mode."
     :keymap *org-source-edit-keymap*))

(defstruct org-source-edit-session
  origin-buffer
  origin-window
  origin-point
  body-start
  body-end
  opening-line
  closing-line
  source-body
  language
  edit-buffer
  closing-p)

(defun org-source-edit-live-buffer-p (buffer)
  (and (bufferp buffer) (not (deleted-buffer-p buffer))))

(defun org-source-edit-session-for-buffer (&optional (buffer (current-buffer)))
  (and (org-source-edit-live-buffer-p buffer)
       (buffer-value buffer 'org-source-edit-session)))

(defun org-source-edit-structural-line-p (line index)
  (let ((end index))
    (loop :while (and (< end (length line))
                      (char= (char line end) #\,))
          :do (incf end))
    (or (and (< end (length line))
             (char= (char line end) #\*))
        (and (< (1+ end) (length line))
             (char= (char line end) #\#)
             (char= (char line (1+ end)) #\+)))))

(defun org-source-edit-transform-line (line escape-p)
  (let ((index (position-if-not
                (lambda (character)
                  (member character '(#\Space #\Tab)))
                line)))
    (cond
      ((null index) line)
      ((and escape-p (org-source-edit-structural-line-p line index))
       (concatenate 'string (subseq line 0 index) "," (subseq line index)))
      ((and (not escape-p)
            (char= (char line index) #\,)
            (org-source-edit-structural-line-p line (1+ index)))
       (concatenate 'string (subseq line 0 index) (subseq line (1+ index))))
      (t line))))

(defun org-source-edit-transform (text escape-p)
  "Apply GNU Org's comma escaping or unescaping to source TEXT."
  (with-output-to-string (output)
    (loop :with start := 0
          :for newline := (position #\Newline text :start start)
          :do
             (write-string
              (org-source-edit-transform-line
               (subseq text start (or newline (length text))) escape-p)
              output)
             (unless newline (return))
             (write-char #\Newline output)
             (setf start (1+ newline)))))

(defun org-source-edit-content (buffer)
  (let ((text (points-to-string (buffer-start-point buffer)
                                (buffer-end-point buffer))))
    (when (> (length text) *org-babel-input-limit*)
      (editor-error "The Org source edit exceeds the configured input limit"))
    (when (and (plusp (length text))
               (not (char= (char text (1- (length text))) #\Newline)))
      (setf text (concatenate 'string text (string #\Newline))))
    (org-source-edit-transform text t)))

(defun org-source-edit-mode-symbol (language)
  (labels ((available-mode (package-name symbol-name)
             (alexandria:when-let* ((package (find-package package-name))
                                    (symbol (find-symbol symbol-name package)))
               (and (ignore-errors (ensure-mode-object symbol)) symbol))))
    (let ((normalized (org-babel-normalized-language language)))
      (or
       (cond
         ((string= normalized "bash")
          (available-mode "LEM-POSIX-SHELL-MODE" "POSIX-SHELL-MODE"))
         ((string= normalized "python")
          (available-mode "LEM-PYTHON-MODE" "PYTHON-MODE"))
         ((member normalized '("c" "c++") :test #'string=)
          (available-mode "LEM-C-MODE" "C-MODE"))
         ((string= normalized "nix")
          (available-mode "LEM-NIX-MODE" "NIX-MODE"))
         ((member normalized '("sql" "sqlite" "dsq") :test #'string=)
          (available-mode "LEM-SQL-MODE" "SQL-MODE")))
       'lem/buffer/fundamental-mode:fundamental-mode))))

(defun org-source-edit-block-matches-session-p (block session)
  (and block
       (eq (point-buffer (org-babel-block-body-start block))
           (org-source-edit-session-origin-buffer session))
       (= (position-at-point (org-babel-block-body-start block))
          (position-at-point (org-source-edit-session-body-start session)))
       (= (position-at-point (org-babel-block-end block))
          (position-at-point (org-source-edit-session-body-end session)))
       (string= (line-string (org-babel-block-begin block))
                (org-source-edit-session-opening-line session))
       (string= (line-string (org-babel-block-end block))
                (org-source-edit-session-closing-line session))
       (string= (org-babel-block-language block)
                (org-source-edit-session-language session))))

(defun org-source-edit-current-block (session)
  (let ((origin (org-source-edit-session-origin-buffer session)))
    (unless (org-source-edit-live-buffer-p origin)
      (editor-error "The Org source buffer no longer exists"))
    (let ((block
            (with-current-buffer origin
              (org-babel-block-at-point
               (org-source-edit-session-body-start session) t))))
      (unless (org-source-edit-block-matches-session-p block session)
        (editor-error "The Org source block changed while it was being edited"))
      (unless (string= (org-babel-block-body block)
                       (org-source-edit-session-source-body session))
        (editor-error "The Org source body changed while it was being edited"))
      block)))

(defun org-source-edit-update-markers (session block)
  (move-point (org-source-edit-session-body-start session)
              (org-babel-block-body-start block))
  (move-point (org-source-edit-session-body-end session)
              (org-babel-block-end block)))

(defun org-source-edit-write-back (session &key save-source-p)
  "Write SESSION back as one source-buffer undo step."
  (let* ((edit-buffer (org-source-edit-session-edit-buffer session))
         (origin (org-source-edit-session-origin-buffer session))
         (block (org-source-edit-current-block session))
         (new-body (org-source-edit-content edit-buffer))
         (changed-p (not (string= new-body (org-babel-block-body block)))))
    (when (buffer-read-only-p origin)
      (editor-error "The Org source buffer is read-only"))
    (when changed-p
      (let ((start (copy-point (org-babel-block-body-start block) :temporary))
            (end (copy-point (org-babel-block-end block) :temporary)))
        (buffer-disable-undo-boundary origin)
        (unwind-protect
             (progn
               (delete-between-points start end)
               (insert-string start new-body))
          (buffer-enable-undo-boundary origin)
          (buffer-undo-boundary origin)))
      (let ((updated
              (with-current-buffer origin
                (org-babel-block-at-point
                 (org-source-edit-session-body-start session) t))))
        (unless updated
          (editor-error "Could not relocate the edited Org source block"))
        (org-source-edit-update-markers session updated))
      (setf (org-source-edit-session-source-body session) new-body))
    (when save-source-p
      (unless (buffer-filename origin)
        (editor-error "The Org source buffer has no file to save"))
      (save-buffer origin))
    (buffer-unmark edit-buffer)
    changed-p))

(defun org-source-edit-coordinate (point start)
  (let ((line-end (copy-point point :temporary)))
    (line-end line-end)
    (values (max 0 (- (line-number-at-point point)
                      (line-number-at-point start)))
            (- (position-at-point point)
               (position-at-point line-end)))))

(defun org-source-edit-move-to-coordinate (point start end line end-offset)
  (move-point point start)
  (dotimes (_ line)
    (unless (and (< (position-at-point point) (position-at-point end))
                 (line-offset point 1))
      (return)))
  (let ((line-start-position (position-at-point point)))
    (line-end point)
    (move-to-position
     point
     (max line-start-position
          (min (position-at-point end)
               (+ (position-at-point point) end-offset)))))
  point)

(defun org-source-edit-origin-live-p (session)
  (let ((origin (org-source-edit-session-origin-buffer session)))
    (and (org-source-edit-live-buffer-p origin)
         (ignore-errors
           (eq (point-buffer (org-source-edit-session-origin-point session))
               origin)))))

(defun org-source-edit-restore-origin (session line end-offset)
  (unless (org-source-edit-origin-live-p session)
    (editor-error "The Org source buffer no longer exists"))
  (let ((window (org-source-edit-session-origin-window session))
        (origin (org-source-edit-session-origin-buffer session)))
    (when (and window (not (deleted-window-p window)))
      (setf (current-window) window))
    (unless (eq (current-buffer) origin)
      (switch-to-buffer origin nil nil))
    (org-source-edit-move-to-coordinate
     (current-point)
     (org-source-edit-session-body-start session)
     (org-source-edit-session-body-end session)
     line end-offset)))

(defun org-source-edit-release-points (session)
  (dolist (point (list (org-source-edit-session-origin-point session)
                       (org-source-edit-session-body-start session)
                       (org-source-edit-session-body-end session)))
    (when point (ignore-errors (delete-point point))))
  (setf (org-source-edit-session-origin-point session) nil
        (org-source-edit-session-body-start session) nil
        (org-source-edit-session-body-end session) nil))

(defun org-source-edit-disable-buffer (session)
  (let ((buffer (org-source-edit-session-edit-buffer session)))
    (when (org-source-edit-live-buffer-p buffer)
      (with-current-buffer buffer
        (remove-hook (variable-value 'before-save-hook :buffer buffer)
                     'org-source-edit-before-save-hook)
        (remove-hook (variable-value 'kill-buffer-hook :buffer buffer)
                     'org-source-edit-kill-buffer-hook)
        (setf (buffer-value buffer 'org-source-edit-session) nil)
        (when (mode-active-p buffer 'org-source-edit-mode)
          (org-source-edit-mode nil))))))

(defun org-source-edit-close (session)
  (unless (org-source-edit-session-closing-p session)
    (setf (org-source-edit-session-closing-p session) t)
    (org-source-edit-disable-buffer session)
    (org-source-edit-release-points session)))

(defun org-source-edit-before-save-hook (&optional
                                           (buffer (current-buffer)))
  (when (org-source-edit-session-for-buffer buffer)
    (editor-error
     "Use C-x C-s to save the Org source or C-c ' to write back and exit")))

(defun org-source-edit-kill-buffer-hook (&optional (buffer (current-buffer)))
  (alexandria:when-let ((session (org-source-edit-session-for-buffer buffer)))
    (unless (org-source-edit-session-closing-p session)
      (setf (org-source-edit-session-closing-p session) t)
      (when (org-source-edit-origin-live-p session)
        (ignore-errors
          (org-source-edit-restore-origin session 0 0)))
      (org-source-edit-release-points session))))

(defun org-source-edit-origin-kill-buffer-hook (&optional
                                                  (origin (current-buffer)))
  (dolist (buffer (copy-list (buffer-list)))
    (alexandria:when-let ((session (org-source-edit-session-for-buffer buffer)))
      (when (eq origin (org-source-edit-session-origin-buffer session))
        (setf (org-source-edit-session-closing-p session) t)
        (org-source-edit-disable-buffer session)
        (org-source-edit-release-points session)
        (when (org-source-edit-live-buffer-p buffer)
          (with-global-variable-value (kill-buffer-hook nil)
            (delete-buffer buffer)))))))

(defun org-source-edit-find-session (block)
  (find-if
   (lambda (buffer)
     (alexandria:when-let ((session (org-source-edit-session-for-buffer buffer)))
       (and (eq (org-source-edit-session-origin-buffer session)
                (point-buffer (org-babel-block-begin block)))
            (= (position-at-point (org-source-edit-session-body-start session))
               (position-at-point (org-babel-block-body-start block)))
            session)))
   (buffer-list)))

(defun org-source-edit-open (block)
  (alexandria:when-let ((existing (org-source-edit-find-session block)))
    (switch-to-buffer existing nil nil)
    (message "Continue editing this Org source block")
    (return-from org-source-edit-open existing))
  (let* ((origin (current-buffer))
         (origin-point (copy-point (current-point) :right-inserting))
         (body-start (copy-point (org-babel-block-body-start block)
                                 :left-inserting))
         (body-end (copy-point (org-babel-block-end block) :right-inserting))
         (language (org-babel-block-language block))
         (body (org-babel-block-body block))
         (edit-text (org-source-edit-transform body nil))
         (name (unique-buffer-name
                (format nil "*Org Src ~a [~a]*"
                        (buffer-name origin) language)))
         (buffer (make-buffer name
                              :directory (ignore-errors
                                           (buffer-directory origin))))
         (session
           (make-org-source-edit-session
            :origin-buffer origin
            :origin-window (current-window)
            :origin-point origin-point
            :body-start body-start
            :body-end body-end
            :opening-line (line-string (org-babel-block-begin block))
            :closing-line (line-string (org-babel-block-end block))
            :source-body body
            :language language
            :edit-buffer buffer)))
    (multiple-value-bind (line end-offset)
        (if (and (<= (position-at-point body-start)
                     (position-at-point origin-point))
                 (<= (position-at-point origin-point)
                     (position-at-point body-end)))
            (org-source-edit-coordinate origin-point body-start)
            (values 0 0))
      (change-buffer-mode buffer (org-source-edit-mode-symbol language))
      (insert-string (buffer-start-point buffer) edit-text)
      (buffer-unmark buffer)
      (setf (buffer-value buffer 'org-source-edit-session) session)
      (with-current-buffer buffer
        (add-hook (variable-value 'before-save-hook :buffer buffer)
                  'org-source-edit-before-save-hook)
        (add-hook (variable-value 'kill-buffer-hook :buffer buffer)
                  'org-source-edit-kill-buffer-hook)
        (org-source-edit-mode t))
      (switch-to-buffer buffer nil nil)
      (org-source-edit-move-to-coordinate
       (current-point) (buffer-start-point buffer) (buffer-end-point buffer)
       line end-offset)
      (message "Edit, then C-c ' to finish or C-c C-k to abort")
      buffer)))

(define-command lem-yath-org-edit-special (argument) (:universal-nil)
  "Edit the Org source block at point in a language-mode buffer."
  (when argument
    (editor-error "Org Babel session-buffer editing is not configured"))
  (when (buffer-read-only-p (current-buffer))
    (editor-error "Org buffer is read-only"))
  (let ((block (or (org-babel-block-at-point (current-point) t)
                   (editor-error "Point is not in an Org source block"))))
    (when (> (length (org-babel-block-body block)) *org-babel-input-limit*)
      (editor-error "The Org source block exceeds the configured input limit"))
    (org-source-edit-open block)))

(define-command lem-yath-org-edit-src-exit () ()
  "Write the edited source block back and return to its Org buffer."
  (let ((session (or (org-source-edit-session-for-buffer)
                     (editor-error "This is not an Org source edit buffer"))))
    (multiple-value-bind (line end-offset)
        (org-source-edit-coordinate
         (current-point) (buffer-start-point (current-buffer)))
      (org-source-edit-write-back session)
      (let ((edit-buffer (org-source-edit-session-edit-buffer session)))
        (org-source-edit-restore-origin session line end-offset)
        (org-source-edit-close session)
        (when (org-source-edit-live-buffer-p edit-buffer)
          (with-global-variable-value (kill-buffer-hook nil)
            (delete-buffer edit-buffer))))
      (message "Org source block updated"))))

(define-command lem-yath-org-edit-src-abort () ()
  "Discard edit-buffer changes and return to the Org source buffer."
  (let ((session (or (org-source-edit-session-for-buffer)
                     (editor-error "This is not an Org source edit buffer"))))
    (let ((edit-buffer (org-source-edit-session-edit-buffer session)))
      (org-source-edit-restore-origin session 0 0)
      (org-source-edit-close session)
      (when (org-source-edit-live-buffer-p edit-buffer)
        (with-global-variable-value (kill-buffer-hook nil)
          (delete-buffer edit-buffer))))
    (message "Org source edit aborted")))

(define-command lem-yath-org-edit-src-save () ()
  "Write the edit buffer back and save its Org source file."
  (let ((session (or (org-source-edit-session-for-buffer)
                     (editor-error "This is not an Org source edit buffer"))))
    (org-source-edit-write-back session :save-source-p t)
    (message "Org source block written and saved")))

(defun org-source-edit-cleanup-for-reload ()
  (dolist (buffer (copy-list (buffer-list)))
    (alexandria:when-let ((session (org-source-edit-session-for-buffer buffer)))
      (when (org-source-edit-origin-live-p session)
        (ignore-errors (org-source-edit-restore-origin session 0 0)))
      (setf (org-source-edit-session-closing-p session) t)
      (org-source-edit-disable-buffer session)
      (org-source-edit-release-points session)
      (when (org-source-edit-live-buffer-p buffer)
        (with-global-variable-value (kill-buffer-hook nil)
          (delete-buffer buffer))))))

(define-key *org-mode-keymap* "C-c '" 'lem-yath-org-edit-special)
(define-key *org-source-edit-keymap* "C-c '" 'lem-yath-org-edit-src-exit)
(define-key *org-source-edit-keymap* "C-c C-k" 'lem-yath-org-edit-src-abort)
(define-key *org-source-edit-keymap* "C-x C-s" 'lem-yath-org-edit-src-save)

(remove-hook (variable-value 'kill-buffer-hook :global t)
             'org-source-edit-origin-kill-buffer-hook)
(add-hook (variable-value 'kill-buffer-hook :global t)
          'org-source-edit-origin-kill-buffer-hook)
