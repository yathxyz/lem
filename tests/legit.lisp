(defpackage :lem-tests/legit
  (:use :cl :lem :rove)
  (:import-from :lem
                :with-current-buffers)
  (:import-from :lem-fake-interface
                :with-fake-interface))
(in-package :lem-tests/legit)

;; Note: This test file uses internal symbols (::) from lem/legit package
;; because we need to test internal state management that is not part of
;; the public API. This is standard practice for unit testing internals.

;;; Helper functions and macros

(defmacro with-fresh-legit-context (&body body)
  `(unwind-protect
       (progn (assert (null (lem/legit::current-pane-context))) ,@body)
     (cleanup-legit-windows)))

(defun cleanup-legit-windows ()
  (lem/legit::finalize-peek-legit))

(defun call-with-temp-git-repo (function)
  "Call FUNCTION in a temporary git repository."
  (let ((temp-dir (uiop:ensure-directory-pathname
                   (format nil "~A/lem-test-~A/"
                           (uiop:temporary-directory)
                           (get-universal-time)))))
    (unwind-protect
         (progn
           (ensure-directories-exist temp-dir)
           (uiop:with-current-directory (temp-dir)
             ;; Initialize git repo
             (uiop:run-program '("git" "init") :ignore-error-status t)
             (uiop:run-program '("git" "config" "user.email" "test@test.com") :ignore-error-status t)
             (uiop:run-program '("git" "config" "user.name" "Test") :ignore-error-status t)
             ;; Create initial commit
             (with-open-file (s (merge-pathnames "README.md" temp-dir)
                                :direction :output :if-exists :supersede)
               (write-string "# Test" s))
             (uiop:run-program '("git" "add" ".") :ignore-error-status t)
             (uiop:run-program '("git" "commit" "-m" "Initial commit") :ignore-error-status t)
             (funcall function)))
      ;; Cleanup
      (uiop:delete-directory-tree temp-dir :validate t :if-does-not-exist :ignore))))

(defmacro with-temp-git-repo (&body body)
  "Execute BODY in a temporary git repository."
  `(call-with-temp-git-repo (lambda () ,@body)))

;;; Tests for legit-status-active-p

(deftest legit-status-active-p/unbound
  (testing "returns nil when the frame has no pane context"
    (with-current-buffers ()
      (with-fake-interface ()
        (with-fresh-legit-context
          (ok (not (lem/legit::legit-status-active-p))))))))

(deftest legit-status-active-p/deleted-window
  (testing "returns nil when the status pane is deleted"
    (with-current-buffers ()
      (with-fake-interface ()
        (with-fresh-legit-context
          ;; Create a floating window and then delete it
          (let* ((buffer (lem:make-buffer "*test-peek*" :temporary t))
                 (window (make-instance 'lem:floating-window
                                        :buffer buffer
                                        :x 0 :y 0
                                        :width 40 :height 20
                                        :use-modeline-p nil)))
            (setf (lem/legit::pane-context-peek (lem/legit::current-pane-context t)) window)
            ;; Delete the window
            (lem:delete-window window)
            (ok (not (lem/legit::legit-status-active-p)))))))))

(deftest legit-status-active-p/valid-window
  (testing "returns t when the status pane is valid"
    (with-current-buffers ()
      (with-fake-interface ()
        (with-fresh-legit-context
          (let* ((buffer (lem:make-buffer "*test-peek*" :temporary t))
                 (window (make-instance 'lem:floating-window
                                        :buffer buffer
                                        :x 0 :y 0
                                        :width 40 :height 20
                                        :use-modeline-p nil)))
            (setf (lem/legit::pane-context-peek (lem/legit::current-pane-context t)) window)
            (ok (lem/legit::legit-status-active-p))
            ;; Cleanup
            (lem:delete-window window)))))))

;;; Tests for display function state management

(deftest display/initial-open-sets-parent-window
  (testing "initial display sets the owning parent window to current window"
    (with-current-buffers ()
      (with-fake-interface ()
        (with-fresh-legit-context
          (let ((original-window (lem:current-window))
                (collector (make-instance 'lem/legit::collector
                                          :buffer (lem:make-buffer "*test-legit*" :temporary t))))
            (unwind-protect
                 (progn
                   ;; Call display
                   (lem/legit::display collector)
                   ;; Check that the owning parent window is set to original window
                   (ok (eq original-window (lem/legit::parent-window)))
                   ;; Check that new windows were created
                   (ok (not (null (lem/legit::peek-window))))
                   (ok (not (null (lem/legit::source-window))))
                   (ok (not (lem:deleted-window-p (lem/legit::peek-window))))
                   (ok (not (lem:deleted-window-p (lem/legit::source-window)))))
              ;; Cleanup - always run
              (cleanup-legit-windows))))))))

