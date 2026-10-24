#!/usr/bin/env bash
# herdr-agent-tabs: name each agent tab "<status glyph> <agent topic>" and
# publish the topic as the `topic` pane token, which the sidebar shows as $topic.
#
#   agent-tabs.sh <event>   reconcile every tab (any herdr event, or startup)
#   agent-tabs.sh reset     hand the current tab back to automatic naming
#
# Every run is one idempotent pass: read one snapshot, work out every label,
# rename only the tabs that are wrong. Needs bash and jq.
set -u

HERDR=${HERDR_BIN_PATH:-herdr}
CONFIG=${AT_CONFIG:-${XDG_CONFIG_HOME:-$HOME/.config}/herdr-agent-tabs/config.sh}
STATE_DIR=${AT_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/herdr-agent-tabs}
STATE_FILE=$STATE_DIR/state.json
SOURCE=herdr-agent-tabs

# Defaults; config.sh overrides any of them (see config.example.sh).
MAX_LEN=28
GLYPH_WORKING="◔"
GLYPH_BLOCKED="◉"
GLYPH_DONE="●"
GLYPH_IDLE="○"
# shellcheck source=/dev/null
[ -f "$CONFIG" ] && . "$CONFIG"

# The whole decision, as one jq program over the snapshot. Pure: it reads the
# snapshot and the state, and prints a plan for the shell to carry out.
#
# Ownership ("hand renames win"): herdr has no auto/manual flag, so the state
# records the label this plugin last set on each tab. A tab is ours while its
# label still matches that record. A new tab is ours while it carries herdr's
# default label, a bare number. Anything else was typed by a person: the tab
# keeps that name until `reset`, and only the status glyph in front of it moves.
# shellcheck disable=SC2016
AT_JQ='
def clean: (. // "") | tostring | gsub("[[:cntrl:]]"; " ");

# Terminal title -> task: drop the spinner/status glyphs agents park at either
# end, and squeeze whitespace.
def task: clean
  | sub("^[^[:alnum:]]+"; "")
  | sub("([[:space:]]+[^[:alnum:][:space:][:ascii:]]+)*[[:space:]]*$"; "")
  | gsub("[[:space:]]+"; " ");

# Cut to $n characters on a word boundary; a lone overlong word is cut mid-word.
def fit($n):
  if length <= $n then .
  elif .[$n:$n+1] == " " then .[:$n]
  else .[:$n] as $c | ($c | sub("[[:space:]]+[^[:space:]]*$"; "")) as $w
    | if $w == $c or $w == "" then $c else $w end
  end
  | sub("[[:space:],.;:-]+$"; "");

# What an agent pane says it is working on, or "" when its title only names the
# agent, the directory, or herdr default number.
def topic:
  (.terminal_title_stripped // .terminal_title | task) as $t
  | ($t | ascii_downcase) as $l
  | (.agent | clean | ascii_downcase) as $k
  | ((.foreground_cwd // .cwd) | clean | rtrimstr("/") | split("/") | last // ""
     | ascii_downcase) as $d
  | if $t == "" or ($t | test("^[0-9]+$")) or $l == $k or $l == "\($k) code"
       or $l == $d or ($t | test("^[^[:space:]]*/[^[:space:]]*$"))
    then "" else $t | fit(80) end;

# The configured glyphs plus the defaults, so switching glyph sets never stacks
# an old glyph behind a new one on a hand-named tab.
def glyphs: [$glyph[], "◔", "◐", "◉", "●", "○"] | map(select(. != "")) | unique;
def unglyph: . as $l
  | (first(glyphs[] as $g | $l | select(startswith($g + " ")) | .[($g | length) + 1:])
     // $l);

(.result.snapshot // .result // .) as $s
| [($s.panes // [])[] | select((.agent // "") != "")] as $agents
| ($s.focused_pane_id // "") as $fp
| [ ($s.tabs // [])[] | . as $t
    | ($t.label | clean) as $cur
    | ($agents | map(select(.tab_id == $t.tab_id))) as $ap
    | (($ap | map(select(.pane_id == $fp))) + $ap | first) as $p
    | (if ($resets | index($t.tab_id)) then {owned: true, label: $cur}
       else $state.tabs[$t.tab_id] end) as $rec
    | (if $rec == null then ($cur | test("^[0-9]+$"))
       else $rec.owned and $rec.label == $cur end) as $owned
    | ($cur | unglyph) as $hand
    | (if $p == null then $hand
       else (if $owned | not then $hand
             else ($p | topic) as $tp | if $tp == "" then $p.agent | clean else $tp end
               | fit($max) end) as $base
         | ($glyph[$t.agent_status // ""] // "") as $g
         | if $g == "" or $base == "" then $base else "\($g) \($base)" end
       end) as $want
    | {tab: $t.tab_id, cur: $cur, owned: $owned,
       want: (if $want == "" then $cur else $want end)} ]
| . as $tabs
| { renames: [$tabs[] | select(.want != .cur) | {tab, want, cur}],
    state: {tabs: ($tabs | map({key: .tab, value: {owned, label: .want}}) | from_entries)},
    topics: [$agents[] | {pane: .pane_id, agent: (.agent | clean), want: topic,
                          have: (.tokens.topic | clean)} | select(.want != .have)] }
'

at_glyphs() {
  jq -nc --arg w "$GLYPH_WORKING" --arg b "$GLYPH_BLOCKED" --arg d "$GLYPH_DONE" \
    --arg i "$GLYPH_IDLE" '{working: $w, blocked: $b, done: $d, idle: $i}'
}

# at_plan <snapshot> <state> <resets JSON array> -> plan JSON
at_plan() {
  jq -c --argjson state "$2" --argjson resets "$3" --argjson glyph "$(at_glyphs)" \
    --argjson max "$MAX_LEN" "$AT_JQ" <<<"$1"
}

at_reconcile() {
  local snap state plan resets="[]" f tab want cur pane agent topic failed="[]"
  snap=$("$HERDR" api snapshot 2>/dev/null) || return 0
  state=$(cat "$STATE_FILE" 2>/dev/null)
  jq -e 'type == "object"' <<<"$state" >/dev/null 2>&1 || state='{}'
  for f in "$STATE_DIR"/reset.*; do
    [ -e "$f" ] || continue
    resets=$(jq -c --arg t "$(cat "$f")" '. + [$t]' <<<"$resets")
    rm -f "$f"
  done
  plan=$(at_plan "$snap" "$state" "$resets") || return 0

  # Fields are joined with the unit separator: labels are free text, and
  # control characters were already removed from them by `clean`.
  while IFS=$'\x1f' read -r tab want cur; do
    [ -n "$tab" ] || continue
    "$HERDR" tab rename "$tab" "$want" >/dev/null 2>&1 ||
      failed=$(jq -c --arg t "$tab" --arg c "$cur" '. + [{tab: $t, cur: $c}]' <<<"$failed")
  done < <(jq -r '.renames[] | [.tab, .want, .cur] | join("\u001f")' <<<"$plan")

  while IFS=$'\x1f' read -r pane agent topic; do
    [ -n "$pane" ] || continue
    if [ -n "$topic" ]; then
      "$HERDR" pane report-metadata "$pane" --source "$SOURCE" --agent "$agent" \
        --token "topic=$topic" >/dev/null 2>&1 || true
    else
      "$HERDR" pane report-metadata "$pane" --source "$SOURCE" \
        --clear-token topic >/dev/null 2>&1 || true
    fi
  done < <(jq -r '.topics[] | [.pane, .agent, .want] | join("\u001f")' <<<"$plan")

  # Record only what landed: a failed rename keeps the label herdr still shows,
  # or the next pass would read it as a hand rename.
  jq --argjson failed "$failed" \
    '.state | reduce $failed[] as $f (.; .tabs[$f.tab].label = $f.cur)' \
    <<<"$plan" >"$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
}

# One worker per burst of events. A run that finds the lock taken leaves the
# rerun flag for the holder, which loops until the flag stays gone. The flag is
# set before the lock is tried, so the holder always sees it after releasing.
at_run() {
  local lock=$STATE_DIR/lock rerun=$STATE_DIR/rerun
  mkdir -p "$STATE_DIR"
  touch "$rerun"
  while [ -e "$rerun" ]; do
    if ! mkdir "$lock" 2>/dev/null; then
      # A lock older than a minute belongs to a run that died.
      if [ -n "$(find "$lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]; then
        rmdir "$lock" 2>/dev/null
        continue
      fi
      return 0
    fi
    while rm "$rerun" 2>/dev/null; do at_reconcile; done
    rmdir "$lock"
  done
}

at_main() {
  case "${1:-}" in
  reset)
    local tab=${HERDR_TAB_ID:-}
    [ -n "$tab" ] || tab=$("$HERDR" api snapshot 2>/dev/null |
      jq -r '(.result.snapshot // .result // .).focused_tab_id // empty')
    [ -n "$tab" ] || return 0
    mkdir -p "$STATE_DIR"
    printf '%s' "$tab" >"$STATE_DIR/reset.$$"
    at_run
    ;;
  *) at_run ;;
  esac
}

# Sourced by the tests; executed by herdr.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then at_main "$@"; fi
