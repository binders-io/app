# Automations, links and the MCP server

Binders can drive other software, and other software can drive Binders. Three doors:

- **Rules** run a Shortcut, open a URL, run a script or call a web hook when you say a phrase, or when something happens
  in Binders. Settings → Automations.
- **`binders://` links** let anything that can open a link (Shortcuts, Raycast, Alfred, Keyboard Maestro, a script) add a
  to-do, add to the calendar, ask the knowledge base, or start dictation.
- **The MCP server** lets AI tools such as Claude Code and Claude Desktop search and ask your knowledge base, on this Mac.

None of it runs unless you set it up. A web hook sends its payload to the address you give it; everything else stays local.

## Rules

A rule is a trigger and an action.

**Triggers**

| Trigger | When it fires | `{text}` |
|---|---|---|
| A phrase, in Command Mode | Hold **fn ⌃** and say the phrase followed by the rest: "send to Things buy milk tomorrow" | What follows the phrase |
| Dictation inserted | Text was dictated into an app | The text |
| To-do added | You added a to-do by voice, link or MCP | The task |
| Promise noted | A promise or ask was found in something you wrote | The task |
| Meeting notes ready | A meeting finished and its notes were written | The notes |
| Writing captured | A message or mail you wrote was kept | The text, redacted |

**Actions**

| Action | What happens |
|---|---|
| Run a Shortcut | `shortcuts run <name>` with the rendered input as text (default `{text}`) |
| Open a URL | The template with placeholders filled in, percent-encoded, opened like a link |
| Run a script | `zsh -lc <command>`, with `BINDERS_TEXT`, `BINDERS_TITLE`, `BINDERS_WHEN`, `BINDERS_DATE`, `BINDERS_APP`, `BINDERS_BINDER`, `BINDERS_SUMMARY`, `BINDERS_LINK` and `BINDERS_EVENT` in the environment, and the text on standard input |
| Call a web hook | POST with `Content-Type: application/json`: the body template with placeholders escaped, or every field as JSON when the body is empty |

**Placeholders**

| Placeholder | Meaning |
|---|---|
| `{text}` | The whole thing, as said or as kept |
| `{title}` | The text with the time phrase taken off the end ("call Sam") |
| `{when}` | The time phrase, as said ("tomorrow at 3 pm"), or empty |
| `{date}` | That time in ISO 8601, local time, or empty |
| `{app}` | The app involved |
| `{binder}` | The binder's name |
| `{summary}` | Meeting notes, or the sentence a promise came from |
| `{link}` | A `binders://` link back to the item |
| `{event}` | The trigger's name |

**Examples**

- *Things:* phrase "send to things", open URL `things:///add?title={title}&when={date}`.
- *Reminders:* event "To-do added", run the Shortcut "Add Reminder" with input `{title}`, where the Shortcut adds its input
  to Reminders. Binders' board and Reminders then stay in step.
- *Notion, Obsidian, anything:* event "Meeting notes ready", run a Shortcut with input `{title}\n\n{summary}\n\n{link}`.
- *n8n, Home Assistant, Zapier:* event "Promise noted", call a web hook; leave the body empty to send every field.
- *A log:* phrase "log", run the script `echo "$(date +%F) $BINDERS_TEXT" >> ~/log.txt`.

Rules are kept in `automations.json` in the data folder (Settings → Privacy → Open data folder), so you can read, version
and share them:

```json
[
  {
    "action": { "openURL": { "template": "things:///add?title={title}&when={date}" } },
    "id": "8C1D…",
    "isEnabled": true,
    "name": "Send to Things",
    "trigger": { "phrase": { "text": "send to things" } }
  }
]
```

"Test with sample text" in the editor runs the rule with a sample payload, so you can see what your Shortcut or hook
receives before saying anything.

## Links: `binders://`

| Link | Does |
|---|---|
| `binders://todo?text=call%20Sam%20tomorrow` | Adds a to-do; a time at the end becomes its due date |
| `binders://calendar?text=lunch%20with%20Sam%20tomorrow%20at%20noon` | Adds a calendar event |
| `binders://ask?q=what%20did%20we%20decide%20about%20pricing` | Opens Knowledge with the question |
| `binders://dictate` | Starts hands-free dictation, or finishes it |
| `binders://command` | The same, in Command Mode |
| `binders://capture/on`, `/off`, `/toggle` | Writing capture |
| `binders://meeting/start`, `/stop`, `/toggle` | Meeting notes |
| `binders://meeting/<id>` | Opens that meeting |
| `binders://open?section=home\|writing\|knowledge\|settings&page=automations` | Opens the window there |

Text goes in the query, percent-encoded. From a shell: `open "binders://todo?text=call%20Sam"`.

## The MCP server

`Binders --mcp` speaks the [Model Context Protocol](https://modelcontextprotocol.io) over standard input and output, the
transport every host supports. It reads the same database the app does, and runs only while the host that started it is
connected. Nothing leaves the Mac; the host is on this Mac too.

**Claude Code**

```
claude mcp add binders -- /Applications/Binders.app/Contents/MacOS/Binders --mcp
```

**Claude Desktop** and other hosts that take a JSON configuration:

```json
{ "mcpServers": { "binders": { "command": "/Applications/Binders.app/Contents/MacOS/Binders", "args": ["--mcp"] } } }
```

Settings → Automations → MCP server has both, with the path of the copy you are running, and a copy button.

**Tools**

| Tool | Returns |
|---|---|
| `search_knowledge` (query, limit, kind) | The best-matching passages across meetings, notes, dictations and captured writing, by keywords and meaning |
| `ask_knowledge` (question) | A written answer with the passages it drew on. Uses your local language model, so it takes a few seconds |
| `list_binders` | Your binders with their counts |
| `list_meetings` (limit, binder) · `get_meeting` (id, include_transcript) | Meetings, and one in full |
| `list_notes` (limit, binder) · `get_note` (id) | Notes, and one in full |
| `list_todos` (status) | Promises, asks and to-dos |
| `recent_dictations` (limit) | What you dictated lately |
| `add_to_knowledge` (title, text, source, binder) | Anything worth remembering: a fact, a document's text, a web page, an email. Kept under the title with its source, so search and answers can cite it |
| `add_note` (text, binder) · `append_to_note` (id, text) | A new note, with its first line as title; or more text at the end of one |
| `create_binder` (name) | A new binder, or the existing one's id if the name is taken |
| `add_meeting` (title, notes, date, attendees, duration_minutes, app, binder) | A meeting that happened elsewhere, from its notes or transcript, so it is searchable with the rest |
| `add_todo` (text) · `set_todo_status` (id, status) | A to-do, with a time at the end as its due date; done, open or dismissed |
| `add_to_calendar` (text) | An event from a phrase such as "lunch with Sam tomorrow at noon" |

Reads go straight to the database. Writes are handed to the running app, which does them and answers with the new
item's id, so its windows update, reminders get scheduled and the index picks the item up within seconds; if the app
isn't running, macOS launches it. Nothing can be deleted this way.

Dates are ISO 8601 in local time. Try it by hand:

```
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | /Applications/Binders.app/Contents/MacOS/Binders --mcp
```
