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

;;; --- calendar dates ------------------------------------------------------

(defun leap-year-p (year)
  (and (zerop (mod year 4))
       (or (not (zerop (mod year 100)))
           (zerop (mod year 400)))))

(defun days-in-month (month year)
  (case month
    ((1 3 5 7 8 10 12) 31)
    ((4 6 9 11) 30)
    (2 (if (leap-year-p year) 29 28))
    (otherwise 0)))

(defun ascii-digits-p (text start end)
  (loop :for index :from start :below end
        :for character := (char text index)
        :always (char<= #\0 character #\9)))

(defun valid-iso-date-p (text)
  "Whether TEXT is exactly YYYY-MM-DD and denotes a real calendar date."
  (and (stringp text)
       (= (length text) 10)
       (char= (char text 4) #\-)
       (char= (char text 7) #\-)
       (ascii-digits-p text 0 4)
       (ascii-digits-p text 5 7)
       (ascii-digits-p text 8 10)
       (let ((year (parse-integer text :start 0 :end 4))
             (month (parse-integer text :start 5 :end 7))
             (day (parse-integer text :start 8 :end 10)))
         (and (plusp year)
              (<= 1 month 12)
              (<= 1 day (days-in-month month year))))))

(defun iso-date-components (date)
  (unless (valid-iso-date-p date)
    (error "Invalid ISO date: ~s" date))
  (values (parse-integer date :start 0 :end 4)
          (parse-integer date :start 5 :end 7)
          (parse-integer date :start 8 :end 10)))

(defun iso-date-for-time (time)
  "Return local calendar date at TIME as YYYY-MM-DD."
  (multiple-value-bind (second minute hour day month year)
      (decode-universal-time time)
    (declare (ignore second minute hour))
    (format nil "~4,'0d-~2,'0d-~2,'0d" year month day)))

(defun iso-date-add-calendar (date amount unit)
  "Add signed AMOUNT of UNIT (d, w, m, or y) to ISO DATE."
  (multiple-value-bind (year month day) (iso-date-components date)
    (let ((result
            (ecase (char-downcase unit)
              ((#\d #\w)
               (multiple-value-bind
                     (second minute hour new-day new-month new-year)
                   (decode-universal-time
                    (+ (encode-universal-time 0 0 12 day month year 0)
                       (* amount
                          (if (char-equal unit #\w) 7 1)
                          86400))
                    0)
                 (declare (ignore second minute hour))
                 (format nil "~4,'0d-~2,'0d-~2,'0d"
                         new-year new-month new-day)))
              (#\m
               (let* ((zero-month (+ (* year 12) (1- month) amount))
                      (new-year (floor zero-month 12))
                      (new-month (1+ (mod zero-month 12)))
                      (new-day (and (plusp new-year)
                                    (min day
                                         (days-in-month new-month new-year)))))
                 (and new-day
                      (format nil "~4,'0d-~2,'0d-~2,'0d"
                              new-year new-month new-day))))
              (#\y
               (let* ((new-year (+ year amount))
                      (new-day (and (plusp new-year)
                                    (min day
                                         (days-in-month month new-year)))))
                 (and new-day
                      (format nil "~4,'0d-~2,'0d-~2,'0d"
                              new-year month new-day)))))))
      (and (valid-iso-date-p result) result))))

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
      (setf (buffer-directory buffer) directory
            (buffer-value buffer 'lem-yath-direnv-process-buffer) t))
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

(defun boot-idle-timer-initialized-p ()
  "Verify immediate and recovered idle-timer deadlines."
  (handler-case
      (let* ((lem/common/timer::*timer-manager*
               (make-instance 'lem/common/timer:timer-manager))
             (lem/common/timer::*idle-timer-list* nil)
             (lem/common/timer::*processed-idle-timer-list* nil)
             (timer (lem/common/timer:make-idle-timer
                     (lambda ()) :name "boot timer probe")))
        (unwind-protect
             (progn
               (lem/common/timer:start-timer timer 100)
               (let ((started-last-time
                       (slot-value timer 'lem/common/timer::last-time)))
                 ;; Simulate a timer restored from an image before its manager
                 ;; existed; the deadline query must recover it as well.
                 (setf (slot-value timer 'lem/common/timer::last-time) nil)
                 (and (numberp started-last-time)
                      (numberp
                       (lem/common/timer:get-next-timer-timing-ms))
                      (numberp
                       (slot-value timer 'lem/common/timer::last-time)))))
          (lem/common/timer:stop-timer timer)))
    (error () nil)))

(defun write-boot-report (path)
  "Write a machine-checkable report of the boot state to PATH."
  (with-open-file (s path :direction :output
                          :if-exists :supersede
                          :if-does-not-exist :create)
    (let ((boot-error (symbol-value (find-symbol "*LEM-YATH-BOOT-ERROR*" :lem-user))))
      (format s "boot-error: ~a~%" (or boot-error "none"))
      (format s "boot-ok: ~a~%" (boot-ok-p))
      (format s "aot-root: ~a~%"
              (or (uiop:getenv "LEM_YATH_AOT_FASL_ROOT") "none"))
      (format s "vi-mode: ~a~%" (typep (current-global-mode) 'lem-vi-mode:vi-mode))
      (format s "leader: ~a~%" (variable-value 'lem-vi-mode/leader:leader-key :global))
      (format s "leader-bindings: ~a~%"
              (and (fboundp 'evil-leader-bindings-ok-p)
                   (evil-leader-bindings-ok-p)))
      (format s "idle-timer-deadline: ~a~%"
              (boot-idle-timer-initialized-p))
      (dolist (entry '(("rust-spec" lem-rust-mode:rust-mode)
                       ("nix-spec" lem-nix-mode:nix-mode)
                       ("python-spec" lem-python-mode:python-mode)
                       ("markdown-spec" lem-markdown-mode:markdown-mode)
                       ("csharp-spec" csharp-mode)
                       ("java-spec" lem-java-mode:java-mode)))
        (destructuring-bind (label mode) entry
          (let ((spec (lem-lsp-mode/spec:get-language-spec mode)))
            (format s "~a: ~a~%" label
                    (and spec (lem-lsp-mode/spec:get-spec-command spec))))))
      (format s "commands: ~{~a~^ ~}~%"
              (loop :for name :in '("LEM-YATH-VCS-STATUS" "LEM-YATH-ROAM-FIND" "LEM-YATH-LLM-SEND"
                                    "LEM-YATH-COMPILE" "LEM-YATH-CAPTURE" "LEM-YATH-FORMAT-BUFFER"
                                    "LEM-YATH-JAVA-LSP")
                    :collect (if (find-symbol name :lem-yath) "t" name)))))
  path)
