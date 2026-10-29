# The phone link

How an iPhone, or any paired client, talks to Binders on a Mac. The Mac is the server and the only writer; clients are
paired devices. Nothing goes through a server of ours: the connection runs over the local network, or over a VPN (Covee,
Tailscale or another) when you're away.

Switch it on in Settings → iPhone. It is off by default, because it opens a network port.

## Security

- **Pairing.** The Mac shows a QR code with a one-time secret, valid for ten minutes, and opens a pairing port (7448) that
  accepts only a key derived from that secret (HKDF-SHA256). Over that connection the client asks to pair and receives
  a random 256-bit device key. The code then stops working and the pairing port closes.
- **Every later connection** is TLS 1.2 with a pre-shared key (`TLS_PSK_WITH_AES_128_GCM_SHA256`) on port 7447. The Mac
  accepts only the keys of paired devices; there are no certificates to manage.
- **Proving which device it is.** Right after connecting, the client asks for a challenge and answers with an
  HMAC-SHA256 of it, made with its device key. Until then, every request is refused. This is what lets Settings show
  which device is connected, and cut one off.
- **Removing a device** deletes its key, closes its connections and restarts the listener without it.
- Device keys live in the Mac's Keychain (`link-device-key-<id>`, under io.binders.mac). `link-devices.json`, in
  `~/Library/Application Support/Binders`, lists paired devices only: id, name and when each was paired. A file from
  before keys moved has them moved to the Keychain the first time it's read, and is written again without them (a key
  the Keychain won't take stays in the file until it does); after that, a key put into the file isn't trusted. A device
  whose key isn't in the Keychain is listed in Settings to pair again, with Remove. Pairing that can't write its key to
  the Keychain fails and says so. A Mac 0.8.0 reads keys from the file, so after a downgrade it sees no paired devices.
- **The address plays no part in who's allowed in.** Whatever answers at a stale or typed address can't finish the
  handshake without the key, which never crosses the wire; it sees only the device id (the TLS identity), which opens
  nothing. That's why the phone tries every address it knows, including ones you type.
- **A VPN is the way to reach the Mac from outside.** Forwarding a router's port to 7447 isn't supported: every TCP
  connection gets a session before TLS, and `TLS_PSK_WITH_AES_128_GCM_SHA256` has no forward secrecy, so traffic recorded
  on the internet could be read if a device key ever leaked. A session that hasn't said hello (or paired) in 20 s is
  closed, and at most 64 wait at once. A name you add, and Tailscale's MagicDNS name for the Mac (offered while
  Tailscale runs, below), are looked up through the DNS the phone is using and sent as the TLS server name before the
  handshake, as for any name. On a VPN path both stay inside the VPN; with the VPN off on the phone, the network it's on
  sees them.

## Finding the Mac

- **Bonjour.** On the local network, the Mac advertises `_binders._tcp`, and the phone finds it by its name wherever it
  is on that network.
- **The Mac's addresses.** The Mac reads its own interfaces and offers every address a phone could use, best first: the
  local network (the IPv4 addresses on its `en*` interfaces, labelled Wi-Fi, Ethernet or Local network, in interface
  order; IPv6 there is left to Bonjour); then names (yours, then Tailscale's); then VPN addresses (the private, CGNAT and
  unique-local ones, 10/8, 172.16/12, 192.168/16, 100.64/10 and fc00::/7, on a tunnel: `utun*`, `ipsec*`, `ppp*`, `wg*`,
  `tun*`, `tap*`, `feth*`, `zt*`, or any point-to-point interface but `gif` and `stf`), IPv4 before IPv6 and yours before
  a VPN's own before the interfaces'; and last a VPN that also carries a public address, such as Cloudflare WARP, which
  a phone can rarely reach through ("rarely reachable"). Any VPN is found this way, Covee included, with no tool of its
  own; a VPN's addresses are labelled with the name it registered with the system (from the network configuration's
  service for that interface), and "VPN" when it registered none. Never offered: loopback, link-local, self-assigned and multicast addresses, an interface that's down, public
  addresses on a tunnel, VM networks and Apple's own links (`bridge*`, `vmenet*`, `vnic*`, `awdl*`, `llw*`, `anpi*`,
  `ap*`). Each address is offered once, written one way (IPv6 as `inet_ntop` writes it, names lowercased without a
  trailing dot). The rules are `LinkAddresses.classify` in BindersKit.
