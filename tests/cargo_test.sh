#!/usr/bin/env bash
# Cargo target discovery: adjacent target/ dirs, CARGO_TARGET_DIR, and the
# report-only ~/.cargo caches. Uses a fake cargo on PATH for the clean plan.
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
CARGO_SCAN="$HERE/../scripts/scan_cargo.sh"
SCAN="$HERE/../scripts/scan_worktrees.sh"
SB=$(mktemp -d "${TMPDIR:-/tmp}/cargo-sandbox.XXXXXX")
SB=$(cd "$SB" && pwd -P)
H="$SB/home"
mkdir -p "$H"
fail=0

old_stamp=$(date -d '30 days ago' +%Y%m%d%H%M 2>/dev/null || date -v-30d +%Y%m%d%H%M)
age() { touch -t "$old_stamp" "$@"; }

BIN="$SB/bin"
mkdir -p "$BIN"
cat > "$BIN/cargo" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$BIN/cargo"

PROJ="$H/code/app"
mkdir -p "$PROJ/crates/foo" "$PROJ/stray/target/debug" "$PROJ/no-manifest/target"
printf '[package]\nname = "app"\nversion = "0.1.0"\n' > "$PROJ/Cargo.toml"
printf '[package]\nname = "foo"\nversion = "0.1.0"\n' > "$PROJ/crates/foo/Cargo.toml"
mkdir -p "$PROJ/target/debug" "$PROJ/crates/foo/target/debug"
echo root-build > "$PROJ/target/debug/app"
echo member-build > "$PROJ/crates/foo/target/debug/foo"
echo stray-build > "$PROJ/stray/target/debug/nope"
echo orphan-build > "$PROJ/no-manifest/target/blob"
age "$PROJ/target" "$PROJ/target/debug" "$PROJ/target/debug/app"

# Report-only cargo home caches.
mkdir -p "$H/.cargo/registry/cache" "$H/.cargo/git/checkouts"
echo reg > "$H/.cargo/registry/cache/crate.tgz"
echo git > "$H/.cargo/git/checkouts/repo"

export HOME="$H" CARGO_BUILD_RUNNING=0
unset CARGO_TARGET_DIR CARGO_HOME

echo "== per-project targets, cargo on PATH =="
PATH="$BIN:/usr/bin:/bin" "$CARGO_SCAN" --json "$PROJ" > "$SB/cargo.json"
PATH="$BIN:/usr/bin:/bin" "$CARGO_SCAN" --plan "$PROJ" > "$SB/plan-cargo.txt"
PATH="/usr/bin:/bin" "$CARGO_SCAN" --plan "$PROJ" > "$SB/plan-rm.txt"
CARGO_BUILD_RUNNING=1 PATH="$BIN:/usr/bin:/bin" "$CARGO_SCAN" --json "$PROJ" > "$SB/busy.json"
CARGO_BUILD_RUNNING=1 PATH="$BIN:/usr/bin:/bin" "$CARGO_SCAN" --plan "$PROJ" > "$SB/busy-plan.txt"

python3 - "$SB/cargo.json" "$SB/busy.json" "$PROJ" "$H" <<'PY'
import json, sys
main, busy, proj, home = sys.argv[1:]
d = json.load(open(main))
assert d["cargo_on_path"] is True
assert d["build_running"] is False
assert d["shared_only"] is False
paths = {t["path"]: t for t in d["targets"]}
root = paths[proj + "/target"]
member = paths[proj + "/crates/foo/target"]
assert root["verdict"] == "SAFE" and root["shared"] is False
assert root["manifest"] == proj + "/Cargo.toml"
assert root["size_kb"] > 0 and root["idle_days"] >= 14
assert member["verdict"] == "SAFE"
assert member["manifest"] == proj + "/crates/foo/Cargo.toml"
assert member["idle_days"] is not None and member["idle_days"] < 14
blob = json.dumps(d)
assert proj + "/stray/target" not in blob
assert proj + "/no-manifest/target" not in blob
assert d["caches"]["registry_cache"]["present"] is True
assert d["caches"]["registry_cache"]["report_only"] is True
assert d["caches"]["registry_cache"]["size_kb"] > 0
assert d["caches"]["git_checkouts"]["present"] is True
assert d["caches"]["git_checkouts"]["path"] == home + "/.cargo/git/checkouts"
b = json.load(open(busy))
assert b["build_running"] is True
assert b["targets"] and all(t["verdict"] == "REVIEW" for t in b["targets"])
print("json assertions ok")
PY

