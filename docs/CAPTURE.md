# Capturing what you send AI tools in the terminal

While writing capture is on, Binders keeps the prompts you send AI tools in the terminal (or an editor), the way it keeps
the messages you write in Mail or Teams: redacted, in the open binder, searchable in Knowledge. It reads what each tool
records itself. The terminal's screen and command output are never read, pasted blocks aren't kept, shell commands
(`!git …`) and bare slash commands are left out, and so are replies under three words.

Settings → Writing capture → In the terminal lists the tools and turns each on or off.

## Tools Binders knows

| Tool | Where it keeps your prompts |
| --- | --- |
| Claude Code | `~/.claude/history.jsonl` |
| Codex | `~/.codex/history.jsonl` |
| Gemini CLI | `~/.gemini/tmp/<project>/logs.json` |
| Qwen Code | `~/.qwen/tmp/<project>/logs.json` |
| GitHub Copilot CLI | `~/.copilot/command-history-state.json` |
| OpenCode | `~/.local/share/opencode/opencode.db` |

## Another tool, described

A tool that writes your prompts somewhere can be added without a new Binders: describe it in
`~/Library/Application Support/Binders/agent-harnesses.json` (Settings → Add a Tool… makes the file with an example). The
file is an array; an entry with the same `id` as a built-in one replaces it.

```json
[
  {
    "id": "mytool",
    "name": "My Tool",
    "format": "jsonl",
    "path": "~/.mytool/history.jsonl",
    "text": "prompt",
    "time": "timestamp",
    "timeUnit": "ms",
    "project": "cwd"
  }
]
```

- `format`: `jsonl` (one JSON object per line, added at the end), `json` (one file, rewritten; `items` is the dotted path
  to the array of prompts, empty when the file is the array), or `sqlite` (`query` returns rows of id, text, time in
  milliseconds and project, newer than `:since`).
- `path`: `~` is your home folder; `*` stands for any one folder.
- `text`, `time`, `project`: dotted paths to the prompt's words, its time and its folder in each item. Without `text`, the
  item itself is the words.
- `timeUnit`: `ms`, `s` or `iso`.
- `match`: only items whose dotted paths have these values, such as `{"type": "user"}` for a log that also holds replies.

## Another tool, through its hook

A tool that runs a command when you send a prompt can hand the prompt to Binders:

```sh
"/Applications/Binders.app/Contents/MacOS/Binders" --capture-prompt --tool "Cursor"
```

The prompt comes on stdin, as the tool's JSON (`prompt`, `text` or `message`, with `cwd` or `workspace_roots` for the
folder) or as plain words. The command prints nothing and always succeeds, so it never holds the tool up, and it keeps
nothing while capture is off. For Cursor, in `~/.cursor/hooks.json`:

```json
{ "version": 1, "hooks": { "beforeSubmitPrompt": [ { "command": "\"/Applications/Binders.app/Contents/MacOS/Binders\" --capture-prompt --tool Cursor" } ] } }
```
