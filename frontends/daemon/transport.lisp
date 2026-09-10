(in-package :lem-daemon/transport)

(defclass local-backend () ())
(defclass local-listener () ())
(defclass local-connection () ())

(define-condition local-endpoint-in-use (error)
  ((endpoint :initarg :endpoint :reader local-endpoint-in-use-endpoint))
  (:report (lambda (condition stream)
             (format stream "A daemon is already running at ~a"
                     (local-endpoint-in-use-endpoint condition)))))

(defvar *local-backend* nil)

(defun require-local-backend ()
  (or *local-backend*
      (error "No secure local daemon transport is available on this platform")))

(defgeneric backend-process-id (backend))
(defgeneric local-endpoint (backend server-name))
(defgeneric local-metadata (backend server-name))
(defgeneric open-local-listener (backend server-name backlog))
(defgeneric local-listener-endpoint (listener))
(defgeneric accept-local-connection (listener))
(defgeneric connect-local (backend server-name))
(defgeneric local-connection-stream (connection))
(defgeneric close-local-connection (connection))
(defgeneric close-local-listener (listener))
