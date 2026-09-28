# Sharing binders with a team

Binders shares through a folder you already sync, such as OneDrive, Dropbox, Google Drive or iCloud Drive. There is no server
in between, and nothing is shared until someone flips a binder's switch.

## Set up

1. One person makes a folder for the team inside their cloud drive (not the top of the drive itself, which can't be shared as a
   whole), chooses **Settings → Team → Create team space…** on it, and shares **that folder** with the others, with permission
   to edit. It holds `Meetings`, `Notes` and `_binders`; share the folder around them, not `_binders` alone.
2. Everyone else adds the shared folder to their own drive, which is what brings it to their Mac: in OneDrive, open **Shared**
   on the web and choose **Add shortcut to My files** (or **Sync**); in Google Drive, **Add shortcut to Drive**; in Dropbox,
   **Add to my Dropbox**. Once it shows up in Finder, they choose **Settings → Team → Join team space…** and pick it. Picking
   a folder inside it, or the drive it sits in, works too.
3. Set **Your name** in the same place, so teammates see who shared what. It starts as the name on your Mac account.

If Join says there's no team space, run this in Terminal: it lists every team space your drives have brought to the Mac.

```
find ~/Library/CloudStorage -maxdepth 4 -path '*_binders/team.json'
```

A path like `…/Alex Doe - _binders/team.json` means only the `_binders` folder was shared or synced: share and add the folder
around it instead. No output means the shared folder hasn't reached the Mac yet.

## Who is who

There are no accounts. Each Mac gets a random member id the first time Binders runs, and your name comes from
**Settings → Team → Your name**. Everything you share carries both, and each Mac keeps a small file in `_binders/members`
with its name and when it last synced, which is how the Members list is filled in. Who can join is decided by the drive:
anyone the folder is shared with, with permission to edit, can join.

## Sharing

Sharing is per binder. Open a binder and switch on **Share with team**: its meetings and notes are written to the team folder,
and the binder appears in your teammates' sidebars within a minute or so. Switch it off and your items are withdrawn.

- Shared meetings are read-only for everyone but their author.
- Shared notes can be edited by anyone. If two people edit the same note at once, the team's version stays and your own edit is
  saved as a private note, so nothing is lost.
- Shared items show up in teammates' search, answers and knowledge graph, marked with who they came from.
- The team folder holds plain Markdown with front matter, so it also opens as an Obsidian vault.

Audio never goes to the team folder. Only notes, summaries and transcripts of what you chose to share do.
