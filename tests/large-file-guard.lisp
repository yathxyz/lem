(defpackage :lem-tests/large-file-guard
  (:use :cl :rove)
  (:import-from :lem-fake-interface
                :with-fake-interface))
(in-package :lem-tests/large-file-guard)

;;; PI-2: files above `large-file-threshold' open in fundamental mode with syntax
;;; highlighting and expensive mode hooks off, after a y/n prompt on the
;;; find-file path. Declining opens nothing (no half-created buffer); small files
;;; keep their normal mode; the threshold is configurable and NIL disables it.

(defun write-file-of-size (path bytes)
  "Write PATH filled with BYTES bytes of ASCII content."
  (with-open-file (stream path
                          :direction :output
                          :if-exists :supersede
                          :if-does-not-exist :create)
    (loop :repeat bytes :do (write-char #\a stream))))

(defmacro with-temp-file ((path type size) &body body)
  "Bind PATH to a fresh temp file with extension TYPE, filled to SIZE bytes."
  `(let ((,path (uiop:with-temporary-file (:pathname p :type ,type :keep t) p)))
     (unwind-protect
          (progn (write-file-of-size ,path ,size)
                 ,@body)
       (uiop:delete-file-if-exists ,path))))

(defmacro with-threshold ((bytes) &body body)
  "Set `large-file-threshold' to BYTES for the dynamic extent of BODY."
  (let ((old (gensym)))
    `(let ((,old (lem:variable-value 'lem:large-file-threshold :global)))
       (unwind-protect
            (progn
              (setf (lem:variable-value 'lem:large-file-threshold :global) ,bytes)
              ,@body)
         (setf (lem:variable-value 'lem:large-file-threshold :global) ,old)))))

(defun open-file (path)
  "Open PATH through the find-file path the way `find-file' does, with mode
detection active. The real editor installs PROCESS-FILE on the find-file hook at
startup; the headless test harness does not, so bind it locally here."
  (let ((lem:*find-file-hook* (list (cons 'lem-core::process-file 5000))))
    (lem:execute-find-file lem:*find-file-executor*
                           (lem:get-file-mode (namestring path))
                           (namestring path))))

(defun visiting-buffer (path)
  (lem:get-file-buffer (namestring path)))

(deftest accepting-opens-large-file-in-fundamental-mode
  (with-fake-interface ()
    ;; A .sh file would normally open in posix-shell-mode with highlighting on.
    (with-threshold (1024)
      (with-temp-file (path "sh" 4096)
        (lem:unread-key (lem:make-key :sym "y"))
        (let ((buffer (open-file path)))
          (unwind-protect
               (progn
                 (ok (lem:bufferp buffer)
                     "accepting the prompt opens the file")
                 (ok (eq 'lem/buffer/fundamental-mode:fundamental-mode
                         (lem:buffer-major-mode buffer))
                     "large file opens in fundamental mode, not its detected mode")
                 (ok (null (lem:variable-value 'lem:enable-syntax-highlight
                                               :buffer buffer))
                     "syntax highlighting stays off for the large file"))
            (when (lem:bufferp buffer) (lem:delete-buffer buffer))))))))

(deftest declining-leaves-no-buffer
  (with-fake-interface ()
    (with-threshold (1024)
      (with-temp-file (path "sh" 4096)
        (lem:unread-key (lem:make-key :sym "n"))
        (let ((result (open-file path)))
          (ok (null result)
              "declining the prompt returns no buffer")
          (ok (null (visiting-buffer path))
              "declining leaves no half-created buffer behind"))))))

(deftest small-file-keeps-its-normal-mode
  (with-fake-interface ()
    (with-threshold (1048576)
      (with-temp-file (path "sh" 4096)
        ;; No key is fed: a below-threshold file must open without prompting.
        (let ((buffer (open-file path)))
          (unwind-protect
               (progn
                 (ok (lem:bufferp buffer)
                     "small file opens without a prompt")
                 (ok (eq 'lem-posix-shell-mode:posix-shell-mode
                         (lem:buffer-major-mode buffer))
                     "small file keeps its detected major mode"))
            (when (lem:bufferp buffer) (lem:delete-buffer buffer))))))))

(deftest nil-threshold-disables-guard
  (with-fake-interface ()
    (with-threshold (nil)
      (with-temp-file (path "sh" 4096)
        ;; No key fed: with the guard disabled even a large file must not prompt.
        (let ((buffer (open-file path)))
          (unwind-protect
               (progn
                 (ok (lem:bufferp buffer)
                     "a NIL threshold opens the file without prompting")
                 (ok (eq 'lem-posix-shell-mode:posix-shell-mode
                         (lem:buffer-major-mode buffer))
                     "a NIL threshold preserves normal mode detection"))
            (when (lem:bufferp buffer) (lem:delete-buffer buffer))))))))
