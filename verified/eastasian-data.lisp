;;;; verified/eastasian-data.lisp -- East Asian width tables (SPEC-VK VK-10).
;;;;
;;;; GENERATED -- do not edit by hand.  Regenerate with:
;;;;   sbcl --script scripts/gen-eastasian.lisp acl2
;;;; (add UCD_DIR=<dir> to reuse a local UCD mirror; the same command with
;;;; no argument regenerates the production src/.../eastasian.lisp, and
;;;; `both' emits both -- the two files derive from ONE UCD parse, so the
;;;; kernel tables and production tables cannot drift.)
;;;;
;;;; Unicode Character Database version 17.0.0.
;;;;
;;;; This is an ACL2 book: (in-package "ACL2"), certified by
;;;; scripts/run-proofs.sh and loaded verbatim into the Lem image through
;;;; verified/shim.lisp (SPEC-VK Constraint 2).  It holds ONLY constant
;;;; data as CODE -- three predicates, each a balanced binary-search
;;;; decision tree of literal codepoint comparisons (production's
;;;; gen-binary-search-function shape).  SBCL compiles them to O(log n)
;;;; literal integer compares -- as fast as production's fasl, not an O(n)
;;;; list scan (which regressed CJK string-width ~30x):
;;;;   (k-wide-code-p code)      East_Asian_Width W/F + Emoji_Presentation
;;;;   (k-ambiguous-code-p code) East_Asian_Width A
;;;;   (k-zero-code-p code)      general category Mn/Me + ZWJ U+200D
;;;; These recognize EXACTLY the same codepoints as production's
;;;; *eastasian-full* / *eastasian-ambiguous* / *zero-width* vectors
;;;; (src/common/character/eastasian.lisp), same UCD parse.  Non-recursive,
;;;; so ACL2 admits them at once; verified/width.lisp keeps them DISABLED
;;;; (opaque booleans) during proofs.

(in-package "ACL2")

;; East_Asian_Width W or F, plus Emoji_Presentation -> display width 2.
(defun k-wide-code-p (code)
  (declare (type (unsigned-byte 32) code)
           (optimize (speed 3) (safety 0) (debug 0)))
  (if (< code #x17000)
    (if (< code #x2757)
      (if (< code #x26BD)
        (if (< code #x2614)
          (if (< code #x23E9)
            (if (< code #x231A)
              (if (< code #x1100)
                nil
                (if (<= code #x115F) t
                nil))
              (if (<= code #x231B) t
              (if (< code #x2329)
                nil
                (if (<= code #x232A) t
                nil))))
            (if (<= code #x23EC) t
            (if (< code #x23F3)
              (if (< code #x23F0)
                nil
                (if (<= code #x23F0) t
                nil))
              (if (<= code #x23F3) t
              (if (< code #x25FD)
                nil
                (if (<= code #x25FE) t
                nil))))))
          (if (<= code #x2615) t
          (if (< code #x268A)
            (if (< code #x2648)
              (if (< code #x2630)
                nil
                (if (<= code #x2637) t
                nil))
              (if (<= code #x2653) t
              (if (< code #x267F)
                nil
                (if (<= code #x267F) t
                nil))))
            (if (<= code #x268F) t
            (if (< code #x26A1)
              (if (< code #x2693)
                nil
                (if (<= code #x2693) t
                nil))
              (if (<= code #x26A1) t
              (if (< code #x26AA)
                nil
                (if (<= code #x26AB) t
                nil))))))))
        (if (<= code #x26BE) t
        (if (< code #x26FD)
          (if (< code #x26EA)
            (if (< code #x26CE)
              (if (< code #x26C4)
                nil
                (if (<= code #x26C5) t
                nil))
              (if (<= code #x26CE) t
              (if (< code #x26D4)
                nil
                (if (<= code #x26D4) t
                nil))))
            (if (<= code #x26EA) t
            (if (< code #x26F5)
              (if (< code #x26F2)
                nil
                (if (<= code #x26F3) t
                nil))
              (if (<= code #x26F5) t
              (if (< code #x26FA)
                nil
                (if (<= code #x26FA) t
                nil))))))
          (if (<= code #x26FD) t
          (if (< code #x274C)
            (if (< code #x270A)
              (if (< code #x2705)
                nil
                (if (<= code #x2705) t
                nil))
              (if (<= code #x270B) t
              (if (< code #x2728)
                nil
                (if (<= code #x2728) t
                nil))))
            (if (<= code #x274C) t
            (if (< code #x2753)
              (if (< code #x274E)
                nil
                (if (<= code #x274E) t
                nil))
              (if (<= code #x2755) t
              nil))))))))
      (if (<= code #x2757) t
      (if (< code #x31EF)
        (if (< code #x2E9B)
          (if (< code #x2B1B)
            (if (< code #x27B0)
              (if (< code #x2795)
                nil
                (if (<= code #x2797) t
                nil))
              (if (<= code #x27B0) t
              (if (< code #x27BF)
                nil
                (if (<= code #x27BF) t
                nil))))
            (if (<= code #x2B1C) t
            (if (< code #x2B55)
              (if (< code #x2B50)
                nil
                (if (<= code #x2B50) t
                nil))
              (if (<= code #x2B55) t
              (if (< code #x2E80)
                nil
                (if (<= code #x2E99) t
                nil))))))
          (if (<= code #x2EF3) t
          (if (< code #x3099)
            (if (< code #x2FF0)
              (if (< code #x2F00)
                nil
                (if (<= code #x2FD5) t
                nil))
              (if (<= code #x303E) t
              (if (< code #x3041)
                nil
                (if (<= code #x3096) t
                nil))))
            (if (<= code #x30FF) t
            (if (< code #x3131)
              (if (< code #x3105)
                nil
                (if (<= code #x312F) t
                nil))
              (if (<= code #x318E) t
              (if (< code #x3190)
                nil
                (if (<= code #x31E5) t
                nil))))))))
        (if (<= code #x321E) t
        (if (< code #xFE30)
          (if (< code #xA960)
            (if (< code #x3250)
              (if (< code #x3220)
                nil
                (if (<= code #x3247) t
                nil))
              (if (<= code #xA48C) t
              (if (< code #xA490)
                nil
                (if (<= code #xA4C6) t
                nil))))
            (if (<= code #xA97C) t
            (if (< code #xF900)
              (if (< code #xAC00)
                nil
                (if (<= code #xD7A3) t
                nil))
              (if (<= code #xFAFF) t
              (if (< code #xFE10)
                nil
                (if (<= code #xFE19) t
                nil))))))
          (if (<= code #xFE52) t
          (if (< code #xFFE0)
            (if (< code #xFE68)
              (if (< code #xFE54)
                nil
                (if (<= code #xFE66) t
                nil))
              (if (<= code #xFE6B) t
              (if (< code #xFF01)
                nil
                (if (<= code #xFF60) t
                nil))))
            (if (<= code #xFFE6) t
            (if (< code #x16FF0)
              (if (< code #x16FE0)
                nil
                (if (<= code #x16FE4) t
                nil))
              (if (<= code #x16FF6) t
              nil))))))))))
    (if (<= code #x18CD5) t
    (if (< code #x1F3F8)
      (if (< code #x1F18E)
        (if (< code #x1B150)
          (if (< code #x1AFF5)
            (if (< code #x18D80)
              (if (< code #x18CFF)
                nil
                (if (<= code #x18D1E) t
                nil))
              (if (<= code #x18DF2) t
              (if (< code #x1AFF0)
                nil
                (if (<= code #x1AFF3) t
                nil))))
            (if (<= code #x1AFFB) t
            (if (< code #x1B000)
              (if (< code #x1AFFD)
                nil
                (if (<= code #x1AFFE) t
                nil))
              (if (<= code #x1B122) t
              (if (< code #x1B132)
                nil
                (if (<= code #x1B132) t
                nil))))))
          (if (<= code #x1B152) t
          (if (< code #x1D300)
            (if (< code #x1B164)
              (if (< code #x1B155)
                nil
                (if (<= code #x1B155) t
                nil))
              (if (<= code #x1B167) t
              (if (< code #x1B170)
                nil
                (if (<= code #x1B2FB) t
                nil))))
            (if (<= code #x1D356) t
            (if (< code #x1F004)
              (if (< code #x1D360)
                nil
                (if (<= code #x1D376) t
                nil))
              (if (<= code #x1F004) t
              (if (< code #x1F0CF)
                nil
                (if (<= code #x1F0CF) t
                nil))))))))
        (if (<= code #x1F18E) t
        (if (< code #x1F32D)
          (if (< code #x1F240)
            (if (< code #x1F1E6)
              (if (< code #x1F191)
                nil
                (if (<= code #x1F19A) t
                nil))
              (if (<= code #x1F202) t
              (if (< code #x1F210)
                nil
                (if (<= code #x1F23B) t
                nil))))
            (if (<= code #x1F248) t
            (if (< code #x1F260)
              (if (< code #x1F250)
                nil
                (if (<= code #x1F251) t
                nil))
              (if (<= code #x1F265) t
              (if (< code #x1F300)
                nil
                (if (<= code #x1F320) t
                nil))))))
          (if (<= code #x1F335) t
          (if (< code #x1F3CF)
            (if (< code #x1F37E)
              (if (< code #x1F337)
                nil
                (if (<= code #x1F37C) t
                nil))
              (if (<= code #x1F393) t
              (if (< code #x1F3A0)
                nil
                (if (<= code #x1F3CA) t
                nil))))
            (if (<= code #x1F3D3) t
            (if (< code #x1F3F4)
              (if (< code #x1F3E0)
                nil
                (if (<= code #x1F3F0) t
                nil))
              (if (<= code #x1F3F4) t
              nil))))))))
      (if (<= code #x1F43E) t
      (if (< code #x1F6F4)
        (if (< code #x1F5A4)
          (if (< code #x1F54B)
            (if (< code #x1F442)
              (if (< code #x1F440)
                nil
                (if (<= code #x1F440) t
                nil))
              (if (<= code #x1F4FC) t
              (if (< code #x1F4FF)
                nil
                (if (<= code #x1F53D) t
                nil))))
            (if (<= code #x1F54E) t
            (if (< code #x1F57A)
              (if (< code #x1F550)
                nil
                (if (<= code #x1F567) t
                nil))
              (if (<= code #x1F57A) t
              (if (< code #x1F595)
                nil
                (if (<= code #x1F596) t
                nil))))))
          (if (<= code #x1F5A4) t
          (if (< code #x1F6D0)
            (if (< code #x1F680)
              (if (< code #x1F5FB)
                nil
                (if (<= code #x1F64F) t
                nil))
              (if (<= code #x1F6C5) t
              (if (< code #x1F6CC)
                nil
                (if (<= code #x1F6CC) t
                nil))))
            (if (<= code #x1F6D2) t
            (if (< code #x1F6DC)
              (if (< code #x1F6D5)
                nil
                (if (<= code #x1F6D8) t
                nil))
              (if (<= code #x1F6DF) t
              (if (< code #x1F6EB)
                nil
                (if (<= code #x1F6EC) t
                nil))))))))
        (if (<= code #x1F6FC) t
        (if (< code #x1FA8E)
          (if (< code #x1F93C)
            (if (< code #x1F7F0)
              (if (< code #x1F7E0)
                nil
                (if (<= code #x1F7EB) t
                nil))
              (if (<= code #x1F7F0) t
              (if (< code #x1F90C)
                nil
                (if (<= code #x1F93A) t
                nil))))
            (if (<= code #x1F945) t
            (if (< code #x1FA70)
              (if (< code #x1F947)
                nil
                (if (<= code #x1F9FF) t
                nil))
              (if (<= code #x1FA7C) t
              (if (< code #x1FA80)
                nil
                (if (<= code #x1FA8A) t
                nil))))))
          (if (<= code #x1FAC6) t
          (if (< code #x1FAEF)
            (if (< code #x1FACD)
              (if (< code #x1FAC8)
                nil
                (if (<= code #x1FAC8) t
                nil))
              (if (<= code #x1FADC) t
              (if (< code #x1FADF)
                nil
                (if (<= code #x1FAEA) t
                nil))))
            (if (<= code #x1FAF8) t
            (if (< code #x30000)
              (if (< code #x20000)
                nil
                (if (<= code #x2FFFD) t
                nil))
              (if (<= code #x3FFFD) t
              nil)))))))))))))

;; East_Asian_Width A -> configurable width (*ambiguous-character-width*).
(defun k-ambiguous-code-p (code)
  (declare (type (unsigned-byte 32) code)
           (optimize (speed 3) (safety 0) (debug 0)))
  (if (< code #x2190)
    (if (< code #x261)
      (if (< code #x113)
        (if (< code #xDE)
          (if (< code #xB0)
            (if (< code #xA7)
              (if (< code #xA4)
                (if (< code #xA1)
                  nil
                  (if (<= code #xA1) t
                  nil))
                (if (<= code #xA4) t
                nil))
              (if (<= code #xA8) t
              (if (< code #xAD)
                (if (< code #xAA)
                  nil
                  (if (<= code #xAA) t
                  nil))
                (if (<= code #xAE) t
                nil))))
            (if (<= code #xB4) t
            (if (< code #xC6)
              (if (< code #xBC)
                (if (< code #xB6)
                  nil
                  (if (<= code #xBA) t
                  nil))
                (if (<= code #xBF) t
                nil))
              (if (<= code #xC6) t
              (if (< code #xD7)
                (if (< code #xD0)
                  nil
                  (if (<= code #xD0) t
                  nil))
                (if (<= code #xD8) t
                nil))))))
          (if (<= code #xE1) t
          (if (< code #xF7)
            (if (< code #xEC)
              (if (< code #xE8)
                (if (< code #xE6)
                  nil
                  (if (<= code #xE6) t
                  nil))
                (if (<= code #xEA) t
                nil))
              (if (<= code #xED) t
              (if (< code #xF2)
                (if (< code #xF0)
                  nil
                  (if (<= code #xF0) t
                  nil))
                (if (<= code #xF3) t
                nil))))
            (if (<= code #xFA) t
            (if (< code #x101)
              (if (< code #xFE)
                (if (< code #xFC)
                  nil
                  (if (<= code #xFC) t
                  nil))
                (if (<= code #xFE) t
                nil))
              (if (<= code #x101) t
              (if (< code #x111)
                nil
                (if (<= code #x111) t
                nil))))))))
        (if (<= code #x113) t
        (if (< code #x166)
          (if (< code #x13F)
            (if (< code #x12B)
              (if (< code #x126)
                (if (< code #x11B)
                  nil
                  (if (<= code #x11B) t
                  nil))
                (if (<= code #x127) t
                nil))
              (if (<= code #x12B) t
              (if (< code #x138)
                (if (< code #x131)
                  nil
                  (if (<= code #x133) t
                  nil))
                (if (<= code #x138) t
                nil))))
            (if (<= code #x142) t
            (if (< code #x14D)
              (if (< code #x148)
                (if (< code #x144)
                  nil
                  (if (<= code #x144) t
                  nil))
                (if (<= code #x14B) t
                nil))
              (if (<= code #x14D) t
              (if (< code #x152)
                nil
                (if (<= code #x153) t
                nil))))))
          (if (<= code #x167) t
          (if (< code #x1D6)
            (if (< code #x1D0)
              (if (< code #x1CE)
                (if (< code #x16B)
                  nil
                  (if (<= code #x16B) t
                  nil))
                (if (<= code #x1CE) t
                nil))
              (if (<= code #x1D0) t
              (if (< code #x1D4)
                (if (< code #x1D2)
                  nil
                  (if (<= code #x1D2) t
                  nil))
                (if (<= code #x1D4) t
                nil))))
            (if (<= code #x1D6) t
            (if (< code #x1DC)
              (if (< code #x1DA)
                (if (< code #x1D8)
                  nil
                  (if (<= code #x1D8) t
                  nil))
                (if (<= code #x1DA) t
                nil))
              (if (<= code #x1DC) t
              (if (< code #x251)
                nil
                (if (<= code #x251) t
                nil))))))))))
      (if (<= code #x261) t
      (if (< code #x2030)
        (if (< code #x3B1)
          (if (< code #x2D8)
            (if (< code #x2C9)
              (if (< code #x2C7)
                (if (< code #x2C4)
                  nil
                  (if (<= code #x2C4) t
                  nil))
                (if (<= code #x2C7) t
                nil))
              (if (<= code #x2CB) t
              (if (< code #x2D0)
                (if (< code #x2CD)
                  nil
                  (if (<= code #x2CD) t
                  nil))
                (if (<= code #x2D0) t
                nil))))
            (if (<= code #x2DB) t
            (if (< code #x300)
              (if (< code #x2DF)
                (if (< code #x2DD)
                  nil
                  (if (<= code #x2DD) t
                  nil))
                (if (<= code #x2DF) t
                nil))
              (if (<= code #x36F) t
              (if (< code #x3A3)
                (if (< code #x391)
                  nil
                  (if (<= code #x3A1) t
                  nil))
                (if (<= code #x3A9) t
                nil))))))
          (if (<= code #x3C1) t
          (if (< code #x2013)
            (if (< code #x410)
              (if (< code #x401)
                (if (< code #x3C3)
                  nil
                  (if (<= code #x3C9) t
                  nil))
                (if (<= code #x401) t
                nil))
              (if (<= code #x44F) t
              (if (< code #x2010)
                (if (< code #x451)
                  nil
                  (if (<= code #x451) t
                  nil))
                (if (<= code #x2010) t
                nil))))
            (if (<= code #x2016) t
            (if (< code #x2020)
              (if (< code #x201C)
                (if (< code #x2018)
                  nil
                  (if (<= code #x2019) t
                  nil))
                (if (<= code #x201D) t
                nil))
              (if (<= code #x2022) t
              (if (< code #x2024)
                nil
                (if (<= code #x2027) t
                nil))))))))
        (if (<= code #x2030) t
        (if (< code #x2109)
          (if (< code #x207F)
            (if (< code #x203B)
              (if (< code #x2035)
                (if (< code #x2032)
                  nil
                  (if (<= code #x2033) t
                  nil))
                (if (<= code #x2035) t
                nil))
              (if (<= code #x203B) t
              (if (< code #x2074)
                (if (< code #x203E)
                  nil
                  (if (<= code #x203E) t
                  nil))
                (if (<= code #x2074) t
                nil))))
            (if (<= code #x207F) t
            (if (< code #x2103)
              (if (< code #x20AC)
                (if (< code #x2081)
                  nil
                  (if (<= code #x2084) t
                  nil))
                (if (<= code #x20AC) t
                nil))
              (if (<= code #x2103) t
              (if (< code #x2105)
                nil
                (if (<= code #x2105) t
                nil))))))
          (if (<= code #x2109) t
          (if (< code #x2153)
            (if (< code #x2121)
              (if (< code #x2116)
                (if (< code #x2113)
                  nil
                  (if (<= code #x2113) t
                  nil))
                (if (<= code #x2116) t
                nil))
              (if (<= code #x2122) t
              (if (< code #x212B)
                (if (< code #x2126)
                  nil
                  (if (<= code #x2126) t
                  nil))
                (if (<= code #x212B) t
                nil))))
            (if (<= code #x2154) t
            (if (< code #x2170)
              (if (< code #x2160)
                (if (< code #x215B)
                  nil
                  (if (<= code #x215E) t
                  nil))
                (if (<= code #x216B) t
                nil))
              (if (<= code #x2179) t
              (if (< code #x2189)
                nil
                (if (<= code #x2189) t
                nil))))))))))))
    (if (<= code #x2199) t
    (if (< code #x25C6)
      (if (< code #x2260)
        (if (< code #x221A)
          (if (< code #x2202)
            (if (< code #x21D4)
              (if (< code #x21D2)
                (if (< code #x21B8)
                  nil
                  (if (<= code #x21B9) t
                  nil))
                (if (<= code #x21D2) t
                nil))
              (if (<= code #x21D4) t
              (if (< code #x2200)
                (if (< code #x21E7)
                  nil
                  (if (<= code #x21E7) t
                  nil))
                (if (<= code #x2200) t
                nil))))
            (if (<= code #x2203) t
            (if (< code #x220F)
              (if (< code #x220B)
                (if (< code #x2207)
                  nil
                  (if (<= code #x2208) t
                  nil))
                (if (<= code #x220B) t
                nil))
              (if (<= code #x220F) t
              (if (< code #x2215)
                (if (< code #x2211)
                  nil
                  (if (<= code #x2211) t
                  nil))
                (if (<= code #x2215) t
                nil))))))
          (if (<= code #x221A) t
          (if (< code #x2234)
            (if (< code #x2225)
              (if (< code #x2223)
                (if (< code #x221D)
                  nil
                  (if (<= code #x2220) t
                  nil))
                (if (<= code #x2223) t
                nil))
              (if (<= code #x2225) t
              (if (< code #x222E)
                (if (< code #x2227)
                  nil
                  (if (<= code #x222C) t
                  nil))
                (if (<= code #x222E) t
                nil))))
            (if (<= code #x2237) t
            (if (< code #x224C)
              (if (< code #x2248)
                (if (< code #x223C)
                  nil
                  (if (<= code #x223D) t
                  nil))
                (if (<= code #x2248) t
                nil))
              (if (<= code #x224C) t
              (if (< code #x2252)
                nil
                (if (<= code #x2252) t
                nil))))))))
        (if (<= code #x2261) t
        (if (< code #x2460)
          (if (< code #x2295)
            (if (< code #x226E)
              (if (< code #x226A)
                (if (< code #x2264)
                  nil
                  (if (<= code #x2267) t
                  nil))
                (if (<= code #x226B) t
                nil))
              (if (<= code #x226F) t
              (if (< code #x2286)
                (if (< code #x2282)
                  nil
                  (if (<= code #x2283) t
                  nil))
                (if (<= code #x2287) t
                nil))))
            (if (<= code #x2295) t
            (if (< code #x22BF)
              (if (< code #x22A5)
                (if (< code #x2299)
                  nil
                  (if (<= code #x2299) t
                  nil))
                (if (<= code #x22A5) t
                nil))
              (if (<= code #x22BF) t
              (if (< code #x2312)
                nil
                (if (<= code #x2312) t
                nil))))))
          (if (<= code #x24E9) t
          (if (< code #x25A3)
            (if (< code #x2580)
              (if (< code #x2550)
                (if (< code #x24EB)
                  nil
                  (if (<= code #x254B) t
                  nil))
                (if (<= code #x2573) t
                nil))
              (if (<= code #x258F) t
              (if (< code #x25A0)
                (if (< code #x2592)
                  nil
                  (if (<= code #x2595) t
                  nil))
                (if (<= code #x25A1) t
                nil))))
            (if (<= code #x25A9) t
            (if (< code #x25BC)
              (if (< code #x25B6)
                (if (< code #x25B2)
                  nil
                  (if (<= code #x25B3) t
                  nil))
                (if (<= code #x25B7) t
                nil))
              (if (<= code #x25BD) t
              (if (< code #x25C0)
                nil
                (if (<= code #x25C1) t
                nil))))))))))
      (if (<= code #x25C8) t
      (if (< code #x26E8)
        (if (< code #x2660)
          (if (< code #x2609)
            (if (< code #x25E2)
              (if (< code #x25CE)
                (if (< code #x25CB)
                  nil
                  (if (<= code #x25CB) t
                  nil))
                (if (<= code #x25D1) t
                nil))
              (if (<= code #x25E5) t
              (if (< code #x2605)
                (if (< code #x25EF)
                  nil
                  (if (<= code #x25EF) t
                  nil))
                (if (<= code #x2606) t
                nil))))
            (if (<= code #x2609) t
            (if (< code #x261E)
              (if (< code #x261C)
                (if (< code #x260E)
                  nil
                  (if (<= code #x260F) t
                  nil))
                (if (<= code #x261C) t
                nil))
              (if (<= code #x261E) t
              (if (< code #x2642)
                (if (< code #x2640)
                  nil
                  (if (<= code #x2640) t
                  nil))
                (if (<= code #x2642) t
                nil))))))
          (if (<= code #x2661) t
          (if (< code #x26BF)
            (if (< code #x266C)
              (if (< code #x2667)
                (if (< code #x2663)
                  nil
                  (if (<= code #x2665) t
                  nil))
                (if (<= code #x266A) t
                nil))
              (if (<= code #x266D) t
              (if (< code #x269E)
                (if (< code #x266F)
                  nil
                  (if (<= code #x266F) t
                  nil))
                (if (<= code #x269F) t
                nil))))
            (if (<= code #x26BF) t
            (if (< code #x26D5)
              (if (< code #x26CF)
                (if (< code #x26C6)
                  nil
                  (if (<= code #x26CD) t
                  nil))
                (if (<= code #x26D3) t
                nil))
              (if (<= code #x26E1) t
              (if (< code #x26E3)
                nil
                (if (<= code #x26E3) t
                nil))))))))
        (if (<= code #x26E9) t
        (if (< code #xFE00)
          (if (< code #x273D)
            (if (< code #x26F6)
              (if (< code #x26F4)
                (if (< code #x26EB)
                  nil
                  (if (<= code #x26F1) t
                  nil))
                (if (<= code #x26F4) t
                nil))
              (if (<= code #x26F9) t
              (if (< code #x26FE)
                (if (< code #x26FB)
                  nil
                  (if (<= code #x26FC) t
                  nil))
                (if (<= code #x26FF) t
                nil))))
            (if (<= code #x273D) t
            (if (< code #x3248)
              (if (< code #x2B56)
                (if (< code #x2776)
                  nil
                  (if (<= code #x277F) t
                  nil))
                (if (<= code #x2B59) t
                nil))
              (if (<= code #x324F) t
              (if (< code #xE000)
                nil
                (if (<= code #xF8FF) t
                nil))))))
          (if (<= code #xFE0F) t
          (if (< code #x1F18F)
            (if (< code #x1F110)
              (if (< code #x1F100)
                (if (< code #xFFFD)
                  nil
                  (if (<= code #xFFFD) t
                  nil))
                (if (<= code #x1F10A) t
                nil))
              (if (<= code #x1F12D) t
              (if (< code #x1F170)
                (if (< code #x1F130)
                  nil
                  (if (<= code #x1F169) t
                  nil))
                (if (<= code #x1F18D) t
                nil))))
            (if (<= code #x1F190) t
            (if (< code #xF0000)
              (if (< code #xE0100)
                (if (< code #x1F19B)
                  nil
                  (if (<= code #x1F1AC) t
                  nil))
                (if (<= code #xE01EF) t
                nil))
              (if (<= code #xFFFFD) t
              (if (< code #x100000)
                nil
                (if (<= code #x10FFFD) t
                nil)))))))))))))))

;; General category Mn or Me, plus ZWJ (U+200D) -> display width 0.
(defun k-zero-code-p (code)
  (declare (type (unsigned-byte 32) code)
           (optimize (speed 3) (safety 0) (debug 0)))
  (if (< code #xA82C)
    (if (< code #xEB1)
      (if (< code #xA70)
        (if (< code #x829)
          (if (< code #x6DF)
            (if (< code #x5C4)
              (if (< code #x591)
                (if (< code #x483)
                  (if (< code #x300)
                    nil
                    (if (<= code #x36F) t
                    nil))
                  (if (<= code #x489) t
                  nil))
                (if (<= code #x5BD) t
                (if (< code #x5C1)
                  (if (< code #x5BF)
                    nil
                    (if (<= code #x5BF) t
                    nil))
                  (if (<= code #x5C2) t
                  nil))))
              (if (<= code #x5C5) t
              (if (< code #x64B)
                (if (< code #x610)
                  (if (< code #x5C7)
                    nil
                    (if (<= code #x5C7) t
                    nil))
                  (if (<= code #x61A) t
                  nil))
                (if (<= code #x65F) t
                (if (< code #x6D6)
                  (if (< code #x670)
                    nil
                    (if (<= code #x670) t
                    nil))
                  (if (<= code #x6DC) t
                  nil))))))
            (if (<= code #x6E4) t
            (if (< code #x7EB)
              (if (< code #x711)
                (if (< code #x6EA)
                  (if (< code #x6E7)
                    nil
                    (if (<= code #x6E8) t
                    nil))
                  (if (<= code #x6ED) t
                  nil))
                (if (<= code #x711) t
                (if (< code #x7A6)
                  (if (< code #x730)
                    nil
                    (if (<= code #x74A) t
                    nil))
                  (if (<= code #x7B0) t
                  nil))))
              (if (<= code #x7F3) t
              (if (< code #x81B)
                (if (< code #x816)
                  (if (< code #x7FD)
                    nil
                    (if (<= code #x7FD) t
                    nil))
                  (if (<= code #x819) t
                  nil))
                (if (<= code #x823) t
                (if (< code #x825)
                  nil
                  (if (<= code #x827) t
                  nil))))))))
          (if (<= code #x82D) t
          (if (< code #x9BC)
            (if (< code #x93C)
              (if (< code #x8CA)
                (if (< code #x897)
                  (if (< code #x859)
                    nil
                    (if (<= code #x85B) t
                    nil))
                  (if (<= code #x89F) t
                  nil))
                (if (<= code #x8E1) t
                (if (< code #x93A)
                  (if (< code #x8E3)
                    nil
                    (if (<= code #x902) t
                    nil))
                  (if (<= code #x93A) t
                  nil))))
              (if (<= code #x93C) t
              (if (< code #x951)
                (if (< code #x94D)
                  (if (< code #x941)
                    nil
                    (if (<= code #x948) t
                    nil))
                  (if (<= code #x94D) t
                  nil))
                (if (<= code #x957) t
                (if (< code #x981)
                  (if (< code #x962)
                    nil
                    (if (<= code #x963) t
                    nil))
                  (if (<= code #x981) t
                  nil))))))
            (if (<= code #x9BC) t
            (if (< code #xA3C)
              (if (< code #x9E2)
                (if (< code #x9CD)
                  (if (< code #x9C1)
                    nil
                    (if (<= code #x9C4) t
                    nil))
                  (if (<= code #x9CD) t
                  nil))
                (if (<= code #x9E3) t
                (if (< code #xA01)
                  (if (< code #x9FE)
                    nil
                    (if (<= code #x9FE) t
                    nil))
                  (if (<= code #xA02) t
                  nil))))
              (if (<= code #xA3C) t
              (if (< code #xA4B)
                (if (< code #xA47)
                  (if (< code #xA41)
                    nil
                    (if (<= code #xA42) t
                    nil))
                  (if (<= code #xA48) t
                  nil))
                (if (<= code #xA4D) t
                (if (< code #xA51)
                  nil
                  (if (<= code #xA51) t
                  nil))))))))))
        (if (<= code #xA71) t
        (if (< code #xC46)
          (if (< code #xB41)
            (if (< code #xACD)
              (if (< code #xABC)
                (if (< code #xA81)
                  (if (< code #xA75)
                    nil
                    (if (<= code #xA75) t
                    nil))
                  (if (<= code #xA82) t
                  nil))
                (if (<= code #xABC) t
                (if (< code #xAC7)
                  (if (< code #xAC1)
                    nil
                    (if (<= code #xAC5) t
                    nil))
                  (if (<= code #xAC8) t
                  nil))))
              (if (<= code #xACD) t
              (if (< code #xB01)
                (if (< code #xAFA)
                  (if (< code #xAE2)
                    nil
                    (if (<= code #xAE3) t
                    nil))
                  (if (<= code #xAFF) t
                  nil))
                (if (<= code #xB01) t
                (if (< code #xB3F)
                  (if (< code #xB3C)
                    nil
                    (if (<= code #xB3C) t
                    nil))
                  (if (<= code #xB3F) t
                  nil))))))
            (if (<= code #xB44) t
            (if (< code #xBCD)
              (if (< code #xB62)
                (if (< code #xB55)
                  (if (< code #xB4D)
                    nil
                    (if (<= code #xB4D) t
                    nil))
                  (if (<= code #xB56) t
                  nil))
                (if (<= code #xB63) t
                (if (< code #xBC0)
                  (if (< code #xB82)
                    nil
                    (if (<= code #xB82) t
                    nil))
                  (if (<= code #xBC0) t
                  nil))))
              (if (<= code #xBCD) t
              (if (< code #xC3C)
                (if (< code #xC04)
                  (if (< code #xC00)
                    nil
                    (if (<= code #xC00) t
                    nil))
                  (if (<= code #xC04) t
                  nil))
                (if (<= code #xC3C) t
                (if (< code #xC3E)
                  nil
                  (if (<= code #xC40) t
                  nil))))))))
          (if (<= code #xC48) t
          (if (< code #xD3B)
            (if (< code #xCBF)
              (if (< code #xC62)
                (if (< code #xC55)
                  (if (< code #xC4A)
                    nil
                    (if (<= code #xC4D) t
                    nil))
                  (if (<= code #xC56) t
                  nil))
                (if (<= code #xC63) t
                (if (< code #xCBC)
                  (if (< code #xC81)
                    nil
                    (if (<= code #xC81) t
                    nil))
                  (if (<= code #xCBC) t
                  nil))))
              (if (<= code #xCBF) t
              (if (< code #xCE2)
                (if (< code #xCCC)
                  (if (< code #xCC6)
                    nil
                    (if (<= code #xCC6) t
                    nil))
                  (if (<= code #xCCD) t
                  nil))
                (if (<= code #xCE3) t
                (if (< code #xD00)
                  nil
                  (if (<= code #xD01) t
                  nil))))))
            (if (<= code #xD3C) t
            (if (< code #xDD2)
              (if (< code #xD62)
                (if (< code #xD4D)
                  (if (< code #xD41)
                    nil
                    (if (<= code #xD44) t
                    nil))
                  (if (<= code #xD4D) t
                  nil))
                (if (<= code #xD63) t
                (if (< code #xDCA)
                  (if (< code #xD81)
                    nil
                    (if (<= code #xD81) t
                    nil))
                  (if (<= code #xDCA) t
                  nil))))
              (if (<= code #xDD4) t
              (if (< code #xE34)
                (if (< code #xE31)
                  (if (< code #xDD6)
                    nil
                    (if (<= code #xDD6) t
                    nil))
                  (if (<= code #xE31) t
                  nil))
                (if (<= code #xE3A) t
                (if (< code #xE47)
                  nil
                  (if (<= code #xE4E) t
                  nil))))))))))))
      (if (<= code #xEB1) t
      (if (< code #x1A60)
        (if (< code #x109D)
          (if (< code #xFC6)
            (if (< code #xF39)
              (if (< code #xF18)
                (if (< code #xEC8)
                  (if (< code #xEB4)
                    nil
                    (if (<= code #xEBC) t
                    nil))
                  (if (<= code #xECE) t
                  nil))
                (if (<= code #xF19) t
                (if (< code #xF37)
                  (if (< code #xF35)
                    nil
                    (if (<= code #xF35) t
                    nil))
                  (if (<= code #xF37) t
                  nil))))
              (if (<= code #xF39) t
              (if (< code #xF86)
                (if (< code #xF80)
                  (if (< code #xF71)
                    nil
                    (if (<= code #xF7E) t
                    nil))
                  (if (<= code #xF84) t
                  nil))
                (if (<= code #xF87) t
                (if (< code #xF99)
                  (if (< code #xF8D)
                    nil
                    (if (<= code #xF97) t
                    nil))
                  (if (<= code #xFBC) t
                  nil))))))
            (if (<= code #xFC6) t
            (if (< code #x105E)
              (if (< code #x1039)
                (if (< code #x1032)
                  (if (< code #x102D)
                    nil
                    (if (<= code #x1030) t
                    nil))
                  (if (<= code #x1037) t
                  nil))
                (if (<= code #x103A) t
                (if (< code #x1058)
                  (if (< code #x103D)
                    nil
                    (if (<= code #x103E) t
                    nil))
                  (if (<= code #x1059) t
                  nil))))
              (if (<= code #x1060) t
              (if (< code #x1085)
                (if (< code #x1082)
                  (if (< code #x1071)
                    nil
                    (if (<= code #x1074) t
                    nil))
                  (if (<= code #x1082) t
                  nil))
                (if (<= code #x1086) t
                (if (< code #x108D)
                  nil
                  (if (<= code #x108D) t
                  nil))))))))
          (if (<= code #x109D) t
          (if (< code #x180F)
            (if (< code #x17B4)
              (if (< code #x1732)
                (if (< code #x1712)
                  (if (< code #x135D)
                    nil
                    (if (<= code #x135F) t
                    nil))
                  (if (<= code #x1714) t
                  nil))
                (if (<= code #x1733) t
                (if (< code #x1772)
                  (if (< code #x1752)
                    nil
                    (if (<= code #x1753) t
                    nil))
                  (if (<= code #x1773) t
                  nil))))
              (if (<= code #x17B5) t
              (if (< code #x17C9)
                (if (< code #x17C6)
                  (if (< code #x17B7)
                    nil
                    (if (<= code #x17BD) t
                    nil))
                  (if (<= code #x17C6) t
                  nil))
                (if (<= code #x17D3) t
                (if (< code #x180B)
                  (if (< code #x17DD)
                    nil
                    (if (<= code #x17DD) t
                    nil))
                  (if (<= code #x180D) t
                  nil))))))
            (if (<= code #x180F) t
            (if (< code #x1939)
              (if (< code #x1920)
                (if (< code #x18A9)
                  (if (< code #x1885)
                    nil
                    (if (<= code #x1886) t
                    nil))
                  (if (<= code #x18A9) t
                  nil))
                (if (<= code #x1922) t
                (if (< code #x1932)
                  (if (< code #x1927)
                    nil
                    (if (<= code #x1928) t
                    nil))
                  (if (<= code #x1932) t
                  nil))))
              (if (<= code #x193B) t
              (if (< code #x1A56)
                (if (< code #x1A1B)
                  (if (< code #x1A17)
                    nil
                    (if (<= code #x1A18) t
                    nil))
                  (if (<= code #x1A1B) t
                  nil))
                (if (<= code #x1A56) t
                (if (< code #x1A58)
                  nil
                  (if (<= code #x1A5E) t
                  nil))))))))))
        (if (<= code #x1A60) t
        (if (< code #x1CD0)
          (if (< code #x1B6B)
            (if (< code #x1AE0)
              (if (< code #x1A73)
                (if (< code #x1A65)
                  (if (< code #x1A62)
                    nil
                    (if (<= code #x1A62) t
                    nil))
                  (if (<= code #x1A6C) t
                  nil))
                (if (<= code #x1A7C) t
                (if (< code #x1AB0)
                  (if (< code #x1A7F)
                    nil
                    (if (<= code #x1A7F) t
                    nil))
                  (if (<= code #x1ADD) t
                  nil))))
              (if (<= code #x1AEB) t
              (if (< code #x1B36)
                (if (< code #x1B34)
                  (if (< code #x1B00)
                    nil
                    (if (<= code #x1B03) t
                    nil))
                  (if (<= code #x1B34) t
                  nil))
                (if (<= code #x1B3A) t
                (if (< code #x1B42)
                  (if (< code #x1B3C)
                    nil
                    (if (<= code #x1B3C) t
                    nil))
                  (if (<= code #x1B42) t
                  nil))))))
            (if (<= code #x1B73) t
            (if (< code #x1BE8)
              (if (< code #x1BA8)
                (if (< code #x1BA2)
                  (if (< code #x1B80)
                    nil
                    (if (<= code #x1B81) t
                    nil))
                  (if (<= code #x1BA5) t
                  nil))
                (if (<= code #x1BA9) t
                (if (< code #x1BE6)
                  (if (< code #x1BAB)
                    nil
                    (if (<= code #x1BAD) t
                    nil))
                  (if (<= code #x1BE6) t
                  nil))))
              (if (<= code #x1BE9) t
              (if (< code #x1C2C)
                (if (< code #x1BEF)
                  (if (< code #x1BED)
                    nil
                    (if (<= code #x1BED) t
                    nil))
                  (if (<= code #x1BF1) t
                  nil))
                (if (<= code #x1C33) t
                (if (< code #x1C36)
                  nil
                  (if (<= code #x1C37) t
                  nil))))))))
          (if (<= code #x1CD2) t
          (if (< code #x2DE0)
            (if (< code #x1DC0)
              (if (< code #x1CED)
                (if (< code #x1CE2)
                  (if (< code #x1CD4)
                    nil
                    (if (<= code #x1CE0) t
                    nil))
                  (if (<= code #x1CE8) t
                  nil))
                (if (<= code #x1CED) t
                (if (< code #x1CF8)
                  (if (< code #x1CF4)
                    nil
                    (if (<= code #x1CF4) t
                    nil))
                  (if (<= code #x1CF9) t
                  nil))))
              (if (<= code #x1DFF) t
              (if (< code #x2CEF)
                (if (< code #x20D0)
                  (if (< code #x200D)
                    nil
                    (if (<= code #x200D) t
                    nil))
                  (if (<= code #x20F0) t
                  nil))
                (if (<= code #x2CF1) t
                (if (< code #x2D7F)
                  nil
                  (if (<= code #x2D7F) t
                  nil))))))
            (if (<= code #x2DFF) t
            (if (< code #xA6F0)
              (if (< code #xA66F)
                (if (< code #x3099)
                  (if (< code #x302A)
                    nil
                    (if (<= code #x302D) t
                    nil))
                  (if (<= code #x309A) t
                  nil))
                (if (<= code #xA672) t
                (if (< code #xA69E)
                  (if (< code #xA674)
                    nil
                    (if (<= code #xA67D) t
                    nil))
                  (if (<= code #xA69F) t
                  nil))))
              (if (<= code #xA6F1) t
              (if (< code #xA80B)
                (if (< code #xA806)
                  (if (< code #xA802)
                    nil
                    (if (<= code #xA802) t
                    nil))
                  (if (<= code #xA806) t
                  nil))
                (if (<= code #xA80B) t
                (if (< code #xA825)
                  nil
                  (if (<= code #xA826) t
                  nil))))))))))))))
    (if (<= code #xA82C) t
    (if (< code #x1163D)
      (if (< code #x11038)
        (if (< code #xAAF6)
          (if (< code #xAA31)
            (if (< code #xA980)
              (if (< code #xA8FF)
                (if (< code #xA8E0)
                  (if (< code #xA8C4)
                    nil
                    (if (<= code #xA8C5) t
                    nil))
                  (if (<= code #xA8F1) t
                  nil))
                (if (<= code #xA8FF) t
                (if (< code #xA947)
                  (if (< code #xA926)
                    nil
                    (if (<= code #xA92D) t
                    nil))
                  (if (<= code #xA951) t
                  nil))))
              (if (<= code #xA982) t
              (if (< code #xA9BC)
                (if (< code #xA9B6)
                  (if (< code #xA9B3)
                    nil
                    (if (<= code #xA9B3) t
                    nil))
                  (if (<= code #xA9B9) t
                  nil))
                (if (<= code #xA9BD) t
                (if (< code #xAA29)
                  (if (< code #xA9E5)
                    nil
                    (if (<= code #xA9E5) t
                    nil))
                  (if (<= code #xAA2E) t
                  nil))))))
            (if (<= code #xAA32) t
            (if (< code #xAAB2)
              (if (< code #xAA4C)
                (if (< code #xAA43)
                  (if (< code #xAA35)
                    nil
                    (if (<= code #xAA36) t
                    nil))
                  (if (<= code #xAA43) t
                  nil))
                (if (<= code #xAA4C) t
                (if (< code #xAAB0)
                  (if (< code #xAA7C)
                    nil
                    (if (<= code #xAA7C) t
                    nil))
                  (if (<= code #xAAB0) t
                  nil))))
              (if (<= code #xAAB4) t
              (if (< code #xAAC1)
                (if (< code #xAABE)
                  (if (< code #xAAB7)
                    nil
                    (if (<= code #xAAB8) t
                    nil))
                  (if (<= code #xAABF) t
                  nil))
                (if (<= code #xAAC1) t
                (if (< code #xAAEC)
                  nil
                  (if (<= code #xAAED) t
                  nil))))))))
          (if (<= code #xAAF6) t
          (if (< code #x10A0C)
            (if (< code #xFE20)
              (if (< code #xABED)
                (if (< code #xABE8)
                  (if (< code #xABE5)
                    nil
                    (if (<= code #xABE5) t
                    nil))
                  (if (<= code #xABE8) t
                  nil))
                (if (<= code #xABED) t
                (if (< code #xFE00)
                  (if (< code #xFB1E)
                    nil
                    (if (<= code #xFB1E) t
                    nil))
                  (if (<= code #xFE0F) t
                  nil))))
              (if (<= code #xFE2F) t
              (if (< code #x10376)
                (if (< code #x102E0)
                  (if (< code #x101FD)
                    nil
                    (if (<= code #x101FD) t
                    nil))
                  (if (<= code #x102E0) t
                  nil))
                (if (<= code #x1037A) t
                (if (< code #x10A05)
                  (if (< code #x10A01)
                    nil
                    (if (<= code #x10A03) t
                    nil))
                  (if (<= code #x10A06) t
                  nil))))))
            (if (<= code #x10A0F) t
            (if (< code #x10EAB)
              (if (< code #x10AE5)
                (if (< code #x10A3F)
                  (if (< code #x10A38)
                    nil
                    (if (<= code #x10A3A) t
                    nil))
                  (if (<= code #x10A3F) t
                  nil))
                (if (<= code #x10AE6) t
                (if (< code #x10D69)
                  (if (< code #x10D24)
                    nil
                    (if (<= code #x10D27) t
                    nil))
                  (if (<= code #x10D6D) t
                  nil))))
              (if (<= code #x10EAC) t
              (if (< code #x10F82)
                (if (< code #x10F46)
                  (if (< code #x10EFA)
                    nil
                    (if (<= code #x10EFF) t
                    nil))
                  (if (<= code #x10F50) t
                  nil))
                (if (<= code #x10F85) t
                (if (< code #x11001)
                  nil
                  (if (<= code #x11001) t
                  nil))))))))))
        (if (<= code #x11046) t
        (if (< code #x1133B)
          (if (< code #x111B6)
            (if (< code #x110C2)
              (if (< code #x1107F)
                (if (< code #x11073)
                  (if (< code #x11070)
                    nil
                    (if (<= code #x11070) t
                    nil))
                  (if (<= code #x11074) t
                  nil))
                (if (<= code #x11081) t
                (if (< code #x110B9)
                  (if (< code #x110B3)
                    nil
                    (if (<= code #x110B6) t
                    nil))
                  (if (<= code #x110BA) t
                  nil))))
              (if (<= code #x110C2) t
              (if (< code #x1112D)
                (if (< code #x11127)
                  (if (< code #x11100)
                    nil
                    (if (<= code #x11102) t
                    nil))
                  (if (<= code #x1112B) t
                  nil))
                (if (<= code #x11134) t
                (if (< code #x11180)
                  (if (< code #x11173)
                    nil
                    (if (<= code #x11173) t
                    nil))
                  (if (<= code #x11181) t
                  nil))))))
            (if (<= code #x111BE) t
            (if (< code #x1123E)
              (if (< code #x1122F)
                (if (< code #x111CF)
                  (if (< code #x111C9)
                    nil
                    (if (<= code #x111CC) t
                    nil))
                  (if (<= code #x111CF) t
                  nil))
                (if (<= code #x11231) t
                (if (< code #x11236)
                  (if (< code #x11234)
                    nil
                    (if (<= code #x11234) t
                    nil))
                  (if (<= code #x11237) t
                  nil))))
              (if (<= code #x1123E) t
              (if (< code #x112E3)
                (if (< code #x112DF)
                  (if (< code #x11241)
                    nil
                    (if (<= code #x11241) t
                    nil))
                  (if (<= code #x112DF) t
                  nil))
                (if (<= code #x112EA) t
                (if (< code #x11300)
                  nil
                  (if (<= code #x11301) t
                  nil))))))))
          (if (<= code #x1133C) t
          (if (< code #x11446)
            (if (< code #x113D0)
              (if (< code #x11370)
                (if (< code #x11366)
                  (if (< code #x11340)
                    nil
                    (if (<= code #x11340) t
                    nil))
                  (if (<= code #x1136C) t
                  nil))
                (if (<= code #x11374) t
                (if (< code #x113CE)
                  (if (< code #x113BB)
                    nil
                    (if (<= code #x113C0) t
                    nil))
                  (if (<= code #x113CE) t
                  nil))))
              (if (<= code #x113D0) t
              (if (< code #x11438)
                (if (< code #x113E1)
                  (if (< code #x113D2)
                    nil
                    (if (<= code #x113D2) t
                    nil))
                  (if (<= code #x113E2) t
                  nil))
                (if (<= code #x1143F) t
                (if (< code #x11442)
                  nil
                  (if (<= code #x11444) t
                  nil))))))
            (if (<= code #x11446) t
            (if (< code #x115B2)
              (if (< code #x114BA)
                (if (< code #x114B3)
                  (if (< code #x1145E)
                    nil
                    (if (<= code #x1145E) t
                    nil))
                  (if (<= code #x114B8) t
                  nil))
                (if (<= code #x114BA) t
                (if (< code #x114C2)
                  (if (< code #x114BF)
                    nil
                    (if (<= code #x114C0) t
                    nil))
                  (if (<= code #x114C3) t
                  nil))))
              (if (<= code #x115B5) t
              (if (< code #x115DC)
                (if (< code #x115BF)
                  (if (< code #x115BC)
                    nil
                    (if (<= code #x115BD) t
                    nil))
                  (if (<= code #x115C0) t
                  nil))
                (if (<= code #x115DD) t
                (if (< code #x11633)
                  nil
                  (if (<= code #x1163A) t
                  nil))))))))))))
      (if (<= code #x1163D) t
      (if (< code #x11F36)
        (if (< code #x11A59)
          (if (< code #x1193B)
            (if (< code #x1171D)
              (if (< code #x116AD)
                (if (< code #x116AB)
                  (if (< code #x1163F)
                    nil
                    (if (<= code #x11640) t
                    nil))
                  (if (<= code #x116AB) t
                  nil))
                (if (<= code #x116AD) t
                (if (< code #x116B7)
                  (if (< code #x116B0)
                    nil
                    (if (<= code #x116B5) t
                    nil))
                  (if (<= code #x116B7) t
                  nil))))
              (if (<= code #x1171D) t
              (if (< code #x11727)
                (if (< code #x11722)
                  (if (< code #x1171F)
                    nil
                    (if (<= code #x1171F) t
                    nil))
                  (if (<= code #x11725) t
                  nil))
                (if (<= code #x1172B) t
                (if (< code #x11839)
                  (if (< code #x1182F)
                    nil
                    (if (<= code #x11837) t
                    nil))
                  (if (<= code #x1183A) t
                  nil))))))
            (if (<= code #x1193C) t
            (if (< code #x11A01)
              (if (< code #x119D4)
                (if (< code #x11943)
                  (if (< code #x1193E)
                    nil
                    (if (<= code #x1193E) t
                    nil))
                  (if (<= code #x11943) t
                  nil))
                (if (<= code #x119D7) t
                (if (< code #x119E0)
                  (if (< code #x119DA)
                    nil
                    (if (<= code #x119DB) t
                    nil))
                  (if (<= code #x119E0) t
                  nil))))
              (if (<= code #x11A0A) t
              (if (< code #x11A47)
                (if (< code #x11A3B)
                  (if (< code #x11A33)
                    nil
                    (if (<= code #x11A38) t
                    nil))
                  (if (<= code #x11A3E) t
                  nil))
                (if (<= code #x11A47) t
                (if (< code #x11A51)
                  nil
                  (if (<= code #x11A56) t
                  nil))))))))
          (if (<= code #x11A5B) t
          (if (< code #x11CB5)
            (if (< code #x11C30)
              (if (< code #x11B60)
                (if (< code #x11A98)
                  (if (< code #x11A8A)
                    nil
                    (if (<= code #x11A96) t
                    nil))
                  (if (<= code #x11A99) t
                  nil))
                (if (<= code #x11B60) t
                (if (< code #x11B66)
                  (if (< code #x11B62)
                    nil
                    (if (<= code #x11B64) t
                    nil))
                  (if (<= code #x11B66) t
                  nil))))
              (if (<= code #x11C36) t
              (if (< code #x11C92)
                (if (< code #x11C3F)
                  (if (< code #x11C38)
                    nil
                    (if (<= code #x11C3D) t
                    nil))
                  (if (<= code #x11C3F) t
                  nil))
                (if (<= code #x11CA7) t
                (if (< code #x11CB2)
                  (if (< code #x11CAA)
                    nil
                    (if (<= code #x11CB0) t
                    nil))
                  (if (<= code #x11CB3) t
                  nil))))))
            (if (<= code #x11CB6) t
            (if (< code #x11D90)
              (if (< code #x11D3C)
                (if (< code #x11D3A)
                  (if (< code #x11D31)
                    nil
                    (if (<= code #x11D36) t
                    nil))
                  (if (<= code #x11D3A) t
                  nil))
                (if (<= code #x11D3D) t
                (if (< code #x11D47)
                  (if (< code #x11D3F)
                    nil
                    (if (<= code #x11D45) t
                    nil))
                  (if (<= code #x11D47) t
                  nil))))
              (if (<= code #x11D91) t
              (if (< code #x11EF3)
                (if (< code #x11D97)
                  (if (< code #x11D95)
                    nil
                    (if (<= code #x11D95) t
                    nil))
                  (if (<= code #x11D97) t
                  nil))
                (if (<= code #x11EF4) t
                (if (< code #x11F00)
                  nil
                  (if (<= code #x11F01) t
                  nil))))))))))
        (if (<= code #x11F3A) t
        (if (< code #x1DA75)
          (if (< code #x16FE4)
            (if (< code #x1611E)
              (if (< code #x11F5A)
                (if (< code #x11F42)
                  (if (< code #x11F40)
                    nil
                    (if (<= code #x11F40) t
                    nil))
                  (if (<= code #x11F42) t
                  nil))
                (if (<= code #x11F5A) t
                (if (< code #x13447)
                  (if (< code #x13440)
                    nil
                    (if (<= code #x13440) t
                    nil))
                  (if (<= code #x13455) t
                  nil))))
              (if (<= code #x16129) t
              (if (< code #x16B30)
                (if (< code #x16AF0)
                  (if (< code #x1612D)
                    nil
                    (if (<= code #x1612F) t
                    nil))
                  (if (<= code #x16AF4) t
                  nil))
                (if (<= code #x16B36) t
                (if (< code #x16F8F)
                  (if (< code #x16F4F)
                    nil
                    (if (<= code #x16F4F) t
                    nil))
                  (if (<= code #x16F92) t
                  nil))))))
            (if (<= code #x16FE4) t
            (if (< code #x1D185)
              (if (< code #x1CF30)
                (if (< code #x1CF00)
                  (if (< code #x1BC9D)
                    nil
                    (if (<= code #x1BC9E) t
                    nil))
                  (if (<= code #x1CF2D) t
                  nil))
                (if (<= code #x1CF46) t
                (if (< code #x1D17B)
                  (if (< code #x1D167)
                    nil
                    (if (<= code #x1D169) t
                    nil))
                  (if (<= code #x1D182) t
                  nil))))
              (if (<= code #x1D18B) t
              (if (< code #x1DA00)
                (if (< code #x1D242)
                  (if (< code #x1D1AA)
                    nil
                    (if (<= code #x1D1AD) t
                    nil))
                  (if (<= code #x1D244) t
                  nil))
                (if (<= code #x1DA36) t
                (if (< code #x1DA3B)
                  nil
                  (if (<= code #x1DA6C) t
                  nil))))))))
          (if (<= code #x1DA75) t
          (if (< code #x1E2AE)
            (if (< code #x1E01B)
              (if (< code #x1DAA1)
                (if (< code #x1DA9B)
                  (if (< code #x1DA84)
                    nil
                    (if (<= code #x1DA84) t
                    nil))
                  (if (<= code #x1DA9F) t
                  nil))
                (if (<= code #x1DAAF) t
                (if (< code #x1E008)
                  (if (< code #x1E000)
                    nil
                    (if (<= code #x1E006) t
                    nil))
                  (if (<= code #x1E018) t
                  nil))))
              (if (<= code #x1E021) t
              (if (< code #x1E08F)
                (if (< code #x1E026)
                  (if (< code #x1E023)
                    nil
                    (if (<= code #x1E024) t
                    nil))
                  (if (<= code #x1E02A) t
                  nil))
                (if (<= code #x1E08F) t
                (if (< code #x1E130)
                  nil
                  (if (<= code #x1E136) t
                  nil))))))
            (if (<= code #x1E2AE) t
            (if (< code #x1E6EE)
              (if (< code #x1E5EE)
                (if (< code #x1E4EC)
                  (if (< code #x1E2EC)
                    nil
                    (if (<= code #x1E2EF) t
                    nil))
                  (if (<= code #x1E4EF) t
                  nil))
                (if (<= code #x1E5EF) t
                (if (< code #x1E6E6)
                  (if (< code #x1E6E3)
                    nil
                    (if (<= code #x1E6E3) t
                    nil))
                  (if (<= code #x1E6E6) t
                  nil))))
              (if (<= code #x1E6EF) t
              (if (< code #x1E944)
                (if (< code #x1E8D0)
                  (if (< code #x1E6F5)
                    nil
                    (if (<= code #x1E6F5) t
                    nil))
                  (if (<= code #x1E8D6) t
                  nil))
                (if (<= code #x1E94A) t
                (if (< code #xE0100)
                  nil
                  (if (<= code #xE01EF) t
                  nil)))))))))))))))))

