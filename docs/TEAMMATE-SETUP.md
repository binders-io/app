# Setting up Binders (for teammates)

> Sharing is per **binder** now. Create a binder for each thing you work on, put meetings and notes in it, and flip its "Share with team" switch to share all of it. Binders shared with you appear in your sidebar under their owner's name.

Binders is a local voice dictation, meeting notes and knowledge app for Apple Silicon Macs. Everything runs on your Mac; only meetings and notes someone chooses to share go through your team's cloud folder.

## 1. Install

1. You need an Apple Silicon Mac on macOS 14.2 or later.
2. Unzip `Binders.zip` and move **Binders.app** to **Applications**.
3. The first time you open it, macOS will say it can't verify the developer. Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to Binders. (Or run `xattr -dr com.apple.quarantine /Applications/Binders.app` in Terminal.)

## 2. Install the local AI models

1. Install [Ollama](https://ollama.com/download) and open it.
2. In Terminal:

   ```sh
   ollama pull gemma4:26b      # writes notes and cleans up dictation (~17 GB; needs ~32 GB of RAM)
   ollama pull embeddinggemma  # powers meaning-based search (~620 MB)
   ```

   On a Mac with less memory, pull a smaller instruct model instead and pick it in **Binders → Settings → AI → Model**.

## 3. Grant permissions

The Home page walks you through it: **Microphone**, **Accessibility** (so the fn shortcut works everywhere), and the first time you record a meeting, **System Audio Recording** (so the other people on the call are captured). In **System Settings → Keyboard**, set **Press 🌐 key to** → **Do Nothing**.

## 4. Join the team space

1. Accept the shared folder invitation in OneDrive, Dropbox, Google Drive or iCloud Drive, and make sure the folder is synced to this Mac.
2. In Binders, open **Settings → Team → Join team space…** and choose that folder.
3. Set **Your name** so teammates see who shared what.

Shared meetings and notes appear in **Meetings**, **Notes** and **Knowledge** within a minute. Meetings are read-only for everyone but their author; shared notes can be edited by anyone, including in Obsidian (open the team folder as a vault).

## Using it

| Shortcut | Action |
|---|---|
| Hold **fn** | Dictate into any app |
| Hold **fn ⌃** | Command Mode, or ask "what did we decide about…?" |
| **⌥M** | Start / stop meeting notes |
| **⌥S** | Scratchpad |