plan=$(cat "$SB/plan-cargo.txt")
if printf '%s\n' "$plan" | grep -F "cargo clean --manifest-path '$PROJ/Cargo.toml'" >/dev/null; then
  echo 'ok    cargo clean root'
else
  echo 'FAIL  missing cargo clean for root'; fail=1
fi
if printf '%s\n' "$plan" | grep -F "cargo clean --manifest-path '$PROJ/crates/foo/Cargo.toml'" >/dev/null; then
  echo 'ok    cargo clean member'
else
  echo 'FAIL  missing cargo clean for member'; fail=1
fi
if printf '%s\n' "$plan" | grep -v '^#' | grep -E 'rm |stray|no-manifest|registry/cache|git/checkouts' >/dev/null; then
  echo 'FAIL  cargo plan removes the wrong thing'; fail=1
else
  echo 'ok    cargo plan has no rm, stray target, or cargo caches'
fi

rmplan=$(cat "$SB/plan-rm.txt")
if printf '%s\n' "$rmplan" | grep -F "rm -rf '$PROJ/target'" >/dev/null; then
  echo 'ok    rm fallback for root target'
else
  echo 'FAIL  missing rm fallback'; fail=1
fi
if printf '%s\n' "$rmplan" | grep -F "rm -rf '$PROJ/crates/foo/target'" >/dev/null; then
  echo 'ok    rm fallback for member target'
else
  echo 'FAIL  missing member rm'; fail=1
fi
if printf '%s\n' "$rmplan" | grep '^cargo ' >/dev/null; then
  echo 'FAIL  cargo clean planned without cargo'; fail=1
else
  echo 'ok    no cargo clean when cargo is absent'
fi
if printf '%s\n' "$rmplan" | grep '^rm ' | grep -E 'stray|no-manifest|registry/cache|git/checkouts' >/dev/null; then
  echo 'FAIL  rm fallback touched a non-adjacent target or a cache'; fail=1
else
  echo 'ok    rm fallback stays on adjacent target directories'
fi

if printf '%s\n' "$(cat "$SB/busy-plan.txt")" | grep -E '^(cargo |rm )' >/dev/null; then
  echo 'FAIL  plan ran while cargo was busy'; fail=1
else
  echo 'ok    no cleanup while a build is running'
fi

echo "== CARGO_TARGET_DIR replaces per-project targets =="
SHARED="$SB/shared-cargo-out"
mkdir -p "$SHARED/debug"
echo shared > "$SHARED/debug/out"
# Local targets are larger so a double count would show up in safe_kb.
dd if=/dev/zero of="$PROJ/target/debug/big" bs=1024 count=512 2>/dev/null
dd if=/dev/zero of="$SHARED/debug/big" bs=1024 count=64 2>/dev/null
CARGO_TARGET_DIR="$SHARED" CARGO_BUILD_RUNNING=0 PATH="$BIN:/usr/bin:/bin" \
  "$CARGO_SCAN" --json "$PROJ" > "$SB/shared.json"
CARGO_TARGET_DIR="$SHARED" CARGO_BUILD_RUNNING=0 PATH="$BIN:/usr/bin:/bin" \
  "$CARGO_SCAN" --plan "$PROJ" > "$SB/shared-plan.txt"
