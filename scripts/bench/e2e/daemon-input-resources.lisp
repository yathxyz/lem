(defpackage :lem-bench/daemon-input-resources
  (:use :cl)
  (:local-nicknames (:daemon :lem-daemon) (:protocol :lem-daemon/protocol))
  (:export :start :stop))
(in-package :lem-bench/daemon-input-resources)

;; Loaded only into a disposable daemon by daemon-input.py --resources.
;; The driver permits one outstanding input and validates the returned input ID.
;; Wrap internal entry points here to keep instrumentation out of production.
(defvar *stop-capture* nil)

(defun stop ()
  "Restore the daemon functions replaced by this private diagnostic."
  (when *stop-capture* (funcall *stop-capture*)))

(defun start ()
  "Add receive-to-screen resource counters to the typing probe's screen messages.
Counters are process-wide; GC CPU time is not a wall-clock pause measurement.
The screen endpoint precedes encoding, queueing and socket writing. Instrumented
results include this diagnostic's allocations and synchronization overhead."
  (when *stop-capture* (error "Daemon resource capture is already active"))
  (let ((inputs (make-hash-table :test 'eq))
        (lock (bt2:make-lock :name "daemon benchmark inputs"))
        (handle (symbol-function 'daemon::handle-message))
        (send (symbol-function 'daemon::daemon-send)))
    (setf (symbol-function 'daemon::handle-message)
          (lambda (connection message)
            (when (equal "input" (protocol:field message "type"))
              (let ((sample (vector (protocol:field message "id")
                                    (get-internal-real-time)
                                    (get-internal-run-time)
                                    sb-ext:*gc-run-time*
                                    (sb-ext:get-bytes-consed))))
                (bt2:with-lock-held (lock)
                  (setf (gethash connection inputs) sample))))
            (funcall handle connection message))
          (symbol-function 'daemon::daemon-send)
          (lambda (connection message)
            (when (equal "screen" (protocol:field message "type"))
              (alexandria:when-let
                  ((input (bt2:with-lock-held (lock) (gethash connection inputs))))
                (setf (gethash "benchmark" message)
                      (protocol:make-object
                       "input-id" (aref input 0)
                       "units-per-second" internal-time-units-per-second
                       "received-wall" (aref input 1)
                       "received-cpu" (aref input 2)
                       "received-gc-cpu" (aref input 3)
                       "received-consed" (aref input 4)
                       "screen-wall" (get-internal-real-time)
                       "screen-cpu" (get-internal-run-time)
                       "screen-gc-cpu" sb-ext:*gc-run-time*
                       "screen-consed" (sb-ext:get-bytes-consed)))))
            (funcall send connection message))
          *stop-capture*
          (lambda ()
            (setf (symbol-function 'daemon::handle-message) handle
                  (symbol-function 'daemon::daemon-send) send
                  *stop-capture* nil))))
  t)
