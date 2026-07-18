;;;; Safe external-change handling and Emacs-style persistent editor state.

(eval-when (:compile-toplevel :load-toplevel :execute)
  #+sbcl (require :sb-posix))

(in-package :lem-yath)

(defparameter *persistence-format-version* 1)
(defparameter *persistence-state-size-limit* (* 32 1024 1024))
(defparameter *persistence-path-size-limit* 2048)
(defparameter *persistence-kill-string-size-limit* (* 64 1024))
(defparameter *persistence-search-string-size-limit* 4096)
(defparameter *persistence-prompt-string-size-limit* 1024)
(defparameter *persistence-reader-depth-limit* 16)
(defparameter *persistence-reader-object-limit* 10000)
(defparameter *persistence-reader-atom-size-limit* 64)
(defparameter *persistence-save-interval* 300)
(defparameter *save-place-limit* 600)
(defparameter *prompt-history-limit* 100)
(defparameter *kill-ring-size* 120)
(defparameter *saved-kill-ring-limit* 40)
(defparameter *search-ring-limit* 16)
(defparameter *safe-auto-revert-interval* 5)
(defparameter *safe-auto-revert-digest-limit* (* 16 1024 1024))
(defparameter *persistence-failure-retry-interval* 60)

(defvar *saved-places* '())
(defvar *forgotten-place-paths* '())
(defvar *literal-search-history* '())
(defvar *regexp-search-history* '())
(defvar *persistence-loaded-p* nil)
(defvar *last-persistence-save-time* 0)
(defvar *last-persistence-failure-time* nil)
(defvar *persistence-failure-reported-p* nil)
(defvar *persistence-state-baseline* nil
  "Normalized state last applied to this process from shared storage.")
(defvar *last-auto-revert-check-time* nil)
(defvar *safe-auto-revert-timer* nil)
(defvar *isearch-history-position* nil)
(defvar *isearch-history-edit-string* "")
(defvar *isearch-history-selected-string* nil)
(defvar *isearch-history-start-point* nil)

(defparameter *persistent-prompt-history-keys*
  '(("LEM-YATH" "LEM-YATH-CITAR")
    ("LEM-YATH" "LEM-YATH-DEVDOCS-DOCSET")
    ("LEM-YATH" "LEM-YATH-DEVDOCS-ENTRY")
    ("LEM-YATH" "LEM-YATH-FIND-NAME")
    ("LEM-YATH" "LEM-YATH-LLM-BACKEND")
    ("LEM-YATH" "LEM-YATH-LLM-MODEL")
    ("LEM-YATH" "LEM-YATH-NOTMUCH")
    ("LEM-YATH" "LEM-YATH-PROJECT-GREP")
    ("LEM-YATH" "LEM-YATH-ROAM")
    ("LEM-YATH" "LEM-YATH-WORKSPACE-SYMBOL")
    ("LEM-YATH" "LEM-YATH-WORKSPACE-SYMBOL-QUERY"))
  "Reviewed prompt histories safe to persist.  Unknown names default to private.")

(defun persistence-state-override ()
  (uiop:getenv "LEM_YATH_PERSISTENCE_STATE_FILE"))

(defun persistence-state-pathname ()
  "Return the private state file, allowing a hermetic test override."
  (alexandria:if-let (override (persistence-state-override))
    (uiop:parse-native-namestring override)
    (merge-pathnames "state/persistence.sexp" (lem-home))))

(defun persistence-lock-pathname ()
  (uiop:parse-native-namestring
   (concatenate 'string
                (uiop:native-namestring (persistence-state-pathname))
                ".lock")))

(defun bounded-persistence-string-p (value limit)
  (and (stringp value)
       (<= (length value) limit)))

(defun proper-list-p (value)
  (and (listp value)
       (handler-case
           (integerp (list-length value))
         (type-error () nil))))

(defun take-list (list limit)
  (loop :for value :in list
        :repeat limit
        :collect value))

(defun readable-string-copy (string)
  "Return a non-displaced simple string that PRIN1 writes without #A syntax."
  (let ((copy (make-string (length string) :element-type 'character)))
    (replace copy string)
    copy))

(defun merge-mru-list (newer older &key (test #'equal) limit key)
  "Merge newest-first lists NEWER and OLDER without losing either writer."
  ;; Every caller uses case-sensitive string or structural equality, for which
  ;; an EQUAL hash table avoids quadratic work on a hostile state form.
  (declare (ignore test))
  (let ((result '())
        (seen (make-hash-table :test #'equal)))
    (dolist (item (append newer older))
      (let ((identity (if key (funcall key item) item)))
        (unless (gethash identity seen)
          (setf (gethash identity seen) t)
          (push item result))))
    (setf result (nreverse result))
    (if limit (take-list result limit) result)))

(defun normalize-string-history (history count-limit string-limit)
  (if (proper-list-p history)
      (merge-mru-list
       (loop :for value :in history
             :repeat (* 2 count-limit)
             :when (bounded-persistence-string-p value string-limit)
               :collect (readable-string-copy value))
       '()
       :test #'string=
       :limit count-limit)
      '()))

(defun valid-place-entry-p (entry)
  (and (proper-list-p entry)
       (= 2 (length entry))
       (bounded-persistence-string-p
        (first entry) *persistence-path-size-limit*)
       (or (and (integerp (second entry))
                (<= 1 (second entry) most-positive-fixnum))
           (bounded-persistence-string-p
            (second entry) *persistence-path-size-limit*))))

(defun normalize-places (places)
  (if (proper-list-p places)
      (merge-mru-list
       (loop :for entry :in places
             :repeat (* 2 *save-place-limit*)
             :when (valid-place-entry-p entry)
               :collect (list (readable-string-copy (first entry))
                              (if (stringp (second entry))
                                  (readable-string-copy (second entry))
                                  (second entry))))
       '()
       :test #'string=
       :key #'first
       :limit *save-place-limit*)
      '()))

(defun valid-kill-options-p (options)
  (member options '(nil (:vi-line) (:vi-block)) :test #'equal))

(defun valid-kill-entry-p (entry)
  (and (proper-list-p entry)
       (= 2 (length entry))
       (bounded-persistence-string-p
        (first entry) *persistence-kill-string-size-limit*)
       (valid-kill-options-p (second entry))))

(defun normalize-kill-entries (entries)
  (if (proper-list-p entries)
      (loop :for entry :in entries
            :repeat (* 2 *saved-kill-ring-limit*)
            :when (valid-kill-entry-p entry)
              :collect (list (readable-string-copy (first entry))
                             (copy-list (second entry)))
                :into result
            :when (= (length result) *saved-kill-ring-limit*)
              :do (loop-finish)
            :finally (return result))
      '()))

(defun valid-prompt-key-p (key)
  (and (proper-list-p key)
       (= 2 (length key))
       (every (lambda (value)
                (bounded-persistence-string-p value 256))
              key)))

(defun persistent-prompt-key-p (key)
  (member key *persistent-prompt-history-keys* :test #'equal))

(defun valid-prompt-entry-p (entry)
  (and (proper-list-p entry)
       (= 2 (length entry))
       (valid-prompt-key-p (first entry))
       (persistent-prompt-key-p (first entry))
       (proper-list-p (second entry))))

(defun normalize-prompt-histories (entries)
  (if (proper-list-p entries)
      (loop :for entry :in entries
            :repeat (* 2 (length *persistent-prompt-history-keys*))
            :when (valid-prompt-entry-p entry)
              :collect
              (list (mapcar #'readable-string-copy (first entry))
                    (normalize-string-history
                     (second entry)
                     *prompt-history-limit*
                     *persistence-prompt-string-size-limit*)))
      '()))

(defun empty-persistence-state ()
  (list :version *persistence-format-version*
        :bookmarks '()
        :places '()
        :kill-ring '()
        :literal-searches '()
        :regexp-searches '()
        :prompt-histories '()))

(defun normalize-persistence-state (state)
  (handler-case
      (if (and (proper-list-p state)
               (evenp (length state))
               (eql (getf state :version) *persistence-format-version*))
          (list :version *persistence-format-version*
                :bookmarks
                (normalize-bookmark-state (getf state :bookmarks))
                :places (normalize-places (getf state :places))
                :kill-ring
                (normalize-kill-entries (getf state :kill-ring))
                :literal-searches
                (normalize-string-history
                 (getf state :literal-searches)
                 *search-ring-limit*
                 *persistence-search-string-size-limit*)
                :regexp-searches
                (normalize-string-history
                 (getf state :regexp-searches)
                 *search-ring-limit*
                 *persistence-search-string-size-limit*)
                :prompt-histories
                (normalize-prompt-histories
                 (getf state :prompt-histories)))
          (empty-persistence-state))
    (error () (empty-persistence-state))))

(defun read-bounded-utf8-file (pathname)
  "Read at most the configured byte budget through one open descriptor."
  (with-open-file (stream pathname :element-type '(unsigned-byte 8))
    (let ((declared-length (file-length stream)))
      (when (> declared-length *persistence-state-size-limit*)
        (error "Persistence state exceeds ~:d bytes"
               *persistence-state-size-limit*))
      (let* ((octets
               (make-array (1+ declared-length)
                           :element-type '(unsigned-byte 8)))
             (count (read-sequence octets stream)))
        (when (> count declared-length)
          (error "Persistence state changed while being read"))
        #+sbcl
        (sb-ext:octets-to-string octets
                                 :end count
                                 :external-format :utf-8)
        #-sbcl
        (error "Safe persistence requires the supported SBCL runtime")))))

(defparameter *persistence-reader-atoms*
  '("NIL" ":VERSION" ":BOOKMARKS" ":PLACES" ":KILL-RING" ":LITERAL-SEARCHES"
    ":REGEXP-SEARCHES" ":PROMPT-HISTORIES" ":VI-LINE" ":VI-BLOCK"))

(defun validate-persistence-reader-text (text)
  "Accept only the small list/string/integer grammar emitted by our writer."
  (let ((depth 0)
        (objects 0)
        (token-start nil)
        (in-string-p nil)
        (escaped-p nil))
    (labels ((count-object ()
               (when (> (incf objects) *persistence-reader-object-limit*)
                 (error "Persistence state has too many objects")))
             (finish-token (end)
               (when token-start
                 (let ((token-length (- end token-start)))
                   (when (> token-length
                            *persistence-reader-atom-size-limit*)
                     (error "Persistence atom is too large"))
                   (let ((token (subseq text token-start end)))
                     (unless (or (member (string-upcase token)
                                         *persistence-reader-atoms*
                                         :test #'string=)
                                 (and (plusp token-length)
                                      (every #'digit-char-p token)))
                       (error "Unsupported persistence atom: ~a" token))
                     (count-object)
                     (setf token-start nil))))))
      (loop :for index :below (length text)
            :for character := (char text index)
            :do
               (if in-string-p
                   (cond
                     (escaped-p (setf escaped-p nil))
                     ((char= character #\\) (setf escaped-p t))
                     ((char= character #\") (setf in-string-p nil)))
                   (cond
                     ((member character
                              '(#\Space #\Tab #\Newline #\Return #\Page))
                      (finish-token index))
                     ((char= character #\()
                      (finish-token index)
                      (when (> (incf depth) *persistence-reader-depth-limit*)
                        (error "Persistence state is nested too deeply"))
                      (count-object))
                     ((char= character #\))
                      (finish-token index)
                      (when (minusp (decf depth))
                        (error "Unbalanced persistence state")))
                     ((char= character #\")
                      (finish-token index)
                      (setf in-string-p t)
                      (count-object))
                     ((find character "#'`,;|\\")
                      (error "Unsupported persistence reader syntax"))
                     ((null token-start)
                      (setf token-start index)))))
      (finish-token (length text))
      (unless (and (zerop depth) (not in-string-p) (not escaped-p))
        (error "Unbalanced persistence state"))
      t)))

(defun reject-persistence-dispatch (stream character)
  (declare (ignore stream character))
  (error "Dispatch reader syntax is forbidden in persistence state"))

(defun persistence-readtable ()
  (let ((readtable (copy-readtable nil)))
    (set-macro-character #\# #'reject-persistence-dispatch nil readtable)
    readtable))

(defun read-persistence-state-file ()
  "Read one non-evaluating, bounded state form; malformed state is ignored."
  (let ((pathname (persistence-state-pathname)))
    (if (uiop:file-exists-p pathname)
        (handler-case
            (let ((text (read-bounded-utf8-file pathname)))
              (validate-persistence-reader-text text)
              (with-input-from-string (stream text)
                (let ((*read-eval* nil)
                      (*readtable* (persistence-readtable)))
                (let ((state (read stream nil :eof)))
                  (if (or (eq state :eof)
                          (not (eq (read stream nil :eof) :eof)))
                      (empty-persistence-state)
                        (normalize-persistence-state state))))))
          (error () (empty-persistence-state)))
        (empty-persistence-state))))

(defun call-with-persistence-lock (function)
  "Serialize state merges across Lem processes with an OS-released lock."
  (let* ((pathname (persistence-state-pathname))
         (directory (uiop:pathname-directory-pathname pathname))
         (directory-existed-p (uiop:directory-exists-p directory)))
    (ensure-directories-exist pathname)
  #+sbcl
    (progn
      (if (and (persistence-state-override) directory-existed-p)
          (let ((stat (sb-posix:stat (uiop:native-namestring directory))))
            (unless (and (= (sb-posix:stat-uid stat) (sb-posix:getuid))
                         (zerop (logand (sb-posix:stat-mode stat) #o077)))
              (error "Persistence override directory must be owned by this user and mode 0700: ~a"
                     directory)))
          (sb-posix:chmod (uiop:native-namestring directory) #o700))
      (when (uiop:file-exists-p pathname)
        (let ((stat (sb-posix:lstat (uiop:native-namestring pathname))))
          (unless (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
                     sb-posix:s-ifreg)
            (error "Persistence state is not a regular file: ~a" pathname))
          (sb-posix:chmod (uiop:native-namestring pathname) #o600)))
      (let ((descriptor
              (sb-posix:open
               (uiop:native-namestring (persistence-lock-pathname))
               (logior sb-posix:o-creat sb-posix:o-rdwr
                       sb-posix:o-nofollow)
               #o600)))
        (unwind-protect
             (progn
               (sb-posix:fchmod descriptor #o600)
               (let ((stat (sb-posix:fstat descriptor)))
                 (unless (= (logand (sb-posix:stat-mode stat)
                                    sb-posix:s-ifmt)
                            sb-posix:s-ifreg)
                   (error "Persistence lock is not a regular file")))
               (sb-posix:lockf descriptor sb-posix:f-lock 0)
               (funcall function))
          (ignore-errors (sb-posix:lockf descriptor sb-posix:f-ulock 0))
          (ignore-errors (sb-posix:close descriptor)))))
  #-sbcl
    (error "Safe persistence requires the supported SBCL runtime")))

(defun serialize-persistence-state (state)
  "Return normalized UTF-8 state bytes, refusing an unreadable future file."
  (let* ((string
           (with-output-to-string (stream)
             (let ((*print-readably* t)
                   (*print-pretty* nil))
               (prin1 (normalize-persistence-state state) stream)
               (terpri stream))))
         (octets
           #+sbcl
           (sb-ext:string-to-octets string :external-format :utf-8)
           #-sbcl
           (error "Safe persistence requires the supported SBCL runtime")))
    (when (> (length octets) *persistence-state-size-limit*)
      (error "Refusing persistence state larger than ~:d bytes"
             *persistence-state-size-limit*))
    octets))

(defun persistence-temporary-pathname (pathname)
  (uiop:parse-native-namestring
   (format nil "~a.tmp.~d.~16,'0x"
           (uiop:native-namestring pathname)
           #+sbcl (sb-posix:getpid)
           #-sbcl 0
           (random (ash 1 60)))))

(defun write-persistence-state-file (state)
  "Atomically replace the state file with mode 0600."
  (let* ((pathname (persistence-state-pathname))
         (temporary (persistence-temporary-pathname pathname))
         (octets (serialize-persistence-state state))
         (descriptor nil)
         (stream nil))
    (unwind-protect
         (progn
           #+sbcl
           (progn
             (setf descriptor
                   (sb-posix:open
                    (uiop:native-namestring temporary)
                    (logior sb-posix:o-creat sb-posix:o-excl
                            sb-posix:o-wronly sb-posix:o-nofollow)
                    #o600))
             (sb-posix:fchmod descriptor #o600)
             (setf stream
                   (sb-sys:make-fd-stream
                    descriptor
                    :output t
                    :element-type '(unsigned-byte 8)
                    :buffering :full
                    :name (uiop:native-namestring temporary)))
             (write-sequence octets stream)
             (finish-output stream)
             (sb-posix:fsync descriptor)
             (close stream)
             (setf stream nil
                   descriptor nil))
           #-sbcl
           (error "Safe persistence requires the supported SBCL runtime")
           (uiop:rename-file-overwriting-target temporary pathname)
           #+sbcl (sb-posix:chmod (uiop:native-namestring pathname) #o600))
      (when stream
        (handler-case
            (progn
              (close stream :abort t)
              (setf descriptor nil))
          (error () nil))
        (setf stream nil))
      (when descriptor
        (ignore-errors (sb-posix:close descriptor)))
      (when (uiop:file-exists-p temporary)
        (ignore-errors (delete-file temporary))))))

;;; --- saved places ---------------------------------------------------------

(defun save-place-excluded-file-p (pathname)
  (let ((name (file-namestring pathname)))
    (or (string= name "COMMIT_EDITMSG")
        (string= name "svn-commit.tmp")
        (cl-ppcre:scan "^hg-editor-.*\\.txt$" name)
        (cl-ppcre:scan "^bzr_log\\..*$" name))))

(defun persistent-buffer-path (buffer)
  (alexandria:when-let
      ((filename
         (or (buffer-filename buffer)
             (and (mode-active-p
                   buffer 'lem/directory-mode/mode:directory-mode)
                  (buffer-directory buffer)))))
    (handler-case
        (let ((pathname (truename filename)))
          (unless (and (buffer-filename buffer)
                       (save-place-excluded-file-p pathname))
            (uiop:native-namestring pathname)))
      (error () nil))))

(defun directory-place-value (buffer)
  (when (mode-active-p buffer 'lem/directory-mode/mode:directory-mode)
    (alexandria:when-let
        ((pathname
           (lem/directory-mode/internal:get-pathname
            (buffer-point buffer))))
      (uiop:native-namestring pathname))))

(defun restore-directory-place (buffer selected-path)
  "Move BUFFER to its row for SELECTED-PATH, if that entry still exists."
  (with-point ((row (buffer-start-point buffer)))
    (loop
      (alexandria:when-let
          ((pathname (lem/directory-mode/internal:get-pathname row)))
        (when (string= selected-path (uiop:native-namestring pathname))
          (move-point (buffer-point buffer) row)
          (return selected-path)))
      (unless (line-offset row 1)
        (return nil)))))

(defun record-buffer-place (&optional (buffer (current-buffer)))
  "Remember BUFFER's point, omitting point one and transient VCS files."
  (alexandria:when-let ((path (persistent-buffer-path buffer)))
    (let ((position
            (or (directory-place-value buffer)
                (position-at-point (buffer-point buffer)))))
      (setf *saved-places*
            (remove path *saved-places* :key #'first :test #'string=)
            *forgotten-place-paths*
            (remove path *forgotten-place-paths* :test #'string=))
      (if (and (integerp position) (= position 1))
          (pushnew path *forgotten-place-paths* :test #'string=)
          (push (list path position) *saved-places*))
      (setf *saved-places*
            (take-list *saved-places* *save-place-limit*))
      position)))

(defun record-all-buffer-places ()
  (dolist (buffer (buffer-list))
    (unless (deleted-buffer-p buffer)
      (record-buffer-place buffer))))

(defun restore-buffer-place (&optional (buffer (current-buffer)))
  "Restore BUFFER's saved point, clamping an obsolete position to EOF."
  (alexandria:when-let* ((path (persistent-buffer-path buffer))
                         (entry (find path *saved-places*
                                      :key #'first :test #'string=)))
    (let ((position (second entry)))
      (if (stringp position)
          (and (mode-active-p
                buffer 'lem/directory-mode/mode:directory-mode)
               (restore-directory-place buffer position))
          (let ((point (buffer-point buffer)))
            (unless (move-to-position point position)
              (buffer-end point))
            position)))))

(defun persistence-place-snapshot ()
  (copy-tree *saved-places*))

;;; --- kill ring ------------------------------------------------------------

(defun persistence-kill-ring-snapshot
    (&optional (killring (current-killring))
               (limit (lem/common/ring:ring-length
                       (lem/common/killring::killring-ring killring))))
  "Return physical newest-first entries, independent of yank-pop rotation."
  (let ((snapshot (lem/common/killring:copy-killring killring)))
    (loop :for index :below
            (min limit
                 (lem/common/ring:ring-length
                  (lem/common/killring::killring-ring snapshot)))
          :collect
          (multiple-value-bind (string options)
              (lem/common/killring:peek-killring-item snapshot index)
            (list string (copy-list options))))))

(defun restore-kill-ring (entries)
  (let ((killring (lem/common/killring:make-killring *kill-ring-size*)))
    (dolist (entry (reverse (normalize-kill-entries entries)))
      (lem/common/killring:push-killring-item
       killring (first entry) :options (second entry)))
    (setf lem-core::*killring* killring)
    killring))

(defmethod lem/common/killring:push-killring-item :around
    ((killring lem/common/killring::killring) string
     &rest arguments
     &key (options lem/common/killring::*options*) &allow-other-keys)
  "Match `kill-do-not-save-duplicates': suppress only a consecutive duplicate."
  (declare (ignore arguments))
  (let* ((options (alexandria:ensure-list options))
         (ring (lem/common/killring::killring-ring killring)))
    (if (and (not lem/common/killring::*appending*)
             (plusp (lem/common/ring:ring-length ring))
             (let ((newest (lem/common/ring:ring-ref ring 0)))
               (and (string= string
                             (lem/common/killring::item-string newest))
                    (equal options
                           (lem/common/killring::item-options newest)))))
        (progn
          (setf (lem/common/killring::killring-offset killring) 0)
          killring)
        (call-next-method))))

;;; --- literal and regexp search rings -------------------------------------

(defun add-search-history (string regexp-p)
  (when (and (stringp string) (plusp (length string)))
    (if regexp-p
        (setf *regexp-search-history*
              (merge-mru-list
               (list string) *regexp-search-history*
               :test #'string= :limit *search-ring-limit*))
        (setf *literal-search-history*
              (merge-mru-list
               (list string) *literal-search-history*
               :test #'string= :limit *search-ring-limit*)))))

(defun current-isearch-regexp-p ()
  (and (boundp 'lem/isearch::*isearch-search-forward-function*)
       (eq lem/isearch::*isearch-search-forward-function*
           #'search-forward-regexp)))

(defun current-isearch-history ()
  (if (current-isearch-regexp-p)
      *regexp-search-history*
      *literal-search-history*))

(defun record-isearch-history (string)
  (add-search-history string (current-isearch-regexp-p))
  (setf *isearch-history-position* nil
        *isearch-history-selected-string* nil
        *isearch-history-start-point* nil))

(defun reset-isearch-history-session ()
  (setf *isearch-history-position* nil
        *isearch-history-edit-string* ""
        *isearch-history-selected-string* nil
        *isearch-history-start-point*
        (and (boundp 'lem/isearch::*isearch-start-point*)
             lem/isearch::*isearch-start-point*)))

(defun prepare-isearch-history-session ()
  (when (or (not (eq *isearch-history-start-point*
                     lem/isearch::*isearch-start-point*))
            (and *isearch-history-selected-string*
                 (not (string=
                       *isearch-history-selected-string*
                       lem/isearch::*isearch-string*))))
    (reset-isearch-history-session))
  (unless *isearch-history-position*
    (setf *isearch-history-edit-string* lem/isearch::*isearch-string*)))

(defun replace-active-isearch-string (string)
  (setf lem/isearch::*isearch-string* string
        *isearch-history-selected-string* string)
  (funcall lem/isearch::*isearch-search-function*
           (current-point) string)
  (lem/isearch::isearch-update-display)
  string)

(define-command lem-yath-isearch-previous-history () ()
  "Replace the active isearch input with the next older same-kind search."
  (prepare-isearch-history-session)
  (let ((history (current-isearch-history)))
    (when history
      (let ((next (if *isearch-history-position*
                      (min (1+ *isearch-history-position*)
                           (1- (length history)))
                      0)))
        (setf *isearch-history-position* next)
        (replace-active-isearch-string (nth next history))))))

(define-command lem-yath-isearch-next-history () ()
  "Move toward newer isearch history, restoring the edited input at the end."
  (prepare-isearch-history-session)
  (when *isearch-history-position*
    (if (plusp *isearch-history-position*)
        (progn
          (decf *isearch-history-position*)
          (replace-active-isearch-string
           (nth *isearch-history-position* (current-isearch-history))))
        (progn
          (setf *isearch-history-position* nil)
          (replace-active-isearch-string *isearch-history-edit-string*)))))

(defun start-persistent-isearch (regexp-p backward-p)
  (let ((history (if regexp-p
                     *regexp-search-history*
                     *literal-search-history*)))
    ;; Lem has one shared previous string.  Set it per search kind so an empty
    ;; C-s/C-r repeat uses the correct persisted ring without rewriting config.
    (setf lem/isearch::*isearch-previous-string* (or (first history) ""))
    (cond
      ((and regexp-p backward-p)
       (lem/isearch:isearch-backward-regexp))
      (regexp-p
       (lem/isearch:isearch-forward-regexp))
      (backward-p
       (lem/isearch:isearch-backward))
      (t
       (lem/isearch:isearch-forward)))
    (reset-isearch-history-session)))

(define-command lem-yath-isearch-forward () ()
  (start-persistent-isearch nil nil))

(define-command lem-yath-isearch-backward () ()
  (start-persistent-isearch nil t))

(define-command lem-yath-isearch-forward-regexp () ()
  (start-persistent-isearch t nil))

(define-command lem-yath-isearch-backward-regexp () ()
  (start-persistent-isearch t t))

;;; --- named prompt histories ----------------------------------------------

(defun prompt-symbol-key (symbol)
  (list (package-name (symbol-package symbol)) (symbol-name symbol)))

(defun persistent-prompt-history-symbol-p (symbol)
  "Persist only reviewed names; shared, SQL, connection, and unknown stay private."
  (and (symbolp symbol)
       symbol
       (symbol-package symbol)
       (persistent-prompt-key-p (prompt-symbol-key symbol))))

(defun prompt-key-symbol (key)
  (when (valid-prompt-key-p key)
    (alexandria:when-let ((package (find-package (first key))))
      (find-symbol (second key) package))))

(defun persistence-prompt-history-snapshot ()
  "Return safe named prompt histories as newest-first string lists."
  (sort
   (loop :for symbol :being :the :hash-keys
           :of lem/prompt-window::*history-table*
         :using (hash-value history)
         :when (persistent-prompt-history-symbol-p symbol)
           :collect
           (list (prompt-symbol-key symbol)
                 (normalize-string-history
                  (reverse (lem/common/history:history-data-list history))
                  *prompt-history-limit*
                  *persistence-prompt-string-size-limit*)))
   #'string< :key (lambda (entry) (format nil "~{~a~^/~}" (first entry)))))

(defun restore-prompt-histories (entries)
  (dolist (entry (normalize-prompt-histories entries))
    (alexandria:when-let ((symbol (prompt-key-symbol (first entry))))
      (when (persistent-prompt-history-symbol-p symbol)
        (let ((history
                (lem/common/history:make-history
                 :limit *prompt-history-limit*)))
          (dolist (string (reverse (second entry)))
            (lem/common/history:add-history
             history string :allow-duplicates nil))
          (setf (gethash symbol lem/prompt-window::*history-table*) history))))))

(defun cap-live-prompt-history (history)
  (let* ((data (lem/common/history::history-data history))
         (count (length data)))
    (when (> count *prompt-history-limit*)
      (replace data data
               :start1 0
               :end1 *prompt-history-limit*
               :start2 (- count *prompt-history-limit*)
               :end2 count)
      (setf (fill-pointer data) *prompt-history-limit*))
    (setf (lem/common/history::history-limit history) *prompt-history-limit*
          (lem/common/history::history-index history) (length data))
    history))

(defun cap-all-live-prompt-histories ()
  (loop :for history :being :the :hash-values
          :of lem/prompt-window::*history-table*
        :do (cap-live-prompt-history history)))

;;; --- state merge, load, and flush ----------------------------------------

(defun prompt-history-value (key histories)
  (second (find key histories :key #'first :test #'equal)))

(defun merge-three-way-mru-list
    (live disk baseline &key (test #'equal) limit)
  "Merge one MRU list without reviving entries removed by either writer.

An unchanged local list follows DISK exactly.  Otherwise additions made since
BASELINE are unioned, while a baseline entry survives only when both LIVE and
DISK still contain it.  This makes intentional removals stable across stale
processes without discarding independent concurrent additions."
  (cond
    ((equal live baseline)
     (if limit (take-list disk limit) disk))
    ((equal disk baseline)
     (if limit (take-list live limit) live))
    (t
     (let ((merged (merge-mru-list live disk :test test)))
       (setf merged
             (remove-if-not
              (lambda (entry)
                (or (not (member entry baseline :test test))
                    (and (member entry live :test test)
                         (member entry disk :test test))))
              merged))
       (if limit (take-list merged limit) merged)))))

(defun merge-prompt-histories (newer older baseline)
  (let ((keys
          (merge-mru-list (mapcar #'first newer)
                          (mapcar #'first older)
                          :test #'equal)))
    (mapcar
     (lambda (key)
       (list key
             (merge-three-way-mru-list
              (prompt-history-value key newer)
              (prompt-history-value key older)
              (prompt-history-value key baseline)
              :test #'string=
              :limit *prompt-history-limit*)))
     keys)))

(defun merge-kill-ring-state (newer older baseline)
  ;; Preserve duplicates already present in a process's live ring, while only
  ;; appending entries learned from another process when they are not present.
  (cond
    ((equal newer baseline) (take-list older *saved-kill-ring-limit*))
    ((equal older baseline) (take-list newer *saved-kill-ring-limit*))
    (t
     (take-list
      (remove-if-not
       (lambda (entry)
         (or (not (member entry baseline :test #'equal))
             (and (member entry newer :test #'equal)
                  (member entry older :test #'equal))))
       (append newer
               (remove-if (lambda (entry)
                            (member entry newer :test #'equal))
                          older)))
      *saved-kill-ring-limit*))))

(defun place-state-table (places)
  (let ((table (make-hash-table :test #'equal)))
    (dolist (entry places table)
      (setf (gethash (first entry) table) entry))))

(defun merge-place-state (live disk baseline)
  "Apply local place changes since BASELINE over the latest DISK state."
  (let* ((baseline-table (place-state-table baseline))
         (live-table (place-state-table live))
         (result-table (place-state-table disk)))
    (maphash
     (lambda (path baseline-entry)
       (multiple-value-bind (live-entry live-p) (gethash path live-table)
         (cond
           ((not live-p)
            (remhash path result-table))
           ((not (equal live-entry baseline-entry))
            (setf (gethash path result-table) live-entry)))))
     baseline-table)
    (maphash
     (lambda (path live-entry)
       (unless (gethash path baseline-table)
         (setf (gethash path result-table) live-entry)))
     live-table)
    (let ((order (if (equal live baseline)
                     (merge-mru-list disk live :key #'first)
                     (merge-mru-list live disk :key #'first))))
      (loop :for candidate :in order
            :for path = (first candidate)
            :for entry = (gethash path result-table)
            :when entry
              :collect entry))))

(defun persistent-place-path-exists-p (path)
  (or (uiop:file-exists-p path)
      (uiop:directory-exists-p path)))

(defun merge-persistence-states (newer older &optional baseline)
  (let* ((newer (normalize-persistence-state newer))
         (older (normalize-persistence-state older))
         (baseline
           (normalize-persistence-state
            (or baseline *persistence-state-baseline*)))
         (places
           (remove-if
            (lambda (entry)
              (or (member (first entry) *forgotten-place-paths*
                          :test #'string=)
                  (not (persistent-place-path-exists-p (first entry)))))
            (take-list
             (merge-place-state (getf newer :places)
                                (getf older :places)
                                (getf baseline :places))
             *save-place-limit*))))
    (list :version *persistence-format-version*
          :bookmarks
          (merge-bookmark-persistence-state
           (getf newer :bookmarks)
           (getf older :bookmarks))
          :places places
          :kill-ring
          (merge-kill-ring-state (getf newer :kill-ring)
                                 (getf older :kill-ring)
                                 (getf baseline :kill-ring))
          :literal-searches
          (merge-three-way-mru-list
           (getf newer :literal-searches)
           (getf older :literal-searches)
           (getf baseline :literal-searches)
           :test #'string= :limit *search-ring-limit*)
          :regexp-searches
          (merge-three-way-mru-list
           (getf newer :regexp-searches)
           (getf older :regexp-searches)
           (getf baseline :regexp-searches)
           :test #'string= :limit *search-ring-limit*)
          :prompt-histories
          (merge-prompt-histories (getf newer :prompt-histories)
                                  (getf older :prompt-histories)
                                  (getf baseline :prompt-histories)))))

(defun collect-persistence-state ()
  (list :version *persistence-format-version*
        :bookmarks (bookmark-persistence-snapshot)
        :places (copy-tree *saved-places*)
        :kill-ring
        (persistence-kill-ring-snapshot
         (current-killring) *saved-kill-ring-limit*)
        :literal-searches (copy-list *literal-search-history*)
        :regexp-searches (copy-list *regexp-search-history*)
        :prompt-histories (persistence-prompt-history-snapshot)))

(defun apply-persistence-state
    (state &key restore-live-kill-ring restore-bookmarks)
  (let ((state (normalize-persistence-state state)))
    (setf *saved-places* (copy-tree (getf state :places))
          *literal-search-history* (copy-list (getf state :literal-searches))
          *regexp-search-history* (copy-list (getf state :regexp-searches)))
    (when restore-live-kill-ring
      (restore-kill-ring (getf state :kill-ring)))
    (when restore-bookmarks
      (load-bookmark-persistence-state (getf state :bookmarks)))
    (restore-prompt-histories (getf state :prompt-histories))
    state))

(defun load-persistence-state ()
  "Safely load bookmarks, places, rings, and prompt histories from disk."
  (call-with-persistence-lock
   (lambda ()
     (let ((state (read-persistence-state-file)))
       (apply-persistence-state state
                                :restore-live-kill-ring t
                                :restore-bookmarks t)
       (setf *persistence-state-baseline* (copy-tree state)))))
  (setf *persistence-loaded-p* t
        *last-persistence-save-time* (get-internal-real-time))
  t)

(defun flush-persistence-state (&key (record-places t))
  "Merge and atomically persist this process's state under an interprocess lock."
  (when record-places
    (record-all-buffer-places))
  (call-with-persistence-lock
   (lambda ()
     (let* ((live (collect-persistence-state))
            (merged
             (merge-persistence-states
              live
              (read-persistence-state-file))))
       (write-persistence-state-file merged)
       ;; Pull merged bookmark/place/search/prompt state into this process.
       ;; Rebuilding the kill ring would disturb yank-pop rotation mid-session.
       (apply-persistence-state merged
                                :restore-live-kill-ring nil
                                :restore-bookmarks t)
       ;; The merged kill ring is deliberately not installed because doing so
       ;; would disturb yank-pop rotation.  Baseline only the ring this process
       ;; actually retains; every other category now reflects MERGED live.
       (setf *persistence-state-baseline* (copy-tree merged)
             (getf *persistence-state-baseline* :kill-ring)
             (copy-tree (getf live :kill-ring))))))
  (setf *forgotten-place-paths* '()
        *last-persistence-save-time* (get-internal-real-time))
  t)

(defun persistence-save-due-p ()
  (>= (- (get-internal-real-time) *last-persistence-save-time*)
      (* *persistence-save-interval* internal-time-units-per-second)))

(defun persistence-retry-due-p ()
  (or (null *last-persistence-failure-time*)
      (>= (- (get-internal-real-time) *last-persistence-failure-time*)
          (* *persistence-failure-retry-interval*
             internal-time-units-per-second))))

(defun call-persistence-safely (function context)
  "Keep ancillary state I/O failure from aborting editing or editor exit."
  (handler-case
      (prog1 (funcall function)
        (setf *last-persistence-failure-time* nil
              *persistence-failure-reported-p* nil))
    (error (condition)
      (setf *last-persistence-failure-time* (get-internal-real-time))
      (unless *persistence-failure-reported-p*
        (setf *persistence-failure-reported-p* t)
        (ignore-errors
          (message "Persistence ~a failed: ~a" context condition)))
      nil)))

(defun maybe-flush-persistence-state ()
  (when (and (persistence-save-due-p) (persistence-retry-due-p))
    ;; Savehist is periodic; save-place remains kill/switch/exit driven.
    (call-persistence-safely
     (lambda () (flush-persistence-state :record-places nil))
     "periodic save")))

;;; --- safe external-change handling ---------------------------------------

(defun stat-file-metadata (stat)
  (list (sb-posix:stat-dev stat)
        (sb-posix:stat-ino stat)
        (sb-posix:stat-size stat)
        (sb-posix:stat-mtime stat)
        (sb-posix:stat-ctime stat)))

(defun stat-optional-value (stat accessor-name)
  (let ((accessor (find-symbol accessor-name :sb-posix)))
    (and accessor (fboundp accessor) (funcall accessor stat))))

(defun directory-entry-name-signature (directory)
  "Hash direct entry names when SB-POSIX cannot expose subsecond mtimes."
  (let ((hash #xcbf29ce484222325)
        (count 0))
    (dolist (pathname (list-directory directory :sort-method :pathname))
      (incf count)
      (loop :for character :across (uiop:native-namestring pathname)
            :do (setf hash
                      (logand #xffffffffffffffff
                              (* (logxor hash (char-code character))
                                 #x100000001b3))))
      (setf hash
            (logand #xffffffffffffffff
                    (* (logxor hash #xff) #x100000001b3))))
    (list count hash)))

(defun directory-state-signature (buffer)
  "Return Dired-style identity and modification time for BUFFER's directory."
  (handler-case
      (let* ((directory
               (uiop:ensure-directory-pathname (buffer-directory buffer)))
             (stat (sb-posix:stat (uiop:native-namestring directory)))
             (mtime-nsec
               (stat-optional-value stat "STAT-MTIME-NSEC")))
        (if (= (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)
               sb-posix:s-ifdir)
            (list :present
                  (sb-posix:stat-dev stat)
                  (sb-posix:stat-ino stat)
                  (sb-posix:stat-mtime stat)
                  mtime-nsec
                  ;; Emacs receives a high-resolution file attribute.  Stock
                  ;; SB-POSIX exposes only whole seconds, so hash names there
                  ;; to avoid missing a create/delete in the baseline second.
                  (unless mtime-nsec
                    (directory-entry-name-signature directory)))
            (list :missing)))
    (sb-posix:syscall-error () (list :unreadable))
    (error () (list :unreadable))))

(defun directory-buffer-path-keys (buffer &key marked-only)
  (with-point ((row (buffer-start-point buffer)))
    (loop
      :for pathname = (lem/directory-mode/internal:get-pathname row)
      :when (and pathname
                 (or (not marked-only)
                     (lem/directory-mode/internal:get-mark row)))
        :collect (uiop:native-namestring pathname)
      :while (line-offset row 1))))

(defun restore-directory-marks (buffer marked-paths)
  (let ((marked (make-hash-table :test #'equal)))
    (dolist (path marked-paths)
      (setf (gethash path marked) t))
    (with-point ((row (buffer-start-point buffer)))
      (loop
        (alexandria:when-let
            ((pathname (lem/directory-mode/internal:get-pathname row)))
          (when (gethash (uiop:native-namestring pathname) marked)
            (lem/directory-mode/internal:set-mark row t)))
        (unless (line-offset row 1)
          (return))))))

(defun directory-auto-revert-stale-p (buffer)
  (let ((baseline
          (buffer-value buffer 'lem-yath-directory-state-signature))
        (current (directory-state-signature buffer)))
    (and (eq (first baseline) :present)
         (eq (first current) :present)
         (not (equal baseline current)))))

(defun directory-auto-revert (buffer)
  "Refresh BUFFER while retaining Dired's selected entry, column, and marks."
  (let* ((point (buffer-point buffer))
         (selected
           (alexandria:when-let
               ((pathname
                  (lem/directory-mode/internal:get-pathname point)))
             (uiop:native-namestring pathname)))
         (column (point-column point))
         (marked (directory-buffer-path-keys buffer :marked-only t))
         (sort-method
           (or (buffer-value buffer :sort-method)
               lem/directory-mode/internal:*default-sort-method*)))
    (lem/directory-mode/internal:update-buffer
     buffer :sort-method sort-method)
    (restore-directory-marks buffer marked)
    (when (and selected (restore-directory-place buffer selected))
      (move-to-column (buffer-point buffer) column))
    (buffer-unmark buffer)
    (setf (buffer-value buffer 'lem-yath-directory-state-signature)
          (directory-state-signature buffer))))

(defun initialize-directory-auto-revert-adapter (buffer)
  "Install the local-directory adapter without replacing another adapter."
  (when (and (mode-active-p buffer 'lem/directory-mode/mode:directory-mode)
             (null (buffer-value
                    buffer 'lem-yath-auto-revert-stale-function))
             (null (buffer-value
                    buffer 'lem-yath-auto-revert-function)))
    ;; Refresh once on installation so an existing buffer and its baseline
    ;; cannot disagree after a configuration reload.
    (setf (buffer-value buffer 'lem-yath-auto-revert-stale-function)
          'directory-auto-revert-stale-p
          (buffer-value buffer 'lem-yath-auto-revert-function)
          'directory-auto-revert
          (buffer-value buffer 'lem-yath-auto-revert-ignore-modified-p) t)
    (directory-auto-revert buffer)))

(defun bounded-stream-content-digest (stream byte-limit)
  "Hash no more than BYTE-LIMIT bytes and report whether EOF was stable."
  (let ((hash #xcbf29ce484222325)
        (total 0)
        (buffer (make-array 65536 :element-type '(unsigned-byte 8))))
    (loop
      (let* ((remaining (- byte-limit total))
             (count
               (if (plusp remaining)
                   (read-sequence buffer stream
                                  :end (min (length buffer) remaining))
                   0)))
        (dotimes (index count)
          (setf hash
                (logand #xffffffffffffffff
                        (* (logxor hash (aref buffer index))
                           #x100000001b3))))
        (incf total count)
        (cond
          ((< count (min (length buffer) remaining))
           (return (values hash t)))
          ((= total byte-limit)
           (return (values hash
                           (eq (read-byte stream nil :eof) :eof)))))))))

(defun file-state-signature (pathname &key digest full-digest)
  "Read one stable descriptor and return metadata plus an optional bounded hash."
  (unless (uiop:file-exists-p pathname)
    (return-from file-state-signature (list :missing)))
  (handler-case
      #+sbcl
      (with-open-file (stream pathname :element-type '(unsigned-byte 8))
        (let* ((descriptor (sb-sys::fd-stream-fd stream))
               (before (stat-file-metadata (sb-posix:fstat descriptor)))
               (size (third before))
               (hash nil)
               (complete t))
          (when (and digest
                     (or full-digest
                         (<= size *safe-auto-revert-digest-limit*)))
            (multiple-value-setq (hash complete)
              (bounded-stream-content-digest stream size)))
          (let ((after (stat-file-metadata (sb-posix:fstat descriptor)))
                (path-after
                  (stat-file-metadata
                   (sb-posix:stat (uiop:native-namestring pathname)))))
            (if (and complete (equal before after) (equal after path-after))
                (append (list :present) after (list hash))
                (list :unstable)))))
      #-sbcl
      (error "Safe external-change handling requires SBCL")
    (error () (list :unreadable))))

(defun file-signatures-equal-p (left right)
  (cond
    ((and (eq (first left) :present) (eq (first right) :present))
     (and (equal (subseq left 0 6) (subseq right 0 6))
          (or (null (seventh left))
              (null (seventh right))
              (eql (seventh left) (seventh right)))))
    (t (equal left right))))

(defun buffer-file-path-key (buffer)
  (alexandria:when-let ((filename (buffer-filename buffer)))
    (handler-case
        (uiop:native-namestring
         (uiop:ensure-pathname filename :want-absolute t))
      (error () nil))))

(defun buffer-fingerprint-temporary-pathname ()
  (merge-pathnames
   (format nil "lem-yath-buffer.~d.~16,'0x"
           #+sbcl (sb-posix:getpid)
           #-sbcl 0
           (random (ash 1 60)))
   (uiop:temporary-directory)))

(defun buffer-output-fingerprint (buffer)
  "Stream BUFFER through Lem's exact writer and return its byte size and hash."
  #+sbcl
  (let* ((encoding (buffer-encoding buffer))
         (internal-p
           (or (null encoding)
               (typep encoding 'lem/buffer/encodings:internal-encoding)))
         (check (lem/buffer/encodings:encoding-check encoding))
         (temporary (buffer-fingerprint-temporary-pathname))
         (descriptor nil)
         (output-descriptor nil)
         (output-stream nil)
         (input-stream nil))
    ;; A secure, immediately unlinked file keeps exact encoded output bounded
    ;; by available disk space instead of duplicating a large buffer in RAM.
    (when check
      (map-region (buffer-start-point buffer) (buffer-end-point buffer) check))
    (unwind-protect
         (progn
           (setf descriptor
                 (sb-posix:open
                  (uiop:native-namestring temporary)
                  (logior sb-posix:o-creat sb-posix:o-excl
                          sb-posix:o-rdwr sb-posix:o-nofollow)
                  #o600))
           (sb-posix:fchmod descriptor #o600)
           (sb-posix:unlink (uiop:native-namestring temporary))
           (setf temporary nil
                 output-descriptor (sb-posix:dup descriptor)
                 output-stream
                 (sb-sys:make-fd-stream
                  output-descriptor
                  :output t
                  :element-type (if internal-p 'character '(unsigned-byte 8))
                  :external-format
                  (if (and internal-p encoding)
                      (lem/buffer/encodings:encoding-external-format encoding)
                      :utf-8)
                  :buffering :full
                  :name "unlinked Lem buffer fingerprint"))
           (map-region
            (buffer-start-point buffer)
            (buffer-end-point buffer)
            (if internal-p
                (lem/buffer/file::%write-region-to-file
                 (if encoding
                     (lem/buffer/encodings:encoding-end-of-line encoding)
                     :lf)
                 output-stream)
                (lem/buffer/file::%%write-region-to-file
                 encoding output-stream)))
           (finish-output output-stream)
           (close output-stream)
           (setf output-stream nil
                 output-descriptor nil)
           (sb-posix:lseek descriptor 0 sb-posix:seek-set)
           (let ((size (sb-posix:stat-size (sb-posix:fstat descriptor))))
             (setf input-stream
                   (sb-sys:make-fd-stream
                    descriptor
                    :input t
                    :element-type '(unsigned-byte 8)
                    :buffering :full
                    :name "unlinked Lem buffer fingerprint"))
             (multiple-value-bind (digest complete)
                 (bounded-stream-content-digest input-stream size)
               (unless complete
                 (error "Encoded buffer fingerprint changed while being read"))
               (close input-stream)
               (setf input-stream nil
                     descriptor nil)
               (values size digest))))
      (when output-stream
        (handler-case
            (progn
              (close output-stream :abort t)
              (setf output-descriptor nil))
          (error () nil)))
      (when input-stream
        (handler-case
            (progn
              (close input-stream :abort t)
              (setf descriptor nil))
          (error () nil)))
      (when output-descriptor
        (ignore-errors (sb-posix:close output-descriptor)))
      (when descriptor
        (ignore-errors (sb-posix:close descriptor)))
      (when temporary
        (ignore-errors (sb-posix:unlink
                        (uiop:native-namestring temporary))))))
  #-sbcl
  (error "Safe persistence requires the supported SBCL runtime"))

(defun stable-buffer-file-signature (buffer pathname)
  "Return BUFFER's stable on-disk identity.
Ordinary buffers must encode to the file's bytes.  Active SOPS buffers instead
track stable ciphertext because their deliberately decrypted text cannot match
the visited file byte-for-byte."
  (handler-case
      (let ((before (file-state-signature pathname :digest t :full-digest t)))
        (case (first before)
          (:missing
           (return-from stable-buffer-file-signature
             (if (and (null (buffer-last-write-date buffer))
                      (null (buffer-value
                             buffer 'lem-yath-file-state-path)))
                 (list :missing)
                 (list :unknown))))
          (:present)
          (otherwise
           (return-from stable-buffer-file-signature (list :unknown))))
        (when (sops-buffer-active-p buffer)
          (return-from stable-buffer-file-signature before))
        (multiple-value-bind (size digest)
            (buffer-output-fingerprint buffer)
          (let ((after
                  (file-state-signature pathname :digest t :full-digest t)))
            (if (and (file-signatures-equal-p before after)
                     (= size (fourth after))
                     (eql digest (seventh after)))
                after
                (list :unknown)))))
    (error () (list :unknown))))

(defun set-buffer-file-state (buffer path signature)
  (setf (buffer-value buffer 'lem-yath-file-state-path) path
        (buffer-value buffer 'lem-yath-file-state-buffer-name)
        (buffer-name buffer)
        (buffer-value buffer 'lem-yath-file-state-directory)
        (buffer-directory buffer)
        (buffer-value buffer 'lem-yath-file-state-signature) signature
        (buffer-value buffer 'lem-yath-file-state-conflict) nil)
  signature)

(defun initialize-buffer-file-state (buffer &key force)
  (unless (buffer-value buffer 'lem-yath-file-state-buffer-name)
    (setf (buffer-value buffer 'lem-yath-file-state-buffer-name)
          (buffer-name buffer)
          (buffer-value buffer 'lem-yath-file-state-directory)
          (buffer-directory buffer)))
  (alexandria:when-let ((path (buffer-file-path-key buffer)))
    (when (or force
              (not (string= path
                            (or (buffer-value
                                 buffer 'lem-yath-file-state-path)
                                ""))))
      (set-buffer-file-state
       buffer path (stable-buffer-file-signature buffer path)))))

(defun report-buffer-file-conflict (buffer signature control)
  (unless (equal signature
                 (buffer-value buffer 'lem-yath-file-state-conflict))
    (setf (buffer-value buffer 'lem-yath-file-state-conflict) signature)
    (message control (buffer-name buffer))))

(defun safe-auto-revert-check-non-file-buffer (buffer)
  (let ((stale (buffer-value buffer 'lem-yath-auto-revert-stale-function))
        (revert (buffer-value buffer 'lem-yath-auto-revert-function)))
    (when (and stale revert
               (or (not (buffer-modified-p buffer))
                   (buffer-value
                    buffer 'lem-yath-auto-revert-ignore-modified-p))
               (funcall stale buffer))
      (with-current-buffer buffer
        (funcall revert buffer))
      :reverted)))

(defun safe-auto-revert-check-buffer (buffer &key force-digest notification)
  "Refresh one clean stale BUFFER, never replacing dirty or missing content."
  (when (or (deleted-buffer-p buffer) (buffer-temporary-p buffer))
    (return-from safe-auto-revert-check-buffer :skipped))
  (initialize-directory-auto-revert-adapter buffer)
  (initialize-buffer-file-state buffer)
  (unless (buffer-filename buffer)
    (return-from safe-auto-revert-check-buffer
      (or (safe-auto-revert-check-non-file-buffer buffer) :skipped)))
  (let* ((path (buffer-file-path-key buffer))
         (tracked-path (buffer-value buffer 'lem-yath-file-state-path))
         (baseline (buffer-value buffer 'lem-yath-file-state-signature)))
    (unless (and path tracked-path (string= path tracked-path))
      (return-from safe-auto-revert-check-buffer :path-changed))
    (let ((current
            (file-state-signature
             path
             :digest (or force-digest notification
                         (eq buffer (current-buffer)))
             ;; An inotify event is stronger evidence than a periodic stat.
             ;; Hash the complete file so a same-metadata rewrite above the
             ;; ordinary background digest cap cannot be missed.
             :full-digest notification)))
      (when (file-signatures-equal-p baseline current)
        (return-from safe-auto-revert-check-buffer :unchanged))
      (case (first current)
        (:present
         (if (buffer-modified-p buffer)
             (progn
               (report-buffer-file-conflict
                buffer current
                "~a changed on disk; keeping unsaved buffer edits")
               :conflict)
             (handler-case
                 (progn
                   (with-current-buffer buffer
                     (alexandria:if-let
                         (revert
                           (lem-core/commands/file:revert-buffer-function
                            buffer))
                       (funcall revert buffer)
                       (lem-core/commands/file:sync-buffer-with-file-content
                        buffer)))
                   (let ((signature
                           (stable-buffer-file-signature buffer path)))
                     (if (eq (first signature) :present)
                         (progn
                           (set-buffer-file-state buffer path signature)
                           (message "Reverted ~a after an external change"
                                    (buffer-name buffer))
                           :reverted)
                         (progn
                           (setf (buffer-value
                                  buffer 'lem-yath-file-state-signature)
                                 (list :unknown))
                           (report-buffer-file-conflict
                            buffer signature
                            "Could not verify reloaded ~a; will retry safely")
                           :failed))))
               (error (condition)
                 (declare (ignore condition))
                 (report-buffer-file-conflict
                  buffer current
                  "Could not safely reload ~a; keeping its buffer")
                 :failed))))
        (:missing
         (report-buffer-file-conflict
          buffer current "~a was deleted on disk; keeping its buffer")
         :missing)
        (:unreadable
         (report-buffer-file-conflict
          buffer current "~a is unreadable on disk; keeping its buffer")
         :unreadable)
        (:unstable
         (report-buffer-file-conflict
          buffer current "~a is changing on disk; keeping its buffer")
         :unstable)))))

(defun auto-revert-check-due-p ()
  (or (null *last-auto-revert-check-time*)
      (>= (- (get-internal-real-time) *last-auto-revert-check-time*)
          (* *safe-auto-revert-interval* internal-time-units-per-second))))

(defun safe-auto-revert-file-paths ()
  (loop :for buffer :in (buffer-list)
        :for path := (and (not (deleted-buffer-p buffer))
                          (not (buffer-temporary-p buffer))
                          (buffer-file-path-key buffer))
        :when path :collect path))

(defun safe-auto-revert-reconcile-watches ()
  (file-notify-reconcile (safe-auto-revert-file-paths)))

(defun safe-auto-revert-notification (path)
  "Check every live buffer visiting PATH after a filesystem notification."
  (dolist (buffer (buffer-list))
    (when (and (not (deleted-buffer-p buffer))
               (not (buffer-temporary-p buffer))
               (alexandria:when-let
                   ((buffer-path (buffer-file-path-key buffer)))
                 (string= buffer-path path)))
      (handler-case
          (safe-auto-revert-check-buffer
           buffer :force-digest t :notification t)
        (error (condition)
          (ignore-errors
            (message "External-change check failed for ~a: ~a"
                     (buffer-name buffer) condition)))))))

(defun safe-auto-revert-check-all (&key force)
  "Run the configured global safety scan, bypassing its throttle with FORCE."
  (when (or force (auto-revert-check-due-p))
    (setf *last-auto-revert-check-time* (get-internal-real-time))
    (safe-auto-revert-reconcile-watches)
    (loop :for buffer :in (buffer-list)
          :collect
          (handler-case
              (safe-auto-revert-check-buffer
               buffer :force-digest (or force (eq buffer (current-buffer))))
            (error (condition)
              (ignore-errors
                (message "External-change check failed for ~a: ~a"
                         (buffer-name buffer) condition))
              :failed)))))

(defun stop-safe-auto-revert-timer ()
  "Stop the periodic external-change timer owned by this configuration."
  (alexandria:when-let ((timer *safe-auto-revert-timer*))
    ;; Clear ownership first so an already queued callback becomes a no-op.
    (setf *safe-auto-revert-timer* nil)
    (ignore-errors (stop-timer timer)))
  nil)

(defun start-safe-auto-revert-timer ()
  "Run Emacs' five-second safety scan alongside prompt notifications."
  (stop-safe-auto-revert-timer)
  (let (timer)
    (setf timer
          (make-timer
           (lambda ()
             (when (eq timer *safe-auto-revert-timer*)
               (handler-case
                   (safe-auto-revert-check-all)
                 (error (condition)
                   (ignore-errors
                     (message "Periodic external-change check failed: ~a"
                              condition))))))
           :name "lem-yath safe auto revert"))
    (setf *safe-auto-revert-timer*
          (start-timer timer
                       (* 1000 *safe-auto-revert-interval*)
                       :repeat t))))

(defun restore-buffer-tracked-identity (buffer)
  (let ((tracked-path (buffer-value buffer 'lem-yath-file-state-path))
        (tracked-name (buffer-value buffer 'lem-yath-file-state-buffer-name))
        (tracked-directory
          (buffer-value buffer 'lem-yath-file-state-directory)))
    (if tracked-path
        (setf (buffer-filename buffer) tracked-path)
        (progn
          (setf (lem/buffer/internal::buffer-%filename buffer) nil)
          (when tracked-directory
            (setf (buffer-directory buffer) tracked-directory))))
    (when (and tracked-name
               (not (string= tracked-name (buffer-name buffer))))
      (buffer-rename buffer tracked-name))))

(defun confirm-stale-save (buffer control)
  (unless (prompt-for-y-or-n-p (format nil control (buffer-name buffer)))
    (editor-error "Save cancelled; disk and buffer versions differ")))

(defun safe-stale-save-guard (buffer)
  "Require confirmation before overwriting a changed or newly targeted file."
  (alexandria:when-let ((path (buffer-file-path-key buffer)))
    (let* ((tracked-path
             (buffer-value buffer 'lem-yath-file-state-path))
           (path-changed-p
             (or (null tracked-path) (not (string= path tracked-path))))
           (current
             (file-state-signature path :digest t :full-digest t)))
      (if path-changed-p
          (handler-case
              (when (and (not (eq (first current) :missing))
                         (not (buffer-value
                               buffer
                               'lem-core/commands/file::write-file-overwrite-confirmed)))
                (confirm-stale-save
                 buffer
                 "~a targets an existing or unverifiable file; overwrite it"))
            (editor-error (condition)
              (restore-buffer-tracked-identity buffer)
              (error condition)))
          (let ((baseline
                  (buffer-value buffer 'lem-yath-file-state-signature)))
            (unless (file-signatures-equal-p baseline current)
              (confirm-stale-save
               buffer
               "~a changed on disk; overwrite it with this buffer")))))))

(defun persistence-after-save-hook (buffer)
  (let* ((path (buffer-file-path-key buffer))
         (signature
           (and path (stable-buffer-file-signature buffer path))))
    (if (and signature (eq (first signature) :present))
        (progn
          (set-buffer-file-state buffer path signature)
          (record-buffer-place buffer))
        (let ((disk-signature
                (and path
                     (file-state-signature
                      path :digest t :full-digest t))))
          (if (and (buffer-modified-p buffer)
                   disk-signature
                   (eq (first disk-signature) :present))
              ;; An after-save hook may legitimately create a new dirty
              ;; descendant after the exact saved node.  Track the stable
              ;; bytes on disk without pretending the live descendant was
              ;; saved or flagging it as an external race.
              (progn
                (set-buffer-file-state buffer path disk-signature)
                (record-buffer-place buffer))
              (progn
                (setf (buffer-value buffer 'lem-yath-file-state-signature)
                      (list :unknown))
                (report-buffer-file-conflict
                 buffer (list :post-save-mismatch)
                 "~a changed while being saved; keeping the buffer modified")
                (editor-error
                 "Saved file no longer matches the live buffer"))))))
    ;; WRITE-FILE can change the visited pathname.  Reconcile the complete set
    ;; so the old parent watch is released when no other buffer needs it.
    (safe-auto-revert-reconcile-watches))

(defun persistence-after-sync-hook (buffer)
  "Refresh tracking after any core/LSP caller synchronizes from disk."
  (alexandria:when-let ((path (buffer-file-path-key buffer)))
    (set-buffer-file-state
     buffer path (stable-buffer-file-signature buffer path))))

(defun persistence-find-file-hook (buffer)
  (initialize-buffer-file-state buffer :force t)
  (safe-auto-revert-reconcile-watches)
  (restore-buffer-place buffer)
  (setf (buffer-value buffer 'lem-yath-place-restored-p) t))

(defun persistence-kill-buffer-hook (buffer)
  (record-buffer-place buffer)
  (alexandria:when-let* ((service *file-notify-service*)
                         (path (buffer-file-path-key buffer)))
    (unless (some
             (lambda (other)
               (and (not (eq other buffer))
                    (not (deleted-buffer-p other))
                    (alexandria:when-let
                        ((other-path (buffer-file-path-key other)))
                      (string= path other-path))))
             (buffer-list))
      (ignore-errors (file-notify-remove-path service path)))))

(defun persistence-switch-buffer-hook (target)
  (record-buffer-place (current-buffer))
  (unless (buffer-value target 'lem-yath-place-restored-p)
    (when (mode-active-p target 'lem/directory-mode/mode:directory-mode)
      (restore-buffer-place target))
    (setf (buffer-value target 'lem-yath-place-restored-p) t))
  (safe-auto-revert-check-buffer target :force-digest t))

(defun persistence-exit-hook ()
  (stop-safe-auto-revert-timer)
  (stop-file-notify-service)
  (call-persistence-safely #'flush-persistence-state "exit save"))

(defun persistence-post-command-hook ()
  (maybe-flush-persistence-state))

;;; --- activation -----------------------------------------------------------

;; The configured Emacs disables all automatic/backup writes.  Lem's optional
;; auto-save mode writes directly to the visited file, so force it off.
(setf lem/auto-save:*make-backup-files* nil)
(ignore-errors (lem/auto-save:auto-save-mode nil))

;; Match Emacs' live minibuffer-history cap independently of the smaller,
;; default-deny set of histories eligible for persistence.
(setf lem/prompt-window::*prompt-history-limit* *prompt-history-limit*)
(cap-all-live-prompt-histories)

;; Replace core's unsafe current-buffer mtime hook with a global, digest-aware
;; checker.  Remove/re-add every hook so hot reload remains exactly idempotent.
(remove-hook *pre-command-hook* 'lem-core/commands/file::ask-revert-buffer)
(remove-hook *pre-command-hook* 'safe-auto-revert-check-all)
(add-hook *pre-command-hook* 'safe-auto-revert-check-all 5000)
(start-file-notify-service #'safe-auto-revert-notification)
(safe-auto-revert-reconcile-watches)
(start-safe-auto-revert-timer)

(remove-hook (variable-value 'before-save-hook :global t)
             'safe-stale-save-guard)
(add-hook (variable-value 'before-save-hook :global t)
          'safe-stale-save-guard 10000)

(remove-hook (variable-value 'after-save-hook :global t)
             'persistence-after-save-hook)
(add-hook (variable-value 'after-save-hook :global t)
          'persistence-after-save-hook -10000)

(remove-hook *find-file-hook* 'persistence-find-file-hook)
(add-hook *find-file-hook* 'persistence-find-file-hook 10000)

(remove-hook lem-core/commands/file:*after-sync-buffer-hook*
             'persistence-after-sync-hook)
(add-hook lem-core/commands/file:*after-sync-buffer-hook*
          'persistence-after-sync-hook)

(remove-hook (variable-value 'kill-buffer-hook :global t)
             'persistence-kill-buffer-hook)
(add-hook (variable-value 'kill-buffer-hook :global t)
          'persistence-kill-buffer-hook)

(remove-hook *switch-to-buffer-hook* 'persistence-switch-buffer-hook)
(add-hook *switch-to-buffer-hook* 'persistence-switch-buffer-hook)

(remove-hook *exit-editor-hook* 'persistence-exit-hook)
(add-hook *exit-editor-hook* 'persistence-exit-hook)

(remove-hook *post-command-hook* 'persistence-post-command-hook)
(add-hook *post-command-hook* 'persistence-post-command-hook)

(remove-hook lem/isearch:*isearch-finish-hooks* 'record-isearch-history)
(add-hook lem/isearch:*isearch-finish-hooks* 'record-isearch-history)

(define-key *global-keymap* "C-s" 'lem-yath-isearch-forward)
(define-key *global-keymap* "C-r" 'lem-yath-isearch-backward)
(define-key *global-keymap* "C-M-s" 'lem-yath-isearch-forward-regexp)
(define-key *global-keymap* "C-M-r" 'lem-yath-isearch-backward-regexp)
(define-key lem/isearch:*isearch-keymap*
  "M-p" 'lem-yath-isearch-previous-history)
(define-key lem/isearch:*isearch-keymap*
  "M-n" 'lem-yath-isearch-next-history)

(let ((first-load (not *persistence-loaded-p*)))
  (when first-load
    (unless (call-persistence-safely #'load-persistence-state "startup load")
      ;; A private-state failure must not make every config reload repeat the
      ;; same startup error.  Periodic and exit saves retain bounded retries.
      (setf *persistence-loaded-p* t
            *last-persistence-save-time* (get-internal-real-time))))
  (dolist (buffer (buffer-list))
    (initialize-buffer-file-state buffer)
    (when first-load
      (restore-buffer-place buffer))))

;; A source reload into a process started before baseline tracking already has
;; the last loaded state live.  Capture it once instead of treating every live
;; entry as a new addition on the first subsequent flush.
(unless *persistence-state-baseline*
  (setf *persistence-state-baseline* (collect-persistence-state)))
