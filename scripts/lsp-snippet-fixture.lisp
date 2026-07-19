(in-package :lem-yath)

(defvar *lsp-snippet-test-report-path*
  (uiop:getenv "LEM_YATH_LSP_SNIPPET_TEST_REPORT"))

(defvar *lsp-snippet-test-pwned* nil)
(defvar *lsp-snippet-test-rollback-baseline* nil)
(defvar *lsp-snippet-test-throwing-hook-fired-p* nil)

(defclass lsp-snippet-test-client
    (lem-language-client/client:client)
  ((response
    :initarg :response
    :initform nil
    :reader lsp-snippet-test-client-response)
   (error-message
    :initarg :error-message
    :initform nil
    :reader lsp-snippet-test-client-error-message)
   (request-count
    :initform 0
    :accessor lsp-snippet-test-client-request-count)))

(defmethod lem-language-client/request:request-async
    ((client lsp-snippet-test-client)
     (message lsp:completion-item/resolve)
     item callback &optional error-callback)
  (declare (ignore message))
  (incf (lsp-snippet-test-client-request-count client))
  (let* ((data (handler-case (lsp:completion-item-data item)
                 (unbound-slot () nil)))
         (token (and (hash-table-p data) (gethash "fixture" data))))
    (lsp-snippet-test-report
     "RESOLVE count=~d label=~a token=~a"
     (lsp-snippet-test-client-request-count client)
     (lsp:completion-item-label item)
     (or token "none")))
  (alexandria:if-let ((error-message
                       (lsp-snippet-test-client-error-message client)))
    (if error-callback
        (funcall error-callback error-message -32000)
        (error error-message))
    (funcall callback (lsp-snippet-test-client-response client)))
  nil)

