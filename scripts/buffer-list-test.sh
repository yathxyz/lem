#!/usr/bin/env bash
# Real-ncurses coverage for the configured Ibuffer saved filter groups.
set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
id="${LEM_YATH_CHECK_ID:-buffer-list-$$}"
root="$(mktemp -d "${TMPDIR:-/tmp}/lem-yath-buffer-list.XXXXXX")"
export HOME="$root/home"
export XDG_CACHE_HOME="$root/cache"
export LEM_YATH_BUFFER_LIST_REPORT="$root/report"
export LEM_YATH_BUFFER_LIST_TARGET="$root/buffer-list-zz-target.txt"
export LEM_YATH_BUFFER_LIST_SAVE_TARGET="$root/buffer-list-save-target.txt"
export LEM_YATH_BUFFER_LIST_SORT_A="$root/a-file.txt"
export LEM_YATH_BUFFER_LIST_SORT_B="$root/b-file.txt"
export LEM_YATH_BUFFER_LIST_SORT_C="$root/c-file.txt"
export LEM_TUI_WIDTH=180
export LEM_TUI_HEIGHT=36
mkdir -p "$HOME" "$XDG_CACHE_HOME"

source_file="$root/buffer-list-source.txt"
printf 'BUFFER LIST SOURCE\n' >"$source_file"
printf 'BUFFER LIST SELECTED TARGET\n' >"$LEM_YATH_BUFFER_LIST_TARGET"
printf 'SAVE ORIGINAL\n' >"$LEM_YATH_BUFFER_LIST_SAVE_TARGET"
: >"$LEM_YATH_BUFFER_LIST_SORT_A"
: >"$LEM_YATH_BUFFER_LIST_SORT_B"
: >"$LEM_YATH_BUFFER_LIST_SORT_C"
: >"$LEM_YATH_BUFFER_LIST_REPORT"

source "$here/scripts/tui-driver.sh"

session="lem-yath-buffer-list-$id"
failed=0

cleanup() {
  lem_stop "$session"
  rm -rf "$root"
}
trap cleanup EXIT
trap 'exit 130' INT TERM

pass() { printf 'PASS  %-28s %s\n' "$1" "$2"; }
fail() {
  failed=1
  printf 'FAIL  %-28s %s\n' "$1" "$2"
  tail -20 "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true
  lem_capture "$session" 2>/dev/null || true
}

report_count() {
  grep -c '^STATE ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true
}

report_state() {
  local before attempts=0
  before=$(report_count)
  lem_keys "$session" F5
  while ((attempts < 40)); do
    if (( $(report_count) > before )); then return 0; fi
    sleep 0.25
    attempts=$((attempts + 1))
  done
  return 1
}

latest_state() {
  grep '^STATE ' "$LEM_YATH_BUFFER_LIST_REPORT" | tail -1
}

