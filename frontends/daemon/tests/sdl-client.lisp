(defpackage :lem-daemon/tests/sdl-client
  (:use :cl :rove)
  (:local-nicknames (:protocol :lem-daemon/protocol)
                    (:gui :lem-daemon/sdl-client)))
(in-package :lem-daemon/tests/sdl-client)

(defun wire-round-trip (message)
  (protocol:decode-message (protocol:encode-message message)))

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
