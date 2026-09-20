(in-package :lem-core)

(defvar *editor-event-queue* (make-concurrent-queue))

(defstruct (routed-input-event
             (:constructor make-routed-input-event (session prepare event)))
  session prepare event)

(defvar *routed-input-session* nil)
(defvar *deferred-routed-input-events* '())

(defun finish-routed-input-session ()
  (setf *routed-input-session* nil))

(defun cancel-routed-input-session (session)
  (when (eq session *routed-input-session*)
    (setf *routed-input-session* nil)
    (error 'editor-abort)))

(defun event-queue-length ()
  (len *editor-event-queue*))

(defun send-event (obj)
  (enqueue *editor-event-queue* obj))

(defun send-abort-event (editor-thread force)
  (bt2:interrupt-thread editor-thread
                       (lambda ()
                         (interrupt force))))

(defun receive-event (timeout)
  (loop
    (let ((e (note-event-dequeued
              (if (and (null *routed-input-session*)
                       *deferred-routed-input-events*)
                  (pop *deferred-routed-input-events*)
                  (dequeue *editor-event-queue*
                           :timeout timeout
                           :timeout-value :timeout))))
          (deferred-p nil)
          (routed-callback-p nil)
          (previous-session *routed-input-session*))
      (when (routed-input-event-p e)
        (cond
          ((and *routed-input-session*
                (not (eq *routed-input-session*
                         (routed-input-event-session e))))
           (setf *deferred-routed-input-events*
                 (nconc *deferred-routed-input-events* (list e)))
           (setf deferred-p t))
          (t
           (setf *routed-input-session* (routed-input-event-session e))
           (funcall (routed-input-event-prepare e))
           ;; A peer deferred by a synchronous command must not overwrite that
           ;; command's timestamps. Start its timing only after routing succeeds.
           (setf e (note-event-dequeued (routed-input-event-event e))
                 routed-callback-p (or (functionp e) (symbolp e))))))
      (cond (deferred-p nil)
            ((null e) (return nil))
            ((eql e :timeout)
             (assert timeout)
             (return nil))
            ((eql e :resize)
             (when (>= 1 (event-queue-length))
               (update-on-display-resized)))
            ((or (functionp e) (symbolp e))
             (unwind-protect (funcall e)
               ;; A routed paste/callback completes here, while a key or mouse
               ;; command retains ownership until the interpreter completes it.
               (when routed-callback-p
                 (setf *routed-input-session* previous-session))))
            (t
             (return e))))))
