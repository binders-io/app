#!/bin/zsh
# Runs the BindersKit tests with coverage and prints a Markdown summary: totals, then every source file.
# Exits non-zero when the tests fail or line coverage is under the threshold (default 85).
#
#   scripts/coverage.sh            # table on stdout
#   scripts/coverage.sh 90         # stricter threshold
set -euo pipefail
cd "$(dirname "$0")/../Packages/BindersKit"
THRESHOLD="${1:-85}"

RESULT=$(swift test --enable-code-coverage 2>&1) || { echo "$RESULT" | tail -30; echo; echo "Tests failed."; exit 1; }
TESTS=$(echo "$RESULT" | grep -Eo "Executed [0-9]+ tests, with [0-9]+ failures" | tail -1)
REPORT=$(swift test --show-codecov-path | tail -1)

python3 - "$REPORT" "$THRESHOLD" "$TESTS" <<'PY'
import json, os, sys
report, threshold, tests = sys.argv[1], float(sys.argv[2]), sys.argv[3]
rows = []
for entry in json.load(open(report))["data"][0]["files"]:
    if "/Sources/BindersKit/" not in entry["filename"]:
        continue
    lines, functions = entry["summary"]["lines"], entry["summary"]["functions"]
    rows.append((os.path.basename(entry["filename"]), lines["covered"], lines["count"], functions["covered"], functions["count"]))
covered, total = sum(r[1] for r in rows), sum(r[2] for r in rows)
fcovered, ftotal = sum(r[3] for r in rows), sum(r[4] for r in rows)
percent = covered / total * 100
print(f"### BindersKit coverage\n")
print(f"{tests}. **{percent:.1f}% of lines** ({covered}/{total}) and **{fcovered / ftotal * 100:.1f}% of functions** ({fcovered}/{ftotal}) across {len(rows)} source files.\n")
print("| File | Lines | Covered |")
print("|---|---:|---:|")
for name, c, t, _, _ in sorted(rows, key=lambda r: (r[1] / max(r[2], 1), r[0])):
    print(f"| `{name}` | {t} | {c / max(t, 1) * 100:.1f}% |")
if percent < threshold:
    print(f"\nLine coverage {percent:.1f}% is under the {threshold:.0f}% threshold.")
    sys.exit(1)
PY
