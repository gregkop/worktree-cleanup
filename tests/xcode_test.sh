#!/usr/bin/env bash
# Fixture for the macOS Xcode/iOS cache report. Runs on Linux by setting
# XCODE_SCAN_ENABLE=1 and stubbing xcrun. Does not touch the real $HOME.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
XCODE="$HERE/../scripts/scan_xcode.sh"
SCAN="$HERE/../scripts/scan_worktrees.sh"
SB=$(mktemp -d "${TMPDIR:-/tmp}/xcode-sandbox.XXXXXX")
SB=$(cd "$SB" && pwd -P)
H="$SB/home"
mkdir -p "$H"
fail=0

old_stamp=$(date -d '30 days ago' +%Y%m%d%H%M 2>/dev/null || date -v-30d +%Y%m%d%H%M)
age() { touch -t "$old_stamp" "$@"; }

# ---- fake xcrun -------------------------------------------------------------
BIN="$SB/bin"
mkdir -p "$BIN"
cat > "$BIN/xcrun" <<'EOF'
#!/bin/sh
[ "$1" = "simctl" ] || exit 1
shift
if [ "$1" = "list" ] && [ "$2" = "devices" ]; then
  cat <<'OUT'
== Devices ==
-- iOS 17.5 --
    iPhone 15 (AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE) (Shutdown) (unavailable)
-- iOS 18.0 --
    iPhone 16 (BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF) (Booted)
== Unavailable ==
    iPhone SE (3rd generation) (CCCCCCCC-DDDD-EEEE-FFFF-000000000001) (Shutdown) (unavailable)
OUT
  exit 0
fi
if [ "$1" = "list" ] && [ "$2" = "runtimes" ]; then
  cat <<'OUT'
== Runtimes ==
iOS 17.5 (17.5 - 21F79) - com.apple.CoreSimulator.SimRuntime.iOS-17-5
iOS 16.4 (16.4 - 20E247) - com.apple.CoreSimulator.SimRuntime.iOS-16-4 (unavailable)
OUT
  exit 0
fi
exit 1
EOF
chmod +x "$BIN/xcrun"

# ---- DerivedData, simulators, device support, archives ----------------------
DD="$H/Library/Developer/Xcode/DerivedData"
SRC="$SB/src"
mkdir -p "$SRC/Stale App" "$SRC/Fresh"
touch "$SRC/Stale App/Stale.xcworkspace" "$SRC/Fresh/Fresh.xcodeproj"

write_plist() { # $1 file, $2 workspace path
  cat > "$1" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>WorkspacePath</key>
  <string>$2</string>
</dict>
</plist>
EOF
}

mkdir -p "$DD/OldApp-aaaaaaaa"
write_plist "$DD/OldApp-aaaaaaaa/info.plist" "$SRC/Old App/Old.xcworkspace"
echo old > "$DD/OldApp-aaaaaaaa/log"
age "$DD/OldApp-aaaaaaaa" "$DD/OldApp-aaaaaaaa/info.plist" "$DD/OldApp-aaaaaaaa/log"

mkdir -p "$DD/StaleApp-bbbbbbbb/Build"
write_plist "$DD/StaleApp-bbbbbbbb/info.plist" "$SRC/Stale App/Stale.xcworkspace"
echo stale > "$DD/StaleApp-bbbbbbbb/Build/out"
age "$DD/StaleApp-bbbbbbbb" "$DD/StaleApp-bbbbbbbb/info.plist" "$DD/StaleApp-bbbbbbbb/Build"

mkdir -p "$DD/FreshApp-cccccccc/Build"
write_plist "$DD/FreshApp-cccccccc/info.plist" "$SRC/Fresh/Fresh.xcodeproj"
echo fresh > "$DD/FreshApp-cccccccc/Build/out"

mkdir -p "$DD/GoneRecent-eeeeeeee"
write_plist "$DD/GoneRecent-eeeeeeee/info.plist" "$SRC/Gone/Gone.xcodeproj"
echo gone > "$DD/GoneRecent-eeeeeeee/log"

mkdir -p "$DD/StringsApp-dddddddd"
printf 'junk\0WorkspacePath\0%s\0tail\n' "$SRC/Strings/App.xcodeproj" > "$DD/StringsApp-dddddddd/info.plist"
echo strings > "$DD/StringsApp-dddddddd/log"
age "$DD/StringsApp-dddddddd" "$DD/StringsApp-dddddddd/info.plist" "$DD/StringsApp-dddddddd/log"

mkdir -p "$DD/ModuleCache.noindex"
echo cache > "$DD/ModuleCache.noindex/mod"
age "$DD/ModuleCache.noindex" "$DD/ModuleCache.noindex/mod"

