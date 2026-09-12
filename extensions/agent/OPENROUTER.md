# Native OpenRouter transport

`lem-agent/openrouter` supplies a single provider round for `lem-agent`. It has no
editor dependency and owns no tool dispatch, permission decision, session history,
or agent loop. Those remain in the Lisp session core.

```lisp
(asdf:load-system "lem-agent/openrouter")
(lem-agent:register-provider
 agent-manager "openrouter"
 (lem-agent/openrouter:make-provider
  :job-manager job-manager
  :curl-program pinned-curl-path
  :ca-bundle pinned-ca-bundle-path
  :api-key-provider openrouter-credential-function
  :timeout 120
  :max-tokens 4096))
```

Construct the adapter on a startup worker: it validates the existing job manager
and resolves the absolute executable and optional CA paths. Pin curl and the CA
bundle from the prepared Nix closure. The existing packaged Lisp guardian/SBCL
configuration must be available to the supplied job manager. No second process
manager is created. Register this provider before creating or resuming sessions;
the model comes from each session's explicitly selected `:model`.

The HTTP process starts in `/`, so a missing or renamed project directory does
not prevent provider requests needed to discuss and recover that problem. The
session and operation roots remain unchanged; file and process tools still apply
their own project-directory checks.

The credential function runs on the provider worker once per round. Its default
reads only `OPENROUTER_API_KEY`; it never reads `OPENAI_API_KEY` as a fallback. A
missing key or a key containing whitespace/control characters fails before any
job is submitted. Loading or constructing the adapter does not read credentials.

The remote endpoint is fixed to `https://openrouter.ai/api/v1/chat/completions`.
TLS verification remains enabled. Redirects are not followed. For automated tests,
`:test-endpoint` accepts only an explicitly supplied `http://127.0.0.1:PORT/PATH`
with a restricted path; it cannot select another remote credential destination.

Each request is a managed argv job running pinned curl with `--disable` first,
disabling user curl configuration. URL, authorization header, CA path and JSON body
are quoted into `--config -` input. They never become argv or journal launch data.
The child receives only `LC_ALL=C.UTF-8`, so inherited credential, proxy and curl
configuration variables cannot alter the request. Request transport therefore
does not currently support environment-configured proxies. Curl config quoting
and option behavior follow the [official curl manual](https://curl.se/docs/manpage.html#--config).

The job retains only one output byte per channel; the session core owns the actual
transcript. Diagnostics report safe transport categories and numeric status/exit
codes without echoing provider error bodies, credentials, curl stderr or request
contents. `transport-error-kind` and `transport-error-status` expose these fields
to a caller catching `transport-error`. The current core's generic provider-error
record includes the condition type; a later UI can deliberately expose these safe
fields without printing arbitrary adapter conditions.

## Protocol and limits

Requests encode core tool schemas as function definitions, assistant calls with
JSON-string arguments, and tool results as tool messages associated with their
call IDs. The adapter returns completely assembled JSON argument objects; the
core validates them and decides whether a tool may run. This follows OpenRouter's
[tool-calling contract](https://openrouter.ai/docs/guides/features/tool-calling).

The parser consumes bounded byte chunks before allocating a full line. It validates
HTTP status and SSE content type, then handles UTF-8 across chunk boundaries, LF,
CRLF and CR lines, comments, optional BOM, and multiline `data:` events. Interleaved
tool-call fragments are assembled by bounded indices. A complete response requires
`stop` or `tool_calls`, consistent complete tool calls, `[DONE]`, and an exited
managed job with exit code zero and no journal error. Curl success alone is
insufficient. Missing terminators, partial arguments, unsupported finish reasons,
malformed data, non-2xx status and mid-stream errors fail explicitly.

OpenRouter may send an accounting chunk after the terminal chunk, repeating its
finish reason with an empty delta. The parser permits that documented usage frame
and rejects new content or tool fragments after completion. See
[OpenRouter streaming](https://openrouter.ai/docs/api_reference/streaming).
An HTTP 200 can carry a provider error inside SSE; these are failures according to
[OpenRouter error handling](https://openrouter.ai/docs/api/reference/errors-and-debugging).

| Boundary | Maximum |
| --- | ---: |
| HTTP headers | 16 KiB |
| One line or assembled SSE event | 64 KiB |
| Entire HTTP response | 1 MiB |
| JSON request body | 480 KiB |
| Escaped private curl input | 1 MiB |
| Text result | 65,536 characters |
| One tool's argument fragments | 16,384 characters |
| Tool calls per round | 16 |
| JSON nesting | 16 levels |

These transport limits supplement the core's smaller per-session limits. A budget
failure cancels the managed request; no partial tool call reaches dispatch. There
are no automatic retries or provider fallback loops in this adapter. Cancellation
is registered immediately after submission; the core's late-registration behavior
covers an interrupt racing with job creation. Stream callbacks check the operation
generation before emitting text. Killing the local request closes its connection;
the adapter does not claim to reverse a remote effect or guarantee remote billing
stops, since cancellation support depends on the upstream provider.

## Verification and integration

Run `scripts/run-tests.sh lem-agent/openrouter-tests` with `LEM_TEST_CURL` pointing
to a real curl binary and `LEM_TOOLKIT_SBCL` pointing to the stock SBCL worker.
The suite uses only a local Common Lisp HTTP fixture and explicit fake credentials.
It covers bytewise UTF-8, multiline SSE, multiple fragmented calls, the native
tool/result/provider round, malformed and bounded input, non-2xx and mid-stream
errors, timeout, cancellation, nonzero curl exit after a valid protocol finish,
credential transport and endpoint restrictions.
It also verifies provider/tool rounds remain available with missing or renamed
project directories while tool contexts preserve the original session root.

This optional system is ready for the prepared profile to load and register.
Daemon lifecycle wiring, credential selection UI, concrete tools, transcript views
and live-provider acceptance remain separate integration work. Local fixture
success does not establish live authentication or support for a particular model.