- **Tailscale** gets one extra. While it's installed (`/Applications/Tailscale.app`, `/usr/local/bin` or
  `/opt/homebrew/bin`, never a search of PATH, and never in a throwaway folder), the Mac asks
  `tailscale status --json --peers=false`, off the main thread, for 2 s at most: then the tool is told to stop, and
  killed half a second later if it hasn't. Its answer counts only while its `BackendState` is `Running`: then the
  addresses it names are labelled Tailscale, any it names that no interface has are added (Tailscale in userspace), and
  so is its MagicDNS name, without the trailing dot. Nothing another VPN has up is ever dropped because Tailscale named a
  different address. When the tool fails, or can't be found any more (uninstalled, or moved by an update), its last good
  answer stands in for five minutes and only relabels addresses that are up, so a Tailscale that quit is never offered.
  A stopped Tailscale's answer is ignored.
- **Yours.** Settings → iPhone lists the addresses, and lets you add a name or an address (a name your VPN gives the
  Mac, say) and leave out detected ones. They're kept in the Mac's preferences, `phoneLinkAddedAddresses` and
  `phoneLinkLeftOutAddresses`, not in `link-devices.json`. An address you add is offered even while its VPN is down,
  which is how to keep a VPN's fixed address in every hello; one typed with the link's own port is kept without it.
- **When the Mac reads them again:** once the link starts; when the kernel's routing socket says an address or an
  interface changed, settled for a second (it sees every tunnel, a homegrown VPN's too); every 30 s while the link is on;
  before a hello, when the last read is 5 s old; before every pairing code; and when Settings → iPhone opens. Tailscale
  is asked when the link starts and for every pairing code, when the addresses the interfaces give change (at most every
  15 s), when Settings opens (once 15 s have passed) and otherwise every five minutes.
- **The QR code** carries the likeliest few, which an iPhone 2.0 build (6-26) tries one by one, 4 s each, every time
  it connects (and every build as it pairs): at most 5, within 128 bytes of address text, none a phone can rarely reach
  and none with its own port; the local network's IPv4 first, then other IPv4, then names, then IPv6 in brackets. A
  newer phone learns the rest at its first hello. Each module of the code is drawn the same whole number of pixels.
- **In the hello.** To a phone whose hello lists `addresses`, the reply carries `addresses`: what the Mac offers (at
  most 16), in the order to try them, each `{host, port, kind, label, unlikely?}`. `kind` is `local`, `vpn`, `tailscale`
  or `added`, an open set: a phone shows the label of one it doesn't know. The list is read fresh for that hello, and
  goes only to a paired device that proved its key. When it changes, a phone that reads the notice is told (below).
- **The phone's order.** At once: Bonjour (when it sees the Mac), the address that worked last (always, whether or not
  any list still has it) and one just tested that answered. Then the addresses you added on the iPhone, what the Mac
  said at its last hello (apart from the rarely reachable ones), the ones that won a dial in the last 30 days (at most
  4, so one a hello left out while its VPN was down is still tried), the pairing code's, and last the rarely reachable
  ones. Each address once, at most 12 besides Bonjour. A phone paired with Mac 0.8.0, whose code held only its Wi-Fi
  address, learns the rest at its first hello after the Mac is updated; pairing again once puts them in the code too.
- **The dial.** The first ones start together and the rest 250 ms apart, at once when the one before fails. Every
  connection that opens asks for a challenge straight away; the first whose challenge is answered says hello, signing
  its own challenge, and subscribes; every other try is closed. So the Mac sees one hello and one subscribe per connect,
  a try whose path stalls after it opened never holds up one that works, and a hello the Mac turns down ends the dial
  with its words. Offline, the phone says which addresses it tried and what happened to each; it says the Mac doesn't
  know this iPhone any more only when Bonjour, an address the Mac listed or the last good one failed the key. Your Mac
  on the iPhone lists the addresses with the one in use, and **Test** opens one and asks for a challenge only, which
  counts no connection.

## Messages

Newline-delimited JSON-RPC 2.0, the same framing as `Binders --mcp`. One message per line, at most 8 MB.

