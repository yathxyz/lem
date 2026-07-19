#!/usr/bin/env bash
# Real-TUI acceptance for the configured Notmuch read/compose/send/fetch workflow.
set -euo pipefail

# Lem/tmux key decoding requires a UTF-8 locale in the Nix sandbox.
export LC_ALL=C.UTF-8

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/tui-driver.sh
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-notmuch-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-notmuch.XXXXXX")"
session="lem-yath-notmuch-$id"

cleanup() {
  if [[ -n ${smtp_server_pid:-} ]]; then
    kill "$smtp_server_pid" 2>/dev/null || true
    wait "$smtp_server_pid" 2>/dev/null || true
  fi
  lem_stop "$session" || true
  rm -rf -- "$root"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_NOTMUCH_REPORT="$root/report"
export LEM_YATH_NOTMUCH_LOG="$root/notmuch-argv.jsonl"
export LEM_YATH_NOTMUCH_STATE="$root/state.json"
export LEM_YATH_MBSYNC_LOG="$root/mbsync-argv"
export LEM_YATH_NOTMUCH_OPEN_LOG="$root/xdg-open.jsonl"
export LEM_YATH_NOTMUCH_INSERT_LOG="$root/notmuch-insert.jsonl"
export LEM_YATH_SMTP_FAKE_LOG="$root/smtp-submit.jsonl"
export LEM_YATH_NOTMUCH_FAIL_INSERT_ONCE="$root/fail-insert-once"
export LEM_YATH_NOTMUCH_PDF="$root/notmuch attachment;safe.pdf"
export LEM_YATH_NOTMUCH_COMPOSE_ATTACHMENT="$root/compose attachment safe.bin"
smtp_attachment="$root/"'smtp attachment;safe $(touch PWNED).bin'
fakebin="$root/fake bin;safe"
export LEM_YATH_NOTMUCH_FAKE_BIN="$fakebin"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$fakebin"
real_notmuch=$(command -v notmuch)
: >"$LEM_YATH_NOTMUCH_REPORT"
: >"$LEM_YATH_NOTMUCH_LOG"
: >"$LEM_YATH_MBSYNC_LOG"
: >"$LEM_YATH_NOTMUCH_OPEN_LOG"
: >"$LEM_YATH_NOTMUCH_INSERT_LOG"
: >"$LEM_YATH_SMTP_FAKE_LOG"
printf 'attachment bytes\000with binary\377tail\n' \
  >"$LEM_YATH_NOTMUCH_COMPOSE_ATTACHMENT"
cp "$LEM_YATH_NOTMUCH_COMPOSE_ATTACHMENT" "$smtp_attachment"
printf '%s\n' '{"searches":0,"news":0,"inserts":0,"tags":{"alpha@example.invalid":["inbox","unread"],"payment+safe;touch PWNED@example.invalid":["inbox","unread"],"reply/second?value@example.invalid":["inbox","unread"]}}' >"$LEM_YATH_NOTMUCH_STATE"
cp "$here/scripts/fake-notmuch.py" "$fakebin/notmuch"
cp "$here/scripts/fake-mbsync.sh" "$fakebin/mbsync"
cp "$here/scripts/fake-notmuch-xdg-open.py" "$fakebin/xdg-open"
cp "$here/scripts/fake-smtp-submit.py" "$fakebin/lem-yath-smtp-submit"
python=$(command -v python3)
shell=$(command -v bash)
sed -i "1c#!$python" "$fakebin/notmuch" "$fakebin/xdg-open" "$fakebin/lem-yath-smtp-submit"
sed -i "1c#!$shell" "$fakebin/mbsync"
chmod +x "$fakebin/notmuch" "$fakebin/mbsync" "$fakebin/xdg-open" "$fakebin/lem-yath-smtp-submit"
export PATH="$fakebin:$PATH"

real_smtp_program=${LEM_YATH_SMTP_SUBMIT_PROGRAM:?configured wrapper did not expose the SMTP helper}
export LEM_YATH_SMTP_SUBMIT_PROGRAM="$fakebin/lem-yath-smtp-submit"

source_file="$root/source file;safe.txt"
printf 'Notmuch source remains exact\n' >"$source_file"
python3 - "$LEM_YATH_NOTMUCH_PDF" <<'PY'
import sys

path = sys.argv[1]
stream = b"BT /F1 18 Tf 72 720 Td (Notmuch Attachment Page) Tj ET\n"
objects = [
    b"<< /Type /Catalog /Pages 2 0 R >>",
    b"<< /Type /Pages /Kids [3 0 R] /Count 1 >>",
    b"<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] "
    b"/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
    b"<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
    b"<< /Length %d >>\nstream\n" % len(stream) + stream + b"endstream",
]
pdf = bytearray(b"%PDF-1.4\n%\xe2\xe3\xcf\xd3\n")
offsets = [0]
for number, body in enumerate(objects, 1):
    offsets.append(len(pdf))
    pdf.extend(f"{number} 0 obj\n".encode())
    pdf.extend(body)
    pdf.extend(b"\nendobj\n")
xref = len(pdf)
pdf.extend(f"xref\n0 {len(objects) + 1}\n".encode())
pdf.extend(b"0000000000 65535 f \n")
for offset in offsets[1:]:
    pdf.extend(f"{offset:010d} 00000 n \n".encode())
pdf.extend(
    f"trailer\n<< /Size {len(objects) + 1} /Root 1 0 R >>\n"
    f"startxref\n{xref}\n%%EOF\n".encode()
)
with open(path, "wb") as output:
    output.write(pdf)
PY

failed=0
pass() { printf 'PASS  %-24s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-24s %s\n' "$1" "$2"
  lem_capture "$session" 2>/dev/null || true
  sed -n '1,120p' "$LEM_YATH_NOTMUCH_REPORT" 2>/dev/null || true
  sed -n '1,120p' "$LEM_YATH_NOTMUCH_LOG" 2>/dev/null || true
  sed -n '1,40p' "$LEM_YATH_NOTMUCH_STATE" 2>/dev/null || true
}

# Keep the fake backend strict for editor argv/state coverage, but first prove
# the pinned real Notmuch accepts the completion query grammar and emits the
# mailbox form consumed by the provider.
real_address_root="$root/real-address"
mkdir -p "$real_address_root/mail/cur" "$real_address_root/mail/new" \
  "$real_address_root/mail/tmp"
cat >"$real_address_root/config" <<EOF
[database]
path=$real_address_root/mail
[user]
name=Yanni
primary_email=yanni@example.invalid
other_email=alias@example.invalid
[new]
tags=unread;inbox;
ignore=
[search]
exclude_tags=deleted;spam;
[maildir]
synchronize_flags=true
EOF
cat >"$real_address_root/mail/new/message" <<'EOF'
From: Yanni <yanni@example.invalid>
To: Alice Real <alice.real@example.invalid>
Date: Wed, 15 Jul 2026 20:00:00 +0100
Message-ID: <real-address@example.invalid>
Subject: Real address fixture

Address completion fixture.
EOF
real_address_query='(from:"yanni@example.invalid" or from:"alias@example.invalid") and (to:ali*)'
if NOTMUCH_CONFIG="$real_address_root/config" "$real_notmuch" new \
     >"$real_address_root/new.out" 2>"$real_address_root/new.err" &&
   NOTMUCH_CONFIG="$real_address_root/config" "$real_notmuch" address \
     --format=text --output=recipients --deduplicate=address \
     "$real_address_query" >"$real_address_root/address.out" \
     2>"$real_address_root/address.err" &&
   grep -Fxq 'Alice Real <alice.real@example.invalid>' \
     "$real_address_root/address.out"; then
  pass address-real-cli 'pinned Notmuch accepted the safe wildcard query and returned a mailbox candidate'
else
  sed -n '1,40p' "$real_address_root/new.out" \
    "$real_address_root/new.err" "$real_address_root/address.out" \
    "$real_address_root/address.err" >&2
  fail address-real-cli 'real Notmuch query grammar or address output diverged'
fi

report_count() { grep -c "^$1" "$LEM_YATH_NOTMUCH_REPORT" 2>/dev/null || true; }
wait_report() {
  local prefix=$1 before=$2 index=0
  while ((index < 80)); do
    if (( $(report_count "$prefix") > before )); then return 0; fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}
latest() { grep "^$1" "$LEM_YATH_NOTMUCH_REPORT" | tail -n 1; }
invoke_report() {
  local before
  before=$(report_count STATE)
  lem_keys "$session" F1
  wait_report STATE "$before"
}
wait_log_count() {
  local path=$1 expected=$2 index=0
  while ((index < 80)); do
    if [ "$(wc -l <"$path")" -ge "$expected" ]; then return 0; fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}
notmuch_tag_prompt() {
  local key=$1 tag=$2
  tmux_cmd send-keys -t "$session" -l -- "$key"
  sleep 0.3
  tmux_cmd send-keys -t "$session" -l -- "$tag"
  lem_keys "$session" Enter
}

# Exercise the packaged submission helper itself against a one-shot local
# STARTTLS server before the TUI uses a deterministic fake submitter.  This
# proves authinfo lookup, AUTH, envelope/Bcc handling, and normalized FCC bytes
# without contacting the owner's Bridge or the network.
smtp_tls="$root/smtp-tls"
mkdir -p "$smtp_tls"
openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj '/CN=localhost' \
  -keyout "$smtp_tls/key.pem" -out "$smtp_tls/cert.pem" >/dev/null 2>&1
export LEM_YATH_SMTP_TEST_PORT_FILE="$smtp_tls/port"
export LEM_YATH_SMTP_TEST_CAPTURE="$smtp_tls/capture.json"
export LEM_YATH_SMTP_TEST_CERT="$smtp_tls/cert.pem"
export LEM_YATH_SMTP_TEST_KEY="$smtp_tls/key.pem"
export LEM_YATH_SMTP_TEST_USERNAME='bridge user'
export LEM_YATH_SMTP_TEST_PASSWORD='bridge;password'
python3 "$here/scripts/fake-smtp-server.py" >"$smtp_tls/server.log" 2>&1 &
smtp_server_pid=$!
for _ in $(seq 1 80); do
  [[ -s $LEM_YATH_SMTP_TEST_PORT_FILE ]] && break
  sleep 0.1
done
smtp_port=$(cat "$LEM_YATH_SMTP_TEST_PORT_FILE" 2>/dev/null || true)
printf '%s\n' \
  'machine unrelated.invalid login ignored password ignored' >"$HOME/.authinfo"
printf '%s\n' \
  'machine 127.0.0.1' \
  "port $smtp_port" \
  'login "bridge user"' \
  'password "bridge;password"' >"$HOME/.netrc"
chmod 600 "$HOME/.authinfo" "$HOME/.netrc"
smtp_input="$smtp_tls/input.eml"
smtp_output="$smtp_tls/output.eml"
printf '%s\n' \
  'From: Yanni <yanni@example.invalid>' \
  'To: Alice <alice@example.invalid>' \
  'Bcc: Audit <audit+safe-touch-PWNED@example.invalid>' \
  'Subject: SMTP helper; $(touch PWNED)' \
  '' \
  'Literal body; `touch PWNED`.' \
  "<#part type=\"application/octet-stream\" filename=\"$smtp_attachment\" disposition=attachment>" \
  >"$smtp_input"
smtp_helper_ok=1
LEM_YATH_SMTP_SERVER=127.0.0.1 \
LEM_YATH_SMTP_PORT="$smtp_port" \
  "$real_smtp_program" <"$smtp_input" >"$smtp_output" 2>"$smtp_tls/helper.err" || smtp_helper_ok=0
wait "$smtp_server_pid" || smtp_helper_ok=0
smtp_server_pid=
if ((smtp_helper_ok)) && python3 - "$smtp_output" "$LEM_YATH_SMTP_TEST_CAPTURE" \
     "$smtp_attachment" <<'PY'
import json, sys
from pathlib import Path
from email import policy
from email.parser import BytesParser

output = open(sys.argv[1], "rb").read()
capture = json.load(open(sys.argv[2]))
attachment_path = Path(sys.argv[3])
message = BytesParser(policy=policy.default).parsebytes(output)
assert capture["tls"] is True
assert capture["authenticated"] is True
assert capture["mail_from"] == "<yanni@example.invalid>"
assert capture["recipients"] == [
    "<alice@example.invalid>",
    "<audit+safe-touch-PWNED@example.invalid>",
]
assert message["Bcc"] is None
assert message["Date"] and message["Message-ID"]
assert message.get_content_type() == "multipart/mixed"
body = message.get_body(preferencelist=("plain",))
assert body is not None and "Literal body; `touch PWNED`." in body.get_content()
assert "<#part" not in body.get_content()
attachments = list(message.iter_attachments())
assert len(attachments) == 1
assert attachments[0].get_content_type() == "application/octet-stream"
assert attachments[0].get_filename() == attachment_path.name
assert attachments[0].get_payload(decode=True) == attachment_path.read_bytes()
assert "Bcc:" not in capture["message"]
assert capture["message"].encode() == output
PY
then
  pass smtp-helper 'packaged STARTTLS submission built MIME, authenticated privately, hid Bcc, and returned exact FCC bytes'
else
  fail smtp-helper 'MIME, STARTTLS, authinfo, envelope recipients, Bcc stripping, or normalized output diverged'
fi
invalid_smtp="$smtp_tls/invalid.eml"
printf '%s\n' \
  'From: Yanni <yanni@example.invalid>' \
  'To: Alice <alice@example.invalid>' \
  'Bcc: Audit <audit+safe;touch-PWNED@example.invalid>' \
  'Subject: invalid recipient' '' 'body' >"$invalid_smtp"
if ! LEM_YATH_SMTP_SERVER=127.0.0.1 \
     LEM_YATH_SMTP_PORT="$smtp_port" \
       "$real_smtp_program" <"$invalid_smtp" >"$smtp_tls/invalid.out" \
       2>"$smtp_tls/invalid.err" &&
   grep -Fq 'Bcc contains a malformed address' "$smtp_tls/invalid.err"; then
  pass smtp-address-refusal 'malformed recipient syntax failed before any SMTP connection'
else
  fail smtp-address-refusal 'the helper accepted or misclassified a malformed recipient address'
fi

attachment_refusal_ok=1
unsafe_link="$smtp_tls/unsafe-link.bin"
oversized_attachment="$smtp_tls/oversized.bin"
ln -s "$smtp_attachment" "$unsafe_link"
truncate -s 7340033 "$oversized_attachment"
for refusal in symlink oversized malformed; do
  refusal_input="$smtp_tls/$refusal.eml"
  case "$refusal" in
    symlink)
      marker="<#part type=\"application/octet-stream\" filename=\"$unsafe_link\" disposition=attachment>"
      expected='attachment is not a regular file'
      ;;
    oversized)
      marker="<#part type=\"application/octet-stream\" filename=\"$oversized_attachment\" disposition=attachment>"
      expected='attachment exceeds the 7 MiB composition limit'
      ;;
    malformed)
      marker="<#part filename=\"$smtp_attachment\" disposition=attachment>"
      expected='attachment marker is malformed'
      ;;
  esac
  printf '%s\n' \
    'From: Yanni <yanni@example.invalid>' \
    'To: Alice <alice@example.invalid>' \
    'Subject: attachment refusal' '' 'body' "$marker" >"$refusal_input"
  if LEM_YATH_SMTP_SERVER=127.0.0.1 LEM_YATH_SMTP_PORT="$smtp_port" \
       "$real_smtp_program" <"$refusal_input" \
       >"$smtp_tls/$refusal.out" 2>"$smtp_tls/$refusal.err" ||
     ! grep -Fq "$expected" "$smtp_tls/$refusal.err"; then
    attachment_refusal_ok=0
  fi
