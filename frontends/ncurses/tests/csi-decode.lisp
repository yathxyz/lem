(defpackage :lem-ncurses/tests/csi-decode
  (:use :cl :rove :lem))
(in-package :lem-ncurses/tests/csi-decode)

;;; Unit tests for the pure CSI key decoder (lem-ncurses/input:decode-csi-key).
;;; These lock the modifier/sym mapping; the end-to-end pipeline (raw bytes ->
;;; ncurses -> parser) is verified separately by the scripted tmux acceptance.

(defun decode (final &rest params)
  "Decode a CSI sequence with FINAL byte (character) and numeric PARAMS."
  (lem-ncurses/input:decode-csi-key final (coerce params 'vector)))

(deftest modified-cursor-keys
  ;; C-Up = ESC [ 1 ; 5 A
  (let ((k (decode #\A 1 5)))
    (ok (equal "Up" (key-sym k)))
    (ok (key-ctrl k)) (ng (key-meta k)) (ng (key-shift k)))
  ;; M-Left = ESC [ 1 ; 3 D
  (let ((k (decode #\D 1 3)))
    (ok (equal "Left" (key-sym k)))
    (ok (key-meta k)) (ng (key-ctrl k)) (ng (key-shift k)))
  ;; S-Right = ESC [ 1 ; 2 C
  (let ((k (decode #\C 1 2)))
    (ok (equal "Right" (key-sym k)))
    (ok (key-shift k)) (ng (key-ctrl k)) (ng (key-meta k)))
  ;; C-End = ESC [ 1 ; 5 F
  (let ((k (decode #\F 1 5)))
    (ok (equal "End" (key-sym k)))
    (ok (key-ctrl k))))

(deftest modified-tilde-keys
  ;; S-F5 = ESC [ 15 ; 2 ~
  (let ((k (decode #\~ 15 2)))
    (ok (equal "F5" (key-sym k)))
    (ok (key-shift k)) (ng (key-ctrl k)) (ng (key-meta k)))
  ;; C-PageDown = ESC [ 6 ; 5 ~
  (let ((k (decode #\~ 6 5)))
    (ok (equal "PageDown" (key-sym k)))
    (ok (key-ctrl k)) (ng (key-shift k)) (ng (key-meta k)))
  ;; C-Delete = ESC [ 3 ; 5 ~
  (let ((k (decode #\~ 3 5)))
    (ok (equal "Delete" (key-sym k)))
    (ok (key-ctrl k))))

(deftest all-modifier-combinations
  ;; modifier param = 1 + bitmask(shift=1 alt=2 ctrl=4)
  (let ((k (decode #\A 1 2)))            ; shift
    (ok (key-shift k)) (ng (key-meta k)) (ng (key-ctrl k)))
  (let ((k (decode #\A 1 3)))            ; alt
    (ng (key-shift k)) (ok (key-meta k)) (ng (key-ctrl k)))
  (let ((k (decode #\A 1 4)))            ; alt+shift
    (ok (key-shift k)) (ok (key-meta k)) (ng (key-ctrl k)))
  (let ((k (decode #\A 1 5)))            ; ctrl
    (ng (key-shift k)) (ng (key-meta k)) (ok (key-ctrl k)))
  (let ((k (decode #\A 1 6)))            ; ctrl+shift
    (ok (key-shift k)) (ng (key-meta k)) (ok (key-ctrl k)))
  (let ((k (decode #\A 1 7)))            ; ctrl+alt
    (ng (key-shift k)) (ok (key-meta k)) (ok (key-ctrl k)))
  (let ((k (decode #\A 1 8)))            ; ctrl+alt+shift
    (ok (key-shift k)) (ok (key-meta k)) (ok (key-ctrl k))))

(deftest begin-final-byte-covered
  ;; final byte E (KP center / Begin) rounds out the A-F range in the comment.
  (let ((k (decode #\E 1 5)))
    (ok (equal "Begin" (key-sym k)))
    (ok (key-ctrl k))))

(deftest non-keys-return-nil
  ;; bracketed paste introducer is not a key here (payload read elsewhere).
  (ok (null (decode #\~ 200)))
  ;; unknown final byte.
  (ok (null (decode #\Z 1 5)))
  ;; unknown tilde parameter.
  (ok (null (decode #\~ 99 5))))
