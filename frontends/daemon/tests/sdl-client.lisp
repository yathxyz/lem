(defpackage :lem-daemon/tests/sdl-client
  (:use :cl :rove)
  (:local-nicknames (:protocol :lem-daemon/protocol)
                    (:gui :lem-daemon/sdl-client)))
(in-package :lem-daemon/tests/sdl-client)

(defun wire-round-trip (message)
  (protocol:decode-message (protocol:encode-message message)))

(deftest incoming-wakes-once-per-batch
  (let* ((notifications 0)
         (incoming (gui::make-incoming :notify (lambda () (incf notifications)))))
    (gui::enqueue-screen-message incoming :first)
    (gui::enqueue-screen-message incoming :second)
    (ok (= 1 notifications) "pending messages share one wakeup")
    (ok (equal '(:first :second) (gui::take-messages incoming))
        "draining preserves wire order")
    (let ((failure (make-condition 'simple-error)))
      (gui::enqueue-screen-message incoming failure)
      (ok (= 2 notifications) "a reader error wakes an idle consumer")
      (ok (eq failure (first (gui::take-messages incoming)))))
    ;; A synchronous drain also proves notification runs outside the lock.
    (setf (gui::incoming-notify incoming)
          (lambda () (gui::take-messages incoming)))
    (gui::enqueue-screen-message incoming :third)
    (ok (null (gui::take-messages incoming)))
    (gui::stop-screen-reader incoming nil)
    (gui::enqueue-screen-message incoming :after-stop)
    (ok (null (gui::take-messages incoming)) "shutdown suppresses new messages")))

(deftest incoming-overflow-remains-visible
  (let ((incoming (gui::make-incoming)))
    (dotimes (i 256) (gui::enqueue-screen-message incoming i))
    (ok (handler-case
            (progn (gui::enqueue-screen-message incoming :overflow) nil)
          (error (condition)
            (gui::enqueue-screen-message incoming condition)
            t)))
    (let ((messages (gui::take-messages incoming)))
      (ok (= 257 (length messages)))
      (ok (typep (car (last messages)) 'error)
          "backpressure errors are delivered even when the queue is full"))))

(deftest graphical-screen-wire-format
  (let* ((screen (gui::make-graphical-screen))
         (row (lem-daemon::make-cell-row 8))
         (text (format nil "漢e~c" (code-char #x301))))
    (lem-daemon::overlay-text row 1 text '("#FF0000" "#0000FF" 3))
    (gui::update-screen
     screen (wire-round-trip
             (protocol:make-object
              "full" t "rows" (vector (lem-daemon::encode-screen-row row))
              "foreground" "#FFFFFF" "background" "#000000" "mouse" t)))
    (let ((decoded (aref (gui::graphical-screen-rows screen) 0)))
      (ok (equalp (lem-daemon::cell-row-cells row) (lem-daemon::cell-row-cells decoded))
          "JSON decoding preserves wide glyphs, combining marks, and columns")
      (ok (equalp (lem-daemon::cell-row-faces row) (lem-daemon::cell-row-faces decoded))
          "JSON decoding preserves styled cells")
      (ok (gui::graphical-screen-mouse-enabled screen)))
    (lem-daemon::overlay-text row 1 text '("#00FF00" nil 0))
    (gui::update-screen
     screen (wire-round-trip
             (protocol:make-object
              "changes" (vector (lem-daemon::encode-screen-row row 0))
              "foreground" "#FFFFFF" "background" "#000000")))
    (ok (equalp (lem-daemon::cell-row-faces row)
                 (lem-daemon::cell-row-faces (aref (gui::graphical-screen-rows screen) 0)))
        "a diff updates faces when the text is unchanged")
    (ok (handler-case
            (progn
              (gui::update-screen
               screen (protocol:make-object
                       "changes" (vector (lem-daemon::encode-screen-row row 9)))) nil)
          (error () t))
        "an out-of-bounds diff is a client error")))

#+(and sbcl linux)
(deftest graphical-reader-stops-without-peer-disconnect
  (let* ((old-runtime (uiop:getenv "XDG_RUNTIME_DIR"))
         (root (merge-pathnames
                (format nil "lem-gui-reader-~d-~d/" (sb-posix:getpid) (random 1000000000))
                (uiop:temporary-directory)))
         (backend (lem-daemon/transport:require-local-backend))
         (listener nil) (transport nil) (peer nil) (reader nil)
         (incoming (gui::make-incoming)))
    (unwind-protect
         (progn
           (setf (uiop:getenv "XDG_RUNTIME_DIR") (namestring root)
                 listener (lem-daemon/transport:open-local-listener backend "reader" 1)
                 transport (lem-daemon/transport:connect-local backend "reader")
                 peer (lem-daemon/transport:accept-local-connection listener))
           (let ((connection (make-instance 'lem-daemon/client::client-connection
                                            :transport transport
                                            :stream (lem-daemon/transport:local-connection-stream transport))))
             (setf reader (bt2:make-thread (lambda () (gui::read-screens connection incoming))
                                           :name "Graphical reader cancellation test"))
             (ok (loop :repeat 200
                       :when (gui::incoming-reader-started-p incoming) :return t
                       :do (sleep 0.01)))
             (sleep 0.05)
             (sb-ext:with-timeout 2
               (gui::stop-screen-reader incoming reader))
             (ok (not (bt2:thread-alive-p reader))
                 "cleanup cancels a blocked read while the daemon socket remains open")
             (ok (open-stream-p (lem-daemon/transport:local-connection-stream transport))
                 "the reader releases the stream before its owner closes it")
             (setf reader nil incoming (gui::make-incoming))
             (gui::stop-screen-reader incoming nil)
             (setf reader (bt2:make-thread (lambda () (gui::read-screens connection incoming))
                                           :name "Graphical reader early cancellation test"))
             (sb-ext:with-timeout 2 (bt2:join-thread reader))
             (ok (not (gui::incoming-reader-started-p incoming))
                 "cancellation before reader startup prevents a new blocking read")))
      (when reader (gui::stop-screen-reader incoming reader))
      (when transport (lem-daemon/transport:close-local-connection transport))
      (when peer (lem-daemon/transport:close-local-connection peer))
      (when listener (lem-daemon/transport:close-local-listener listener))
      (setf (uiop:getenv "XDG_RUNTIME_DIR") old-runtime)
      (when (uiop:directory-exists-p root)
        (uiop:delete-directory-tree root :validate t)))))


#+sbcl
(deftest graphical-runtime-restores-native-float-traps
  (let ((original-init (symbol-function 'sdl2:init*))
        (original-window (symbol-function 'gui::call-with-graphical-window))
        (original-quit (symbol-function 'sdl2:quit*))
        (original-modes (sb-int:get-floating-point-modes)))
    (unwind-protect
         (dolist (failure '(nil :initialization :window :cleanup))
           (sb-int:set-floating-point-modes :traps '(:invalid :overflow :divide-by-zero))
           (let ((traps (getf (sb-int:get-floating-point-modes) :traps))
                 (expected (when failure
                             (make-condition 'simple-error :format-control "Injected ~a failure"
                                                           :format-arguments (list failure))))
                 (calls nil) (result nil) (condition nil))
             (flet ((native-call (phase)
                      (push phase calls)
                      ;; Native graphics libraries expect IEEE NaNs, not a
                      ;; Lisp condition, when their calculations raise invalid.
                      (ok (sb-ext:float-nan-p
                           (cffi:foreign-funcall "sqrt" :double -1d0 :double))
                          "native floating-point exceptions are masked")
                      (when (eq phase failure) (error expected))))
               (setf (symbol-function 'sdl2:init*)
                     (lambda (flags) (declare (ignore flags)) (native-call :initialization) 0)
                     (symbol-function 'gui::call-with-graphical-window)
                     (lambda (&rest arguments)
                       (declare (ignore arguments))
                       (native-call :window)
                       (values 37 :second-value))
                     (symbol-function 'sdl2:quit*)
                     (lambda () (native-call :cleanup)))
               (handler-case
                   (setf result (multiple-value-list (gui:run-graphical nil nil nil)))
                 (error (error) (setf condition error))))
             (if failure
                 (ok (eq condition expected) "the original SDL failure propagates")
                 (ok (and (null condition) (equal result '(37 :second-value)))
                     "normal return preserves all values"))
             (ok (equal (reverse calls)
                        (if (eq failure :initialization)
                            '(:initialization)
                            '(:initialization :window :cleanup)))
                 "cleanup runs only after successful initialization")
             (ok (equal traps (getf (sb-int:get-floating-point-modes) :traps))
                 "caller traps are restored on normal and exceptional exits")))
      (setf (symbol-function 'sdl2:init*) original-init
            (symbol-function 'gui::call-with-graphical-window) original-window
            (symbol-function 'sdl2:quit*) original-quit)
      (apply #'sb-int:set-floating-point-modes original-modes))))
