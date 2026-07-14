;;;; Pinned Dirvish presentation shared by directory and find-name buffers.

(in-package :lem-yath)

(define-attribute dirvish-size-attribute
  (t :foreground :base03))

(defconstant +dirvish-file-count-overflow+ 15000)

(defun dirvish-native-path (path)
  (etypecase path
    (string path)
    (pathname (uiop:native-namestring path))))

(defun dirvish-count-directory-entries (path)
  "Count PATH's direct children, bounded like pinned Dirvish."
  (let ((program (executable-find "find")))
    (unless program
      (error "Required find executable is unavailable"))
    (multiple-value-bind (output error-output exit-code)
        (uiop:run-program
         (list (namestring program)
               "-H" (dirvish-native-path path)
               "-mindepth" "1" "-maxdepth" "1" "-printf" ".")
         :output :string
         :error-output :string
         :ignore-error-status t)
      (unless (and (integerp exit-code) (zerop exit-code))
        (error "find failed~@[ (~a)~]: ~a"
               exit-code
               (let ((detail
                       (string-trim '(#\Space #\Tab #\Newline #\Return)
                                    error-output)))
                 (if (plusp (length detail)) detail "no diagnostic"))))
      (let ((count (length output)))
        (if (>= count (- +dirvish-file-count-overflow+ 2))
            :many
            count)))))

(defun dirvish-six-cell-field (text)
  (let ((length (length text)))
    (cond
      ((> length 6) (subseq text (- length 6)))
      ((< length 6)
       (concatenate 'string
                    (make-string (- 6 length) :initial-element #\Space)
                    text))
      (t text))))

(defun dirvish-human-readable (number base)
  "Format NUMBER in pinned Dirvish's six-cell size/count representation."
  (let ((value (coerce number 'double-float))
        (base (coerce base 'double-float))
        (prefixes '("" "k" "M" "G" "T" "P" "E" "Z" "Y")))
    (loop :while (and (>= value base) (rest prefixes))
          :do (setf value (/ value base)
                    prefixes (rest prefixes)))
    (let* ((fraction (mod value 1d0))
           (fractional-p
             (and (< value 10d0)
                  (>= fraction 0.05d0)
                  (< fraction 0.95d0))))
      (dirvish-six-cell-field
       (format nil
               (if fractional-p "~,1f~a" "~d~a")
               (if fractional-p value (round value))
               (first prefixes))))))

(defun dirvish-size-field (path)
  "Return pinned Dirvish's six-cell default size attribute for PATH."
  (handler-case
      (let* ((native (dirvish-native-path path))
             (stat (sb-posix:lstat native))
             (type (logand (sb-posix:stat-mode stat) sb-posix:s-ifmt)))
        (cond
          ((= type sb-posix:s-ifdir)
           (let ((count (dirvish-count-directory-entries native)))
             (if (eq count :many)
                 " MANY "
                 (dirvish-human-readable count 1000))))
          ((= type sb-posix:s-iflnk)
           (handler-case
               (let ((target (sb-posix:stat native)))
                 (if (= (logand (sb-posix:stat-mode target) sb-posix:s-ifmt)
                        sb-posix:s-ifdir)
                     (let ((count (dirvish-count-directory-entries native)))
                       (if (eq count :many)
                           " MANY "
                           (dirvish-human-readable count 1000)))
                     (dirvish-human-readable
                      (sb-posix:stat-size target) 1024)))
             (error ()
               (dirvish-human-readable (sb-posix:stat-size stat) 1024))))
          (t
           (dirvish-human-readable (sb-posix:stat-size stat) 1024))))
    (error () " ---- ")))

(defun insert-dirvish-directory-entry (point item)
  "Insert ITEM as a hidden-details Dirvish row and retain display metadata."
  (let* ((pathname (lem/directory-mode/internal:item-pathname item))
         (name (lem/directory-mode/internal::item-name item))
         (start (copy-point point :temporary)))
    (line-start start)
    (insert-string
     point name
     :attribute (lem/directory-mode/internal::get-file-attribute pathname)
     :file pathname)
    (when (lem/directory-mode/file:symbolic-link-p pathname)
      (insert-string point (format nil " -> ~A" (probe-file pathname))))
    (put-text-property start point :dirvish-size
                       (dirvish-size-field pathname))))

;; Dirvish hides Dired's details by default.  The configured attribute list is
;; only (file-size), rendered later without adding bytes to the buffer.
(setf lem/directory-mode/internal:*file-entry-inserters*
      (list #'insert-dirvish-directory-entry))

(defun dirvish-extend-display-size (logical-line width size)
  "Right-align six-cell SIZE in LOGICAL-LINE without changing source text."
  (let* ((string (lem-core::logical-line-string logical-line))
         (display-width (lem/common/character:string-width string))
         (padding (- width display-width (length size))))
    (when (plusp padding)
      (let* ((source-end (length string))
             (start (+ source-end padding))
             (end (+ start (length size)))
             (cursor
               (lem-core::logical-line-end-of-line-cursor-attribute
                logical-line))
             (attributes (lem-core::logical-line-attributes logical-line)))
        (setf string
              (concatenate 'string string
                           (make-string padding :initial-element #\Space)
                           size))
        (when cursor
          (setf attributes
                (lem-core::overlay-attributes
                 attributes source-end (1+ source-end) cursor)
                (lem-core::logical-line-end-of-line-cursor-attribute
                 logical-line)
                nil))
        (setf (lem-core::logical-line-string logical-line) string
              (lem-core::logical-line-attributes logical-line)
              (lem-core::overlay-attributes
               attributes start end 'dirvish-size-attribute))))))

(defun dirvish-presentation-buffer-p (buffer)
  (member (buffer-major-mode buffer)
          '(lem/directory-mode/mode:directory-mode lem-yath-find-name-mode)))

(defun transform-dirvish-display-line (buffer point logical-line window)
  "Add the configured Dirvish size attribute to a visible file row."
  (when (and window
             (dirvish-presentation-buffer-p buffer)
             (>= (lem-core::window-body-width window) 20))
    (alexandria:when-let ((size (text-property-at point :dirvish-size)))
      (dirvish-extend-display-size
       logical-line (lem-core::window-body-width window) size))))