| Method | When | Result |
|---|---|---|
| `binders/pair` `{name}` | pairing port only | `{device, key, name, protocol}` (the key is base64) |
| `binders/challenge` | first, on 7447 | `{challenge}` (base64, 32 bytes) |
| `binders/hello` `{device, proof, name, protocol, features?}` | after the challenge | `{name, version, protocol, features, addresses?}` (`addresses` only to a phone that lists `addresses`) |
| `binders/subscribe` | after hello | `{}`; the Mac then sends `binders/changed` |
| `binders/format` `{text}` | after hello | `{text, used_model, model}`: dictation cleaned up the way the Mac cleans its own |
| `binders/dictation` `{id, text, raw, app, date, model?}` | after hello | `{}`; kept with the Mac's dictations, once per `id` |
| `binders/conversation` (a conversation, below) | after hello, when `features` lists `conversation` | `{id}`; kept once per `id` |
| `binders/suggestions` | after hello, when `features` lists `suggestions` | `{suggestions}`: cards and answers offered about the phone's conversations of the last three days |
| `binders/suggestion` `{id, action}` | the same | `{message}`; `action` is `accept` (a card goes on its board) or `dismiss` |
| `binders/warm` | after hello, when `features` lists `warm` | `{}` at once; the Mac loads its model, as the phone heard someone start talking |
| `binders/outcomes` `{ids}` | after hello, when `features` lists `outcomes` | `{outcomes}`: what became of each capture or moment asked after (at most 50), below |
| `binders/outcome` `{id, action, agent?, request_id?}` | the same | `{message}`; `action` is `add`, `not-now`, `undo` or `assign` (from a moment's notification or row) |
| `binders/decision` `{card, approval, approve, reason?}` | after hello, when `features` lists `approvals` | `{message}`; your Approve or Decline on an agent's request for approval, for exactly the request `approval` names (a newer request on the card isn't decided by it), sent from the card's approval box (the notification only opens the card); the Mac records the receipt, then answers the agent |
| `binders/manager` `{text, id?, thread?, kind?, binder?, agent?}` | after hello, when `features` lists `manager` | the request, as `binders/manager-requests` gives it; something you typed to the Manager (`kind` `ask`, the default) or a tidy (`kind` `tidy`, with `binder` an id or a name, none for every binder). `id` is the phone's own, so one sent twice is one request; `thread` is a request whose conversation it goes on; `agent` is the Manager the phone asked you about first: if another has the role, by now or by the time it would start, it's refused |
| `binders/manager-requests` `{limit?, ids?, thread?}` | the same | `{requests, suggestions, agent?, local?, problem?}`: what you asked, newest first (`limit`, 20 by default, at most 50), each `{id, thread, kind, text, from, at, status, agent?, reply?, replied_at?, why?, changes: [{kind, line}], can_undo, undone_at?}`; the note edits it suggested that wait for you, each with the lines it adds and takes away (`changes`, `+ ` and `- `) or `outdated`; who has the role (`local` when it's a local model, which stays on the Mac), and why nothing would start now |
| `binders/manager-act` `{id, action}` or `{suggestion, action}` | the same | `{message}`; `stop` or `undo` on a request (Undo puts back everything it changed), `accept` or `dismiss` on a suggested note edit (accepted, it's your edit) |
| `binders/chats` `{agent?}` | after hello, when `features` lists `agentChats` | `{chats}`: your chats with your agents, the latest first (one agent's with `agent`), each `{id, agent, title, started_at, updated_at, status, count, why?, last?, live?}`; `status` is `idle`, `running` (Claude Code is answering; `live` is what it has written so far) or `waiting` (for an agent that checks the board itself) |
| `binders/chat` `{id}` | the same | the chat, with `messages`: each `{id, from, text, at, via?, delivered}`, `from` `you` or `agent` |
| `binders/chat-send` `{agent, text, chat?, id?}` | the same | the chat, with your message in it; a new chat without `chat`. `id` is the phone's own, so one sent twice is one message. Refused for an agent that can't chat (only Claude Code and agents that check the board themselves can) |
| `binders/chat-act` `{id, action}` | the same | `{message}`; `stop` ends the chat's run |
| `binders/sessions` `{agent}` | after hello, when `features` lists `agentSessions` | `{agent, what, avatar, chats, terminal, sessions}`: one agent as the Mac's Agents page shows it, `what` it is ("Claude Code · in ~/code/app"), what it wears (`avatar`: `claude`, `codex`, `opencode`, `copilot`, `antigravity`, `cursor`, `grok`, `local` or `other`), whether it chats, whether Binders reads its runs, and its sessions, the one running first and then the newest, each `{kind, id, title, updated_at, running, needs_you, done}`, `kind` `card` or `chat` |
| `binders/session` `{kind, id, agent?}` | the same | `{kind, id, title, blocks, earlier, running, current?, since?, intro?, hint?, blocked?, needs_you, column?}`: one session as its terminal, read from Binders' own logs of its runs; the newest 150 `blocks`, each `{id, type, …}`: `run`, `you`, `said` and `waiting` with `text` (`waiting` with `why`), `binders` with `summary` and `text`, `tool` with `{name, argument, status, summary?, output?, diff?, more?, diff_more?}`, `plan` with `[{text, status}]`, `end` with `ok` and `text`; `earlier` says how many older ones the Mac kept back, `more` and `diff_more` how many lines. `hint` says where your words go; `blocked` why they can't |
| `binders/session-send` `{card, agent, text, id?}` | the same | `{message}`; your words into a card's session, as the Agents page's prompt sends them, when they reach `agent`, the one the phone asked you about; for any other agent they stay on the card. `id` is the phone's own, so words sent twice go once. A chat's words go by `binders/chat-send` |
| `binders/session-act` `{card, action}` | the same | `{message}`; `stop` ends the card's run |
| `tools/call` `list_agents`, from a Mac that lists `manager` | the same | each of your agents also has `binders` (the names of the binders whose cards it takes, for where a message from the Agents tab goes), `avatar` (what it wears, as in `binders/sessions`) and `manager: true` for the one with the role; a local model, only ever the Manager, isn't listed |
| `binders/moment` (a moment, below) | after hello, when `features` lists `moment` | `{outcome}`: what the Mac made of it, kept once per `id` |
| `ping` | after hello | `{}`: a word with no side effect, which every Mac with the link answers |
| `initialize`, `tools/list`, `tools/call` | after hello | the same tools as the MCP server (see [AUTOMATIONS.md](AUTOMATIONS.md)) |

Each end lists, in hello, what it understands besides the tools, and neither sends the other anything it didn't list.

- The Mac's `features` (in its reply) name what it takes: `conversation`, `suggestions`, `warm`, `outcomes`, `moment`,
  `dedupe` (it saves a repeat of the same `request_id` once, below), `momentAdds` (it adds a graduated kind at once),
  `giveTo` (`binders/suggestion` takes `action: give` with an `agent`: the card goes on its binder's board, meant for the
  agent, in Ready, and the Mac hands it over), `approvals`, `askProgress`, `addresses` (it says where a phone can
  reach it, above), `momentAgreed` (it takes the phone's yes with a moment, `agreed` below, for an agent you let start
  on cards Binders sends it), `commentWakes` (a comment on a card an agent holds in progress wakes it; from a phone, only
  when its `to` names that agent; a phone asks first before a comment only on a Mac that lists it), `momentAuto` (it
  reads a moment's `mode`, hands over in Auto mode, takes `stop` and `not-me` in `binders/outcome`, and says what Auto
  mode can do now in `list_agents`, to a phone that lists `momentAuto`), `soloAuto` (it reads a capture's `mode`,
  `solo`, `soloHold`, `agreed` and `soloMoments`, reads a capture the phone heard as only you for what you said and hands
  it over in Auto mode, reads a moment's `fromTranscript` and `uncued`, takes `stop-all`, `not-only-me` and `mode` in
  `binders/outcome` on a capture, sends `found`, `soloLine` and `joins` in outcomes, and gives `solo_start`, `solo` and
  `auto_fingerprint` in `list_agents`), `folders` (binders have folders: `list_folders`, and `folder` on `list_notes`, `/`
  for the binder's top or a folder's id, and on `add_note`, a folder's id, which decides the binder; one that's gone puts
  the note at the binder's top) and `distill` (it answers `note_progress`, a Distill note's Work bar, cards and report,
  or a binder's Work list, and says `distill: true` in `get_note` and `list_notes` for a note with Distill on; a phone
  shows a note's Work section and a binder's Work list only for a Mac that lists it). A phone that lists `workStreamsDoing` is
  sent `doing` in `work_streams` (what a Claude Code run on the Mac says it's doing); one that doesn't isn't, since an
  older phone saves the whole reply. A phone holds
  back what its Mac doesn't list, and sends it once the Mac is updated: it keeps All-day capture's conversations in its
  outbox until it sees `conversation`.
- The phone's `features` (in its hello) name what it reads: `suggestion:<kind>` for each kind of suggestion,
  `notification:<method>` for each notification, `addresses` for the Mac's addresses in the hello reply, and
  `momentAgreed`: it sends its yes with what you say, so `list_agents` tells it which agents start on cards Binders sends
  them (`auto_start`) and fingerprints those with that too, so a yes given before is asked again;
  `commentsAskFirst`: it asks before a comment goes to an agent you haven't said yes to, and names that agent in `to`
  with the comment; `momentAuto`: it sends a moment's `mode`, and reads `auto` in `list_agents` and `handedOver` and
  `stop` in outcomes; `soloAuto`: it sends a capture's `mode`, `solo` and `soloMoments` (and in Auto mode its yes)
  and a moment's `fromTranscript` and `uncued`, and reads `found`, `soloLine`, `joins` and the new `list_agents` keys;
  `folders`: it shows a binder's folders and files the notes made in one there, asking only a Mac that lists
  `folders`; and `distill`: it shows a note's Work section and a binder's Work list, read-only. A phone that doesn't
  list `folders` never passes `folder`, and `list_notes` without it lists every note in the binder, as before; a folder
  changing on the Mac comes as a change to `notes` in `binders/changed`. Its saved copy of a `note_progress` reply
  leaves out what runs say they're doing (`doing`, and the report's sentences), as its copy of `work_streams` does. An
  older phone never asks for `note_progress`, and its decoders leave the new keys (`distill`, `waits_for`,
  `distilled_from`) be.
  A phone that lists nothing (iPhone 2.0) is taken to read
  `suggestion:card`, `suggestion:answer` and `notification:binders/changed`, and is sent nothing else: it decodes
  suggestions against a closed list, so one kind it doesn't know would freeze its refresh, and it takes any other
  notification as "everything changed". A newer phone lists every kind it knows, skips an item it can't read rather than
  the whole list, and lets go of a notification it doesn't know.

### Staying connected

A Mac that goes to sleep doesn't say goodbye, and TCP alone takes about ten minutes to notice. So, while connected and
nothing else is said, the phone sends `binders/subscribe` after 10 seconds of quiet with the app in front, or after a
minute in the background, where capture or the keyboard holds the link. While a request waits for its answer, its own
timeout speaks for the link instead, so a long upload isn't cut off. Any request that times out has the phone check at
once (2 s, then 5 s), and without an answer it connects again. While you talk, a `ping` (or `binders/warm`) goes at most
every 30 seconds with a 3 second timeout, so a sleeping Mac is noticed before the sentence ends.

The phone's timeouts sit in one table (`LinkTimeouts`): connecting 4 s for each address (Bonjour and the last good one
start together, the rest 250 ms apart), each step of hello 10 s (a Mac that takes the connection but doesn't answer is
passed over for its next address), a screen's read 8 s, a change 15 s, Ask 200 s (past
the Mac's own 180 s), and from the outbox 20 s for a note, a to-do, an answer or a Give to, 15 s for a dictation, 45 s
for a moment and 60 s for a conversation. Siri's moment waits up to 6 s for the link and 20 s for its answer. Dictation
cleanup takes about 4 s in all, the link at most 2 s of it; past that, Binders' own rules tidy the words. An item that
times out waits for the next outbox run, so nothing is sent twice in a row.

When the phone's network changes (settled for a second), it doesn't wait for its next try. Not connected, it tries at
once, at most once every 3 s, and leaves the waits between tries (1, 2, 5, 10 and 30 s) where they were; a change
during a try brings one more straight after. Connected, a new route has it check the link with `binders/subscribe`, or
drop and dial again a link whose own path went. Every settled update counts, even one whose interfaces, gateways and
reachability look the same, as a VPN coming up can show only in something else. It does this only while the app is open
in front: in the background, a link that All-day capture, the keyboard or an errand holds comes back on the waits
between tries, or once a check finds it gone.

### Sent once

To a Mac that lists `dedupe`, every tool call the outbox makes for a note, a to-do, an answer or a Give to carries its
item's id as `request_id`. Sent again after its reply was lost (a timeout, the link gone on the way), it's saved once:
the Mac answers a repeat as it did the first time, and keeps ids for a week, up to 5,000, per sender. A moment's
`assign` carries one too, though assigning the same agent again is already a no-op there. A note or to-do retried without its binder (renamed or deleted on the Mac) keeps its id.
A note kept in the outbox from inside a folder keeps the folder's id (`folder`, Optional), sent with it only to a Mac
that lists `folders`.
An answer already on the card, in your words, after the question it answers counts as sent and isn't sent again. To a Mac
that doesn't list `dedupe`, the arguments are as before.

### Outcomes

What became of a capture, for its row on the phone. `state` and `actions` are open sets of words, so a newer Mac's states
still read on an older phone; `line` can hold what was said, and `title` is the same without it, for the Lock Screen.

```json
{"id": "3A02EC85-6FEF-4AF9-9231-14713C1AEB2F", "state": "filed", "line": "Filed in Events: Ignite booth plan · 2 to-dos",
 "title": "Filed in Events", "settled": true, "binder": "Events", "todos": 2}
```

States today: `writing` (being written up), `filed`, `not-kept` (too short, or small talk) and `failed` (no notes, with
the reason). A capture with no words never reaches the Mac: the phone keeps it as Not kept on its own. The phone asks after its sent captures of the last three days that haven't settled, whenever `meetings`
changes; only over the link, never through MCP.

A moment's outcome has its own states: `offered` (with `add` and `not-now`), `acted` (a to-do or card made, with `undo`,
and `assign` when an agent could take it), `answered`, `undone`, `dismissed`, `nothing` (heard on its own, with nothing to
do: no notification) and `working` (the model is still on it; the phone asks again). It also carries, each Optional:
`kind`, what the moment was read as (todo, question, idea, status, note), which the phone's Lock Screen wording goes by;
`sources`, an answer's source titles, which a newer phone leaves out of what Siri says (they're still on the line after
the answer, for older phones); and `timings` (heard, sent, decided, `asrMillis`, `llmMillis`) for the Timings row.

