(defpackage :lem-vi-mode/tests/insert
  (:use :cl
        :lem
        :rove
        :lem-vi-mode/tests/utils)
  (:import-from :lem-fake-interface
                :with-fake-interface)
  (:import-from :named-readtables
                :in-readtable))
(in-package :lem-vi-mode/tests/insert)

(in-readtable :interpol-syntax)

(deftest repeat-key-recording-ownership
  ;; Exercise the recorder directly to retain the caller's key lists across
  ;; successive commands, rebinding and replacement of the public recording.
  (let* ((prefix (list (make-key :sym "i")))
         (keys (list (make-key :sym "a") (make-key :sym "b")))
         (expected (append prefix keys))
         (lem-vi-mode/core:*last-repeat-keys* prefix))
    (lem-vi-mode::record-repeat-keys keys)
    (lem-vi-mode::record-repeat-keys nil)
    (ok (equal expected lem-vi-mode/core:*last-repeat-keys*))
    (ok (= 1 (length prefix)))
    (ok (= 2 (length keys)))
    (let ((saved (copy-list lem-vi-mode/core:*last-repeat-keys*)))
      (let ((lem-vi-mode/core:*last-repeat-keys* nil))
        (lem-vi-mode::record-repeat-keys keys)
        (ok (equal keys lem-vi-mode/core:*last-repeat-keys*)))
      (lem-vi-mode::record-repeat-keys keys)
      (ok (equal (append saved keys) lem-vi-mode/core:*last-repeat-keys*)))
    (setf lem-vi-mode/core:*last-repeat-keys* prefix)
    (lem-vi-mode::record-repeat-keys keys)
    (ok (equal expected lem-vi-mode/core:*last-repeat-keys*))
    (ok (= 1 (length prefix)))
    (ok (= 2 (length keys)))))

(deftest vi-repeat-insert-recording
  (with-fake-interface ()
    (with-vi-buffer (#?"[f]oo\nbar\nbaz\n")
      (cmd "Aαβ<C-h>γ<Esc>")
      (ok (text= #?"fooαγ\nbar\nbaz\n"))
      (let ((saved (copy-list lem-vi-mode/core:*last-repeat-keys*)))
        (cmd "j^.")
        (ok (text= #?"fooαγ\nbarαγ\nbaz\n"))
        (ok (equal saved lem-vi-mode/core:*last-repeat-keys*))
        (ok (state= :normal)))
      (cmd "jAZ<Esc>.")
      (ok (text= #?"fooαγ\nbarαγ\nbazZZ\n"))
      (ok (state= :normal)))
    (with-vi-buffer (#?"[a]bcdef\nuvwxyz\n")
      (cmd "RXY<Esc>j^.")
      (ok (text= #?"XYcdef\nXYwxyz\n"))
      (ok (state= :normal)))))

(deftest vi-insert-enters-insert-mode
  (with-fake-interface ()
    (with-vi-buffer (#?"[f]oo\n")
      (cmd "i")
      (ok (state= :insert)))))

(deftest vi-insert-typing
  (with-fake-interface ()
    (with-vi-buffer (#?"[f]oo\n")
      (cmd "ihello <Esc>")
      (ok (buf= #?"hello[ ]foo\n"))
      (ok (state= :normal)))))

(deftest vi-insert-kill-last-word
  (with-fake-interface ()
    (testing "word"
      (with-vi-buffer (#?"[f]oo bar\n")
        (cmd "A<C-w><Esc>")
        (ok (buf= #?"foo[ ]\n"))))
    (testing "trailing whitespace"
      (with-vi-buffer (#?"[f]oo bar  \n")
        (cmd "A<C-w><Esc>")
        (ok (buf= #?"foo[ ]\n"))))
    (testing "punctuation is a separate word"
      (with-vi-buffer (#?"[f]oo.bar\n")
        (cmd "A<C-w><Esc>")
        (ok (buf= #?"foo[.]\n"))
        (cmd "a<C-w><Esc>")
        (ok (buf= #?"fo[o]\n"))))))

(deftest vi-append
  (with-fake-interface ()
    (with-vi-buffer (#?"[f]oo\n")
      (cmd "a")
      (ok (state= :insert)))
    ;; 'a' moves cursor after current char before inserting
    (with-vi-buffer (#?"[f]oo\n")
      (cmd "aX<Esc>")
      (ok (buf= #?"f[X]oo\n"))
      (ok (state= :normal)))
    ;; append at end of line stays at end
    (with-vi-buffer (#?"fo[o]\n")
      (cmd "aX<Esc>")
      (ok (buf= #?"foo[X]\n")))))

(deftest vi-insert-bol
  (with-fake-interface ()
    (with-vi-buffer (#?"  [f]oo\n")
      (cmd "I")
      (ok (state= :insert)))
    ;; I moves to first non-whitespace
    (with-vi-buffer (#?"  [f]oo\n")
      (cmd "IX<Esc>")
      (ok (buf= #?"  [X]foo\n")))
    (with-vi-buffer (#?"  fo[o]\n")
      (cmd "IX<Esc>")
      (ok (buf= #?"  [X]foo\n")))))

(deftest vi-append-eol
  (with-fake-interface ()
    (with-vi-buffer (#?"[f]oo\n")
      (cmd "A")
      (ok (state= :insert)))
    (with-vi-buffer (#?"[f]oo\n")
      (cmd "AX<Esc>")
      (ok (buf= #?"foo[X]\n")))))

(deftest vi-open-below
  (with-fake-interface ()
    (with-vi-buffer (#?"[f]oo\nbar\n")
      (cmd "o")
      (ok (state= :insert)))
    (with-vi-buffer (#?"[f]oo\nbar\n")
      (cmd "ohello<Esc>")
      (ok (buf= #?"foo\nhell[o]\nbar\n"))
      (ok (state= :normal)))))

(deftest vi-open-above
  (with-fake-interface ()
    (with-vi-buffer (#?"foo\n[b]ar\n")
      (cmd "O")
      (ok (state= :insert)))
    (with-vi-buffer (#?"foo\n[b]ar\n")
      (cmd "Ohello<Esc>")
      (ok (buf= #?"foo\nhell[o]\nbar\n"))
      (ok (state= :normal)))))

(deftest vi-escape-returns-to-normal
  (with-fake-interface ()
    (with-vi-buffer (#?"[f]oo\n")
      (cmd "i")
      (ok (state= :insert))
      (cmd "<Esc>")
      (ok (state= :normal)))))

(deftest vi-escape-moves-cursor-back
  (with-fake-interface ()
    ;; escaping after typing moves cursor back one char
    (with-vi-buffer (#?"[f]oo\n")
      (cmd "iabc<Esc>")
      (ok (buf= #?"ab[c]foo\n")))))

(deftest vi-change-word
  (with-fake-interface ()
    (with-vi-buffer (#?"[f]oo bar\n")
      (cmd "cw")
      (ok (state= :insert)))
    (with-vi-buffer (#?"[f]oo bar\n")
      (cmd "cwhello<Esc>")
      (ok (buf= #?"hell[o] bar\n")))))

(deftest vi-substitute-char
  (with-fake-interface ()
    (with-vi-buffer (#?"[f]oo\n")
      (cmd "s")
      (ok (state= :insert)))
    (with-vi-buffer (#?"[f]oo\n")
      (cmd "sX<Esc>")
      (ok (buf= #?"[X]oo\n")))))
