(defpackage :lem-agent/edit-recovery
  (:use :cl :lem)
  (:local-nicknames (:agent :lem-agent) (:ui :lem-agent/ui)
                    (:proposals :lem-buffer-proposals))
  (:export :show-retained-reviews :show-retained-review :capture-selection
           :release-selection :restage-selection :discard-displayed-review
           :agent-retained-reviews :agent-retained-review-open
           :agent-retained-review-refresh :agent-retained-review-discard
           :agent-restage-retained-review :agent-show-session))
(in-package :lem-agent/edit-recovery)

(defparameter *render-limit* (* 192 1024))
(defparameter *maximum-views* 32)
(defparameter *maximum-pending-discards* 16)
(defvar *pending-discards* 0)             ; editor-owned
(defvar *recovery-keymap* (make-keymap :description "Historical agent edits"))
(define-major-mode retained-review-mode nil
    (:name "Historical edits" :keymap *recovery-keymap*))

(defun require-editor-thread ()
  (let ((editor (find-editor-thread)))
    (when (and editor (not (eq editor (bt2:current-thread))))
      (error "Candidate recovery requires the editor thread"))))

(defun field (object name) (when (hash-table-p object) (gethash name object)))
(defun json-text (value) (with-output-to-string (out) (yason:encode value out)))

