# Automations, links and the MCP server

Binders can drive other software, and other software can drive Binders. Three doors:

- **Rules** run a Shortcut, open a URL, run a script or call a web hook when you say a phrase, or when something happens
  in Binders. Settings → Automations.
- **`binders://` links** let anything that can open a link (Shortcuts, Raycast, Alfred, Keyboard Maestro, a script) add a
  to-do, add to the calendar, ask the knowledge base, or start dictation.
- **The MCP server** lets AI tools such as Claude Code and Claude Desktop search and ask your knowledge base, and pick up
  work from your binders' boards, on this Mac.

None of it runs unless you set it up. A web hook sends its payload to the address you give it; everything else stays local.

## Rules

A rule is a trigger and an action.

**Triggers**

| Trigger | When it fires | `{text}` |
|---|---|---|
| A phrase, in Command Mode | Hold **fn ⌃** and say the phrase followed by the rest: "send to Things buy milk tomorrow" | What follows the phrase |
| Dictation inserted | Text was dictated into an app | The text |
| To-do added | You added a to-do: in Command Mode, in the iPhone app, or with Add on a suggestion. With the rule's "Also for…" option on, also a to-do said to yourself ("Binders, …", Tell Binders), one from an agent or tool, and one from a `binders://todo` link | The task |
| Promise noted | A promise or ask was found in something you wrote | The task |
| Meeting notes ready | A meeting finished and its notes were written | The notes |
| Writing captured | A message or mail you wrote was kept | The text, redacted |

**Actions**

| Action | What happens |
|---|---|
| Run a Shortcut | `shortcuts run <name>` with the rendered input as text (default `{text}`) |
| Open a URL | The template with placeholders filled in and opened like a link. Placeholders go only in the query's values, encoded strictly (everything but letters, digits, `-`, `_` and `~`, so `.` and `/` too), so what a to-do or a binder says can't change what the link opens. A template with a placeholder in its scheme, address, path, a parameter's name or after `#`, or without a scheme, is refused in the editor, and a rule like that saved earlier is refused when it runs |
| Run a script | `zsh -lc <command>`, with `BINDERS_TEXT`, `BINDERS_TITLE`, `BINDERS_WHEN`, `BINDERS_DATE`, `BINDERS_APP`, `BINDERS_BINDER`, `BINDERS_SUMMARY`, `BINDERS_LINK` and `BINDERS_EVENT` in the environment (and `BINDERS_TODO_ORIGIN` for a to-do), and the text on standard input |
| Call a web hook | POST with `Content-Type: application/json`: the body template with placeholders escaped, or every field as JSON when the body is empty (with `todo_origin` for a to-do). A token, typed in the editor, is kept in your Keychain, never in automations.json, and goes as `Authorization: Bearer`, only to the address the rule was saved with: a rule whose address changed outside Settings sends nothing ("Not sent: its address isn't the one you saved it with…") until it's saved again. Deleting the rule or changing its action removes the token |

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
| `{todo_origin}` | Where a to-do came from: `voice` (Command Mode, and every to-do made before origins were kept), `phone`, `suggestion`, `moment` (said to yourself), `agent` or `link` |

A "To-do added" rule runs for to-dos you made. **Also for to-dos said to yourself, from agents and from links**, off
unless you turn it on for that rule, lets it run for the rest too. Nothing heard on your iPhone, and not tapped, runs a
rule without that choice, and a kind of to-do added at once by graduation runs none.

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
| `binders://dictate` | Starts hands-free dictation, after asking you, or finishes it |
| `binders://command` | The same, in Command Mode |
| `binders://capture/on`, `/off`, `/toggle` | Writing capture. Turning it on asks you first |
| `binders://meeting/start`, `/stop`, `/toggle` | Meeting notes. Starting a recording asks you first |
| `binders://meeting/<id>` | Opens that meeting |
| `binders://card/<id>` | Opens that card in its own window, without bringing Binders forward (the `BINDERS_LINK` a woken agent gets), or Home with a note when it's gone |
| `binders://note/<id>` (or `binders://note?id=<id>`) | Opens that note in its binder, or says it's gone. A card made with Put on Board links back to its note this way |
| `binders://open?section=home\|writing\|knowledge\|settings&page=automations` | Opens the window there |

Text goes in the query, percent-encoded. From a shell: `open "binders://todo?text=call%20Sam"`.

## The MCP server

