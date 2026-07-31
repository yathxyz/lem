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

(deftest scancode-modifier-fallback
  (let ((keyboard::*pressed-modifier-scancodes* '()))
    (keyboard::note-modifier-scancode
     (sdl2:scancode-key-to-value :scancode-lctrl)
     t)
    (testing "a pressed modifier scancode augments missing SDL modifier bits"
      (ok (keyboard::modifier-ctrl
           (keyboard::effective-modifier (keyboard::make-modifier)))))
    (keyboard::note-modifier-scancode
     (sdl2:scancode-key-to-value :scancode-lctrl)
     nil)
    (testing "the modifier is cleared on key-up"
      (ng (keyboard::modifier-ctrl
           (keyboard::effective-modifier (keyboard::make-modifier)))))))
