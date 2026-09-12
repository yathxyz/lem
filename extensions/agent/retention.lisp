;;;; Bounded session admission and deliberate journal maintenance.
(in-package :lem-agent)

(defun count-manager-journals (manager)
  (let ((count 0))
    (store:map-private-json (manager-directory manager)
                            (lambda (id path) (declare (ignore path))
                              (when (valid-id-p id) (incf count))))
    count))

(defun session-capacity (manager)
  "Copied, I/O-free capacity information. Slots include uncertain initial writes."
  (bt2:with-lock-held ((manager-lock manager))
    (json-object "limit" (manager-maximum-sessions manager)
                 "loaded" (hash-table-count (manager-session-table manager))
                 "reserved" (manager-journal-count manager)
                 "unloaded" (manager-unloaded-count manager)
                 "pending_cleanup" (when (manager-pending-discard manager)
                                       (copy-seq (first (manager-pending-discard manager)))))))

(defun recovered-record (record)
  (let ((prior-active (field record "active_turn")))
    (when (or prior-active (member (field record "status") '("running" "waiting") :test #'equal))
      (interrupt-retained-reviews record "daemon-interrupted; external outcome unknown; not replayed")
      (loop for turn across (field record "turns")
            when (equal (field turn "id") prior-active)
              do (finish-orphan-calls turn "daemon-interrupted; external outcome unknown; not replayed")
                 (setf (field turn "status") "interrupted"))
      (loop for decision across (field record "decisions")
            when (equal (field decision "status") "pending")
              do (setf (field decision "status") "cancelled" (field decision "reason") "daemon-interrupted"))
      (setf (field record "status") "interrupted" (field record "active_turn") nil))
    (incf (field record "generation"))
    (setf (field record "stream") "")
    record))

(defun restore-manager-journals (manager)
  ;; Maintenance never holds the UI-facing manager lock across filesystem I/O.
  ;; Shutdown takes this storage lock before releasing the directory lease.
  (bt2:with-lock-held ((manager-storage-lock manager))
    (bt2:with-lock-held ((manager-lock manager)) (check-manager-open manager))
    (let ((sessions nil) (failures nil) (failure-count 0) (unloaded 0) (examined 0) (ignored 0))
      (store:map-private-json
       (manager-directory manager)
       (lambda (id path)
         (declare (ignore path))
         (cond
           ((not (valid-id-p id)) (incf ignored))
           ((find-session manager id))
           ((or (>= examined (manager-maximum-sessions manager))
                (bt2:with-lock-held ((manager-lock manager))
                  (>= (hash-table-count (manager-session-table manager)) (manager-maximum-sessions manager))))
            (incf unloaded))
           (t
            (incf examined)
            (handler-case
                (push (attach-session manager
                                      (recovered-record
                                       (validate-restored-record
                                        id (store:read-private-json (manager-directory manager) id
                                                                   :maximum-depth 24)))
                                      :restoring t)
                      sessions)
              (error (condition)
                (incf unloaded) (incf failure-count)
                (when (< (length failures) 32)
                  (push (cons id (format nil "Invalid or unavailable agent journal (~a)" (type-of condition)))
                        failures))))))))
      (bt2:with-lock-held ((manager-lock manager)) (setf (manager-unloaded-count manager) unloaded))
      (when (> unloaded (length failures))
        (push (cons "capacity" (format nil "~d journals remain unloaded, including ~d rejected records. Inspect the journal inventory; nothing was evicted."
                                        unloaded failure-count)) failures))
      (when (plusp ignored)
        (push (cons "noncanonical" (format nil "~d noncanonical JSON filenames were ignored. Inventory lists them for manual inspection; the agent never creates these names." ignored))
              failures))
      (values (nreverse sessions) (nreverse failures)))))

