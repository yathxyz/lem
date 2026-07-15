(in-package :lem-yath)

(define-command claude-bridge-test-mutate-source () ()
  "Mutate the test source without changing the focused review buffer."
  (let ((buffer (or (get-buffer "source.txt")
                    (editor-error "Claude bridge test source is missing"))))
    (insert-string (buffer-start-point buffer) "external ")))

(dolist (keymap (list *global-keymap*
                      lem-vi-mode:*normal-keymap*
                      lem-vi-mode:*insert-keymap*
                      lem-vi-mode:*visual-keymap*))
  (define-key keymap "F9" 'claude-bridge-test-mutate-source))
