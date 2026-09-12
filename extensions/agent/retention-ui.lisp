(defpackage :lem-agent/retention-ui
  (:use :cl :lem)
  (:local-nicknames (:agent :lem-agent) (:ui :lem-agent/ui))
  (:export :show-journals :show-journal :agent-journals :agent-journal-open
           :agent-journal-next :agent-journal-refresh :agent-journal-discard
           :agent-journal-close-session))
(in-package :lem-agent/retention-ui)

(defvar *journal-keymap* (make-keymap :description "Stored agent sessions"))
(define-major-mode agent-journal-mode nil (:name "Agent journals" :keymap *journal-keymap*))
(defvar *pending* 0)                       ; editor-owned
(defparameter *maximum-views* 8)
(defparameter *maximum-pending* 8)

(defun field (object name) (when (hash-table-p object) (gethash name object)))
(defun json-text (value) (with-output-to-string (out) (yason:encode value out)))
(defun operation-status (buffer text) (ui::set-status buffer text))

(defun background (buffer operation function continuation)
  (ui::require-editor-thread)
  (when (deleted-buffer-p buffer) (editor-error "The journal view was closed"))
  (when (or (buffer-value buffer 'pending) (>= *pending* *maximum-pending*))
    (editor-error "A journal request is pending; wait for its status"))
  (let ((token (list operation)))
    (setf (buffer-value buffer 'pending) token) (incf *pending*)
    (operation-status buffer (format nil "~a pending" operation))
    (handler-case
        (bt2:make-thread
         (lambda ()
           (let (result failure)
             (handler-case (setf result (multiple-value-list (funcall function)))
               (error (condition) (setf failure (format nil "~a failed (~a); refresh status before retrying"
                                                       operation (type-of condition)))))
             (send-event
              (lambda ()
                (decf *pending*)
                (unless (or (deleted-buffer-p buffer) (not (eq token (buffer-value buffer 'pending))))
                  (setf (buffer-value buffer 'pending) nil)
                  (if failure (operation-status buffer failure)
                      (apply continuation buffer result)))))))
         :name "agent journal view")
      (error (condition)
        (setf (buffer-value buffer 'pending) nil) (decf *pending*) (error condition)))
    token))

(defun new-view (manager id)
  (ui::require-editor-thread)
  (unless manager (editor-error "No native agent manager is configured"))
  (when (>= (count-if (lambda (buffer) (eq 'agent-journal-mode (buffer-major-mode buffer))) (buffer-list))
            *maximum-views*)
    (editor-error "Close a journal view before opening another"))
  (let ((buffer (make-buffer (unique-buffer-name "*Agent journals*") :enable-undo-p nil)))
    (setf (buffer-value buffer 'manager) manager (buffer-value buffer 'journal-id) id
          (buffer-value buffer 'recovery-exclude) t)
    (change-buffer-mode buffer 'agent-journal-mode)
    (setf (buffer-read-only-p buffer) t)
    buffer))

(defun replace-view (buffer text &optional spans)
  (with-buffer-read-only buffer nil
    (erase-buffer buffer) (insert-string (buffer-point buffer) text)
    (dolist (span spans)
      (destructuring-bind (start end id) span
        (with-point ((left (buffer-start-point buffer)) (right (buffer-start-point buffer)))
          (move-to-position left (1+ start)) (move-to-position right (1+ end))
          (put-text-property left right 'journal-target id))))
    (buffer-start (buffer-point buffer)) (buffer-mark-saved buffer)))

(defun inventory (manager after)
  (multiple-value-bind (page next total) (agent:list-session-journals manager :after after)
    (let ((spans nil)
          (text (make-array 0 :element-type 'character :adjustable t :fill-pointer 0)))
      (labels ((add (string) (loop for character across string do (vector-push-extend character text))))
        (add (format nil "Stored agent sessions~%Capacity: ~a~%JSON directory entries: ~d~%~%Return inspect; n next page; g refresh; q close view.~%Stored running/waiting records are historical; inspection never resumes them.~%~%"
                     (json-text (agent:session-capacity manager)) total))
        (dolist (entry page)
          (let ((start (length text)) (id (field entry "id")))
            (add (format nil "~a  ~a~%" (json-text id)
                         (cond ((not (field entry "addressable")) "noncanonical name: manual inspection only")
                               ((field entry "loaded") "loaded session") (t "unloaded history"))))
            (when (field entry "addressable") (push (list start (length text) id) spans))))
        (unless page (add (format nil "No further journal names.~%"))))
      (values (coerce text 'simple-string) (nreverse spans) next))))

(defun count-text (record key)
  (if record (format nil "~d" (length (field record key))) "UNKNOWN"))

(defun inspection-text (id record stamp diagnostic capacity)
  (with-output-to-string (out)
    (format out "Stored session ~a~%Exact stored fingerprint: ~a~%Capacity: ~a~2%" id stamp (json-text capacity))
    (format out "g refresh; x explicitly close loaded session; d confirm whole-history discard; q close view.~%")
    (format out "Stored status: ~a~%Stored turns: ~a; queued messages: ~a; retained candidates: ~a; submission receipts: ~a.~%"
            (if record (field record "status") "UNKNOWN") (count-text record "turns")
            (count-text record "queue") (count-text record "retained_reviews") (count-text record "submissions"))
    (format out "These are stored records. A live composer can contain newer text. Separate drafts remain after session deletion and lose their session association.~%")
    (format out "History does not establish whether an uncertain external action completed. Discard neither reverses effects nor saves editor buffers.~2%")
    (if diagnostic (format out "Inspection diagnostic: ~a~%Stored contents and counts are UNKNOWN.~%" diagnostic)
        (let* ((encoded (json-text record)) (length (length encoded)))
          (write-string encoded out :end (min length 65536))
          (when (> length 65536)
            (format out "~%[JSON preview truncated. Discard removes the entire exact inspected journal, including the omitted history.]~%"))))))

(defun refresh (buffer)
  (let ((manager (buffer-value buffer 'manager)) (id (buffer-value buffer 'journal-id))
        (after (buffer-value buffer 'after)))
    (if id
        (background buffer "Journal inspection"
                    (lambda ()
                      (multiple-value-bind (record stamp diagnostic) (agent:inspect-session-journal manager id)
                        (values (inspection-text id record stamp diagnostic (agent:session-capacity manager))
                                record stamp diagnostic)))
                    (lambda (buffer text record stamp diagnostic)
                      (setf (buffer-value buffer 'record) record (buffer-value buffer 'fingerprint) stamp
                            (buffer-value buffer 'diagnostic) diagnostic)
                      (replace-view buffer text) (operation-status buffer "Stored history inspected")))
        (background buffer "Journal inventory" (lambda () (inventory manager after))
                    (lambda (buffer text spans next)
                      (setf (buffer-value buffer 'next) next)
                      (replace-view buffer text spans) (operation-status buffer "Inventory ready"))))))

(defun show-journals (&optional (manager ui:*default-manager*))
  (let ((buffer (new-view manager nil))) (refresh buffer) buffer))
(defun show-journal (manager id)
  (let ((buffer (new-view manager id))) (refresh buffer) buffer))
(defun select-view (buffer) (setf (current-window) (pop-to-buffer buffer)))

(define-command agent-journals () () (select-view (show-journals)))
(define-command agent-journal-open () ()
  (let ((id (text-property-at (current-point) 'journal-target)))
    (unless id (editor-error "Select a complete addressable journal row"))
    (select-view (show-journal (buffer-value (current-buffer) 'manager) id))))
(define-command agent-journal-refresh () () (refresh (current-buffer)))
(define-command agent-journal-next () ()
  (let* ((buffer (current-buffer)) (next (buffer-value buffer 'next)))
    (when (or (buffer-value buffer 'journal-id) (not next)) (editor-error "No next journal page"))
    (when (buffer-value buffer 'pending) (editor-error "Wait for the current journal request"))
    (setf (buffer-value buffer 'after) next) (refresh buffer)))

(define-command agent-journal-close-session () ()
  (let* ((buffer (current-buffer)) (manager (buffer-value buffer 'manager))
         (id (buffer-value buffer 'journal-id)) (session (and id (agent:find-session manager id))))
    (unless session (editor-error "This journal has no loaded session to close"))
    (when (prompt-for-y-or-n-p (format nil "Permanently close session ~a and interrupt its work? " id))
      (background buffer "Close session"
                  (lambda ()
                    (let ((receipt (agent:close-session session)))
                      (loop (multiple-value-bind (value done) (agent:await-request receipt :timeout 1)
                              (when done (return value))))))
                  (lambda (buffer value) (declare (ignore value)) (refresh buffer))))))

(define-command agent-journal-discard () ()
  (let* ((buffer (current-buffer)) (manager (buffer-value buffer 'manager))
         (id (buffer-value buffer 'journal-id)) (stamp (buffer-value buffer 'fingerprint))
         (record (buffer-value buffer 'record)))
    (unless (and id stamp) (editor-error "Inspect an exact session journal before discarding it"))
    (when (buffer-value buffer 'pending) (editor-error "Wait for the current journal request"))
    (when (prompt-for-y-or-n-p
           (format nil "Discard ALL stored history for ~a (~a queued, ~a candidates, ~a receipts), including unknown outcomes? "
                   id (count-text record "queue") (count-text record "retained_reviews") (count-text record "submissions")))
      (background buffer "Journal discard"
                  (lambda () (agent:discard-session-journal manager id stamp :acknowledge-uncertain t))
                  (lambda (buffer removed)
                    (declare (ignore removed))
                    (setf (buffer-value buffer 'fingerprint) nil (buffer-value buffer 'record) nil)
                    (replace-view buffer "The selected stored session was durably discarded. Separate drafts and editor buffers remain.")
                    (operation-status buffer "Journal discarded"))))))

(loop for (key command) on '("Return" agent-journal-open "n" agent-journal-next
                            "g" agent-journal-refresh "d" agent-journal-discard
                            "x" agent-journal-close-session "q" ui:agent-close-view)
      by #'cddr do (define-key *journal-keymap* key command))
