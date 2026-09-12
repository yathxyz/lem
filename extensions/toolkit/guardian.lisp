;;;; Stock SBCL, one Lisp thread, no Quicklisp or user init. All child ownership is
;;;; explicit: no SBCL RUN-PROGRAM registrations or automatic child reaping here.
(require :sb-posix)
(load (merge-pathnames "wire.lisp" *load-truename*))
(defpackage :lem-toolkit/jobs-guardian
  (:use :cl) (:local-nicknames (:wire :lem-toolkit/jobs-wire)))
(in-package :lem-toolkit/jobs-guardian)

(sb-alien:define-alien-routine ("prctl" %prctl) sb-alien:int
  (option sb-alien:int) (arg2 sb-alien:unsigned-long) (arg3 sb-alien:unsigned-long)
  (arg4 sb-alien:unsigned-long) (arg5 sb-alien:unsigned-long))
(sb-alien:define-alien-routine ("execvp" %execvp) sb-alien:int
  (program (* sb-alien:char)) (arguments (* (* sb-alien:char))))

(defvar *watchdog* nil)
(defvar *watchdog-reaped* nil)
(defvar *anchor* nil)
(defvar *heartbeat* nil)
(defvar *protocol-output* nil)
(defvar *control-input* nil)
(defvar *cleaned* nil)

