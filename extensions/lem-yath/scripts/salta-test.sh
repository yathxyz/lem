#!/usr/bin/env bash
# Real-TUI acceptance for the configured Salta/PostgREST workflows.
set -euo pipefail

# Tmux's pane-width accounting requires a UTF-8 locale for its Unicode border.
export LC_ALL=C.UTF-8

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=scripts/tui-driver.sh
source "$here/scripts/tui-driver.sh"

id="${LEM_YATH_CHECK_ID:-salta-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-salta.XXXXXX")"
session="lem-yath-salta-$id"

cleanup() {
  lem_stop "$session" || true
  rm -rf -- "$root"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_SALTA_REPORT="$root/report"
export LEM_YATH_SALTA_CURL_LOG="$root/curl.jsonl"
fakebin="$root/fake bin;safe"
export LEM_YATH_SALTA_FAKE_BIN="$fakebin"
mkdir -p "$HOME" "$XDG_CACHE_HOME" "$fakebin"
: >"$LEM_YATH_SALTA_REPORT"
: >"$LEM_YATH_SALTA_CURL_LOG"
cp "$here/scripts/fake-salta-curl.py" "$fakebin/curl"
python=$(command -v python3)
sed -i "1c#!$python" "$fakebin/curl"
chmod +x "$fakebin/curl"
ln -s "$(command -v timeout)" "$fakebin/timeout"
export PATH="$fakebin:$PATH"

secret='service-role;"\touch PWNED'
export SALTA_SUPABASE_KEY="$secret"
export SALTA_SUPABASE_URL='https://salta.invalid/base;safe'
source_file="$root/source file;safe.txt"
printf 'Salta source remains exact\n' >"$source_file"

failed=0
pass() { printf 'PASS  %-24s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-24s %s\n' "$1" "$2"
  lem_capture "$session" 2>/dev/null || true
  sed -n '1,180p' "$LEM_YATH_SALTA_REPORT" 2>/dev/null || true
  sed -n '1,180p' "$LEM_YATH_SALTA_CURL_LOG" 2>/dev/null || true
}

report_count() { grep -c "^$1" "$LEM_YATH_SALTA_REPORT" 2>/dev/null || true; }
wait_report() {
  local prefix=$1 before=$2 index=0
  while ((index < 80)); do
    if (( $(report_count "$prefix") > before )); then return 0; fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}
latest() { grep "^$1" "$LEM_YATH_SALTA_REPORT" | tail -n 1; }
invoke_report() {
  local before
  before=$(report_count STATE)
  lem_keys "$session" F4
  wait_report STATE "$before"
}
wait_lines() {
  local path=$1 expected=$2 index=0
  while ((index < 80)); do
    if [ "$(wc -l <"$path")" -ge "$expected" ]; then return 0; fi
    sleep 0.25
    index=$((index + 1))
  done
  return 1
}
submit_prompt() {
  local prompt=$1 text=$2
  lem_wait_for "$session" "$prompt" 20 >/dev/null
  tmux_cmd send-keys -t "$session" -l -- "$text"
  lem_keys "$session" Enter
}
search_property() {
  lem_keys "$session" C-c s s
  submit_prompt 'Search properties:' "$1"
}
restore_source() {
  lem_keys "$session" F5
  lem_wait_for "$session" NORMAL 20 >/dev/null
}
restore_detail() {
  lem_keys "$session" F6
  lem_wait_for "$session" 'Property' 20 >/dev/null
}

fixture="$(lem-yath_lisp_string "$here/scripts/salta-fixture.lisp")"
lem_start "$session" "$source_file" --eval "(load #P$fixture)"

if wait_report READY 0 && lem_wait_for "$session" NORMAL 60 >/dev/null &&
   grep -Fqx -- "EXEC curl=$fakebin/curl" "$LEM_YATH_SALTA_REPORT" &&
   invoke_report &&
   [[ $(latest STATE) == *'mode=other '*'generation=0 '*'numeric=yes source-live=yes source-exact=yes' ]]; then
  pass boot 'configured Lem loaded the isolated Salta transport and safe formatters'
else
  fail boot 'fixture, fake curl resolution, numeric safety, or source state diverged'
fi
if ((failed)); then exit 1; fi

search_property 'oak;touch PWNED'
if lem_wait_for "$session" 'Alice Example' 20 >/dev/null && invoke_report &&
   [[ $(latest STATE) == 'STATE mode=list name=*salta-properties* row=app-1 app=none code=none generation=1 read-only=yes keys=yes kill=none numeric=yes source-live=yes source-exact=yes' ]]; then
  pass search 'physical C-c s s focused a read-only Vi-priority property list'
else
  fail search 'search RPC, rendering, focus, row identity, or key precedence diverged'
fi
if ((failed)); then exit 1; fi

lem_keys "$session" w
if invoke_report && [[ $(latest STATE) == *'kill=APP-001 '* ]]; then
  pass list-copy 'w copied the visible application code rather than its hidden UUID'
else
  fail list-copy 'list copy semantics diverged from the configured tabulated list'
fi

lem_keys "$session" Enter
if lem_wait_for "$session" 'Insulation' 20 >/dev/null && invoke_report &&
   [[ $(latest STATE) == 'STATE mode=detail name=*salta: APP-001* row=none app=app-1 code=APP-001 generation=2 read-only=yes keys=yes kill=APP-001 numeric=yes source-live=yes source-exact=yes' ]]; then
  pass detail 'Return fetched and focused the complete property detail workflow'
else
  fail detail 'detail bundle, context, mode, or source preservation diverged'
fi

lem_keys "$session" w
if invoke_report && [[ $(latest STATE) == *'kill=APP-001 '* ]]; then
  pass detail-copy 'detail w copied the configured application code'
else
  fail detail-copy 'detail clipboard behavior diverged'
fi

lem_keys "$session" c
if lem_wait_for "$session" 'REF-1' 20 >/dev/null && invoke_report &&
   [[ $(latest STATE) == 'STATE mode=list name=*salta-claims: APP-001* row=claim-1 app=app-1 code=APP-001 generation=3 read-only=yes keys=yes kill=APP-001 numeric=yes source-live=yes source-exact=yes' ]]; then
  pass claims 'detail c opened the application claim-line list with retained context'
else
  fail claims 'claim-line route or application context diverged'
fi

restore_detail
lem_keys "$session" p
if lem_wait_for "$session" 'salta-payments: APP-001' 20 >/dev/null && invoke_report &&
   [[ $(latest STATE) == 'STATE mode=list name=*salta-payments: APP-001* row=pay-1 app=app-1 code=APP-001 generation=4 read-only=yes keys=yes kill=APP-001 numeric=yes source-live=yes source-exact=yes' ]]; then
  pass detail-payments 'detail p opened property-scoped payments with retained context'
else
  fail detail-payments 'property payment filtering or context diverged'
fi

restore_detail
lem_keys "$session" r
if lem_wait_for "$session" 'Margin:' 20 >/dev/null && invoke_report &&
   [[ $(latest STATE) == 'STATE mode=list name=*salta-reckoner: APP-001* row=INS app=none code=none generation=5 read-only=yes keys=yes kill=APP-001 numeric=yes source-live=yes source-exact=yes' ]]; then
  pass reckoner 'detail r rendered revenue, cost, profit, totals, and margin'
else
  fail reckoner 'reckoner RPC, totals, or detail binding diverged'
fi

restore_detail
before_refresh=$(wc -l <"$LEM_YATH_SALTA_CURL_LOG")
lem_keys "$session" g
if wait_lines "$LEM_YATH_SALTA_CURL_LOG" "$((before_refresh + 4))"; then sleep 0.5; fi
if invoke_report &&
   [[ $(latest STATE) == *'mode=detail name=*salta: APP-001* '*'generation=6 '*'source-exact=yes' ]]; then
  pass refresh 'detail g reran the captured application query without a prompt'
else
  fail refresh 'detail refresh or context capture diverged'
fi

restore_source
lem_keys "$session" C-c s c
submit_prompt 'Contractor:' 'Acme (AC)'
if lem_wait_for "$session" 'Rate Card: July 2026' 20 >/dev/null && invoke_report &&
   [[ $(latest STATE) == *'mode=detail name=*salta-rates: Acme (AC)* '*'read-only=yes keys=yes '*'source-exact=yes' ]]; then
  pass rates 'C-c s c completed contractor selection and latest-rate-card rendering'
else
  fail rates 'contractor cache, rate-card request, or rates rendering diverged'
fi

restore_source
lem_keys "$session" C-c s f
submit_prompt 'Contractor:' 'Acme (AC)'
if lem_wait_for "$session" 'Outstanding:' 20 >/dev/null && invoke_report &&
   [[ $(latest STATE) == *'mode=detail name=*salta-financials: Acme (AC)* '*'read-only=yes keys=yes '*'source-exact=yes' ]]; then
  pass financials 'C-c s f reused contractor completion and rendered financial totals'
else
  fail financials 'financial query, cache reuse, or detail rendering diverged'
fi

restore_source
lem_keys "$session" C-c s p
if lem_wait_for "$session" 'RUN-1' 20 >/dev/null &&
   ! lem_capture "$session" | grep -Fq 'Filter by contractor?' &&
   invoke_report &&
   [[ $(latest STATE) == *'mode=list name=*salta-payments* row=pay-1 '*'source-exact=yes' ]]; then
  pass payments 'unprefixed C-c s p opened recent payments without an extra prompt'
else
  fail payments 'payment prefix semantics or list rendering diverged from Emacs'
fi

restore_source
search_property slow
sleep 0.2
search_property new
if lem_wait_for "$session" 'Newest result' 20 >/dev/null; then sleep 3; fi
if ! lem_capture "$session" | grep -Fq 'Late stale result' && invoke_report &&
   [[ $(latest STATE) == *'mode=list name=*salta-properties* row=new-id '*'source-exact=yes' ]]; then
  pass stale 'a late older RPC could not replace the newest Salta result'
else
  fail stale 'out-of-order Salta completion displaced newer state'
fi

if python3 - "$LEM_YATH_SALTA_CURL_LOG" "$secret" <<'PY'
import json, sys, urllib.parse
calls = [json.loads(line) for line in open(sys.argv[1])]
secret = sys.argv[2]
expected_argv = [
    "--silent", "--show-error", "--fail-with-body",
    "--max-time", "5", "--config", "-"
]
assert calls
for call in calls:
    assert call["argv"] == expected_argv
    assert secret not in "\n".join(call["argv"])
    assert call["url"] not in call["argv"]
    assert f"apikey: {secret}" in call["headers"]
    assert f"Authorization: Bearer {secret}" in call["headers"]
    assert call["url"].startswith("https://salta.invalid/base;safe/rest/v1/")
searches = [
    call for call in calls
    if call["url"].endswith("/rpc/fuzzy_search_properties")
]
assert any(call["body"] == {
    "query_text": "oak;touch PWNED", "result_limit": 20
} for call in searches)
assert any(call["body"]["query_text"] == "slow" for call in searches)
assert any(call["body"]["query_text"] == "new" for call in searches)
paths = [urllib.parse.urlsplit(call["url"]).path for call in calls]
for suffix in [
    "/rpc/fuzzy_search_properties", "/rpt_applications",
    "/rpt_application_measures", "/rpt_claim_lines", "/rpt_payments",
    "/rpc/get_reckoner_data", "/contractors", "/rate_cards", "/rates",
    "/rpt_contractor_financials",
]:
    assert any(path.endswith(suffix) for path in paths), suffix
assert sum(path.endswith("/contractors") for path in paths) == 1
PY
then
  pass transport 'credentials, JSON bodies, and URLs stayed on bounded curl stdin'
else
  fail transport 'request coverage, cache behavior, or credential process boundary diverged'
fi

if [ ! -e "$root/PWNED" ] && [ ! -e "$PWD/PWNED" ]; then
  pass inert 'metacharacter credentials, queries, URLs, and paths remained inert'
else
  fail inert 'test metacharacters escaped a direct process boundary'
fi

if ((failed)); then exit 1; fi
printf 'SUMMARY PASS failures=0\n'