(defun list-session-journals (manager &key after (limit 32))
  "Blocking worker API: bounded lexicographic page of names, next cursor, total.
Malformed JSON names are included but do not count toward admission; no payload is read."
  (unless (and (typep limit '(integer 1 64)) (or (null after) (text-p after 255)))
    (error "Invalid session inventory page"))
  (bt2:with-lock-held ((manager-storage-lock manager))
    (bt2:with-lock-held ((manager-lock manager)) (check-manager-open manager))
    (let* ((names nil)
           (total (store:map-private-json
                   (manager-directory manager)
                   (lambda (id path)
                     (declare (ignore path))
                     (when (or (null after) (string> id after))
                       (push (copy-seq id) names)
                       (setf names (sort names #'string<))
                       (when (> (length names) limit)
                         (setf (cdr (nthcdr (1- limit) names)) nil)))))))
      (values (mapcar (lambda (id) (json-object "id" id "addressable" (valid-id-p id)
                                               "loaded" (not (null (find-session manager id))))) names)
              (car (last names)) total))))

(defun read-session-journal (manager id)
  (multiple-value-bind (record fingerprint diagnostic)
      (store:inspect-private-json (manager-directory manager) id :maximum-depth 24)
    (if diagnostic (values nil fingerprint diagnostic)
        (handler-case (values (validate-restored-record id record) fingerprint nil)
          (error (condition)
            (values nil fingerprint (format nil "Invalid session schema (~a); stored contents and counts are unknown"
                                            (type-of condition))))))))

(defun inspect-session-journal (manager id)
  "Blocking worker API: copied journal, exact byte fingerprint, optional diagnostic.
Reading never attaches a session, invokes tools, opens editor files or checkpoints."
  (unless (valid-id-p id) (error "Invalid session journal ID"))
  (bt2:with-lock-held ((manager-storage-lock manager))
    (bt2:with-lock-held ((manager-lock manager)) (check-manager-open manager))
    (let* ((pending (bt2:with-lock-held ((manager-lock manager)) (manager-pending-discard manager)))
           (directory (store:ensure-private-directory (manager-directory manager) :create nil)))
      (if (and (equal id (first pending)) (null (store::path-stat (store::record-path directory id))))
          (values nil (copy-seq (second pending)) "Deletion durability is uncertain; retry this exact cleanup. Stored contents and counts are unknown.")
          (read-session-journal manager id)))))

(defun uncertain-session-history-p (record)
  (or (null record)
      (member (field record "status") '("running" "waiting" "interrupted" "failed") :test #'equal)
      (some (lambda (turn) (member (field turn "status") '("interrupted" "failed") :test #'equal))
            (field record "turns"))
      (some (lambda (turn)
              (some (lambda (message)
                      (and (equal "tool" (field message "role"))
                           (hash-table-p (field message "content"))
                           (equal "unknown" (field (field message "content") "outcome"))))
                    (field turn "messages")))
            (field record "turns"))
      (find "unknown" (field record "retained_reviews") :key (lambda (review) (field review "status")) :test #'equal)))

(defun discard-session-journal (manager id expected-fingerprint &key acknowledge-uncertain)
  "Blocking explicit whole-history deletion. Never stops or deletes a live actor.
The caller must obtain human confirmation for this exact inspected fingerprint.
Errors, including directory fsync failure after unlink, retain the capacity slot."
  (unless (and (valid-id-p id) (text-p expected-fingerprint 64 64))
    (error "Discard requires an exact session ID and inspected fingerprint"))
  (bt2:with-lock-held ((manager-storage-lock manager))
    (let ((session nil) (pending nil))
      (bt2:with-lock-held ((manager-lock manager))
        (check-manager-open manager)
        (setf session (gethash id (manager-session-table manager))
              pending (manager-pending-discard manager))
        (when (and pending (not (equal pending (list id expected-fingerprint))))
          (error "Retry the pending exact session cleanup before another deletion")))
      (when session
        (bt2:with-lock-held ((session-lock session))
          (unless (and (session-closed session)
                       (equal "closed" (field (session-cached-snapshot session) "status")))
            (error "Explicitly close this session before discarding its journal"))
          (when (some (lambda (worker) (bt2:thread-alive-p (car worker))) (session-workers session))
            (error "Session still owns live tool or cancellation workers; capacity remains reserved")))
        ;; Close receipts are published before the final actor drain. Waiting
        ;; here cannot block manager/snapshot reads on the editor thread.
        (bt2:join-thread (session-thread session)))
      (let* ((directory (store:ensure-private-directory (manager-directory manager) :create nil))
             (absent (null (store::path-stat (store::record-path directory id)))))
        (if (and absent pending)
            ;; A prior unlink may have completed before fsync failed. This exact
            ;; retry makes absence durable; no stale file can be silently skipped.
            (store::fsync-directory directory)
            (progn
              (multiple-value-bind (record fingerprint diagnostic) (read-session-journal manager id)
                (declare (ignore diagnostic))
                (unless (equal expected-fingerprint fingerprint)
                  (error "Session journal changed; inspect and confirm its current contents"))
                (when (and (uncertain-session-history-p record) (not acknowledge-uncertain))
                  (error "Explicitly acknowledge unknown outcomes before discarding this history")))
              (bt2:with-lock-held ((manager-lock manager))
                (setf (manager-pending-discard manager) (list (copy-seq id) (copy-seq expected-fingerprint))))
              (unless (store:discard-record directory id)
                (error "Session journal disappeared; retry this exact cleanup to confirm durable absence")))))
      (bt2:with-lock-held ((manager-lock manager))
        (setf (manager-pending-discard manager) nil)
        (remhash id (manager-session-table manager))
        (decf (manager-journal-count manager))
        (when (and (not session) (plusp (manager-unloaded-count manager)))
          (decf (manager-unloaded-count manager))))
      t)))
