;;;; Temporary GNU Org agenda buffer, subtree, and region restrictions.

(in-package :lem-yath)

(defstruct (agenda-restriction (:constructor make-agenda-restriction))
  kind
  file
  start-line
  end-line)

(defstruct (agenda-restriction-context
            (:constructor make-agenda-restriction-context))
  file
  subtree-start-line
  subtree-end-line
  region-start-line
  region-end-line)

(defun agenda-restriction-file-equal-p (left right)
  (and left right
       (or (ignore-errors (uiop:pathname-equal left right))
           (equal (namestring left) (namestring right)))))

(defun agenda-restriction-inclusive-end-line (point)
  "Return the last line before exclusive POINT."
  (let ((line (line-number-at-point point)))
    (if (and (start-line-p point) (> line 1))
        (1- line)
        line)))

(defun agenda-restriction-active-region-lines (buffer)
  (let ((mark (buffer-mark buffer)))
    (when (and (buffer-mark-p buffer)
               (not (point= mark (buffer-point buffer))))
      (let ((start (region-beginning buffer))
            (end (region-end buffer)))
        (values (line-number-at-point start)
                (agenda-restriction-inclusive-end-line end))))))

(defun agenda-restriction-origin-context (&optional (buffer (current-buffer)))
  "Capture the Org source context used by one agenda dispatcher invocation."
  (let ((file (buffer-filename buffer)))
    (when (and file (mode-active-p buffer 'org-mode))
      (multiple-value-bind (region-start region-end)
          (agenda-restriction-active-region-lines buffer)
        (let* ((heading (org-current-heading-point (buffer-point buffer)))
               (subtree-end (and heading (org-subtree-end-point heading))))
          (make-agenda-restriction-context
           :file file
           :subtree-start-line (and heading (line-number-at-point heading))
           :subtree-end-line
           (and subtree-end
                (agenda-restriction-inclusive-end-line subtree-end))
           :region-start-line region-start
           :region-end-line region-end))))))

(defun agenda-restriction-from-kind (context kind)
  "Return KIND's restriction from dispatcher CONTEXT and whether it is valid."
  (unless context
    (return-from agenda-restriction-from-kind (values nil nil)))
  (let ((file (agenda-restriction-context-file context)))
    (ecase kind
      (:buffer
       (values (make-agenda-restriction :kind :buffer :file file) t))
      (:subtree
       (let ((start (agenda-restriction-context-subtree-start-line context))
             (end (agenda-restriction-context-subtree-end-line context)))
         (if (and start end)
             (values
              (make-agenda-restriction
               :kind :subtree :file file :start-line start :end-line end)
              t)
             (values nil nil))))
      (:region
       (let ((start (agenda-restriction-context-region-start-line context))
             (end (agenda-restriction-context-region-end-line context)))
         (if (and start end (<= start end))
             (values
              (make-agenda-restriction
               :kind :region :file file :start-line start :end-line end)
              t)
             (values nil nil)))))))

(defun agenda-restriction-context-region-p (context)
  (and context
       (agenda-restriction-context-region-start-line context)
       (agenda-restriction-context-region-end-line context)))

(defun agenda-restriction-next-kind (restriction context)
  "Return Org's next restriction kind for repeated `<'."
  (case (and restriction (agenda-restriction-kind restriction))
    (:buffer (if (agenda-restriction-context-region-p context)
                 :region
                 :subtree))
    ((:subtree :region) nil)
    (otherwise :buffer)))

(defun agenda-restriction-matches-p (restriction file line)
  (and (agenda-restriction-file-equal-p
        (agenda-restriction-file restriction) file)
       (or (eq (agenda-restriction-kind restriction) :buffer)
           (and (integerp line)
                (<= (agenda-restriction-start-line restriction) line)
                (<= line (agenda-restriction-end-line restriction))))))

(defun agenda-restriction-scan-scope (buffer files failures)
  "Apply BUFFER's temporary restriction to agenda scan inputs."
  (let ((restriction
          (buffer-value buffer 'lem-yath-agenda-restriction)))
    (if (null restriction)
        (values files failures nil)
        (let ((restricted-files
                (remove-if-not
                 (lambda (file)
                   (agenda-restriction-file-equal-p
                    (agenda-restriction-file restriction) file))
                 files)))
          (values restricted-files nil
                  (lambda (file line)
                    (agenda-restriction-matches-p
                     restriction file line)))))))

(defun agenda-restriction-label (restriction)
  (if restriction
      (string-downcase (symbol-name (agenda-restriction-kind restriction)))
      "unrestricted"))

(defun agenda-restriction-filter-occur-source (source restriction)
  "Restrict zero-based Occur blocks in SOURCE to RESTRICTION's line range."
  (when (and restriction
             (not (eq (agenda-restriction-kind restriction) :buffer)))
    (let* ((first (1- (agenda-restriction-start-line restriction)))
           (last (1- (agenda-restriction-end-line restriction)))
           (blocks
             (remove-if-not
              (lambda (block)
                (and (<= first (buffer-list-occur-block-first-line block))
                     (<= (buffer-list-occur-block-last-line block) last)))
              (buffer-list-occur-source-blocks source))))
      (setf (buffer-list-occur-source-blocks source) blocks
            (buffer-list-occur-source-match-count source)
            (reduce #'+ blocks
                    :key (lambda (block)
                           (length (buffer-list-occur-block-matches block)))
                    :initial-value 0))))
  source)

(setf *agenda-scan-scope-function* #'agenda-restriction-scan-scope)