done
if ((attachment_refusal_ok)); then
  pass smtp-attachment-refusal 'malformed, symlink, and oversized attachments failed before SMTP'
else
  fail smtp-attachment-refusal 'an unsafe attachment reached SMTP or produced the wrong refusal'
fi

fixture="$(lem-yath_lisp_string "$here/scripts/notmuch-fixture.lisp")"
lem_start "$session" "$source_file" --eval "(load #P$fixture)"

if wait_report READY 0 && lem_wait_for "$session" NORMAL 60 >/dev/null &&
   grep -Fqx -- "EXEC notmuch=$fakebin/notmuch xdg-open=$fakebin/xdg-open" \
     "$LEM_YATH_NOTMUCH_REPORT"; then
  pass boot 'configured Lem loaded the fixture and resolved the fake notmuch'
else
  fail boot 'configured Lem did not load the fixture with the fake notmuch'
fi

lem_keys "$session" F3
if lem_wait_for "$session" 'First thread' 20 >/dev/null && invoke_report &&
   [[ $(latest STATE) == 'STATE mode=list query=yes row=alpha thread=none message=none read-only=yes keys=yes body=no html-hidden=no source-live=yes source-exact=yes' ]]; then
  pass search 'the query opened and focused a read-only newest-first list'
else
  fail search 'search rendering, focus, row identity, or keymaps diverged'