For a moment that came with a `mode`, `handedOver` says Binders handed its card over without a tap: `auto`,
or `start` (a "Binders, …" for an agent you let start); such an outcome has the actions `stop`, `undo` and `not-me`
while it's with the agent, and `binders/outcome` takes `stop` and, from that phone, `not-me`. `waiting` (`wake` or
`give`) says it waits on you, and `late` that it reached the Mac late, for the phone to say when it was said, in its
own time zone.

For a conversation read for what you said, `found` lists each item and each moment that went with it (`id`, `heard`,
`said`, `kind`, `joined`), whose own outcomes come as moments' do; `soloLine` says why one from a phone in Add at Once
or Auto mode wasn't read; a moment's `joins` is the capture it waits for. `binders/outcome` takes, on a conversation's
id from a phone that lists `soloAuto`, `stop-all`, `not-only-me`, and `mode` with `add` or `suggest` (what's not handed
over yet is then decided as that mode).

### Moments

Something short you said to yourself while All-day capture listened, written down on the phone and kept by its gate (see
[CAPTURE-ALLDAY.md](CAPTURE-ALLDAY.md)): only the words, never audio. `wake` says it began with "Binders"; heard on its own,
`cue` is the phrase that let it through and `voice` how much it sounded like you. Siri's Ask Binders and Tell Binders send
one too, with `engine: "siri"`, `wake: true`, and `kind: "question"` for Ask: the Mac reads a moment with that kind as a
question or a status request, never as something to add. `asrMillis` is the phone's write-down time. `adds` lists the
kinds the phone says have graduated (todo, idea, note), sent only for something heard on its own and only to a Mac that
lists `momentAdds`; that Mac adds one of those at once with Undo, runs no automation for it, and still offers anything
meant for an agent. `agreed`, only to a Mac that lists `momentAgreed`, is the phone's yes for each agent you said yes to
on it (by name, trimmed and lowercased, with the fingerprint it had then), sent only with a "Binders, …" said on its own,
not in a conversation, not through Siri, a Shortcut or a transcript, and scored as your voice past the start bar
Calibrate sets; the Mac starts an agent you let start on cards Binders sends it only with it, and checks where the moment
came from itself too. An older phone never sends it.

