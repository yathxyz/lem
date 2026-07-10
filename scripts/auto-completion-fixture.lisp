(in-package :lem-yath)

(define-major-mode lem-yath-auto-test-mode ()
    (:name "AutoTest"))

(define-major-mode lem-yath-auto-other-mode ()
    (:name "AutoOther"))

(defvar *auto-test-callbacks* (make-hash-table :test 'equal))
(defvar *auto-test-primary-label* "primaryOnlyCandidate")
(defvar *auto-test-origin-buffer* nil)

(defun auto-test-report (control &rest arguments)
  (with-open-file (stream (uiop:getenv "LEM_YATH_AUTO_COMPLETION_REPORT")
                          :direction :output
                          :if-exists :append
                          :if-does-not-exist :create)
    (apply #'format stream control arguments)
    (terpri stream)))

(defun auto-test-buffer-text ()
  (points-to-string (buffer-start-point (current-buffer))
                    (buffer-end-point (current-buffer))))

(defun auto-test-fill-buffer (name mode text)
  (let ((buffer (or (get-buffer name) (make-buffer name))))
    (change-buffer-mode buffer mode)
    (with-current-buffer buffer
      (erase-buffer buffer)
      (insert-string (buffer-point buffer) text)
      (buffer-start (buffer-point buffer)))
    buffer))

(defun auto-test-reset-current-buffer ()
  (lem/completion-mode:completion-end)
  (auto-completion-cancel-timer)
  (setf *auto-completion-context* nil)
  (change-buffer-mode (current-buffer) 'lem-yath-auto-test-mode)
  (setf (variable-value 'lem/language-mode:completion-spec
                        :buffer (current-buffer))
        nil)
  (erase-buffer (current-buffer)))

(defun auto-test-dabbrev-source-text ()
  (with-output-to-string (stream)
    (dotimes (index 12)
      (format stream "alphaCandidate~2,'0d~%" index))))

(define-command lem-yath-test-auto-dabbrev-setup () ()
  (auto-test-reset-current-buffer)
  (setf *auto-test-origin-buffer* (current-buffer))
  (auto-test-fill-buffer "*auto-completion-source*"
                         'lem-yath-auto-test-mode
                         (auto-test-dabbrev-source-text))
  (auto-test-fill-buffer "*auto-completion-foreign*"
                         'lem-yath-auto-other-mode
                         "alphaForeignCandidate\n")
  (auto-test-fill-buffer "*auto-completion-target*"
                         'lem-yath-auto-other-mode
                         "")
  (auto-test-report "SETUP dabbrev"))

(define-command lem-yath-test-auto-middle-setup () ()
  (auto-test-reset-current-buffer)
  (setf *auto-test-primary-label* "banana")
  (auto-test-fill-buffer "*auto-completion-source*"
                         'lem-yath-auto-test-mode
                         "")
  (setf (variable-value 'lem/language-mode:completion-spec
                        :buffer (current-buffer))
        #'auto-test-primary-provider)
  (insert-string (current-point) "baZZ")
  (buffer-start (current-point))
  (character-offset (current-point) 2)
  (auto-test-report "SETUP middle"))

(defun auto-test-primary-provider (point)
  (multiple-value-bind (start end prefix)
      (auto-completion-symbol-bounds point)
    (auto-test-report "PRIMARY ~a" prefix)
    (list
     (lem/completion-mode:make-completion-item
      :label *auto-test-primary-label*
      :filter-text *auto-test-primary-label*
      :insert-text *auto-test-primary-label*
      :detail "Primary"
      :start start
      :end end
      :accept-action
      (lambda ()
        (auto-test-report "ACCEPT primary buffer=~a"
                          (auto-test-buffer-text)))))))

(define-command lem-yath-test-auto-primary-setup () ()
  (auto-test-reset-current-buffer)
  (setf *auto-test-primary-label* "primaryOnlyCandidate")
  (auto-test-fill-buffer "*auto-completion-source*"
                         'lem-yath-auto-test-mode
                         "privateFallbackCandidate\n")
  (setf (variable-value 'lem/language-mode:completion-spec
                        :buffer (current-buffer))
        #'auto-test-primary-provider)
  (auto-test-report "SETUP primary"))

(define-command lem-yath-test-auto-cancel-setup () ()
  (auto-test-reset-current-buffer)
  (setf *auto-test-primary-label* "cancelShouldNotAppear")
  (auto-test-fill-buffer "*auto-completion-source*"
                         'lem-yath-auto-test-mode
                         "")
  (setf (variable-value 'lem/language-mode:completion-spec
                        :buffer (current-buffer))
        #'auto-test-primary-provider)
  (auto-test-report "SETUP cancel"))

(define-command lem-yath-test-auto-file-setup () ()
  (auto-test-reset-current-buffer)
  (auto-test-fill-buffer "*auto-completion-source*"
                         'lem-yath-auto-test-mode
                         "")
  (alexandria:when-let ((directory
                         (uiop:getenv "LEM_YATH_AUTO_COMPLETION_FILE_DIR")))
    (setf (buffer-directory) directory))
  (auto-test-report "SETUP file directory=~a" (buffer-directory)))

(defun auto-test-async-provider (point then)
  (multiple-value-bind (start end query)
      (auto-completion-symbol-bounds point)
    (declare (ignore start end))
    (setf (gethash query *auto-test-callbacks*) then)
    (auto-test-report "REQUEST ~a" query)))

(define-command lem-yath-test-auto-async-setup () ()
  (auto-test-reset-current-buffer)
  (clrhash *auto-test-callbacks*)
  (auto-test-fill-buffer "*auto-completion-source*"
                         'lem-yath-auto-test-mode
                         "")
  (setf (variable-value 'lem/language-mode:completion-spec
                        :buffer (current-buffer))
        (lem/completion-mode:make-completion-spec
         #'auto-test-async-provider :async t))
  (auto-test-report "SETUP async"))

(define-command lem-yath-test-deliver-old-auto-completion () ()
  (alexandria:when-let ((callback (gethash "asy" *auto-test-callbacks*)))
    (auto-test-report "DELIVER old")
    (funcall callback
             (list
              (lem/completion-mode:make-completion-item
               :label "STALE-ASY"
               :insert-text "stale_async")))))

(define-command lem-yath-test-auto-move-left () ()
  (character-offset (current-point) -1))

(define-command lem-yath-test-auto-switch-buffer () ()
  (switch-to-buffer (get-buffer "*auto-completion-target*")))

(define-command lem-yath-test-report-auto-completion-state () ()
  (let ((context lem/completion-mode::*completion-context*))
    (if context
        (progn
          (auto-test-report
           "STATE context automatic=~s max=~s cycle=~s items=~d popup=~s buffer=~a"
           (lem/completion-mode::context-automatic-p context)
           (lem/completion-mode::context-max-display-items context)
           (lem/completion-mode::context-cycle-p context)
           (length (lem/completion-mode::context-last-items context))
           (not (null (lem/completion-mode::context-popup-menu context)))
           (auto-test-buffer-text))
          (alexandria:when-let*
              ((popup (lem/completion-mode::context-popup-menu context))
               (item (lem/popup-menu:get-focus-item popup)))
            (auto-test-report
             "FOCUS ~a"
             (lem/completion-mode:completion-item-label item))))
        (auto-test-report "STATE none buffer=~a timer=~s"
                          (auto-test-buffer-text)
                          (not (null *auto-completion-timer*))))
    (when *auto-test-origin-buffer*
      (auto-test-report
       "ORIGIN completion-mode=~s"
       (mode-active-p *auto-test-origin-buffer*
                      'lem/completion-mode:completion-mode)))))

(define-command lem-yath-test-auto-completion-static-checks () ()
  (let ((failures 0))
    (labels ((check (condition label)
               (auto-test-report "~a STATIC ~a"
                                 (if condition "PASS" "FAIL")
                                 label)
               (unless condition
                 (incf failures))))
      (check (= 3 *auto-completion-prefix-length*) "prefix-three")
      (check (= 200 *auto-completion-delay-ms*) "delay-200ms")
      (check (= 10 *auto-completion-max-display-items*) "ten-rows")
      (auto-test-reset-current-buffer)
      (let ((called :not-called))
        (lem-lsp-mode::text-document/completion
         (current-point)
         (lambda (items) (setf called items)))
        (check (null called) "lsp-without-workspace-completes-empty"))
      (auto-test-report "SUMMARY STATIC ~a failures=~d"
                        (if (zerop failures) "PASS" "FAIL")
                        failures))))

(define-key lem/completion-mode::*completion-mode-keymap*
  "F5" 'lem-yath-test-report-auto-completion-state)
(define-key lem/completion-mode::*completion-mode-keymap*
  "F8" 'lem-yath-test-auto-move-left)
(define-key lem/completion-mode::*completion-mode-keymap*
  "F9" 'lem-yath-test-auto-switch-buffer)
(pushnew 'lem-yath-test-report-auto-completion-state
         *auto-completion-continue-commands*)
(define-key lem-vi-mode:*insert-keymap*
  "F6" 'lem-yath-test-deliver-old-auto-completion)
(define-key lem-vi-mode:*insert-keymap*
  "F7" 'lem-yath-test-report-auto-completion-state)
(define-key lem-vi-mode:*normal-keymap*
  "F7" 'lem-yath-test-report-auto-completion-state)
