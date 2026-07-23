;;;; Typed gptel-style conversation reconstruction and Org prompt rendering.

(in-package :lem-yath)

(defparameter *llm-conversation-input-limit* (* 4 1024 1024))
(defparameter *llm-conversation-message-limit* 256)
(defparameter *llm-org-prompt-output-limit* (* 8 1024 1024))
(defparameter *llm-org-prompt-timeout* 15)

(defvar *llm-conversation-messages* nil
  "Typed user/assistant messages captured for one synchronous dispatch.")

(defstruct llm-org-protected-block
  token
  markdown)

(defun llm-message-role (message)
  (and (hash-table-p message) (gethash "role" message)))

(defun llm-message-content (message)
  (and (hash-table-p message) (gethash "content" message)))

(defun llm-conversation-role-at (point)
  (if (eq (text-property-at point 'lem-yath-llm-role) :assistant)
      "assistant"
      "user"))

(defun llm-conversation-push-span (turns role text)
  (if (and turns (string= role (caar turns)))
      (setf (cdar turns) (concatenate 'string (cdar turns) text))
      (push (cons role text) turns))
  turns)

(defun llm-conversation-turns (buffer end)
  "Return role-tagged text spans in BUFFER before END."
  (with-current-buffer buffer
    (let ((turns nil)
          (total 0))
      (with-point ((point (buffer-start-point buffer))
                   (limit end))
        (loop :while (point< point limit)
              :do
                 (let* ((role (llm-conversation-role-at point))
                        (next (copy-point point :temporary)))
                   (unless (next-single-property-change
                            next 'lem-yath-llm-role limit)
                     (move-point next limit))
                   (let ((text (points-to-string point next)))
                     (incf total (length text))
                     (when (> total *llm-conversation-input-limit*)
                       (editor-error "LLM conversation exceeds the input limit"))
                     (setf turns
                           (llm-conversation-push-span turns role text)))
                   (move-point point next))))
      (nreverse turns))))

(defun llm-strip-user-prompt-prefix (text)
  (let ((text (string-trim '(#\Space #\Tab #\Newline #\Return) text)))
    (if (and (>= (length text) 2)
             (char= (char text 0) #\*)
             (char= (char text 1) #\Space))
        (string-left-trim '(#\Space #\Tab #\Newline #\Return)
                          (subseq text 2))
        text)))

(defun llm-org-source-language (line)
  (cl-ppcre:register-groups-bind (language)
      ("(?i)^\\s*#\\+begin_src\\s+([^\\s]+).*$" line)
    language))

(defun llm-org-end-source-p (line)
  (cl-ppcre:scan "(?i)^\\s*#\\+end_src\\s*$" line))

(defun llm-org-result-heading-p (line)
  (cl-ppcre:scan "(?i)^\\s*#\\+results(?:\\[[^]]+\\])?:" line))

(defun llm-org-result-colon-line-p (line)
  (cl-ppcre:scan "^\\s*:(?:\\s|$)" line))

(defun llm-org-result-table-line-p (line)
  (cl-ppcre:scan "^\\s*\\|" line))

(defun llm-org-blank-line-p (line)
  (every (lambda (character) (member character '(#\Space #\Tab))) line))

(defun llm-org-lines-text (lines start end &key strip-colons)
  (with-output-to-string (output)
    (loop :for index :from start :below end
          :for line := (aref lines index)
          :do
             (when strip-colons
               (setf line
                     (cl-ppcre:regex-replace
                      "^\\s*:\\s?" line "")))
             (write-line line output))))

(defun llm-org-result-data (lines start)
  "Return result text and the first unconsumed line from vector LINES."
  (let* ((count (length lines))
         (index start))
    (loop :while (and (< index count)
                      (llm-org-blank-line-p (aref lines index)))
          :do (incf index))
    (cond
      ((and (< index count)
            (llm-org-result-colon-line-p (aref lines index)))
       (let ((end index))
         (loop :while (and (< end count)
                           (llm-org-result-colon-line-p (aref lines end)))
               :do (incf end))
         (values (llm-org-lines-text lines index end :strip-colons t) end)))
      ((and (< index count)
            (llm-org-result-table-line-p (aref lines index)))
       (let ((end index))
         (loop :while (and (< end count)
                           (llm-org-result-table-line-p (aref lines end)))
               :do (incf end))
         (values (llm-org-lines-text lines index end) end)))
      ((and (< index count)
            (cl-ppcre:scan
             "(?i)^\\s*#\\+begin_(?:example|src|export)(?:\\s|$)"
             (aref lines index)))
       (let ((end (1+ index)))
         (loop :while (and (< end count)
                           (not (cl-ppcre:scan
                                 "(?i)^\\s*#\\+end_(?:example|src|export)\\s*$"
                                 (aref lines end))))
               :do (incf end))
         (if (< end count)
             (values (llm-org-lines-text lines (1+ index) end) (1+ end))
             (values nil start))))
      (t (values nil start)))))

(defun llm-org-markdown-fence (body &optional language label)
  (format nil "~@[~a~%~]```~a~%~a~%```~%"
          label (or language "")
          (string-right-trim '(#\Space #\Tab #\Newline #\Return) body)))

(defun llm-org-unused-token (text index)
  (loop :for candidate := (format nil "LEMYATHGPTELBLOCK~8,'0dTOKEN" index)
        :then (concatenate 'string candidate "X")
        :unless (search candidate text) :return candidate))

(defun llm-org-protect-source-blocks (text)
  "Replace Org source/result pairs with Pandoc-stable tokens."
  (let* ((lines (coerce (uiop:split-string text :separator '(#\Newline))
                        'vector))
         (count (length lines))
         (index 0)
         (token-index 0)
         (protected nil))
    (values
     (with-output-to-string (output)
       (loop :while (< index count)
             :for line := (aref lines index)
             :for language := (llm-org-source-language line)
             :do
                (if (null language)
                    (progn (write-line line output) (incf index))
                    (let ((end (1+ index)))
                      (loop :while (and (< end count)
                                        (not (llm-org-end-source-p
                                              (aref lines end))))
                            :do (incf end))
                      (if (>= end count)
                          (progn (write-line line output) (incf index))
                          (let* ((body (llm-org-lines-text
                                        lines (1+ index) end))
                                 (after (1+ end))
                                 (result-heading after))
                            (loop :while (and (< result-heading count)
                                              (llm-org-blank-line-p
                                               (aref lines result-heading)))
                                  :do (incf result-heading))
                            (multiple-value-bind (result next)
                                (if (and (< result-heading count)
                                         (llm-org-result-heading-p
                                          (aref lines result-heading)))
                                    (llm-org-result-data
                                     lines (1+ result-heading))
                                    (values nil after))
                              (incf token-index)
                              (let* ((token (llm-org-unused-token
                                             text token-index))
                                     (markdown
                                       (concatenate
                                        'string
                                        (llm-org-markdown-fence body language)
                                        (if result
                                            (llm-org-markdown-fence
                                             result "text" "Output:")
                                            ""))))
                                (push (make-llm-org-protected-block
                                       :token token :markdown markdown)
                                      protected)
                                (write-line token output)
                                (setf index (if result next after))))))))))
     (nreverse protected))))

(defun llm-replace-literal (text old new)
  (with-output-to-string (output)
    (loop :with start := 0
          :for position := (search old text :start2 start)
          :do
             (write-string text output :start start
                                      :end (or position (length text)))
          :while position
          :do (write-string new output)
              (setf start (+ position (length old))))))

(defun llm-org-render-user-text (text &optional directory)
  "Render one bounded Org user turn as Markdown, falling back to TEXT."
  (when (> (length text) *llm-conversation-input-limit*)
    (editor-error "LLM user turn exceeds the input limit"))
  (handler-case
      (multiple-value-bind (prepared protected)
          (llm-org-protect-source-blocks text)
        (let ((pandoc (executable-find "pandoc")))
          (unless pandoc (return-from llm-org-render-user-text text))
          (let ((*project-process-timeout* *llm-org-prompt-timeout*))
            (multiple-value-bind (stdout stderr status)
                (run-project-program
                 (list (uiop:native-namestring pandoc)
                       "--from=org" "--to=gfm" "--wrap=none")
                 :directory (or directory (uiop:getcwd))
                 :input prepared
                 :output-limit *llm-org-prompt-output-limit*)
              (declare (ignore stderr))
              (unless (and (integerp status) (zerop status))
                (return-from llm-org-render-user-text text))
              (dolist (block protected)
                (setf stdout
                      (llm-replace-literal
                       stdout
                       (llm-org-protected-block-token block)
                       (llm-org-protected-block-markdown block))))
              (string-trim '(#\Space #\Tab #\Newline #\Return) stdout)))))
    (error () text)))

(defun llm-render-user-text-for-buffer (text buffer)
  "Render TEXT as Org only when BUFFER is in Org mode."
  (if (mode-active-p buffer 'org-mode)
      (llm-org-render-user-text
       text (ignore-errors (buffer-directory buffer)))
      text))

(defun llm-conversation-messages-to-point (buffer end)
  "Build typed, transformed chat messages from BUFFER through END."
  (let ((messages nil))
    (dolist (turn (llm-conversation-turns buffer end))
      (let* ((role (car turn))
             (raw (if (string= role "user")
                      (llm-strip-user-prompt-prefix (cdr turn))
                      (string-trim '(#\Space #\Tab #\Newline #\Return)
                                   (cdr turn))))
             (content (if (string= role "user")
                          (llm-render-user-text-for-buffer raw buffer)
                          raw)))
        (when (plusp (length content))
          (push (llm-json-object "role" role "content" content) messages))))
    (setf messages (nreverse messages))
    (when (> (length messages) *llm-conversation-message-limit*)
      (editor-error "LLM conversation exceeds the message limit"))
    messages))

(defun llm-conversation-last-user-content (messages)
  (loop :for message :in (reverse messages)
        :when (string= (or (llm-message-role message) "") "user")
          :return (llm-message-content message)))

(defun llm-conversation-replace-last-user-content (messages content)
  "Return MESSAGES with its final user turn replaced by CONTENT."
  (let ((reversed (reverse (copy-list messages)))
        (replaced nil))
    (loop :for tail :on reversed
          :for message := (car tail)
          :when (and (not replaced)
                     (string= (or (llm-message-role message) "") "user"))
            :do
               (setf (car tail)
                     (llm-json-object "role" "user" "content" content)
                     replaced t))
    (reverse reversed)))

(defun llm-messages-with-system (prompt system)
  "Return a system-prefixed typed conversation or one ordinary user turn."
  (append
   (list (llm-json-object "role" "system" "content" system))
   (or *llm-conversation-messages*
       (list (llm-json-object "role" "user" "content" prompt)))))