`mode`, only to a Mac that lists `momentAuto`, is the phone's Mode for what you say on your own when it was heard:
`suggest`, `add` or `auto`. In Add at Once and Auto mode the phone sends every kind in `adds`, so a Mac that
doesn't read `mode` adds them at once; one that does, in `auto`, also hands a to-do or an idea over (see
CAPTURE-ALLDAY.md, item 9). In Auto mode, `agreed` comes with something heard on its own too, when the phone heard it as
you on your own past the start bar, and `autoHold` says why it didn't when it didn't: `calibrate`, `audio` or `voice`. A
moment kept while the Mac was away goes as the mode the phone has when it's sent, if Auto mode was turned off since.
`alone`, only to a Mac that lists `momentAuto`, marks a moment said on its own that took the words of the conversation
that opened at its first word, with nothing said in the three minutes before it that no kept moment holds: the Mac reads
it as said on its own, while `conversation` keeps that id for a Mac that doesn't read `alone`.

To a Mac that lists `soloAuto`: `fromTranscript` marks a "Binders, …" found in the transcript of a capture the phone
vouched as only you, which waits for that capture (`conversation`) like any moment said in it; `uncued` is `fix`, `todo`
or `idea` for something kept in Auto mode without a cue, as the phone's rules read it.

```json
{"id": "9C3F21AA-5B1E-4C2D-9E61-0F6A4B2D7C11", "heard": "2026-10-16T09:12:40Z", "text": "remind me to call Sam tomorrow at 3",
 "device": "iPhone", "engine": "parakeet-v2", "wake": true, "seconds": 2.4}
```