(defun binary-stream (fd direction &optional (auto-close nil))
  (sb-sys:make-fd-stream fd :input (eq direction :input) :output (eq direction :output)
                        :element-type '(unsigned-byte 8) :buffering :none :auto-close auto-close))
(defun close-fd (fd) (when fd (ignore-errors (sb-posix:close fd))))
(defun make-pipe () (multiple-value-list (sb-posix:pipe)))
(defun read-byte-required (fd)
  (or (read-byte (binary-stream fd :input) nil) (error "Ownership pipe closed")))
(defun send-byte (fd byte)
  (let ((stream (binary-stream fd :output))) (write-byte byte stream) (finish-output stream)))
(defun null-stdio ()
  (let ((fd (sb-posix:open "/dev/null" sb-posix:o-rdwr)))
    (dotimes (target 3) (sb-posix:dup2 fd target))
    (unless (< fd 3) (close-fd fd))))
(defun close-fds-except (allowed)
  (dolist (path (directory "/proc/self/fd/*" :resolve-symlinks nil))
    (let* ((name (string-right-trim "/" (namestring path)))
           (fd (parse-integer name :start (1+ (position #\/ name :from-end t)) :junk-allowed t)))
      (when (and fd (not (member fd allowed))) (close-fd fd)))))
(defun protect-parent (parent)
  (unless (zerop (%prctl 1 sb-posix:sigkill 0 0 0)) (error "Cannot protect process startup"))
  (unless (= parent (sb-posix:getppid)) (sb-ext:exit :code 125 :abort t)))
(defun signal-owned (pid group)
  ;; Call only before reaping an owned direct child (or an adopted anchor).
  (handler-case (sb-posix:kill (if group (- pid) pid) sb-posix:sigkill)
    (sb-posix:syscall-error (condition)
      (unless (= sb-posix:esrch (sb-posix:syscall-errno condition)) (error condition)))))

(defun alien-strings (values)
  (let ((array (sb-alien:make-alien (* sb-alien:char) (1+ (length values)))))
    (loop for value in values for i from 0 do
      (setf (sb-alien:deref array i) (sb-alien:make-alien-string value :external-format :utf-8)))
    (setf (sb-alien:deref array (length values))
          (sb-alien:sap-alien (sb-sys:int-sap 0) (* sb-alien:char)))
    array))

(defun exec-command (argv directory environment input output errors ready gate parent)
  (protect-parent parent)
  (sb-posix:dup2 input 0) (sb-posix:dup2 output 1) (sb-posix:dup2 errors 2)
  (close-fds-except (list 0 1 2 ready gate))
  (sb-posix:chdir directory)
  (let ((arguments (alien-strings argv)) (environment (alien-strings environment)))
    (dolist (signal (list sb-posix:sigpipe sb-posix:sigint sb-posix:sigquit
                          sb-posix:sigterm sb-posix:sighup sb-posix:sigchld))
      (sb-sys:enable-interrupt signal :default))
    (send-byte ready (char-code #\R)) (close-fd ready)
    (read-byte-required gate) (close-fd gate)
    ;; Project environment is installed only in this gated exec child. It cannot
    ;; affect SBCL startup, the watchdog, anchor, broker, or their dynamic loaders.
    (setf (sb-alien:extern-alien "environ" (* (* sb-alien:char))) environment)
    (%execvp (sb-alien:deref arguments 0) arguments)
    (write-string "Managed job executable could not be started." *error-output*)
    (terpri *error-output*) (finish-output *error-output*)
    (sb-ext:exit :code 127 :abort t)))

(defun run-anchor (argv directory environment input output errors status ready gate parent)
  (protect-parent parent)
  (sb-posix:setpgid 0 0)
  (send-byte ready (char-code #\R)) (close-fd ready)
  (read-byte-required gate) (close-fd gate)
  (let* ((command-ready (make-pipe)) (command-gate (make-pipe))
         (anchor (sb-posix:getpid)) (child (sb-posix:fork)))
    (when (zerop child)
      (handler-case
          (exec-command argv directory environment input output errors (second command-ready) (first command-gate) anchor)
        (error () (sb-ext:exit :code 125 :abort t))))
    (close-fd (second command-ready)) (close-fd (first command-gate))
    (close-fd input) (close-fd output) (close-fd errors)
    (read-byte-required (first command-ready)) (close-fd (first command-ready))
    ;; Queue RUNNING before the command can execute, including startup hooks that
    ;; stop their parent or entire group. The outside broker can always cancel.
    (wire:write-frame #\R #() (binary-stream status :output))
    (send-byte (second command-gate) (char-code #\S)) (close-fd (second command-gate))
    (multiple-value-bind (pid wait-status) (sb-posix:waitpid child 0)
      (unless (= pid child) (error "Wrong command child"))
      (wire:write-frame
       #\X (wire:utf8 (if (sb-posix:wifexited wait-status)
                          (format nil "exited ~d" (sb-posix:wexitstatus wait-status))
                          (format nil "signaled ~d" (sb-posix:wtermsig wait-status))))
       (binary-stream status :output)))
    ;; Keep the identity reserved until group cleanup, even after target exit.
    (loop (sleep 3600))))

(defun run-watchdog (argv directory environment input output errors heartbeat status)
  (let ((anchor nil) (group-ready nil))
    (unwind-protect
         (handler-case
             (progn
               (sb-posix:setpgid 0 0)
               (null-stdio)
               (close-fds-except (list 0 1 2 input output errors heartbeat status))
               (when (sb-sys:wait-until-fd-usable heartbeat :input 0 nil)
                 (error "Controller ended before launch"))
               (let ((ready (make-pipe)) (gate (make-pipe)) (parent (sb-posix:getpid)))
                 (setf anchor (sb-posix:fork))
                 (when (zerop anchor)
                   (close-fd heartbeat) (close-fd (first ready)) (close-fd (second gate))
                   (handler-case
                       (run-anchor argv directory environment input output errors status (second ready) (first gate) parent)
                     (error (condition)
                       (ignore-errors (wire:write-frame #\F (wire:utf8 (princ-to-string condition)) (binary-stream status :output)))
                       (sb-ext:exit :code 125 :abort t))))
                 (close-fd (second ready)) (close-fd (first gate))
                 (read-byte-required (first ready)) (close-fd (first ready))
                 (setf group-ready t)
                 (wire:write-frame #\A (wire:utf8 (write-to-string anchor)) (binary-stream status :output))
                 (send-byte (second gate) (char-code #\S)) (close-fd (second gate)))
               (close-fd input) (close-fd output) (close-fd errors) (close-fd status)
               (read-byte (binary-stream heartbeat :input) nil))
           (error (condition)
             (ignore-errors (wire:write-frame #\F (wire:utf8 (princ-to-string condition)) (binary-stream status :output)))))
      (when (and anchor (plusp anchor)) (ignore-errors (signal-owned anchor group-ready)))
      ;; NEVER reap the anchor. The broker is a subreaper, so watchdog exit or
      ;; failure transfers ownership without making the anchor PID reusable.
      (sb-ext:exit :code 0 :abort t))))

(defun cleanup-owned ()
  (unless *cleaned*
    (setf *cleaned* t)
    (close-fd *heartbeat*) (setf *heartbeat* nil)
    (when (and *watchdog* (not *watchdog-reaped*))
      (ignore-errors (sb-posix:waitpid *watchdog* 0)) (setf *watchdog-reaped* t))
    (when *anchor*
      ;; After watchdog exit this unreaped anchor is our adopted direct child.
      (ignore-errors (signal-owned *anchor* t))
      (ignore-errors (sb-posix:waitpid *anchor* 0)) (setf *anchor* nil))
    (loop (multiple-value-bind (pid status) (ignore-errors (sb-posix:waitpid -1 sb-posix:wnohang))
            (declare (ignore status)) (unless (and pid (plusp pid)) (return))))))

(defun finish (state code)
  (cleanup-owned)
  (ignore-errors (wire:write-frame #\X (wire:utf8 (format nil "~a ~d" state code)) *protocol-output*))
  (sb-ext:exit :code 0 :abort t))

(defun read-ready-octets (fd buffer)
  (when (sb-sys:wait-until-fd-usable fd :input 0 nil)
    (sb-sys:with-pinned-objects (buffer)
      (sb-posix:read fd (sb-sys:vector-sap buffer) (length buffer)))))

(defun guardian-main ()
  (unless (= 1 (length (sb-thread:list-all-threads))) (error "Guardian must have one Lisp thread"))
  (sb-sys:enable-interrupt sb-posix:sigchld :default)
  (unless (zerop (%prctl 36 1 0 0 0)) (error "Cannot establish child subreaper"))
  (setf *protocol-output* (binary-stream 1 :output) *control-input* (binary-stream 0 :input))
  (multiple-value-bind (tag payload) (wire:read-frame *control-input*)
    (unless (eql tag #\L) (error "Expected launch frame"))
    (multiple-value-bind (argv directory timeout-ms input-bytes environment) (wire:decode-launch payload)
      (let* ((stdout (make-pipe)) (stderr (make-pipe)) (stdin (make-pipe))
             (heartbeat (make-pipe)) (status (make-pipe))
             (status-input (binary-stream (first status) :input))
             (deadline (+ (get-internal-real-time) (* (/ timeout-ms 1000) internal-time-units-per-second)))
             (buffer (make-array 4096 :element-type '(unsigned-byte 8)))
             (output-open t) (error-open t) (input-open t) (input-offset 0))
        (setf *watchdog* (sb-posix:fork))
        (when (zerop *watchdog*)
          (run-watchdog argv directory environment (first stdin) (second stdout) (second stderr)
                        (first heartbeat) (second status)))
        (setf *heartbeat* (second heartbeat))
        (close-fd (first heartbeat)) (close-fd (second status))
        (close-fd (first stdin)) (close-fd (second stdout)) (close-fd (second stderr))
        (sb-posix:fcntl (second stdin) sb-posix:f-setfl sb-posix:o-nonblock)
        (labels ((drain (fd tag)
                   (let ((n (read-ready-octets fd buffer)))
                     (cond ((null n) (values t 0)) ((zerop n) (values nil 0))
                           (t (wire:write-frame tag (subseq buffer 0 n) *protocol-output*) (values t n))))))
          (loop
            (when (or (listen *control-input*) (sb-sys:wait-until-fd-usable 0 :input 0 nil))
              (if (eql (read-byte *control-input* nil) (char-code #\K))
                  (finish "cancelled" 9) (finish "interrupted" 9)))
            (when (>= (get-internal-real-time) deadline) (finish "timed-out" 9))
            ;; Read announcement before checking watchdog death: queued frames
            ;; identify an anchor adopted from a just-killed watchdog.
            (when (or (listen status-input) (sb-sys:wait-until-fd-usable (first status) :input 0 nil))
              (multiple-value-bind (kind bytes) (wire:read-frame status-input)
                (case kind
                  (#\F (error "Child debug: ~a" (wire:text bytes)))
                  (#\A (when *anchor* (error "Duplicate command anchor"))
                       (setf *anchor* (parse-integer (wire:text bytes)))
                       (unless (> *anchor* 1) (error "Invalid command anchor")))
                  (#\R (unless *anchor* (error "Command lacks owned anchor"))
                       (wire:write-frame #\R #() *protocol-output*))
                  (#\X
                   ;; Stop descendants first, then consume the pipe contents to
                   ;; EOF. An escaped writer or an abnormally enlarged pipe must
                   ;; not turn bounded draining into silent successful truncation.
                   (cleanup-owned)
                   (let ((drain-deadline (+ (get-internal-real-time)
                                            (* 1/2 internal-time-units-per-second))))
                     (loop repeat 1024
                           while (and (or output-open error-open)
                                      (< (get-internal-real-time) drain-deadline))
                           do (let ((progress 0))
                                (when output-open
                                  (multiple-value-bind (open count) (drain (first stdout) #\O)
                                    (setf output-open open) (incf progress count)))
                                (when error-open
                                  (multiple-value-bind (open count) (drain (first stderr) #\E)
                                    (setf error-open open) (incf progress count)))
                                (when (and (zerop progress) (or output-open error-open)) (sleep 0.001)))))
                   (when (or output-open error-open)
                     (wire:write-frame #\F (wire:utf8 "Output drain incomplete after group cleanup") *protocol-output*)
                     (finish "failed" 125))
                   (let* ((text (wire:text bytes)) (space (position #\Space text)))
                     (unless space (error "Invalid command result"))
                     (finish (subseq text 0 space) (parse-integer text :start (1+ space)))))
                  (t (error "Command anchor status ended unexpectedly")))))
            (multiple-value-bind (pid wait-status) (sb-posix:waitpid *watchdog* sb-posix:wnohang)
              (declare (ignore wait-status))
              (when (plusp pid) (setf *watchdog-reaped* t) (error "Managed job watchdog exited unexpectedly")))
            (when input-open
              (if (= input-offset (length input-bytes))
                  (progn (close-fd (second stdin)) (setf input-open nil))
                  (when (sb-sys:wait-until-fd-usable (second stdin) :output 0 nil)
                    (handler-case
                        (sb-sys:with-pinned-objects (input-bytes)
                          (incf input-offset
                                (sb-posix:write (second stdin)
                                                (sb-sys:sap+ (sb-sys:vector-sap input-bytes) input-offset)
                                                (min 4096 (- (length input-bytes) input-offset)))))
                      (sb-posix:syscall-error (condition)
                        (case (sb-posix:syscall-errno condition)
                          (11 nil) (32 (close-fd (second stdin)) (setf input-open nil))
                          (t (error condition))))))))
            (loop repeat 16 do
              (when output-open (setf output-open (drain (first stdout) #\O)))
              (when error-open (setf error-open (drain (first stderr) #\E))))
            (sleep 0.005)))))))

(unwind-protect
     (handler-case (guardian-main)
       (error (condition)
         (format *error-output* "Guardian debug: ~a~%" condition)
         (cleanup-owned)
         (ignore-errors (wire:write-frame #\F (wire:utf8 "Managed job guardian or anchor failed") *protocol-output*))
         (finish "failed" 125)))
  (cleanup-owned))