fi

lem_keys "$session" Enter
if lem_wait_for "$session" 'First plain body' 20 >/dev/null; then
  lem_keys "$session" A
fi
if lem_wait_for "$session" 'Primary plain body' 20 >/dev/null && invoke_report &&
   [[ $(latest STATE) == 'STATE mode=show query=no row=none thread=beta message=payment+safe;touch PWNED@example.invalid read-only=yes keys=yes body=yes html-hidden=yes source-live=yes source-exact=yes' ]]; then
  pass read 'Return opened a bare-ID thread and A archived it before opening the next thread'
else
  fail read 'bare-ID show query, thread archive navigation, nested parsing, or focus failed'
fi

lem_keys "$session" /
sleep 0.3
tmux_cmd send-keys -t "$session" -l -- 'quarterly report;safe.pdf'
lem_keys "$session" Enter Enter
if lem_wait_for "$session" 'Notmuch Attachment Page' 20 >/dev/null; then
  before_pdf=$(report_count PDF)
  lem_keys "$session" F2
else
  before_pdf=-1
fi
if [ "$before_pdf" -ge 0 ] && wait_report PDF "$before_pdf" &&
   [[ $(latest PDF) == 'PDF mode=yes page=1 temporary=yes file-private=yes dir-private=yes source=yes' ]]; then
  pass pdf-attachment 'Return extracted and previewed the selected PDF in a private ephemeral reader'