The reply carries the outcome when the Mac decided in time. A phone whose Mac is away keeps the moment in its outbox as a
dictation carrying the moment, so it's sent once the Mac is back, and a phone downgraded meanwhile still sends its words
as a dictation. A moment sent again gets the same outcome and makes nothing twice.

### Conversations

All-day capture on the iPhone transcribes and labels speakers on the phone, then sends the text. The audio never leaves the
phone. Segment times are seconds since `started` on the wall clock; `speakers` names the labels it could
(see [CAPTURE-ALLDAY.md](CAPTURE-ALLDAY.md)).

```json
{"id": "3A02EC85-6FEF-4AF9-9231-14713C1AEB2F", "started": "2026-10-15T14:42:00Z", "ended": "2026-10-15T14:45:10Z",
 "device": "iPhone", "engine": "parakeet-v2", "speakers": {"Speaker 2": "You"},
 "segments": [
  {"id": "6F1D…", "channel": "microphone", "start": 2.0, "end": 6.1, "speaker": "Speaker 1",
   "text": "Hey, have you got a minute? It's about the launch email."},
  {"id": "0B7A…", "channel": "microphone", "start": 9.4, "end": 14.2, "speaker": "Speaker 2",
   "text": "Sure. I'll send Sam the final pricing email by Friday."}]}
```