`Binders --mcp` speaks the [Model Context Protocol](https://modelcontextprotocol.io) over standard input and output, the
transport every host supports. It reads the same database the app does, and runs only while the host that started it is
connected. The server stays on this Mac, but what a host reads goes wherever that host sends it, usually to its own AI
model.

Captures (what All-day capture heard), meeting transcripts and teammates' items are left out for every host until you
allow them for it in Settings → MCP → What each tool can read. Those choices are kept in the Keychain, so nothing but
Binders changes them. Cards and to-dos made from a capture, or from something you said to yourself near your iPhone,
count as captures: a host that may not read captures doesn't see them, unless you meant the card for it. The board tools work
the same otherwise.

A run Binders starts for a card (Claude Code, Codex, OpenCode, GitHub Copilot CLI or Antigravity) gets the board tools only, for
that card only, and acts as exactly the agent it woke: it lists only its card, can't read or take another, and makes no
new cards. Every such run's server has `BINDERS_TOOLS=board`, `BINDERS_RUN=1`, `BINDERS_CARD` and `BINDERS_AGENT` as
literal values in that run's own server entry. `BINDERS_RUN` says Binders started it, so a server that didn't get a
card's id or an agent's name offers no tools at all; `BINDERS_TOOLS` stays `board` because an earlier Binders (one
put back in its place while a run goes on, say) reads any other value as your own host, and with `board` still
keeps a run to its card's board tools.
Claude Code gets the server through `--strict-mcp-config --mcp-config`; Codex through `-c mcp_servers.binders.*`
overrides, with `--ignore-user-config`; OpenCode through `OPENCODE_CONFIG_CONTENT`; GitHub Copilot CLI through
`--additional-mcp-config` with a file in the run's folder, and a Copilot settings folder of Binders' own; Antigravity
through a `.agents/mcp_config.json` Binders writes in the run's worktree, whose `binders` entry stands in for any of
yours, and takes out again when the run ends, before anything is committed. None of your own config files for these
tools is changed. Claude Code's settings carry Stop and SessionEnd hooks that run Binders' own
`--agent-hook stop` and `--agent-hook session-end`, with the card and agent taken from the run's environment, so what the
run said last goes on the card once. On a Mac whose organization manages Claude Code's MCP servers (a `managed-mcp.json`),
or once Claude Code has refused `--strict-mcp-config` there, a run starts without it, and a `--agent-hook pre-tool` hook
lets it use Binders' board tools and nothing else. When those settings keep Binders' server out of a run altogether, the
card says so and what you can do instead: ask whoever manages the Mac to allow Binders' server, post the card to a Claude
Code session you have open, or wake the agent with a command. The others have no such hooks: Binders reads the run's own JSON output when it
ends, and puts what it said last on the card once. Each of their runs leaves a record beside its log, so a run that
outlives Binders (a quit, a crash, an update) is taken up again when Binders opens, and its end still happens once. A run
that fails or is stopped leaves its card in Blocked with why, and your answer sends it back to work. While the card is in
progress, the card shows what the run is doing: the task it's on from Claude Code's own task list, or the plan in the
other tools' own output (read at most every 30 seconds in each Binders process, kept only on screen).

**A run's permissions.** Binders starts Claude Code with nobody there to answer its permission questions, so its
**Permissions** setting decides what happens to each one. **Auto** (the default for a new agent) lets Claude Code's own
reviewer answer them, so a run can use the web or read a file outside its worktree when that looks safe, and is refused
when it doesn't. **Edits files in its worktree**, **Plans only** and **Only what's allowed** refuse anything that would
have asked. In every mode Binders' deny list (no `git push`, `open`, `~/.ssh`, your other keys and sign-ins, the coding
tools' own sign-ins and sessions, Binders' data or your team folder) and the sandbox (its commands reach only the sites
you list) still hold. A run in auto mode that stops before it takes the card says so on the card, in case your Claude
Code doesn't offer auto mode.