else
  fail pdf-attachment 'attachment discovery, raw extraction, PDF preview, or private modes diverged'
fi

before_clean=$(report_count CLEAN)
lem_keys "$session" q
if lem_wait_for "$session" 'Primary plain body' 20 >/dev/null; then
  lem_keys "$session" F8
fi
if wait_report CLEAN "$before_clean" &&
   [[ $(latest CLEAN) == 'CLEAN buffer=yes file=yes directory=yes source=yes' ]]; then
  pass pdf-cleanup 'q killed the ephemeral reader and removed its owned file and directory'
else
  fail pdf-cleanup 'the ephemeral attachment buffer or private files survived q'
fi

before_refusal=$(report_count REFUSAL)
lem_keys "$session" F9
if wait_report REFUSAL "$before_refusal" &&
   [[ $(latest REFUSAL) == 'REFUSAL output=yes nonpdf=yes timeout=yes invalid=yes clean=yes source=yes' ]]; then
  pass pdf-refusal 'oversize, non-PDF, timeout, and invalid-ID extraction failed cleanly'
else
  fail pdf-refusal 'an attachment extraction refusal leaked or disturbed the mail view'
fi

before_compose=$(report_count COMPOSE)
lem_keys "$session" C
if lem_wait_for "$session" 'Subject:' 20 >/dev/null; then
  lem_keys "$session" F6
fi
new_compose_ok=0
if wait_report COMPOSE "$before_compose" &&
   [[ $(latest COMPOSE) == 'COMPOSE mode=yes from=yes to=no subject=no quote=no all=no reply=no sent=no fcc=no read-only=no keys=yes active-send=yes source=yes' ]]; then
  new_compose_ok=1
fi

address_ok=0
attachment_ok=0
if ((new_compose_ok)); then
  lem_keys "$session" A
  tmux_cmd send-keys -t "$session" -l -- 'ali'
  if lem_wait_for "$session" 'Alice Example <alice@example.invalid>' 20 >/dev/null; then
    tmux_cmd send-keys -t "$session" -l -- 'c'
    sleep 0.4
    lem_keys "$session" C-n Enter
    sleep 0.5
    tmux_cmd send-keys -t "$session" -l -- ', tea'
  fi
  if lem_wait_for "$session" 'Team Address <team@example.invalid>' 20 >/dev/null; then
    lem_keys "$session" C-n Enter
    sleep 0.5
    before_err_log=$(wc -l <"$LEM_YATH_NOTMUCH_LOG")
    tmux_cmd send-keys -t "$session" -l -- ', err'
    wait_log_count "$LEM_YATH_NOTMUCH_LOG" "$((before_err_log + 1))" || true
  fi
  sleep 0.5
  address_calls=$(python3 - "$LEM_YATH_NOTMUCH_LOG" <<'PY'
import json, sys
print(sum(1 for line in open(sys.argv[1]) if json.loads(line)[:1] == ["address"]))
PY
)
  lem_keys "$session" Escape
  lem_wait_for "$session" 'NORMAL' 5 >/dev/null || true
  lem_keys "$session" j A
  tmux_cmd send-keys -t "$session" -l -- 'ali'
  sleep 0.8
  lem_keys "$session" Escape
  lem_wait_for "$session" 'NORMAL' 5 >/dev/null || true
  lem_keys "$session" G o
  tmux_cmd send-keys -t "$session" -l -- 'ali'
  sleep 0.8
  lem_keys "$session" Escape
  lem_wait_for "$session" 'NORMAL' 5 >/dev/null || true
  after_nonheader_calls=$(python3 - "$LEM_YATH_NOTMUCH_LOG" <<'PY'
import json, sys
print(sum(1 for line in open(sys.argv[1]) if json.loads(line)[:1] == ["address"]))
PY
)
  before_address=$(report_count ADDRESS)
  lem_keys "$session" F7
  if wait_report ADDRESS "$before_address" &&
     [[ $(latest ADDRESS) == 'ADDRESS mode=yes to=yes subject=yes body=yes spec=yes cache=yes failure=yes idle=yes matrix=yes contexts=yes,yes,yes,yes,yes source=yes' ]] &&
     [[ $after_nonheader_calls -eq $address_calls ]] &&
     python3 - "$LEM_YATH_NOTMUCH_LOG" <<'PY'