To a Mac that lists `soloAuto`, from a phone whose Said to yourself Mode is Add at Once, or Auto once its new sheet was
seen, a conversation also carries `mode` (`add` or `auto`), `solo: true` when the phone heard only you in it
(its diarizer ran over the whole capture; every voice heard for two seconds at a stretch scored at or past the start bar
Calibrate sets; anything else under three seconds in at most two stretches; nothing played and no call on the phone
while it wrote speech), `soloHold` with why not, a word (`print`, `calibrate`, `diarizer`, `audio`, `call`,
`continues`, `voice`, `voices`, `dialogue`, `unsure`, `parts`, or a newer one), `soloMoments` (the moments said in it
that may go with it), in Auto mode with `solo` the phone's yes for each agent (`agreed`, as for a moment), and as
numbers the lowest of your voices' scores (`voice`) and the seconds of other speech let through (`otherSpeech`). A
segment the phone isn't sure is yours is labelled "Not sure who". `keptForMoment` marks a conversation kept, though
short, for a moment said in it: it comes with no segments. A capture waiting in the outbox goes as the phone's mode when
it's sent, never higher, and with only the yeses still given then. The Mac takes these only over the link, from a phone
whose hello listed `soloAuto`; in a Binders file they're never written, and they'd be ignored.

A 90-minute conversation is a few hundred kilobytes. One that would go past the 8 MB message cap is split by time into parts,
each with an id derived from the conversation's, so a part sent again is still recognised.

