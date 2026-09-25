#!/usr/bin/env python3
"""Downloads, from the only place they are counted: the GitHub release assets. The site's button and the app's updater
both fetch from there, so DMG downloads are new installs and zip downloads are updates.

    scripts/download-stats.py            snapshot the counts, then report what changed since the last snapshot
    scripts/download-stats.py --report   report only

Snapshots go to dist/stats/downloads.csv (not committed). Also shows the repository's traffic for the last 14 days and
where its visitors came from. Needs the GitHub CLI (gh), signed in with access to the repository.
"""
import csv
import json
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

REPO = "binders-io/app"
LOG = Path(__file__).resolve().parent.parent / "dist" / "stats" / "downloads.csv"
KINDS = {".dmg": "new installs", ".zip": "updates", ".tar.gz": "scripts and packages"}


def gh(path):
    out = subprocess.run(["gh", "api", path, "--paginate"], capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f"gh api {path} failed: {out.stderr.strip()}")
    # --paginate concatenates JSON arrays page by page.
    text = out.stdout.strip().replace("][", ",")
    return json.loads(text) if text else []


def people(n):
    return f"{n} {'person' if n == 1 else 'people'}"


def kind(name):
    return next((label for ext, label in KINDS.items() if name.endswith(ext)), None)


def main():
    report_only = "--report" in sys.argv
    now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
    current = [(r["tag_name"], a["name"], a["download_count"]) for r in gh(f"repos/{REPO}/releases") for a in r["assets"] if kind(a["name"])]

    previous, last_time = {}, None
    if LOG.exists():
        rows = list(csv.DictReader(LOG.open()))
        if rows:
            last_time = rows[-1]["time"]
            previous = {(r["release"], r["asset"]): int(r["downloads"]) for r in rows if r["time"] == last_time}

    since = f"since {last_time}" if last_time else "first snapshot"
    print(f"Downloads of {REPO} release files          total   {since}")
    totals = {}
    for tag, name, count in current:
        delta = count - previous.get((tag, name), 0) if last_time else count
        totals[kind(name)] = totals.get(kind(name), 0) + count
        print(f"  {tag:<8} {name:<28} {kind(name):<22} {count:>6}   {'+' if delta >= 0 else ''}{delta}")
    print("  " + " · ".join(f"{label}: {totals.get(label, 0)}" for label in KINDS.values()))

    if not report_only:
        LOG.parent.mkdir(parents=True, exist_ok=True)
        new = not LOG.exists()
        with LOG.open("a", newline="") as f:
            writer = csv.writer(f)
            if new:
                writer.writerow(["time", "release", "asset", "downloads"])
            writer.writerows([now, tag, name, count] for tag, name, count in current)
        print(f"  Snapshot saved to {LOG.relative_to(Path.cwd()) if LOG.is_relative_to(Path.cwd()) else LOG}")

    views = gh(f"repos/{REPO}/traffic/views")
    clones = gh(f"repos/{REPO}/traffic/clones")
    referrers = gh(f"repos/{REPO}/traffic/popular/referrers")
    print(f"\nRepository, last 14 days: {views.get('count', 0)} views ({people(views.get('uniques', 0))}), "
          f"{clones.get('count', 0)} clones ({people(clones.get('uniques', 0))})")
    if referrers:
        print("Where visitors came from:")
        for r in referrers[:10]:
            print(f"  {r['referrer']:<32} {r['count']:>5} views  {people(r['uniques'])}")


if __name__ == "__main__":
    main()