(defun lsp-snippet-test-report (control &rest arguments)
  (with-open-file (stream *lsp-snippet-test-report-path*
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun lsp-snippet-test-buffer-text ()
  (points-to-string (buffer-start-point (current-buffer))
                    (buffer-end-point (current-buffer))))

(defun lsp-snippet-test-hex (string)
  (with-output-to-string (stream)
    (loop :for character :across string
          :do (format stream "~2,'0x" (char-code character)))))

(defun lsp-snippet-test-focus-label ()
  (alexandria:when-let*
      ((context lem/completion-mode::*completion-context*)
       (popup (lem/completion-mode::context-popup-menu context))
       (item (lem/popup-menu:get-focus-item popup)))
    (lem/completion-mode:completion-item-label item)))

(defun lsp-snippet-test-mutating-throwing-hook (start end old-length)
  (declare (ignore end old-length))
  (unless *lsp-snippet-test-throwing-hook-fired-p*
    (setf *lsp-snippet-test-throwing-hook-fired-p* t)
    (let ((buffer (point-buffer start)))
      (remove-hook (variable-value 'after-change-functions :buffer buffer)
                   'lsp-snippet-test-mutating-throwing-hook)
      (insert-string (buffer-end-point buffer) "!")
      (editor-error "fixture nested LSP completion mutation failure"))))

(defun lsp-snippet-test-rollback-history-restored-p ()
  (and *lsp-snippet-test-rollback-baseline*
       (let ((after (lem:buffer-undo-tree-snapshot (current-buffer))))
         (and (= (getf *lsp-snippet-test-rollback-baseline* :node-count)
                 (getf after :node-count))
              (= (getf *lsp-snippet-test-rollback-baseline* :payload-bytes)
                 (getf after :payload-bytes))
              (eql (getf *lsp-snippet-test-rollback-baseline* :current)
                   (getf after :current))))))

(defun lsp-snippet-test-reset (label text point-offset)
  (lem/completion-mode:completion-end)
  (auto-completion-cancel-timer)
  (setf *auto-completion-context* nil)
  (when (mode-active-p (current-buffer) 'lem-yath-snippet-mode)
    (lem-yath-snippet-mode nil))
  (unless (eq (buffer-major-mode (current-buffer))
              'lem/buffer/fundamental-mode:fundamental-mode)
    (change-buffer-mode
     (current-buffer) 'lem/buffer/fundamental-mode:fundamental-mode))
  (setf (variable-value 'lem/language-mode:completion-spec
                        :buffer (current-buffer))
        nil)
  (remove-hook
   (variable-value 'after-change-functions :buffer (current-buffer))
   'lsp-snippet-test-mutating-throwing-hook)
  (let ((*inhibit-read-only* t))
    (erase-buffer (current-buffer))
    (insert-string (current-point) text))
  (buffer-start (current-point))
  (character-offset (current-point) point-offset)
  (clear-buffer-edit-history (current-buffer))
  (setf (buffer-value (current-buffer) :lsp-snippet-test-label) label
        *lsp-snippet-test-pwned* nil
        *lsp-snippet-test-rollback-baseline* nil
        *lsp-snippet-test-throwing-hook-fired-p* nil
        (lem-vi-mode/core:buffer-state (current-buffer))
        'lem-vi-mode:normal)
  (lem-yath-snippet-mode t)
  (lsp-snippet-test-report "SETUP label=~a" label))

(defun lsp-snippet-test-position (character &optional (line 0))
  (make-instance 'lsp:position :line line :character character))

(defun lsp-snippet-test-range (start end)
  (make-instance 'lsp:range
                 :start (lsp-snippet-test-position start)
                 :end (lsp-snippet-test-position end)))

(defun lsp-snippet-test-line-range
    (start-line start-character end-line end-character)
  (make-instance
   'lsp:range
   :start (lsp-snippet-test-position start-character start-line)
   :end (lsp-snippet-test-position end-character end-line)))

(defun lsp-snippet-test-invalid-range ()
  (make-instance 'lsp:range
                 :start (lsp-snippet-test-position 0 99)
                 :end (lsp-snippet-test-position 1 99)))

(defun lsp-snippet-test-convert-items (items &optional workspace)
  (lem-lsp-mode::convert-completion-items
   (current-point) items workspace))

(defun lsp-snippet-test-open-items (items &optional workspace)
  (let ((converted (lsp-snippet-test-convert-items items workspace)))
    (lem/completion-mode:run-completion
     (lem/completion-mode:make-completion-spec
      (lambda (point then)
        (declare (ignore point))
        (funcall then converted))
      :async t))))

(defun lsp-snippet-test-open-frozen-items (items &optional workspace)
  (let ((converted (lsp-snippet-test-convert-items items workspace))
        (provider-count 0))
    (lem/completion-mode:run-completion
     (lem/completion-mode:make-completion-spec
      (lambda (point then)
        (declare (ignore point))
        (incf provider-count)
        (lsp-snippet-test-report
         "FROZEN provider-count=~d" provider-count)
        (funcall then converted))
      :async t)
     :filter-function #'lem-lsp-mode::filter-completion-items
     :separator #\x)
    (lsp-snippet-test-report
     "FROZEN local=~a"
     (if (lem/completion-mode:completion-start-local-filtering #\x)
         "yes"
         "no"))))

(defun lsp-snippet-test-conversion-rejected-p (item)
  (handler-case
      (null (lsp-snippet-test-convert-items (list item)))
    (error (condition)
      (let ((message (princ-to-string condition)))
        (lsp-snippet-test-report
         "DETAIL rejected-main label=~a error=~a"
         (lsp:completion-item-label item)
         message)
        (not (null (search "Invalid LSP" message
                           :test #'char-equal)))))))

(defun lsp-snippet-test-encoding-workspace (encoding)
  (make-instance
   'lem-lsp-mode::workspace
   :server-capabilities
   (make-instance 'lsp:server-capabilities
                  :position-encoding encoding)))

(defun lsp-snippet-test-position-roundtrip-p (encoding expected-units)
  (let ((text "a😀b"))
    (and (= (length expected-units) (1+ (length text)))
         (loop :for index :from 0 :below (length expected-units)
               :for units :across expected-units
               :always
               (and
                (= units
                   (lem-lsp-mode::string-index-to-position-character
                    text index encoding))
                (= index
                   (lem-lsp-mode::position-character-to-string-index
                    text units encoding)))))))

(defun lsp-snippet-test-split-units-rejected-p (encoding units)
  (every (lambda (unit)
           (null
            (lem-lsp-mode::position-character-to-string-index
             "a😀b" unit encoding)))
         units))

(defun lsp-snippet-test-outbound-position-p (encoding expected-character)
  (let* ((workspace (lsp-snippet-test-encoding-workspace encoding))
         (position
           (lem-lsp-mode::point-to-workspace-position
            (current-point) workspace))
         (arguments
           (lem-lsp-mode::make-text-document-position-arguments
            (current-point) workspace))
         (argument-position (getf arguments :position)))
    (with-point ((start (buffer-start-point (current-buffer)))
                 (end (buffer-start-point (current-buffer)))
                 (decoded (buffer-start-point (current-buffer))))
      (character-offset start 1)
      (character-offset end 2)
      (let* ((range
               (lem-lsp-mode::points-to-workspace-range
                start end workspace))
             (range-start (lsp:range-start range))
             (range-end (lsp:range-end range)))
        (and (= 0 (lsp:position-line position))
             (= expected-character (lsp:position-character position))
             (= expected-character
                (lsp:position-character argument-position))
             (= 1 (lsp:position-character range-start))
             (= expected-character (lsp:position-character range-end))
             (lem-lsp-mode::move-to-workspace-position
              decoded position workspace)
             (point= decoded (current-point)))))))

(defun lsp-snippet-test-diagnostic-decoding-p (workspace)
  (let* ((buffer (current-buffer))
         (diagnostic
           (make-instance
            'lsp:diagnostic
            :range (lsp-snippet-test-range 1 5)
            :message "utf8 diagnostic")))
    (lem-lsp-mode::reset-buffer-diagnostic buffer)
    (unwind-protect
         (progn
           (lem-lsp-mode::highlight-diagnostic workspace buffer diagnostic)
           (let ((overlays
                   (lem-lsp-mode::buffer-diagnostic-overlays buffer)))
             (and (= 1 (length overlays))
                  (= 2 (position-at-point
                        (overlay-start (first overlays))))
                  (= 3 (position-at-point
                        (overlay-end (first overlays)))))))
      (lem-lsp-mode::reset-buffer-diagnostic buffer))))

(defun lsp-snippet-test-highlight-decoding-p (workspace)
  (let ((highlight
          (make-instance
           'lsp:document-highlight
           :range (lsp-snippet-test-range 1 3))))
    (lem-lsp-mode::clear-document-highlight-overlays)
    (unwind-protect
         (progn
           (lem-lsp-mode::display-document-highlights
            workspace (current-buffer) (vector highlight))
           (let ((overlays (lem-lsp-mode::document-highlight-overlays)))
             (and (= 1 (length overlays))
                  (= 2 (position-at-point
                        (overlay-start (first overlays))))
                  (= 3 (position-at-point
                        (overlay-end (first overlays)))))))
      (lem-lsp-mode::clear-document-highlight-overlays))))

(defun lsp-snippet-test-document-symbol-decoding-p (workspace)
  (let* ((source-buffer (current-buffer))
         (collector-buffer
           (make-buffer (format nil "*lsp-symbol-~a*" (gensym))
                        :temporary t
                        :enable-undo-p nil))
         (collector
           (make-instance 'lem/peek-source::collector
                          :buffer collector-buffer))
         (range (lsp-snippet-test-range 3 4))
         (symbol
           (make-instance 'lsp:document-symbol
                          :name "symbol"
                          :kind lsp:symbol-kind-function
                          :range range
                          :selection-range range)))
    (unwind-protect
         (let ((lem/peek-source::*collector* collector))
           (lem-lsp-mode::append-document-symbol-item
            workspace source-buffer symbol 0)
           (with-point ((point (buffer-start-point collector-buffer)))
             (alexandria:when-let
                 ((move-function
                    (lem/peek-source:get-move-function point)))
               (alexandria:when-let ((target (funcall move-function)))
                 (and (= 1 (line-number-at-point target))
                      (= 2 (point-charpos target)))))))
      (delete-buffer collector-buffer))))

(defun lsp-snippet-test-definition-decoding-p (workspace)
  (let* ((buffer (current-buffer))
         (location
           (make-instance
            'lsp:location
            :uri (lem-lsp-mode::buffer-uri buffer)
            :range (lsp-snippet-test-range 5 6)))
         (xref (lem-lsp-mode::convert-location location workspace)))
    (when xref
      (let ((position (lem/language-mode:xref-location-position xref)))
        (and (= 1 (lem/language-mode::xref-position-line-number position))
             (= 2 (lem/language-mode::xref-position-charpos position))
             (string= "a😀b"
                      (lem/language-mode:xref-location-content xref)))))))

(defun lsp-snippet-test-read-lsp-source-forms ()
  (let ((path
          (alexandria:if-let (source (uiop:getenv "LEM_YATH_LEM_SOURCE"))
            (merge-pathnames
             "extensions/lsp-mode/lsp-mode.lisp"
             (uiop:ensure-directory-pathname source))
            (asdf:system-relative-pathname :lem-lsp-mode "lsp-mode.lisp")))
        (eof (gensym "EOF")))
    (with-open-file (stream path :direction :input)
      ;; The file uses local package nicknames such as CLIENT.  READ does not
      ;; execute its leading DEFPACKAGE/IN-PACKAGE forms, so supply the package
      ;; in which the source is normally read.
      (let ((*read-eval* nil)
            (*package* (find-package :lem-lsp-mode/lsp-mode)))
        (loop :for form := (read stream nil eof)
              :until (eq form eof)
              :collect form)))))

(defun lsp-snippet-test-count-call-forms (forms name &optional arity)
  (labels ((walk (tree)
             (if (consp tree)
                 (+ (if (and (symbolp (first tree))
                             (string= name (symbol-name (first tree)))
                             (or (null arity)
                                 (eql arity
                                      (ignore-errors (1- (length tree))))))
                        1
                        0)
                    (walk (car tree))
                    (walk (cdr tree)))
                 0)))
    (reduce #'+ forms :key #'walk :initial-value 0)))

(defun lsp-snippet-test-source-position-guard-p ()
  (let ((forms (lsp-snippet-test-read-lsp-source-forms)))
    (and (zerop (lsp-snippet-test-count-call-forms
                 forms "MOVE-TO-LSP-POSITION"))
         (zerop (lsp-snippet-test-count-call-forms
                 forms "POINTS-TO-LSP-RANGE"))
         (zerop (lsp-snippet-test-count-call-forms
                 forms "MAKE-TEXT-DOCUMENT-POSITION-ARGUMENTS" 1)))))

(defun lsp-snippet-test-jsonrpc-late-response-clean-p ()
  (let* ((connection (make-instance 'jsonrpc/connection:connection))
         (callback-count 0)
         (id 77))
    (jsonrpc/connection::set-callback-for-id
     connection id (lambda (response)
                     (declare (ignore response))
                     (incf callback-count)))
    (let ((removed-p
            (jsonrpc/connection:remove-callback-for-id connection id)))
      (jsonrpc/connection:add-message-to-queue
       connection (jsonrpc:make-response :id id :result "late"))
      (and removed-p
           (zerop callback-count)
           (zerop
            (hash-table-count
             (jsonrpc/connection::connection-response-callback connection)))
           (zerop
            (hash-table-count
             (jsonrpc/connection::connection-ignored-response-ids
              connection)))
           (null
            (find "RESPONSE-MAP"
                  (c2mop:class-slots (class-of connection))
                  :test #'string=
                  :key (lambda (slot)
                         (symbol-name
                          (c2mop:slot-definition-name slot)))))))))

(defun lsp-snippet-test-jsonrpc-timeout-cleans-callback-p ()
  (let ((connection (make-instance 'jsonrpc/connection:connection))
        (client (make-instance 'jsonrpc/base:jsonrpc))
        (timed-out-p nil))
    (handler-case
        (jsonrpc/base:call-to client connection "fixture/timeout" nil
                              ;; SBCL treats an exact zero timeout as an
                              ;; indefinite wait in this blocking path.  A
                              ;; small positive deadline exercises the real
                              ;; synchronous timeout cleanup deterministically.
                              :timeout 0.05)
      (error ()
        (setf timed-out-p t)))
    (and timed-out-p
         (not
          (chanl:recv-blocks-p
           (jsonrpc/connection:connection-outbox connection)))
         (zerop
          (hash-table-count
           (jsonrpc/connection::connection-response-callback connection))))))

(defun lsp-snippet-test-item
    (label text
     &key filter-text text-edit
       (additional-text-edits nil additional-text-edits-p)
       (data nil data-p))
  (apply #'make-instance
         'lsp:completion-item
         :label label
         :filter-text (or filter-text label)
         :insert-text text
         :insert-text-format lsp:insert-text-format-snippet
         (append
          (when text-edit (list :text-edit text-edit))
          (when additional-text-edits-p
            (list :additional-text-edits additional-text-edits))
          (when data-p (list :data data)))))

(defun lsp-snippet-test-additional-edit (start end text)
  (make-instance 'lsp:text-edit
                 :range (lsp-snippet-test-range start end)
                 :new-text text))

(defun lsp-snippet-test-make-read-only (start-offset end-offset)
  (with-point ((start (buffer-start-point (current-buffer)))
               (end (buffer-start-point (current-buffer))))
    (character-offset start start-offset)
    (character-offset end end-offset)
    (put-text-property start end :read-only t)))

(defun lsp-snippet-test-workspace (client)
  (make-instance
   'lem-lsp-mode::workspace
   :client client
   :server-capabilities
   (make-instance
    'lsp:server-capabilities
    :completion-provider
    (make-instance 'lsp:completion-options :resolve-provider t))))

(defun lsp-snippet-test-open-resolvable-item
    (item &key response error-message)
  (let ((client (make-instance 'lsp-snippet-test-client
                               :response response
                               :error-message error-message)))
    (lsp-snippet-test-open-items
     (list item)
     (lsp-snippet-test-workspace client))))

(define-command lem-yath-test-lsp-snippet-insert-setup () ()
  (lsp-snippet-test-reset "insert" "pri" 3)
  (lsp-snippet-test-open-items
   (list (lsp-snippet-test-item
          "INSERT-SNIPPET" "print(${1:value})$0"
          :filter-text "pri"))))

(define-command lem-yath-test-lsp-snippet-text-edit-setup () ()
  (lsp-snippet-test-reset "text-edit" "foTAIL" 2)
  (lsp-snippet-test-open-items
   (list
    (lsp-snippet-test-item
     "FUNCTION-SNIPPET"
     "ignored"
     :filter-text "fo"
     :text-edit
     (make-instance 'lsp:text-edit
                    :range (lsp-snippet-test-range 0 6)
                    :new-text "fn(${1:name}, $1)$0")))))

(define-command lem-yath-test-lsp-snippet-insert-replace-setup () ()
  (lsp-snippet-test-reset "insert-replace" "foTAIL" 2)
  (lsp-snippet-test-open-items
   (list
    (lsp-snippet-test-item
     "INSERT-REPLACE-SNIPPET"
     "ignored"
     :filter-text "fo"
     :text-edit
     (make-instance 'lsp:insert-replace-edit
                    :new-text "ir(${1:x})$0"
                    :insert (lsp-snippet-test-range 0 2)
                    :replace (lsp-snippet-test-range 0 6))))))

(define-command lem-yath-test-lsp-snippet-plain-setup () ()
  (lsp-snippet-test-reset "plain" "pla" 3)
  (lsp-snippet-test-open-items
   (list
    (make-instance 'lsp:completion-item
                   :label "PLAIN-ITEM"
                   :filter-text "pla"
                   :insert-text "plain$1${2:x}"
                   :insert-text-format lsp:insert-text-format-plain-text))))

(define-command lem-yath-test-lsp-snippet-empty-fallback-setup () ()
  (lsp-snippet-test-reset "empty-fallback" "lab" 3)
  (lsp-snippet-test-open-items
   (list
    (make-instance 'lsp:completion-item
                   :label "labelFallback"
                   :filter-text ""
                   :insert-text ""
                   :sort-text ""
                   :insert-text-format lsp:insert-text-format-plain-text))))

(define-command lem-yath-test-lsp-snippet-multiple-setup () ()
  (lsp-snippet-test-reset "multiple" "f" 1)
  (lsp-snippet-test-open-items
   (list (lsp-snippet-test-item "A-FOO" "foo(${1:x})$0"
                                :filter-text "f")
         (lsp-snippet-test-item "B-FAR" "far(${1:y})$0"
                                :filter-text "f"))))

(define-command lem-yath-test-lsp-snippet-malformed-setup () ()
  (lsp-snippet-test-reset "malformed" "bad" 3)
  (lsp-snippet-test-open-items
   (list (lsp-snippet-test-item "BROKEN-SNIPPET" "oops(${1:broken"
                                :filter-text "bad"))))

(define-command lem-yath-test-lsp-snippet-inert-setup () ()
  (lsp-snippet-test-reset "inert" "evil" 4)
  (lsp-snippet-test-open-items
   (list
    (lsp-snippet-test-item
     "INERT-SNIPPET"
     "`(progn (setf *lsp-snippet-test-pwned* t) \"BAD\")`-${1:safe}$0"
     :filter-text "evil"))))

(define-command lem-yath-test-lsp-snippet-additional-setup () ()
  (lsp-snippet-test-reset "additional" "AAfoTAILZZ" 4)
  (lsp-snippet-test-open-items
   (list
    (lsp-snippet-test-item
     "ADDITIONAL-SNIPPET"
     "ignored"
     :filter-text "fo"
     :text-edit
     (make-instance 'lsp:text-edit
                    :range (lsp-snippet-test-range 2 8)
                    :new-text "call(${1:x}, $1)$0")
     :additional-text-edits
     (vector
      (lsp-snippet-test-additional-edit 0 2 "PRE$1-")
      (lsp-snippet-test-additional-edit 8 10 "-POST"))))))

(define-command lem-yath-test-lsp-snippet-utf16-setup () ()
  (lsp-snippet-test-reset "utf16" "😀AAfoTAIL😀ZZ" 5)
  (lsp-snippet-test-open-items
   (list
    (lsp-snippet-test-item
     "UTF16-SNIPPET"
     "ignored"
     :filter-text "fo"
     :text-edit
     (make-instance 'lsp:text-edit
                    :range (lsp-snippet-test-range 4 10)
                    :new-text "utf(${1:x})$0")
     :additional-text-edits
     (vector
      (lsp-snippet-test-additional-edit 0 4 "PRE-")
      (lsp-snippet-test-additional-edit 10 14 "-POST"))))))

(define-command lem-yath-test-lsp-snippet-frozen-setup () ()
  (lsp-snippet-test-reset "frozen" "AAfoTAILZZ" 4)
  (lsp-snippet-test-open-frozen-items
   (list
    (lsp-snippet-test-item
     "FROZEN-SNIPPET"
     "ignored"
     :filter-text "fox"
     :text-edit
     (make-instance 'lsp:text-edit
                    :range (lsp-snippet-test-range 2 8)
                    :new-text "frozen(${1:value})$0")
     :additional-text-edits
     (vector (lsp-snippet-test-additional-edit 8 10 "-POST"))))))

(define-command lem-yath-test-lsp-snippet-out-of-range-additional-setup () ()
  (lsp-snippet-test-reset "out-of-range-additional" "AAfoTAILZZ" 4)
  (lsp-snippet-test-open-items
   (list
    (lsp-snippet-test-item
     "OUT-OF-RANGE-ADDITIONAL-SNIPPET"
     "ignored"
     :filter-text "fo"
     :text-edit
     (make-instance 'lsp:text-edit
                    :range (lsp-snippet-test-range 2 8)
                    :new-text "safe(${1:x})$0")
     :additional-text-edits
     (vector
      (make-instance 'lsp:text-edit
                     :range (lsp-snippet-test-invalid-range)
                     :new-text "OUT-OF-RANGE"))))))

(define-command lem-yath-test-lsp-snippet-overlap-main-setup () ()
  (lsp-snippet-test-reset "overlap-main" "AAfoTAILZZ" 4)
  (lsp-snippet-test-open-items
   (list
    (lsp-snippet-test-item
     "OVERLAP-MAIN-SNIPPET"
     "ignored"
     :filter-text "fo"
     :text-edit
     (make-instance 'lsp:text-edit
                    :range (lsp-snippet-test-range 2 8)
                    :new-text "main(${1:x})$0")
     :additional-text-edits
     (vector (lsp-snippet-test-additional-edit 3 5 "OVERLAP"))))))

(define-command lem-yath-test-lsp-snippet-overlap-pair-setup () ()
  (lsp-snippet-test-reset "overlap-pair" "AAfoTAILZZ" 4)
  (lsp-snippet-test-open-items
   (list
    (lsp-snippet-test-item
     "OVERLAP-PAIR-SNIPPET"
     "ignored"
     :filter-text "fo"
     :text-edit
     (make-instance 'lsp:text-edit
                    :range (lsp-snippet-test-range 2 8)
                    :new-text "pair(${1:x})$0")
     :additional-text-edits
     (vector
      (lsp-snippet-test-additional-edit 8 10 "FIRST")
      (lsp-snippet-test-additional-edit 9 10 "SECOND"))))))

(define-command lem-yath-test-lsp-snippet-adjacent-insertion-setup () ()
  (lsp-snippet-test-reset "adjacent-insertion" "AAfoTAILZZ" 4)
  (lsp-snippet-test-open-items
   (list
    (lsp-snippet-test-item
     "ADJACENT-INSERTION-SNIPPET"
     "ignored"
     :filter-text "fo"
     :text-edit
     (make-instance 'lsp:text-edit
                    :range (lsp-snippet-test-range 2 8)
                    :new-text "boundary(${1:x})$0")
     :additional-text-edits
     (vector
      (lsp-snippet-test-additional-edit 8 8 "-EDGE"))))))

(define-command lem-yath-test-lsp-snippet-read-only-preflight-setup () ()
  (lsp-snippet-test-reset "read-only-preflight" "AAfoTAILZZ" 4)
  (lsp-snippet-test-make-read-only 0 2)
  (lsp-snippet-test-open-items
   (list
    (lsp-snippet-test-item
     "READ-ONLY-PREFLIGHT-SNIPPET"
     "ignored"
     :filter-text "fo"
     :text-edit
     (make-instance 'lsp:text-edit
                    :range (lsp-snippet-test-range 2 8)
                    :new-text "readonly(${1:x})$0")
     :additional-text-edits
     (vector
      ;; Descending application would mutate this writable suffix first.
      (lsp-snippet-test-additional-edit 8 10 "-POST")
      ;; Preflight must reject this later, protected prefix before any edit.
      (lsp-snippet-test-additional-edit 0 2 "PRE-"))))))

(define-command lem-yath-test-lsp-snippet-transaction-rollback-setup () ()
  (lsp-snippet-test-reset "transaction-rollback" "AAfoTAILZZ" 4)
  (lsp-snippet-test-open-items
   (list
    (lsp-snippet-test-item
     "TRANSACTION-ROLLBACK-SNIPPET"
     "ignored"
     :filter-text "fo"
     :text-edit
     (make-instance 'lsp:text-edit
                    :range (lsp-snippet-test-range 2 8)
                    :new-text "atomic(${1:x})$0")
     :additional-text-edits
     (vector
      (lsp-snippet-test-additional-edit 0 2 "PRE-")
      (lsp-snippet-test-additional-edit 8 10 "-POST")))))
  (setf *lsp-snippet-test-rollback-baseline*
        (lem:buffer-undo-tree-snapshot (current-buffer)))
  (add-hook
   (variable-value 'after-change-functions :buffer (current-buffer))
   'lsp-snippet-test-mutating-throwing-hook
   20000))

(define-command lem-yath-test-lsp-snippet-resolve-setup () ()
  (lsp-snippet-test-reset "resolve" "AAfoTAILZZ" 4)
  (let* ((response
           (make-instance
            'lsp:completion-item
            :label "RESOLVED-SNIPPET"
            ;; Resolve is not allowed to change the primary insertion.  This
            ;; deliberately hostile value proves the original item still wins.
            :insert-text "WRONG-RESOLVED-TEXT"
            :insert-text-format lsp:insert-text-format-plain-text
            :additional-text-edits
            (vector
             (lsp-snippet-test-additional-edit 0 2 "RES-")
             (lsp-snippet-test-additional-edit 8 10 "-OK"))))
         (item
           (lsp-snippet-test-item
            "RESOLVE-SNIPPET"
            "ignored"
            :filter-text "fo"
            :text-edit
            (make-instance 'lsp:text-edit
                           :range (lsp-snippet-test-range 2 8)
                           :new-text "resolved(${1:name})$0")
            :data (lem-lsp-base/type:make-lsp-map
                   "fixture" "acceptance"))))
    (lsp-snippet-test-open-resolvable-item item :response response)))

(define-command lem-yath-test-lsp-snippet-resolve-error-setup () ()
  (lsp-snippet-test-reset "resolve-error" "AAfoTAILZZ" 4)
  (lsp-snippet-test-open-resolvable-item
   (lsp-snippet-test-item
    "RESOLVE-ERROR-SNIPPET"
    "ignored"
    :filter-text "fo"
    :text-edit
    (make-instance 'lsp:text-edit
                   :range (lsp-snippet-test-range 2 8)
                   :new-text "once(${1:value})$0")
    :additional-text-edits
    (vector (lsp-snippet-test-additional-edit 0 2 "ORIG-"))
    :data (lem-lsp-base/type:make-lsp-map "fixture" "error"))
   :error-message "fixture completion resolve failure"))

(define-command lem-yath-test-lsp-snippet-resolve-conflict-setup () ()
  (lsp-snippet-test-reset "resolve-conflict" "AAfoTAILZZ" 4)
  (let ((response
          (make-instance
           'lsp:completion-item
           :label "RESOLVED-CONFLICT"
           :insert-text "WRONG-RESOLVED-INSERT"
           :insert-text-format lsp:insert-text-format-plain-text
           :text-edit
           (make-instance 'lsp:text-edit
                          :range (lsp-snippet-test-range 0 10)
                          :new-text "WRONG-RESOLVED-TEXT-EDIT")
           :additional-text-edits
           (vector
            (lsp-snippet-test-additional-edit 0 2 "NEW-")
            (lsp-snippet-test-additional-edit 8 10 "-EXTRA")))))
    (lsp-snippet-test-open-resolvable-item
     (lsp-snippet-test-item
      "RESOLVE-CONFLICT-SNIPPET"
      "ignored"
      :filter-text "fo"
      :text-edit
      (make-instance 'lsp:text-edit
                     :range (lsp-snippet-test-range 2 8)
                     :new-text "stable(${1:name}, $1)$0")
      :data (lem-lsp-base/type:make-lsp-map "fixture" "conflict"))
     :response response)))

(defun lsp-snippet-test-completion-item-capabilities ()
  (let* ((capabilities (lem-lsp-mode::client-capabilities))
         (text-document
           (lsp:client-capabilities-text-document capabilities))
         (completion
           (lsp:text-document-client-capabilities-completion text-document))
         (completion-item
           (lsp:completion-client-capabilities-completion-item completion)))
    completion-item))

(defun lsp-snippet-test-capability-value ()
  (gethash "snippetSupport"
           (lsp-snippet-test-completion-item-capabilities)))

(defun lsp-snippet-test-position-encodings ()
  (handler-case
      (let* ((capabilities (lem-lsp-mode::client-capabilities))
             (general (lsp:client-capabilities-general capabilities)))
        (lsp:general-client-capabilities-position-encodings general))
    (unbound-slot () nil)))

(define-command lem-yath-test-lsp-snippet-static-checks () ()
  (let ((failures 0))
    (labels ((check (condition label)
               (lsp-snippet-test-report
                "~a STATIC ~a"
                (if condition "PASS" "FAIL") label)
               (unless condition
                 (incf failures)))
             (converted (item)
               (first (lsp-snippet-test-convert-items (list item)))))
      (handler-case
          (progn
            (check (lsp-snippet-test-capability-value)
                   "capability-enabled-with-handler")
            (let ((encodings (lsp-snippet-test-position-encodings)))
              (check
               (and (vectorp encodings)
                    (= 1 (length encodings))
                    (string= "utf-16" (aref encodings 0)))
               "capability-position-encoding-is-utf16-only"))
            (let* ((completion-item
                     (lsp-snippet-test-completion-item-capabilities))
                   (resolve-support
                     (gethash "resolveSupport" completion-item))
                   (properties
                     (and (hash-table-p resolve-support)
                          (gethash "properties" resolve-support))))
              (check (gethash "insertReplaceSupport" completion-item)
                     "capability-insert-replace-support")
              (check
               (and (vectorp properties)
                    (= 1 (length properties))
                    (string= "additionalTextEdits" (aref properties 0)))
               "capability-resolve-support-is-bounded"))
            (let ((saved
                    (variable-value
                     'lem/completion-mode:completion-snippet-preparation-function
                     :global)))
              (unwind-protect
                   (progn
                     (setf (variable-value
                            'lem/completion-mode:completion-snippet-preparation-function
                            :global)
                           nil)
                     (check (not (lsp-snippet-test-capability-value))
                            "capability-disabled-without-handler"))
                (setf (variable-value
                       'lem/completion-mode:completion-snippet-preparation-function
                       :global)
                      saved)))
            (let* ((plain
                     (converted
                      (make-instance
                       'lsp:completion-item
                       :label "PLAIN"
                       :insert-text "literal$1"
                       :insert-text-format lsp:insert-text-format-plain-text)))
                   (snippet
                     (converted
                      (lsp-snippet-test-item "SNIPPET" "${1:value}$0"))))
              (check
               (null
                (lem/completion-mode:completion-item-final-insert-action plain))
               "plain-format-has-default-inserter")
              (check
               (functionp
                (lem/completion-mode:completion-item-final-insert-action
                 snippet))
               "snippet-format-has-final-inserter"))
            (lsp-snippet-test-reset "static-empty-fallback" "lab" 3)
            (let* ((label "labelFallback")
                   (item
                     (make-instance
                      'lsp:completion-item
                      :label label
                      :filter-text ""
                      :insert-text ""
                      :sort-text ""
                      :insert-text-format
                      lsp:insert-text-format-plain-text))
                   (converted (converted item)))
              (check
               (and
                (string=
                 label
                 (lem/completion-mode:completion-item-filter-text converted))
                (string=
                 label
                 (lem/completion-mode:completion-item-insert-text converted))
                (string=
                 label
                 (lem-lsp-mode::completion-item-sort-text converted)))
               "empty-completion-strings-fall-back-to-label"))
            (check
             (lsp-snippet-test-position-roundtrip-p
              "utf-8" #(0 1 5 6))
             "utf8-position-helper-roundtrip")
            (check
             (lsp-snippet-test-position-roundtrip-p
              "utf-16" #(0 1 3 4))
             "utf16-position-helper-roundtrip")
            (check
             (lsp-snippet-test-position-roundtrip-p
              "utf-32" #(0 1 2 3))
             "utf32-position-helper-roundtrip")
            (check
             (lsp-snippet-test-split-units-rejected-p
              "utf-8" '(2 3 4 7))
             "utf8-split-units-rejected")
            (check
             (lsp-snippet-test-split-units-rejected-p
              "utf-16" '(2 5))
             "utf16-split-units-rejected")
            (lsp-snippet-test-reset
             "static-outbound-position" "a😀b" 2)
            (dolist (spec '(("utf-8" 5 "utf8-outbound-position-range")
                            ("utf-16" 3 "utf16-outbound-position-range")
                            ("utf-32" 2 "utf32-outbound-position-range")))
              (destructuring-bind (encoding character label) spec
                (check
                 (lsp-snippet-test-outbound-position-p
                  encoding character)
                 label)))
            (lsp-snippet-test-reset
             "static-apply-text-edits-utf16" "a😀b" 0)
            (lem-lsp-mode::apply-text-edits
             (current-buffer)
             (vector
              (make-instance
               'lsp:text-edit
               :range (lsp-snippet-test-range 1 3)
               :new-text "X"))
             (lsp-snippet-test-encoding-workspace "utf-16"))
            (check
             (string= "aXb" (lsp-snippet-test-buffer-text))
             "apply-text-edits-decodes-utf16")
            (lsp-snippet-test-reset
             "static-apply-adjacent-edits" "abcdef" 0)
            (lem-lsp-mode::apply-text-edits
             (current-buffer)
             (vector
              ;; Ascending server order is deliberately adverse: applying the
              ;; first edit eagerly would invalidate the second edit's offset.
              (make-instance
               'lsp:text-edit
               :range (lsp-snippet-test-range 0 3)
               :new-text "LEFT")
              (make-instance
               'lsp:text-edit
               :range (lsp-snippet-test-range 3 6)
               :new-text "RIGHT"))
             (lsp-snippet-test-encoding-workspace "utf-16"))
            (check
             (string= "LEFTRIGHT" (lsp-snippet-test-buffer-text))
             "apply-text-edits-preserves-adjacent-ranges")
            (lsp-snippet-test-reset
             "static-apply-invalid-later" "abcdef" 0)
            (let ((rejected-p nil))
              (handler-case
                  (lem-lsp-mode::apply-text-edits
                   (current-buffer)
                   (vector
                    (make-instance
                     'lsp:text-edit
                     :range (lsp-snippet-test-range 0 1)
                     :new-text "MUTATED")
                    (make-instance
                     'lsp:text-edit
                     :range (lsp-snippet-test-invalid-range)
                     :new-text "INVALID"))
                   (lsp-snippet-test-encoding-workspace "utf-16"))
                (error ()
                  (setf rejected-p t)))
              (check
               (and rejected-p
                    (string= "abcdef" (lsp-snippet-test-buffer-text)))
               "apply-text-edits-invalid-later-is-atomic"))
            (lsp-snippet-test-reset
             "static-workspace-edit-origin" "a😀b" 0)
            (let* ((buffer (current-buffer))
                   (workspace
                     (lsp-snippet-test-encoding-workspace "utf-8"))
                   (changes
                     (lem-lsp-base/type:make-lsp-map
                      (lem-lsp-mode::buffer-uri buffer)
                      (vector
                       (make-instance
                        'lsp:text-edit
                        :range (lsp-snippet-test-range 1 5)
                        :new-text "Y"))))
                   (edit (make-instance 'lsp:workspace-edit
                                        :changes changes)))
              (lem-lsp-mode::apply-workspace-edit workspace edit)
              (check
               (string= "aYb" (lsp-snippet-test-buffer-text))
               "workspace-edit-preserves-origin-encoding"))
            (lsp-snippet-test-reset
             "static-diagnostic-utf8" "a😀b" 0)
            (check
             (lsp-snippet-test-diagnostic-decoding-p
              (lsp-snippet-test-encoding-workspace "utf-8"))
             "diagnostic-range-decodes-utf8")
            (lsp-snippet-test-reset
             "static-highlight-utf16" "a😀b" 0)
            (check
             (lsp-snippet-test-highlight-decoding-p
              (lsp-snippet-test-encoding-workspace "utf-16"))
             "document-highlight-range-decodes-utf16")
            (lsp-snippet-test-reset
             "static-symbol-utf16" "a😀b" 0)
            (check
             (lsp-snippet-test-document-symbol-decoding-p
              (lsp-snippet-test-encoding-workspace "utf-16"))
             "document-symbol-range-decodes-utf16")
            (lsp-snippet-test-reset
             "static-definition-utf8" "a😀b" 0)
            (check
             (lsp-snippet-test-definition-decoding-p
              (lsp-snippet-test-encoding-workspace "utf-8"))
             "definition-range-decodes-utf8")
            (check
             (lsp-snippet-test-source-position-guard-p)
             "lsp-source-has-no-codepoint-only-call-sites")
            (check
             (lsp-snippet-test-jsonrpc-late-response-clean-p)
             "jsonrpc-late-response-leaves-no-state")
            (check
             (lsp-snippet-test-jsonrpc-timeout-cleans-callback-p)
             "jsonrpc-timeout-removes-callback")
            (lsp-snippet-test-reset
             "static-main-out-of-range" "foTAIL" 2)
            (check
             (lsp-snippet-test-conversion-rejected-p
              (lsp-snippet-test-item
               "MAIN-OUT-OF-RANGE" "ignored"
               :text-edit
               (make-instance 'lsp:text-edit
                              :range (lsp-snippet-test-invalid-range)
                              :new-text "bad")))
             "main-text-edit-out-of-range-rejected")
            (lsp-snippet-test-reset
             "static-main-multiline" "fo\nTAIL" 2)
            (check
             (lsp-snippet-test-conversion-rejected-p
              (lsp-snippet-test-item
               "MAIN-MULTILINE" "ignored"
               :text-edit
               (make-instance
                'lsp:text-edit
                :range (lsp-snippet-test-line-range 0 0 1 4)
                :new-text "bad")))
             "main-text-edit-multiline-rejected")
            (lsp-snippet-test-reset
             "static-main-misses-request" "AAfoTAIL" 4)
            (check
             (lsp-snippet-test-conversion-rejected-p
              (lsp-snippet-test-item
               "MAIN-MISSES-REQUEST" "ignored"
               :text-edit
               (make-instance 'lsp:text-edit
                              :range (lsp-snippet-test-range 0 2)
                              :new-text "bad")))
             "main-text-edit-must-contain-request")
            (lsp-snippet-test-reset
             "static-insert-replace-prefix" "foTAIL" 2)
            (check
             (lsp-snippet-test-conversion-rejected-p
              (lsp-snippet-test-item
               "INSERT-REPLACE-NONPREFIX" "ignored"
               :text-edit
               (make-instance
                'lsp:insert-replace-edit
                :new-text "bad"
                :insert (lsp-snippet-test-range 0 6)
                :replace (lsp-snippet-test-range 0 2))))
             "insert-replace-insert-must-prefix-replace")
            (lsp-snippet-test-reset
             "static-mixed-main-ranges" "foTAIL" 2)
            (let ((converted
                    (lsp-snippet-test-convert-items
                     (list
                      (lsp-snippet-test-item
                       "INVALID-MAIN" "ignored"
                       :text-edit
                       (make-instance
                        'lsp:text-edit
                        :range (lsp-snippet-test-invalid-range)
                        :new-text "bad"))
                      (lsp-snippet-test-item
                       "VALID-MAIN" "ignored"
                       :text-edit
                       (make-instance
                        'lsp:text-edit
                        :range (lsp-snippet-test-range 0 6)
                        :new-text "valid(${1:x})$0"))))))
              (check
               (and (= 1 (length converted))
                    (string=
                     "VALID-MAIN"
                     (lem/completion-mode:completion-item-label
                      (first converted))))
               "malformed-main-does-not-discard-valid-sibling"))
            (lsp-snippet-test-reset "static-range" "foTAIL" 2)
            (let* ((item
                     (lsp-snippet-test-item
                      "RANGE" "ignored"
                      :text-edit
                      (make-instance 'lsp:text-edit
                                     :range (lsp-snippet-test-range 0 6)
                                     :new-text "${1:x}$0")))
                   (converted (converted item)))
              (lsp-snippet-test-report
               "DETAIL range start=~d end=~d"
               (position-at-point
                (lem/completion-mode::completion-item-start converted))
               (position-at-point
                (lem/completion-mode::completion-item-end converted)))
              (check
               (and (= 1 (position-at-point
                          (lem/completion-mode::completion-item-start
                           converted)))
                    (= 7 (position-at-point
                          (lem/completion-mode::completion-item-end
                           converted))))
               "text-edit-preserves-full-range"))
            (lsp-snippet-test-reset "static-success" "token" 5)
            (let ((insert-count 0)
                  (accept-count 0))
              (lem/completion-mode:run-completion
               (lambda (point)
                 (declare (ignore point))
                 (list
                  (lem/completion-mode:make-completion-item
                   :label "CUSTOM"
                   :filter-text "token"
                   :final-insert-action
                   (lambda (point start end)
                     (incf insert-count)
                     (delete-between-points start end)
                     (move-point point start)
                     (insert-string point "custom")
                     t)
                   :accept-action (lambda () (incf accept-count))))))
              (lsp-snippet-test-report
               "DETAIL custom insert-count=~d accept-count=~d text-hex=~a"
               insert-count accept-count
               (lsp-snippet-test-hex (lsp-snippet-test-buffer-text)))
              (check (and (= insert-count 1) (= accept-count 1)
                          (string= "custom"
                                   (lsp-snippet-test-buffer-text)))
                     "custom-insert-and-post-actions-once"))
            (lsp-snippet-test-reset "static-failure" "keep" 4)
            (let ((accept-count 0))
              (lem/completion-mode:run-completion
               (lambda (point)
                 (declare (ignore point))
                 (list
                  (lem/completion-mode:make-completion-item
                   :label "FAIL"
                   :filter-text "keep"
                   :final-insert-action
                   (lambda (point start end)
                     (declare (ignore point start end))
                     nil)
                   :accept-action (lambda () (incf accept-count))))))
              (check (and (zerop accept-count)
                          (string= "keep" (lsp-snippet-test-buffer-text)))
                     "failed-custom-insert-preserves-text-and-skips-post")))
        (error (condition)
          (lsp-snippet-test-report "FAIL STATIC unhandled-error=~a" condition)
          (incf failures)))
      (ignore-errors (lem/completion-mode:completion-end))
      (lsp-snippet-test-report
       "SUMMARY STATIC ~a failures=~d"
       (if (zerop failures) "PASS" "FAIL") failures))))

(define-command lem-yath-test-lsp-snippet-record-state () ()
  (lsp-snippet-test-report
   (concatenate
    'string
    "STATE label=~a text-hex=~a point=~d active=~a field=~a "
    "completion=~a local=~a focus=~a pwned=~a hook=~a group=~a history=~a")
   (buffer-value (current-buffer) :lsp-snippet-test-label)
   (lsp-snippet-test-hex (lsp-snippet-test-buffer-text))
   (position-at-point (current-point))
   (if (snippet-active-session-p) "yes" "no")
   (or (snippet-current-field-number) "none")
   (if lem/completion-mode::*completion-context* "yes" "no")
   (if (lem/completion-mode:completion-local-filtering-p) "yes" "no")
   (or (lsp-snippet-test-focus-label) "none")
   (if *lsp-snippet-test-pwned* "yes" "no")
   (if *lsp-snippet-test-throwing-hook-fired-p* "yes" "no")
   (if (lem/buffer/internal::buffer-%active-change-group (current-buffer))
       "yes"
       "no")
   (if (lsp-snippet-test-rollback-history-restored-p) "yes" "no")))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*insert-keymap*
                      lem-vi-mode:*visual-keymap*
                      lem/completion-mode::*completion-mode-keymap*))
  (define-key keymap "F12" 'lem-yath-test-lsp-snippet-record-state))

(pushnew 'lem-yath-test-lsp-snippet-record-state
         *auto-completion-continue-commands*)

(lsp-snippet-test-report "READY")
