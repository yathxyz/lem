(in-package :lem-yath)

(define-major-mode lem-yath-auto-test-mode ()
    (:name "AutoTest"))

(define-major-mode lem-yath-auto-other-mode ()
    (:name "AutoOther"))

(defvar *auto-test-callbacks* (make-hash-table :test 'equal))
(defvar *auto-test-primary-label* "primaryOnlyCandidate")
(defvar *auto-test-origin-buffer* nil)
(defvar *auto-test-corfu-accept-count* 0)
(defvar *auto-test-valid-focus-count* 0)
(defvar *auto-test-valid-accept-count* 0)
(defvar *auto-test-sentinel-window* nil)
(defvar *auto-test-sentinel-buffer* nil)
(defvar *auto-test-recursive-change-group* nil)
(defvar *auto-test-recursive-change-attempted-p* nil)
(defvar *auto-test-recursive-change-rejected-p* nil)
(defvar *auto-test-refusal-node-ref* nil)
(defvar *auto-test-cross-buffer-target* nil)
(defvar *auto-test-cross-buffer-fired-p* nil)
(defvar *auto-test-abort-replay-group* nil)
(defvar *auto-test-abort-replay-attempted-p* nil)
(defvar *auto-test-abort-replay-rejected-p* nil)
(defparameter *auto-test-corfu-labels*
  '("previewAlpha" "previewBeta" "previewGamma"))

(defun auto-test-report (control &rest arguments)
  (with-open-file (stream (uiop:getenv "LEM_YATH_AUTO_COMPLETION_REPORT")
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun auto-test-buffer-text ()
  (points-to-string (buffer-start-point (current-buffer))
                    (buffer-end-point (current-buffer))))

(defun auto-test-fill-buffer (name mode text)
  (let ((buffer (or (get-buffer name) (make-buffer name))))
    (change-buffer-mode buffer mode)
    (with-current-buffer buffer
      (erase-buffer buffer)
      (insert-string (buffer-point buffer) text)
      (buffer-start (buffer-point buffer)))
    buffer))

(defun auto-test-reset-current-buffer ()
  (lem/completion-mode:completion-end)
  (auto-completion-cancel-timer)
  (setf *auto-completion-context* nil)
  (change-buffer-mode (current-buffer) 'lem-yath-auto-test-mode)
  (setf (variable-value 'lem/language-mode:completion-spec
                        :buffer (current-buffer))
        nil)
  (erase-buffer (current-buffer)))

(defun auto-test-dabbrev-source-text ()
  (with-output-to-string (stream)
    (dotimes (index 12)
      (format stream "alphaCandidate~2,'0d~%" index))))

(define-command lem-yath-test-auto-dabbrev-setup () ()
  (auto-test-reset-current-buffer)
  (setf *auto-test-origin-buffer* (current-buffer))
  (auto-test-fill-buffer "*auto-completion-source*"
                         'lem-yath-auto-test-mode
                         (auto-test-dabbrev-source-text))
  (auto-test-fill-buffer "*auto-completion-foreign*"
                         'lem-yath-auto-other-mode
                         "alphaForeignCandidate\n")
  (auto-test-fill-buffer "*auto-completion-target*"
                         'lem-yath-auto-other-mode
                         "")
  (auto-test-report "SETUP dabbrev"))

(define-command lem-yath-test-auto-middle-setup () ()
  (auto-test-reset-current-buffer)
  (setf *auto-test-primary-label* "banana")
  (auto-test-fill-buffer "*auto-completion-source*"
                         'lem-yath-auto-test-mode
                         "")
  (setf (variable-value 'lem/language-mode:completion-spec
                        :buffer (current-buffer))
        #'auto-test-primary-provider)
  (insert-string (current-point) "baZZ")
  (buffer-start (current-point))
  (character-offset (current-point) 2)
  (auto-test-report "SETUP middle"))

(defun auto-test-primary-provider (point)
  (multiple-value-bind (start end prefix)
      (auto-completion-symbol-bounds point)
    (auto-test-report "PRIMARY ~a" prefix)
    (list
     (lem/completion-mode:make-completion-item
      :label *auto-test-primary-label*
      :filter-text *auto-test-primary-label*
      :insert-text *auto-test-primary-label*
      :detail "Primary"
      :start start
      :end end
      :accept-action
      (lambda ()
        (auto-test-report "ACCEPT primary buffer=~a"
                          (auto-test-buffer-text)))))))

(defun auto-test-corfu-provider (point)
  (multiple-value-bind (start end prefix)
      (auto-completion-symbol-bounds point)
    (auto-test-report "CORFU REQUEST ~a" prefix)
    (mapcar
     (lambda (label)
       (lem/completion-mode:make-completion-item
        :label label
        :filter-text label
        :insert-text label
        :detail "Corfu"
        :start start
        :end end
        :accept-action
        (lambda ()
          (incf *auto-test-corfu-accept-count*)
          (auto-test-report "CORFU ACCEPT ~a count=~d buffer=~a"
                            label
                            *auto-test-corfu-accept-count*
                            (auto-test-buffer-text)))))
     *auto-test-corfu-labels*)))

(defun auto-test-valid-provider (point)
  "Keep an exact candidate behind a longer first item for preselect=valid."
  (multiple-value-bind (start end prefix)
      (auto-completion-symbol-bounds point)
    (auto-test-report "VALID REQUEST ~a" prefix)
    (mapcar
     (lambda (label)
       (lem/completion-mode:make-completion-item
        :label label
        :filter-text label
        :insert-text label
        :detail "Valid"
        :start start
        :end end
        :focus-action
        (lambda (context)
          (declare (ignore context))
          (incf *auto-test-valid-focus-count*)
          (auto-test-report "VALID FOCUS ~a count=~d"
                            label *auto-test-valid-focus-count*))
        :accept-action
        (lambda ()
          (incf *auto-test-valid-accept-count*)
          (auto-test-report "VALID ACCEPT ~a count=~d buffer=~a"
                            label
                            *auto-test-valid-accept-count*
                            (auto-test-buffer-text)))))
     '("validExtra" "valid"))))

(define-command lem-yath-test-auto-corfu-setup () ()
  (auto-test-reset-current-buffer)
  (setf *auto-test-corfu-accept-count* 0
        *auto-test-origin-buffer* (current-buffer))
  (auto-test-fill-buffer "*auto-completion-source*"
                         'lem-yath-auto-test-mode
                         "")
  (setf (variable-value 'lem/language-mode:completion-spec
                        :buffer (current-buffer))
        #'auto-test-corfu-provider)
  (auto-test-report "SETUP corfu"))

(define-command lem-yath-test-auto-corfu-middle-setup () ()
  (lem-yath-test-auto-corfu-setup)
  (insert-string (current-point) "prZZ")
  (buffer-start (current-point))
  (character-offset (current-point) 2)
  (auto-test-report "SETUP corfu-middle"))

(define-command lem-yath-test-auto-valid-setup () ()
  (auto-test-reset-current-buffer)
  (setf *auto-test-valid-focus-count* 0
        *auto-test-valid-accept-count* 0
        *auto-test-origin-buffer* (current-buffer))
  (auto-test-fill-buffer "*auto-completion-source*"
                         'lem-yath-auto-test-mode
                         "")
  (setf (variable-value 'lem/language-mode:completion-spec
                        :buffer (current-buffer))
        #'auto-test-valid-provider)
  (insert-string (current-point) "vali")
  (auto-test-report "SETUP valid"))

(define-command lem-yath-test-auto-corfu-lisp-setup () ()
  (lem-yath-test-auto-corfu-setup)
  (change-buffer-mode (current-buffer) 'lem-lisp-mode:lisp-mode)
  (lem-paredit-mode:paredit-mode t)
  (setf (variable-value 'lem/language-mode:completion-spec
                        :buffer (current-buffer))
        #'auto-test-corfu-provider)
  (auto-test-report "SETUP corfu-lisp paredit=~s"
                    (mode-active-p (current-buffer)
                                   'lem-paredit-mode:paredit-mode)))

(define-command lem-yath-test-auto-primary-setup () ()
  (auto-test-reset-current-buffer)
  (setf *auto-test-primary-label* "primaryOnlyCandidate")
  (auto-test-fill-buffer "*auto-completion-source*"
                         'lem-yath-auto-test-mode
                         "privateFallbackCandidate\n")
  (setf (variable-value 'lem/language-mode:completion-spec
                        :buffer (current-buffer))
        #'auto-test-primary-provider)
  (auto-test-report "SETUP primary"))

(define-command lem-yath-test-auto-cancel-setup () ()
  (auto-test-reset-current-buffer)
  (setf *auto-test-primary-label* "cancelShouldNotAppear")
  (auto-test-fill-buffer "*auto-completion-source*"
                         'lem-yath-auto-test-mode
                         "")
  (setf (variable-value 'lem/language-mode:completion-spec
                        :buffer (current-buffer))
        #'auto-test-primary-provider)
  (auto-test-report "SETUP cancel"))

(define-command lem-yath-test-auto-file-setup () ()
  (auto-test-reset-current-buffer)
  (auto-test-fill-buffer "*auto-completion-source*"
                         'lem-yath-auto-test-mode
                         "")
  (alexandria:when-let ((directory
                         (uiop:getenv "LEM_YATH_AUTO_COMPLETION_FILE_DIR")))
    (setf (buffer-directory) directory))
  (auto-test-report "SETUP file directory=~a" (buffer-directory)))

(defun auto-test-async-provider (point then)
  (multiple-value-bind (start end query)
      (auto-completion-symbol-bounds point)
    (declare (ignore start end))
    (setf (gethash query *auto-test-callbacks*) then)
    (auto-test-report "REQUEST ~a" query)))

(define-command lem-yath-test-auto-async-setup () ()
  (auto-test-reset-current-buffer)
  (clrhash *auto-test-callbacks*)
  (auto-test-fill-buffer "*auto-completion-source*"
                         'lem-yath-auto-test-mode
                         "")
  (setf (variable-value 'lem/language-mode:completion-spec
                        :buffer (current-buffer))
        (lem/completion-mode:make-completion-spec
         #'auto-test-async-provider :async t))
  (auto-test-report "SETUP async"))

(define-command lem-yath-test-deliver-old-auto-completion () ()
  (alexandria:when-let ((callback (gethash "asy" *auto-test-callbacks*)))
    (auto-test-report "DELIVER old")
    (funcall callback
             (list
              (lem/completion-mode:make-completion-item
               :label "STALE-ASY"
               :insert-text "stale_async")))))

(define-command lem-yath-test-auto-move-left () ()
  (character-offset (current-point) -1))

(define-command lem-yath-test-auto-delete-source-window () ()
  "Delete the exact window that owns the active completion session."
  (let ((source (current-window)))
    (split-window-horizontally source)
    (let ((replacement
            (find-if (lambda (window) (not (eq window source)))
                     (window-list))))
      (unless replacement
        (editor-error "Could not create a replacement test window"))
      (setf (current-window) replacement)
      (delete-window source)
      (auto-test-report
       "SOURCE DELETE context=~s session=~s buffer=~s floats=~d accept=~d windows=~d"
       (not (null lem/completion-mode::*completion-context*))
       (not (null (auto-completion-live-session)))
       (auto-test-buffer-text)
       (length (lem-core::frame-floating-windows (current-frame)))
       *auto-test-corfu-accept-count*
       (length (window-list))))))

(define-command lem-yath-test-auto-switch-buffer () ()
  (switch-to-buffer (get-buffer "*auto-completion-target*")))

(defun auto-test-clear-sentinel ()
  (let ((window *auto-test-sentinel-window*)
        (buffer *auto-test-sentinel-buffer*))
    (setf *auto-test-sentinel-window* nil
          *auto-test-sentinel-buffer* nil)
    (when window
      (ignore-errors
        (unless (deleted-window-p window)
          (delete-window window))))
    (when buffer
      (ignore-errors
        (unless (deleted-buffer-p buffer)
          (delete-buffer buffer))))))

(define-command lem-yath-test-make-sentinel-float () ()
  (auto-test-clear-sentinel)
  (let* ((buffer (make-buffer nil :temporary t :enable-undo-p nil))
         (source (current-window))
         (window nil))
    (insert-string (buffer-point buffer) "S")
    (buffer-unmark buffer)
    (setf window
          (make-instance
           'lem:floating-window
           :buffer buffer
           :x (+ (window-x source) (1- (window-width source)))
           :y (window-y source)
           :width 1 :height 1
           :use-modeline-p nil
           :cursor-invisible t
           :clickable nil)
          *auto-test-sentinel-buffer* buffer
          *auto-test-sentinel-window* window)
    (auto-test-report "SENTINEL made")))

(define-command lem-yath-test-clear-sentinel-float () ()
  (auto-test-clear-sentinel)
  (auto-test-report "SENTINEL cleared"))

(define-command lem-yath-test-deliver-current-auto-completion () ()
  (alexandria:when-let ((callback (gethash "asy" *auto-test-callbacks*)))
    (auto-test-report "DELIVER current")
    (funcall callback
             (mapcar
              (lambda (label)
                (lem/completion-mode:make-completion-item
                 :label label :filter-text label :insert-text label
                 :detail "Async"))
              '("asyncAlpha" "asyncBeta" "asyncGamma")))))

(define-command lem-yath-test-deliver-nil-auto-completion () ()
  (alexandria:when-let ((callback (gethash "asy" *auto-test-callbacks*)))
    (auto-test-report "DELIVER nil")
    (funcall callback nil)))

(define-command lem-yath-test-report-auto-completion-state () ()
  (let ((context lem/completion-mode::*completion-context*))
    (if context
        (progn
          (auto-test-report
           "STATE context automatic=~s max=~s cycle=~s items=~d popup=~s buffer=~a"
           (lem/completion-mode::context-automatic-p context)
           (lem/completion-mode::context-max-display-items context)
           (lem/completion-mode::context-cycle-p context)
           (length (lem/completion-mode::context-last-items context))
           (not (null (lem/completion-mode::context-popup-menu context)))
           (auto-test-buffer-text))
          (alexandria:when-let*
              ((popup (lem/completion-mode::context-popup-menu context))
               (item (lem/popup-menu:get-focus-item popup)))
            (auto-test-report
             "FOCUS ~a"
             (lem/completion-mode:completion-item-label item))))
        (auto-test-report "STATE none buffer=~a timer=~s"
                          (auto-test-buffer-text)
                          (not (null *auto-completion-timer*))))
    (when *auto-test-origin-buffer*
      (auto-test-report
       "ORIGIN completion-mode=~s"
       (mode-active-p *auto-test-origin-buffer*
                      'lem/completion-mode:completion-mode)))))

(defun auto-test-item-label (item)
  (and item (lem/completion-mode:completion-item-label item)))

(define-command lem-yath-test-report-corfu-state () ()
  (let* ((buffer (current-buffer))
         (session (auto-completion-live-session))
         (context lem/completion-mode::*completion-context*)
         (snapshot (buffer-undo-tree-snapshot buffer))
         (preview-buffer
           (and session (auto-completion-session-preview-buffer session)))
         (preview-window
           (and session (auto-completion-session-preview-window session)))
         (popup (and session (auto-completion-popup session)))
         (group (and session
                     (auto-completion-session-change-group session)))
         (selected (and session
                        (auto-completion-current-selected-item session)))
         (preview-live-p
           (and preview-window (not (deleted-window-p preview-window))))
         (floating-windows
           (lem-core::frame-floating-windows (current-frame)))
         (popup-window (and popup
                            (lem/popup-menu::popup-menu-window popup)))
         (expected
           (and session selected
                (multiple-value-list
                 (auto-completion-preview-spec session selected))))
         (geometry-p
           (and preview-live-p
                expected
                (= (length expected) 4)
                (= (window-x preview-window) (second expected))
                (= (window-y preview-window) (third expected))
                (= (window-width preview-window) (fourth expected))
                (= (window-height preview-window) 1)))
         (preview-index (and preview-live-p
                             (position preview-window floating-windows
                                       :test #'eq)))
         (popup-index (and popup-window
                           (position popup-window floating-windows
                                     :test #'eq))))
    (auto-test-report
     (concatenate
      'string
      "CORFU STATE context=~s buffer=~s tick=~d modified=~s point=~d "
      "nodes=~d current=~d preselect=~s selected=~s preview=~s "
      "preview-text=~s group=~s owned-floats=~d all-floats=~d "
      "focus=~s sentinel=~s geometry=~s under-popup=~s cursor-hidden=~s "
      "items=~d valid-focus=~d valid-accept=~d")
     (not (null context))
     (auto-test-buffer-text)
     (buffer-modified-tick buffer)
     (buffer-modified-p buffer)
     (position-at-point (current-point))
     (getf snapshot :node-count)
     (getf snapshot :current)
     (and session
          (auto-test-item-label
           (auto-completion-session-preselect-item session)))
     (and session
          (auto-test-item-label
           (auto-completion-session-selected-item session)))
     preview-live-p
     (and preview-buffer
          (not (deleted-buffer-p preview-buffer))
          (buffer-text preview-buffer))
     (and group (buffer-change-group-active-p group))
     (if preview-live-p 1 0)
     (length floating-windows)
     (and popup (lem/popup-menu:popup-menu-focus-active-p popup))
     (and *auto-test-sentinel-window*
          (not (deleted-window-p *auto-test-sentinel-window*)))
     geometry-p
     (and preview-index popup-index (< preview-index popup-index))
     (and preview-live-p (window-cursor-invisible-p preview-window))
     (if context
         (length (lem/completion-mode::context-last-items context))
         0)
     *auto-test-valid-focus-count*
     *auto-test-valid-accept-count*)))

(defun auto-test-signals-error-p (thunk)
  (handler-case (progn (funcall thunk) nil)
    (error () t)))

(defun auto-test-open-command-state (buffer)
  "Capture pending-command identity without sealing it."
  (let* ((current (lem/buffer/internal::buffer-%undo-tree-current buffer))
         (history (lem/buffer/internal::buffer-edit-history buffer)))
    (list
     :current current
     :children (lem/buffer/internal::undo-tree-node-children current)
     :preferred (lem/buffer/internal::undo-tree-node-preferred current)
     :history history
     :edits (loop :for edit :across history :collect edit)
     :pending-payload
     (lem/buffer/internal::buffer-%undo-tree-pending-payload-bytes buffer)
     :pending-dirty
     (lem/buffer/internal::buffer-%undo-tree-pending-dirty-p buffer)
     :node-count (lem/buffer/internal::buffer-%undo-tree-node-count buffer)
     :payload-bytes
     (lem/buffer/internal::buffer-%undo-tree-payload-bytes buffer)
     :edit-count (lem/buffer/internal::buffer-%undo-tree-edit-count buffer)
     :generation (lem/buffer/internal::buffer-%undo-tree-generation buffer)
     :next-id (lem/buffer/internal::buffer-%undo-tree-next-id buffer))))

(defun auto-test-open-command-state-equal-p (before after)
  "Compare exact topology/open identity, excluding monotonic ABA counters."
  (and (eq (getf before :current) (getf after :current))
       (eq (getf before :children) (getf after :children))
       (eq (getf before :preferred) (getf after :preferred))
       (eq (getf before :history) (getf after :history))
       (= (length (getf before :edits)) (length (getf after :edits)))
       (every #'eq (getf before :edits) (getf after :edits))
       (= (getf before :pending-payload) (getf after :pending-payload))
       (eq (getf before :pending-dirty) (getf after :pending-dirty))
       (= (getf before :node-count) (getf after :node-count))
       (= (getf before :payload-bytes) (getf after :payload-bytes))
       (= (getf before :edit-count) (getf after :edit-count))))

(defun auto-test-force-one-undo-prune (buffer protected)
  "Exercise real leaf pruning while making exactly one limit check succeed."
  (let* ((name 'lem/buffer/internal::undo-tree-over-retention-limit-p)
         (original (symbol-function name))
         (calls 0))
    (unwind-protect
        (progn
          (sb-ext:without-package-locks
            (setf (symbol-function name)
                  (lambda (ignored-buffer)
                    (declare (ignore ignored-buffer))
                    (= 1 (incf calls)))))
          (lem/buffer/internal::prune-sorted-undo-leaves buffer protected))
      (sb-ext:without-package-locks
        (setf (symbol-function name) original)))))

(defun auto-test-make-prunable-branches (buffer)
  "Return OLD, KEEP, and their empty root with the root current."
  (insert-string (buffer-point buffer) "old")
  (buffer-undo-boundary buffer)
  (let ((old (lem/buffer/internal::buffer-%undo-tree-current buffer)))
    (buffer-undo (buffer-point buffer))
    (insert-string (buffer-point buffer) "keep")
    (buffer-undo-boundary buffer)
    (let ((keep (lem/buffer/internal::buffer-%undo-tree-current buffer)))
      (buffer-undo (buffer-point buffer))
      (values old keep
              (lem/buffer/internal::buffer-%undo-tree-current buffer)))))

(defun auto-test-cross-buffer-replay-hook (start end old-length)
  (declare (ignore start end old-length))
  (unless *auto-test-cross-buffer-fired-p*
    (setf *auto-test-cross-buffer-fired-p* t)
    (with-current-buffer *auto-test-cross-buffer-target*
      (insert-string (buffer-point *auto-test-cross-buffer-target*) "hook"))))

(defun auto-test-change-group-cancel-p ()
  (handler-case
      (let ((buffer (make-buffer nil :temporary t :enable-undo-p t)))
        (unwind-protect
            (with-current-buffer buffer
              (buffer-disable-undo-boundary buffer)
              (insert-string (buffer-point buffer) "pre")
              (let ((group (buffer-prepare-change-group buffer)))
                (insert-string (buffer-point buffer) "view")
                (buffer-cancel-change-group group)
                (buffer-enable-undo-boundary buffer)
                (buffer-undo-boundary buffer)
                (and (string= "pre" (buffer-text buffer))
                     (not (buffer-change-group-active-p group))
                     (buffer-undo (buffer-point buffer))
                     (string= "" (buffer-text buffer)))))
          (ignore-errors (delete-buffer buffer))))
    (error (condition)
      (auto-test-report "CHANGE GROUP CANCEL ERROR ~A" condition)
      nil)))

(defun auto-test-change-group-accept-p ()
  (handler-case
      (let ((buffer (make-buffer nil :temporary t :enable-undo-p t)))
        (unwind-protect
            (with-current-buffer buffer
              (buffer-disable-undo-boundary buffer)
              (insert-string (buffer-point buffer) "pre")
              (let ((group (buffer-prepare-change-group buffer)))
                (insert-string (buffer-point buffer) "view")
                (buffer-accept-change-group group)
                (buffer-enable-undo-boundary buffer)
                (buffer-undo-boundary buffer)
                (and (string= "preview" (buffer-text buffer))
                     (not (buffer-change-group-active-p group))
                     (buffer-undo (buffer-point buffer))
                     (string= "" (buffer-text buffer)))))
          (ignore-errors (delete-buffer buffer))))
    (error (condition)
      (auto-test-report "CHANGE GROUP ACCEPT ERROR ~A" condition)
      nil)))

(defun auto-test-change-group-saved-p ()
  "A save commits one open insert command to a stable saved node."
  (handler-case
      (let ((buffer (make-buffer nil :temporary t :enable-undo-p t)))
        (unwind-protect
            (with-current-buffer buffer
              (buffer-disable-undo-boundary buffer)
              (insert-string (buffer-point buffer) "pre")
              (let ((group (buffer-prepare-change-group buffer)))
                (insert-string (buffer-point buffer) "view")
                (buffer-mark-saved buffer)
                (let* ((snapshot (buffer-undo-tree-snapshot buffer))
                       (current (getf snapshot :current)))
                  (and (string= "preview" (buffer-text buffer))
                       (not (buffer-change-group-active-p group))
                       (not (buffer-modified-p buffer))
                       (eql current (getf snapshot :clean))
                       (eql current (getf snapshot :last-saved))
                       (buffer-undo (buffer-point buffer))
                       (string= "" (buffer-text buffer))
                       (buffer-modified-p buffer)
                       (buffer-redo (buffer-point buffer))
                       (string= "preview" (buffer-text buffer))
                       (not (buffer-modified-p buffer))))))
          (ignore-errors (buffer-enable-undo-boundary buffer))
          (ignore-errors (delete-buffer buffer))))
    (error (condition)
      (auto-test-report "CHANGE GROUP SAVE ERROR ~A" condition)
      nil)))

(defun auto-test-change-group-pinned-p ()
  "Retention pruning cannot consume an active transaction baseline."
  (handler-case
      (let ((buffer (make-buffer nil :temporary t :enable-undo-p t)))
        (unwind-protect
            (with-current-buffer buffer
              (let ((group (buffer-prepare-change-group buffer)))
                (insert-string (buffer-point buffer) "a")
                (buffer-undo-boundary buffer)
                (insert-string (buffer-point buffer) "b")
                (buffer-undo-boundary buffer)
                ;; This is the exact root-advance attempted once retained
                ;; payload crosses the soft limit.  The newest node alone is
                ;; insufficient protection: the active baseline must pin root.
                (and (null
                      (lem/buffer/internal::advance-undo-root
                       buffer
                       (lem/buffer/internal::buffer-%undo-tree-current buffer)))
                     (buffer-change-group-active-p group)
                     (buffer-cancel-change-group group)
                     (let ((snapshot (buffer-undo-tree-snapshot buffer)))
                       (and (string= "" (buffer-text buffer))
                            (not (buffer-change-group-active-p group))
                            (not (buffer-modified-p buffer))
                            (= 1 (getf snapshot :node-count))
                            (= 0 (getf snapshot :payload-bytes)))))))
          (ignore-errors (delete-buffer buffer))))
    (error (condition)
      (auto-test-report "CHANGE GROUP PIN ERROR ~A" condition)
      nil)))

(defun auto-test-change-group-history-barrier-p ()
  "Ordinary history travel refuses before sealing an active transaction."
  (handler-case
      (let ((buffer (make-buffer nil :temporary t :enable-undo-p t)))
        (unwind-protect
            (with-current-buffer buffer
              (insert-string (buffer-point buffer) "base")
              (buffer-undo-boundary buffer)
              (let* ((root (lem/buffer/internal::buffer-%undo-tree-root buffer))
                     (group (buffer-prepare-change-group buffer)))
                (insert-string (buffer-point buffer) "change")
                (let* ((before-text (buffer-text buffer))
                       (before-tick (buffer-modified-tick buffer))
                       (before-modified (buffer-modified-p buffer))
                       (before (auto-test-open-command-state buffer))
                       (destination
                         (lem/buffer/internal::make-node-ref buffer root))
                       (undo-refused
                         (auto-test-signals-error-p
                          (lambda () (buffer-undo (buffer-point buffer)))))
                       (redo-refused
                         (auto-test-signals-error-p
                          (lambda () (buffer-redo (buffer-point buffer)))))
                       (move-refused
                         (auto-test-signals-error-p
                          (lambda ()
                            (buffer-undo-tree-move
                             (buffer-point buffer) destination))))
                       (after (auto-test-open-command-state buffer)))
                  (and undo-refused
                       redo-refused
                       move-refused
                       (buffer-change-group-active-p group)
                       (string= before-text (buffer-text buffer))
                       (= before-tick (buffer-modified-tick buffer))
                       (eq before-modified (buffer-modified-p buffer))
                       (auto-test-open-command-state-equal-p before after)
                       (= (getf before :generation) (getf after :generation))
                       (= (getf before :next-id) (getf after :next-id))
                       (buffer-cancel-change-group group)
                       (string= "base" (buffer-text buffer))
                       (not (buffer-change-group-active-p group))))))
          (ignore-errors (delete-buffer buffer))))
    (error (condition)
      (auto-test-report "CHANGE GROUP HISTORY BARRIER ERROR ~A" condition)
      nil)))

(defun auto-test-change-group-abort-p ()
  "Fail-closed abort preserves text, resets ownership, and permits reuse."
  (handler-case
      (let ((buffer (make-buffer nil :temporary t :enable-undo-p t)))
        (unwind-protect
            (with-current-buffer buffer
              (insert-string (buffer-point buffer) "base")
              (buffer-undo-boundary buffer)
              (let ((group (buffer-prepare-change-group buffer)))
                (insert-string (buffer-point buffer) "-live")
                (let ((tick (buffer-modified-tick buffer)))
                  (and (buffer-abort-change-group group)
                       (= tick (buffer-modified-tick buffer))
                       (string= "base-live" (buffer-text buffer))
                       (not (buffer-change-group-active-p group))
                       (null
                        (lem/buffer/internal::buffer-%active-change-group
                         buffer))
                       (let ((snapshot (buffer-undo-tree-snapshot buffer)))
                         (and (getf snapshot :truncated)
                              (= 1 (getf snapshot :node-count))
                              (= 0 (getf snapshot :payload-bytes))))
                       (buffer-modified-p buffer)
                       (let ((next (buffer-prepare-change-group buffer)))
                         (and (buffer-change-group-active-p next)
                              (buffer-abort-change-group next)
                              (not (buffer-change-group-active-p next))))))))
          (ignore-errors (delete-buffer buffer))))
    (error (condition)
      (auto-test-report "CHANGE GROUP ABORT ERROR ~A" condition)
      nil)))

(defun auto-test-abort-during-replay-hook (start end old-length)
  (declare (ignore start end old-length))
  (unless *auto-test-abort-replay-attempted-p*
    (setf *auto-test-abort-replay-attempted-p* t)
    (handler-case
        (buffer-abort-change-group *auto-test-abort-replay-group*)
      (error ()
        (setf *auto-test-abort-replay-rejected-p* t)))))

(defun auto-test-change-group-abort-during-replay-p ()
  "A replay hook cannot reset the closing group's tree under its route."
  (handler-case
      (let ((buffer (make-buffer nil :temporary t :enable-undo-p t)))
        (unwind-protect
            (with-current-buffer buffer
              (insert-string (buffer-point buffer) "base")
              (buffer-undo-boundary buffer)
              (let ((group (buffer-prepare-change-group buffer)))
                (insert-string (buffer-point buffer) "change")
                (buffer-undo-boundary buffer)
                (setf *auto-test-abort-replay-group* group
                      *auto-test-abort-replay-attempted-p* nil
                      *auto-test-abort-replay-rejected-p* nil)
                (add-hook
                 (variable-value 'after-change-functions :buffer buffer)
                 'auto-test-abort-during-replay-hook 20000)
                (unwind-protect
                    (buffer-cancel-change-group group)
                  (remove-hook
                   (variable-value 'after-change-functions :buffer buffer)
                   'auto-test-abort-during-replay-hook))
                (and *auto-test-abort-replay-attempted-p*
                     *auto-test-abort-replay-rejected-p*
                     (string= "base" (buffer-text buffer))
                     (not (buffer-change-group-active-p group))
                     (null
                      (lem/buffer/internal::buffer-%active-change-group buffer))
                     (lem/buffer/internal::validate-undo-tree buffer)
                     (buffer-undo (buffer-point buffer))
                     (string= "" (buffer-text buffer)))))
          (ignore-errors
            (remove-hook
             (variable-value 'after-change-functions :buffer buffer)
             'auto-test-abort-during-replay-hook))
          (setf *auto-test-abort-replay-group* nil
                *auto-test-abort-replay-attempted-p* nil
                *auto-test-abort-replay-rejected-p* nil)
          (ignore-errors (delete-buffer buffer))))
    (error (condition)
      (auto-test-report "CHANGE GROUP REPLAY ABORT ERROR ~A" condition)
      nil)))

(defun auto-test-refuse-change (point argument)
  (declare (ignore argument))
  (setf *auto-test-refusal-node-ref*
        (buffer-undo-tree-current (point-buffer point)))
  (editor-error "change-group refusal probe"))

(defun auto-test-change-group-refusal-atomic-p ()
  "A refusal restores the exact unsealed command without an ABA reference."
  (handler-case
      (let ((buffer (make-buffer nil :temporary t :enable-undo-p t)))
        (unwind-protect
            (with-current-buffer buffer
              (insert-string (buffer-point buffer) "base")
              (buffer-undo-boundary buffer)
              (let ((group (buffer-prepare-change-group buffer)))
                (insert-string (buffer-point buffer) "change")
                (let ((before-text (buffer-text buffer))
                      (before-tick (buffer-modified-tick buffer))
                      (before-modified (buffer-modified-p buffer))
                      (before (auto-test-open-command-state buffer))
                      (refused-p nil))
                  (setf *auto-test-refusal-node-ref* nil)
                  (add-hook
                   (variable-value 'before-change-functions :buffer buffer)
                   'auto-test-refuse-change 20000)
                  (unwind-protect
                      (handler-case (buffer-cancel-change-group group)
                        (error () (setf refused-p t)))
                    (remove-hook
                     (variable-value 'before-change-functions :buffer buffer)
                     'auto-test-refuse-change))
                  (let ((after (auto-test-open-command-state buffer)))
                    (and refused-p
                         *auto-test-refusal-node-ref*
                         (buffer-change-group-active-p group)
                         (string= before-text (buffer-text buffer))
                         (= before-tick (buffer-modified-tick buffer))
                         (eq before-modified (buffer-modified-p buffer))
                         (auto-test-open-command-state-equal-p before after)
                         (> (getf after :generation)
                            (getf before :generation))
                         (> (getf after :next-id) (getf before :next-id))
                         (auto-test-signals-error-p
                          (lambda ()
                            (lem/buffer/internal::resolve-node-ref
                             *auto-test-refusal-node-ref*)))
                         (buffer-cancel-change-group group)
                         (string= "base" (buffer-text buffer))
                         (not (buffer-change-group-active-p group)))))))
          (ignore-errors
            (remove-hook
             (variable-value 'before-change-functions :buffer buffer)
             'auto-test-refuse-change))
          (setf *auto-test-refusal-node-ref* nil)
          (ignore-errors (delete-buffer buffer))))
    (error (condition)
      (auto-test-report "CHANGE GROUP REFUSAL ERROR ~A" condition)
      nil)))

(defun auto-test-change-group-pruned-preferred-p ()
  "Cancel chooses a live baseline child after its saved preference is pruned."
  (handler-case
      (let ((buffer (make-buffer nil :temporary t :enable-undo-p t)))
        (unwind-protect
            (with-current-buffer buffer
              (multiple-value-bind (old keep root)
                  (auto-test-make-prunable-branches buffer)
                (setf (lem/buffer/internal::undo-tree-node-preferred root) old)
                (let ((group (buffer-prepare-change-group buffer)))
                  (insert-string (buffer-point buffer) "group")
                  (buffer-undo-boundary buffer)
                  (let ((protected
                          (lem/buffer/internal::buffer-%undo-tree-current buffer)))
                    (and (auto-test-force-one-undo-prune buffer protected)
                         (null
                          (gethash
                           (lem/buffer/internal::undo-tree-node-id old)
                           (lem/buffer/internal::buffer-%undo-tree-table buffer)))
                         (buffer-change-group-active-p group)
                         (buffer-cancel-change-group group)
                         (lem/buffer/internal::validate-undo-tree buffer)
                         (string= "" (buffer-text buffer))
                         (eq root
                             (lem/buffer/internal::buffer-%undo-tree-current
                              buffer))
                         (equal (list keep)
                                (lem/buffer/internal::undo-tree-node-children
                                 root))
                         (eq keep
                             (lem/buffer/internal::undo-tree-node-preferred
                              root)))))))
          (ignore-errors (delete-buffer buffer))))
    (error (condition)
      (auto-test-report "CHANGE GROUP PRUNED PREFERRED ERROR ~A" condition)
      nil)))

(defun auto-test-change-group-pruned-split-preferred-p ()
  "A split command reopens after its parent's saved preference is pruned."
  (handler-case
      (let ((buffer (make-buffer nil :temporary t :enable-undo-p t)))
        (unwind-protect
            (with-current-buffer buffer
              (multiple-value-bind (old keep root)
                  (auto-test-make-prunable-branches buffer)
                (setf (lem/buffer/internal::undo-tree-node-preferred root) old)
                (insert-string (buffer-point buffer) "pre")
                (let ((group (buffer-prepare-change-group buffer)))
                  (insert-string (buffer-point buffer) "group")
                  (buffer-undo-boundary buffer)
                  (let ((protected
                          (lem/buffer/internal::buffer-%undo-tree-current buffer)))
                    (and (auto-test-force-one-undo-prune buffer protected)
                         (null
                          (gethash
                           (lem/buffer/internal::undo-tree-node-id old)
                           (lem/buffer/internal::buffer-%undo-tree-table buffer)))
                         (buffer-cancel-change-group group)
                         (not (buffer-change-group-active-p group))
                         (string= "pre" (buffer-text buffer))
                         (eq root
                             (lem/buffer/internal::buffer-%undo-tree-current
                              buffer))
                         (equal (list keep)
                                (lem/buffer/internal::undo-tree-node-children
                                 root))
                         (eq keep
                             (lem/buffer/internal::undo-tree-node-preferred
                              root))
                         (plusp
                          (fill-pointer
                           (lem/buffer/internal::buffer-edit-history buffer)))
                         (progn
                           (buffer-undo-boundary buffer)
                           (lem/buffer/internal::validate-undo-tree buffer))
                         (buffer-undo (buffer-point buffer))
                         (string= "" (buffer-text buffer)))))))
          (ignore-errors (delete-buffer buffer))))
    (error (condition)
      (auto-test-report "CHANGE GROUP PRUNED SPLIT ERROR ~A" condition)
      nil)))

(defun auto-test-change-group-cross-buffer-replay-p ()
  "Replay hooks retain edits made in another buffer and do not strand its group."
  (handler-case
      (let ((source (make-buffer nil :temporary t :enable-undo-p t))
            (target (make-buffer nil :temporary t :enable-undo-p t)))
        (unwind-protect
            (let ((group nil))
              (with-current-buffer target
                (setf group (buffer-prepare-change-group target)))
              (with-current-buffer source
                (insert-string (buffer-point source) "source")
                (buffer-undo-boundary source))
              (setf *auto-test-cross-buffer-target* target
                    *auto-test-cross-buffer-fired-p* nil)
              (add-hook
               (variable-value 'after-change-functions :buffer source)
               'auto-test-cross-buffer-replay-hook 20000)
              (unwind-protect
                  (buffer-undo (buffer-point source))
                (remove-hook
                 (variable-value 'after-change-functions :buffer source)
                 'auto-test-cross-buffer-replay-hook))
              (with-current-buffer target
                (let* ((source-text (buffer-text source))
                       (target-text (buffer-text target))
                       (active-p (buffer-change-group-active-p group))
                       (edit-count
                         (fill-pointer
                          (lem/buffer/internal::buffer-edit-history target)))
                       (pending-dirty-p
                         (lem/buffer/internal::buffer-%undo-tree-pending-dirty-p
                          target))
                       (pre-ok
                         (and *auto-test-cross-buffer-fired-p*
                              (string= "" source-text)
                              (string= "hook" target-text)
                              active-p
                              (plusp edit-count)
                              (not pending-dirty-p))))
                  (unless pre-ok
                    (auto-test-report
                     "CHANGE GROUP CROSS BUFFER PRE fired=~S source=~S target=~S active=~S edits=~D dirty=~S"
                     *auto-test-cross-buffer-fired-p* source-text target-text
                     active-p edit-count pending-dirty-p))
                  (when pre-ok
                    (let ((accepted-p (buffer-accept-change-group group)))
                      (buffer-undo-boundary target)
                      (let ((inactive-p
                              (not (buffer-change-group-active-p group)))
                            (undone-p (buffer-undo (buffer-point target))))
                        (unless
                            (and accepted-p inactive-p undone-p
                                 (string= "" (buffer-text target)))
                          (auto-test-report
                           "CHANGE GROUP CROSS BUFFER POST accepted=~S inactive=~S undone=~S target=~S"
                           accepted-p inactive-p undone-p
                           (buffer-text target)))
                        (and accepted-p inactive-p undone-p
                             (string= "" (buffer-text target)))))))))
          (ignore-errors
            (remove-hook
             (variable-value 'after-change-functions :buffer source)
             'auto-test-cross-buffer-replay-hook))
          (setf *auto-test-cross-buffer-target* nil
                *auto-test-cross-buffer-fired-p* nil)
          (ignore-errors (delete-buffer source))
          (ignore-errors (delete-buffer target))))
    (error (condition)
      (auto-test-report "CHANGE GROUP CROSS BUFFER ERROR ~A" condition)
      nil)))

(defun auto-test-recursive-change-hook (start end old-length)
  (declare (ignore start end old-length))
  (unless *auto-test-recursive-change-attempted-p*
    (setf *auto-test-recursive-change-attempted-p* t)
    (handler-case
        (buffer-cancel-change-group *auto-test-recursive-change-group*)
      (error ()
        (setf *auto-test-recursive-change-rejected-p* t)))))

(defun auto-test-change-group-reentrant-p ()
  "Replay hooks cannot recursively close the group being replayed."
  (handler-case
      (let ((buffer (make-buffer nil :temporary t :enable-undo-p t)))
        (unwind-protect
            (with-current-buffer buffer
              (insert-string (buffer-point buffer) "base")
              (buffer-undo-boundary buffer)
              (let ((group (buffer-prepare-change-group buffer)))
                (insert-string (buffer-point buffer) "change")
                (buffer-undo-boundary buffer)
                (setf *auto-test-recursive-change-group* group
                      *auto-test-recursive-change-attempted-p* nil
                      *auto-test-recursive-change-rejected-p* nil)
                (add-hook
                 (variable-value 'after-change-functions :buffer buffer)
                 'auto-test-recursive-change-hook 20000)
                (unwind-protect
                    (buffer-cancel-change-group group)
                  (remove-hook
                   (variable-value 'after-change-functions :buffer buffer)
                   'auto-test-recursive-change-hook))
                (and *auto-test-recursive-change-attempted-p*
                     *auto-test-recursive-change-rejected-p*
                     (string= "base" (buffer-text buffer))
                     (not (buffer-change-group-active-p group))
                     (buffer-undo-tree-snapshot buffer))))
          (ignore-errors
            (remove-hook
             (variable-value 'after-change-functions :buffer buffer)
             'auto-test-recursive-change-hook))
          (setf *auto-test-recursive-change-group* nil)
          (ignore-errors (delete-buffer buffer))))
    (error (condition)
      (auto-test-report "CHANGE GROUP REENTRANCY ERROR ~A" condition)
      nil)))

(defun auto-test-change-group-inhibited-edit-p ()
  "An untracked edit invalidates reset without changing the truthful edit."
  (handler-case
      (let ((buffer (make-buffer nil :temporary t :enable-undo-p t)))
        (unwind-protect
            (with-current-buffer buffer
              (let ((group (buffer-prepare-change-group buffer)))
                (with-inhibit-undo ()
                  (insert-string (buffer-point buffer) "untracked"))
                (let ((tick (buffer-modified-tick buffer))
                      (refused-p nil))
                  (handler-case (buffer-cancel-change-group group)
                    (error () (setf refused-p t)))
                  (and refused-p
                       (not (buffer-change-group-active-p group))
                       (= tick (buffer-modified-tick buffer))
                       (string= "untracked" (buffer-text buffer))
                       (buffer-modified-p buffer)
                       (buffer-undo-tree-snapshot buffer)))))
          (ignore-errors (delete-buffer buffer))))
    (error (condition)
      (auto-test-report "CHANGE GROUP INHIBITED ERROR ~A" condition)
      nil)))

(define-command lem-yath-test-auto-completion-static-checks () ()
  (let ((failures 0))
    (labels ((check (condition label)
               (auto-test-report "~a STATIC ~a"
                                 (if condition "PASS" "FAIL")
                                 label)
               (unless condition
                 (incf failures))))
      (check (= 3 *auto-completion-prefix-length*) "prefix-three")
      (check (= 200 *auto-completion-delay-ms*) "delay-200ms")
      (check (= 10 *auto-completion-max-display-items*) "ten-rows")
      (check (fboundp 'buffer-prepare-change-group)
             "change-group-api")
      (check (auto-test-change-group-cancel-p)
             "change-group-cancel-is-honest")
      (check (auto-test-change-group-accept-p)
             "change-group-accept-one-undo")
      (check (auto-test-change-group-saved-p)
             "change-group-save-stable-one-undo")
      (check (auto-test-change-group-pinned-p)
             "change-group-baseline-pinned")
      (check (auto-test-change-group-history-barrier-p)
             "change-group-history-move-barrier")
      (check (auto-test-change-group-abort-p)
             "change-group-fail-closed-abort")
      (check (auto-test-change-group-abort-during-replay-p)
             "change-group-replay-abort-rejected")
      (check (auto-test-change-group-refusal-atomic-p)
             "change-group-open-refusal-atomic")
      (check (auto-test-change-group-pruned-preferred-p)
             "change-group-pruned-preferred-sanitized")
      (check (auto-test-change-group-pruned-split-preferred-p)
             "change-group-pruned-split-preferred-sanitized")
      (check (auto-test-change-group-cross-buffer-replay-p)
             "change-group-cross-buffer-replay-retained")
      (check (auto-test-change-group-reentrant-p)
             "change-group-reentrant-close-rejected")
      (check (auto-test-change-group-inhibited-edit-p)
             "change-group-inhibited-edit-invalidates")
      (auto-test-reset-current-buffer)
      (let ((called :not-called))
        (lem-lsp-mode::text-document/completion
         (current-point)
         (lambda (items) (setf called items)))
        (check (null called) "lsp-without-workspace-completes-empty"))
      (auto-test-report "SUMMARY STATIC ~a failures=~d"
                        (if (zerop failures) "PASS" "FAIL")
                        failures))))

(define-command lem-yath-test-change-group-audit-checks () ()
  (let ((checks
          `(("history-barrier" . ,(auto-test-change-group-history-barrier-p))
            ("abort" . ,(auto-test-change-group-abort-p))
            ("replay-abort" .
             ,(auto-test-change-group-abort-during-replay-p))
            ("open-refusal" . ,(auto-test-change-group-refusal-atomic-p))
            ("baseline-preferred" .
             ,(auto-test-change-group-pruned-preferred-p))
            ("split-preferred" .
             ,(auto-test-change-group-pruned-split-preferred-p))
            ("cross-buffer-replay" .
             ,(auto-test-change-group-cross-buffer-replay-p)))))
    (dolist (check checks)
      (auto-test-report "CHANGE AUDIT ~a ~a"
                        (if (cdr check) "PASS" "FAIL")
                        (car check)))
    (auto-test-report "CHANGE AUDIT SUMMARY ~a failures=~d"
                      (if (every #'cdr checks) "PASS" "FAIL")
                      (count-if-not #'cdr checks))))

(define-key lem/completion-mode::*completion-mode-keymap*
  "F1" 'lem-yath-test-auto-delete-source-window)
(define-key lem/completion-mode::*completion-mode-keymap*
  "F5" 'lem-yath-test-report-auto-completion-state)
(define-key lem/completion-mode::*completion-mode-keymap*
  "F8" 'lem-yath-test-auto-move-left)
(define-key lem/completion-mode::*completion-mode-keymap*
  "F9" 'lem-yath-test-auto-switch-buffer)
(define-key lem/completion-mode::*completion-mode-keymap*
  "F10" 'lem-yath-test-report-corfu-state)
(define-key lem/completion-mode::*completion-mode-keymap*
  "F2" 'lem-yath-test-make-sentinel-float)
(define-key lem/completion-mode::*completion-mode-keymap*
  "F3" 'lem-yath-test-clear-sentinel-float)
(define-key lem/completion-mode::*completion-mode-keymap*
  "F11" 'lem-yath-test-deliver-current-auto-completion)
(define-key lem/completion-mode::*completion-mode-keymap*
  "F12" 'lem-yath-test-deliver-nil-auto-completion)
(pushnew 'lem-yath-test-report-auto-completion-state
         *auto-completion-continue-commands*)
(pushnew 'lem-yath-test-report-corfu-state
         *auto-completion-continue-commands*)
(dolist (command '(lem-yath-test-make-sentinel-float
                   lem-yath-test-auto-delete-source-window
                   lem-yath-test-clear-sentinel-float
                   lem-yath-test-deliver-current-auto-completion
                   lem-yath-test-deliver-nil-auto-completion))
  (pushnew command *auto-completion-continue-commands*))
(define-key lem-vi-mode:*insert-keymap*
  "F6" 'lem-yath-test-deliver-old-auto-completion)
(define-key lem-vi-mode:*insert-keymap*
  "F7" 'lem-yath-test-report-auto-completion-state)
(define-key lem-vi-mode:*insert-keymap*
  "F10" 'lem-yath-test-report-corfu-state)
(define-key lem-vi-mode:*insert-keymap*
  "F2" 'lem-yath-test-make-sentinel-float)
(define-key lem-vi-mode:*insert-keymap*
  "F3" 'lem-yath-test-clear-sentinel-float)
(define-key lem-vi-mode:*insert-keymap*
  "F11" 'lem-yath-test-deliver-current-auto-completion)
(define-key lem-vi-mode:*insert-keymap*
  "F12" 'lem-yath-test-deliver-nil-auto-completion)
(define-key lem-vi-mode:*normal-keymap*
  "F7" 'lem-yath-test-report-auto-completion-state)
(define-key lem-vi-mode:*normal-keymap*
  "F10" 'lem-yath-test-report-corfu-state)
(define-key lem-vi-mode:*normal-keymap*
  "F3" 'lem-yath-test-clear-sentinel-float)

;; Test setup must not depend on M-x's prompt becoming input-active on the
;; same redisplay that paints its label.  These fixture-only chords still use
;; Lem's real key dispatcher while keeping setup deterministic under load.
(define-key lem-vi-mode:*normal-keymap*
  "C-c z s" 'lem-yath-test-auto-completion-static-checks)
(define-key lem-vi-mode:*normal-keymap*
  "C-c z c" 'lem-yath-test-auto-corfu-setup)
(define-key lem-vi-mode:*normal-keymap*
  "C-c z v" 'lem-yath-test-auto-valid-setup)
(define-key lem-vi-mode:*normal-keymap*
  "C-c z r" 'lem-yath-test-auto-corfu-middle-setup)
(define-key lem-vi-mode:*normal-keymap*
  "C-c z a" 'lem-yath-test-auto-async-setup)
(define-key lem-vi-mode:*normal-keymap*
  "C-c z d" 'lem-yath-test-auto-dabbrev-setup)
(define-key lem-vi-mode:*normal-keymap*
  "C-c z l" 'lem-yath-test-auto-corfu-lisp-setup)
(define-key lem-vi-mode:*normal-keymap*
  "C-c z m" 'lem-yath-test-auto-middle-setup)
(define-key lem-vi-mode:*normal-keymap*
  "C-c z p" 'lem-yath-test-auto-primary-setup)
(define-key lem-vi-mode:*normal-keymap*
  "C-c z f" 'lem-yath-test-auto-file-setup)
(define-key lem-vi-mode:*normal-keymap*
  "C-c z x" 'lem-yath-test-auto-cancel-setup)
(define-key lem-vi-mode:*normal-keymap*
  "C-c z g" 'lem-yath-test-change-group-audit-checks)