**Codex, OpenCode, GitHub Copilot CLI and Antigravity.** Binders starts each one for a card in a git worktree it makes for that card
and tool, `~/.binders/worktrees/<repository>-<hash>/binders-<card>-<tool>` on the branch `binders-card-<card>-<tool>`,
from the commit you have checked out; a card that moves to another tool gets a worktree of its own, so no tool starts in
a folder another tool wrote. Binders never touches your checkout (no checkout, reset, stash, add or commit there) and
never runs `git worktree prune`. When a run stops, Binders commits what it changed on that branch, as you, unsigned,
with hooks, fsmonitor and submodule recursion off and the worktree's git folder named from Binders' own record. It
refuses the commit, and says why on the card, when the run made a git repository inside the worktree, added a link to
another repository, changed more than 2,000 files or 100 MB, deleted more than half the branch's files, or rewrote the
worktree's `.git` file. Worktrees and their branches stay until you remove them (`git worktree remove <path>`). Each
agent runs in one of two modes: **Edits files in its worktree** (the default) or **Plans only**, which Antigravity
doesn't have.
- **Codex** runs in its own sandbox, set for the run by a permission profile: it writes only to its worktree, its own
  temp folder and `/tmp` (Codex's own default), and its commands reach nothing on the network. They can't read Codex's
  own folder (`~/.codex`, but for its packaged tools in `~/.codex/packages`), `~/.claude`, or the worktrees Claude Code
  keeps for other cards in the repository's `.claude/worktrees`. It loads neither your Codex settings, rules, hooks,
  plugins and apps nor your shell profile. Binders won't start it on a Mac with Codex settings from an administrator
  (anything in `/etc/codex`, whose rules and hooks would load even so, or a managed profile).
- **OpenCode** and **GitHub Copilot CLI 1.0.10** have no sandbox, so their runs get no shell and no web at all: they read
  and edit files in the worktree and use the board tools. OpenCode runs under an agent named for that run, without the
  repository's own OpenCode settings or any plugins, and denied everything outside its worktree. OpenCode checks a path
  by its text and follows a link in it, so Binders won't start it in a worktree with a link that leads outside it, and
  says which on the card. Copilot runs with
  `--deny-tool=shell`, its own path checks and a settings folder of Binders' own (`~/.binders/copilot`), set back to
  safe values before every run. Its `task` and `lsp` tools are off (`--excluded-tools`), since a custom agent's own MCP
  servers and a language server set up in the repository would start outside every permission rule.
- **Antigravity** (`agy`, which took over from Gemini CLI) starts as `agy --input-format stream-json --output-format
  stream-json --sandbox --mode accept-edits --disable-slash-commands`, with `--model` when you set one and
  `--conversation` to carry on the card's last conversation; the prompt goes on standard input as one stream-json
  message, never in its arguments. It edits files in the worktree without asking and can't be held to reading only, so
  an Antigravity agent can't be saved as Plans only. Its commands run in its terminal sandbox, and only those your own
  allow rules allow: with no one there to approve, any other is refused, and the card names it ("Antigravity wasn't
  allowed to run `npm test`."). Binders can't set Antigravity's permissions for a run, so before each one, and before
  making a worktree, it reads `toolPermission` and `permissions.allow` in `~/.gemini/antigravity-cli/settings.json` and
  doesn't start the run, saying why on the card, when the file is missing or isn't plain JSON; when it doesn't allow
  `"mcp(binders/*)"` (a headless run refuses any MCP tool no rule allows, so it couldn't reach the board); when
  `toolPermission` is `always-proceed` or a preset Binders doesn't know; or when a rule writes outside the worktree,
  reads one of the private folders below (or a folder that holds one), or allows `read_url`, `execute_url`,
  `unsandboxed`, `mcp(*)` or another server's tools. So its runs reach nothing on the network and use no other MCP
  server's tools. Your own Antigravity hooks, plugins and MCP servers still load (Binders can't turn them off), but
  Binders won't start a run in a worktree whose `.agents` folder holds hooks, servers or plugins, or commit one that
  left them there, and refuses a repository that tracks its own `.agents/mcp_config.json`. Binders' rules keep a run's
  commands and allow rules away from the private folders below; whether Antigravity's own file tools ask before reading
  outside the worktree is Antigravity's to decide. A run uses the sign-in agy keeps in your keychain (run `agy` once in
  Terminal to sign in), and no API key reaches it. Binders never starts it with `--mode auto`, Antigravity's own mode
  in which another model approves its commands, or `--dangerously-skip-permissions`, and refuses a command agent
  ("A Command…") that runs `agy --mode auto`. The card's end line has the command to look in on the run
  (`cd <worktree> && agy --conversation <id>`).
- No run but Antigravity's (above) can read Binders' data, logs or team folder, `~/.ssh` or your other keys and sign-ins (`~/.gnupg`, `~/.netrc`,
  `~/.git-credentials`, `~/.npmrc`, `~/.pypirc`, `~/.aws`, `~/.azure`, `~/.config/gcloud`, `~/.kube`, `~/.docker`,
  `~/.config/gh`), or the coding tools' own sign-ins, sessions and histories: all of `~/.codex`, OpenCode's
  `~/.local/share/opencode`, `~/.local/state/opencode` and `~/.config/opencode`, `~/.copilot`, `~/.grok`, `~/.gemini`,
  `~/.cursor`, `~/.claude.json`, and in `~/.claude` the sign-in and what other sessions left (transcripts, prompt
  history, file history, to-do lists, pastes, pasted images, backups). So a run can't use your sign-ins for gh, npm,
  cloud tools or Docker; Claude Code's runs included.
- Each starts with only a small set of your environment (PATH, HOME, USER, LOGNAME, SHELL, LANG, its own TMPDIR): no
  API keys or tokens from your shell. Each starts only at the version Binders checked its options with (Codex 0.162,
  OpenCode 1.18 and Antigravity 1.4 by major and minor, Copilot 1.0.10 exactly); a newer one needs **Check** once, in
  its agent's settings.

**Your open session instead of a run.** A Claude Code agent's **Post to the Claude Code session open in this
repository** (off) sends one line into the inbox socket of a Claude Code session you have open in that repository
(Claude Code 2.1.224 or later, found from `~/.claude/sessions/<pid>.json`), instead of starting a run: the card's title,
id and `binders://card` link, and that the board tools have it. It goes only to a session with Binders' tools (Binders'
MCP server running as one of its processes), never into a run Binders started, a worktree under `.claude/worktrees` or a
script's run. With none open, or none with Binders' tools, the run starts; a post that fails starts nothing. A card the
agent holds from a run goes to a run, for your answer, your comment, Send Back or Wake Now. The session works under its
own name (usually "Claude Code"), so your answers and comments on a card it took stay on the card; the message tells it
to wait for you in the session after it asks. Whether the session takes the message, holds it or drops it depends on its
`crossSessionInbound` setting and permission mode.

Each host's entry sets `BINDERS_AGENT` to the host's name. The server puts that name first on the board whatever an agent
calls itself (`Claude Code · binders-io/app`), and no agent can act as "You".

