(defpackage :lem-daemon/tests/protocol
  (:use :cl :rove)
  (:local-nicknames (:protocol :lem-daemon/protocol)
                    (:transport :lem-daemon/transport)))
(in-package :lem-daemon/tests/protocol)

(deftest message-round-trip
  (let* ((message (protocol:make-object
                   "version" protocol:+protocol-version+
                   "type" "eval"
                   "id" "42"
                   "form" "(+ 20 22)"))
         (bytes (protocol:encode-message message))
         (decoded (protocol:decode-message bytes)))
    (ok (= protocol:+protocol-version+ (protocol:field decoded "version")))
    (ok (string= "eval" (protocol:field decoded "type")))
    (ok (string= "(+ 20 22)" (protocol:field decoded "form")))))

(deftest framed-message-round-trip
  (let ((path (merge-pathnames
               (format nil "lem-daemon-protocol-~d.bin" (random 1000000000))
               (uiop:temporary-directory))))
    (unwind-protect
         (progn
           (with-open-file (out path :direction :output :element-type '(unsigned-byte 8)
                                     :if-exists :supersede)
             (protocol:write-message
              (protocol:make-object "type" "hello" "version" 1) out))
           (with-open-file (in path :direction :input :element-type '(unsigned-byte 8))
             (let ((message (protocol:read-message in)))
               (ok (string= "hello" (protocol:field message "type")))
               (ok (null (protocol:read-message in))))))
      (when (probe-file path) (delete-file path)))))

(deftest server-name-validation
  (dolist (name '("server" "work-2" "a.b_c"))
    (ok (protocol:valid-server-name-p name) name))
  (dolist (name '("" "../other" "/tmp/x" ".hidden" "white space"))
    (ng (protocol:valid-server-name-p name) name)))

(deftest daemon-display-cells
  (let ((row (lem-daemon::make-cell-row 6)))
    (lem-daemon::overlay-text row 0 "漢x")
    (let ((text (lem-daemon::cell-row-string row)))
      (ok (= 6 (lem-core:string-width text))
          "wide characters retain the requested terminal width")
      (ok (string= "漢x   " text)))
    (lem-daemon::overlay-text row 1 "ab")
    (let ((text (lem-daemon::cell-row-string row)))
      (ok (= 6 (lem-core:string-width text))
          "overwriting a wide-character continuation repairs the row")
      (ok (string= " ab   " text)))))

;; Frozen placement algorithm from 818f1e89c: exercise the optimized compositor
;; against an independent path, including width changes after creating a row.
(defun reference-overlay-text (row column text &optional face)
  (let ((cells (lem-daemon::cell-row-cells row))
        (faces (lem-daemon::cell-row-faces row)))
    (loop :with column := column
          :for character :across text
          :for string := (string character)
          :for width := (lem:string-width string)
          :do (cond
                ((zerop width)
                 (loop :for index :downfrom (1- column) :to 0
                       :when (and (< index (length cells)) (stringp (aref cells index)))
                         :do (setf (aref cells index)
                                   (concatenate 'string (aref cells index) string))
                             (loop-finish)))
                ((minusp column) (incf column width))
                ((<= (+ column width) (length cells))
                 (loop :for index :from column :below (+ column width)
                       :do (lem-daemon::clear-cell-at row index))
                 (setf (aref cells column) string (aref faces column) face)
                 (loop :for index :from (1+ column) :below (+ column width)
                       :do (setf (aref cells index) lem-daemon::+continuation-cell+
                                 (aref faces index) face))
                 (incf column width))
                (t (return)))))
  row)

(deftest cell-composition-matches-character-placement
  (let ((failure nil)
        (texts (list "" "abcdef" "漢字x" "α·é" "éx" "́x"
                     (format nil "x~c~c~c" #\Tab #\Newline (code-char 1))
                     (string (code-char #xe001))
                     (format nil "a~cb" (code-char #x1f4c1))))
        (face '("#ABCDEF" "#123456" 3)))
    (block compare
      (dolist (source-width '(0 1 2 5 12))
        (dolist (target-width '(0 1 2 5 12))
          (dolist (column '(-4 -1 0 1 4 12 15))
            (dolist (text texts)
              (dolist (ambiguous-width '(1 2))
                (let* ((source (lem-daemon::make-cell-row source-width face))
                       (expected (lem-daemon::make-cell-row target-width))
                       (actual (lem-daemon::make-cell-row target-width)))
                  (let ((lem/common/character/string-width-utils:*ambiguous-character-width* 1))
                    (reference-overlay-text source 0 text face))
                  (reference-overlay-text expected 0 "漢字abcdef" face)
                  (reference-overlay-text actual 0 "漢字abcdef" face)
                  (let ((lem/common/character/string-width-utils:*ambiguous-character-width*
                          ambiguous-width))
                    (loop :with x := column
                          :for cell :across (lem-daemon::cell-row-cells source)
                          :for style :across (lem-daemon::cell-row-faces source)
                          :unless (eq cell lem-daemon::+continuation-cell+)
                            :do (reference-overlay-text expected x cell style)
                                (incf x (lem:string-width cell)))
                    (lem-daemon::overlay-cells actual column source))
                  (unless (equalp expected actual)
                    (setf failure (list source-width target-width column text ambiguous-width))
                    (return-from compare)))))))))
    (ok (null failure) (format nil "3150 composition cases; first mismatch: ~s" failure))))

(deftest cell-composition-accepts-general-strings
  (dolist (text (list (make-array 5 :element-type 'character :initial-contents "axxxx"
                                  :adjustable t :fill-pointer 1)
                     (make-array 1 :element-type 'character
                                   :displaced-to (copy-seq "α漢x") :displaced-index-offset 1)
                     (make-array 5 :element-type 'character :initial-contents "éxxx"
                                  :adjustable t :fill-pointer 2)))
    (let ((source (lem-daemon::make-cell-row 1))
          (expected (lem-daemon::make-cell-row 6))
          (actual (lem-daemon::make-cell-row 6))
          (face '("#FF0000" "#0000FF" 3)))
      (setf (aref (lem-daemon::cell-row-cells source) 0) text
            (aref (lem-daemon::cell-row-faces source) 0) face)
      (reference-overlay-text expected 1 text face)
      (lem-daemon::overlay-cells actual 1 source)
      (ok (equalp expected actual)
          "composition respects fill pointers and displaced string storage"))))

(deftest single-cell-overwrites-preserve-neighbor-glyphs
  (let ((failure nil))
    (block compare
      (loop :for width :from 0 :to 8
            :do (loop :for column :from -1 :to 9
                      :do (dolist (text '("abcdef" "漢字abc" "a漢b字" "é漢x"))
                            (let ((expected (lem-daemon::make-cell-row width))
                                  (actual (lem-daemon::make-cell-row width)))
                              (reference-overlay-text expected 0 text '("#FF0000" nil 1))
                              (reference-overlay-text actual 0 text '("#FF0000" nil 1))
                              (reference-overlay-text expected column "x" '(nil "#0000FF" 2))
                              (lem-daemon::overlay-text actual column "x" '(nil "#0000FF" 2))
                              (unless (equalp expected actual)
                                (setf failure (list width column text))
                                (return-from compare)))))))
    (ok (null failure)
        (format nil "396 boundary/face cases; first mismatch: ~s" failure))))

(deftest cell-composition-uses-current-icon-width
  (let* ((lem/common/character/icon::*icon-code-table*
           (alexandria:copy-hash-table lem/common/character/icon::*icon-code-table*))
         (source (lem-daemon::make-cell-row 4))
         (target (lem-daemon::make-cell-row 6)))
    (remhash (char-code #\x) lem/common/character/icon::*icon-code-table*)
    (lem-daemon::overlay-text source 0 "xy")
    (setf (gethash (char-code #\x) lem/common/character/icon::*icon-code-table*) t)
    (lem-daemon::overlay-cells target 0 source)
    (ok (eq lem-daemon::+continuation-cell+
            (aref (lem-daemon::cell-row-cells target) 1)))
    (ok (equal "y" (aref (lem-daemon::cell-row-cells target) 2)))
    (remhash (char-code #\x) lem/common/character/icon::*icon-code-table*)
    (lem-daemon::overlay-cells target 0 source)
    (ok (equal "y" (aref (lem-daemon::cell-row-cells target) 1)))))

(deftest composed-row-survives-later-edits
  (let ((source (lem-daemon::make-cell-row 8))
        (target (lem-daemon::make-cell-row 8)))
    (lem-daemon::overlay-text source 0 "a漢b" '("#FF0000" nil 1))
    (lem-daemon::overlay-cells target 0 source)
    (let ((snapshot (lem-daemon::cell-row-string target))
          (faces (copy-seq (lem-daemon::cell-row-faces target))))
      (lem-daemon::overlay-text source 1 "xy")
      (lem-daemon::overlay-text source 1 "́")
      (lem-daemon::clear-cell-row source 4)
      (ok (equal snapshot (lem-daemon::cell-row-string target)))
      (ok (equalp faces (lem-daemon::cell-row-faces target))))
    (let ((snapshot (lem-daemon::cell-row-string source)))
      (lem-daemon::overlay-text target 1 "́")
      (lem-daemon::clear-cell-row target 2)
      (ok (equal snapshot (lem-daemon::cell-row-string source))))))

(deftest character-cell-storage-preserves-placement-and-independence
  (let ((failure nil))
    (loop :for code :below (min 258 char-code-limit)
          :for character := (code-char code)
          :when character
            :do (dolist (ambiguous-width '(1 2))
                  (let ((lem/common/character/string-width-utils:*ambiguous-character-width*
                          ambiguous-width)
                        (expected (lem-daemon::make-cell-row 8))
                        (actual (lem-daemon::make-cell-row 8))
                        (text (format nil "a~cb" character)))
                    (reference-overlay-text expected 0 text '("#FF0000" nil 1))
                    (lem-daemon::overlay-text actual 0 text '("#FF0000" nil 1))
                    (unless (equalp expected actual)
                      (push (list code ambiguous-width) failure)))))
    (ok (null failure) (format nil "byte and non-byte boundary placement: ~s" failure)))
  (let ((first (lem-daemon::make-cell-row 4))
        (second (lem-daemon::make-cell-row 4))
        (input (copy-seq "aba")))
    (lem-daemon::overlay-text first 0 input)
    (lem-daemon::overlay-text second 0 input)
    (setf (char input 0) #\x)
    (lem-daemon::overlay-text first 1 "́")
    (lem-daemon::overlay-text first 1 "z")
    (ok (equal "áza " (lem-daemon::cell-row-string first)))
    (ok (equal "aba " (lem-daemon::cell-row-string second))
        "combining and overwriting one row leave independently rendered cells intact")
    (lem-daemon::clear-cell-row second 0)
    (lem-daemon::overlay-text second 0 "aba")
    (ok (equal "aba " (lem-daemon::cell-row-string second))
        "later rows still see the original character strings")))

(deftest screen-storage-reuse-preserves-wire-snapshots
  (lem:with-current-buffers ()
    (let* ((yason:*parse-json-arrays-as-vectors* t)
           (lem-core::*display-frame-map* (make-hash-table))
           (lem-core::*frames* nil)
           ;; No writer: retain the encoded queue to detect later mutation.
           (connection (make-instance 'lem-daemon::daemon-connection))
           (implementation (make-instance 'lem-daemon:daemon-implementation
                                          :connection connection :width 12 :height 5))
           (wire-rows nil))
      (lem:with-implementation implementation
        (let ((frame (lem:make-frame nil)))
          (unwind-protect
               (progn
                 (lem:map-frame implementation frame)
                 (lem:setup-frame frame (lem:make-buffer "screen-reuse"))
                 (let ((view (lem:window-view (lem:current-window))))
                   (labels ((put-row (y text face)
                              (let ((row (lem-daemon::make-cell-row 12)))
                                (lem-daemon::overlay-text row 0 text face)
                                (setf (gethash y (lem-daemon::daemon-view-grid view)) row)))
                            (check-frame ()
                              (multiple-value-bind (expected x y)
                                  (lem-daemon::implementation-screen implementation)
                                (lem-if:update-display implementation)
                                (let ((message
                                        (protocol:decode-message
                                         (car (lem-daemon::connection-write-tail connection)))))
                                  (if (protocol:field message "full")
                                      (setf wire-rows (protocol:field message "rows"))
                                      (loop :for change :across (protocol:field message "changes")
                                            :do (setf (aref wire-rows (protocol:field change "row"))
                                                      change)))
                                  (ok (= (length expected) (length wire-rows)))
                                  (ok (loop :for row :across expected
                                            :for wire :across wire-rows
                                            :for reference := (lem-daemon::encode-screen-row row)
                                            :always (and (equal (protocol:field reference "text")
                                                                (protocol:field wire "text"))
                                                         (equalp (protocol:field reference "runs")
                                                                 (protocol:field wire "runs"))))
                                      "queued full/delta frames reconstruct a fresh composition")
                                  (let ((cursor (protocol:field message "cursor")))
                                    (ok (and (= x (protocol:field cursor "x"))
                                             (= y (protocol:field cursor "y")))))
                                (ok (equalp expected
                                            (lem-daemon::daemon-implementation-previous-screen
                                             implementation)))))))
                     (lem-if:clear implementation view)
                     (put-row 0 "漢é wide" '("#FF0000" "#000000" 1))
                     (put-row 3 "stale" '(nil "#123456" 4))
                     (setf (lem-daemon::daemon-view-cursor view) '(2 . 0))
                     (check-frame)
                     (let* ((first-grid (lem-daemon::daemon-implementation-previous-screen
                                         implementation))
                            (first-bytes (car (lem-daemon::connection-write-head connection)))
                            (snapshot (copy-seq first-bytes)))
                       (put-row 0 "x" '("#00FF00" nil 2))
                       (check-frame)
                       (ng (eq first-grid
                               (lem-daemon::daemon-implementation-previous-screen implementation))
                           "successive frames use independent grids")
                       (lem-if:clear implementation view)
                       (put-row 1 "́漢" nil)
                       (check-frame)
                       (ok (eq first-grid
                               (lem-daemon::daemon-implementation-previous-screen implementation))
                           "the third frame reuses the first grid after diffing")
                       (lem-if:set-view-pos implementation view -2 2)
                       (check-frame)
                       ;; An empty frame must remove old text, continuations and faces.
                       (lem-if:clear implementation view)
                       (check-frame)
                       ;; Exercise both dimensions and a forced full snapshot reset.
                       (setf (lem-daemon::daemon-implementation-width implementation) 7
                             (lem-daemon::daemon-implementation-height implementation) 3)
                       (put-row 0 "漢漢漢漢" '(nil "#0000FF" 0))
                       (check-frame)
                       (setf (lem-daemon::daemon-implementation-width implementation) 16
                             (lem-daemon::daemon-implementation-height implementation) 8)
                       (check-frame)
                       (setf (lem-daemon::daemon-implementation-previous-screen implementation) nil)
                       (check-frame)
                       (check-frame)
                       (ok (equalp snapshot first-bytes)
                           "reusing grids never changes already queued encoded messages")))))
            (lem:teardown-frame frame)
            (lem:unmap-frame implementation)))))))

(deftest modeline-storage-reuse-clears-text-and-faces
  (let* ((implementation (make-instance 'lem-daemon:daemon-implementation))
         (view (lem-daemon::make-daemon-view :width 12 :height 1))
         (attribute (lem:make-attribute :foreground "white" :background "blue"))
         (accent (lem:make-attribute :foreground "red" :bold t))
         (snapshots nil))
    (labels ((objects (text face)
               (when text
                 (list (make-instance 'lem-core/display:text-object
                                      :string text :attribute face))))
             (render-and-check (width height left right base)
               (lem-if:set-view-size implementation view width height)
               (let* ((previous (gethash height (lem-daemon::daemon-view-grid view)))
                      (fresh (lem-daemon::make-daemon-view :width width :height height)))
                 (lem-if:render-line-on-modeline implementation view left right base 1)
                 (lem-if:render-line-on-modeline implementation fresh left right base 1)
                 (let* ((row (gethash height (lem-daemon::daemon-view-grid view)))
                        (reference (gethash height (lem-daemon::daemon-view-grid fresh)))
                        (encoded (lem-daemon::encode-screen-row row)))
                   (ok (equalp row reference)
                       "reused text, continuation cells and faces match a fresh modeline")
                   (when previous
                     (ok (eq (eq row previous)
                             (= width (length (lem-daemon::cell-row-cells previous))))
                         "only storage with the current width is reused"))
                   (push (cons encoded (protocol:encode-message encoded)) snapshots)))))
      (dolist (width '(12 12 2 2 0 0 8 8 12))
        (render-and-check width 1 (objects "漢é long" accent)
                          (objects "右側" nil) attribute)
        (lem:set-attribute-background attribute "green")
        (render-and-check width 1 (objects "x" nil) nil attribute)
        (render-and-check width 1 nil nil nil)
        (ok (every #'null (lem-daemon::cell-row-faces
                           (gethash 1 (lem-daemon::daemon-view-grid view))))
            "an unstyled empty redraw removes prior modeline faces")
        (ok (every (lambda (cell) (equal cell " "))
                   (lem-daemon::cell-row-cells
                    (gethash 1 (lem-daemon::daemon-view-grid view))))
            "an empty redraw removes prior text and wide continuations")
        (render-and-check width 2 (objects "left overlaps right" nil)
                          (objects "é漢" accent) attribute)
        (lem-if:clear implementation view)
        (render-and-check width 2 nil (objects "z" nil) nil))
      (dolist (snapshot snapshots)
        (ok (equalp (cdr snapshot) (protocol:encode-message (car snapshot)))
            "later modeline redraws do not mutate previously encoded row objects")))))

(deftest daemon-theme-interface
  (let ((implementation (make-instance 'lem-daemon:daemon-implementation)))
    (ng (lem/common/color:light-color-p
         (lem-if:get-background-color implementation)))
    (lem-if:update-background implementation "#ffffff")
    (lem-if:update-foreground implementation "#123456")
    (ok (lem/common/color:light-color-p
         (lem-if:get-background-color implementation)))
    (ok (lem/common/color:color-equal
         (lem/common/color:parse-color "#123456")
         (lem-if:get-foreground-color implementation)))))

(deftest styled-display-cells
  (let* ((row (lem-daemon::make-cell-row 6))
         (red (lem-daemon::drawing-face (lem:make-attribute :foreground "red" :bold t)))
         (green (lem-daemon::drawing-face (lem:make-attribute :foreground "green")))
         (text (format nil "漢e~c" (code-char #x301))))
    (lem-daemon::overlay-text row 0 text red)
    (let ((runs (lem-daemon::encode-face-runs
                 (lem-daemon::cell-row-cells row) (lem-daemon::cell-row-faces row))))
      (ok (= 1 (length runs)))
      (ok (equalp (vector 0 text "#FF0000" nil 1) (aref runs 0))
          "a wide character and combining mark remain in their styled run"))
    (lem-daemon::overlay-text row 1 "ab" green)
    (ok (string= " ab   " (lem-daemon::cell-row-string row)))
    (let ((runs (lem-daemon::encode-face-runs
                 (lem-daemon::cell-row-cells row) (lem-daemon::cell-row-faces row))))
      (ok (= 1 (length runs)))
      (ok (and (= 1 (aref (aref runs 0) 0))
               (string= "ab" (aref (aref runs 0) 1)))
          "overwriting a wide continuation clears the old glyph and face"))
    (lem-daemon::clear-cell-row row 1)
    (ok (zerop (length (lem-daemon::encode-face-runs
                       (lem-daemon::cell-row-cells row) (lem-daemon::cell-row-faces row))))
        "clearing text also removes its face")))

(deftest modeline-and-eol-faces
  (let* ((implementation (make-instance 'lem-daemon:daemon-implementation))
         (view (lem-daemon::make-daemon-view :width 8 :height 1))
         (attribute (lem:make-attribute :foreground "white" :background "blue"))
         (object (make-instance 'lem-core/display:text-object :string "Mode"
                                :attribute nil)))
    (lem-if:render-line-on-modeline implementation view (list object) nil attribute 1)
    (let ((row (gethash 1 (lem-daemon::daemon-view-grid view))))
      (ok (string= "Mode    " (lem-daemon::cell-row-string row)))
      (ok (every (lambda (face) (equal face '("#FFFFFF" "#0000FF" 0)))
                 (lem-daemon::cell-row-faces row))
          "the modeline's default face covers text and padding")
      (lem-daemon::render-object-into-row
       row 4 (make-instance 'lem-core/display:extend-to-eol-object
                            :color (lem/common/color:make-color 1 2 3)))
      (ok (equal '(nil "#010203" 0) (aref (lem-daemon::cell-row-faces row) 7))
          "end-of-line background fill preserves its color"))))

(deftest mouse-message-validation
  (flet ((down (&rest overrides)
           (let ((message (protocol:make-object "kind" "down" "x" 10 "y" 4
                                                 "button" 1 "clicks" 2)))
             (loop :for (key value) :on overrides :by #'cddr
                   :do (setf (gethash key message) value))
             message)))
    (let ((event (lem-daemon::decode-mouse-message (down))))
      (ok (typep event 'lem-core::mouse-button-down))
      (ok (and (= 10 (lem-core::mouse-event-x event))
               (= 4 (lem-core::mouse-event-y event))
               (= 2 (lem-core::mouse-button-down-clicks event))
               (eq :button-1 (lem-core::mouse-event-button event)))
          "mouse coordinates, button, and click count reach a core event"))
    (dolist (invalid '(("x" -1) ("x" 1000) ("y" "4")
                       ("button" 0) ("button" 5) ("clicks" 0) ("kind" "evaluate")))
      (ok (handler-case
              (progn (lem-daemon::decode-mouse-message (apply #'down invalid)) nil)
            (error () t))
          (format nil "invalid mouse input is rejected: ~s" invalid))))
  (let ((event (lem-daemon::decode-mouse-message
                (protocol:make-object "kind" "wheel" "x" 2 "y" 3 "dx" 0 "dy" -1))))
    (ok (and (typep event 'lem-core::mouse-wheel)
             (= -1 (lem-core::mouse-wheel-y event)))
        "wheel direction is preserved")))

(deftest yath-file-client-compatibility
  (flet ((key-command (keys)
           (alexandria:when-let
               ((prefix
                  (lem-core::keymap-find
                   lem-daemon::*daemon-edit-mode-keymap*
                   (lem-core::parse-keyspec keys))))
             (lem-core::prefix-suffix prefix))))
    (ok (eq 'lem-daemon:daemon-edit-save-and-done (key-command "Z Z"))
        "the yath save-and-finish key remains available")
    (ok (eq 'lem-daemon:daemon-edit-abort (key-command "Z Q"))
        "the yath abort key remains available")
    (ok (eq 'lem-daemon:daemon-edit-done (key-command "C-x #"))
        "the clean finish key remains available"))
  (ok (handler-case
          (progn (lem-daemon/client::build-file-entries '("+9")) nil)
        (error (condition)
          (search "must precede a file" (princ-to-string condition))))
      "a dangling location is rejected before connecting"))

#+(and sbcl linux)
(deftest unix-transport-lifecycle-safety
  (let* ((old-runtime (uiop:getenv "XDG_RUNTIME_DIR"))
         (root (merge-pathnames
                (format nil "lem-daemon-transport-~d-~d/"
                        (sb-posix:getpid) (random 1000000000))
                (uiop:temporary-directory)))
         (backend (transport:require-local-backend))
         (name (format nil "safety-~d" (random 1000000000)))
         (endpoint nil)
         (metadata nil)
         (listener nil))
    (unwind-protect
         (progn
           (ensure-directories-exist (merge-pathnames "marker" root))
           (setf (uiop:getenv "XDG_RUNTIME_DIR")
                 (uiop:native-namestring root)
                 endpoint (transport:local-endpoint backend name)
                 metadata (transport:local-metadata backend name))
           (ensure-directories-exist metadata)
           (let ((protected (merge-pathnames "protected.txt" root)))
             (with-open-file (stream protected :direction :output
                                                :if-exists :supersede)
               (write-string "protected" stream))
             (sb-posix:symlink (uiop:native-namestring protected)
                               (uiop:native-namestring metadata))
             (ok (handler-case
                     (progn
                       (transport:open-local-listener backend name 4)
                       nil)
                   (error () t))
                 "unsafe metadata is rejected")
             (ok (string= "protected" (uiop:read-file-string protected))
                 "metadata validation never follows an untrusted symlink")
             (delete-file metadata))

           (let ((stale (make-instance 'sb-bsd-sockets:local-socket
                                       :type :stream)))
             (unwind-protect
                  (sb-bsd-sockets:socket-bind
                   stale (uiop:native-namestring endpoint))
               (ignore-errors (sb-bsd-sockets:socket-close stale))))
           (setf listener (transport:open-local-listener backend name 4))
           (ok (probe-file endpoint) "a stale owned socket is recovered")
           (transport:close-local-listener listener)
           (setf listener nil)
           (ok (and (not (probe-file endpoint)) (not (probe-file metadata)))
               "closing a listener removes only its owned endpoint metadata")

           (setf listener (transport:open-local-listener backend name 4))
           (ok (handler-case
                   (progn
                     (transport:open-local-listener backend name 4)
                     nil)
                 (error () t))
               "a live daemon endpoint cannot be claimed")
           (ok (probe-file endpoint)
               "rejecting a duplicate daemon preserves the live endpoint"))
      (when listener (transport:close-local-listener listener))
      (setf (uiop:getenv "XDG_RUNTIME_DIR") old-runtime)
      (when (uiop:directory-exists-p root)
        (uiop:delete-directory-tree root :validate t)))))

#+(and sbcl linux)
(deftest alternate-editor-policy
  (let ((server (format nil "absent-~d-~d"
                        (sb-posix:getpid) (random 1000000000)))
        (alternate (format nil "~a --noinform --non-interactive --quit"
                           (first sb-ext:*posix-argv*))))
    (ok (= 0 (lem-daemon/client:run-client
              (list "--server-name" server
                    "--alternate-editor" alternate
                    "unavailable.txt")))
        "an explicit alternate editor is used when no daemon is reachable")
    (ok (handler-case
            (progn
              (lem-daemon/client:run-client
               (list "--server-name" server "unavailable.txt"))
              nil)
          (error () t))
        "the client does not start or choose an editor implicitly")))