mkdir -p "$DD/FreshCache.noindex"
echo cache > "$DD/FreshCache.noindex/mod"

SIM="$H/Library/Developer/CoreSimulator/Devices"
mkdir -p \
  "$SIM/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/data" \
  "$SIM/CCCCCCCC-DDDD-EEEE-FFFF-000000000001/data" \
  "$SIM/BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF/data"
echo sim > "$SIM/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE/data/disk"
echo sim > "$SIM/CCCCCCCC-DDDD-EEEE-FFFF-000000000001/data/disk"
echo sim > "$SIM/BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF/data/disk"

RT="$H/Library/Developer/CoreSimulator/Profiles/Runtimes/iOS 16.4.simruntime"
mkdir -p "$RT"
echo runtime > "$RT/bundle"

DS="$H/Library/Developer/Xcode/iOS DeviceSupport"
mkdir -p "$DS/iPhone14,2 16.0 (20A362)" "$DS/iPhone15,2 18.0 (22A335)"
echo sym > "$DS/iPhone14,2 16.0 (20A362)/Symbols"
echo sym > "$DS/iPhone15,2 18.0 (22A335)/Symbols"
age "$DS/iPhone14,2 16.0 (20A362)" "$DS/iPhone14,2 16.0 (20A362)/Symbols"

ARCH="$H/Library/Developer/Xcode/Archives/2024-01-02/App.xcarchive"
mkdir -p "$ARCH"
echo archive > "$ARCH/Info.plist"

export HOME="$H" PATH="$BIN:$PATH" XCODE_RUNNING=0
unset XCODE_DERIVED_DATA XCODE_SIM_DEVICES XCODE_DEVICE_SUPPORT XCODE_ARCHIVES XCODE_SIM_RUNTIMES XCODE_SCAN_ENABLE

echo "== linux skip (dirs exist, enable off) =="
skip_json=$("$XCODE" --json)
printf '%s\n' "$skip_json" | python3 -c '
import json,sys
d=json.load(sys.stdin)
assert d["skipped"] is True and d["reason"] == "not macOS", d
'
mkdir -p "$SB/empty-root"
wt_skip=$("$SCAN" --no-agent-dirs --json "$SB/empty-root")
python3 -c '
import json,sys
d=json.loads(sys.argv[1])
assert d["xcode"]["skipped"] is True
assert d["xcode"]["reason"] == "not macOS"
assert "cargo" in d
' "$wt_skip"
export XCODE_SCAN_ENABLE=1

echo "== scan =="
"$XCODE" > "$SB/text.txt"
"$XCODE" --json > "$SB/xcode.json"
"$XCODE" --plan > "$SB/plan.txt"
"$XCODE" --stale-days 0 --json > "$SB/stale0.json"
XCODE_RUNNING=1 "$XCODE" --json > "$SB/running.json"
XCODE_RUNNING=1 "$XCODE" --plan > "$SB/running-plan.txt"

python3 - "$SB/xcode.json" "$SB/stale0.json" "$SB/running.json" "$SRC" <<'PY'
import json, sys
main, stale0, running, src = sys.argv[1:]
d = json.load(open(main))
assert d["skipped"] is False
assert d["xcode_running"] is False
assert d["stale_days"] == 14
folders = {f["name"]: f for f in d["derived_data"]["folders"]}
def need(name, verdict, source):
    f = folders[name]
    assert f["verdict"] == verdict, (name, f["verdict"], verdict)
    assert f["source"] == source, (name, f)
    assert f["size_kb"] > 0, f
    return f
old = need("OldApp-aaaaaaaa", "SAFE", "missing")
assert "Old App" in old["workspace_path"]
assert old["idle_days"] >= 14
stale = need("StaleApp-bbbbbbbb", "SAFE", "exists")
assert stale["idle_days"] >= 14
assert "Stale App" in stale["workspace_path"]
need("FreshApp-cccccccc", "REVIEW", "exists")
gone = need("GoneRecent-eeeeeeee", "SAFE", "missing")
assert gone["idle_days"] is not None and gone["idle_days"] < 14
strings = need("StringsApp-dddddddd", "SAFE", "missing")
assert strings["workspace_path"].endswith("App.xcodeproj")
assert strings["idle_days"] >= 14
need("ModuleCache.noindex", "SAFE", "unknown")
need("FreshCache.noindex", "REVIEW", "unknown")
assert d["derived_data"]["total_kb"] > 0