Notifications from the Mac: `binders/changed` `{kinds: ["notes", "todos", "meetings", "binders", "dictations", "tasks",
"other"]}`, sent whenever the database saves, grouped over a quarter of a second. To a phone that lists
`notification:binders/approval`, an agent's request for your approval comes as `binders/approval` with who asks, what,
exactly who it goes to and the exact text; the phone rings it with the title only on the Lock Screen. To a phone that
lists `notification:binders/addresses`, a change to the Mac's addresses comes as `binders/addresses` `{addresses}`, the
whole new list, whenever it differs from the last one that phone was given (also on `binders/subscribe`, before its
reply, for a phone whose hello came before the change). The phone keeps it in place of what it had.

Ask as it goes: to a Mac that lists `askProgress`, the phone adds a `progress_token` (a UUID) to `ask_knowledge`'s
arguments, and the Mac sends that phone `binders/ask-progress` `{token, seq, stage, sources?, text?}` while it works:
`keyword` with the passages that have the question's words, `sources` with the passages the answer draws on (both in
`ask_knowledge`'s reply shape), then `writing` with the whole answer so far, at most four times a second. The reply is
unchanged and has everything, so a phone that never sends a token, or a Mac that ignores one, works as before. Until the
first update, the phone says the Mac is looking it up and writing the answer. The Mac gives the whole answer, its search included, 180 seconds; if the wait ends early, what was written stays
on the phone with why. A checklist lives in a note or a meeting,
so a change to either also lists `todos`. Clients refetch what they show.

The Manager's requests change as `manager` in `binders/changed`: the phone asks `binders/manager-requests` again. Its
replies are the Manager's words, shown as its.

An agent's question arrives as `tasks`. The phone reads the Blocked cards (`list_tasks` with `column: blocked`, then
`get_task` for each card whose `updated` changed), rings each question once, and sends an answer as `comment_task {id,
text}`, the call the card's answer box makes. There's no new method for it.

An answer that can't go yet waits in answers.json, beside the outbox, and goes first once the Mac is back. It's kept apart
because a build of the app from before answers would send one the wrong way, be refused, and hold back everything
behind it. A Give to waits in handoffs.json for the same reason, written there before it's tried, and goes as `binders/outcome`
`assign` (a moment) or `update_task` with `for` (a card, then into Ready if it's still in Backlog). Each file is read one
item at a time, so an item this build can't read is left out alone, and a file that can't be opened while the iPhone is
locked (written by builds 6 to 9) is set aside and read once it opens, never written over.

## Testing

`BindersKit` has the client (`LinkClient`), and the Mac's self-test plays a phone against a server on spare ports, in a
throwaway folder:

```sh
BINDERS_DATA_DIR=$(mktemp -d) build/Build/Products/Release/Binders.app/Contents/MacOS/Binders --selftest-link
```

It pairs, checks the code can't be reused, proves the device, uses the tools, hears a change, and is shut out by a wrong
key and by removal. Then, on a fixed made-up scan of a Mac with Wi-Fi, Covee, WARP and a stopped Tailscale, where a
phone can reach the Mac: the pairing code, the addresses in a hello only to a phone that lists them, the notice when
they change (and on subscribe, for a phone whose hello came first), Tailscale running beside Covee, the hello's own
read, an address typed with the link's port, the parallel dial (one hello per connect, a stalled try never holding up
one that answers, hellos never overlapping, a refusal ending it, a wrong key, Test), a session that never says who it
is, Tailscale's tool through stand-ins (never the real one), this Mac's own interfaces (read only, printed as counts)
and the longest pairing code's QR size. A throwaway folder never reads the real network for the link: it gets a fixed
made-up scan, and no routing socket or 30 s read. `--selftest-link-serve` serves made-up addresses too, as the iPhone's
screenshots are taken against it, unless it's given `--real-network`, for a real iPhone on this network. `--selftest-conversation` plays a phone sending the day's conversations: kept once, written up with the
language model in Settings, filed in a binder, never shared, and small talk kept out of sight.