python3 - "$SB/shared.json" "$PROJ" "$SHARED" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
proj, shared = sys.argv[2], sys.argv[3]
assert d["shared_only"] is True
assert d["cargo_target_dir"] == shared
assert len(d["targets"]) == 1, d["targets"]
t = d["targets"][0]
assert t["path"] == shared and t["shared"] is True and t["verdict"] == "SAFE"
assert t["size_kb"] < 200, t
blob = json.dumps(d["targets"])
assert proj + "/target" not in blob
assert proj + "/crates/foo/target" not in blob
print("shared target ok")
PY
shared_plan=$(cat "$SB/shared-plan.txt")
# One cargo clean is enough for the shared directory.
n=$(printf '%s\n' "$shared_plan" | grep -c '^cargo clean ' || true)
if [ "$n" = 1 ]; then
  echo 'ok    one cargo clean for the shared dir'
else
  echo "FAIL  expected 1 cargo clean, got $n"; fail=1
fi
if printf '%s\n' "$shared_plan" | grep -F "$PROJ/target" >/dev/null; then
  echo 'FAIL  shared plan still names a project target'; fail=1
else
  echo 'ok    shared plan does not name project targets'
fi

echo "== scan_worktrees picks up repo and worktree targets =="
export GIT_AUTHOR_NAME=sandbox GIT_AUTHOR_EMAIL=sandbox@example.com
export GIT_COMMITTER_NAME=sandbox GIT_COMMITTER_EMAIL=sandbox@example.com
export GIT_CONFIG_NOSYSTEM=1
git -c init.defaultBranch=main init -q "$PROJ"
git -C "$PROJ" add Cargo.toml crates/foo/Cargo.toml
git -C "$PROJ" commit -q -m init
git -C "$PROJ" worktree add -q "$H/code/app-wt" -b agent/build
mkdir -p "$H/code/app-wt/target/debug"
echo wt > "$H/code/app-wt/target/debug/out"
# The worktree has the root Cargo.toml from the branch. Stray target is untracked
# in the main repo and must stay out of the plan.
unset CARGO_TARGET_DIR
PATH="$BIN:/usr/bin:/bin" CARGO_BUILD_RUNNING=0 \
  "$SCAN" --no-agent-dirs --json "$H/code" > "$SB/wt.json"
PATH="$BIN:/usr/bin:/bin" CARGO_BUILD_RUNNING=0 \
  "$SCAN" --no-agent-dirs --plan "$H/code" > "$SB/wt-plan.txt"
python3 - "$SB/wt.json" "$PROJ" "$H/code/app-wt" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
proj, wt = sys.argv[2], sys.argv[3]
assert d["xcode"]["skipped"] is True
paths = {t["path"] for t in d["cargo"]["targets"]}
assert proj + "/target" in paths
assert proj + "/crates/foo/target" in paths
assert wt + "/target" in paths
assert all(t["verdict"] == "SAFE" for t in d["cargo"]["targets"])
blob = json.dumps(d["cargo"]["targets"])
assert proj + "/stray/target" not in blob
assert proj + "/no-manifest/target" not in blob
print("worktree integration ok")
PY
wtplan=$(cat "$SB/wt-plan.txt")
if printf '%s\n' "$wtplan" | grep -F "cargo clean --manifest-path '$H/code/app-wt/Cargo.toml'" >/dev/null; then
  echo 'ok    worktree cargo clean'
else
  echo 'FAIL  worktree target missing from plan'; fail=1
fi
if printf '%s\n' "$wtplan" | grep '^rm \|^cargo ' | grep -E 'stray|no-manifest|registry/cache|Archives|DerivedData' >/dev/null; then
  echo 'FAIL  worktree plan escaped the cargo targets'; fail=1
else
  echo 'ok    worktree plan stays on cargo clean lines'
fi

# Scanner is read-only.
if [ -f "$PROJ/target/debug/app" ] && [ -f "$PROJ/stray/target/debug/nope" ] && [ -f "$H/.cargo/registry/cache/crate.tgz" ]; then
  echo 'ok    nothing deleted'
else
  echo 'FAIL  scanner deleted a fixture'; fail=1
fi

echo
if [ $fail = 0 ]; then echo "ALL CARGO CHECKS PASSED"; else echo "SOME CARGO CHECKS FAILED"; fi
exit $fail