sims = {s["udid"]: s for s in d["simulators"]["unavailable"]}
assert set(sims) == {
    "AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE",
    "CCCCCCCC-DDDD-EEEE-FFFF-000000000001",
}
assert sims["AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"]["name"] == "iPhone 15"
assert sims["AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"]["runtime"] == "iOS 17.5"
assert sims["AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE"]["size_kb"] > 0
assert sims["CCCCCCCC-DDDD-EEEE-FFFF-000000000001"]["name"] == "iPhone SE (3rd generation)"
assert "BBBBBBBB-CCCC-DDDD-EEEE-FFFFFFFFFFFF" not in sims
assert d["simulators"]["unavailable_kb"] > 0

rts = d["runtimes"]["unavailable"]
assert len(rts) == 1 and "iOS 16.4" in rts[0]["line"]
assert rts[0]["path"].endswith("iOS 16.4.simruntime")
assert rts[0]["size_kb"] > 0

versions = {v["name"]: v for v in d["device_support"]["versions"]}
assert versions["iPhone14,2 16.0 (20A362)"]["old"] is True
assert versions["iPhone14,2 16.0 (20A362)"]["idle_days"] >= 14
assert versions["iPhone15,2 18.0 (22A335)"]["old"] is False
assert d["device_support"]["report_only"] is True
assert d["archives"]["report_only"] is True
assert d["archives"]["total_kb"] > 0
assert d["archives"]["present"] is True

z = json.load(open(stale0))
zfolders = {f["name"]: f for f in z["derived_data"]["folders"]}
assert zfolders["FreshApp-cccccccc"]["verdict"] == "SAFE"
assert zfolders["FreshCache.noindex"]["verdict"] == "SAFE"

r = json.load(open(running))
assert r["xcode_running"] is True
for f in r["derived_data"]["folders"]:
    assert f["verdict"] == "REVIEW", f["name"]
assert len(r["simulators"]["unavailable"]) == 2
print("json assertions ok")
PY

plan=$(cat "$SB/plan.txt")
for name in OldApp-aaaaaaaa StaleApp-bbbbbbbb GoneRecent-eeeeeeee StringsApp-dddddddd ModuleCache.noindex; do
  c=$(cd "$DD/$name" && pwd -P)
  if printf '%s\n' "$plan" | grep -F "rm -rf '$c'" >/dev/null; then
    printf 'ok    plan rm %s\n' "$name"
  else
    printf 'FAIL  plan missing rm for %s\n' "$name"; fail=1
  fi
done
for name in FreshApp-cccccccc FreshCache.noindex; do
  c=$(cd "$DD/$name" && pwd -P)
  if printf '%s\n' "$plan" | grep -F "rm -rf '$c'" >/dev/null; then
    printf 'FAIL  plan removed fresh %s\n' "$name"; fail=1
  else
    printf 'ok    plan keeps %s\n' "$name"
  fi
done
if printf '%s\n' "$plan" | grep -qx 'xcrun simctl delete unavailable'; then
  echo 'ok    plan simctl'
else
  echo 'FAIL  missing simctl delete'; fail=1
fi
if printf '%s\n' "$plan" | grep '^rm ' | grep -E 'Archives|DeviceSupport|CoreSimulator' >/dev/null; then
  echo 'FAIL  plan rm touches archives, device support, or simulators'; fail=1
else
  echo 'ok    plan leaves archives, device support, and simulator dirs'
fi

run_plan=$(cat "$SB/running-plan.txt")
if printf '%s\n' "$run_plan" | grep '^rm ' >/dev/null; then
  echo 'FAIL  plan rm while Xcode is running'; fail=1
else
  echo 'ok    no DerivedData rm while Xcode is running'
fi
if printf '%s\n' "$run_plan" | grep -qx 'xcrun simctl delete unavailable'; then
  echo 'ok    simctl still planned while Xcode is running'
else
  echo 'FAIL  simctl dropped while Xcode is running'; fail=1
fi

# Nothing removed.
if [ -d "$DD/OldApp-aaaaaaaa" ] && [ -d "$ARCH" ] && [ -d "$SIM/AAAAAAAA-BBBB-CCCC-DDDD-EEEEEEEEEEEE" ]; then
  echo 'ok    fixture still on disk'
else
  echo 'FAIL  scanner deleted something'; fail=1
fi

# Text report mentions the sections.
grep -q 'Xcode / iOS caches' "$SB/text.txt" || { echo 'FAIL  text header'; fail=1; }
grep -q 'Archives (report only' "$SB/text.txt" || { echo 'FAIL  archives line'; fail=1; }

echo
if [ $fail = 0 ]; then echo "ALL XCODE CHECKS PASSED"; else echo "SOME XCODE CHECKS FAILED"; fi
exit $fail
