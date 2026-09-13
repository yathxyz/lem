# Native daily tools

The configured daemon owns ordinary project buffers, interactive terminal
processes, and its self-connected Common Lisp REPL across client connections.
Use `M-x lem-yath-project-find-file`, `M-x vterm`, and `M-x start-lisp-repl`.
`C-z` selects the configured Emacs input state in the REPL. A terminal starts in
raw Insert state; its normal terminal escape controls remain available.

REPL output and new prompts advance only windows that were already at the end
of the buffer. A client browsing earlier output keeps its own position. Output
does not select another frame or replace its buffer. This matters when the
evaluation callback runs while a different client is active: the next expression
must still enter the originating REPL's input area.

`extensions/lem-yath/scripts/native-daily-tools-test.py` drives two actual terminal
clients through PTYs against configured `LEM_BIN` and `LEMCLIENT_BIN`. It uses a
temporary Git project with spaces and a literal semicolon in its directory name,
private daemon state, and a Bash process with startup files disabled. `HOME` is
unchanged. Project selection, terminal launch/input, REPL launch/input, and shell
exit use native keys. Administrative eval selects initial fixture views and
observes state; it does not execute the tested shell command or REPL expressions.

The scenario checks project selection without changing the peer view, literal
shell working directory, REPL evaluation and prompt position, subsequent input
after client loss, last-client detach/reconnect, surviving Lisp state and shell
process, explicit shell exit, and unchanged fixture files. Run it through
`nix run .#native-daily-tools-test` from `extensions/lem-yath`, or use
`checks.x86_64-linux.native-daily-tools` there.

Client detachment preserves live processes; daemon failure has a different
contract. [Text recovery](daemon-recovery.md) restores checkpointed text into
separate unsaved buffers. [Managed jobs](managed-jobs.md) retain bounded records
and reconcile interrupted work. Neither reconstructs arbitrary shell or Lisp
execution stacks after process death. Start a new shell or REPL deliberately.
