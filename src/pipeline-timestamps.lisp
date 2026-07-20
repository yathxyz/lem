(in-package :lem-core)

;;;; Input->paint pipeline timestamps (SPEC-PERF PF-2).
;;;;
;;;; Five monotonic timestamps are threaded through the keystroke pipeline so
;;;; end-to-end latency decomposes into attributable stages:
;;;;
;;;;   t0  input arrives in-process     (frontend input thread: tty bytes
;;;;                                     read on ncurses, key RPC received
;;;;                                     on lem-server/webview)
;;;;   t1  event enqueued via send-event (frontend input thread)
;;;;   t2  event dequeued               (editor thread, receive-event)
;;;;   t3  command dispatch returns      (editor thread, command loop)
;;;;   t4  redisplay done               (editor thread, redraw-display)
;;;;
;;;; and the stage deltas are recorded into the T0 histograms:
;;;;
;;;;   queue-wait = t2-t1    command = t3-t2    redisplay = t4-t3
;;;;   keystroke  = t4-t1    (the input-event -> paint proxy)
;;;;
;;;; t0/t1 cross the thread boundary attached to a `pipeline-event' wrapper on
;;;; the event queue (this changes no `lem-core' API: the wrapper is unwrapped
;;;; in `receive-event' before any consumer sees it).  t2/t3/t4 are editor-
;;;; thread state, touched only from the single command loop.  The ncurses and
;;;; lem-server (webview) input paths wrap key events; any other queue producer
;;;; enqueues raw events, never sets t0/t1, and every note below is guarded off
;;;; for it.  On webview, t4 is core paint done -- the browser's own render
;;;; falls outside the pipeline, so keystroke there is not glass-to-glass.
;;;;
;;;; The histogram backend (`lem/metrics') is loaded after this file, so the
;;;; recording is reached through an installed sink function rather than a
;;;; compile-time reference; when no backend is installed every note is a cheap
;;;; no-op (SPEC-PERF Constraint 4).

(declaim (inline pipeline-now))
(defun pipeline-now ()
  "Current value of a process-wide monotonic clock, in microseconds.
The same clock is read on the input and editor threads, so cross-thread
stage deltas are meaningful."
  (declare (optimize (speed 3) (safety 0)))
  #.(if (= internal-time-units-per-second 1000000)
        '(get-internal-real-time)
        '(values (truncate (* (get-internal-real-time) 1000000)
                           internal-time-units-per-second))))

(defstruct (pipeline-event (:constructor make-pipeline-event (payload t0 t1)))
  "Carries an input event (a key) from a frontend input thread across the
event queue together with its pipeline timestamps T0 (input arrived
in-process) and T1 (enqueued).  `receive-event' unwraps it, recording the
queue wait and retaining the stamps for the command and redisplay stages;
the ncurses and lem-server key paths produce these, and every other queue
producer enqueues raw events that pass through unchanged."
  (payload nil)
  (t0 0 :type fixnum)
  (t1 0 :type fixnum))

;;; Editor-thread in-flight stamps.  These are process-global specials but are
;;; written and read only from the single editor command loop, so they need no
;;; synchronisation; NIL means "no timestamped keystroke is in flight".
(defvar *pipeline-t1* nil "Enqueue time (t1) of the in-flight keystroke, or NIL.")
(defvar *pipeline-t2* nil "Dequeue time (t2) of the in-flight keystroke, or NIL.")
(defvar *pipeline-t3* nil "Command-done time (t3), set while a redisplay is pending.")

(defvar *pipeline-recorder* nil
  "NIL, or a function of (STAGE VALUE NAME) installed by the telemetry backend
to receive pipeline stage measurements (STAGE is one of :queue-wait, :command,
:redisplay, :keystroke; VALUE is microseconds; NAME is the command symbol for
:command and NIL otherwise).  When NIL, no backend is recording and every
pipeline note is a cheap no-op.")

(defun set-pipeline-recorder (function)
  "Install FUNCTION as the pipeline stage sink, or NIL to uninstall it.
Called by the telemetry backend as recording turns on or off."
  (setf *pipeline-recorder* function))

(declaim (inline pipeline-recording-p))
(defun pipeline-recording-p ()
  "True when a telemetry backend is installed and recording pipeline stages.
Frontends read this to skip timestamp capture entirely when telemetry is off."
  (and *pipeline-recorder* t))

(defun note-event-dequeued (event)
  "Handle EVENT as it is pulled off the event queue by `receive-event'.
When EVENT is a `pipeline-event' (a timestamped key), record its
queue wait (t2-t1), retain its stamps for the command/redisplay stages, and
return the unwrapped payload.  Any other object is returned unchanged."
  (if (pipeline-event-p event)
      (let ((recorder *pipeline-recorder*))
        (when recorder
          (let ((t1 (pipeline-event-t1 event))
                (t2 (pipeline-now)))
            (setf *pipeline-t1* t1
                  *pipeline-t2* t2
                  *pipeline-t3* nil)
            (funcall recorder :queue-wait (- t2 t1) nil)))
        (pipeline-event-payload event))
      event))

(defun pipeline-command-name (command)
  "The symbol naming COMMAND, whether COMMAND is a command symbol or a
`primary-command' instance."
  (if (symbolp command)
      command
      (command-name command)))

(defun note-command-done (command)
  "Record the command stage (t3-t2) for COMMAND, keyed by its name, and
retain t3 for the redisplay stage.  A no-op unless a timestamped keystroke is
in flight (t2 set)."
  (let ((recorder *pipeline-recorder*)
        (t2 *pipeline-t2*))
    (when (and recorder t2)
      (let ((t3 (pipeline-now)))
        (setf *pipeline-t3* t3)
        (funcall recorder :command (- t3 t2) (pipeline-command-name command))))))

(defun note-redisplay-done ()
  "Charge the current redisplay to the in-flight keystroke, if any: record
the redisplay stage (t4-t3) and the end-to-end keystroke latency (t4-t1),
then clear the in-flight stamps so each keystroke is charged exactly once.
A no-op for redisplays that were not driven by a keystroke command."
  (let ((recorder *pipeline-recorder*))
    (when recorder
      (let ((t1 *pipeline-t1*)
            (t3 *pipeline-t3*))
        (when (and t1 t3)
          (let ((t4 (pipeline-now)))
            (funcall recorder :redisplay (- t4 t3) nil)
            (funcall recorder :keystroke (- t4 t1) nil)
            (setf *pipeline-t1* nil
                  *pipeline-t2* nil
                  *pipeline-t3* nil)))))))

(defun send-input-event (event read-time)
  "Enqueue an input EVENT read by a frontend input thread.  READ-TIME is the
t0 stamp (monotonic microseconds at which the input arrived in-process), or
NIL when telemetry is off.  Key events are wrapped with pipeline timestamps so
the editor thread can decompose their input->paint latency; every other event
is enqueued verbatim, leaving non-key events and frontends that never pass a
READ-TIME unaffected."
  (if (and read-time (key-p event))
      (send-event (make-pipeline-event event read-time (pipeline-now)))
      (send-event event)))