import json, sys

calls = [json.loads(line) for line in open(sys.argv[1])]
addresses = [call for call in calls if call[:1] == ["address"]]
base = '(from:"yanni@example.invalid" or from:"alias@example.invalid") and (to:{}*)'
expected = [
    ["address", "--format=text", "--output=recipients", "--deduplicate=address", base.format("ali")],
    ["address", "--format=text", "--output=recipients", "--deduplicate=address", base.format("tea")],
    ["address", "--format=text", "--output=recipients", "--deduplicate=address", base.format("err")],
]
assert addresses == expected, addresses
PY
  then
    address_ok=1
  fi

  before_attachment=$(report_count ATTACH)
  lem_keys "$session" C-c C-a
  if lem_wait_for "$session" 'Attach file:' 10 >/dev/null; then
    tmux_cmd send-keys -t "$session" -l -- \
      "$LEM_YATH_NOTMUCH_COMPOSE_ATTACHMENT"
    lem_keys "$session" Enter
  fi
  if lem_wait_for "$session" 'Attached compose attachment safe' 15 >/dev/null; then
    lem_keys "$session" F10
  fi
  if wait_report ATTACH "$before_attachment" &&
     [[ $(latest ATTACH) == 'ATTACH mode=yes marker=yes regular=yes bounded=yes count=1 keys=yes active=yes source=yes' ]]; then
    attachment_ok=1
  fi
fi

lem_keys "$session" C-c C-k
if lem_wait_for "$session" 'Discard this unsent mail composition?' 3 >/dev/null; then
  tmux_cmd send-keys -t "$session" -l -- 'y'
fi
if ((new_compose_ok)) && lem_wait_for "$session" 'Primary plain body' 20 >/dev/null; then
  pass compose-new 'C opened the configured Notmuch identity in an editable mail buffer and C-c C-k returned'
else
  fail compose-new 'new-mail identity, compose mode, or cancellation diverged'
fi
if ((address_ok)); then
  pass address-completion 'recipient headers completed asynchronously with exact cached argv, token bounds, and safe failure'
else
  fail address-completion 'header scope, popup acceptance, cache, failure recovery, or direct address argv diverged'
fi
if ((attachment_ok)); then
  pass compose-attachment 'C-c C-a inserted one exact bounded MML attachment marker'
else
  fail compose-attachment 'file prompt, MML marker, size guard, or active C-c C-a binding diverged'
fi

before_compose=$(report_count COMPOSE)
lem_keys "$session" c c
if lem_wait_for "$session" 'Subject:' 20 >/dev/null; then
  lem_keys "$session" F6
fi
compose_alias_ok=0
if wait_report COMPOSE "$before_compose" &&
   [[ $(latest COMPOSE) == 'COMPOSE mode=yes from=yes to=no subject=no quote=no all=no reply=no sent=no fcc=no read-only=no keys=yes active-send=yes source=yes' ]]; then
  compose_alias_ok=1
fi
lem_keys "$session" C-c C-k
if ((compose_alias_ok)) && lem_wait_for "$session" 'Primary plain body' 20 >/dev/null; then
  pass compose-alias 'cc opened the same configured new-mail composition and canceled cleanly'
else
  fail compose-alias 'the Evil-collection cc alias did not reach new-mail composition'
fi

before_compose=$(report_count COMPOSE)
lem_keys "$session" c R
if lem_wait_for "$session" 'Cc: Team' 20 >/dev/null; then
  lem_keys "$session" F6
fi
reply_all_ok=0
if wait_report COMPOSE "$before_compose" &&
   [[ $(latest COMPOSE) == 'COMPOSE mode=yes from=yes to=yes subject=yes quote=yes all=yes reply=yes sent=no fcc=no read-only=no keys=yes active-send=yes source=yes' ]]; then
  reply_all_ok=1
fi
lem_keys "$session" C-c C-k
if ((reply_all_ok)) && lem_wait_for "$session" 'Primary plain body' 20 >/dev/null &&
   python3 - "$LEM_YATH_NOTMUCH_LOG" <<'PY'
import json, sys

calls = [json.loads(line) for line in open(sys.argv[1])]
query = 'id:"payment+safe;touch PWNED@example.invalid"'
assert ["reply", "--format=default", "--reply-to=all", query] in calls
PY
then
  pass reply-all 'cR used the exact selected Message-ID and Notmuch all-recipient template'
else
  fail reply-all 'the Evil-collection cR route, Cc template, or exact reply query diverged'
fi

before_compose=$(report_count COMPOSE)
lem_keys "$session" c r
if lem_wait_for "$session" '> Primary plain body.' 20 >/dev/null; then
  lem_keys "$session" F6
