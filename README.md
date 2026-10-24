# herdr-agent-tabs

A herdr plugin that names each agent tab after the agent's status and topic:

```text
◔ Fix login bug      working
◉ Fix login bug      blocked (waiting on you)
● Fix login bug      done
○ Fix login bug      idle
```

It also publishes the topic, without the glyph, as the `topic` pane token, so
the sidebar can show it with `$topic`:

```toml
[ui.sidebar.agents]
rows = [["state_icon", "machine", "workspace", "$topic"], ["agent"]]
```

## Rules

- The topic is the agent's terminal title with spinner glyphs stripped, cut to
  `MAX_LEN` (28) on a word boundary. A title that only names the agent
  ("Claude Code") or the directory falls back to the agent kind (`claude`).
- In a tab with several agents, the focused agent names it, and the first
  agent does when focus is in another tab. Each agent still gets its own
  sidebar topic.
- Tabs without an agent keep herdr's name. When an agent leaves a tab, the
  glyph goes and the last topic stays.
- **Hand renames win.** A tab you rename keeps your name; only the glyph in
  front of it follows the agent. To hand it back:
  `herdr plugin action invoke herdr-agent-tabs.reset`.
- herdr fires no event when an agent retitles its terminal. A new topic shows
  on the next status change or focus change.

## Install

Needs herdr 0.9 or newer, bash, and jq.

```sh
herdr plugin install minerado/herdr-agent-tabs
```

Or, from a clone you want to edit:

```sh
herdr plugin link /path/to/herdr-agent-tabs
```

## Settings

All optional. Copy `config.example.sh` to
`~/.config/herdr-agent-tabs/config.sh` and change what you need:

- `MAX_LEN`: longest topic on a tab (default 28).
- `GLYPH_WORKING`, `GLYPH_BLOCKED`, `GLYPH_DONE`, `GLYPH_IDLE`: the status
  glyphs. Pick characters your terminal font has. A glyph the font lacks is
  drawn from a fallback font and can look smaller than the rest (`◐` does in
  JetBrains Mono, which is why working is `◔`).

State lives in `~/.local/state/herdr-agent-tabs/`.

## Test

```sh
bash tests/test.sh
```
