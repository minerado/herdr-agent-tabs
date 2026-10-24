#!/usr/bin/env bash
# Runs agent-tabs.sh against a fake herdr: it serves $MOCK_SNAP and logs every
# write to $MOCK_LOG. Run with `bash tests/test.sh`.
set -u
here=$(cd "$(dirname "$0")" && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/herdr" <<'EOF'
#!/usr/bin/env bash
case "$1 $2" in
"api snapshot") cat "$MOCK_SNAP" ;;
"tab rename") [ "$3" = "${MOCK_FAIL_TAB:-}" ] && exit 1; echo "rename $3 ${*:4}" >>"$MOCK_LOG" ;;
"pane report-metadata") echo "meta ${*:3}" >>"$MOCK_LOG" ;;
esac
EOF
chmod +x "$tmp/herdr"

export HERDR_BIN_PATH=$tmp/herdr AT_CONFIG=/nonexistent AT_STATE_DIR=$tmp/state
export MOCK_SNAP=$tmp/snap.json MOCK_LOG=$tmp/log
unset HERDR_TAB_ID

pass=0 fail=0
check() { # check <name> <expected> <actual>
  if [ "$2" = "$3" ]; then pass=$((pass + 1))
  else fail=$((fail + 1)); printf 'FAIL %s\n  want: %s\n  got:  %s\n' "$1" "$2" "$3"; fi
}

# snap <tabs JSON> <panes JSON> [focused pane]
snap() {
  jq -n --argjson t "$1" --argjson p "$2" --arg f "${3:-}" \
    '{result: {snapshot: {tabs: $t, panes: $p, focused_pane_id: $f}}}' >"$MOCK_SNAP"
}
tab() { printf '{"tab_id":"%s","label":"%s","agent_status":"%s"}' "$@"; }
agent() { # agent <pane> <tab> <title> [topic token]
  jq -nc --arg p "$1" --arg t "$2" --arg ti "$3" --arg tok "${4:-}" \
    '{pane_id: $p, tab_id: $t, agent: "claude", terminal_title_stripped: $ti,
      cwd: "/home/u/Work", tokens: (if $tok == "" then null else {topic: $tok} end)}'
}
run() { : >"$MOCK_LOG"; bash "$here/../agent-tabs.sh" "${1:-test}"; }
log() { cat "$MOCK_LOG"; }

# --- 1. a new agent tab gets glyph + topic, and its pane the topic token
snap "[$(tab t1 1 working)]" "[$(agent p1 t1 'Fix login bug')]"
run
check "new tab named" "rename t1 ◔ Fix login bug
meta p1 --source herdr-agent-tabs --agent claude --token topic=Fix login bug" "$(log)"

# --- 2. a second pass with nothing changed writes nothing
snap "[$(tab t1 '◔ Fix login bug' working)]" "[$(agent p1 t1 'Fix login bug' 'Fix login bug')]"
run
check "idempotent" "" "$(log)"

# --- 3. a status change swaps only the glyph
snap "[$(tab t1 '◔ Fix login bug' done)]" "[$(agent p1 t1 'Fix login bug' 'Fix login bug')]"
run
check "status swap" "rename t1 ● Fix login bug" "$(log)"

# --- 4. a hand rename keeps its name and gains the glyph; only the glyph moves
snap "[$(tab t1 'my name' working)]" "[$(agent p1 t1 'Fix login bug' 'Fix login bug')]"
run
check "hand rename gets glyph" "rename t1 ◔ my name" "$(log)"
snap "[$(tab t1 '◔ my name' working)]" "[$(agent p1 t1 'Other topic' 'Fix login bug')]"
run
check "hand name survives a new topic" "meta p1 --source herdr-agent-tabs --agent claude --token topic=Other topic" "$(log)"
snap "[$(tab t1 '◔ my name' done)]" "[$(agent p1 t1 'Fix login bug' 'Fix login bug')]"
run
check "hand name glyph swap" "rename t1 ● my name" "$(log)"

# --- 5. reset hands it back
export HERDR_TAB_ID=t1
run reset
unset HERDR_TAB_ID
check "reset" "rename t1 ● Fix login bug" "$(log)"

# --- 6. a custom label the plugin never set keeps its name, glyph added
snap "[$(tab t2 'notes' idle)]" "[$(agent p2 t2 'Write docs')]"
run
check "unknown custom label kept" "rename t2 ○ notes
meta p2 --source herdr-agent-tabs --agent claude --token topic=Write docs" "$(log)"

