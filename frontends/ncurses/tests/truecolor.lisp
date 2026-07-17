(defpackage :lem-ncurses/tests/truecolor
  (:use :cl :rove))
(in-package :lem-ncurses/tests/truecolor)

;;; Unit tests for the pure parts of TF-3 (24-bit color): direct-color number
;;; mapping, terminfo candidate selection, and the palette-preserving 256-color
;;; quantizer. The fact that these run headlessly (no curses screen) also locks
;;; the requirement that filling the color table never calls init_color: any
;;; curses call here would crash without an initialized screen.
;;; The end-to-end rendering (SGR 38;2 emission, no OSC 4 leakage) is verified
;;; by the scripted tmux acceptance.

(deftest direct-terminfo-candidates
  (ok (equal '("xterm-direct")
             (lem-ncurses/term::direct-terminfo-candidates "xterm-256color")))
  (ok (equal '("tmux-direct" "xterm-direct")
             (lem-ncurses/term::direct-terminfo-candidates "tmux-256color")))
  (ok (equal '("screen-direct" "xterm-direct")
             (lem-ncurses/term::direct-terminfo-candidates "screen")))
  (ok (equal '("xterm-direct")
             (lem-ncurses/term::direct-terminfo-candidates "xterm"))))

(deftest color-to-direct-number
  (flet ((direct (r g b)
           (lem-ncurses/term::color-to-direct-number (lem:make-color r g b))))
    (ok (= #x5f87af (direct #x5f #x87 #xaf)))
    (ok (= #xffffff (direct #xff #xff #xff)))
    ;; 0-7 collide with the ANSI color range in direct-color terminfo and are
    ;; nudged to 8 so output never depends on the user's palette.
    (ok (= 8 (direct 0 0 0)))
    (ok (= 8 (direct 0 0 7)))
    (ok (= 9 (direct 0 0 9)))))

(deftest direct-number-round-trip
  (let ((color (lem-ncurses/term::direct-number-to-color #x5f87af)))
    (ok (= #x5f (lem:color-red color)))
    (ok (= #x87 (lem:color-green color)))
    (ok (= #xaf (lem:color-blue color)))))

(deftest truecolor-get-color-returns-direct-numbers
  (let ((lem-ncurses/term::*truecolor-p* t))
    (ok (= #x123456 (lem-ncurses/term::get-color "#123456")))
    (ok (= #xff0000 (lem-ncurses/term::get-color "red")))))

(deftest quantizer-targets-standard-palette
  (let ((lem-ncurses/term::*truecolor-p* nil))
    (lem-ncurses/term::init-colors 256)
    ;; Exact members of the standard xterm cube/ramp map to themselves.
    (ok (= 196 (lem-ncurses/term::get-color "#ff0000")))
    (ok (= 46 (lem-ncurses/term::get-color "#00ff00")))
    (ok (= 21 (lem-ncurses/term::get-color "#0000ff")))
    (ok (= 16 (lem-ncurses/term::get-color "#000000")))
    (ok (= 231 (lem-ncurses/term::get-color "#ffffff")))
    ;; Registers 0-15 are user-themed and must never be chosen when the full
    ;; 256-color table is available.
    (loop :for hex :in '("#000000" "#cd0000" "#e5e5e5" "#5c5cff" "#808080")
          :do (ok (<= 16 (lem-ncurses/term::get-color hex))))))

(deftest truecolor-editor-variable-defaults-to-auto
  (ok (eq :auto (lem:variable-value 'lem-ncurses/config:truecolor :global))))
