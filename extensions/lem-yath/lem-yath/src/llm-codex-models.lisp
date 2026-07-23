;;;; Cached, asynchronous ChatGPT Codex model discovery.

(in-package :lem-yath)

(defparameter *llm-codex-model-fallback*
  '("gpt-5.4" "gpt-5.3-codex"))
(defparameter *llm-codex-model-candidates*
  '("gpt-5.4" "gpt-5.3-codex" "gpt-5.2-codex" "gpt-5-codex"))
(defparameter *llm-codex-model-cache-limit* (* 64 1024))
(defparameter *llm-codex-model-response-limit* (* 256 1024))
(defparameter *llm-codex-model-refresh-timeout* 30)
(defparameter *llm-codex-model-refresh-idle-delay* 5)

(defvar *llm-codex-models* (copy-list *llm-codex-model-fallback*))
(defvar *llm-codex-model-source* :fallback)
(defvar *llm-codex-model-refresh-timer* nil)
(defvar *llm-codex-model-refresh-running-p* nil)
(defvar *llm-codex-model-refresh-generation* 0)
(defvar *llm-codex-model-refresh-lock*
  (bt2:make-lock :name "lem-yath/codex-model-refresh"))

(defun llm-codex-model-cache-override ()
  (uiop:getenv "LEM_YATH_CODEX_MODEL_CACHE"))

(defun llm-codex-model-cache-pathname ()
  "Return the private JSON model cache pathname."
  (alexandria:if-let ((override (llm-codex-model-cache-override)))
    (uiop:parse-native-namestring override)
    (let ((cache-home
            (alexandria:if-let ((xdg (uiop:getenv "XDG_CACHE_HOME")))
              (uiop:ensure-directory-pathname
               (uiop:parse-native-namestring xdg))
              (merge-pathnames ".cache/" (user-homedir-pathname)))))
      (merge-pathnames "lem-yath/chatgpt-codex/models.json" cache-home))))

(defun llm-codex-normalize-models (values &key strict)
  "Filter VALUES to known candidates while preserving first-seen order."
  (let ((values (llm-json-elements values)))
    (when (and strict (not (every #'stringp values)))
      (error "ChatGPT Codex model cache contains a non-string model id"))
    (remove-duplicates
     (remove-if-not
      (lambda (model)
        (and (stringp model)
             (member model *llm-codex-model-candidates* :test #'string=)))
      values)
     :test #'string= :from-end t)))

(defun llm-codex-read-model-cache ()
  "Read the private JSON model cache without evaluating Lisp data."
  (handler-case
      (let ((pathname (llm-codex-model-cache-pathname)))
        (when (uiop:file-exists-p pathname)
          (llm-model-cache-validate-file pathname "ChatGPT Codex")
          (let* ((object
                   (yason:parse
                    (llm-model-cache-read-text
                     pathname *llm-codex-model-cache-limit*
                     "ChatGPT Codex")))
                 (version (and (hash-table-p object)
                               (gethash "version" object)))
                 (models (and (hash-table-p object)
                              (gethash "models" object))))
            (when (and (eql version 1) models)
              (llm-codex-normalize-models models :strict t)))))
    (error () nil)))

(defun llm-codex-write-model-cache (models)
  "Atomically replace the private ChatGPT Codex model cache with MODELS."
  (llm-model-cache-write
   (llm-codex-model-cache-pathname) models *llm-codex-model-cache-limit*
   (not (null (llm-codex-model-cache-override))) "ChatGPT Codex"))

(defun llm-codex-model-probe-body (model)
  (with-output-to-string (stream)
    (yason:encode
     (llm-json-object
      "model" model
      "instructions" *llm-codex-instructions-prefix*
      "input"
      (vector
       (llm-json-object
        "type" "message" "role" "user"
        "content"
        (vector
         (llm-json-object
          "type" "input_text" "text" "Reply with exactly OK."))))
      "store" yason:false
      "stream" t)
     stream)))

(defun llm-codex-model-probe-http-status (output)
  (let ((status nil))
    (with-input-from-string (stream output)
      (loop :for line := (read-line stream nil)
            :while line
            :when (and (>= (length line) 28)
                       (string= line "__LEM_YATH_HTTP_STATUS__:"
                                :end1 25 :end2 25))
              :do (let ((value (subseq line 25)))
                    (when (and (= (length value) 3)
                               (every #'digit-char-p value))
                      (setf status (parse-integer value))))))
    status))

(defun llm-codex-probe-model (auth model)
  "Return true when MODEL is accepted; call only off the editor thread."
  (let ((*project-process-timeout*
          (+ *llm-codex-model-refresh-timeout* 2)))
    (multiple-value-bind (stdout stderr process-status)
        (run-project-program
         (llm-curl-arguments
          *llm-codex-model-refresh-timeout* :status-p t)
         :input
         (llm-curl-config
          "POST" *llm-codex-endpoint*
          (llm-codex-headers auth (llm-oauth-secure-uuid))
          (llm-codex-model-probe-body model))
         :output-limit *llm-codex-model-response-limit*)
      (declare (ignore stderr process-status))
      (let ((status (llm-codex-model-probe-http-status stdout)))
        (unless status
          (error "ChatGPT Codex model probe returned no HTTP status"))
        (member status '(200 429))))))

(defun llm-codex-fetch-models (&key allow-login)
  "Probe the configured candidates sequentially outside the editor thread."
  (let ((*llm-codex-auto-login* allow-login))
    (let ((auth (llm-codex-ensure-auth)))
      (loop :for model :in *llm-codex-model-candidates*
            :when (llm-codex-probe-model auth model)
              :collect model))))

(defun llm-codex-apply-models (models source &key quiet)
  (let ((models (llm-codex-normalize-models models :strict t)))
    (unless models (error "Cannot apply an empty ChatGPT Codex model list"))
    (setf *llm-codex-models* models
          *llm-codex-model-source* source)
    (when (and (eq *llm-backend* :chatgpt-codex)
               (not (member *llm-model* models :test #'string=)))
      (setf *llm-model* (first models)))
    (unless quiet
      (message "ChatGPT Codex: loaded ~d models from ~(~a~)"
               (length models) source))))

(defmethod llm-model-candidates-for-backend ((backend (eql :chatgpt-codex)))
  *llm-codex-models*)

(defun llm-codex-finish-model-refresh
    (generation models condition quiet)
  (when (and models (= generation *llm-codex-model-refresh-generation*))
    (llm-codex-apply-models models :network :quiet quiet))
  (when (and condition (not quiet))
    (message "ChatGPT Codex: model refresh failed (~a)" condition)))

(defun llm-codex-start-model-refresh (&key quiet allow-login)
  "Start one asynchronous model refresh; return NIL if one already runs."
  (let ((claimed nil)
        (generation *llm-codex-model-refresh-generation*))
    (bt2:with-lock-held (*llm-codex-model-refresh-lock*)
      (unless *llm-codex-model-refresh-running-p*
        (setf *llm-codex-model-refresh-running-p* t
              claimed t)))
    (when claimed
      (handler-case
          (bt2:make-thread
           (lambda ()
             (let ((models nil)
                   (condition nil))
               (unwind-protect
                    (handler-case
                        (let ((fetched
                                (llm-codex-fetch-models
                                 :allow-login allow-login)))
                          (unless fetched
                            (error "ChatGPT Codex model refresh found no supported models"))
                          (llm-codex-write-model-cache fetched)
                          (setf models fetched))
                      (error (error) (setf condition error)))
                 (bt2:with-lock-held (*llm-codex-model-refresh-lock*)
                   (setf *llm-codex-model-refresh-running-p* nil)))
               (send-event
                (lambda ()
                  (llm-codex-finish-model-refresh
                   generation models condition quiet)))))
           :name "lem-yath/codex-model-refresh")
        (error (condition)
          (bt2:with-lock-held (*llm-codex-model-refresh-lock*)
            (setf *llm-codex-model-refresh-running-p* nil))
          (unless quiet
            (message "ChatGPT Codex: could not start model refresh (~a)"
                     condition))
          (setf claimed nil)))
    claimed)))

(defun llm-codex-stop-model-refresh-timer ()
  (alexandria:when-let ((timer *llm-codex-model-refresh-timer*))
    (setf *llm-codex-model-refresh-timer* nil)
    (ignore-errors (stop-timer timer))))

(defun llm-codex-automatic-model-refresh-p ()
  (let ((setting (uiop:getenv "LEM_YATH_CODEX_MODEL_REFRESH")))
    (not (member (string-downcase (or setting "1"))
                 '("0" "false" "no") :test #'string=))))

(defun llm-codex-schedule-model-refresh ()
  (llm-codex-stop-model-refresh-timer)
  (when (llm-codex-automatic-model-refresh-p)
    (let (timer)
      (setf timer
            (make-idle-timer
             (lambda ()
               (when (eq timer *llm-codex-model-refresh-timer*)
                 (setf *llm-codex-model-refresh-timer* nil)
                 (llm-codex-start-model-refresh
                  :quiet t :allow-login nil)))
             :name "lem-yath ChatGPT Codex model refresh"))
      (setf *llm-codex-model-refresh-timer*
            (start-timer
             timer (* 1000 *llm-codex-model-refresh-idle-delay*)
             :repeat nil)))))

(defun initialize-llm-codex-models ()
  (incf *llm-codex-model-refresh-generation*)
  (alexandria:when-let ((cached (llm-codex-read-model-cache)))
    (llm-codex-apply-models cached :cache :quiet t))
  (llm-codex-schedule-model-refresh))

(define-command lem-yath-chatgpt-codex-refresh-models () ()
  "Refresh the ChatGPT Codex model catalog asynchronously."
  (if (llm-codex-start-model-refresh :allow-login t)
      (message "ChatGPT Codex: refreshing models")
      (message "ChatGPT Codex: model refresh already running")))

(initialize-editor-feature 'initialize-llm-codex-models)
