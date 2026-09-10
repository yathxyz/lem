(defpackage :lem-daemon/tests/protocol
  (:use :cl :rove)
  (:local-nicknames (:protocol :lem-daemon/protocol)
                    (:transport :lem-daemon/transport)))
(in-package :lem-daemon/tests/protocol)

(deftest message-round-trip
  (let* ((message (protocol:make-object
                   "version" protocol:+protocol-version+
                   "type" "eval"
                   "id" "42"
                   "form" "(+ 20 22)"))
         (bytes (protocol:encode-message message))
         (decoded (protocol:decode-message bytes)))
    (ok (= protocol:+protocol-version+ (protocol:field decoded "version")))
    (ok (string= "eval" (protocol:field decoded "type")))
    (ok (string= "(+ 20 22)" (protocol:field decoded "form")))))

(deftest framed-message-round-trip
  (let ((path (merge-pathnames
               (format nil "lem-daemon-protocol-~d.bin" (random 1000000000))
               (uiop:temporary-directory))))
    (unwind-protect
         (progn
           (with-open-file (out path :direction :output :element-type '(unsigned-byte 8)
                                     :if-exists :supersede)
             (protocol:write-message
              (protocol:make-object "type" "hello" "version" 1) out))
           (with-open-file (in path :direction :input :element-type '(unsigned-byte 8))
             (let ((message (protocol:read-message in)))
               (ok (string= "hello" (protocol:field message "type")))
               (ok (null (protocol:read-message in))))))
      (when (probe-file path) (delete-file path)))))

(deftest server-name-validation
  (dolist (name '("server" "work-2" "a.b_c"))
    (ok (protocol:valid-server-name-p name) name))
  (dolist (name '("" "../other" "/tmp/x" ".hidden" "white space"))
    (ng (protocol:valid-server-name-p name) name)))

(deftest daemon-display-cells
  (let ((row (lem-daemon::make-cell-row 6)))
    (lem-daemon::overlay-text row 0 "漢x")
    (let ((text (lem-daemon::cell-row-string row)))
      (ok (= 6 (lem-core:string-width text))
          "wide characters retain the requested terminal width")
      (ok (string= "漢x   " text)))
    (lem-daemon::overlay-text row 1 "ab")
    (let ((text (lem-daemon::cell-row-string row)))
      (ok (= 6 (lem-core:string-width text))
          "overwriting a wide-character continuation repairs the row")
      (ok (string= " ab   " text)))))

(deftest daemon-theme-interface
  (let ((implementation (make-instance 'lem-daemon:daemon-implementation)))
    (ng (lem/common/color:light-color-p
         (lem-if:get-background-color implementation)))
    (lem-if:update-background implementation "#ffffff")
    (lem-if:update-foreground implementation "#123456")
    (ok (lem/common/color:light-color-p
         (lem-if:get-background-color implementation)))
    (ok (lem/common/color:color-equal
         (lem/common/color:parse-color "#123456")
         (lem-if:get-foreground-color implementation)))))

(deftest styled-display-cells
  (let* ((row (lem-daemon::make-cell-row 6))
         (red (lem-daemon::drawing-face (lem:make-attribute :foreground "red" :bold t)))
         (green (lem-daemon::drawing-face (lem:make-attribute :foreground "green")))
         (text (format nil "漢e~c" (code-char #x301))))
    (lem-daemon::overlay-text row 0 text red)
    (let ((runs (lem-daemon::encode-face-runs
                 (lem-daemon::cell-row-cells row) (lem-daemon::cell-row-faces row))))
      (ok (= 1 (length runs)))
      (ok (equalp (vector 0 text "#FF0000" nil 1) (aref runs 0))
          "a wide character and combining mark remain in their styled run"))
    (lem-daemon::overlay-text row 1 "ab" green)
    (ok (string= " ab   " (lem-daemon::cell-row-string row)))
    (let ((runs (lem-daemon::encode-face-runs
                 (lem-daemon::cell-row-cells row) (lem-daemon::cell-row-faces row))))
      (ok (= 1 (length runs)))
      (ok (and (= 1 (aref (aref runs 0) 0))
               (string= "ab" (aref (aref runs 0) 1)))
          "overwriting a wide continuation clears the old glyph and face"))
    (lem-daemon::clear-cell-row row 1)
    (ok (zerop (length (lem-daemon::encode-face-runs
                       (lem-daemon::cell-row-cells row) (lem-daemon::cell-row-faces row))))
        "clearing text also removes its face")))

(deftest modeline-and-eol-faces
  (let* ((implementation (make-instance 'lem-daemon:daemon-implementation))
         (view (lem-daemon::make-daemon-view :width 8 :height 1))
         (attribute (lem:make-attribute :foreground "white" :background "blue"))
         (object (make-instance 'lem-core/display:text-object :string "Mode"
                                :attribute nil)))
    (lem-if:render-line-on-modeline implementation view (list object) nil attribute 1)
    (let ((row (gethash 1 (lem-daemon::daemon-view-grid view))))
      (ok (string= "Mode    " (lem-daemon::cell-row-string row)))
      (ok (every (lambda (face) (equal face '("#FFFFFF" "#0000FF" 0)))
                 (lem-daemon::cell-row-faces row))
          "the modeline's default face covers text and padding")
      (lem-daemon::render-object-into-row
       row 4 (make-instance 'lem-core/display:extend-to-eol-object
                            :color (lem/common/color:make-color 1 2 3)))
      (ok (equal '(nil "#010203" 0) (aref (lem-daemon::cell-row-faces row) 7))
          "end-of-line background fill preserves its color"))))

(deftest mouse-message-validation
  (flet ((down (&rest overrides)
           (let ((message (protocol:make-object "kind" "down" "x" 10 "y" 4
                                                 "button" 1 "clicks" 2)))
             (loop :for (key value) :on overrides :by #'cddr
                   :do (setf (gethash key message) value))
             message)))
    (let ((event (lem-daemon::decode-mouse-message (down))))
      (ok (typep event 'lem-core::mouse-button-down))
      (ok (and (= 10 (lem-core::mouse-event-x event))
               (= 4 (lem-core::mouse-event-y event))
               (= 2 (lem-core::mouse-button-down-clicks event))
               (eq :button-1 (lem-core::mouse-event-button event)))
          "mouse coordinates, button, and click count reach a core event"))
    (dolist (invalid '(("x" -1) ("x" 1000) ("y" "4")
                       ("button" 0) ("button" 5) ("clicks" 0) ("kind" "evaluate")))
      (ok (handler-case
              (progn (lem-daemon::decode-mouse-message (apply #'down invalid)) nil)
            (error () t))
          (format nil "invalid mouse input is rejected: ~s" invalid))))
  (let ((event (lem-daemon::decode-mouse-message
                (protocol:make-object "kind" "wheel" "x" 2 "y" 3 "dx" 0 "dy" -1))))
    (ok (and (typep event 'lem-core::mouse-wheel)
             (= -1 (lem-core::mouse-wheel-y event)))
        "wheel direction is preserved")))

(deftest yath-file-client-compatibility
  (flet ((key-command (keys)
           (alexandria:when-let
               ((prefix
                  (lem-core::keymap-find
                   lem-daemon::*daemon-edit-mode-keymap*
                   (lem-core::parse-keyspec keys))))
             (lem-core::prefix-suffix prefix))))
    (ok (eq 'lem-daemon:daemon-edit-save-and-done (key-command "Z Z"))
        "the yath save-and-finish key remains available")
    (ok (eq 'lem-daemon:daemon-edit-abort (key-command "Z Q"))
        "the yath abort key remains available")
    (ok (eq 'lem-daemon:daemon-edit-done (key-command "C-x #"))
        "the clean finish key remains available"))
  (ok (handler-case
          (progn (lem-daemon/client::build-file-entries '("+9")) nil)
        (error (condition)
          (search "must precede a file" (princ-to-string condition))))
      "a dangling location is rejected before connecting"))

#+(and sbcl linux)
(deftest unix-transport-lifecycle-safety
  (let* ((old-runtime (uiop:getenv "XDG_RUNTIME_DIR"))
         (root (merge-pathnames
                (format nil "lem-daemon-transport-~d-~d/"
                        (sb-posix:getpid) (random 1000000000))
                (uiop:temporary-directory)))
         (backend (transport:require-local-backend))
         (name (format nil "safety-~d" (random 1000000000)))
         (endpoint nil)
         (metadata nil)
         (listener nil))
    (unwind-protect
         (progn
           (ensure-directories-exist (merge-pathnames "marker" root))
           (setf (uiop:getenv "XDG_RUNTIME_DIR")
                 (uiop:native-namestring root)
                 endpoint (transport:local-endpoint backend name)
                 metadata (transport:local-metadata backend name))
           (ensure-directories-exist metadata)
           (let ((protected (merge-pathnames "protected.txt" root)))
             (with-open-file (stream protected :direction :output
                                                :if-exists :supersede)
               (write-string "protected" stream))
             (sb-posix:symlink (uiop:native-namestring protected)
                               (uiop:native-namestring metadata))
             (ok (handler-case
                     (progn
                       (transport:open-local-listener backend name 4)
                       nil)
                   (error () t))
                 "unsafe metadata is rejected")
             (ok (string= "protected" (uiop:read-file-string protected))
                 "metadata validation never follows an untrusted symlink")
             (delete-file metadata))

           (let ((stale (make-instance 'sb-bsd-sockets:local-socket
                                       :type :stream)))
             (unwind-protect
                  (sb-bsd-sockets:socket-bind
                   stale (uiop:native-namestring endpoint))
               (ignore-errors (sb-bsd-sockets:socket-close stale))))
           (setf listener (transport:open-local-listener backend name 4))
           (ok (probe-file endpoint) "a stale owned socket is recovered")
           (transport:close-local-listener listener)
           (setf listener nil)
           (ok (and (not (probe-file endpoint)) (not (probe-file metadata)))
               "closing a listener removes only its owned endpoint metadata")

           (setf listener (transport:open-local-listener backend name 4))
           (ok (handler-case
                   (progn
                     (transport:open-local-listener backend name 4)
                     nil)
                 (error () t))
               "a live daemon endpoint cannot be claimed")
           (ok (probe-file endpoint)
               "rejecting a duplicate daemon preserves the live endpoint"))
      (when listener (transport:close-local-listener listener))
      (setf (uiop:getenv "XDG_RUNTIME_DIR") old-runtime)
      (when (uiop:directory-exists-p root)
        (uiop:delete-directory-tree root :validate t)))))

#+(and sbcl linux)
(deftest alternate-editor-policy
  (let ((server (format nil "absent-~d-~d"
                        (sb-posix:getpid) (random 1000000000)))
        (alternate (format nil "~a --noinform --non-interactive --quit"
                           (first sb-ext:*posix-argv*))))
    (ok (= 0 (lem-daemon/client:run-client
              (list "--server-name" server
                    "--alternate-editor" alternate
                    "unavailable.txt")))
        "an explicit alternate editor is used when no daemon is reachable")
    (ok (handler-case
            (progn
              (lem-daemon/client:run-client
               (list "--server-name" server "unavailable.txt"))
              nil)
          (error () t))
        "the client does not start or choose an editor implicitly")))
