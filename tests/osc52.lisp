(defpackage :lem-tests/osc52
  (:use :cl :rove))
(in-package :lem-tests/osc52)

(defun octets (string)
  (babel:string-to-octets string :encoding :utf-8))

(deftest base64-encode-known-vectors
  ;; RFC 4648 test vectors, padding included.
  (ok (equal "" (lem/common/osc52:base64-encode-octets (octets ""))))
  (ok (equal "Zg==" (lem/common/osc52:base64-encode-octets (octets "f"))))
  (ok (equal "Zm8=" (lem/common/osc52:base64-encode-octets (octets "fo"))))
  (ok (equal "Zm9v" (lem/common/osc52:base64-encode-octets (octets "foo"))))
  (ok (equal "Zm9vYg==" (lem/common/osc52:base64-encode-octets (octets "foob"))))
  (ok (equal "Zm9vYmE=" (lem/common/osc52:base64-encode-octets (octets "fooba"))))
  (ok (equal "Zm9vYmFy" (lem/common/osc52:base64-encode-octets (octets "foobar")))))

(deftest base64-encodes-utf8
  ;; Multi-byte input is encoded from its UTF-8 octets.
  (ok (equal (lem/common/osc52:base64-encode-octets (octets "αβγ"))
             "zrHOss6z")))

(deftest plain-sequence-structure
  ;; ESC ] 52 ; c ; <base64> BEL
  (multiple-value-bind (seq truncated-p)
      (lem/common/osc52:encode-clipboard-sequence "foobar")
    (ng truncated-p)
    (ok (equal seq (format nil "~C]52;c;Zm9vYmFy~C" #\Escape #\Bel)))))

(deftest tmux-wrapping-doubles-escapes
  ;; ESC P tmux ; <inner, every ESC doubled> ESC \
  (multiple-value-bind (seq truncated-p)
      (lem/common/osc52:encode-clipboard-sequence "foobar" :tmux t)
    (ng truncated-p)
    (ok (equal seq
               (format nil "~CPtmux;~C~C]52;c;Zm9vYmFy~C~C\\"
                       #\Escape #\Escape #\Escape #\Bel #\Escape)))))

(deftest truncates-on-character-boundary
  ;; "αβγ" is three 2-byte characters. With a 3-octet cap only the first fits,
  ;; and it must not be split mid-character.
  (multiple-value-bind (seq truncated-p)
      (lem/common/osc52:encode-clipboard-sequence "αβγ" :max-octets 3)
    (ok truncated-p)
    (let ((expected (lem/common/osc52:base64-encode-octets (octets "α"))))
      (ok (equal seq (format nil "~C]52;c;~A~C" #\Escape expected #\Bel))))))

(deftest no-truncation-under-cap
  (multiple-value-bind (seq truncated-p)
      (lem/common/osc52:encode-clipboard-sequence "hello" :max-octets 99000)
    (declare (ignore seq))
    (ng truncated-p)))
