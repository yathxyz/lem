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

(deftest windows-key-normalization
  (let ((plain (keyboard::make-modifier))
        (shifted (keyboard::make-modifier :shift t))
        (ctrl (keyboard::make-modifier :ctrl t))
        (meta (keyboard::make-modifier :meta t)))
    (testing "unshifted Windows virtual-key letters become canonical lowercase"
      (ok (string= "x" (keyboard::normalize-windows-key-symbol "X" plain))))
    (testing "shifted letters remain uppercase"
      (ok (string= "X" (keyboard::normalize-windows-key-symbol "X" shifted))))
    (testing "Windows modifier key-down records are not editor input"
      (ok (keyboard::windows-modifier-key-event-p 0 ctrl))
      (ok (keyboard::windows-modifier-key-event-p 18 meta)))))
