(defpackage :lem-sdl2/tests/keyboard
  (:use :cl :rove)
  (:local-nicknames (:keyboard :lem-sdl2/keyboard)))
(in-package :lem-sdl2/tests/keyboard)

(deftest committed-text-clears-ime-composition
  (let ((keyboard::*textediting-text* "uncommitted")
        (keyboard::*modifier* (keyboard::make-modifier)))
    (keyboard::handle-text-input-internal "")
    (testing "command-key handling is re-enabled after SDL_TEXTINPUT"
      (ok (string= "" keyboard::*textediting-text*)))))
