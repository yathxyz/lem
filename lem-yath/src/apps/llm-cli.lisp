;;;; lem-yath apps/llm-cli -- CLI-agent LLM backends.
;;;;
;;;; Ports the gptel CLI-agent backends from the Emacs config:
;;;;   gptel-claude-code.el -> :claude-code  (claude -p <prompt>)
;;;;   gptel-codex.el       -> :codex        (codex exec <prompt>)
;;;;   gptel-grok-build.el  -> :grok         (grok -p <prompt>)
;;;; Each launches its CLI non-interactively and streams stdout into the
;;;; shared *lem-yath-llm* buffer, reusing the OpenRouter path's UX. Unlike the
;;;; rich Emacs backends we do NOT parse agent-event JSON: plain text is fine.
;;;; lem-yath-llm-set-backend ports gptel's preset/backend switching surface.

(in-package :lem-yath)

(defparameter *llm-cli-commands*
  '((:claude-code "claude" ("-p"))
    (:codex       "codex"  ("exec"))
    (:grok        "grok"   ("-p")))
  "Per-backend (KEYWORD EXECUTABLE FIXED-ARGS) for the CLI-agent backends.
The prompt is appended after FIXED-ARGS when the backend streams.")

(defun llm-cli-spec (backend)
  "Return the (EXECUTABLE FIXED-ARGS) for BACKEND, or NIL."
  (cdr (assoc backend *llm-cli-commands*)))

(defun llm-cli-available-p (backend)
  "True when BACKEND's CLI binary is on PATH."
  (let ((spec (llm-cli-spec backend)))
    (and spec (executable-find (first spec)))))

(defun codex-exec-sandbox-args ()
  "Read-only sandbox flags for `codex exec`, if that CLI advertises them.
Probes `codex exec --help`; returns a list of extra args, or NIL when the
flag is unavailable or the probe fails. Mirrors gptel-grok-build's read-only
default without assuming a fixed flag spelling."
  (handler-case
      (let ((help (with-output-to-string (s)
                    (uiop:run-program '("codex" "exec" "--help")
                                      :output s
                                      :error-output s
                                      :ignore-error-status t))))
        (cond ((search "--sandbox" help) (list "--sandbox" "read-only"))
              ((search "--read-only" help) (list "--read-only"))
              (t nil)))
    (error () nil)))

(defun llm-cli-command (backend prompt)
  "Build the argv list (a list of strings) that runs BACKEND for PROMPT."
  (destructuring-bind (executable fixed-args) (llm-cli-spec backend)
    (append (list executable)
            fixed-args
            (when (eq backend :codex) (codex-exec-sandbox-args))
            (list prompt))))

(defun llm-cli-stream (backend prompt)
  "Run BACKEND's CLI for PROMPT, streaming stdout into the *lem-yath-llm* buffer.
Reuses the OpenRouter path's header/UX and the shared append helpers. Output
is read on a bt2 worker thread and marshalled onto the editor thread by
append-text; missing binary or launch failure degrades to a message."
  (unless (llm-cli-available-p backend)
    (message "~a CLI not found on PATH" (first (llm-cli-spec backend)))
    (return-from llm-cli-stream))
  (let ((buffer (llm-output-buffer))
        (command (llm-cli-command backend prompt)))
    (pop-to-buffer buffer)
    (append-text buffer
                 (format nil "~%## User (~a)~%~%~a~%~%## Assistant~%~%"
                         backend prompt))
    (handler-case
        (let ((process (uiop:launch-program command
                                            :output :stream
                                            :error-output :output)))
          (bt2:make-thread
           (lambda ()
             (unwind-protect
                  (with-open-stream (out (uiop:process-info-output process))
                    (loop :for line := (read-line out nil)
                          :while line
                          :do (append-line buffer line)))
               (let ((code (ignore-errors (uiop:wait-process process))))
                 (if (and code (zerop code))
                     (append-text buffer (string #\Newline))
                     (append-line buffer
                                  (format nil "~%[~a exited ~a]"
                                          (first (llm-cli-spec backend)) code))))))
           :name (format nil "lem-yath/llm-~(~a~)" backend)))
      (error (e)
        (append-line buffer (format nil "~%[failed to launch: ~a]" e))))))

(defmethod llm-backend-stream ((backend (eql :claude-code)) prompt)
  (llm-cli-stream backend prompt))

(defmethod llm-backend-stream ((backend (eql :codex)) prompt)
  (llm-cli-stream backend prompt))

(defmethod llm-backend-stream ((backend (eql :grok)) prompt)
  (llm-cli-stream backend prompt))

(defun llm-available-backends ()
  "Backends usable right now: always :openrouter, plus any CLI on PATH."
  (cons :openrouter
        (loop :for (backend) :in *llm-cli-commands*
              :when (llm-cli-available-p backend)
                :collect backend)))

(define-command lem-yath-llm-set-backend () ()
  "Switch the active LLM backend (gptel preset/backend selection).
Offers :openrouter plus whichever CLI-agent backends are installed, filtered
Prescient-style; sets *llm-backend* and confirms."
  (let* ((backends (llm-available-backends))
         (names (mapcar (lambda (b) (string-downcase (symbol-name b))) backends))
         (choice (prompt-for-string
                  "LLM backend: "
                  :completion-function (lambda (s) (prescient-filter s names))
                  :initial-value (string-downcase (symbol-name *llm-backend*))
                  :history-symbol 'lem-yath-llm-backend))
         (backend (find choice backends
                        :key (lambda (b) (string-downcase (symbol-name b)))
                        :test #'string-equal)))
    (if backend
        (progn
          (setf *llm-backend* backend)
          (message "LLM backend: ~(~a~)" backend))
        (message "Unknown or unavailable backend: ~a" choice))))
