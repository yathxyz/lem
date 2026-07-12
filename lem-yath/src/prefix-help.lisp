;;;; Global Which-Key-style guidance for incomplete key sequences.
;;;; Dispatch remains owned by Lem's live keymaps; this module builds a
;;;; display-only snapshot whose entries are verified through `lookup-keybind'.

(in-package :lem-yath)

(defvar *which-key-idle-delay* 1000
  "Milliseconds of inactivity before automatic prefix help appears.")

(defvar *which-key-description-limit* 27
  "Maximum displayed command-description length, including an ellipsis.")

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

(defun which-key-description (suffix)
  "Describe SUFFIX like an uncustomized Emacs Which-Key entry."
  (which-key-truncate-description
   (cond
     ((which-key-prefix-command-p suffix) "+prefix")
     ((symbolp suffix) (string-downcase (symbol-name suffix)))
     ((functionp suffix) "anonymous command")
     (t (string-downcase (princ-to-string suffix))))))

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
  (let ((continuations
          (loop :for key :in (which-key-active-candidate-keys)
                :for prefix :=
                  (which-key-explicit-continuation prefix-keys key)
                :when prefix
                  :collect
                  (list key
                        (which-key-key-string key)
                        (which-key-description
                         (lem-core::prefix-suffix prefix))))))
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

(defun which-key-make-column (continuations)
  (let ((keymap (lem-core::make-keymap)))
    (dolist (continuation continuations)
      (destructuring-bind (key key-string description) continuation
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

(defun which-key-make-display-map (prefix-keys)
  "Build a display-only, multi-column snapshot for PREFIX-KEYS."
  (let ((continuations (which-key-continuations prefix-keys)))
    (when continuations
      (let ((keymap (lem-core::make-keymap)))
        (setf (lem/transient::keymap-show-p keymap) t
              (lem/transient::keymap-display-style keymap) :row
              (getf (lem-core::keymap-properties keymap)
                    'which-key-display-map-p)
              t)
        (dolist (column
                  (which-key-partition continuations
                                       (which-key-column-size)))
          (lem-core::keymap-add-child
           keymap (which-key-make-column column) t))
        keymap))))

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
      ((or native-transient
           (not (which-key-mode-enabled-p))
           (which-key-command-executing-p)
           (eq keymap lem-core::*root-keymap*)
           (which-key-display-map-p keymap))
       (call-next-method))
      (t
       (let ((prefix-keys (this-command-keys)))
         ;; Deactivate the old snapshot before collecting the live active-map
         ;; graph; transient-mode's own scrolling keys must not leak into the
         ;; next page.  This also implements Emacs's full nested idle delay.
         (lem/transient::hide-transient)
         (let ((display-map
                 (and prefix-keys
                      (which-key-make-display-map prefix-keys))))
           (if (null display-map)
               (call-next-method)
               (progn
                 (which-key-show-prefix prefix-keys)
                 (let ((lem/transient:*transient-popup-delay*
                         *which-key-idle-delay*))
                   (call-next-method display-map))))))))))

(defun which-key-disable ()
  (lem/transient::hide-transient))

(define-minor-mode which-key-mode
    (:name "Which-Key"
     :global t
     :disable-hook 'which-key-disable
     :hide-from-modeline t)
  "Show available continuations after an incomplete key sequence.")

(lem/transient::hide-transient)
(which-key-mode t)
