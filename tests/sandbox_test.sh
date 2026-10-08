#!/usr/bin/env bash
# Builds a throwaway sandbox of repos + worktrees covering every verdict path,
# runs scan_worktrees.sh against it with HOME pointed at the sandbox, and
# checks the verdicts. Only touches the sandbox directory it creates.
#
# Usage: tests/sandbox_test.sh [SANDBOX_DIR]   (default: a new mktemp dir)
set -eu

HERE=$(cd "$(dirname "$0")" && pwd)
SCAN="$HERE/../scripts/scan_worktrees.sh"
SB=${1:-$(mktemp -d "${TMPDIR:-/tmp}/wt-sandbox.XXXXXX")}
mkdir -p "$SB"; SB=$(cd "$SB" && pwd -P)
H="$SB/home"
mkdir -p "$H/code" "$SB/remotes"

export GIT_AUTHOR_NAME=sandbox GIT_AUTHOR_EMAIL=sandbox@example.com
export GIT_COMMITTER_NAME=sandbox GIT_COMMITTER_EMAIL=sandbox@example.com
export GIT_CONFIG_NOSYSTEM=1 HOME="$H"
unset CODEX_HOME TMPDIR
g() { git -c init.defaultBranch=main -c advice.detachedHead=false "$@"; }

old_stamp=$(date -d '30 days ago' +%Y%m%d%H%M 2>/dev/null || date -v-30d +%Y%m%d%H%M)
age() {   # make a worktree look idle for 30 days
  local wt=$1 gd
  gd=$(git -C "$wt" rev-parse --absolute-git-dir)
  for f in "$wt" "$gd/index" "$gd/HEAD" "$gd/logs/HEAD"; do
    [ -e "$f" ] && touch -t "$old_stamp" "$f"
  done
}
commit() { echo "$2" >> "$1/$3"; g -C "$1" add -A; g -C "$1" commit -q -m "$2"; }

# ---- repo "webapp" with a bare origin -------------------------------------
g init -q --bare "$SB/remotes/webapp.git"
g clone -q "$SB/remotes/webapp.git" "$H/code/webapp" 2>/dev/null
W="$H/code/webapp"
printf 'node_modules/\n.claude/worktrees/\n' > "$W/.gitignore"
commit "$W" "initial" README.md
g -C "$W" push -q -u origin main
g -C "$W" remote set-head origin -a >/dev/null

# 1. clean + merged (Cursor), with an ignored node_modules to show regenerable bloat
g -C "$W" worktree add -q "$H/.cursor/worktrees/webapp/abc1" -b feat/merged
commit "$H/.cursor/worktrees/webapp/abc1" "merged feature" feature.txt
mkdir -p "$H/.cursor/worktrees/webapp/abc1/node_modules/big"
dd if=/dev/zero of="$H/.cursor/worktrees/webapp/abc1/node_modules/big/blob" bs=1024 count=6144 2>/dev/null
g -C "$W" merge -q --no-ff -m "merge feat/merged" feat/merged
g -C "$W" push -q origin main
age "$H/.cursor/worktrees/webapp/abc1"

# 2. dirty (Claude Code, in-repo .claude/worktrees)
g -C "$W" worktree add -q "$W/.claude/worktrees/refactor" -b worktree-refactor
echo "half-done edit" >> "$W/.claude/worktrees/refactor/README.md"
echo "scratch" > "$W/.claude/worktrees/refactor/notes.txt"
age "$W/.claude/worktrees/refactor"

# 3. unpushed commits (Conductor)
g -C "$W" worktree add -q "$H/conductor/workspaces/webapp/oslo" -b feat/unpushed
commit "$H/conductor/workspaces/webapp/oslo" "wip 1" wip.txt
commit "$H/conductor/workspaces/webapp/oslo" "wip 2" wip.txt
age "$H/conductor/workspaces/webapp/oslo"

# 4. prunable: directory deleted by hand (Superset)
g -C "$W" worktree add -q "$H/.superset/worktrees/webapp/fix-typo" -b fix-typo
rm -rf "$H/.superset/worktrees/webapp/fix-typo"

# 5. squash-merged on the remote, remote branch deleted -> upstream [gone]
g -C "$W" worktree add -q "$H/.cursor/worktrees/webapp/sq9" -b feat/squash
commit "$H/.cursor/worktrees/webapp/sq9" "squash part 1" squash.txt
commit "$H/.cursor/worktrees/webapp/sq9" "squash part 2" squash.txt
g -C "$H/.cursor/worktrees/webapp/sq9" push -q -u origin feat/squash
g clone -q "$SB/remotes/webapp.git" "$SB/other-clone" 2>/dev/null
g -C "$SB/other-clone" merge -q --squash origin/feat/squash >/dev/null
g -C "$SB/other-clone" commit -q -m "feat: squash (#12)"
g -C "$SB/other-clone" push -q origin main
g -C "$SB/other-clone" push -q origin --delete feat/squash
g -C "$W" fetch -q --prune
age "$H/.cursor/worktrees/webapp/sq9"