# --- 7. titles that only name the agent or directory fall back to the agent kind
for t in "Claude Code" "claude" "Work" "~/Work" "12"; do
  rm -rf "$AT_STATE_DIR"
  snap "[$(tab t3 3 idle)]" "[$(agent p3 t3 "$t")]"
  run
  check "generic title [$t]" "rename t3 ○ claude" "$(log)"
done

# --- 8. long topics are cut on a word boundary; the token keeps 80 chars
rm -rf "$AT_STATE_DIR"
snap "[$(tab t4 4 idle)]" "[$(agent p4 t4 'Obsidian Cursor folder skill collection')]"
run
check "word cut" "rename t4 ○ Obsidian Cursor folder skill" "$(log | head -1)"
snap "[$(tab t4 4 idle)]" "[$(agent p4 t4 'Obsidian Cursor folders skill collection')]"
rm -rf "$AT_STATE_DIR"; run
check "word cut mid-word" "rename t4 ○ Obsidian Cursor folders" "$(log | head -1)"

# --- 9. the agent leaving an owned tab drops the glyph, keeps the name
rm -rf "$AT_STATE_DIR"
snap "[$(tab t5 5 working)]" "[$(agent p5 t5 'Deploy fix')]"
run
snap "[$(tab t5 '◔ Deploy fix' unknown)]" "[]"
run
check "agent gone" "rename t5 Deploy fix" "$(log)"

# --- 10. plain shell tabs keep herdr's name
rm -rf "$AT_STATE_DIR"
snap "[$(tab t6 zsh unknown)]" "[]"
run
check "shell tab untouched" "" "$(log)"

# --- 11. a failed rename does not opt the tab out
rm -rf "$AT_STATE_DIR"
snap "[$(tab t7 7 idle)]" "[$(agent p7 t7 'Ship it' 'Ship it')]"
MOCK_FAIL_TAB=t7 run
run
check "retry after failed rename" "rename t7 ○ Ship it" "$(log)"

# --- 12. the focused agent pane names a two-agent tab; topics go to each pane
rm -rf "$AT_STATE_DIR"
snap "[$(tab t8 8 working)]" "[$(agent p8 t8 'First task'),$(agent p9 t8 'Second task')]" p9
run
check "focused pane wins" "rename t8 ◔ Second task" "$(log | head -1)"
check "both topics" "2" "$(grep -c '^meta' "$MOCK_LOG")"

# --- 13. spinner glyphs on either end of the title are stripped
rm -rf "$AT_STATE_DIR"
snap "[$(tab t9 9 working)]" "[$(agent p9 t9 '✳ Refactor auth ⠋')]"
run
check "spinners stripped" "rename t9 ◔ Refactor auth" "$(log | head -1)"

# --- 14. closed tabs leave the state
snap "[]" "[]"
run
check "state pruned" "{}" "$(jq -c .tabs "$AT_STATE_DIR/state.json")"

# --- 15. a restart renumbers tabs: owned and hand-named tabs are found by label
rm -rf "$AT_STATE_DIR"
snap "[$(tab t1 1 working),$(tab t2 'mine' working)]" \
  "[$(agent p1 t1 'Fix login bug' 'Fix login bug'),$(agent p2 t2 'Other' 'Other')]"
run
snap "[$(tab tA '◔ Fix login bug' idle),$(tab tB '◔ mine' idle)]" \
  "[$(agent pA tA 'New topic' 'New topic'),$(agent pB tB 'Other' 'Other')]"
run
check "restart keeps ownership" "rename tA ○ New topic
rename tB ○ mine" "$(log)"

# --- 16. a slash inside a topic is not a path; a path still is
rm -rf "$AT_STATE_DIR"
snap "[$(tab t1 1 idle)]" "[$(agent p1 t1 'Fix CI/CD pipeline')]"
run
check "slash topic kept" "rename t1 ○ Fix CI/CD pipeline" "$(log | head -1)"
rm -rf "$AT_STATE_DIR"
snap "[$(tab t1 1 idle)]" "[$(agent p1 t1 '~/code/api')]"
run
check "path refused" "rename t1 ○ claude" "$(log)"

# --- 17. a reply without a tab list changes nothing and keeps the state
before=$(cat "$AT_STATE_DIR/state.json")
echo '{"result":{"snapshot":{}}}' >"$MOCK_SNAP"
run
check "bad snapshot no writes" "" "$(log)"
check "bad snapshot keeps state" "$before" "$(cat "$AT_STATE_DIR/state.json")"

echo "$pass passed, $fail failed"
[ "$fail" = 0 ]
