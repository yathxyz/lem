;;;; Automatic, merge-safe persistence for Lem's built-in bookmarks.

(in-package :lem-yath)

(declaim (ftype function proper-list-p bounded-persistence-string-p
                readable-string-copy))
(defvar *persistence-path-size-limit*)

(defparameter *bookmark-persistence-limit* 1000)
(defparameter *bookmark-name-size-limit* 1024)

(defvar *bookmark-persistence-baseline* '()
  "Normalized bookmark state last read from or written to shared storage.")

(defun bookmark-filename-string (filename)
  (typecase filename
    (string filename)
    (pathname (uiop:native-namestring filename))
    (t nil)))

(defun valid-bookmark-state-entry-p (entry)
  (and (proper-list-p entry)
       (= 3 (length entry))
       (bounded-persistence-string-p
        (first entry) *bookmark-name-size-limit*)
       (plusp (length (first entry)))
       (bounded-persistence-string-p
        (second entry) *persistence-path-size-limit*)
       (plusp (length (second entry)))
       (or (null (third entry))
           (and (integerp (third entry))
                (<= 1 (third entry) most-positive-fixnum)))))

(defun normalize-bookmark-state (entries)
  "Return a bounded, deterministic set of bookmark triples.

For duplicate names, the first valid entry wins."
  (let ((table (make-hash-table :test #'equal)))
    (when (proper-list-p entries)
      (loop :for entry :in entries
            :repeat (* 2 *bookmark-persistence-limit*)
            :when (valid-bookmark-state-entry-p entry)
              :do (unless (gethash (first entry) table)
                    (setf (gethash (first entry) table)
                          (list (readable-string-copy (first entry))
                                (readable-string-copy (second entry))
                                (third entry))))))
    (sort (loop :for entry :being :the :hash-value :in table
                :collect entry)
          #'string< :key #'first)))

(defun bookmark-persistence-snapshot ()
  (normalize-bookmark-state
   (loop :for entry :being :the :hash-value
           :in lem-bookmark::*bookmark-table*
         :for filename :=
           (bookmark-filename-string
            (lem-bookmark:bookmark-filename entry))
         :when filename
           :collect (list (lem-bookmark:bookmark-name entry)
                          filename
                          (lem-bookmark:bookmark-position entry)))))

(defun apply-bookmark-persistence-state (state)
  (let ((state (normalize-bookmark-state state)))
    (clrhash lem-bookmark::*bookmark-table*)
    (dolist (entry state)
      (setf (gethash (first entry) lem-bookmark::*bookmark-table*)
            (lem-bookmark::make-bookmark
             :name (first entry)
             :filename (second entry)
             :position (third entry))))
    state))

(defun bookmark-state-table (state)
  (let ((table (make-hash-table :test #'equal)))
    (dolist (entry (normalize-bookmark-state state) table)
      (setf (gethash (first entry) table) entry))))

(defun merge-bookmark-persistence-state (live disk)
  "Apply local changes since the baseline over the latest disk state.

Unchanged local names follow disk, so another process may update or delete
them.  Local additions, updates, and deletions win same-name conflicts."
  (let* ((baseline-table
           (bookmark-state-table *bookmark-persistence-baseline*))
         (live-table (bookmark-state-table live))
         (result-table (bookmark-state-table disk)))
    (maphash
     (lambda (name baseline-entry)
       (multiple-value-bind (live-entry live-p) (gethash name live-table)
         (cond
           ((not live-p)
            (remhash name result-table))
           ((not (equal live-entry baseline-entry))
            (setf (gethash name result-table) live-entry)))))
     baseline-table)
    (maphash
     (lambda (name live-entry)
       (unless (gethash name baseline-table)
         (setf (gethash name result-table) live-entry)))
     live-table)
    (normalize-bookmark-state
     (loop :for entry :being :the :hash-value :in result-table
           :collect entry))))

(defun load-bookmark-persistence-state (state)
  (let ((state (apply-bookmark-persistence-state state)))
    (setf *bookmark-persistence-baseline* (copy-tree state))
    state))