(deftest display/refresh-preserves-parent-window
  (testing "refresh preserves the owning parent window"
    (with-current-buffers ()
      (with-fake-interface ()
        (with-fresh-legit-context
          (let ((original-window (lem:current-window))
                (collector (make-instance 'lem/legit::collector
                                          :buffer (lem:make-buffer "*test-legit*" :temporary t))))
            (unwind-protect
                 (progn
                   ;; Initial display
                   (lem/legit::display collector)
                   (ok (eq original-window (lem/legit::parent-window)))
                   (let ((first-peek-window (lem/legit::peek-window))
                         (first-source-window (lem/legit::source-window)))
                     ;; Refresh (call display again)
                     (let ((collector2 (make-instance 'lem/legit::collector
                                                      :buffer (lem:make-buffer "*test-legit-2*" :temporary t))))
                       (lem/legit::display collector2)
                       ;; the owning parent window should still be original window
                       (ok (eq original-window (lem/legit::parent-window)))
                       ;; Old windows should be deleted
                       (ok (lem:deleted-window-p first-peek-window))
                       (ok (lem:deleted-window-p first-source-window))
                       ;; New windows should exist
                       (ok (not (lem:deleted-window-p (lem/legit::peek-window))))
                       (ok (not (lem:deleted-window-p (lem/legit::source-window)))))))
              ;; Cleanup - always run
              (cleanup-legit-windows))))))))

;;; Integration tests with temporary git repository

(deftest legit-status/open-and-close
  (testing "legit-status opens window and cleanup closes it"
    (with-current-buffers ()
      (with-fake-interface ()
        (with-fresh-legit-context
          (with-temp-git-repo
            (unwind-protect
                 (progn
                   ;; Initially closed
                   (ok (not (lem/legit::legit-status-active-p)))
                   ;; Open with legit-status
                   (lem/legit:legit-status)
                   (ok (lem/legit::legit-status-active-p))
                   ;; Native close is synchronous and preserves the parent.
                   (lem/legit:legit-quit)
                   (ok (not (lem/legit::legit-status-active-p))))
              ;; Cleanup - always run
              (cleanup-legit-windows))))))))

(deftest legit-refresh/keeps-window-open
  (testing "legit-refresh keeps the legit window open"
    (with-current-buffers ()
      (with-fake-interface ()
        (with-fresh-legit-context
          (with-temp-git-repo
            (unwind-protect
                 (progn
                   ;; Open legit
                   (lem/legit:legit-status)
                   (ok (lem/legit::legit-status-active-p))
                   (let ((original-parent (lem/legit::parent-window)))
                     ;; Refresh
                     (lem/legit:legit-refresh)
                     ;; Should still be open
                     (ok (lem/legit::legit-status-active-p))
                     ;; Parent window should be preserved
                     (ok (eq original-parent (lem/legit::parent-window)))))
              ;; Cleanup - always run
              (cleanup-legit-windows))))))))

;;; Tests for parse-github-url (lem/legit/utils package)

