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
- In a tab with several agents, the focused agent names it.
- Tabs without an agent keep herdr's name. When an agent leaves a tab, the
  glyph goes and the last topic stays.
- **Hand renames win.** A tab you rename keeps your name; only the glyph in
  front of it follows the agent. To hand it back:
  `herdr plugin action invoke herdr-agent-tabs.reset`.
- herdr fires no event when an agent retitles its terminal. A new topic shows
  on the next status change or focus change.

## Install

```sh
herdr plugin link ~/code/herdr-agent-tabs
```

Settings: copy `config.example.sh` to `~/.config/herdr-agent-tabs/config.sh`.
State lives in `~/.local/state/herdr-agent-tabs/`. Needs bash and jq.

## Test

```sh
bash tests/test.sh
```