fi
if wait_report COMPOSE "$before_compose" &&
   [[ $(latest COMPOSE) == 'COMPOSE mode=yes from=yes to=yes subject=yes quote=yes all=no reply=yes sent=no fcc=no read-only=no keys=yes active-send=yes source=yes' ]]; then
  pass reply-template 'cr used the exact selected Message-ID and Notmuch sender-reply template'
else
  fail reply-template 'reply query, headers, quote, compose state, or Evil-collection keys diverged'
fi

lem_keys "$session" G o
tmux_cmd send-keys -t "$session" -l -- 'Editor-composed reply; $(touch PWNED).'
sleep 0.25
lem_keys "$session" Escape
sleep 0.25
lem_wait_for "$session" 'NORMAL' 10 >/dev/null || true
touch "$LEM_YATH_NOTMUCH_FAIL_INSERT_ONCE"
before_smtp=$(wc -l <"$LEM_YATH_SMTP_FAKE_LOG")
before_insert=$(wc -l <"$LEM_YATH_NOTMUCH_INSERT_LOG")
before_compose=$(report_count COMPOSE)
before_notmuch=$(wc -l <"$LEM_YATH_NOTMUCH_LOG")
lem_keys "$session" C-c C-c
wait_log_count "$LEM_YATH_SMTP_FAKE_LOG" "$((before_smtp + 1))" || true
wait_log_count "$LEM_YATH_NOTMUCH_LOG" "$((before_notmuch + 1))" || true
lem_wait_for "$session" 'Message sent; recovery required:' 20 >/dev/null || true
lem_keys "$session" F6
if wait_report COMPOSE "$before_compose" &&
   [[ $(latest COMPOSE) == 'COMPOSE mode=yes from=yes to=yes subject=yes quote=yes all=no reply=yes sent=yes fcc=no read-only=yes keys=yes active-send=yes source=yes' ]] &&
   [[ $(wc -l <"$LEM_YATH_SMTP_FAKE_LOG") -eq $((before_smtp + 1)) ]]; then
  pass send-recovery 'an FCC failure retained a stage-safe recovery buffer after one successful SMTP submission'
else
  fail send-recovery 'the FCC failure lost stage state or duplicated/recorded the wrong operation'
fi

# The report is written just before its command returns.  Let the key
# dispatcher finish that command before exercising the real recovery chord;
# otherwise a queued C-c can be consumed as part of the preceding F6 event.
sleep 0.5
lem_keys "$session" C-c C-c
wait_log_count "$LEM_YATH_NOTMUCH_INSERT_LOG" "$((before_insert + 1))" || true

if lem_wait_for "$session" 'Primary plain body' 20 >/dev/null &&
   [[ $(wc -l <"$LEM_YATH_SMTP_FAKE_LOG") -eq $((before_smtp + 1)) ]] &&
   [[ $(wc -l <"$LEM_YATH_NOTMUCH_INSERT_LOG") -eq $((before_insert + 1)) ]] &&
   python3 - "$LEM_YATH_SMTP_FAKE_LOG" "$LEM_YATH_NOTMUCH_INSERT_LOG" \
     "$LEM_YATH_NOTMUCH_LOG" "$LEM_YATH_NOTMUCH_STATE" <<'PY'
import json, sys

smtp = [json.loads(line) for line in open(sys.argv[1])]
inserted = [json.loads(line) for line in open(sys.argv[2])]
calls = [json.loads(line) for line in open(sys.argv[3])]
state = json.load(open(sys.argv[4]))
assert len(smtp) == 1 and smtp[0]["argv"] == []
assert "Editor-composed reply; $(touch PWNED)." in smtp[0]["input"]
assert "<lem-yath-sent@example.invalid>" in smtp[0]["wire"]
assert inserted == [smtp[0]["wire"]]
query = 'id:"payment+safe;touch PWNED@example.invalid"'
assert ["reply", "--format=default", "--reply-to=sender", query] in calls
assert calls.count(["insert", "--create-folder", "--folder=sent"]) == 2
assert ["tag", "+replied", "--", query] in calls
assert state["inserts"] == 1
assert "replied" in state["tags"]["payment+safe;touch PWNED@example.invalid"]
PY
then
  pass send-reply 'retry performed only FCC/tag, returned to the show view, and preserved the exact transmitted message'
else
  fail send-reply 'SMTP, no-duplicate retry, FCC bytes, replied tag, or origin restoration diverged'
fi

lem_keys "$session" C-c s e
if wait_log_count "$LEM_YATH_NOTMUCH_OPEN_LOG" 1; then
  lem_keys "$session" G
fi
if invoke_report && [[ $(latest STATE) == *'message=reply/second?value@example.invalid '* ]]; then
  lem_keys "$session" C-c s e
fi
if wait_log_count "$LEM_YATH_NOTMUCH_OPEN_LOG" 2 &&
   python3 - "$LEM_YATH_NOTMUCH_OPEN_LOG" <<'PY'
import json, sys, urllib.parse
calls = [json.loads(line) for line in open(sys.argv[1])]
base = "https://backup.ecolink.ie/payment-emails/by-message-id?id="
ids = [
    "payment+safe;touch PWNED@example.invalid",
    "reply/second?value@example.invalid",
]
assert calls == [[base + urllib.parse.quote(value, safe="")] for value in ids]
PY
then
  pass payment-email 'C-c s e opened the current message in Salta with exact URL encoding'
else
  fail payment-email 'message-at-point tracking, mode binding, URL encoding, or browser argv diverged'
fi