(defun complete-record (record)
  "Refuse incomplete projections; a preview must never become an edit input."
  (handler-case
      (let* ((copy (agent:json-copy record 65536)) (id (field copy "id")))
        (when (and (hash-table-p copy) (stringp id) (= 32 (length id))
                   (every (lambda (c) (find c "0123456789abcdef")) id)
                   (every (lambda (key) (stringp (field copy key))) '("turn_id" "call_id" "tool"))
                   (typep (field copy "generation") '(integer 0 *))
                   (member (field copy "status") '("executing" "returned" "unknown") :test #'equal)
                   (hash-table-p (field copy "arguments"))
                   (<= (length (babel:string-to-octets (json-text copy) :encoding :utf-8)) 65536))
          copy))
    (error () nil)))

(defun editable-record-p (record)
  (and (equal "propose_edit" (field record "tool"))
       (every (lambda (key) (stringp (field (field record "arguments") key)))
              '("path" "revision" "original" "replacement"))))

(defun same-origin-p (left right)
  ;; Historical status/result enrichment is not a new candidate. JSON objects
  ;; have unordered keys, so compare recursively rather than encoded key order.
  (labels ((same (a b)
             (cond ((and (hash-table-p a) (hash-table-p b))
                    (and (= (hash-table-count a) (hash-table-count b))
                         (loop for key being the hash-keys of a using (hash-value value)
                               always (multiple-value-bind (other present) (gethash key b)
                                        (and present (same value other))))))
                   ((and (vectorp a) (not (stringp a)) (vectorp b) (not (stringp b)))
                    (and (= (length a) (length b)) (every #'same a b)))
                   (t (equal a b)))))
    (and left right
         (every (lambda (key) (same (field left key) (field right key)))
                '("id" "turn_id" "call_id" "tool" "arguments")))))

(defun session-for-view (&optional (buffer (current-buffer)))
  (or (buffer-value buffer 'ui::agent-session)
      (editor-error "This buffer has no native agent session")))

(defun make-recovery-buffer (session id)
  (when (>= (count-if (lambda (buffer) (eq 'retained-review-mode (buffer-major-mode buffer)))
                     (buffer-list)) *maximum-views*)
    (editor-error "Too many historical edit views"))
  (let ((buffer (make-buffer (unique-buffer-name "*Agent historical edits*") :enable-undo-p nil)))
    (setf (buffer-value buffer 'ui::agent-session) session
          (buffer-value buffer 'review-id) id
          ;; Root is descriptive metadata only. Never resolve it or visit a file.
          (buffer-value buffer 'origin-root) (field (agent:session-snapshot session) "root"))
    (change-buffer-mode buffer 'retained-review-mode)
    buffer))

(defun render-recovery (buffer)
  (require-editor-thread)
  (let* ((session (session-for-view buffer)) (id (buffer-value buffer 'review-id))
         (records (if id (list (agent:find-retained-review session id))
                      (agent:list-retained-reviews session)))
         (actions nil) (text (make-array 0 :element-type 'character :adjustable t :fill-pointer 0))
         (truncated nil))
    (labels ((add (string &optional record)
               (let* ((start (length text)) (count (min (length string) (max 0 (- *render-limit* start)))))
                 (loop for i below count do (vector-push-extend (char string i) text))
                 (if (= count (length string))
                     (when record (push (list start (length text) record) actions))
                     (setf truncated t))))
             (line (control &rest arguments) (add (apply #'format nil control arguments))))
      (line "Historical agent edit candidates~%Session: ~a~%Origin root (metadata only): ~a~2%"
            (agent:session-id session) (json-text (buffer-value buffer 'origin-root)))
      (line "Current applicability and prior application are UNKNOWN. A recorded tool return does not establish either.~%")
      (line "This view never visits a file or applies an edit. Restage only from an explicitly selected live region.~%")
      (line "Return inspect row; d discard metadata; g refresh; C-c C-z transcript; q close view.~2%")
      (when (null records) (line "No retained candidates.~%"))
      (loop for raw in records for index from 0 below 16
            for record = (complete-record raw)
            do (cond ((null record) (line "[Candidate missing or incomplete; actions disabled.]~%"))
                     (id
                      (add (format nil "Review ~a~%Origin turn: ~a~%Origin call: ~a~%Tool: ~a~%Historical status: ~a; generation: ~d~%~%Original (JSON string):~%~a~%~%Replacement (JSON string):~%~a~%~%Complete historical record (JSON):~%~a~%"
                                   (field record "id") (json-text (field record "turn_id"))
                                   (json-text (field record "call_id")) (json-text (field record "tool"))
                                   (field record "status") (field record "generation")
                                   (json-text (field (field record "arguments") "original"))
                                   (json-text (field (field record "arguments") "replacement"))
                                   (json-text record)) record))
                     (t (add (format nil "~a  ~a  ~a  ~a~%" (field record "id")
                                     (field record "status") (json-text (field record "tool"))
                                     (json-text (field (field record "arguments") "path"))) record))))
      (when (> (length records) 16) (setf truncated t))
      (when truncated
        (setf actions nil)
        (loop for c across (format nil "~%[Display truncated; all actions disabled.]~%")
              do (vector-push-extend c text)))
      (let ((position (position-at-point (buffer-point buffer)))
            (old-target (text-property-at (buffer-point buffer) 'retained-record)))
        (with-buffer-read-only buffer nil
          (erase-buffer buffer)
          (insert-string (buffer-point buffer) text)
          (dolist (span actions)
            (destructuring-bind (start end record) span
              (with-point ((left (buffer-start-point buffer)) (right (buffer-start-point buffer)))
                (move-to-position left (1+ start)) (move-to-position right (1+ end))
                (put-text-property left right 'retained-record record))))
          (buffer-mark-saved buffer))
        (setf (buffer-read-only-p buffer) t)
        (move-to-position (buffer-point buffer) (min position (1+ (length text))))
        (let ((new-target (text-property-at (buffer-point buffer) 'retained-record)))
          (when (and new-target
                     (not (and (same-origin-p old-target new-target)
                               (eql (field old-target "generation") (field new-target "generation")))))
            (buffer-start (buffer-point buffer)))))
      buffer)))

(defun show-retained-reviews (session)
  "Return a read-only historical list without selecting a window."
  (require-editor-thread)
  (render-recovery (make-recovery-buffer session nil)))
(defun show-retained-review (session id)
  "Return exact bounded history; missing or incomplete records have no actions."
  (require-editor-thread)
  (render-recovery (make-recovery-buffer session id)))

(defstruct (selection (:constructor make-selection (proposal revision generation)))
  proposal revision generation published consumed)

(defun capture-selection (&optional (buffer (current-buffer)))
  "Capture the explicit live mark before any prompt, retaining the change chain."
  (require-editor-thread)
  (when (or (deleted-buffer-p buffer) (buffer-read-only-p buffer) (not (buffer-mark-p buffer)))
    (editor-error "Select an explicit region in a writable live buffer, including a mark for insertion"))
  (let ((start (region-beginning buffer)) (end (region-end buffer)))
    (when (> (- (position-at-point end) (position-at-point start)) 65536)
      (editor-error "Selected region exceeds the historical candidate bound"))
    (let ((proposal (proposals:capture-region start end)))
      (make-selection proposal (proposals:proposal-revision proposal) (proposals:proposal-generation proposal)))))

(defun release-selection (selection)
  "Forget an unpublished temporary capture. Safe on prompt cancellation or error."
  (require-editor-thread)
  (unless (selection-published selection)
    (let ((proposal (selection-proposal selection)))
      (when (eq proposal (proposals:find-proposal (proposals:proposal-id proposal)))
        (unless (member (proposals:proposal-state proposal) '(:applied :rejected :forgotten))
          (proposals:reject-proposal proposal))
        (proposals:forget-proposal proposal))))
  (setf (selection-consumed selection) t))

(defun selection-valid-p (selection &optional staged)
  (let* ((proposal (selection-proposal selection)) (source (proposals:proposal-source-buffer proposal)))
    (and (eq proposal (proposals:find-proposal (proposals:proposal-id proposal)))
         source (not (deleted-buffer-p source)) (not (buffer-read-only-p source))
         (= (selection-revision selection) (buffer-modified-tick source))
         (= (selection-revision selection) (proposals:proposal-revision proposal))
         (= (+ (selection-generation selection) (if staged 1 0)) (proposals:proposal-generation proposal))
         (eq (proposals:proposal-state proposal) (if staged :pending :captured))
         (proposals:proposal-valid-p proposal)
         (equal (proposals:proposal-original proposal) (proposals:proposal-current-text proposal)))))

(defun current-candidate (session expected)
  (let ((current (complete-record (agent:find-retained-review session (field expected "id")))))
    (unless (and (same-origin-p expected current) (editable-record-p current)
                 (not (equal "executing" (field current "status"))))
      (editor-error "Historical candidate is missing, changed, incomplete, or still executing"))
    current))

(defun restage-selection (selection session record)
  "Create a new pending proposal from the pre-prompt capture; never apply text.
RECORD is the exact historical snapshot chosen by the human. Failed attempts
forget the temporary capture. Changes to result/status alone do not rebind it."
  (require-editor-thread)
  (when (selection-consumed selection) (editor-error "This selection capture has already been used"))
  (setf (selection-consumed selection) t)
  (unwind-protect
       (let* ((expected (complete-record record))
              (proposal (selection-proposal selection)))
         (unless (and expected (editable-record-p expected) (selection-valid-p selection))
           (editor-error "Live selection or complete historical candidate is no longer valid"))
         (current-candidate session expected)
         (unless (equal (proposals:proposal-original proposal)
                        (field (field expected "arguments") "original"))
           (editor-error "Selected region must equal the recorded original exactly"))
         (proposals:stage-replacement proposal (field (field expected "arguments") "replacement"))
         ;; A concurrent metadata discard seen during staging abandons this new,
         ;; still unapplied proposal. Later discard cannot revoke a published one.
         (current-candidate session expected)
         (unless (selection-valid-p selection t) (editor-error "Selection changed while staging"))
         (setf (selection-published selection) t)
         proposal)
    (release-selection selection)))

(defun displayed-record (&optional (buffer (current-buffer)))
  (unless (eq (buffer-major-mode buffer) 'retained-review-mode)
    (editor-error "Use a historical candidate view"))
  (or (text-property-at (buffer-point buffer) 'retained-record)
      (editor-error "Place point on a complete historical candidate")))

(defun discard-displayed-review (&optional (buffer (current-buffer)))
  "Queue metadata-only discard; durable receipt waiting stays off the editor."
  (require-editor-thread)
  (let* ((session (session-for-view buffer)) (record (displayed-record buffer))
         (id (field record "id")) (generation (field record "generation"))
         (token (list id generation)))
    (when (or (buffer-value buffer 'discard-pending) (>= *pending-discards* *maximum-pending-discards*))
      (editor-error "A discard is already pending or the receipt limit was reached"))
    (setf (buffer-value buffer 'discard-pending) token)
    (incf *pending-discards*)
    (handler-case
        (bt2:make-thread
         (lambda ()
           (let (value failure)
             (handler-case
                 (let ((receipt (agent:discard-retained-review session id :expected-generation generation)))
                   (loop (multiple-value-bind (result done) (agent:await-request receipt :timeout 1)
                           (when done (setf value result) (return)))))
               (error (condition) (setf failure (format nil "Discard failed (~a); refresh and inspect history." (type-of condition)))))
             (send-event
              (lambda ()
                (decf *pending-discards*)
                (unless (or (deleted-buffer-p buffer)
                            (not (eq token (buffer-value buffer 'discard-pending))))
                  (setf (buffer-value buffer 'discard-pending) nil
                        (buffer-value buffer 'discard-status)
                        (or failure (if value "Metadata discarded; live proposals and source text are unchanged."
                                        "Historical entry was already absent."))
                        (variable-value 'modeline-format :buffer buffer)
                        (list "  " 'modeline-name "  " (buffer-value buffer 'discard-status)))
                  (render-recovery buffer)
                  (redraw-display))))))
         :name "historical candidate discard")
      (error (condition)
        (decf *pending-discards*) (setf (buffer-value buffer 'discard-pending) nil) (error condition)))
    token))

(defun choose-exact-id (prompt ids)
  (let ((id (prompt-for-string prompt :completion-function (lambda (input) (completion input ids)))))
    (unless (member id ids :test #'equal) (editor-error "Choose an exact listed identifier")) id))
(defun select-recovery-buffer (buffer) (setf (current-window) (pop-to-buffer buffer)))

(define-command agent-retained-reviews () ()
  (select-recovery-buffer (show-retained-reviews (session-for-view))))
(define-command agent-retained-review-open () ()
  (select-recovery-buffer (show-retained-review (session-for-view) (field (displayed-record) "id"))))
(define-command agent-retained-review-refresh () () (render-recovery (current-buffer)))
(define-command agent-retained-review-discard () () (discard-displayed-review))
(define-command agent-show-session () ()
  "Deliberately return from any session-associated buffer to a new transcript view."
  (select-recovery-buffer (ui:show-session (session-for-view))))
(define-command agent-restage-retained-review () ()
  "Restage an exact historical candidate into the region selected before prompts."
  (let ((selection (capture-selection)))
    (unwind-protect
         (let* ((manager ui:*default-manager*)
                (sessions (and (agent:manager-open-p manager) (agent:manager-sessions manager))))
           (unless sessions (editor-error "No configured native agent sessions are available"))
           (let* ((session-id (choose-exact-id "Historical session ID: " (mapcar #'agent:session-id sessions)))
                  (session (find session-id sessions :key #'agent:session-id :test #'equal))
                  (records (remove-if-not (lambda (record) (and (complete-record record) (editable-record-p record)))
                                          (agent:list-retained-reviews session))))
             (unless records (editor-error "This session has no complete historical edit candidates"))
             (let* ((id (choose-exact-id "Historical review ID: " (mapcar (lambda (record) (field record "id")) records)))
                    (record (find id records :key (lambda (record) (field record "id")) :test #'equal)))
               (unless (and (agent:manager-open-p manager) (eq session (agent:find-session manager session-id)))
                 (editor-error "The selected session owner has changed"))
               (let* ((proposal (restage-selection selection session record))
                      (buffer (proposals:proposal-review-buffer proposal)))
                 (setf (buffer-value buffer 'ui::agent-session) session)
                 (select-recovery-buffer buffer)))))
      (release-selection selection))))

(loop for (key command) on '("Return" agent-retained-review-open "d" agent-retained-review-discard
                            "g" agent-retained-review-refresh "q" ui:agent-close-view
                            "C-c C-z" agent-show-session)
      by #'cddr do (define-key *recovery-keymap* key command))
(define-key ui::*composer-keymap* "C-c C-z" 'agent-show-session)
(define-key ui::*view-keymap* "C-c C-z" 'agent-show-session)
(define-key proposals::*proposal-review-keymap* "C-c C-z" 'agent-show-session)
