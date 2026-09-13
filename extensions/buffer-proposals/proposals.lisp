(defpackage :lem-buffer-proposals
  (:use :cl :lem)
  (:export :capture-region :stage-replacement :apply-proposal :reject-proposal
           :find-proposal :list-proposals :forget-proposal :proposal
           :proposal-id :proposal-state :proposal-revision :proposal-generation
           :proposal-original :proposal-replacement :proposal-current-text
           :proposal-source-buffer :proposal-source-location :proposal-valid-p
           :proposal-error :proposal-error-reason :proposal-conflict
           :proposal-error-proposal :proposal-review-buffer :show-proposal
           :visit-proposal-source :proposal-finished))
(in-package :lem-buffer-proposals)

(defparameter *maximum-proposals* 64)
(defparameter *maximum-text-characters* (* 1024 1024))
(defparameter *maximum-retained-characters* (* 16 1024 1024))
(defvar *proposals* (make-hash-table :test #'equal))
(defvar *proposal-sequence* 0)
(defvar *proposal-epoch* nil)
(defvar *buffer-proposals-key* 'buffer-proposals)

(define-condition proposal-error (error)
  ((proposal :initarg :proposal :reader proposal-error-proposal)
   (reason :initarg :reason :reader proposal-error-reason))
  (:report (lambda (condition stream)
             (format stream "Buffer proposal ~a: ~a"
                     (let ((proposal (proposal-error-proposal condition)))
                       (if proposal (proposal-id proposal) "unavailable"))
                     (proposal-error-reason condition)))))

(define-condition proposal-conflict (proposal-error) ())

(defstruct (proposal (:constructor %make-proposal) (:conc-name %proposal-))
  id sequence source start end filename buffer-name line column
  revision observed-tick before-tick original replacement
  (generation 0) (state :captured) conflict review-buffer)

(defgeneric proposal-finished (proposal)
  (:documentation "Notify editor integrations after acceptance or rejection commits.
Methods must not edit the source or signal errors.")
  (:method (proposal) (declare (ignore proposal))))

(defun require-editor-thread ()
  (let ((editor (find-editor-thread)))
    (when (and editor (not (eq editor (bt2:current-thread))))
      (error "Buffer proposal operations must run on the editor thread"))))

(defun proposal-id (proposal) (copy-seq (%proposal-id proposal)))
(defun proposal-revision (proposal) (%proposal-revision proposal))
(defun proposal-generation (proposal) (%proposal-generation proposal))
(defun proposal-original (proposal) (copy-seq (%proposal-original proposal)))
(defun proposal-replacement (proposal)
  (when (%proposal-replacement proposal) (copy-seq (%proposal-replacement proposal))))
(defun proposal-source-buffer (proposal) (%proposal-source proposal))

(defun source-live-p (proposal)
  (let ((source (%proposal-source proposal)))
    (and source (not (deleted-buffer-p source))
         (%proposal-start proposal) (%proposal-end proposal)
         (alive-point-p (%proposal-start proposal))
         (alive-point-p (%proposal-end proposal)))))

(defun terminal-proposal-p (proposal)
  (member (%proposal-state proposal) '(:applied :rejected :forgotten)))

(defun mark-conflict (proposal reason)
  (unless (or (terminal-proposal-p proposal) (eq :applying (%proposal-state proposal)))
    (setf (%proposal-state proposal) :conflict
          (%proposal-conflict proposal) (or (%proposal-conflict proposal) reason))))

(defun proposal-current-text (proposal)
  (require-editor-thread)
  (when (source-live-p proposal)
    (let ((start (%proposal-start proposal)) (end (%proposal-end proposal)))
      (when (and (point<= start end)
                 (<= (- (position-at-point end) (position-at-point start))
                     *maximum-text-characters*))
        (points-to-string start end)))))

(defun proposal-source-location (proposal)
  "Return a copied location record; tracked coordinates refer to unsaved text."
  (require-editor-thread)
  (let ((live (source-live-p proposal)))
    (list :id (proposal-id proposal)
          :buffer-name (copy-seq (%proposal-buffer-name proposal))
          :filename (when (%proposal-filename proposal)
                      (copy-seq (%proposal-filename proposal)))
          :line (if live (line-number-at-point (%proposal-start proposal))
                    (%proposal-line proposal))
          :column (if live (point-charpos (%proposal-start proposal))
                      (%proposal-column proposal))
          :revision (%proposal-revision proposal)
          :current-revision (when live (buffer-modified-tick (%proposal-source proposal)))
          :live-p (and live t))))

(defun proposal-valid-p (proposal)
  "Validate the captured region and its observed revision chain without editing."
  (require-editor-thread)
  (cond
    ((terminal-proposal-p proposal) (values nil :already-finished))
    ((not (source-live-p proposal)) (mark-conflict proposal :source-deleted))
    ((not (equal (%proposal-filename proposal) (buffer-filename (%proposal-source proposal))))
     (mark-conflict proposal :source-file-changed))
    ((/= (%proposal-observed-tick proposal)
         (buffer-modified-tick (%proposal-source proposal)))
     (mark-conflict proposal :unobserved-source-change))
    ((not (equal (%proposal-original proposal) (proposal-current-text proposal)))
     (mark-conflict proposal :source-content-changed)))
  (cond
    ((terminal-proposal-p proposal) (values nil :already-finished))
    ((%proposal-conflict proposal) (values nil (%proposal-conflict proposal)))
    (t (values t nil))))

(defun proposal-state (proposal)
  (proposal-valid-p proposal)
  (%proposal-state proposal))

(defun find-proposal (id)
  (require-editor-thread)
  (gethash id *proposals*))

(defun list-proposals ()
  (require-editor-thread)
  (sort (loop :for proposal :being :the :hash-values :of *proposals* :collect proposal)
        #'< :key #'%proposal-sequence))

(defun release-markers (proposal)
  (when (source-live-p proposal)
    (setf (%proposal-line proposal) (line-number-at-point (%proposal-start proposal))
          (%proposal-column proposal) (point-charpos (%proposal-start proposal))))
  (let ((source (%proposal-source proposal)))
    (when (and source (not (deleted-buffer-p source)))
      (setf (buffer-value source *buffer-proposals-key*)
            (delete proposal (buffer-value source *buffer-proposals-key*) :test #'eq)))
    (dolist (point (list (%proposal-start proposal) (%proposal-end proposal)))
      (when (and point (alive-point-p point)) (delete-point point))))
  (setf (%proposal-start proposal) nil (%proposal-end proposal) nil))

(defun forget-proposal (proposal)
  "Remove a finished proposal from bounded history; pending work is never evicted."
  (require-editor-thread)
  (unless (terminal-proposal-p proposal)
    (error 'proposal-error :proposal proposal :reason :still-pending))
  (release-markers proposal)
  (let ((buffer (%proposal-review-buffer proposal)))
    (when (and buffer (not (deleted-buffer-p buffer))) (delete-buffer buffer)))
  (remhash (%proposal-id proposal) *proposals*)
  (setf (%proposal-state proposal) :forgotten
        (%proposal-source proposal) nil
        (%proposal-original proposal) ""
        (%proposal-replacement proposal) nil
        (%proposal-review-buffer proposal) nil)
  nil)

(defun retained-characters ()
  (loop :for proposal :being :the :hash-values :of *proposals*
        :sum (+ (length (%proposal-original proposal))
                (length (%proposal-replacement proposal)))))

(defun reserve-capacity (characters &optional (new-records 0))
  (loop :while (or (> (+ (hash-table-count *proposals*) new-records) *maximum-proposals*)
                  (> (+ (retained-characters) characters) *maximum-retained-characters*))
        :for oldest := (find-if #'terminal-proposal-p (list-proposals))
        :do (if oldest (forget-proposal oldest)
                (error 'proposal-error :proposal nil :reason :proposal-capacity-exceeded))))

(defun capture-region (start end)
  "Capture live unsaved source on the editor thread before requesting a proposal."
  (require-editor-thread)
  (unless (and (alive-point-p start) (alive-point-p end)
               (eq (point-buffer start) (point-buffer end)) (point<= start end))
    (error 'proposal-error :proposal nil :reason :invalid-region))
  (let* ((source (point-buffer start))
         (length (- (position-at-point end) (position-at-point start))))
    (when (or (deleted-buffer-p source) (> length *maximum-text-characters*))
      (error 'proposal-error :proposal nil :reason :source-unavailable-or-too-large))
    (reserve-capacity length 1)
    (let* ((sequence (incf *proposal-sequence*))
           (proposal
             (%make-proposal
              ;; Initialize at runtime, not while building a reusable Lisp image.
              :id (format nil "proposal-~a-~36r"
                          (or *proposal-epoch*
                              (setf *proposal-epoch*
                                    (format nil "~36r-~36r" (get-universal-time)
                                            (random (ash 1 128) (make-random-state t)))))
                          sequence)
              :sequence sequence :source source
              :start (copy-point start :right-inserting)
              :end (copy-point end :left-inserting)
              :filename (when (buffer-filename source) (copy-seq (buffer-filename source)))
              :buffer-name (copy-seq (buffer-name source))
              :line (line-number-at-point start) :column (point-charpos start)
              :revision (buffer-modified-tick source)
              :observed-tick (buffer-modified-tick source)
              :original (points-to-string start end))))
      (setf (gethash (%proposal-id proposal) *proposals*) proposal)
      (push proposal (buffer-value source *buffer-proposals-key*))
      proposal)))

(defun stage-replacement (proposal replacement)
  "Stage bounded replacement text without changing the captured source or revision."
  (require-editor-thread)
  (check-type replacement string)
  (when (or (terminal-proposal-p proposal) (eq :applying (%proposal-state proposal)))
    (error 'proposal-error :proposal proposal :reason :already-finished))
  (when (> (length replacement) *maximum-text-characters*)
    (error 'proposal-error :proposal proposal :reason :replacement-too-large))
  (reserve-capacity (- (length replacement) (length (%proposal-replacement proposal))))
  (proposal-valid-p proposal)
  (setf (%proposal-replacement proposal) (copy-seq replacement))
  (incf (%proposal-generation proposal))
  (unless (%proposal-conflict proposal) (setf (%proposal-state proposal) :pending))
  proposal)

(defun reject-proposal (proposal)
  (require-editor-thread)
  (when (or (terminal-proposal-p proposal) (eq :applying (%proposal-state proposal)))
    (error 'proposal-error :proposal proposal :reason :already-finished))
  (setf (%proposal-state proposal) :rejected)
  (release-markers proposal)
  (proposal-finished proposal)
  proposal)

(defun apply-proposal (proposal &key (expected-revision (%proposal-revision proposal))
                                    (expected-generation (%proposal-generation proposal)))
  "Apply an explicitly accepted candidate as one undo unit, or signal a conflict.
Queued approvals must supply the revision and generation that the human reviewed."
  (require-editor-thread)
  (unless (and (= expected-revision (%proposal-revision proposal))
               (= expected-generation (%proposal-generation proposal)))
    (error 'proposal-conflict :proposal proposal :reason :reviewed-version-changed))
  (multiple-value-bind (valid reason) (proposal-valid-p proposal)
    (unless valid (error 'proposal-conflict :proposal proposal :reason reason)))
  (unless (stringp (%proposal-replacement proposal))
    (error 'proposal-error :proposal proposal :reason :replacement-not-ready))
  (let ((source (%proposal-source proposal)))
    (when (buffer-read-only-p source)
      (error 'proposal-error :proposal proposal :reason :source-read-only))
    (unless (string= (%proposal-original proposal) (%proposal-replacement proposal))
      (let ((boundary-enabled (lem/buffer/internal::buffer-enable-undo-boundary-p source))
            (source-point (position-at-point (buffer-point source)))
            (group nil) (accepted nil))
        (unwind-protect
             (progn
               ;; A proposal must not merge into an open human insertion command.
               (buffer-enable-undo-boundary source)
               (buffer-undo-boundary source)
               (setf group (buffer-prepare-change-group source)
                     (%proposal-state proposal) :applying)
               (buffer-disable-undo-boundary source)
               (with-point ((insertion (%proposal-start proposal) :right-inserting))
                 (delete-between-points (%proposal-start proposal) (%proposal-end proposal))
                 (insert-string insertion (%proposal-replacement proposal))
                 (buffer-accept-change-group group)
                 (setf accepted t)
                 (buffer-enable-undo-boundary source)
                 (buffer-undo-boundary source)
                 (move-point (buffer-point source) insertion)))
          (unless accepted
            (when (and group (buffer-change-group-active-p group))
              (let ((lem/buffer/internal::*inhibit-modification-hooks* t))
                (buffer-cancel-change-group group)))
            (move-to-position (buffer-point source) source-point)
            (setf (%proposal-state proposal) :pending
                  (%proposal-observed-tick proposal) (buffer-modified-tick source)))
          (unless boundary-enabled (buffer-disable-undo-boundary source)))))
    (setf (%proposal-state proposal) :applied)
    (release-markers proposal)
    (proposal-finished proposal))
  proposal)

(defun observe-before-change (point change)
  (let ((buffer (point-buffer point)))
    (dolist (proposal (buffer-value buffer *buffer-proposals-key*))
      (when (member (%proposal-state proposal) '(:captured :pending))
        (setf (%proposal-before-tick proposal) (buffer-modified-tick buffer))
        (unless (= (%proposal-observed-tick proposal) (buffer-modified-tick buffer))
          (mark-conflict proposal :unobserved-source-change))
        (let ((position (position-at-point point))
              (start (position-at-point (%proposal-start proposal)))
              (end (position-at-point (%proposal-end proposal))))
          (when (etypecase change
                  (string (and (plusp (length change)) (<= start position end)))
                  (integer
                   (and (plusp change)
                        (if (= start end) (<= position start (+ position change))
                            (and (< position end) (> (+ position change) start))))))
            (mark-conflict proposal :source-region-edited)))))))

(defun observe-after-change (start end old-length)
  (declare (ignore end old-length))
  (let ((buffer (point-buffer start)))
    (dolist (proposal (buffer-value buffer *buffer-proposals-key*))
      (when (member (%proposal-state proposal) '(:captured :pending))
        (let ((tick (buffer-modified-tick buffer)))
          (unless (or (= tick (%proposal-observed-tick proposal))
                      (and (= tick (1+ (%proposal-observed-tick proposal)))
                           (eql (%proposal-before-tick proposal)
                                (%proposal-observed-tick proposal))))
            (mark-conflict proposal :unobserved-source-change))
          (setf (%proposal-observed-tick proposal) tick
                (%proposal-before-tick proposal) nil))))))

(defun source-killed (buffer)
  (dolist (proposal (list-proposals))
    (when (eq buffer (%proposal-source proposal))
      (mark-conflict proposal :source-deleted)
      (release-markers proposal)
      (setf (%proposal-source proposal) nil))))

(add-hook (variable-value 'before-change-functions :global t) 'observe-before-change)
(add-hook (variable-value 'after-change-functions :global t) 'observe-after-change)
(add-hook (variable-value 'kill-buffer-hook :global t) 'source-killed)
