;;;; Global Which-Key-style guidance for incomplete key sequences.
;;;; Dispatch remains owned by Lem's live keymaps; this module builds a
;;;; display-only snapshot whose entries are verified through `lookup-keybind'.

(in-package :lem-yath)

(defvar *which-key-idle-delay* 1000
  "Milliseconds of inactivity before automatic prefix help appears.")

(defvar *which-key-description-limit* 27
  "Maximum displayed command-description length, including an ellipsis.")

(defvar *which-key-show-docstrings* nil
  "Whether Which-Key entries include the first command docstring line.")

(defvar *which-key-session-prefix-keys* nil)
(defvar *which-key-session-pages* nil)
(defvar *which-key-session-page-index* 0)
(defvar *which-key-replay-display-map* nil)
(defvar *which-key-dispatch-inhibited-p* nil)
(defvar *which-key-input-keymap* (lem-core::make-keymap))

(defun which-key-mode-enabled-p ()
  (ignore-errors
    (mode-active-p (current-buffer) 'which-key-mode)))

(defun which-key-command-executing-p ()
  "Whether a real Lem command is dynamically executing.
Lem's global fallback value for `*this-command*' is a documentation string."
  (and (boundp 'lem-core::*this-command*)
       (typep (symbol-value 'lem-core::*this-command*)
              'lem/common/command:primary-command)))

(defun which-key-display-map-p (keymap)
  (getf (lem-core::keymap-properties keymap)
        'which-key-display-map-p))

(defun which-key-display-map-page-index (keymap)
  (getf (lem-core::keymap-properties keymap)
        'which-key-page-index))

(defun which-key-display-map-page-count (keymap)
  (getf (lem-core::keymap-properties keymap)
        'which-key-page-count))

(defun which-key-key-string (key)
  "Return KEY in the compact notation used by the configured Emacs."
  (let ((string (princ-to-string key)))
    (cond
      ((string= string "Space") "SPC")
      ((string= string "Return") "RET")
      ((string= string "Backspace") "DEL")
      (t string))))

(defun which-key-sequence-string (keys)
  (format nil "~{~a~^ ~}" (mapcar #'which-key-key-string keys)))

(defun which-key-truncate-description (description)
  (let ((limit *which-key-description-limit*))
    (check-type limit (or null (integer 0 *)))
    (cond
      ((or (null limit)
           (<= (length description) limit))
       description)
      ((<= limit 2)
       (subseq ".." 0 limit))
      (t
       (concatenate 'string
                    (subseq description 0 (- limit 2))
                    "..")))))

(defun which-key-prefix-command-p (suffix)
  (and (or (typep suffix 'lem-core::keymap)
           (typep suffix 'lem-core::prefix))
       (lem-core::prefix-p suffix)))

(defun which-key-command-docstring (suffix)
  (when (and (symbolp suffix) (fboundp suffix))
    (alexandria:when-let ((documentation
                           (ignore-errors
                             (documentation suffix 'function))))
      (let* ((newline (position #\newline documentation))
             (first-line (subseq documentation 0 newline)))
        (unless (zerop (length first-line))
          first-line)))))

(defun which-key-description (suffix)
  "Describe SUFFIX like an uncustomized Emacs Which-Key entry."
  (which-key-truncate-description
   (let ((description
           (cond
             ((which-key-prefix-command-p suffix) "+prefix")
             ((symbolp suffix) (string-downcase (symbol-name suffix)))
             ((functionp suffix) "anonymous command")
             (t (string-downcase (princ-to-string suffix))))))
     (alexandria:if-let ((docstring
                          (and *which-key-show-docstrings*
                               (not (which-key-prefix-command-p suffix))
                               (which-key-command-docstring suffix))))
       (format nil "~a ~a" description docstring)
       description))))

(defun which-key-active-candidate-keys
    (&optional (root lem-core::*root-keymap*))
  "Collect unique explicit key objects from the active graph below ROOT."
  (let ((seen (make-hash-table :test #'eq))
        (keys nil))
    (labels ((walk-prefix (prefix)
               (when (and (lem-core::prefix-active-p prefix)
                          (slot-boundp prefix 'lem-core::key))
                 (pushnew (lem-core::prefix-key prefix) keys :test #'equal)
                 (when (slot-boundp prefix 'lem-core::suffix)
                   (let ((suffix (lem-core::prefix-suffix prefix)))
                     (when (or (typep suffix 'lem-core::keymap)
                               (typep suffix 'lem-core::prefix))
                       (walk suffix))))))
             (walk-keymap (keymap)
               (when (lem-core::keymap-active-p keymap)
                 (dolist (child (lem-core::keymap-children keymap))
                   (walk child))
                 (dolist (prefix (lem-core::keymap-prefixes keymap))
                   (walk-prefix prefix))
                 (alexandria:when-let ((base (lem-core::keymap-base keymap)))
                   (walk base))))
             (walk (node)
               (unless (gethash node seen)
                 (setf (gethash node seen) t)
                 (typecase node
                   (lem-core::keymap (walk-keymap node))
                   (lem-core::prefix (walk-prefix node))))))
      (walk root))
    keys))

(defun which-key-explicit-continuation (prefix-keys key)
  "Return the dispatcher-selected explicit prefix after PREFIX-KEYS and KEY."
  (let ((prefix
          (lem-core::lookup-keybind
           (append prefix-keys (list key)))))
    (when (and (typep prefix 'lem-core::prefix)
               (lem-core::prefix-active-p prefix)
               (slot-boundp prefix 'lem-core::key)
               (equal key (lem-core::prefix-key prefix))
               (slot-boundp prefix 'lem-core::suffix)
               (not (eq 'undefined-key
                        (lem-core::prefix-suffix prefix))))
      prefix)))

(defun which-key-continuations (prefix-keys)
  "Return sorted dispatcher-accurate continuations for PREFIX-KEYS."
  (let* ((*which-key-dispatch-inhibited-p* t)
        (continuations
          (loop :for key :in (which-key-active-candidate-keys)
                :for prefix :=
                  (which-key-explicit-continuation prefix-keys key)
                :when prefix
                  :collect
                  (let ((suffix (lem-core::prefix-suffix prefix)))
                    (list key
                          (which-key-key-string key)
                          (which-key-description suffix)
                          suffix)))))
    (stable-sort
     continuations
     (lambda (left right)
       (let ((left-key (second left))
             (right-key (second right)))
         (or (string-lessp left-key right-key)
             (and (string-equal left-key right-key)
                  (string< left-key right-key))))))))

(defun which-key-column-size ()
  "Match Which-Key's default maximum height of one quarter of the frame."
  (max 1 (floor (display-height) 4)))

(defun which-key-partition (items size)
  (loop :while items
        :collect (subseq items 0 (min size (length items)))
        :do (setf items (nthcdr (min size (length items)) items))))

(defun which-key-column-width (continuations)
  "Return the exact width used by Lem transient rendering for one column."
  (let ((key-width
          (reduce #'max continuations :key (lambda (item)
                                              (length (second item)))
                  :initial-value 0)))
    (reduce #'max continuations
            :key (lambda (item)
                   (+ key-width 1 (length (third item))))
            :initial-value 0)))

(defun which-key-pack-columns (columns available-width)
  "Pack COLUMNS into width-bounded pages without reordering entries."
  (check-type available-width (integer 1 *))
  (let ((separator-width
          (length lem/transient::*transient-column-separator*))
        (pages nil)
        (page nil)
        (page-width 0))
    (dolist (column columns)
      (let* ((column-width (which-key-column-width column))
             (candidate-width
               (+ page-width
                  (if page separator-width 0)
                  column-width)))
        (when (and page (> candidate-width available-width))
          (push (nreverse page) pages)
          (setf page nil
                page-width 0
                candidate-width column-width))
        (push column page)
        (setf page-width candidate-width)))
    (when page
      (push (nreverse page) pages))
    (nreverse pages)))

(defun which-key-make-column (continuations)
  (let ((keymap (lem-core::make-keymap)))
    (dolist (continuation continuations)
      (destructuring-bind (key key-string description &optional suffix)
          continuation
        (declare (ignore suffix))
        ;; The menu is display-only.  A harmless symbol suffix avoids adding
        ;; parent links from live keymaps to an ephemeral snapshot.
        (let ((prefix
                (lem-core::make-prefix
                 :key key
                 :suffix 'which-key-display-only
                 :description description)))
          (setf (lem/transient::prefix-display-key prefix) key-string)
          (lem-core::keymap-add-prefix keymap prefix t))))
    keymap))

(defun which-key-make-display-page
    (columns prefix-keys page-index page-count)
  (let ((keymap (lem-core::make-keymap)))
    (setf (lem/transient::keymap-show-p keymap) t
          (lem/transient::keymap-display-style keymap) :row
          (getf (lem-core::keymap-properties keymap)
                'which-key-display-map-p)
          t
          (getf (lem-core::keymap-properties keymap)
                'which-key-prefix-keys)
          (copy-list prefix-keys)
          (getf (lem-core::keymap-properties keymap)
                'which-key-page-index)
          page-index
          (getf (lem-core::keymap-properties keymap)
                'which-key-page-count)
          page-count)
    (dolist (column columns)
      (lem-core::keymap-add-child
       keymap (which-key-make-column column) t))
    keymap))

(defun which-key-make-display-pages (prefix-keys)
  "Build width-bounded display-only pages for PREFIX-KEYS."
  (let ((continuations (which-key-continuations prefix-keys)))
    (when continuations
      (let* ((columns
               (which-key-partition continuations
                                    (which-key-column-size)))
             (page-columns
               (which-key-pack-columns
                columns (max 1 (1- (display-width)))))
             (page-count (length page-columns)))
        (loop :for page :in page-columns
              :for page-index :from 0
              :collect (which-key-make-display-page
                        page prefix-keys page-index page-count))))))

(defun which-key-make-display-map (prefix-keys)
  "Build the first width-bounded display page for PREFIX-KEYS."
  (first (which-key-make-display-pages prefix-keys)))

(defun which-key-reset-session ()
  (setf *which-key-session-prefix-keys* nil
        *which-key-session-pages* nil
        *which-key-session-page-index* 0
        *which-key-replay-display-map* nil))

(defun which-key-start-session (prefix-keys)
  (let ((pages (which-key-make-display-pages prefix-keys)))
    (if pages
        (setf *which-key-session-prefix-keys* (copy-list prefix-keys)
              *which-key-session-pages* pages
              *which-key-session-page-index* 0)
        (which-key-reset-session))
    (first pages)))

(defun which-key-current-display-map ()
  (nth *which-key-session-page-index* *which-key-session-pages*))

(defun which-key-queue-current-page ()
  (setf *which-key-replay-display-map*
        (which-key-current-display-map)))

(defun which-key-turn-page (delta)
  (when *which-key-session-pages*
    (setf *which-key-session-page-index*
          (mod (+ *which-key-session-page-index* delta)
               (length *which-key-session-pages*)))
    (which-key-queue-current-page)))

(defun which-key-rebuild-session ()
  (let ((prefix-keys (copy-list *which-key-session-prefix-keys*))
        (old-index *which-key-session-page-index*))
    (when prefix-keys
      (let ((pages (which-key-make-display-pages prefix-keys)))
        (if pages
            (setf *which-key-session-pages* pages
                  *which-key-session-page-index*
                  (min old-index (1- (length pages))))
            (which-key-reset-session))))
    (which-key-queue-current-page)))

(defun which-key-input-key-p (key keyspec)
  (equal key (first (lem-core::parse-keyspec keyspec))))

(defun which-key-dispatch-context-p (key-sequence)
  (and (not *which-key-dispatch-inhibited-p*)
       *which-key-session-pages*
       key-sequence
       (which-key-input-key-p (car (last key-sequence)) "C-h")
       (equal (butlast key-sequence)
              *which-key-session-prefix-keys*)))

(defmethod keymap-find
    ((keymap (eql *which-key-input-keymap*)) key)
  "Make C-h available only inside the currently tracked ordinary prefix."
  (let ((key-sequence
          (etypecase key
            (lem-core::key (list key))
            (list key))))
    (when (which-key-dispatch-context-p key-sequence)
      (lem-core::first-prefix-match
       keymap (first (lem-core::parse-keyspec "C-h"))
       :active-only t))))

(defun which-key-popup-visible-p ()
  (and (lem/transient::transient-window-alive-p)
       lem/transient::*transient-shown-keymap*
       (which-key-display-map-p
        lem/transient::*transient-shown-keymap*)))

(defun which-key-end-session ()
  (lem/transient::hide-transient)
  (which-key-reset-session))

(defun which-key-standard-help (prefix-keys)
  "Show the live bindings below PREFIX-KEYS in a focused typeout window."
  (let ((continuations (which-key-continuations prefix-keys))
        (prefix-label
          (if prefix-keys
              (which-key-sequence-string prefix-keys)
              "Top-level")))
    (which-key-end-session)
    (with-pop-up-typeout-window
        (out (make-buffer "*Prefix Bindings*") :erase t)
      (format out "~a bindings~2%" prefix-label)
      (format out "~12a~a~%" "key" "binding")
      (format out "~12a~a~%" "---" "-------")
      (dolist (continuation continuations)
        (format out "~12a~a~%"
                (second continuation)
                (let ((*which-key-show-docstrings* nil))
                  (which-key-description (fourth continuation)))))))
  (error 'editor-abort :message nil))

(defun which-key-abort-session ()
  (which-key-end-session)
  (error 'editor-abort :message nil))

(defun which-key-undo-prefix ()
  (let ((parent-prefix
          (butlast (copy-list *which-key-session-prefix-keys*))))
    (if parent-prefix
        (progn
          (which-key-end-session)
          (unread-key-sequence parent-prefix)
          (error 'editor-abort :message nil))
        ;; Which-Key displays a top-level popup here.  Lem cannot retain a
        ;; root transient across command-loop turns, so use its persistent,
        ;; navigable binding window for the same live top-level information.
        (which-key-standard-help nil))))

(defun which-key-digit-key-p (key)
  (let ((string (which-key-key-string key)))
    (and (= 1 (length string))
         (find (char string 0) "123456789"))))

(defun which-key-replay-with-digit (key)
  (let* ((digit (which-key-key-string key))
         (events
           (append (lem-core::parse-keyspec (format nil "M-~a" digit))
                   (copy-list *which-key-session-prefix-keys*))))
    (which-key-end-session)
    (unread-key-sequence events)
    (error 'editor-abort :message nil)))

(defun which-key-toggle-docstrings ()
  (setf *which-key-show-docstrings*
        (not *which-key-show-docstrings*))
  (which-key-rebuild-session))

(defun which-key-dispatch-prompt ()
  (message
   "~a- [~d/~d] C-h: n next, p previous, u undo, d docs, h help, a abort, 1..9 arg"
   (which-key-sequence-string *which-key-session-prefix-keys*)
   (1+ *which-key-session-page-index*)
   (length *which-key-session-pages*))
  (redraw-display))

(define-command which-key-c-h-dispatch () ()
  "Dispatch the configured Which-Key C-h paging and help controls."
  (if (not (which-key-popup-visible-p))
      (which-key-standard-help
       (copy-list *which-key-session-prefix-keys*))
      (progn
        (which-key-dispatch-prompt)
        (let ((key (read-key)))
          (cond
            ((or (which-key-input-key-p key "n")
                 (which-key-input-key-p key "C-n"))
             (which-key-turn-page 1))
            ((or (which-key-input-key-p key "p")
                 (which-key-input-key-p key "C-p"))
             (which-key-turn-page -1))
            ((or (which-key-input-key-p key "u")
                 (which-key-input-key-p key "C-u"))
             (which-key-undo-prefix))
            ((or (which-key-input-key-p key "d")
                 (which-key-input-key-p key "C-d"))
             (which-key-toggle-docstrings))
            ((or (which-key-input-key-p key "h")
                 (which-key-input-key-p key "C-h"))
             (which-key-standard-help
              (copy-list *which-key-session-prefix-keys*)))
            ((or (which-key-input-key-p key "a")
                 (which-key-input-key-p key "C-a"))
             (which-key-abort-session))
            ((which-key-digit-key-p key)
             (which-key-replay-with-digit key))
            (t
             (which-key-queue-current-page)))))))

(defun which-key-install-input-binding ()
  (define-key *which-key-input-keymap* "C-h"
    'which-key-c-h-dispatch)
  (alexandria:when-let
      ((prefix
         (lem-core::first-prefix-match
          *which-key-input-keymap*
          (first (lem-core::parse-keyspec "C-h")))))
    (setf (lem-core::prefix-behavior prefix) :drop)))

(defmethod lem/transient::show-transient :around
    ((keymap lem-core::keymap))
  "Apply Emacs's quarter-frame height only to automatic Which-Key pages."
  (if (which-key-display-map-p keymap)
      (let ((lem/transient::*transient-popup-max-lines*
              (which-key-column-size)))
        (call-next-method))
      (call-next-method)))

(defun which-key-show-prefix (prefix-keys)
  (when prefix-keys
    (message "~a-" (which-key-sequence-string prefix-keys))))

(defmethod keymap-activate :around ((keymap lem-core::keymap))
  "Show delayed guidance for every ordinary keymap-backed incomplete prefix.
Explicit Lem transients retain their native timing and behavior."
  (let ((native-transient
          (lem/transient::resolve-transient-keymap keymap)))
    (cond
      (*which-key-replay-display-map*
       (let ((display-map *which-key-replay-display-map*))
         (setf *which-key-replay-display-map* nil)
         (let ((lem/transient:*transient-popup-delay* 0))
           (call-next-method display-map))))
      ((or native-transient
           (not (which-key-mode-enabled-p))
           (which-key-command-executing-p)
           (eq keymap lem-core::*root-keymap*)
           (which-key-display-map-p keymap))
       (when (or native-transient
                 (not (which-key-mode-enabled-p))
                 (eq keymap lem-core::*root-keymap*))
         (which-key-reset-session))
       (call-next-method))
      (t
       (let ((prefix-keys (this-command-keys)))
         ;; Deactivate the old snapshot before collecting the live active-map
         ;; graph; transient-mode's own scrolling keys must not leak into the
         ;; next page.  This also implements Emacs's full nested idle delay.
         (lem/transient::hide-transient)
         (which-key-reset-session)
         (let ((display-map
                 (and prefix-keys
                      (which-key-start-session prefix-keys))))
           (if (null display-map)
               (call-next-method)
               (progn
                 (which-key-show-prefix prefix-keys)
                 (let ((lem/transient:*transient-popup-delay*
                         *which-key-idle-delay*))
                   (call-next-method display-map))))))))))

(defun which-key-post-command-cleanup ()
  (unless (or *which-key-replay-display-map*
              (lem/transient::transient-window-alive-p)
              lem/transient::*transient-delay-timer*)
    (which-key-reset-session)))

(defun which-key-disable ()
  (which-key-end-session))

(define-minor-mode which-key-mode
    (:name "Which-Key"
     :global t
     :keymap *which-key-input-keymap*
     :disable-hook 'which-key-disable
     :hide-from-modeline t)
  "Show available continuations after an incomplete key sequence.")

(which-key-install-input-binding)
(add-hook *post-command-hook* 'which-key-post-command-cleanup)
(lem/transient::hide-transient)
(which-key-reset-session)
(which-key-mode t)