before_show=$(wc -l <"$LEM_YATH_NOTMUCH_LOG")
lem_keys "$session" g
if wait_log_count "$LEM_YATH_NOTMUCH_LOG" "$((before_show + 1))" &&
   invoke_report && [[ $(latest STATE) == *'mode=show '*'thread=beta '* ]]; then
  pass show-refresh 'g refreshed the current thread in place'
else
  fail show-refresh 'show refresh did not retain the thread view'
fi

lem_keys "$session" q
sleep 0.5
lem_keys "$session" g
if lem_wait_for "$session" 'Second thread refreshed' 20 >/dev/null && invoke_report &&
   [[ $(latest STATE) == 'STATE mode=list query=yes row=beta thread=none message=none read-only=yes keys=yes body=no html-hidden=no source-live=yes source-exact=yes' ]]; then
  pass list-refresh 'q returned and g refreshed while preserving the selected thread'
else
  fail list-refresh 'list return, refresh, or row preservation failed'
fi

triage_ok=1
lem_keys "$session" Enter
lem_wait_for "$session" 'Primary plain body' 20 >/dev/null || triage_ok=0

before_tag=$(wc -l <"$LEM_YATH_NOTMUCH_LOG")
notmuch_tag_prompt + 'showtag;safe'
wait_log_count "$LEM_YATH_NOTMUCH_LOG" "$((before_tag + 2))" || triage_ok=0
lem_wait_for "$session" 'showtag;safe' 20 >/dev/null || triage_ok=0

before_tag=$(wc -l <"$LEM_YATH_NOTMUCH_LOG")
notmuch_tag_prompt - 'showtag;safe'
wait_log_count "$LEM_YATH_NOTMUCH_LOG" "$((before_tag + 2))" || triage_ok=0

before_tag=$(wc -l <"$LEM_YATH_NOTMUCH_LOG")
lem_keys "$session" =
wait_log_count "$LEM_YATH_NOTMUCH_LOG" "$((before_tag + 2))" || triage_ok=0
invoke_report || triage_ok=0
[[ $(latest STATE) == *'mode=show '*'message=reply/second?value@example.invalid '* ]] || triage_ok=0

before_tag=$(wc -l <"$LEM_YATH_NOTMUCH_LOG")
lem_keys "$session" d
wait_log_count "$LEM_YATH_NOTMUCH_LOG" "$((before_tag + 2))" || triage_ok=0
before_tag=$(wc -l <"$LEM_YATH_NOTMUCH_LOG")
lem_keys "$session" d
wait_log_count "$LEM_YATH_NOTMUCH_LOG" "$((before_tag + 2))" || triage_ok=0

lem_keys "$session" 1 G
sleep 0.4
before_tag=$(wc -l <"$LEM_YATH_NOTMUCH_LOG")
lem_keys "$session" a
wait_log_count "$LEM_YATH_NOTMUCH_LOG" "$((before_tag + 2))" || triage_ok=0
invoke_report || triage_ok=0
[[ $(latest STATE) == *'mode=show '*'message=reply/second?value@example.invalid '* ]] || triage_ok=0
before_tag=$(wc -l <"$LEM_YATH_NOTMUCH_LOG")
lem_keys "$session" x
wait_log_count "$LEM_YATH_NOTMUCH_LOG" "$((before_tag + 1))" || triage_ok=0
invoke_report || triage_ok=0
[[ $(latest STATE) == *'mode=list '*'row=beta '* ]] || triage_ok=0

if ((triage_ok)) && python3 - "$LEM_YATH_NOTMUCH_LOG" "$LEM_YATH_NOTMUCH_STATE" <<'PY'
import json, sys

calls = [json.loads(line) for line in open(sys.argv[1])]
expected = [
    ["tag", "+showtag;safe", "--", 'id:"payment+safe;touch PWNED@example.invalid"'],
    ["tag", "-showtag;safe", "--", 'id:"payment+safe;touch PWNED@example.invalid"'],
    ["tag", "+flagged", "--", 'id:"payment+safe;touch PWNED@example.invalid"'],
    ["tag", "+deleted", "--", 'id:"reply/second?value@example.invalid"'],
    ["tag", "-deleted", "--", 'id:"reply/second?value@example.invalid"'],
    ["tag", "-inbox", "--", 'id:"payment+safe;touch PWNED@example.invalid"'],
    ["tag", "-inbox", "--", 'id:"reply/second?value@example.invalid"'],
]
positions = iter(range(len(calls)))
for wanted in expected:
    assert any(calls[index] == wanted for index in positions), wanted
state = json.load(open(sys.argv[2]))
assert sorted(state["tags"]["payment+safe;touch PWNED@example.invalid"]) == ["flagged", "replied"]
assert state["tags"]["reply/second?value@example.invalid"] == []
PY
then
  pass show-triage 'physical +, -, =, d, a, and x mutated exact messages and advanced like Evil-collection'
else
  fail show-triage 'show tag/archive argv, toggle direction, prompt handling, or cursor transition diverged'
fi

x_ok=1
before_tag=$(wc -l <"$LEM_YATH_NOTMUCH_LOG")
notmuch_tag_prompt + inbox
wait_log_count "$LEM_YATH_NOTMUCH_LOG" "$((before_tag + 1))" || x_ok=0
lem_keys "$session" Enter
lem_wait_for "$session" 'Primary plain body' 20 >/dev/null || x_ok=0
before_tag=$(wc -l <"$LEM_YATH_NOTMUCH_LOG")
lem_keys "$session" X
wait_log_count "$LEM_YATH_NOTMUCH_LOG" "$((before_tag + 1))" || x_ok=0
invoke_report || x_ok=0
[[ $(latest STATE) == *'mode=list '*'row=beta '* ]] || x_ok=0
if ((x_ok)); then
  pass show-thread-archive 'X archived only the rendered message IDs and returned to the parent search row'
