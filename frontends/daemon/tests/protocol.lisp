(defpackage :lem-daemon/tests/protocol
  (:use :cl :rove)
  (:local-nicknames (:protocol :lem-daemon/protocol)))
(in-package :lem-daemon/tests/protocol)

(deftest message-round-trip
  (let* ((message (protocol:make-object
                   "version" protocol:+protocol-version+
                   "type" "eval"
                   "id" "42"
                   "form" "(+ 20 22)"))
         (bytes (protocol:encode-message message))
         (decoded (protocol:decode-message bytes)))
    (ok (= 1 (protocol:field decoded "version")))
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
