# The phone link

How an iPhone, or any paired client, talks to Binders on a Mac. The Mac is the server and the only writer; clients are
paired devices. Nothing goes through a server of ours: the connection runs over the local network, or over Tailscale
when you're away.

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
- Device keys live in `~/Library/Application Support/Binders/link-devices.json`, readable only by you.

## Finding the Mac

- On the local network, the Mac advertises `_binders._tcp` with Bonjour.
- The QR code lists every address to try: local network first, then Tailscale. Binders asks Tailscale for its own
  address, so other VPNs in the same 100.64.0.0/10 range aren't offered.

## Messages

Newline-delimited JSON-RPC 2.0, the same framing as `Binders --mcp`. One message per line, at most 8 MB.

| Method | When | Result |
|---|---|---|
| `binders/pair` `{name}` | pairing port only | `{device, key, name, protocol}` (the key is base64) |
| `binders/challenge` | first, on 7447 | `{challenge}` (base64, 32 bytes) |
| `binders/hello` `{device, proof, name, protocol}` | after the challenge | `{name, version, protocol}` |
| `binders/subscribe` | after hello | `{}`; the Mac then sends `binders/changed` |
| `initialize`, `tools/list`, `tools/call` | after hello | the same tools as the MCP server (see [AUTOMATIONS.md](AUTOMATIONS.md)) |

Notifications from the Mac: `binders/changed` `{kinds: ["notes", "todos", "meetings", "binders", "dictations", "other"]}`,
sent whenever the database saves, grouped over a quarter of a second. A checklist lives in a note or a meeting, so a
change to either also lists `todos`. Clients refetch what they show.

## Testing

`BindersKit` has the client (`LinkClient`), and the Mac's self-test plays a phone against a server on spare ports, in a
throwaway folder:

```sh
BINDERS_DATA_DIR=$(mktemp -d) build/Build/Products/Release/Binders.app/Contents/MacOS/Binders --selftest-link
```

It pairs, checks the code can't be reused, proves the device, uses the tools, hears a change, and is shut out by a wrong
key and by removal.
