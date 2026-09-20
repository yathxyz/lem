(defpackage :lem-daemon/tests/protocol
  (:use :cl :rove)
  (:local-nicknames (:protocol :lem-daemon/protocol)
                    (:transport :lem-daemon/transport)))
(in-package :lem-daemon/tests/protocol)

(deftest keyboard-input-timing-is-gated-and-keeps-routing
  (dolist (recording-p '(nil t))
    (let* ((lem-core::*editor-event-queue* (lem/common/queue:make-concurrent-queue))
           (lem-core::*pipeline-recorder* (when recording-p (lambda (&rest values)
                                                            (declare (ignore values)))))
           (connection (make-instance 'lem-daemon::daemon-connection))
           (implementation (make-instance 'lem-daemon:daemon-implementation)))
      ;; No frame or writer is needed to inspect the real producer's queued
      ;; key and encoded acceptance reply; PREPARE runs only on consumption.
      (setf (lem-daemon::connection-negotiated-p connection) t
            (lem-daemon::connection-implementation connection) implementation)
      (lem-daemon::handle-message
       connection (protocol:make-object "version" protocol:+protocol-version+
                                        "type" "input" "id" "key-1" "sym" "x" "ctrl" t))
      (let* ((routed (lem/common/queue:dequeue lem-core::*editor-event-queue*))
             (event (lem-core::routed-input-event-event routed))
             (key (if (lem-core::pipeline-event-p event)
                      (lem-core::pipeline-event-payload event) event)))
        (ok (eq connection (lem-core::routed-input-event-session routed)))
        (ok (eql recording-p (lem-core::pipeline-event-p event)))
        (ok (lem:match-key key :ctrl t :sym "x"))
        (when (lem-core::pipeline-event-p event)
          (ok (<= (lem-core::pipeline-event-t0 event) (lem-core::pipeline-event-t1 event)
                  (lem:pipeline-now))))
        (let ((reply (protocol:decode-message (car (lem-daemon::connection-write-head connection)))))
          (ok (equal "ok" (protocol:field reply "status")))
          (ok (equal "key-1" (protocol:field reply "id"))))))))

(deftest object-construction-preserves-fields
  (dolist (count '(0 1 2 3 4 7 8 9 16 33 64))
    (let* ((fields (loop :for index :below count
                         :append (list (format nil "field-~d" index) index)))
           (object (apply #'protocol:make-object fields)))
      (ok (= count (hash-table-count object)))
      (ok (loop :for index :below count
                :always (eql index (gethash (format nil "field-~d" index) object))))))
  (let* ((value (vector "漢字" nil 42))
         (key (copy-seq "same"))
         (fields (list key :old (copy-seq key) value "dangling"))
         (object (apply #'protocol:make-object fields)))
    (ok (= 2 (hash-table-count object)))
    (ok (eq value (gethash "same" object))
        "equal duplicate keys keep the last value without copying it")
    (multiple-value-bind (value present) (gethash "dangling" object)
      (ok (and present (null value)) "a trailing field name retains its NIL value"))
    (ok (equal fields (list key :old key value "dangling"))
        "construction does not change the caller's field list")
    (setf (gethash "extra" object) t)
    (ok (eq t (gethash "extra" object)) "objects remain extensible")
    (ok (zerop (hash-table-count (protocol:make-object))) "objects are independent")))

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

(deftest unicode-message-decoding
  (let* ((text (coerce (mapcar #'code-char
                             '(0 9 10 13 34 92 127 128 255 2047 2048
                               #xd7ff #xe000 #xffff #x10000 #x1f600 #x10ffff))
                       'string))
         (message (protocol:make-object "text" text "漢字" "é😀"))
         (octets (protocol:encode-message message)))
    (dolist (bytes (list octets
                        (make-array (length octets) :element-type '(unsigned-byte 8)
                                    :adjustable t :fill-pointer (length octets)
                                    :initial-contents octets)
                        (let ((storage (make-array (+ 4 (length octets))
                                                   :element-type '(unsigned-byte 8))))
                          (replace storage octets :start1 2)
                          (make-array (length octets) :element-type '(unsigned-byte 8)
                                      :displaced-to storage :displaced-index-offset 2))))
      (let ((decoded (protocol:decode-message bytes)))
        (ok (equal text (protocol:field decoded "text"))
            "UTF-8 boundaries and escaped controls survive decoding")
        (ok (equal "é😀" (protocol:field decoded "漢字"))
            "Unicode keys, combining text and astral characters survive decoding")))))

(deftest malformed-utf8-messages
  (let ((prefix (protocol:encode-message (protocol:make-object "text" "")))
        ;; Protocol validation must not inherit a caller's replacement policy.
        (babel-encodings:*suppress-character-coding-errors* t))
    (dolist (invalid '((#x80) (#xbf) (#xc0 #x80) (#xc1 #xbf) (#xc2) (#xc2 #x7f)
                       (#xdf #xc0) (#xe0 #x80 #x80) (#xe0 #x9f #xbf) (#xe1 #x80)
                       (#xed #xa0 #x80) (#xed #xbf #xbf) (#xef #xbf)
                       (#xf0 #x80 #x80 #x80) (#xf0 #x8f #xbf #xbf)
                       (#xf1 #x80 #x80) (#xf4 #x90 #x80 #x80)
                       (#xf5 #x80 #x80 #x80) (#xf8 #x88 #x80 #x80 #x80)
                       (#xfc #x84 #x80 #x80 #x80 #x80) (#xfe) (#xff)))
      ;; Check invalid bytes inside a string and after an otherwise valid object.
      ;; Both locations must be validated before JSON parsing can accept input.
      (dolist (position (list (- (length prefix) 2) (length prefix)))
        (let ((bytes (concatenate '(vector (unsigned-byte 8))
                                  (subseq prefix 0 position) invalid (subseq prefix position))))
          (ok (signals (protocol:decode-message bytes) 'protocol:protocol-error)
              "malformed UTF-8 is rejected even under a permissive Babel binding"))))))

(deftest decoded-message-size-limit
  (let ((bytes (make-array protocol:+maximum-message-bytes+
                           :element-type '(unsigned-byte 8) :initial-element 32)))
    (replace bytes (protocol:encode-message (protocol:make-object "x" 1)))
    (ok (= 1 (protocol:field (protocol:decode-message bytes) "x"))
        "a message at the byte limit still decodes")
    (ok (signals (protocol:decode-message
                  (concatenate '(vector (unsigned-byte 8)) bytes #(32)))
                 'protocol:protocol-error)
        "the size limit is enforced before decoding")))

(deftest encoded-row-index-presence
  (let ((row (lem-daemon::make-cell-row 2)))
    (dolist (index '(nil 0 3))
      (let ((object (lem-daemon::encode-screen-row row index)))
        (ok (equal "  " (protocol:field object "text")))
        (ok (zerop (length (protocol:field object "runs"))))
        (multiple-value-bind (value present) (gethash "row" object)
          (ok (and (eql value index) (eq present (not (null index))))))))))

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

(defun reference-overlay-cells (target column source)
  (loop :for cell :across (lem-daemon::cell-row-cells source)
        :for face :across (lem-daemon::cell-row-faces source)
        :unless (eq cell lem-daemon::+continuation-cell+)
          :do (reference-overlay-text target column cell face)
              (incf column (lem:string-width cell)))
  target)

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
                    (reference-overlay-cells expected column source)
                    (lem-daemon::overlay-cells actual column source))
                  (unless (equalp expected actual)
                    (setf failure (list source-width target-width column text ambiguous-width))
                    (return-from compare)))))))))
    (ok (null failure) (format nil "3150 composition cases; first mismatch: ~s" failure))))

(deftest cell-runs-preserve-clipping-faces-and-live-widths
  (let ((failure nil)
        (cases 0)
        (lem/common/character/icon::*icon-code-table*
          (alexandria:copy-hash-table lem/common/character/icon::*icon-code-table*)))
    (block compare
      (dolist (source-width '(2 5 10 16))
        (dolist (target-width '(1 2 5 12))
          (dolist (column '(-6 -1 0 1 4 11 16))
            (dolist (text '("" "      " "xxxxxx" "  漢   字  " "aa bbb c" "é  x"))
              (dolist (wide-character '(nil #\Space #\x))
                (remhash (char-code #\Space) lem/common/character/icon::*icon-code-table*)
                (remhash (char-code #\x) lem/common/character/icon::*icon-code-table*)
                (let ((source (lem-daemon::make-cell-row source-width))
                      (expected (lem-daemon::make-cell-row target-width))
                      (actual (lem-daemon::make-cell-row target-width)))
                  (lem-daemon::overlay-text source 0 text)
                  (dotimes (index source-width)
                    (setf (svref (lem-daemon::cell-row-faces source) index)
                          (if (evenp index) '("#FF0000" nil 1) '(nil "#0000FF" 2))))
                  (reference-overlay-text expected 0 "漢字a漢字b漢" '("#00FF00" nil 0))
                  (reference-overlay-text actual 0 "漢字a漢字b漢" '("#00FF00" nil 0))
                  (when wide-character
                    (setf (gethash (char-code wide-character)
                                   lem/common/character/icon::*icon-code-table*) t))
                  (reference-overlay-cells expected column source)
                  (lem-daemon::overlay-cells actual column source)
                  (incf cases)
                  (unless (equalp expected actual)
                    (setf failure (list source-width target-width column text wide-character))
                    (return-from compare)))))))))
    (ok (null failure)
        (format nil "~d repeated-cell boundary/face/width cases; first mismatch: ~s"
                cases failure))))

(deftest cell-runs-preserve-overlapping-storage
  (flet ((source-for (row sharing)
           (ecase sharing
             (:row row)
             (:both (lem-daemon::copy-cell-row row))
             (:cells (lem-daemon::%make-cell-row
                      (lem-daemon::cell-row-cells row)
                      (copy-seq (lem-daemon::cell-row-faces row))))
             (:faces (lem-daemon::%make-cell-row
                      (copy-seq (lem-daemon::cell-row-cells row))
                      (lem-daemon::cell-row-faces row))))))
    (dolist (sharing '(:row :both :cells :faces))
      (dolist (column '(-2 0 1 4 12))
        (let ((expected (lem-daemon::make-cell-row 12))
              (actual (lem-daemon::make-cell-row 12)))
          (dolist (row (list expected actual))
            (lem-daemon::overlay-text row 0 "aaaa    xxxx")
            (dotimes (index 12)
              (setf (svref (lem-daemon::cell-row-faces row) index)
                    (if (evenp index) '("#FF0000" nil 1) '(nil "#0000FF" 2)))))
          (reference-overlay-cells expected column (source-for expected sharing))
          (lem-daemon::overlay-cells actual column (source-for actual sharing))
          (ok (equalp expected actual)
              (format nil "~s shared storage at column ~d" sharing column)))))))

(deftest cell-runs-stop-at-the-shorter-source-array
  (dolist (face-count '(0 3 6 8))
    (let ((source (lem-daemon::%make-cell-row
                   (make-array 6 :initial-element " ")
                   (make-array face-count :initial-element '("#FF0000" nil 1))))
          (expected (lem-daemon::make-cell-row 12))
          (actual (lem-daemon::make-cell-row 12)))
      (reference-overlay-text expected 0 "漢字a漢字b漢")
      (reference-overlay-text actual 0 "漢字a漢字b漢")
      (reference-overlay-cells expected 1 source)
      (lem-daemon::overlay-cells actual 1 source)
      (ok (equalp expected actual)
          (format nil "six source cells and ~d faces" face-count)))))

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
                            (check-frame (&optional (label "queued full/delta frames reconstruct a fresh composition"))
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
                                      label)
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
                       (put-row 0 "x" '("#00FF00" nil 2))
                       (check-frame)
                       (put-row 0 "X" '("#00FF00" nil 2))
                       (check-frame "an ASCII case-only edit reaches the client")
                       (put-row 0 "漢ä́" '("#00FF00" nil 2))
                       (check-frame)
                       (put-row 0 "漢Ä́" '("#00FF00" nil 2))
                       (check-frame "a Unicode case-only edit preserves wide and combining cells")
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

(deftest unchanged-screen-suppression-preserves-display-state
  (lem:with-current-buffers ()
    (let* ((lem-core::*display-frame-map* (make-hash-table))
           (lem-core::*frames* nil)
           (lem-daemon::*daemon-root-implementation* nil)
           (lem:*after-redraw-display-force* nil)
           (connection (make-instance 'lem-daemon::daemon-connection))
           (implementation (make-instance 'lem-daemon:daemon-implementation
                                          :connection connection :width 12 :height 5))
           (peer-connection (make-instance 'lem-daemon::daemon-connection))
           (peer (make-instance 'lem-daemon:daemon-implementation
                               :connection peer-connection :width 12 :height 5))
           (cursor-attribute (lem:ensure-attribute 'lem:cursor))
           (old-cursor-background (lem:attribute-background cursor-attribute))
           (old-mouse (lem:variable-value 'lem:mouse-mode :global))
           (old-delay (symbol-function 'lem-daemon::terminal-escape-delay))
           (delay 17))
      (lem:with-implementation implementation
        (let ((frame (lem:make-frame nil)))
          (unwind-protect
               (progn
                 (setf (symbol-function 'lem-daemon::terminal-escape-delay) (lambda () delay))
                 (lem:map-frame implementation frame)
                 (lem:setup-frame frame (lem:make-buffer "screen-suppression"))
                 (let ((view (lem:window-view (lem:current-window))))
                   (labels ((unchanged ()
                              (let ((count (lem-daemon::connection-write-count connection)))
                                (dotimes (i 3) (lem-if:update-display implementation))
                                (ok (= count (lem-daemon::connection-write-count connection))
                                    "unchanged redraws enqueue no bytes across grid reuse")))
                            (changed (&key full)
                              (let ((count (lem-daemon::connection-write-count connection)))
                                (lem-if:update-display implementation)
                                (ok (= (1+ count) (lem-daemon::connection-write-count connection))
                                    "a display change still enqueues exactly one screen")
                                (let ((message (protocol:decode-message
                                                (car (lem-daemon::connection-write-tail connection)))))
                                  (ok (eq full (protocol:field message "full")))
                                  (let ((lem:*after-redraw-display-force* nil)) (unchanged))
                                  message)))
                            (check-property (name value &optional cursor)
                              (let ((message (changed)))
                                (ok (equal value (protocol:field
                                                  (if cursor (protocol:field message "cursor") message)
                                                  name))))))
                     (changed :full t)
                     (lem-if:update-display peer)
                     (setf (lem-daemon::daemon-view-cursor view) '(1 . 0))
                     (check-property "x" 1 t)
                     (setf (lem-daemon::daemon-view-cursor view) '(1 . 2))
                     (check-property "y" 2 t)
                     (lem-if:update-cursor-shape implementation :bar)
                     (check-property "shape" "bar" t)
                     (lem-if:update-foreground implementation "#123456")
                     (check-property "foreground" "#123456")
                     (lem-if:update-background implementation "#987654")
                     (check-property "background" "#987654")
                     (lem-if:update-display peer)
                     (ok (= 1 (lem-daemon::connection-write-count peer-connection))
                         "another client's changes do not invalidate this client's snapshot")
                     (lem:set-attribute-background cursor-attribute "#CDA873")
                     (check-property "color" "#CDA873" t)
                     (setf (lem:variable-value 'lem:mouse-mode :global) (not old-mouse))
                     (check-property "mouse" (not old-mouse))
                     (incf delay)
                     (check-property "escape-delay" delay)
                     (let ((row (lem-daemon::make-cell-row 12)))
                       (lem-daemon::overlay-text row 0 "漢é" '("#FF0000" nil 1))
                       (setf (gethash 1 (lem-daemon::daemon-view-grid view)) row))
                     (ok (plusp (length (protocol:field (changed) "changes")))
                         "text and style changes still send row deltas")
                     (lem-daemon::overlay-text
                      (gethash 1 (lem-daemon::daemon-view-grid view)) 0 "漢é" '(nil "#456789" 2))
                     (ok (plusp (length (protocol:field (changed) "changes")))
                         "a style-only change is not mistaken for an unchanged row")
                     (let ((lem:*after-redraw-display-force* t))
                       (ok (zerop (length (protocol:field (changed) "changes")))
                           "forced redraws still send an otherwise unchanged screen"))
                     (setf (lem-daemon::daemon-implementation-width implementation) 13)
                     (changed :full t)
                     (setf (lem-daemon::daemon-implementation-height implementation) 6)
                     (changed :full t)
                     (setf (lem-daemon::daemon-implementation-previous-screen implementation) nil)
                     (changed :full t))))
            (setf (symbol-function 'lem-daemon::terminal-escape-delay) old-delay
                  (lem:variable-value 'lem:mouse-mode :global) old-mouse)
            (lem:set-attribute-background cursor-attribute old-cursor-background)
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