**Claude Code**

```
claude mcp add -s user binders -e BINDERS_AGENT="Claude Code" -- /Applications/Binders.app/Contents/MacOS/Binders --mcp
```

**Claude Desktop** and other hosts that take a JSON configuration:

```json
{ "mcpServers": { "binders": { "command": "/Applications/Binders.app/Contents/MacOS/Binders", "args": ["--mcp"],
                 "env": { "BINDERS_AGENT": "Claude Desktop" } } } }
```

**Or let Binders do it.** Settings → MCP lists Claude Code, Claude Desktop, Cursor, Windsurf, VS Code,
Antigravity and Codex CLI, shows which are on your Mac and which already have Binders, and adds it with one click. Each
tool keeps its servers in its own file; Binders makes a dated backup beside that file first and changes only the
`binders` entry. Antigravity's row also has Remove, which takes out only that entry, and a file of Antigravity's with
comments in it is left alone. Older versions of the Antigravity app read `~/.gemini/antigravity/mcp_config.json`
instead, which Binders doesn't change. Google retired Gemini CLI for personal accounts: its row says so, and shows only
when Binders is already in it or `~/.gemini/settings.json` is there. The ⓘ button shows how to do it by hand, for the
tool's own configuration:

| Tool | Where |
|---|---|
| Claude Code | `claude mcp add -s user binders -e BINDERS_AGENT="Claude Code" -- <path> --mcp` (its own command) |
| Claude Desktop | `~/Library/Application Support/Claude/claude_desktop_config.json`, `mcpServers` |
| Cursor | `~/.cursor/mcp.json`, `mcpServers` |
| Windsurf | `~/.codeium/windsurf/mcp_config.json`, `mcpServers` |
| VS Code | `~/Library/Application Support/Code/User/mcp.json`, `servers` (with `"type": "stdio"`) |
| Antigravity | `~/.gemini/config/mcp_config.json`, `mcpServers` (or `agy mcp add`) |
| Gemini CLI (retired for personal accounts) | `~/.gemini/settings.json`, `mcpServers` |
| Codex CLI | `~/.codex/config.toml`, a `[mcp_servers.binders]` table |

Any other host that takes a stdio server wants the same two things: the command (the path to the Binders executable) and
the argument `--mcp`. The "Anything else" row has that as JSON to copy.

**Tools**