# 6a. Codex-style detached worktree, old -> SAFE ; 6b. same but recent -> REVIEW
g -C "$W" worktree add -q --detach "$H/.codex/worktrees/1a2b/webapp" main
age "$H/.codex/worktrees/1a2b/webapp"
g -C "$W" worktree add -q --detach "$H/.codex/worktrees/9f8e/webapp" main

# 7. pushed but not merged (open PR)
g -C "$W" worktree add -q "$H/.cursor/worktrees/webapp/pr7" -b feat/open-pr
commit "$H/.cursor/worktrees/webapp/pr7" "open pr" pr.txt
g -C "$H/.cursor/worktrees/webapp/pr7" push -q -u origin feat/open-pr
age "$H/.cursor/worktrees/webapp/pr7"

# 8. locked by an agent
g -C "$W" worktree add -q "$H/.claude-squad/worktrees/task_17a" -b squad/task
g -C "$W" worktree lock --reason "claude-squad session running" "$H/.claude-squad/worktrees/task_17a"
age "$H/.claude-squad/worktrees/task_17a"

# ---- repo "api": local only, VS Code-style sibling worktrees -------------------
A="$H/code/api"
g init -q "$A"
commit "$A" "init" main.go
g -C "$A" worktree add -q "$H/code/api.worktrees/feat-x" -b feat-x
commit "$H/code/api.worktrees/feat-x" "feat x" x.go
g -C "$A" merge -q --no-ff -m "merge feat-x" feat-x
age "$H/code/api.worktrees/feat-x"

# ---- orphan: worktree whose parent repo was deleted ---------------------------
g init -q "$SB/doomed"
commit "$SB/doomed" "init" a.txt
g -C "$SB/doomed" worktree add -q "$H/.cursor/worktrees/doomed/zz1" -b agent/x
echo "unsaved agent output" > "$H/.cursor/worktrees/doomed/zz1/output.txt"
rm -rf "$SB/doomed"

# ---- run the scanner ------------------------------------------------------------
cd "$SB"
echo "== text report =="
"$SCAN" "$H"
echo
echo "== plan =="
"$SCAN" --plan "$H"
"$SCAN" --json "$H" > "$SB/report.json"

fail=0
expect() {   # $1 = path suffix, $2 = verdict
  local line
  line=$(grep -F "\"path\": \"$H/$1\"" "$SB/report.json" || true)
  if printf '%s' "$line" | grep -q "\"verdict\": \"$2\""; then
    printf 'ok    %-7s %s\n' "$2" "$1"
  else
    printf 'FAIL  expected %s for %s\n      got: %s\n' "$2" "$1" "${line:-<missing>}"; fail=1
  fi
}
echo
echo "== assertions =="
expect ".cursor/worktrees/webapp/abc1" SAFE
expect "code/webapp/.claude/worktrees/refactor" REVIEW
expect "conductor/workspaces/webapp/oslo" REVIEW
expect ".superset/worktrees/webapp/fix-typo" SAFE
expect ".cursor/worktrees/webapp/sq9" SAFE
expect ".codex/worktrees/1a2b/webapp" SAFE
expect ".codex/worktrees/9f8e/webapp" REVIEW
expect ".cursor/worktrees/webapp/pr7" REVIEW
expect ".claude-squad/worktrees/task_17a" REVIEW
expect "code/api.worktrees/feat-x" SAFE
expect ".cursor/worktrees/doomed/zz1" REVIEW

# The scanner must not have changed anything: every worktree dir still exists.
for d in .cursor/worktrees/webapp/abc1 code/webapp/.claude/worktrees/refactor conductor/workspaces/webapp/oslo \
         .cursor/worktrees/webapp/sq9 .codex/worktrees/1a2b/webapp .cursor/worktrees/doomed/zz1; do
  [ -d "$H/$d" ] || { echo "FAIL  $d disappeared"; fail=1; }
done
git -C "$W" worktree list --porcelain | grep -q "fix-typo" || { echo "FAIL  prunable metadata was pruned"; fail=1; }

echo
if [ $fail = 0 ]; then echo "ALL CHECKS PASSED (sandbox: $SB)"; else echo "SOME CHECKS FAILED (sandbox: $SB)"; fi
exit $fail