else
  fail show-thread-archive 'X query scope, exit restoration, or parent selection diverged'
fi

search_triage_ok=1
before_tag=$(wc -l <"$LEM_YATH_NOTMUCH_LOG")
notmuch_tag_prompt + inbox
wait_log_count "$LEM_YATH_NOTMUCH_LOG" "$((before_tag + 1))" || search_triage_ok=0
before_tag=$(wc -l <"$LEM_YATH_NOTMUCH_LOG")
notmuch_tag_prompt + failtag
wait_log_count "$LEM_YATH_NOTMUCH_LOG" "$((before_tag + 1))" || search_triage_ok=0
invoke_report || search_triage_ok=0
[[ $(latest STATE) == *'mode=list '*'row=beta '* ]] || search_triage_ok=0
before_tag=$(wc -l <"$LEM_YATH_NOTMUCH_LOG")
notmuch_tag_prompt + 'triage;safe'
wait_log_count "$LEM_YATH_NOTMUCH_LOG" "$((before_tag + 1))" || search_triage_ok=0
before_tag=$(wc -l <"$LEM_YATH_NOTMUCH_LOG")
notmuch_tag_prompt - 'triage;safe'
wait_log_count "$LEM_YATH_NOTMUCH_LOG" "$((before_tag + 1))" || search_triage_ok=0
for key in '!' '=' d d a; do
  before_tag=$(wc -l <"$LEM_YATH_NOTMUCH_LOG")
  lem_keys "$session" "$key"
  wait_log_count "$LEM_YATH_NOTMUCH_LOG" "$((before_tag + 1))" || search_triage_ok=0
done
lem_keys "$session" g
lem_wait_for "$session" 'No threads for query:' 20 >/dev/null || search_triage_ok=0

if ((search_triage_ok)) && python3 - "$LEM_YATH_NOTMUCH_LOG" "$LEM_YATH_NOTMUCH_STATE" <<'PY'
import json, sys

calls = [json.loads(line) for line in open(sys.argv[1])]
thread = 'thread:"beta"'
assert ["tag", "+failtag", "--", thread] in calls
expected = [
    ["tag", "+inbox", "--", thread],
    ["tag", "+triage;safe", "--", thread],
    ["tag", "-triage;safe", "--", thread],
    ["tag", "+unread", "--", thread],
    ["tag", "+flagged", "--", thread],
    ["tag", "+deleted", "--", thread],
    ["tag", "-deleted", "--", thread],
    ["tag", "-inbox", "--", thread],
]
positions = iter(range(len(calls)))
for wanted in expected:
    assert any(calls[index] == wanted for index in positions), wanted
state = json.load(open(sys.argv[2]))
assert sorted(state["tags"]["payment+safe;touch PWNED@example.invalid"]) == [
    "flagged", "replied", "unread"
]
assert sorted(state["tags"]["reply/second?value@example.invalid"]) == ["flagged", "unread"]
for message_id in ("payment+safe;touch PWNED@example.invalid", "reply/second?value@example.invalid"):
    assert "failtag" not in state["tags"][message_id]
PY
then
  pass search-triage 'physical +, -, !, =, d, and a performed exact atomic thread triage and refresh removed archived rows'
else
  fail search-triage 'search tag prompts, toggle direction, archive movement, or refresh filtering diverged'
fi

lem_keys "$session" F4
if lem_wait_for "$session" 'No threads for query: tag:empty' 20 >/dev/null &&
   invoke_report && [[ $(latest STATE) == *'mode=list query=no row=none '* ]]; then
  pass empty 'a successful empty JSON array rendered an empty result list'
else
  fail empty 'empty search was confused with process failure'
fi

lem_keys "$session" F3
before_notmuch=$(wc -l <"$LEM_YATH_NOTMUCH_LOG")
if lem_wait_for "$session" 'No threads for query:' 20 >/dev/null; then
  lem_keys "$session" F5
fi
if wait_log_count "$LEM_YATH_MBSYNC_LOG" 1 &&
   wait_log_count "$LEM_YATH_NOTMUCH_LOG" "$((before_notmuch + 1))" &&
   grep -Fxq -- '-a' "$LEM_YATH_MBSYNC_LOG" &&
   python3 - "$LEM_YATH_NOTMUCH_LOG" <<'PY'
import json, sys
calls = [json.loads(line) for line in open(sys.argv[1])]
assert ["new"] in calls
assert [
    "show",
    "--format=raw",
    "--part=7",
    'id:"payment+safe;touch PWNED@example.invalid"',
] in calls
assert ["show", "--format=raw", "--part=8", 'id:"bad@example.invalid"'] in calls
assert ["show", "--format=raw", "--part=9", 'id:"slow@example.invalid"'] in calls
queries = [call[-1] for call in calls if call and call[0] == "search"]
assert 'tag:inbox and subject:"safe;touch PWNED"' in queries
assert all(isinstance(call, list) and all(isinstance(arg, str) for arg in call) for call in calls)
PY
then
  pass fetch 'mbsync -a completed before notmuch new through the fake tools'
else
  fail fetch 'fetch/index sequencing or direct query argv failed'
fi

if [ ! -e "$root/PWNED" ] && [ ! -e "$PWD/PWNED" ]; then
  pass argv 'metacharacter query remained one inert notmuch argv value'
else
  fail argv 'query text escaped the direct argv boundary'
fi

if ((failed)); then exit 1; fi
printf 'SUMMARY PASS failures=0\n'