| Tool | Returns |
|---|---|
| `search_knowledge` (query, limit, kind, binder, folder) | The best-matching passages across meetings, notes, dictations and captured writing, by keywords and meaning, each with the `folder` its source is in (`""` at the top of its binder). With `binder`, only that binder; with `folder` (a path such as `Ops/DevOps`, or an id from `list_folders`), only what's in that folder and the folders inside it |
| `ask_knowledge` (question, binder, folder) | A written answer with the passages it drew on. With `binder` or `folder`, it answers only from that binder, or that folder and the folders inside it. Uses your local language model, so it takes a few seconds |
| `list_binders` | Your binders with their counts, and what goes in each when you've said (`what_goes_here`) |
| `list_meetings` (limit, binder, kind, folder, include_subfolders) · `get_meeting` (id, include_transcript) | Meetings, and one in full, each with its `folder` and `folder_id`. With `folder` (a path or an id; `/` for the top of the binder), only the meetings directly in it, or with `include_subfolders` those in the folders inside it too |
| `list_notes` (limit, offset, binder, tag, status, folder, include_subfolders) · `get_note` (id) | Notes, with their status, owner, due date, #tags, `folder` (its path, `""` at the top of its binder) and `folder_id`, and one in full. With `folder` (a path or an id; `/` for the top of the binder), only the notes directly in it, or with `include_subfolders` those in the folders inside it too |
| `list_todos` (status) | Every to-do: promises, asks, to-dos, and the checklist items in meeting notes, notes and digests, with the card each is on, if any, where it came from (`origin`) and, when it wasn't you, who added it (`made_by`) |
| `recent_dictations` (limit) | What you dictated lately |
| `add_to_knowledge` (title, text, source, binder) | Anything worth remembering: a fact, a document's text, a web page, an email. Kept under the title with its source, so search and answers can cite it |
| `add_note` (text, binder, folder) · `append_to_note` (id, text) | A new note, with its first line as title, in the binder and folder named (a folder's path is made if it's missing; its id decides the binder, and an id that's gone puts the note at the top of the binder, and the reply says so); or more text at the end of one. A note an agent didn't write is then marked as edited by that agent |
| `update_note` (id, find, replace, or text) | Change a note: one passage, given exactly as it is, or the whole text. Its earlier version stays in its history |
| `correct_knowledge` (wrong, right, source_id, reason, binder) | Fix something the knowledge base has wrong. A note that says it is fixed; a meeting, dictation or message stays as it was said. The correction is kept as a note tagged #correction: search marks passages that still say the wrong thing (`corrected`), and answers follow the correction |
| `distill_note` (id, agent) | Binders' own model (the Model for Distill in Settings → AI) reads a note with Distill on and proposes work items (title, brief, `done_when`, section, `quote`, waits, size, who it's for). It's a proposal for you to review and place; it makes no cards. Returns the items when the model finishes within about 25 seconds, else says the proposal waits in Binders |
| `propose_work_items` (id, items, agent) | An agent's own work items for a note with Distill on, by the note's id or by the id of the card that asked it to distill the note. Each item has a title, brief, `done_when`, section, `quote` (the note's own words it came from, copied exactly: a phrase or one line, at most 25 words, where the note marks its card), `waits_for`, size and `for`: one of the user's agents or teammates by name, as the asking card lists them, or `agent`, `person` or `either`. A proposal for you to review, never cards, unless the binder's Agents may place work items is on: then they go to Ready, meant for whoever it picked (`for`), waiting for each other as it proposed (`waits_for`), so agents take them in order, each as its own start switch allows. A run Binders started for one card may call it with that card's id |
| `note_progress` (id or binder, since) | How the work from a note is going (the cards distilled from it, put in its group, or put on the board from it), from the board alone: its `counts` (done, in progress, waits on you, held up, not started), every card (`items`: column, who has it, what its agent says it's doing, its last update and `last_update_at`, `waits_on`, what it waits for, its section) and its `report` (finished since you last looked, in progress, waiting on whom, held up and by what, not started and for whom, sections changed since their cards were made, a `summary` and `markdown`). With `binder`: each note there with Distill on or with cards on the board, with its counts |
| `get_note_history` (id) | A note's versions, newest first, the note as it is now on top: when, who (`by`, `by_kind`: person, teammate or agent, and an agent's `owner`), a `name` if given, lines added and removed, the sections touched, and the distills that read it. The id may be a card distilled from the note, never one put on the board from it or put in its group |
| `get_note_version` (id, version, compare_to) | One version's text (`now` for the note as it is), and with `compare_to` what changed from it, line by line |
| `create_binder` (name) | A new binder, or the existing one's id if the name is taken |
| `list_folders` (binder, parent) | The folders in a binder, or in all of them: each one's `id`, `name`, `path`, `binder`, `binder_id`, `parent_id` (`""` at the top) and how many `notes`, `meetings` and `folders` it holds; with `parent` (a path or an id; `/` for the top), only those directly in it. A teammate's binder's folders only for a tool that may read teammates' items, and `captures` only for one that may read captures |
| `create_folder` (name, binder, parent) | A folder, or each folder of a path (`Ops/DevOps`) that's missing, in the binder named or the current one, inside `parent` or at the top. One already there is returned as it is |
| `rename_folder` (folder, name, binder) | A new name for a folder: `folder` is its id from `list_folders` or its path, and `binder` says which binder when the path could be in more than one. A name another folder beside it has is refused. What's in it stays in it. No tool deletes a folder |
| `move_item` (id, ids, to) | Moves a note, meeting, capture or folder within its binder, or several at once (`ids`), all to the same place: into a folder (its path, made if it's missing, or its id) or to the top (`/`). A folder can't go into itself or one of its own folders, a teammate's meeting stays where they filed it, and a tool moves only what it may read. With `ids`, the reply's `items` says for each one whether it moved, and why not |
| `add_meeting` (title, notes, date, attendees, duration_minutes, app, binder) | A meeting that happened elsewhere, from its notes or transcript, so it is searchable with the rest |
| `add_todo` (text, binder) · `set_todo_status` (id, status) | A to-do, with a time at the end as its due date, in the named binder or the current one; done or open (ticks the checkbox where it lives), or dismiss a promise |
| `add_to_calendar` (text) | An event from a phrase such as "lunch with Sam tomorrow at noon" |

**The board.** Each binder has a board of cards that people and agents pick up: Backlog, Ready, In progress, Blocked,
Review, Done. An agent names itself with `agent` (default: the app it runs in). A claim on a card in progress lasts 30
minutes and every update extends it; a claim that lapses sends the card back to Ready. While a card waits on you, for
your answer in Blocked or your look in Review, its agent keeps it. Your answer gives the agent a fresh 30 minutes, and
so does sending a card back from Review (`list_tasks` with `mine` shows it). On the Mac you can take over any card that
isn't done. An agent's question rings on the Mac, and on a paired iPhone while Binders is open on it (otherwise the
next time it's opened); you can answer it in the notification on either. Agents hand
finished work over for review unless the binder lets them finish.

| Tool | Does |
|---|---|
| `list_tasks` (binder, column, mine, for, since, agent) · `get_task` (id) | Cards (everything but Done unless you ask), only those meant for someone with `for`, or changed since a time with `since`; and one card with its links and timeline. Each card says who it's `meant_for`, and whether you confirmed it, and its `state` in the words A2A and MCP Tasks share: Ready is `submitted`, In progress `working`, Blocked `input_required` while a question or an approval waits on you and `failed` otherwise, Review and Done `completed`, Backlog `canceled`. A card waiting on your approval has `approval` |
| `list_agents` | The agents you hand cards to (Settings → Agents), but not one Binders holds (its command or model turns checks off, or another agent goes by its name), each one's name on the boards and how Binders wakes it. Asked by your iPhone, also where its cards go (`sends_to`), who it sends them to (`vendor`, when known), whether Binders adds what the binder knows (`adds_context`), whether it may act for you (`may_act`) and a `fingerprint` of those; and, for an iPhone that sends its yes with what you say (it lists `momentAgreed`), whether Binders may start it on cards Binders sends it (`auto_start`), which that iPhone's fingerprint covers too, so a yes given before is asked again; and, for an iPhone that hands what you say over in Auto mode (it lists `momentAuto`), what Auto mode can do now (`auto`: `hands_over`, with `level`, or `why` and `model` when it can't) and, for each agent, whether it may take it (`auto`: `takes`, or why not), whether the Mac's yes covers Auto mode (`auto_mode_start`, which puts `auto` in its fingerprint), and the agents Binders can't weigh that take its binders (`auto_left_out`) |
| `work_streams` (binder) | What's happening: who is working on what, questions waiting on you, work waiting for your review, cards meant for someone and not started, what was finished today, and a few plain sentences; and, for a run Binders started on this Mac (Claude Code, Codex, OpenCode, GitHub Copilot CLI or Antigravity), what it says it's doing (`doing`: each card and its line, in the agent's own words) |
| `create_task` (title, todo, details, binder, column, for) | A new card in Backlog or Ready. With `todo` (an id from `list_todos`), the card is made from that to-do, in its binder, and the to-do is ticked off when the card is done; a to-do that already has a card returns that card. With no `binder`, an agent's or a tool's card goes in the binder it fits best, by the decision model chosen in Settings → AI (Tev1 0.8B, another MLX model, or a decision server on this Mac) when one is on and sure enough, else your current binder. Each model has its own level for sure enough: its measure's, or 0.35 for one not measured yet. Without `for`, Binders may suggest the agent whose work it is; a card from MCP never starts one |
| `claim_task` (id, agent) | Takes a card; one owner at a time. A Ready or Backlog card moves to In progress. An agent can't claim, or move to In progress, a card made from what the iPhone heard that you or Binders meant for another agent: "This card is meant for Claude Code · app. Leave it for them." |
| `update_task` (id, progress, links, column, for, agent) | A progress report and links (it keeps the claim), a move, or who it's for. Who it's for, from an agent, is a suggestion until you confirm it |
| `ask_on_task` (id, question, agent) · `comment_task` (id, text, agent) | A question for you (the card waits in Blocked until you answer), or a comment |
| `release_task` (id, note, agent) · `complete_task` (id, summary, agent) | Lets go with a note for the next one, or finishes with a summary |
| `request_approval` (id, action, recipients, text, link, agent) | Asks you to approve something outside Binders before the agent does it ("send an email", exactly who it goes to, the exact text). The card waits in Blocked; your answer comes back on it as "Approved" or "Declined: …" and wakes the agent. Agents can't decide one |

**Distill.** A note with Distill on can be read into work items, which you review and place; placed cards wait for each
other, and an agent can't claim one (or take it by moving it, or finish it without holding it) until every card it waits
for is Done: "This card waits for “…”, which isn't done yet". `list_tasks` and `get_task` say what a card waits for
(`waits_for`: id, title, column) and what it was distilled from (`distilled_from`: note, title, section, version, link,
`quote` when the item had one, and `section_changed` once you've passed a change on). A card in a note's group, whether
Distill made it, you put it there with Part of, or it was put on the board from the note, has `note_id` and
`note_title`; `distilled_from` stays only on cards Distill made. A card put on the board from a note, or put in its group
by hand, gives an agent no way into the note: `get_note_history` and `get_note_version` refuse its id. When the section
a Put on Board card came from changes, its agent hears only who changed which section and by how much. When a section changes after its cards were made, `get_task`'s timeline says who changed it and how many lines, and gives an agent the changed lines only when the user made the change, or a teammate did and the tool may read teammates' items; another agent's change is never given to a different agent, which is told to read the section with `get_note_version`. `get_note` and `list_notes` say `distill: true` for such a note. A
run Binders started for one card also has `propose_work_items`, `get_note_history` and `get_note_version`, with its own
card's id only: they reach the note its card came from, so it can see what changed since its card was made. An agent's
own board-only server reaches a note only through a card it holds or is meant for.
Binders doesn't wake an agent for a card that still waits ("Waits for “…”. Binders wakes Scribe once it's done."): it
wakes it once the last card it waits for is Done, as for a card you made ready. When you or a teammate change the
section a card came from, the agent holding the card in progress is woken as your comment wakes it, with the changed
lines in `answer`; an agent's change waits until you choose Looked at It on the card or Make It Mine on the note. Cards
an agent places through Agents may place work items start an agent only when it may start on cards Binders sends it.

**Agents you hand cards to.** Settings → Agents sets up agents that take cards: Claude Code in a repository; Codex,
OpenCode, GitHub Copilot CLI or Antigravity in a repository, when they're on this Mac (kept in agents-cli.json beside
agents.json); a command, a web hook or a Shortcut. Under **Its work**, **Sends cards to** says who the
agent hands a card to so its model can work on it (OpenAI, Anthropic, a server of yours): Binders can't see where a
program, a Shortcut or a web hook sends things, so your iPhone names this before it gives the agent its first card, and
asks again when it changes. Left empty, Claude Code is Anthropic, and a command that runs `claude`, `codex`, `gemini`,
`agy`, `grok` or `copilot` is Anthropic, OpenAI, Google, Google, xAI or GitHub (Microsoft). A Codex agent is OpenAI, a
Copilot agent GitHub (Microsoft) and an Antigravity agent Google whatever that field says, as Binders fixes where they send cards. An OpenCode agent needs its model as
`provider/model`, and names that provider ("the anthropic provider, as set up in your OpenCode"). **What it's for** is a
few words, such as "personal errands", that Binders goes by to pick the agent for a card or a to-do and to name it on
Give to (a Claude Code, Codex, OpenCode, Copilot or Antigravity agent is "code in the <folder> repository" until you say). **Kinds of
work** (Coding, Writing, Research, Outreach, Scheduling, Errands, Bookkeeping, Design, and your own words) say what it
takes on at a glance, in agents.json as `kinds`; Claude Code and the command-line coding tools take coding unless you
change it. Binders goes by them only when What it's for is empty ("Kinds of work: coding, research."), which a Claude
Code, Codex, OpenCode, Copilot or Antigravity agent's never is: its repository speaks for it then. Nothing goes to it
until you tap Give to, unless you turn on **Start on cards Binders sends it** (off for every agent; `autoStart` in the
file counts only with the turn-on alert's own yes in the Keychain). Then a card you type into Ready, a to-do you add in
Command Mode, or a "Binders, …" you say on your own near your iPhone, in your voice past the start bar Calibrate sets,
goes to it at once when the decision model is very sure it's that agent's work (its raw score at or above that model's
start level: 0.97 for Tev1 0.8B, another model's from its own measure in Settings → AI; a bar measured on made-up cards
rather than a rate) and it takes that binder's cards, and only one you named, when you named one. It needs a decision
model that can start agents: Tev1 0.8B on this Mac, or another one whose measure found a start level. It goes through
Give to's own path (the hourly cap, the briefing, the receipt),
the card says Binders started it and why, and Stop on the card, Stop in the flow bar or Undo on the iPhone takes it back
to Backlog: a run Binders started stops, and a web hook, a Shortcut, a command that has run or your open Claude Code
session keeps what it was sent, as the line then says. Never
what a capture or a conversation heard, what you tell Siri or a Shortcut, a teammate's item, or a card from MCP or
another agent, except the cards an agent places from Distill on a board where you turned on Agents may place work items
(above). Only an agent whose What it's for is in your words, that drafts first (Can send, post or buy off) and that
Binders wakes itself (not one that checks the board itself) can start that way. Binders wakes one (or posts to the Claude Code session you have open in its repository, when you turn that
on) only when you give it a card, answer its question, comment on a card it holds in progress or send its work back, or
for Distill's reasons above, and at once for Give to and Assign (an edit or a comment on the Mac waits two seconds, so two quick comments make one wake).
A web hook's, a command's or a Shortcut's wake says why in `event` (`BINDERS_EVENT` for a command): `ready`, `answered`,
`commented`, `sent_back` or `manual` (`test` from Settings). `answer` has your latest answer or comment, as before; while
comments you made as it worked on the card haven't reached it (sent with an answer or Send Back, held back by the hour's
limit or a run, or on a wake whose hook failed), it has every word of yours it hasn't had, oldest first, never a note by
Binders. A wake that carries your comments goes once the card's last web hook post or Shortcut run has settled.
How it reports back is one of four: through Binders on this
Mac (its MCP entry), from another machine over SSH (an entry to paste there, which runs this Binders' `--mcp` over
`ssh -T`, so this Mac needs Remote Login and a key), a status address Binders asks every three minutes while the card
is in progress (its token in the Keychain, the card's id in the query only), or "I'll move the card myself" (Binders
holds the card for it in In progress, with no lease).

The first time a card goes to an agent, Binders adds a **From your binders** note to it: up to three short passages from
the card's binder that match it, a title and a line each. Never a transcript or a note an agent wrote or changed (until
you make it yours), and captures or teammates' items only if that agent may read them. `get_task` shows the note only as
far as the tool asking may read it, and not at all to an agent with the switch off or one held as changed outside
Binders. A web hook's or a command's wake carries it as `context`. You can
edit or delete it on the Mac, and each agent has a switch for it (on).

**Agents draft first.** Unless you turn on **Can send, post or buy for you** for an agent (off for every agent), it's
told to ask before it sends, posts, buys or deletes anything outside Binders: Claude Code's prompt has a draft-first
step, the other wakes carry `may_act`, and agents on these tools have `request_approval`. Binders can't stop an agent
from using its own tools; it tells it to ask. The request shows on the card and in Needs you on the Mac, and on the
iPhone, where the Lock Screen shows only who asks and what ("Scribe asks to send an email"). The notification has Open
only, which takes an unlocked iPhone to the card: who it goes to and exactly what it says are there, above Approve and
Decline, as on the Mac. Only you decide, for exactly the request shown, and each decision leaves a receipt on the
card (who, which device, when, exactly what) before the agent reads the answer. An agent whose setting is turned on
anywhere but Settings is held as changed outside Binders: its MCP server tells it to draft first, and `list_agents` says
`may_act` false, until you save it in Settings. While agents are paused, Binders keeps the claim on a card it holds for a
status-address agent, asking the address nothing, so the card is still there when you resume. On the iPhone, the first
card, answer, comment on a card it's working on or Send Back for each agent asks first, naming where its cards go and who
it sends them to, and asks again whenever that changes.

**What agents wrote.** A note an agent wrote or changed says so wherever it shows, and every reply that carries it has
`made_by`, `edited_by` and `edited_at` (ISO 8601), each only when set (get_note, list_notes, search_knowledge passages,
ask_knowledge sources). Ask, Command Mode, answers to what you said and `ask_knowledge` leave those notes out, and a
#correction in one steers nothing, until you choose **Make It Mine** on the Mac.

Reads go straight to the database. Writes are handed to the running app, which does them and answers with the new item's
id, so its windows update, reminders get scheduled and the index picks the item up within seconds; if the app isn't
running, macOS launches it. Nothing can be deleted this way, and a note that's changed keeps its earlier version in its
history. Each tool tells the host whether it only reads (`readOnlyHint`), so a host can let lookups through and ask
before anything is added or changed; Settings → MCP lists them as Reads, Adds and Changes. After you update Binders,
restart your AI tool, or reconnect its Binders server, so the server runs the new version.

A write sent again with the same `request_id` argument (any write tool; the iPhone sends one for what it queued) gets
the first answer and is done once. Ids are kept for a week, up to 5,000, per sender, so one sender can't replay
another's, and a request that failed isn't remembered. If Binders couldn't open its library at launch, every write
answers "Binders can't save right now: its library didn't open." and reads say so rather than show an empty library.
On the Mac, Ask says it can't answer and search leaves notes out, as whose words they hold is in the library; quitting
and reopening Binders is the fix.

Dates are ISO 8601 in local time. Try it by hand:

```
echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' | /Applications/Binders.app/Contents/MacOS/Binders --mcp
```

## Talking to your agents

The Agents page in the sidebar is where you talk to them. On the left are the Manager and each agent, saying what it's
doing (working, a card that needs you, idle, off), and under the one you pick, its conversations: each is a card it holds
or one you meant for it, the finished ones under Earlier. On the right is what it holds and what's meant for it, with a
box to message it, or the conversation you picked, as the card's own window shows it, with the same composer and what
waits on you.

A message starts a conversation as a card: its first line is the title and the whole message the details, meant for the
agent on a board it takes cards from (you choose which when it takes several), in Ready, and Binders hands it over as Give
to does. One that checks the board itself picks it up there. What you write on an open conversation is a comment on its
card, which reaches the agent as comments always do. The Manager has its own conversation, its requests and replies.

## The Manager

One agent can be **the Manager**, one at a time: one of your Claude Code agents, or a local model. Choose it under The
Manager in Settings → Agents (or turn on The Manager in a Claude Code agent's own settings), and add a local model there
with Add a Local Model as the Manager…. Then, on the Agents page, you can ask it anything about your binders ("what's blocked and
why?") or ask it to do something ("tidy the Personal board", "distill the roadmap note"), and **Tidy** asks it to tidy one
binder or all of them. A tidy on a schedule (every day or every week) is off until you choose it, and runs only while the
Mac is plugged in, cool and idle.

Binders starts it for one request at a time, in an empty folder of its own (`~/.binders/manager`), with its permission
checks on and Binders' tools alone: no files, commands or web. It reads your binders, notes, meetings and boards the way
a tool you set up does (captures, transcripts and teammates' items only where Settings → MCP lets it), and it can:

- edit a card's title or description (`edit_task`), close a card in Backlog or Ready (`close_task`, saying why), merge cards
  that are the same work (`merge_tasks`), make a card (`create_task`) and comment on one (`comment_task`), leaving alone a
  card an agent holds, one that waits on you, one other cards wait for, and a team's boards;
- make, rename and fill folders (`create_folder`, `rename_folder`, `move_item`);
- distill a note (`distill_note`): its work items wait for you, as Distill's always do;
- suggest an edit to a note (`propose_note_edit`), which you accept or dismiss on the Agents page; accepted,
  it's your edit, the earlier version in the note's history, so the note stays yours and Ask keeps reading it.

A local model as the Manager is the model Distill uses in Settings → AI, or another you name on the same server (Ollama,
a model in Binders, or the OpenAI-compatible server). It takes no cards, only the role. Binders runs it in turns, at most
16 tool calls a request: it starts the same `Binders --mcp` a Claude Code Manager has, under the same confinement, shows
the model the request, the Manager's tools and what it did so far, and calls the one tool the model picks each turn
(each turn's answer held to a JSON schema where the server can hold it). A bigger model follows the steps better.

It can't delete anything, change a note itself or start another agent, and nothing it does wakes one. It ends with a reply
you read where you asked. Each request lists what it changed, and **Undo Its Changes** puts them all back. Requests, their
changes and the suggestions are kept in manager.json in the data folder (the last 200).