report_ui() {
  local before attempts=0
  before=$(grep -c '^UI ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true)
  lem_keys "$session" F8
  while ((attempts < 40)); do
    if (( $(grep -c '^UI ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true) > before )); then
      grep '^UI ' "$LEM_YATH_BUFFER_LIST_REPORT" | tail -1
      return 0
    fi
    sleep 0.25
    attempts=$((attempts + 1))
  done
  return 1
}

report_nav() {
  local before attempts=0
  before=$(grep -c '^NAV ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true)
  lem_keys "$session" F11
  while ((attempts < 40)); do
    if (( $(grep -c '^NAV ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true) > before )); then
      grep '^NAV ' "$LEM_YATH_BUFFER_LIST_REPORT" | tail -1
      return 0
    fi
    sleep 0.25
    attempts=$((attempts + 1))
  done
  return 1
}

report_filter() {
  local before attempts=0
  before=$(grep -c '^FILTER ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true)
  lem_keys "$session" F12
  while ((attempts < 40)); do
    if (( $(grep -c '^FILTER ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true) > before )); then
      grep '^FILTER ' "$LEM_YATH_BUFFER_LIST_REPORT" | tail -1
      return 0
    fi
    sleep 0.25
    attempts=$((attempts + 1))
  done
  return 1
}

fixture="$(lem-yath_lisp_string "$here/scripts/buffer-list-fixture.lisp")"
lem_start "$session" "$source_file" --eval "(load #P$fixture)"

if lem_wait_for "$session" 'BUFFER LIST SOURCE' 60 >/dev/null &&
   grep -q '^READY$' "$LEM_YATH_BUFFER_LIST_REPORT"; then
  pass boot "configured Lem loaded the grouped-buffer fixture"
else
  fail boot "the fixture did not become ready"
fi

expected_classify='classify=org,tramp,emacs,ediff,dired,terminal,help,org,Default'
expected_order='order=org,tramp,emacs,ediff,dired,terminal,help,Default'
if report_state &&
   [[ $(latest_state) == *"$expected_classify"* ]] &&
   [[ $(latest_state) == *"$expected_order"* ]]; then
  pass group-semantics "all seven groups use configured first-match order"
else
  fail group-semantics "classification or group order diverged"
fi

if [[ $(latest_state) == *'subset=org,Default'* ]] &&
   [[ $(latest_state) == *'binding=LEM-YATH-LIST-BUFFERS definitions=7'* ]]; then
  pass hidden-empty-binding "empty groups are omitted and C-x C-b owns the grouped command"
else
  fail hidden-empty-binding "empty-group or binding behavior diverged"
fi

if grep -Fq 'COLUMNS status=[*% ] name=[buffer-list-nam...] name-width=18 size=[        1] mode=[Long Fixture ...] mode-width=16 file=[] wide=[12345678901234....] wide-width=18' \
     "$LEM_YATH_BUFFER_LIST_REPORT"; then
  pass stock-columns "status, fixed widths, right alignment, and cell-safe elision match Ibuffer"
else
  fail stock-columns "the stock Ibuffer column contract diverged"
fi

lem_keys "$session" C-x C-b
if lem_wait_for "$session" 'Buffer[[:space:]]+Size[[:space:]]+Mode[[:space:]]+File' 15 >/dev/null; then
  screen=$(lem_capture "$session")
  missing=0
  for group in org tramp emacs ediff dired terminal help Default; do
    if ! grep -Fq "[ ${group} ]" <<<"$screen"; then
      missing=1
    fi
  done
  if ((missing == 0)) &&
     grep -Eq 'buffer-list-zz-\.\.\.[[:space:]]+[0-9]+[[:space:]]+Fundamental' <<<"$screen" &&
     grep -Eq 'buffer-list-nam\.\.\.[[:space:]]+1[[:space:]]+Long Fixture \.\.\.' <<<"$screen" &&
     grep -Fq 'ctl\nname' <<<"$screen" &&
     grep -Fq '*Org Src direct...' <<<"$screen"; then
    pass grouped-ui "the chooser displays grouped stock Ibuffer columns and escaped rows"
  else
    fail grouped-ui "the grouped chooser omitted headings, columns, or fixture rows"
  fi
else
  fail grouped-ui "C-x C-b did not open the grouped multi-column chooser"
fi

# Heading rows are presentation/control rows, never buffer-operation targets.
lem_keys "$session" x
lem_keys "$session" S
lem_keys "$session" U
sleep 0.3
screen=$(lem_capture "$session")
if grep -Fq '[ org ]' <<<"$screen" &&
   grep -Fq '*Org Src buffer...' <<<"$screen" &&
   ! grep -Eq '[>D][[:space:]]+\[ org \]' <<<"$screen"; then
  pass heading-safety "kill, save, and mark cannot target a group heading"
else
  fail heading-safety "a buffer action mutated or marked a group heading"
fi

# The first row is the first nonempty group heading.  Return follows Ibuffer:
# hide its rows, retain an ellipsis heading, and expand it again in place.
lem_keys "$session" Enter
sleep 0.4
screen=$(lem_capture "$session")
if grep -Fq '[ org ... ]' <<<"$screen" &&
   ! grep -Fq '*Org Src buffer...' <<<"$screen" &&
   grep -Fq '[ tramp ]' <<<"$screen"; then
  pass grouped-collapse "Return collapsed only the focused Ibuffer group"
else
  fail grouped-collapse "the focused heading did not collapse safely"
fi

lem_keys "$session" Enter
sleep 0.4
screen=$(lem_capture "$session")
if grep -Fq '[ org ]' <<<"$screen" &&
   grep -Fq '*Org Src buffer...' <<<"$screen" &&
   ! grep -Fq '[ org ... ]' <<<"$screen"; then
  pass grouped-expand "Return restored the collapsed group in place"
else
  fail grouped-expand "the focused heading did not expand safely"
fi

lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'zz-target'
sleep 0.6
screen=$(lem_capture "$session")
if grep -Fq 'buffer-list-zz-...' <<<"$screen" &&
   [[ $(grep -c 'buffer-list-source\.txt' <<<"$screen") -eq 1 ]] &&
   ! grep -Eq '\[ (org|Default) (\.\.\. )?\]' <<<"$screen"; then
  pass grouped-filter "live filtering presents matching buffers without heading traps"
else
  fail grouped-filter "filtering retained headings or unrelated rows"
fi

# Accept the name filter, then use modal Return to visit the focused row.
lem_keys "$session" Enter
lem_keys "$session" Enter
if lem_wait_for "$session" 'BUFFER LIST SELECTED TARGET' 15 >/dev/null; then
  before=$(grep -c '^CURRENT ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true)
  lem_keys "$session" F6
  attempts=0
  while ((attempts < 40)) &&
        (( $(grep -c '^CURRENT ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true) <= before )); do
    sleep 0.25
    attempts=$((attempts + 1))
  done
  if grep -q '^CURRENT name=buffer-list-zz-target\.txt file=buffer-list-zz-target\.txt group=Default text=BUFFER LIST SELECTED TARGET\\n$' "$LEM_YATH_BUFFER_LIST_REPORT"; then
    pass grouped-select "Return opens the exact focused buffer"
  else
    fail grouped-select "the selected buffer identity was not preserved"
  fi
else
  fail grouped-select "Return did not open the filtered target"
fi

lem_keys "$session" F10
if report_state &&
   [[ $(latest_state) == *"$expected_classify"* ]] &&
   [[ $(latest_state) == *"$expected_order"* ]] &&
   [[ $(latest_state) == *'binding=LEM-YATH-LIST-BUFFERS definitions=7'* ]]; then
  pass reload "source reload preserves definitions, grouping, and binding"
else
  fail reload "reload changed the effective grouped-buffer contract"
fi

lem_keys "$session" C-x C-b
if lem_wait_for "$session" 'Buffer[[:space:]]+Size[[:space:]]+Mode[[:space:]]+File' 15 >/dev/null; then
  lem_keys "$session" o a
  ui=$(report_ui || true)
  if [[ "$ui" == 'UI sort=alphabetic reverse=no format=0 columns=,Buffer,Size,Mode,File order=buffer-list-sort-alpha,buffer-list-sort-middle,buffer-list-sort-zeta' ]]; then
    pass sort-alphabetic "o a sorts names inside each configured group"
  else
    fail sort-alphabetic "unexpected alphabetic state: $ui"
  fi

  lem_keys "$session" o i
  ui=$(report_ui || true)
  if [[ "$ui" == 'UI sort=alphabetic reverse=yes format=0 columns=,Buffer,Size,Mode,File order=buffer-list-sort-zeta,buffer-list-sort-middle,buffer-list-sort-alpha' ]]; then
    pass sort-invert "o i reverses the current Ibuffer ordering"
  else
    fail sort-invert "unexpected reversed state: $ui"
  fi

  lem_keys "$session" o i
  lem_keys "$session" o s
  ui=$(report_ui || true)
  if [[ "$ui" == 'UI sort=size reverse=no format=0 columns=,Buffer,Size,Mode,File order=buffer-list-sort-zeta,buffer-list-sort-middle,buffer-list-sort-alpha' ]]; then
    pass sort-size "o s sorts by live buffer size"
  else
    fail sort-size "unexpected size state: $ui"
  fi

  lem_keys "$session" o f
  ui=$(report_ui || true)
  if [[ "$ui" == 'UI sort=filename reverse=no format=0 columns=,Buffer,Size,Mode,File order=buffer-list-sort-middle,buffer-list-sort-zeta,buffer-list-sort-alpha' ]]; then
    pass sort-filename "o f sorts by visiting filename"
  else
    fail sort-filename "unexpected filename state: $ui"
  fi

  lem_keys "$session" o m
  ui=$(report_ui || true)
  if [[ "$ui" == 'UI sort=major-mode reverse=no format=0 columns=,Buffer,Size,Mode,File order=buffer-list-sort-middle,buffer-list-sort-zeta,buffer-list-sort-alpha' ]]; then
    pass sort-major-mode "o m sorts by major-mode symbol"
  else
    fail sort-major-mode "unexpected major-mode state: $ui"
  fi

  lem_keys "$session" ,
  ui=$(report_ui || true)
  if [[ "$ui" == 'UI sort=mode-name reverse=no format=0 columns=,Buffer,Size,Mode,File order=buffer-list-sort-zeta,buffer-list-sort-alpha,buffer-list-sort-middle' ]]; then
    pass sort-cycle "comma advances through pinned Ibuffer sort modes"
  else
    fail sort-cycle "unexpected cycled state: $ui"
  fi

  lem_keys "$session" o v
  ui=$(report_ui || true)
  if [[ "$ui" == UI\ sort=recency\ reverse=no\ format=0* ]]; then
    pass sort-recency "o v restores the chooser's captured recency order"
  else
    fail sort-recency "unexpected recency state: $ui"
  fi

  lem_keys "$session" '`'
  ui=$(report_ui || true)
  screen=$(lem_capture "$session")
  if [[ "$ui" == UI\ sort=recency\ reverse=no\ format=1\ columns=Buffer,File* ]] &&
     grep -Eq 'Buffer[[:space:]]+File' <<<"$screen" &&
     ! grep -Eq 'Buffer[[:space:]]+Size[[:space:]]+Mode[[:space:]]+File' <<<"$screen"; then
    pass alternate-format "backtick switches to Ibuffer's compact name/file view"
  else
    fail alternate-format "compact format did not render: $ui"
  fi

  lem_keys "$session" '`'
  ui=$(report_ui || true)
  screen=$(lem_capture "$session")
  if [[ "$ui" == UI\ sort=recency\ reverse=no\ format=0* ]] &&
     grep -Eq 'Buffer[[:space:]]+Size[[:space:]]+Mode[[:space:]]+File' <<<"$screen"; then
    pass primary-format "a second backtick restores the stock detailed view"
  else
    fail primary-format "primary format did not return: $ui"
  fi

  lem_keys "$session" Tab
  nav=$(report_nav || true)
  if [[ "$nav" == 'NAV focus=heading:tramp marks=' ]]; then
    pass group-next-tab "Tab moved to the next configured filter group"
  else
    fail group-next-tab "unexpected Tab destination: $nav"
  fi

  lem_keys "$session" BTab
  nav=$(report_nav || true)
  if [[ "$nav" == 'NAV focus=heading:org marks=' ]]; then
    pass group-previous-tab "backtab returned to the previous filter group"
  else
    fail group-previous-tab "unexpected backtab destination: $nav"
  fi

  lem_keys "$session" ']' ']'
  nav=$(report_nav || true)
  if [[ "$nav" == 'NAV focus=heading:tramp marks=' ]]; then
    pass group-next-bracket "]] moved to the next filter group"
  else
    fail group-next-bracket "unexpected ]] destination: $nav"
  fi

  lem_keys "$session" '[' '['
  lem_keys "$session" C-j
  nav=$(report_nav || true)
  if [[ "$nav" == 'NAV focus=heading:tramp marks=' ]]; then
    pass group-next-control "C-j moved to the next filter group"
  else
    fail group-next-control "unexpected C-j destination: $nav"
  fi

  lem_keys "$session" C-k
  nav=$(report_nav || true)
  if [[ "$nav" == 'NAV focus=heading:org marks=' ]]; then
    pass group-previous-control "C-k returned to the previous filter group"
  else
    fail group-previous-control "unexpected C-k destination: $nav"
  fi

  lem_keys "$session" g j
  nav=$(report_nav || true)
  if [[ "$nav" == NAV\ focus=buffer:\*Org\ Src* ]]; then
    pass modal-row-motion "gj moved one row without invoking global screen motion"
  else
    fail modal-row-motion "unexpected gj destination: $nav"
  fi

  lem_keys "$session" g k
  nav=$(report_nav || true)
  if [[ "$nav" == 'NAV focus=heading:org marks=' ]]; then
    pass modal-row-return "gk returned to the group heading"
  else
    fail modal-row-return "unexpected gk destination: $nav"
  fi
else
  fail sorting-ui "could not reopen the grouped chooser for sorting"
fi
lem_keys "$session" q

lem_keys "$session" C-x C-b
lem_keys "$session" s i
filter=$(report_filter || true)
if [[ "$filter" == FILTER\ stack=modified* ]] &&
   [[ "$filter" == *'buffer-list-sort-zeta'* ]] &&
   [[ "$filter" == *'buffer-list-save-target.txt'* ]] &&
   [[ "$filter" != *'buffer-list-zz-target.txt'* ]]; then
  pass filter-modified "s i retained only modified buffers"
else
  fail filter-modified "unexpected modified filter state: $filter"
fi

lem_keys "$session" s v
filter=$(report_filter || true)
if [[ "$filter" == FILTER\ stack=visiting-file,+modified* ]] &&
   [[ "$filter" == *'buffer-list-sort-zeta'* ]] &&
   [[ "$filter" != *'buffer-list-name-that-is-long'* ]]; then
  pass filter-visiting-file "s v composed visiting-file with the modified filter"
else
  fail filter-visiting-file "unexpected visiting-file filter state: $filter"
fi

lem_keys "$session" s '!'
filter=$(report_filter || true)
if [[ "$filter" == FILTER\ stack=not\(visiting-file\),+modified* ]] &&
   [[ "$filter" == *'buffer-list-name-that-is-long'* ]] &&
   [[ "$filter" != *'buffer-list-sort-zeta'* ]]; then
  pass filter-negate "s ! negated only the top filter"
else
  fail filter-negate "unexpected negated filter state: $filter"
fi

lem_keys "$session" s '!'
lem_keys "$session" s p
filter=$(report_filter || true)
if [[ "$filter" == FILTER\ stack=modified* ]] &&
   [[ "$filter" == *'buffer-list-name-that-is-long'* ]] &&
   [[ "$filter" != *'buffer-list-zz-target.txt'* ]]; then
  pass filter-pop "s p removed only the top filter"
else
  fail filter-pop "unexpected popped filter state: $filter"
fi

lem_keys "$session" s /
filter=$(report_filter || true)
if [[ "$filter" == FILTER\ stack=\ visible=* ]] &&
   [[ "$filter" == *'buffer-list-zz-target.txt'* ]]; then
  pass filter-disable "s / disabled the complete filter stack"
else
  fail filter-disable "unexpected disabled filter state: $filter"
fi

lem_keys "$session" s m
tmux_cmd send-keys -t "$session" -l 'buffer-list-test-sort-m-mode'
sleep 0.3
lem_keys "$session" Enter
filter=$(report_filter || true)
if [[ "$filter" == FILTER\ stack=mode=buffer-list-test-sort-m-mode* ]] &&
   [[ "$filter" == *'buffer-list-sort-zeta'* ]] &&
   [[ "$filter" != *'buffer-list-sort-alpha'* ]]; then
  pass filter-mode "s m committed a case-insensitive used-mode filter"
else
  fail filter-mode "unexpected mode filter state: $filter"
fi
lem_keys "$session" s p

lem_keys "$session" s f
tmux_cmd send-keys -t "$session" -l 'b-file\.txt$'
sleep 0.3
lem_keys "$session" Enter
filter=$(report_filter || true)
if [[ "$filter" == FILTER\ stack=filename=* ]] &&
   [[ "$filter" == *'buffer-list-sort-zeta'* ]] &&
   [[ "$filter" != *'buffer-list-sort-alpha'* ]]; then
  pass filter-filename "s f committed a full-filename regexp filter"
else
  fail filter-filename "unexpected filename filter state: $filter"
fi
lem_keys "$session" s p

lem_keys "$session" s b
tmux_cmd send-keys -t "$session" -l 'b-file.txt'
sleep 0.3
lem_keys "$session" Enter
filter=$(report_filter || true)
if [[ "$filter" == FILTER\ stack=basename=b-file.txt* ]] &&
   [[ "$filter" == *'buffer-list-sort-zeta'* ]] &&
   [[ "$filter" != *'buffer-list-sort-alpha'* ]]; then
  pass filter-basename "s b committed a basename regexp filter"
else
  fail filter-basename "unexpected basename filter state: $filter"
fi
lem_keys "$session" s p

lem_keys "$session" s .
tmux_cmd send-keys -t "$session" -l 'txt'
sleep 0.3
lem_keys "$session" Enter
filter=$(report_filter || true)
if [[ "$filter" == FILTER\ stack=extension=txt* ]] &&
   [[ "$filter" == *'buffer-list-zz-target.txt'* ]] &&
   [[ "$filter" != *'buffer-list-name-that-is-long'* ]]; then
  pass filter-extension "s . committed an extension regexp filter"
else
  fail filter-extension "unexpected extension filter state: $filter"
fi
lem_keys "$session" s /
lem_keys "$session" q

lem_keys "$session" C-x C-b
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'sort-'
if lem_wait_for "$session" 'sort-[[:space:]]' 15 >/dev/null; then
  lem_keys "$session" Enter
  filter=$(report_filter || true)
  if [[ "$filter" == FILTER\ stack=name=sort-* ]]; then
    pass filter-name-stack "accepted s n became a poppable name filter"
  else
    fail filter-name-stack "accepted s n was not on the filter stack: $filter"
  fi
  lem_keys "$session" m
  lem_keys "$session" d
  nav=$(report_nav || true)
  screen=$(lem_capture "$session")
  if [[ "$nav" == *'buffer-list-sort-zeta:>,buffer-list-sort-middle:D'* ]] &&
     grep -Eq '>[[:space:]]+.*buffer-list-sor' <<<"$screen" &&
     grep -Eq 'D[[:space:]]+.*buffer-list-sor' <<<"$screen"; then
    pass modal-marks "m and d rendered distinct Evil-Collection > and D marks"
  else
    fail modal-marks "ordinary/deletion marks diverged: $nav"
  fi

  lem_keys "$session" U
  nav=$(report_nav || true)
  if [[ "$nav" == *'marks=' ]]; then
    pass modal-unmark-all "U cleared ordinary and deletion marks"
  else
    fail modal-unmark-all "U retained marks: $nav"
  fi

  lem_keys "$session" g k
  lem_keys "$session" g k
  lem_keys "$session" m
  lem_keys "$session" g k
  lem_keys "$session" u
  nav=$(report_nav || true)
  if [[ "$nav" == *'marks=' ]]; then
    pass modal-unmark-forward "u cleared the current ordinary mark and advanced"
  else
    fail modal-unmark-forward "u retained the current ordinary mark: $nav"
  fi

  lem_keys "$session" t
  nav=$(report_nav || true)
  if [[ "$nav" == *'buffer-list-sort-zeta:>,buffer-list-sort-middle:>,buffer-list-sort-alpha:>'* ]]; then
    pass modal-toggle-marks "t marked every visible buffer"
  else
    fail modal-toggle-marks "t did not toggle all visible rows: $nav"
  fi

  lem_keys "$session" '~'
  nav=$(report_nav || true)
  if [[ "$nav" == *'marks=' ]]; then
    pass modal-toggle-clear "~ inverted the marked set back to empty"
  else
    fail modal-toggle-clear "~ retained marks: $nav"
  fi

  lem_keys "$session" s n
  tmux_cmd send-keys -t "$session" -l 'sort-'
  lem_wait_for "$session" 'sort-[[:space:]]' 15 >/dev/null ||
    fail modal-filter-cancel "s n did not re-enter literal filter input"
  lem_keys "$session" Escape
  sleep 0.3
  filter=$(report_filter || true)
  if [[ "$filter" == FILTER\ stack=name=sort-* ]] &&
     [[ "$filter" == *'buffer-list-sort-zeta'* ]] &&
     [[ "$filter" != *'buffer-list-zz-target.txt'* ]]; then
    pass modal-filter-cancel "Escape cancelled pending input without erasing the accepted stack"
  else
    fail modal-filter-cancel "Escape changed the accepted filter stack: $filter"
  fi
  lem_keys "$session" s /
else
  fail modal-marks "could not narrow to modal mark fixtures"
  lem_keys "$session" Escape
fi
lem_keys "$session" q

lem_keys "$session" C-x C-b
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'save-target'
if lem_wait_for "$session" 'buffer-list-save-target\.txt' 15 >/dev/null; then
  lem_keys "$session" Enter
  lem_keys "$session" m
  lem_keys "$session" S
  sleep 0.5
  if cmp -s "$LEM_YATH_BUFFER_LIST_SAVE_TARGET" <(printf 'SAVE ORIGINAL\nSAVE LOCAL\n'); then
    pass marked-save "m plus S saved the marked grouped entry"
  else
    fail marked-save "the marked file buffer was not saved exactly"
    od -An -tx1 "$LEM_YATH_BUFFER_LIST_SAVE_TARGET" 2>/dev/null || true
  fi
else
  fail marked-save "the save fixture did not survive grouped filtering"
fi
lem_keys "$session" Enter
lem_wait_for "$session" 'SAVE LOCAL' 15 >/dev/null ||
  fail marked-save-select "Return did not close the chooser on the saved buffer"

lem_keys "$session" C-x C-b
lem_keys "$session" s n
tmux_cmd send-keys -t "$session" -l 'kill-target'
sleep 0.6
screen=$(lem_capture "$session")
if (( $(grep -Fc 'buffer-list-kil...' <<<"$screen") >= 2 )); then
  lem_keys "$session" Enter
  lem_keys "$session" d
  lem_keys "$session" d
  lem_keys "$session" x
  sleep 0.5
  before=$(grep -c '^LIFECYCLE ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true)
  lem_keys "$session" F7
  attempts=0
  while ((attempts < 40)) &&
        (( $(grep -c '^LIFECYCLE ' "$LEM_YATH_BUFFER_LIST_REPORT" 2>/dev/null || true) <= before )); do
    sleep 0.25
    attempts=$((attempts + 1))
  done
  if grep -q '^LIFECYCLE save-modified=no kill-a=dead kill-b=dead$' "$LEM_YATH_BUFFER_LIST_REPORT"; then
    pass marked-kill "d plus x removed both deletion-marked entries and the stale filter snapshot"
  else
    fail marked-kill "marked entry deletion did not cleanly update the chooser snapshot"
  fi
else
  fail marked-kill "the kill fixtures did not survive grouped filtering"
fi

if ((failed)); then
  printf '\nBUFFER LIST TEST FAILED\n'
  exit 1
fi

printf '\nBUFFER LIST TEST PASSED\n'
