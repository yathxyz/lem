(defpackage :lem-toolkit/jobs-ui
  (:use :cl :lem)
  (:local-nicknames (:jobs :lem-toolkit/jobs) (:store :lem-daemon/recovery-store))
  (:export :show-job :jobs-list :job-open :job-cancel :job-refresh
           :job-journal-open :job-journal-inspect :job-journal-discard :jobs-next-page :jobs-first-page :jobs-refresh))
(in-package :lem-toolkit/jobs-ui)

(defvar *job-buffers* (make-hash-table :test #'eq))
(defvar *refresh-timer* nil)

(define-major-mode managed-job-mode () (:name "Managed Job" :keymap *managed-job-keymap*))
(define-key *managed-job-keymap* "g" 'job-refresh)
(define-key *managed-job-keymap* "c" 'job-cancel)

(defun refresh-job-buffer (buffer job)
  (let ((snapshot (jobs:job-snapshot job)))
    (unless (equalp snapshot (buffer-value buffer 'last-job-snapshot))
      (let ((position (position-at-point (buffer-point buffer))))
        (with-buffer-read-only buffer nil
          (erase-buffer buffer)
          (insert-string
           (buffer-point buffer)
           (with-output-to-string (out)
             (format out "Job ~a~%State: ~a  Owner: ~a~%Directory: ~a~%Argv: ~s~%"
                     (store:field snapshot "id") (store:field snapshot "state")
                     (store:field snapshot "owner") (store:field snapshot "directory")
                     (store:field snapshot "argv"))
             (when (store:field snapshot "reason") (format out "Reason: ~a~%" (store:field snapshot "reason")))
             (when (store:field snapshot "journal-error")
               (format out "Journal failure: ~a~%" (store:field snapshot "journal-error")))
             (format out "Closing this buffer leaves the job running. Press c to cancel; g to refresh.~%")
             (dolist (channel '("stdout" "stderr"))
               (format out "~%~a (retained ~d of ~d bytes):~%~a"
                       channel (store:field snapshot (concatenate 'string channel "-retained-bytes"))
                       (store:field snapshot (concatenate 'string channel "-bytes"))
                       (store:field snapshot channel)))))
          (move-to-position (buffer-point buffer) (min position (position-at-point (buffer-end-point buffer))))
          (buffer-mark-saved buffer)))
      (setf (buffer-value buffer 'last-job-snapshot) snapshot))))

(defun refresh-visible-jobs ()
  (maphash (lambda (buffer job)
             (if (eq buffer (get-buffer (buffer-name buffer)))
                 (refresh-job-buffer buffer job)
                 (remhash buffer *job-buffers*)))
           *job-buffers*)
  (when (zerop (hash-table-count *job-buffers*))
    (stop-timer *refresh-timer*) (setf *refresh-timer* nil)))

(defun show-job (job)
  (let ((buffer (make-buffer (format nil "*Job ~a*" (jobs:job-id job)))))
    (setf (buffer-value buffer 'managed-job) job
          (buffer-directory buffer) (uiop:ensure-directory-pathname (jobs:job-directory job))
          (buffer-value buffer 'lem-daemon/recovery::recovery-exclude) t
          (gethash buffer *job-buffers*) job)
    (change-buffer-mode buffer 'managed-job-mode)
    (refresh-job-buffer buffer job)
    (setf (buffer-read-only-p buffer) t)
    (unless *refresh-timer*
      (setf *refresh-timer* (start-timer (make-idle-timer 'refresh-visible-jobs :name "managed job views")
                                        500 :repeat t)))
    (pop-to-buffer buffer)
    buffer))

(define-command job-refresh () ()
  (let ((job (buffer-value (current-buffer) 'managed-job)))
    (when job (refresh-job-buffer (current-buffer) job))))
(define-command job-cancel () ()
  (let ((job (buffer-value (current-buffer) 'managed-job)))
    (unless job (editor-error "This buffer does not display a managed job"))
    (jobs:cancel-job job)
    (message "Cancellation requested")))
(define-command job-open (id) ((:string "Job ID: "))
  (let ((job (jobs:find-job id)))
    (unless job (editor-error "Unknown job ID"))
    (show-job job)))
(defvar *maintenance-requests* 0)
(defvar *maintenance-request-lock* (bt2:make-lock :name "Job view maintenance requests"))
(defvar *maintenance-dispatch* #'send-event)
(defvar *confirm-journal-discard* #'prompt-for-y-or-n-p)

(define-major-mode job-inventory-mode () (:name "Job History" :keymap *job-inventory-keymap*))
(define-key *job-inventory-keymap* "g" 'jobs-refresh)
(define-key *job-inventory-keymap* "n" 'jobs-next-page)
(define-key *job-inventory-keymap* "b" 'jobs-first-page)
(define-key *job-inventory-keymap* "Return" 'job-journal-open)
(define-key *job-inventory-keymap* "i" 'job-journal-inspect)
(define-major-mode job-journal-mode () (:name "Job Journal" :keymap *job-journal-keymap*))
(define-key *job-journal-keymap* "g" 'jobs-refresh)
(define-key *job-journal-keymap* "d" 'job-journal-discard)

(defun live-buffer-p (buffer)
  (and buffer (not (deleted-buffer-p buffer)) (eq buffer (get-buffer (buffer-name buffer)))))

(defun async-maintenance (buffer work publish)
  "Bound worker/event receipts and make late completion inert for a killed/replaced view."
  (let ((pending (buffer-value buffer 'maintenance-request)))
    (when (and pending (null (car pending))) (setf (buffer-value buffer 'maintenance-request) nil)))
  (when (buffer-value buffer 'maintenance-request) (editor-error "This job view is already waiting for journal I/O"))
  (let ((token (list t)) (weak (sb-ext:make-weak-pointer buffer)) (dispatch *maintenance-dispatch*))
    (bt2:with-lock-held (*maintenance-request-lock*)
      (when (>= *maintenance-requests* 8) (editor-error "Too many pending job journal requests"))
      (incf *maintenance-requests*))
    (setf (buffer-value buffer 'maintenance-request) token)
    (labels ((claim ()
               (bt2:with-lock-held (*maintenance-request-lock*)
                 (when (car token) (setf (car token) nil) (decf *maintenance-requests*) t))))
      (handler-case
          (bt2:make-thread
           (lambda ()
             (let ((value nil) (failure nil))
               (handler-case (setf value (funcall work))
                 (error (condition)
                   (let ((text (princ-to-string condition)))
                     (setf failure (subseq text 0 (min 2048 (length text)))))))
               (handler-case
                   (funcall dispatch
                            (lambda ()
                              (when (claim)
                                (let ((buffer (sb-ext:weak-pointer-value weak)))
                                  (when (and (live-buffer-p buffer)
                                             (eq token (buffer-value buffer 'maintenance-request)))
                                    (setf (buffer-value buffer 'maintenance-request) nil
                                          (buffer-value buffer 'maintenance-error) failure)
                                    (if failure
                                        (progn
                                          (setf (buffer-value buffer 'journal-entry) nil)
                                          (replace-view-text buffer
                                                             (format nil "Job journal operation failed: ~a~%g refreshes the review before another cleanup attempt.~%" failure)))
                                        (funcall publish buffer value)))))))
                 (error () (claim)))))
           :name "Job journal view")
        (error (condition)
          (claim) (setf (buffer-value buffer 'maintenance-request) nil) (error condition))))
    token))

(defun replace-view-text (buffer text)
  (let ((position (position-at-point (buffer-point buffer))))
    (with-buffer-read-only buffer nil
      (erase-buffer buffer) (insert-string (buffer-point buffer) text)
      (move-to-position (buffer-point buffer) (min position (position-at-point (buffer-end-point buffer))))
      (buffer-mark-saved buffer))))

(defun render-inventory (buffer page)
  (let ((status (jobs:job-manager-status (buffer-value buffer 'journal-manager))))
    (setf (buffer-value buffer 'journal-page) page)
    (replace-view-text
     buffer (with-output-to-string (out)
              (format out "Managed job history: ~d / ~d retained slots; ~d loaded, ~d unloaded.~%"
                      (store:field status "retained-slots") (store:field status "maximum-jobs")
                      (store:field status "loaded") (store:field status "unloaded"))
              (format out "Disk: ~d journals; ~d reserved IDs without journals; ~d noncanonical JSON names left as manual files.~%"
                      (store:field page "total") (store:field page "reserved-without-journal")
                      (store:field page "ignored-names"))
              (when (store:field status "pending-deletion")
                (format out "Pending uncertain deletion: ~a. Inspect this ID and retry its displayed receipt.~%"
                        (store:field (store:field status "pending-deletion") "id")))
              (format out "RET inspects this row; i inspects an exact ID; g refreshes; n next page; b first page.~%~%")
              (loop for entry across (store:field page "entries")
                    do (format out "~a  ~a  ~a~%" (store:field entry "id")
                               (or (store:field entry "diagnostic") (store:field entry "state"))
                               (or (store:field entry "owner") "")))
              (format out "~%~a~%" (if (store:field page "next-after") "More history available: n" "End of history"))))))

(defun refresh-inventory (buffer after)
  (let ((manager (buffer-value buffer 'journal-manager)))
    (async-maintenance buffer (lambda () (jobs:list-job-journal manager :after after :limit 32))
                       (lambda (buffer page)
                         (setf (buffer-value buffer 'journal-after) after)
                         (render-inventory buffer page)))))

(defun bounded-display (value &optional (limit 8192))
  (let ((text (if (stringp value) value (prin1-to-string value))))
    (if (> (length text) limit) (concatenate 'string (subseq text 0 limit) " [display truncated]") text)))

(defun render-journal (buffer entry)
  (setf (buffer-value buffer 'journal-entry) entry)
  (let ((record (store:field entry "record")))
    (replace-view-text
     buffer (with-output-to-string (out)
              (format out "Historical job ~a~%Fingerprint: ~a~%Diagnostic: ~a~%"
                      (store:field entry "id") (store:field entry "fingerprint") (store:field entry "diagnostic"))
              (format out "This is a saved observation. It cannot prove that external effects were undone.~%g refreshes; d deliberately discards this exact reviewed journal.~%")
              (when record
                (dolist (key '("state" "owner" "directory" "argv" "exit-code" "reason" "journal-error"))
                  (format out "~a: ~a~%" key (bounded-display (store:field record key))))
                (dolist (channel '("stdout" "stderr"))
                  (format out "~%~a (retained ~a of ~a observed bytes):~%~a~%" channel
                          (store:field record (concatenate 'string channel "-retained-bytes"))
                          (store:field record (concatenate 'string channel "-bytes"))
                          (bounded-display (babel:octets-to-string
                                            (ironclad:hex-string-to-byte-array
                                             (store:field record (concatenate 'string channel "-hex")))
                                            :encoding :utf-8 :errorp nil)))))))))

(defun refresh-journal (buffer)
  (let ((manager (buffer-value buffer 'journal-manager)) (id (buffer-value buffer 'journal-id)))
    (async-maintenance
     buffer (lambda ()
              (let* ((entry (jobs:inspect-job-record manager id))
                     (pending (store:field (jobs:job-manager-status manager) "pending-deletion")))
                (when (and pending (equal id (store:field pending "id")))
                  (setf (gethash "fingerprint" entry) (store:field pending "fingerprint")
                        (gethash "diagnostic" entry) "uncertain-deletion-durability"))
                entry)) #'render-journal)))

(defun show-journal (manager id)
  (unless (store::valid-id-p id) (editor-error "Select a canonical job ID"))
  (let ((buffer (make-buffer (format nil "*Job Journal ~a*" id))))
    (setf (buffer-value buffer 'journal-manager) manager
          (buffer-value buffer 'journal-id) (copy-seq id)
          (buffer-value buffer 'lem-daemon/recovery::recovery-exclude) t)
    (change-buffer-mode buffer 'job-journal-mode)
    (setf (buffer-read-only-p buffer) t)
    (refresh-journal buffer)
    buffer))

(define-command jobs-refresh () ()
  (let ((buffer (current-buffer)))
    (if (buffer-value buffer 'journal-id) (refresh-journal buffer)
        (refresh-inventory buffer (buffer-value buffer 'journal-after)))))
(define-command jobs-next-page () ()
  (let ((next (store:field (buffer-value (current-buffer) 'journal-page) "next-after")))
    (unless next (editor-error "No later job history page"))
    (refresh-inventory (current-buffer) next)))
(define-command jobs-first-page () () (refresh-inventory (current-buffer) nil))
(define-command job-journal-open () ()
  (let* ((text (line-string (current-point)))
         (id (when (>= (length text) 32) (subseq text 0 32))))
    (unless (store::valid-id-p id) (editor-error "Select a job history row"))
    (pop-to-buffer (show-journal (buffer-value (current-buffer) 'journal-manager) id))))

(define-command job-journal-inspect (id) ((:string "Historical job ID: "))
  (pop-to-buffer (show-journal (or (buffer-value (current-buffer) 'journal-manager) jobs:*default-manager*) id)))

(defun discard-displayed-journal (buffer)
  (let* ((entry (buffer-value buffer 'journal-entry)) (record (and entry (store:field entry "record")))
         (id (and entry (store:field entry "id"))) (fingerprint (and entry (store:field entry "fingerprint")))
         (manager (buffer-value buffer 'journal-manager))
         (uncertain (or (and entry (store:field entry "diagnostic"))
                        (and record (store:field record "journal-error"))
                        (and record (not (member (store:field record "state")
                                                 '("exited" "signaled" "cancelled" "timed-out") :test #'equal))))))
    (unless fingerprint (editor-error "This record has no safe cleanup fingerprint; inspect the file manually"))
    (when (and (funcall *confirm-journal-discard* (format nil "Permanently discard job ~a, fingerprint ~a" id fingerprint))
               (or (not uncertain)
                   (funcall *confirm-journal-discard* "Acknowledge uncertain external effects or deletion durability and forget this history")))
      (unless (and (live-buffer-p buffer) (eq entry (buffer-value buffer 'journal-entry)))
        (editor-error "The job review changed while confirming; inspect it again"))
      (async-maintenance
       buffer (lambda () (jobs:discard-job manager id :expected-fingerprint fingerprint
                                          :acknowledge-uncertain (not (null uncertain))))
       (lambda (buffer removed)
         (setf (buffer-value buffer 'journal-entry) nil)
         (replace-view-text buffer (format nil "Job ~a history ~a.~%" id (if removed "discarded" "already absent"))))))))

(define-command job-journal-discard () () (discard-displayed-journal (current-buffer)))
(define-command jobs-list () ()
  (let ((buffer (make-buffer "*Managed Jobs*")))
    (setf (buffer-value buffer 'journal-manager) jobs:*default-manager*
          (buffer-value buffer 'lem-daemon/recovery::recovery-exclude) t)
    (change-buffer-mode buffer 'job-inventory-mode)
    (setf (buffer-read-only-p buffer) t)
    (refresh-inventory buffer nil)
    (pop-to-buffer buffer)))
