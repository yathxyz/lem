;;;; Shared helpers: paths, processes, fuzzy matching, boot reporting.

(in-package :lem-yath)

(defun initialize-editor-feature (function)
  "Run FUNCTION once a frame exists, including when config loads via --eval."
  (if lem-core::*in-the-editor*
      (funcall function)
      (add-hook *after-init-hook* function)))

(defparameter *boot-ok* nil)

(defun boot-ok-p () *boot-ok*)

;;; --- paths ---------------------------------------------------------------

(defun find-up (start name)
  "Walk upward from directory START looking for file-or-directory NAME.
Returns the containing directory pathname, or NIL."
  (labels ((present-p (dir)
             (or (uiop:probe-file* (merge-pathnames name dir))
                 (uiop:directory-exists-p
                  (uiop:ensure-directory-pathname (merge-pathnames name dir)))))
           (try (dir)
             (when dir
               (if (present-p dir)
                   dir
                   (let ((parent (uiop:pathname-parent-directory-pathname dir)))
                     (unless (equal parent dir)
                       (try parent)))))))
    (ignore-errors (try (uiop:ensure-directory-pathname start)))))

(defun executable-find (name)
  "Locate NAME on PATH; returns the full pathname or NIL."
  (loop :for dir :in (uiop:split-string (or (uiop:getenv "PATH") "") :separator ":")
        :unless (zerop (length dir))
          :do (let ((path (ignore-errors
                            (uiop:probe-file*
                             (merge-pathnames name (uiop:ensure-directory-pathname dir))))))
                (when path (return path)))))

;; Defined in completion.lisp, which follows this foundational module in the
;; serial ASDF system.  Declaring it keeps compilation of prompt helpers clean.
(declaim (ftype function prescient-filter))

;;; --- help ------------------------------------------------------------------

(defun variable-candidates ()
  "Names of bound Lisp variables in the running Lem image."
  (let ((names '()))
    (do-all-symbols (symbol)
      (when (and (boundp symbol) (symbol-package symbol))
        (pushnew (format nil "~a::~a"
                         (package-name (symbol-package symbol))
                         (symbol-name symbol))
                 names
                 :test #'string=)))
    (sort names #'string-lessp)))

(define-command lem-yath-describe-variable () ()
  "Describe a bound Lisp variable, like helpful-variable."
  (let* ((candidates (variable-candidates))
         (choice (prompt-for-string
                  "Variable: "
                  :completion-function
                  (lambda (input) (prescient-filter input candidates))
                  :test-function
                  (lambda (input) (member input candidates :test #'string=))))
         (symbol (read-from-string choice)))
    (with-pop-up-typeout-window (out (make-buffer "*Variable Help*") :erase t)
      (describe symbol out))))

;;; --- async processes -> buffers -------------------------------------------

(defun append-text (buffer string)
  "Append STRING to BUFFER from any thread, via the editor event queue."
  (send-event (lambda ()
                (insert-string (buffer-end-point buffer) string)
                (redraw-display))))

(defun append-line (buffer string)
  (append-text buffer (concatenate 'string string (string #\Newline))))

(defun stream-to-buffer (command buffer-name &key directory (clear t) on-exit)
  "Run COMMAND (a list) asynchronously, streaming its output into BUFFER-NAME.
Output is marshalled onto the editor thread; returns the buffer immediately.
ON-EXIT, if given, is called on the editor thread with the exit code."
  (let ((buffer (make-buffer buffer-name)))
    (when directory
      (setf (buffer-directory buffer) directory))
    (when clear (erase-buffer buffer))
    (pop-to-buffer buffer)
    (let ((process (uiop:launch-program command
                                        :output :stream
                                        :error-output :output
                                        :directory directory)))
      (bt2:make-thread
       (lambda ()
         (unwind-protect
              (with-open-stream (out (uiop:process-info-output process))
                (loop :for line := (read-line out nil)
                      :while line
                      :do (append-line buffer line)))
           (let ((code (ignore-errors (uiop:wait-process process))))
             (append-line buffer (format nil "~%[exit ~a]" code))
             (when on-exit
               (send-event (lambda () (funcall on-exit code)))))))
       :name (format nil "lem-yath/~a" buffer-name)))
    buffer))

;;; --- boot report (consumed by scripts/boot-test.sh) -----------------------

(defun write-boot-report (path)
  "Write a machine-checkable report of the boot state to PATH."
  (with-open-file (s path :direction :output
                          :if-exists :supersede
                          :if-does-not-exist :create)
    (let ((boot-error (symbol-value (find-symbol "*LEM-YATH-BOOT-ERROR*" :lem-user))))
      (format s "boot-error: ~a~%" (or boot-error "none"))
      (format s "boot-ok: ~a~%" (boot-ok-p))
      (format s "vi-mode: ~a~%" (typep (current-global-mode) 'lem-vi-mode:vi-mode))
      (format s "leader: ~a~%" (variable-value 'lem-vi-mode/leader:leader-key :global))
      (format s "leader-bindings: ~a~%"
              (and (fboundp 'evil-leader-bindings-ok-p)
                   (evil-leader-bindings-ok-p)))
      (dolist (entry '(("rust-spec" lem-rust-mode:rust-mode)
                       ("nix-spec" lem-nix-mode:nix-mode)
                       ("python-spec" lem-python-mode:python-mode)
                       ("markdown-spec" lem-markdown-mode:markdown-mode)))
        (destructuring-bind (label mode) entry
          (let ((spec (lem-lsp-mode/spec:get-language-spec mode)))
            (format s "~a: ~a~%" label
                    (and spec (lem-lsp-mode/spec:get-spec-command spec))))))
      (format s "commands: ~{~a~^ ~}~%"
              (loop :for name :in '("LEM-YATH-VCS-STATUS" "LEM-YATH-ROAM-FIND" "LEM-YATH-LLM-SEND"
                                    "LEM-YATH-COMPILE" "LEM-YATH-CAPTURE" "LEM-YATH-FORMAT-BUFFER")
                    :collect (if (find-symbol name :lem-yath) "t" name)))))
  path)