(deftest display/independent-frames-and-exact-close
  (with-current-buffers ()
    (with-fake-interface ()
      (let* ((left-implementation (implementation))
             (left-parent (current-window))
             (left-status (lem/legit::make-peek-legit-buffer)))
        (insert-string (buffer-point left-status) "left status")
        (lem/legit::display (make-instance 'lem/legit::collector :buffer left-status))
        (let ((left-peek (lem/legit::peek-window))
              (left-context (lem/legit::current-pane-context)))
          (with-fake-interface ()
            (let* ((right-implementation (implementation))
                   (right-parent (current-window))
                   (right-status (lem/legit::make-peek-legit-buffer)))
              (insert-string (buffer-point right-status) "right status")
              (lem/legit::display (make-instance 'lem/legit::collector :buffer right-status))
              (let ((right-peek (lem/legit::peek-window))
                    (right-source (lem/legit::source-window)))
                (ok (not (eq left-status right-status)))
                (ok (string= "left status" (buffer-text left-status)))
                (ok (not (lem-core::window-deleted-p left-peek)))
                (ok (eq right-parent (lem/legit::parent-window)))
                (with-implementation left-implementation
                  (setf (current-buffer) (window-buffer (current-window)))
                  (ok (eq left-peek (current-window)))
                  (lem/legit::display (make-instance 'lem/legit::collector :buffer left-status))
                  (ok (eq left-parent (lem/legit::parent-window)))
                  (lem/legit::%legit-quit)
                  (ok (eq left-parent (current-window)))
                  (ok (null (lem/legit::current-pane-context)))
                  ;; A stale exact close cannot affect a replacement context.
                  (lem/legit::display (make-instance 'lem/legit::collector :buffer left-status))
                  (let ((replacement (lem/legit::peek-window)))
                    (lem/legit::finalize-peek-legit left-context)
                    (ok (eq replacement (lem/legit::peek-window))))
                  (cleanup-legit-windows))
                (with-implementation right-implementation
                  (setf (current-buffer) (window-buffer (current-window)))
                  (ok (eq right-peek (current-window)))
                  (ok (not (lem-core::window-deleted-p right-source)))
                  (ok (string= "right status" (buffer-text right-status)))
                  ;; Direct pane deletion must not recursively free itself.
                  (setf (current-window) right-parent)
                  (delete-window right-peek)
                  (ok (lem-core::window-deleted-p right-peek))
                  (ok (lem-core::window-deleted-p right-source))
                  (ok (null (lem/legit::current-pane-context))))))))))))

(deftest display/detach-disposes-only-private-unseen-buffers
  (with-current-buffers ()
    (with-fake-interface ()
      (let* ((owner (implementation)) (frame (current-frame))
             (shared (make-buffer "shared file source"))
             (status (lem/legit::make-peek-legit-buffer)))
        (lem/legit::display (make-instance 'lem/legit::collector :buffer status))
        (let* ((context (lem/legit::current-pane-context))
               (source (lem/legit::source-window))
               (private (mapcar #'cdr (lem/legit::pane-context-buffers context))))
          (with-current-window source (switch-to-buffer shared))
          (with-fake-interface ()
            (switch-to-buffer shared)
            (let ((survivor (current-window)))
              (with-implementation owner (lem-core::teardown-frame frame))
              (ok (lem/legit::pane-context-closed context))
              (loop repeat 20 do (lem-core::receive-event 0))
              (ok (every #'deleted-buffer-p private))
              (ok (not (deleted-buffer-p shared)))
              (ok (eq survivor (current-window)))
              (ok (eq shared (window-buffer survivor))))))))))

(deftest display/close-retires-dependent-popups
  (with-current-buffers ()
    (with-fake-interface ()
      (let* ((parent (current-window))
             (status (lem/legit::make-peek-legit-buffer)))
        (lem/legit::display (make-instance 'lem/legit::collector :buffer status))
        (let* ((peek (lem/legit::peek-window))
               (source (lem/legit::source-window))
               (popup (display-popup-message "pending Git callback" :timeout nil
                                             :source-window peek :style '(:gravity :follow-cursor)))
               (nested (display-popup-message "details" :timeout nil :source-window popup))
               (source-popup (display-popup-message "source" :timeout nil :source-window source))
               (unrelated (display-popup-message "editor" :timeout nil :source-window parent)))
          (lem/legit::%legit-quit)
          (ok (every #'lem-core::window-deleted-p (list popup nested source-popup)))
          (ok (not (lem-core::window-deleted-p unrelated)))
          (ok (eq parent (current-window)))
          (loop repeat 20 do (lem-core::receive-event 0))
          (ok (deleted-buffer-p status))
          ;; A following-cursor popup must never compute a cursor from the
          ;; deleted pane's now-freed buffer point during an idle redisplay.
          (ok (not (signals (redraw-display :force t))))
          (ok (not (deleted-buffer-p (window-buffer parent)))))))))

(deftest display/refresh-retires-only-owner-popups
  (with-current-buffers ()
    (with-fake-interface ()
      (let* ((left-implementation (implementation))
             (left-status (lem/legit::make-peek-legit-buffer)))
        (lem/legit::display (make-instance 'lem/legit::collector :buffer left-status))
        (let ((left-popup (display-popup-message "left" :timeout nil
                                                :source-window (lem/legit::peek-window))))
          (with-fake-interface ()
            (let ((right-status (lem/legit::make-peek-legit-buffer)))
              (lem/legit::display (make-instance 'lem/legit::collector :buffer right-status))
              (let ((right-popup (display-popup-message "right" :timeout nil
                                                        :source-window (lem/legit::peek-window))))
                (with-implementation left-implementation
                  (setf (current-buffer) (window-buffer (current-window)))
                  (lem/legit::display (make-instance 'lem/legit::collector :buffer left-status))
                  (ok (lem-core::window-deleted-p left-popup))
                  (ok (not (lem-core::window-deleted-p right-popup)))
                  (ok (lem/legit::legit-status-active-p))
                  (cleanup-legit-windows))
                (cleanup-legit-windows)))))))))

(deftest parse-github-url/ssh-with-git-suffix
  (testing "parses SSH URL with .git suffix"
    (multiple-value-bind (owner repo)
        (lem/legit/utils:parse-github-url "git@github.com:lem-project/lem.git")
      (ok (equal owner "lem-project"))
      (ok (equal repo "lem")))))

(deftest parse-github-url/ssh-without-git-suffix
  (testing "parses SSH URL without .git suffix"
    (multiple-value-bind (owner repo)
        (lem/legit/utils:parse-github-url "git@github.com:lem-project/lem")
      (ok (equal owner "lem-project"))
      (ok (equal repo "lem")))))

(deftest parse-github-url/https-with-git-suffix
  (testing "parses HTTPS URL with .git suffix"
    (multiple-value-bind (owner repo)
        (lem/legit/utils:parse-github-url "https://github.com/lem-project/lem.git")
      (ok (equal owner "lem-project"))
      (ok (equal repo "lem")))))

(deftest parse-github-url/https-without-git-suffix
  (testing "parses HTTPS URL without .git suffix"
    (multiple-value-bind (owner repo)
        (lem/legit/utils:parse-github-url "https://github.com/lem-project/lem")
      (ok (equal owner "lem-project"))
      (ok (equal repo "lem")))))

(deftest parse-github-url/http-url
  (testing "parses HTTP URL"
    (multiple-value-bind (owner repo)
        (lem/legit/utils:parse-github-url "http://github.com/owner/repo")
      (ok (equal owner "owner"))
      (ok (equal repo "repo")))))

(deftest parse-github-url/with-whitespace
  (testing "trims whitespace from URL"
    (multiple-value-bind (owner repo)
        (lem/legit/utils:parse-github-url "  git@github.com:owner/repo.git  ")
      (ok (equal owner "owner"))
      (ok (equal repo "repo")))))

(deftest parse-github-url/non-github-url
  (testing "returns nil for non-GitHub URL"
    (ok (null (lem/legit/utils:parse-github-url "git@gitlab.com:owner/repo.git")))
    (ok (null (lem/legit/utils:parse-github-url "https://bitbucket.org/owner/repo")))))

(deftest parse-github-url/invalid-url
  (testing "returns nil for invalid URL"
    (ok (null (lem/legit/utils:parse-github-url "not-a-url")))
    (ok (null (lem/legit/utils:parse-github-url "")))))

;;; Tests for build-github-url (lem/legit/utils package)

(deftest build-github-url/basic
  (testing "builds basic URL without line number"
    (ok (equal (lem/legit/utils:build-github-url "owner" "repo" "main" "src/file.lisp")
               "https://github.com/owner/repo/blob/main/src/file.lisp"))))

(deftest build-github-url/with-line-number
  (testing "builds URL with single line number"
    (ok (equal (lem/legit/utils:build-github-url "owner" "repo" "main" "src/file.lisp"
                                                  :start-line 42)
               "https://github.com/owner/repo/blob/main/src/file.lisp#L42"))))

(deftest build-github-url/with-line-range
  (testing "builds URL with line range"
    (ok (equal (lem/legit/utils:build-github-url "owner" "repo" "main" "src/file.lisp"
                                                  :start-line 10 :end-line 20)
               "https://github.com/owner/repo/blob/main/src/file.lisp#L10-L20"))))

(deftest build-github-url/same-start-end-line
  (testing "builds URL with single line when start equals end"
    (ok (equal (lem/legit/utils:build-github-url "owner" "repo" "feature/test" "README.md"
                                                  :start-line 5 :end-line 5)
               "https://github.com/owner/repo/blob/feature/test/README.md#L5"))))

(deftest build-github-url/with-branch-containing-slash
  (testing "builds URL with branch containing slash"
    (ok (equal (lem/legit/utils:build-github-url "owner" "repo" "feature/new-feature" "file.lisp"
                                                  :start-line 1)
               "https://github.com/owner/repo/blob/feature/new-feature/file.lisp#L1"))))
