#!/usr/bin/env bash
# scan_worktrees.sh - find stale git worktrees left behind by AI coding agents.
#
# READ-ONLY. This script never deletes, moves, fetches, or rewrites anything.
# It only runs read-only git plumbing (with optional locks disabled, so even
# `git status` will not refresh an index) plus find/du/stat.
# It also runs scan_xcode.sh and scan_cargo.sh, which are read-only too.
# --plan prints removal commands; it never runs them.
#
# Portable: bash 3.2+ (macOS default) and Linux, stock tools + git.
# License: MIT. https://github.com/gregkop/worktree-cleanup (see README)

set -u
export GIT_OPTIONAL_LOCKS=0 GIT_TERMINAL_PROMPT=0 LC_ALL=C

VERSION="1.1.0"
MAX_DEPTH=6
AGENT_DEPTH=6
STALE_DAYS=7
XCODE_STALE_DAYS=14
OUTPUT="text"          # text | json | plan
DO_SIZE=1
DO_AGENT_DIRS=1
DO_XCODE=1
DO_CARGO=1
ROOTS=()
EXTRA_DIRS=()
CARGO_ROOTS=""
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)

usage() {
  cat <<'EOF'
Usage: scan_worktrees.sh [options] [ROOT ...]

Find git worktrees (especially ones created by AI coding agents), measure
them, and classify each as SAFE (stale, nothing to lose) or REVIEW.
Read-only: nothing is ever deleted or modified.

ROOT            Directories to search for git repos (default: $HOME).
                Known agent worktree folders (Cursor, Codex, Conductor,
                Superset, claude-squad, Vibe Kanban) are always scanned too.

Options:
  --json             Machine-readable JSON output.
  --plan             Print (do NOT run) the git commands that would remove
                     the SAFE worktrees. Review them before running anything.
  --stale-days N     Worktrees touched within N days are REVIEW (default 7).
  --depth N          Max directory depth when searching ROOTs (default 6).
  --no-size          Skip disk-usage measurement (much faster).
  --no-agent-dirs    Do not scan the built-in agent worktree locations.
  --agent-dir PATH   Extra folder that holds worktrees (repeatable), e.g. a
                     custom Codex/Superset worktree root.
  --no-xcode         Do not report Xcode DerivedData or iOS simulators.
  --xcode-stale-days N
                     DerivedData untouched this many days is stale (default 14).
  --no-cargo         Do not report Cargo target/ directories.
  -h, --help         Show this help.
  --version          Show version.

Also reported (still read-only; cleanup commands appear only in --plan):
  Xcode / iOS   On macOS: DerivedData, unavailable simulators, DeviceSupport,
                Archives size. Skipped on Linux. Archives are never planned.
  Cargo         target/ next to a Cargo.toml in the repos and worktrees found
                above. If CARGO_TARGET_DIR is set, that directory is reported
                instead. ~/.cargo registry cache and git checkouts are sizes
                only.

Verdicts:
  SAFE    Directory already gone (prunable), or: clean working tree, every
          commit is merged into the default branch / exists on a remote, not
          locked, and idle for at least --stale-days.
  REVIEW  Anything else: uncommitted or untracked files, unpushed/unmerged
          commits, locked, recently active, orphaned, or could not inspect.
EOF
}

die() { printf 'scan_worktrees: %s\n' "$*" >&2; exit 2; }
warn() { printf 'scan_worktrees: %s\n' "$*" >&2; }
is_uint() { case ${1:-} in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

while [ $# -gt 0 ]; do
  case $1 in
    --json) OUTPUT="json" ;;
    --plan) OUTPUT="plan" ;;
    --stale-days) shift; is_uint "${1:-}" || die "--stale-days needs a number"; STALE_DAYS=$1 ;;
    --depth) shift; is_uint "${1:-}" || die "--depth needs a number"; MAX_DEPTH=$1 ;;
    --no-size) DO_SIZE=0 ;;
    --no-agent-dirs) DO_AGENT_DIRS=0 ;;
    --agent-dir) shift; [ -n "${1:-}" ] || die "--agent-dir needs a path"; EXTRA_DIRS+=("$1") ;;
    --no-xcode) DO_XCODE=0 ;;
    --xcode-stale-days) shift; is_uint "${1:-}" || die "--xcode-stale-days needs a number"; XCODE_STALE_DAYS=$1 ;;
    --no-cargo) DO_CARGO=0 ;;
    -h|--help) usage; exit 0 ;;
    --version) printf '%s\n' "$VERSION"; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do ROOTS+=("$1"); shift; done; break ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *) ROOTS+=("$1") ;;
  esac
  shift
done

command -v git >/dev/null 2>&1 || die "git not found in PATH"
[ -n "${HOME:-}" ] || die "HOME is not set"
[ ${#ROOTS[@]} -gt 0 ] || ROOTS=("$HOME")

NOW=$(date +%s)
NL='
'
US=$(printf '\037')   # unit separator for joining reasons

# ---------------------------------------------------------------- helpers ---
if stat -c %Y / >/dev/null 2>&1; then GNU_STAT=1; else GNU_STAT=0; fi
file_mtime() {
  if [ "$GNU_STAT" = 1 ]; then stat -c %Y "$1" 2>/dev/null; else stat -f %m "$1" 2>/dev/null; fi
}
fmt_date() {
  # BSD/macOS first (-r SECONDS), then GNU (-d @SECONDS).
  date -r "$1" +%Y-%m-%d 2>/dev/null || date -d "@$1" +%Y-%m-%d 2>/dev/null || printf '?'
}
canon() { (cd "$1" 2>/dev/null && pwd -P); }
human_kb() {
  awk -v k="${1:-0}" 'BEGIN {
    if (k < 1024) printf "%dK", k;
    else if (k < 1048576) printf "%.1fM", k / 1024;
    else if (k < 1073741824) printf "%.1fG", k / 1048576;
    else printf "%.2fT", k / 1073741824 }'
}
HOME_C=$(canon "$HOME"); [ -n "$HOME_C" ] || HOME_C=$HOME
pretty_path() {
  case $1 in
    "$HOME"|"$HOME_C") printf '~' ;;
    "$HOME"/*) printf '~%s' "${1#"$HOME"}" ;;
    "$HOME_C"/*) printf '~%s' "${1#"$HOME_C"}" ;;
    *) printf '%s' "$1" ;;
  esac
}
shq() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
json_str() {
  local s=$1
  s=${s//\\/\\\\}; s=${s//\"/\\\"}
  s=${s//$'\t'/\\t}; s=${s//$'\r'/\\r}; s=${s//$'\n'/\\n}
  printf '"%s"' "$s"
}
json_num_or_null() { if is_uint "${1:-}"; then printf '%s' "$1"; else printf 'null'; fi; }
json_bool() { if [ "${1:-0}" = 1 ]; then printf 'true'; else printf 'false'; fi; }
in_list() { case "$NL$2$NL" in *"$NL$1$NL"*) return 0;; esac; return 1; }
add_cargo_root() {
  [ -n "${1:-}" ] && [ -d "$1" ] || return 0
  in_list "$1" "$CARGO_ROOTS" || CARGO_ROOTS="$CARGO_ROOTS${CARGO_ROOTS:+$NL}$1"
}

CODEX_DIR=${CODEX_HOME:-$HOME/.codex}
TMP_BASE=${TMPDIR:-/tmp}; TMP_BASE=${TMP_BASE%/}

# Known agent worktree roots: "tool|path". Verified against vendor docs/source;
# see references/agent-locations.md for sources.
AGENT_DIRS="cursor|$HOME/.cursor/worktrees
codex|$CODEX_DIR/worktrees
conductor|$HOME/conductor/workspaces
superset|$HOME/.superset/worktrees
claude-squad|$HOME/.claude-squad/worktrees
vibe-kanban|$TMP_BASE/vibe-kanban/worktrees
vibe-kanban|/var/tmp/vibe-kanban/worktrees"

tool_for_path() {
  case $1 in
    "$HOME"/.cursor/worktrees/*|"$HOME_C"/.cursor/worktrees/*) echo cursor ;;
    "$CODEX_DIR"/worktrees/*) echo codex ;;
    "$HOME"/conductor/workspaces/*|"$HOME_C"/conductor/workspaces/*|*/.conductor/*) echo conductor ;;
    "$HOME"/.superset/worktrees/*|"$HOME_C"/.superset/worktrees/*) echo superset ;;
    "$HOME"/.claude-squad/worktrees/*|"$HOME_C"/.claude-squad/worktrees/*) echo claude-squad ;;
    */vibe-kanban/worktrees/*|*/.vibe-kanban-workspaces/*) echo vibe-kanban ;;
    */.claude/worktrees/*) echo claude-code ;;
    */.gemini/worktrees/*) echo gemini-cli ;;
    *.worktrees/*) echo 'vscode?' ;;
    *) echo - ;;
  esac
}

# -------------------------------------------------------------- discovery ---
COMMONS=""   # newline-separated canonical git common dirs
ORPHANS=""   # newline-separated worktree dirs whose git metadata is missing

consider_git_path() {   # $1 = path to a .git file or directory
  local g=$1 dir common gd
  dir=${g%/.git}
  common=$(cd "$dir" 2>/dev/null && c=$(git rev-parse --git-common-dir 2>/dev/null) && cd "$c" 2>/dev/null && pwd -P)
  if [ -n "$common" ]; then
    in_list "$common" "$COMMONS" || COMMONS="$COMMONS${COMMONS:+$NL}$common"
    return
  fi
  [ -f "$g" ] || return
  gd=$(sed -n 's/^gitdir: //p' "$g" 2>/dev/null | head -n 1)
  [ -n "$gd" ] || return
  case $gd in /*) ;; *) gd="$dir/$gd" ;; esac
  if [ ! -d "$gd" ]; then
    in_list "$dir" "$ORPHANS" || ORPHANS="$ORPHANS${ORPHANS:+$NL}$dir"
  else
    warn "could not inspect $dir (git refused; ownership/safe.directory?)"
  fi
}

find_git_paths() {   # $1 = root, $2 = depth
  find "$1" -maxdepth "$2" \
    \( -name .git -print -prune \) -o \
    \( -type d ! -path "$1" \( -name node_modules -o -name .Trash -o -name .Trashes \
       -o -name Library -o -name .venv -o -name venv -o -name __pycache__ -o -name target \
       -o -name .gradle -o -name .m2 -o -name .cargo -o -name .rustup -o -name .pnpm-store \
       -o -name DerivedData -o -name Pods -o -name .next -o -name .turbo \
       -o \( -name '.*' ! -name .claude ! -name .gemini ! -name .conductor ! -name .worktrees \
             ! -name .trees \) \) -prune \) 2>/dev/null
}

scan_root() {   # $1 = root, $2 = depth
  local p
  [ -d "$1" ] || return
  while IFS= read -r p; do
    [ -n "$p" ] && consider_git_path "$p"
  done <<EOF
$(find_git_paths "$1" "$2")
EOF
}

for r in "${ROOTS[@]}"; do
  [ -d "$r" ] || { warn "skipping $r (not a directory)"; continue; }
  scan_root "$r" "$MAX_DEPTH"
done
SCANNED_AGENT_DIRS=""
if [ "$DO_AGENT_DIRS" = 1 ]; then
  while IFS='|' read -r _tool d; do
    [ -d "$d" ] || continue
    SCANNED_AGENT_DIRS="$SCANNED_AGENT_DIRS${SCANNED_AGENT_DIRS:+$NL}$_tool|$d"
    scan_root "$d" "$AGENT_DEPTH"
  done <<EOF
$AGENT_DIRS
EOF
fi
for d in ${EXTRA_DIRS[@]+"${EXTRA_DIRS[@]}"}; do
  [ -d "$d" ] || { warn "skipping --agent-dir $d (not a directory)"; continue; }
  SCANNED_AGENT_DIRS="$SCANNED_AGENT_DIRS${SCANNED_AGENT_DIRS:+$NL}custom|$d"
  scan_root "$d" "$AGENT_DEPTH"
done

# ------------------------------------------------------------- inspection ---
N=0
W_PATH=(); W_REPO=(); W_BRANCH=(); W_HEAD=(); W_TOOL=(); W_STATE=()
W_SIZE=(); W_REGEN=(); W_LAST=(); W_IDLE=(); W_DIRTY=(); W_UNPUSHED=()
W_MERGED=(); W_UPSTREAM=(); W_LOCKED=(); W_LOCKREASON=(); W_VERDICT=(); W_REASONS=(); W_COMMON=()
REPO_COUNT=0

is_nested() {   # $1 = path, $2 = newline list of dirs; true if $1 is inside one
  local k
  while IFS= read -r k; do
    [ -n "$k" ] || continue
    case $1 in "$k"/*) return 0 ;; esac
  done <<EOF
$2
EOF
  return 1
}

measure() {   # $1 = dir -> sets M_SIZE, M_REGEN (KB)
  local kb p base kept="" total=""
  M_SIZE=""; M_REGEN=""
  [ "$DO_SIZE" = 1 ] || return
  M_REGEN=0
  while IFS="$(printf '\t')" read -r kb p; do
    [ -n "$p" ] || continue
    if [ "$p" = "$1" ]; then total=$kb; continue; fi
    base=${p##*/}
    case $base in
      node_modules|.venv|venv|target|.next|.nuxt|.turbo|.gradle|__pycache__|.pytest_cache|.parcel-cache|.svelte-kit|DerivedData|Pods|.cache|dist|build|coverage) ;;
      *) continue ;;
    esac
    is_nested "$p" "$kept" && continue
    kept="$kept${kept:+$NL}$p"
    M_REGEN=$((M_REGEN + kb))
  done <<EOF
$(du -k -d 3 "$1" 2>/dev/null | sort -t "$(printf '\t')" -k2,2)
EOF
  M_SIZE=${total:-0}
}

add_row() {   # positional: path repo branch head tool state size regen last dirty unpushed merged upstream locked lockreason verdict reasons common
  W_PATH[N]=$1; W_REPO[N]=$2; W_BRANCH[N]=$3; W_HEAD[N]=$4; W_TOOL[N]=$5; W_STATE[N]=$6
  W_SIZE[N]=$7; W_REGEN[N]=$8; W_LAST[N]=$9; W_DIRTY[N]=${10}; W_UNPUSHED[N]=${11}
  W_MERGED[N]=${12}; W_UPSTREAM[N]=${13}; W_LOCKED[N]=${14}; W_LOCKREASON[N]=${15}
  W_VERDICT[N]=${16}; W_REASONS[N]=${17}; W_COMMON[N]=${18}
  if is_uint "$9" && [ "$9" -gt 0 ]; then W_IDLE[N]=$(( (NOW - $9) / 86400 )); else W_IDLE[N]=""; fi
  N=$((N + 1))
}

PWD_C=$(pwd -P)
# Appends a REVIEW reason; uses the caller's (inspect_repo) locals via dynamic scope.
add_reason() { reasons="$reasons${reasons:+$US}$1"; verdict=REVIEW; }

inspect_repo() {   # $1 = canonical git common dir
  local common=$1 porcelain main="" targets="" t oh lb b has_remotes pid_cache="" pid_cache_done=0 cr
  local -a R_WT R_HEAD R_BRANCH R_LOCKED R_LOCKR R_PRUNE
  local i=-1 line
  porcelain=$(git --git-dir="$common" worktree list --porcelain 2>/dev/null) || return
  while IFS= read -r line; do
    case $line in
      "worktree "*) i=$((i + 1)); R_WT[i]=${line#worktree }; R_HEAD[i]=""; R_BRANCH[i]=""; R_LOCKED[i]=0; R_LOCKR[i]=""; R_PRUNE[i]=0 ;;
      "HEAD "*) R_HEAD[i]=${line#HEAD } ;;
      "branch "*) R_BRANCH[i]=${line#branch refs/heads/} ;;
      bare) R_WT[i]="" ;;
      locked) R_LOCKED[i]=1 ;;
      "locked "*) R_LOCKED[i]=1; R_LOCKR[i]=${line#locked } ;;
      prunable|"prunable "*) R_PRUNE[i]=1 ;;
    esac
  done <<EOF
$porcelain
EOF
  if [ "$i" -ge 0 ]; then
    for ((cr = 0; cr <= i; cr++)); do
      [ -n "${R_WT[cr]}" ] && [ -d "${R_WT[cr]}" ] && add_cargo_root "${R_WT[cr]}"
    done
  fi
  [ "$i" -ge 1 ] || return   # no linked worktrees
  REPO_COUNT=$((REPO_COUNT + 1))
  main=${R_WT[0]}; [ -n "$main" ] || main=$common

  # Default-branch targets (remote first, then local).
  oh=$(git --git-dir="$common" symbolic-ref -q refs/remotes/origin/HEAD 2>/dev/null)
  if [ -n "$oh" ]; then
    targets=$oh; lb=${oh#refs/remotes/origin/}
    git --git-dir="$common" show-ref -q --verify "refs/heads/$lb" 2>/dev/null && targets="$targets refs/heads/$lb"
  else
    for b in main master trunk develop; do
      for t in "refs/remotes/origin/$b" "refs/heads/$b"; do
        git --git-dir="$common" show-ref -q --verify "$t" 2>/dev/null && targets="$targets${targets:+ }$t"
      done
      [ -n "$targets" ] && break
    done
  fi
  has_remotes=0
  [ -n "$(git --git-dir="$common" for-each-ref --count=1 --format=x refs/remotes 2>/dev/null)" ] && has_remotes=1

  local k wt head branch locked lockr tool state size regen last dirty unpushed merged upstream verdict reasons gitdir f tm st up first_t mb pid wt_c
  for ((k = 1; k <= i; k++)); do
    wt=${R_WT[k]}; [ -n "$wt" ] || continue
    head=${R_HEAD[k]}; branch=${R_BRANCH[k]}; locked=${R_LOCKED[k]}; lockr=${R_LOCKR[k]}
    tool=$(tool_for_path "$wt")
    size=""; regen=""; last=""; dirty=""; unpushed=""; merged=""; upstream=""; reasons=""

    if [ "${R_PRUNE[k]}" = 1 ] || [ ! -d "$wt" ]; then
      if [ "$locked" = 1 ]; then
        add_row "$wt" "$main" "$branch" "$head" "$tool" missing "" "" "" "" "" "" "" 1 "$lockr" REVIEW \
          "directory is missing but the worktree is locked${lockr:+ ($lockr)} (removable media?)" "$common"
      else
        add_row "$wt" "$main" "$branch" "$head" "$tool" missing 0 0 "" "" "" "" "" 0 "" SAFE \
          "directory already deleted; only stale metadata left (git worktree prune)" "$common"
      fi
      continue
    fi
    state=ok

    # Last activity: newest of worktree root dir and its private git dir files.
    gitdir=$(git -C "$wt" rev-parse --absolute-git-dir 2>/dev/null)
    last=0
    for f in "$wt" "$gitdir/index" "$gitdir/HEAD" "$gitdir/logs/HEAD"; do
      [ -e "$f" ] || continue
      tm=$(file_mtime "$f"); is_uint "$tm" && [ "$tm" -gt "$last" ] && last=$tm
    done

    if ! st=$(git -C "$wt" status --porcelain --untracked-files=normal 2>/dev/null); then
      measure "$wt"
      add_row "$wt" "$main" "$branch" "$head" "$tool" error "$M_SIZE" "$M_REGEN" "$last" "" "" "" "" "$locked" "$lockr" REVIEW \
        "git status failed; inspect manually" "$common"
      continue
    fi
    dirty=$(printf '%s' "$st" | grep -c . || true)

    # Unpushed: commits on HEAD not on any remote-tracking ref nor the local default branch.
    if [ -n "$head" ]; then
      if [ "$has_remotes" = 1 ]; then
        # shellcheck disable=SC2086
        unpushed=$(git --git-dir="$common" rev-list --count "$head" --not --remotes $targets 2>/dev/null)
      elif [ -n "$targets" ]; then
        # shellcheck disable=SC2086
        unpushed=$(git --git-dir="$common" rev-list --count "$head" --not $targets 2>/dev/null)
      fi
    fi

    # Upstream tracking state.
    if [ -n "$branch" ]; then
      up=$(git --git-dir="$common" for-each-ref --format='%(upstream)|%(upstream:track)' "refs/heads/$branch" 2>/dev/null)
      case $up in
        "|"*|"") upstream=none ;;
        *"[gone]"*) upstream=gone ;;
        *) upstream=ok ;;
      esac
    fi

    # Merged into the default branch? ancestor -> rebased (patch-equivalent) -> squash.
    if [ -n "$head" ] && [ -n "$targets" ]; then
      for t in $targets; do
        if git --git-dir="$common" merge-base --is-ancestor "$head" "$t" 2>/dev/null; then merged=merged; break; fi
      done
      first_t=${targets%% *}
      if [ -z "$merged" ] && is_uint "$unpushed" && [ "$unpushed" -gt 0 ] && [ "$unpushed" -le 500 ]; then
        if c=$(git --git-dir="$common" cherry "$first_t" "$head" 2>/dev/null) && [ -n "$c" ] \
           && ! printf '%s\n' "$c" | grep -q '^+'; then
          merged=rebased
        fi
      fi
      if [ -z "$merged" ] && is_uint "$unpushed" && [ "$unpushed" -gt 0 ] && [ "$unpushed" -le 500 ]; then
        if [ "$pid_cache_done" = 0 ]; then
          pid_cache=$(git --git-dir="$common" log --no-merges --no-color --no-ext-diff --no-textconv -p -n 2000 "$first_t" 2>/dev/null \
            | git patch-id --stable 2>/dev/null | cut -d' ' -f1)
          pid_cache_done=1
        fi
        mb=$(git --git-dir="$common" merge-base "$first_t" "$head" 2>/dev/null)
        if [ -n "$mb" ] && [ -n "$pid_cache" ]; then
          pid=$(git --git-dir="$common" diff --no-color --no-ext-diff --no-textconv "$mb" "$head" 2>/dev/null \
            | git patch-id --stable 2>/dev/null | cut -d' ' -f1)
          [ -n "$pid" ] && in_list "$pid" "$pid_cache" && merged=squash-merged
        fi
      fi
    fi

    measure "$wt"; size=$M_SIZE; regen=$M_REGEN

    # ---- verdict ----
    verdict=SAFE
    wt_c=$(canon "$wt")
    case "$PWD_C/" in "$wt_c"/*) add_reason "this is the current working directory" ;; esac
    [ "$locked" = 1 ] && add_reason "locked${lockr:+: $lockr} (an agent may still own it)"
    [ "$dirty" -gt 0 ] 2>/dev/null && add_reason "$dirty uncommitted/untracked path(s)"
    if [ -f "$wt/.gitmodules" ] && git -C "$wt" submodule status 2>/dev/null | grep -q '^[^-]'; then
      add_reason "has initialized submodules (check them; plain remove will refuse)"
    fi
    if [ -z "$merged" ]; then
      if ! is_uint "$unpushed"; then
        add_reason "cannot tell if commits are safe (no remote/default branch to compare)"
      elif [ "$unpushed" -gt 0 ]; then
        if [ "$upstream" = gone ]; then
          add_reason "$unpushed commit(s) not on any remote; upstream branch deleted (merged via PR? verify)"
        else
          add_reason "$unpushed commit(s) not merged and not on any remote"
        fi
      elif [ -n "$branch" ] && [ "$upstream" != gone ]; then
        add_reason "branch pushed but not merged (open PR?)"
      fi
    fi
    if [ "$STALE_DAYS" -gt 0 ] && [ "$last" -gt 0 ] && [ $(( (NOW - last) / 86400 )) -lt "$STALE_DAYS" ]; then
      add_reason "recently active ($(( (NOW - last) / 86400 ))d ago)"
    fi
    if [ "$verdict" = SAFE ]; then
      case $merged in
        merged) reasons="clean; merged into default branch" ;;
        rebased) reasons="clean; commits already in default branch (rebased)" ;;
        squash-merged) reasons="clean; changes squash-merged into default branch" ;;
        *) if [ "$upstream" = gone ]; then reasons="clean; all commits on remote; upstream branch deleted"
           else reasons="clean; detached HEAD already on remote"; fi ;;
      esac
      reasons="$reasons; idle $(( (NOW - last) / 86400 ))d"
    fi
    add_row "$wt" "$main" "$branch" "$head" "$tool" "$state" "$size" "$regen" "$last" "$dirty" "$unpushed" \
      "$merged" "$upstream" "$locked" "$lockr" "$verdict" "$reasons" "$common"
  done
}

while IFS= read -r c; do
  [ -n "$c" ] && inspect_repo "$c"
done <<EOF
$COMMONS
EOF

while IFS= read -r o; do
  [ -n "$o" ] || continue
  gd=$(sed -n 's/^gitdir: //p' "$o/.git" 2>/dev/null | head -n 1)
  repo=${gd%/.git/worktrees/*}; [ "$repo" = "$gd" ] && repo="?"
  add_cargo_root "$o"
  measure "$o"
  last=$(file_mtime "$o")
  add_row "$o" "$repo" "" "" "$(tool_for_path "$o")" orphan "$M_SIZE" "$M_REGEN" "$last" "" "" "" "" 0 "" REVIEW \
    "orphaned: its git metadata is gone (repo deleted/moved or worktree pruned); files here may be the only copy" ""
done <<EOF
$ORPHANS
EOF

# ---------------------------------------------------------------- output ---
order_rows() {   # SAFE first, then by size desc
  local j rank
  for ((j = 0; j < N; j++)); do
    if [ "${W_VERDICT[j]}" = SAFE ]; then rank=0; else rank=1; fi
    printf '%s\t%s\t%s\n' "$rank" "${W_SIZE[j]:-0}" "$j"
  done | sort -t "$(printf '\t')" -k1,1n -k2,2nr | cut -f3
}
ORDER=$(order_rows)

status_flags() {   # $1 = index
  local j=$1 s=""
  case ${W_STATE[j]} in
    missing) printf 'missing (prunable)'; return ;;
    orphan) printf 'orphaned'; return ;;
    error) printf 'error'; return ;;
  esac
  if [ "${W_DIRTY[j]:-0}" -gt 0 ] 2>/dev/null; then s="dirty:${W_DIRTY[j]}"; else s="clean"; fi
  if [ -n "${W_MERGED[j]}" ]; then s="$s, ${W_MERGED[j]}"
  elif is_uint "${W_UNPUSHED[j]}" && [ "${W_UNPUSHED[j]}" -gt 0 ]; then s="$s, unpushed:${W_UNPUSHED[j]}"
  elif is_uint "${W_UNPUSHED[j]}"; then s="$s, pushed"; fi
  [ "${W_UPSTREAM[j]}" = gone ] && s="$s, gone"
  [ "${W_LOCKED[j]}" = 1 ] && s="$s, locked"
  printf '%s' "$s"
}

trunc() { local s=$1 w=$2; if [ ${#s} -gt "$w" ]; then printf '%s~' "${s:0:$((w - 1))}"; else printf '%s' "$s"; fi; }

sum_kb() {   # $1 = verdict filter (SAFE/REVIEW/ALL), $2 = field (size|regen)
  local j t=0 v
  for ((j = 0; j < N; j++)); do
    [ "$1" = ALL ] || [ "${W_VERDICT[j]}" = "$1" ] || continue
    if [ "$2" = regen ]; then v=${W_REGEN[j]:-0}; else v=${W_SIZE[j]:-0}; fi
    is_uint "$v" && t=$((t + v))
  done
  printf '%s' "$t"
}
count_v() { local j c=0; for ((j = 0; j < N; j++)); do [ "${W_VERDICT[j]}" = "$1" ] && c=$((c + 1)); done; printf '%s' "$c"; }

print_text() {
  local j br rp wtool st size idle w_tool=4 w_repo=4 w_br=6 w_st=6
  printf 'worktree-cleanup scan (read-only) - roots: '
  for r in "${ROOTS[@]}"; do printf '%s ' "$(pretty_path "$r")"; done
  printf '| stale after %sd\n\n' "$STALE_DAYS"
  if [ "$N" -eq 0 ]; then
    printf 'No linked git worktrees found. Nothing to clean up here.\n'
    printf '(Searched %s level(s) deep; use --depth or pass more ROOTs to widen the search.)\n' "$MAX_DEPTH"
    return
  fi
  for j in $ORDER; do
    wtool=${W_TOOL[j]}; [ ${#wtool} -gt "$w_tool" ] && w_tool=${#wtool}
    rp=$(basename "${W_REPO[j]}"); [ ${#rp} -gt "$w_repo" ] && w_repo=${#rp}
    br=${W_BRANCH[j]:-"(${W_HEAD[j]:0:7})"}; [ ${#br} -gt "$w_br" ] && w_br=${#br}
    st=$(status_flags "$j"); [ ${#st} -gt "$w_st" ] && w_st=${#st}
  done
  [ "$w_repo" -gt 20 ] && w_repo=20; [ "$w_br" -gt 28 ] && w_br=28; [ "$w_st" -gt 34 ] && w_st=34
  printf "%-7s %7s %5s  %-${w_tool}s  %-${w_repo}s  %-${w_br}s  %-${w_st}s  %s\n" VERDICT SIZE IDLE TOOL REPO BRANCH STATUS PATH
  for j in $ORDER; do
    if [ -n "${W_SIZE[j]}" ]; then size=$(human_kb "${W_SIZE[j]}"); else size="-"; fi
    [ "${W_STATE[j]}" = missing ] && size="0"
    if [ -n "${W_IDLE[j]}" ]; then idle="${W_IDLE[j]}d"; else idle="-"; fi
    rp=$(basename "${W_REPO[j]}")
    br=${W_BRANCH[j]:-"(${W_HEAD[j]:0:7})"}; [ -z "${W_BRANCH[j]}${W_HEAD[j]}" ] && br="-"
    printf "%-7s %7s %5s  %-${w_tool}s  %-${w_repo}s  %-${w_br}s  %-${w_st}s  %s\n" \
      "${W_VERDICT[j]}" "$size" "$idle" "${W_TOOL[j]}" "$(trunc "$rp" "$w_repo")" "$(trunc "$br" "$w_br")" \
      "$(trunc "$(status_flags "$j")" "$w_st")" "$(pretty_path "${W_PATH[j]}")"
  done

  printf '\nWhy:\n'
  for j in $ORDER; do
    printf '  %-6s %s\n         %s\n' "${W_VERDICT[j]}" "$(pretty_path "${W_PATH[j]}")" \
      "$(printf '%s' "${W_REASONS[j]}" | sed "s/$US/; /g")"
  done

  printf '\nSummary: %s worktree(s) across %s repo(s)' "$N" "$REPO_COUNT"
  [ -n "$ORPHANS" ] && printf ' (incl. %s orphaned dir(s))' "$(printf '%s\n' "$ORPHANS" | grep -c .)"
  printf '\n'
  if [ "$DO_SIZE" = 1 ]; then
    printf '  SAFE    %3s  %8s reclaimable by removing stale worktrees\n' "$(count_v SAFE)" "$(human_kb "$(sum_kb SAFE size)")"
    printf '  REVIEW  %3s  %8s needs a human decision (uncommitted/unpushed/locked/recent)\n' "$(count_v REVIEW)" "$(human_kb "$(sum_kb REVIEW size)")"
    printf '  Regenerable dirs (node_modules, .venv, target, build, ...) inside all worktrees: %s\n' "$(human_kb "$(sum_kb ALL regen)")"
  else
    printf '  SAFE %s, REVIEW %s (sizes skipped: --no-size)\n' "$(count_v SAFE)" "$(count_v REVIEW)"
  fi
  if [ -n "$SCANNED_AGENT_DIRS" ]; then
    printf '\nAgent worktree locations found:\n'
    while IFS='|' read -r tl d; do
      [ -n "$d" ] || continue
      local cnt=0 kb=0
      for ((j = 0; j < N; j++)); do
        case ${W_PATH[j]} in "$d"/*) cnt=$((cnt + 1)); is_uint "${W_SIZE[j]}" && kb=$((kb + W_SIZE[j])) ;; esac
      done
      if [ "$DO_SIZE" = 1 ]; then
        printf '  %-13s %-45s %3s worktree(s)  %s\n' "$tl" "$(pretty_path "$d")" "$cnt" "$(human_kb "$kb")"
      else
        printf '  %-13s %-45s %3s worktree(s)\n' "$tl" "$(pretty_path "$d")" "$cnt"
      fi
    done <<EOF
$SCANNED_AGENT_DIRS
EOF
  fi
  printf '\nNothing was modified. Use --plan to print removal commands for SAFE worktrees, SAFE DerivedData, and Cargo targets. Use --json for machine output.\n'
}

section_off_json() { printf '{"skipped":true,"reason":%s}\n' "$(json_str "$1")"; }

run_xcode() { # $1 = text|json|plan
  local mode=$1
  local args
  if [ "$DO_XCODE" != 1 ]; then
    [ "$mode" = json ] && section_off_json "disabled (--no-xcode)"
    return 0
  fi
  if [ ! -f "$SCRIPT_DIR/scan_xcode.sh" ]; then
    warn "scan_xcode.sh not found; skipping Xcode caches"
    [ "$mode" = json ] && section_off_json "scanner missing"
    return 0
  fi
  args=(--stale-days "$XCODE_STALE_DAYS")
  [ "$DO_SIZE" = 0 ] && args+=(--no-size)
  case $mode in
    json) args+=(--json) ;;
    plan) args+=(--plan) ;;
  esac
  bash "$SCRIPT_DIR/scan_xcode.sh" "${args[@]}"
}

run_cargo() { # $1 = text|json|plan
  local mode=$1
  local args
  if [ "$DO_CARGO" != 1 ]; then
    [ "$mode" = json ] && section_off_json "disabled (--no-cargo)"
    return 0
  fi
  if [ ! -f "$SCRIPT_DIR/scan_cargo.sh" ]; then
    warn "scan_cargo.sh not found; skipping Cargo targets"
    [ "$mode" = json ] && section_off_json "scanner missing"
    return 0
  fi
  args=(--stdin --depth "$MAX_DEPTH")
  [ "$DO_SIZE" = 0 ] && args+=(--no-size)
  case $mode in
    json) args+=(--json) ;;
    plan) args+=(--plan) ;;
  esac
  printf '%s\n' "$CARGO_ROOTS" | bash "$SCRIPT_DIR/scan_cargo.sh" "${args[@]}"
}

print_plan() {
  local j repos="" r c=0
  printf '# worktree-cleanup removal plan for SAFE worktrees (generated %s).\n' "$(fmt_date "$NOW")"
  printf '# NOTHING HAS BEEN RUN. Review every line, get explicit approval, then run.\n'
  printf '# "git worktree remove" (no --force) refuses to delete a worktree with changes.\n'
  printf '# Ignored files inside a worktree (.env copies, node_modules, build output) ARE deleted.\n\n'
  for j in $ORDER; do
    [ "${W_VERDICT[j]}" = SAFE ] || continue
    [ "${W_STATE[j]}" = missing ] && { in_list "${W_COMMON[j]}" "$repos" || repos="$repos${repos:+$NL}${W_COMMON[j]}"; continue; }
    printf '# %s  (%s; %s)\n' "$(human_kb "${W_SIZE[j]:-0}")" "${W_BRANCH[j]:-detached ${W_HEAD[j]:0:7}}" "$(printf '%s' "${W_REASONS[j]}" | sed "s/$US/; /g")"
    printf 'git -C %s worktree remove %s\n' "$(shq "${W_REPO[j]}")" "$(shq "${W_PATH[j]}")"
    in_list "${W_COMMON[j]}" "$repos" || repos="$repos${repos:+$NL}${W_COMMON[j]}"
    c=$((c + 1))
  done
  if [ -n "$repos" ]; then
    printf '\n# Then drop leftover metadata for deleted/removed worktrees:\n'
    while IFS= read -r r; do
      [ -n "$r" ] && printf 'git --git-dir=%s worktree prune\n' "$(shq "$r")"
    done <<EOF
$repos
EOF
  fi
  [ "$c" -eq 0 ] && [ -z "$repos" ] && printf '# No SAFE worktrees found. Nothing to do.\n'
  printf '\n# REVIEW rows are intentionally excluded. Branches are NOT deleted by these commands.\n'
}

print_json() {
  local j first=1 parts p xjson cjson
  printf '{\n  "tool": "worktree-cleanup/scan_worktrees.sh",\n  "version": %s,\n  "generated_at": %s,\n' "$(json_str "$VERSION")" "$NOW"
  printf '  "stale_days": %s,\n  "roots": [' "$STALE_DAYS"
  for r in "${ROOTS[@]}"; do [ $first = 1 ] || printf ', '; first=0; json_str "$r"; done
  printf '],\n  "summary": {"worktrees": %s, "repos": %s, "safe": %s, "review": %s' "$N" "$REPO_COUNT" "$(count_v SAFE)" "$(count_v REVIEW)"
  if [ "$DO_SIZE" = 1 ]; then
    printf ', "safe_kb": %s, "review_kb": %s, "regenerable_kb": %s' "$(sum_kb SAFE size)" "$(sum_kb REVIEW size)" "$(sum_kb ALL regen)"
  fi
  printf '},\n  "worktrees": [\n'
  first=1
  for j in $ORDER; do
    [ $first = 1 ] || printf ',\n'; first=0
    printf '    {"verdict": %s, "path": %s, "repo": %s, "tool": %s, "state": %s' \
      "$(json_str "${W_VERDICT[j]}")" "$(json_str "${W_PATH[j]}")" "$(json_str "${W_REPO[j]}")" \
      "$(json_str "${W_TOOL[j]}")" "$(json_str "${W_STATE[j]}")"
    if [ -n "${W_BRANCH[j]}" ]; then printf ', "branch": %s' "$(json_str "${W_BRANCH[j]}")"; else printf ', "branch": null'; fi
    if [ -n "${W_HEAD[j]}" ]; then printf ', "head": %s' "$(json_str "${W_HEAD[j]}")"; else printf ', "head": null'; fi
    printf ', "size_kb": %s, "regenerable_kb": %s' "$(json_num_or_null "${W_SIZE[j]}")" "$(json_num_or_null "${W_REGEN[j]}")"
    if is_uint "${W_LAST[j]}" && [ "${W_LAST[j]}" -gt 0 ]; then
      printf ', "last_activity": %s, "idle_days": %s' "$(json_str "$(fmt_date "${W_LAST[j]}")")" "${W_IDLE[j]}"
    else
      printf ', "last_activity": null, "idle_days": null'
    fi
    printf ', "dirty_paths": %s, "unpushed_commits": %s' "$(json_num_or_null "${W_DIRTY[j]}")" "$(json_num_or_null "${W_UNPUSHED[j]}")"
    if [ -n "${W_MERGED[j]}" ]; then printf ', "merged": %s' "$(json_str "${W_MERGED[j]}")"; else printf ', "merged": null'; fi
    if [ -n "${W_UPSTREAM[j]}" ]; then printf ', "upstream": %s' "$(json_str "${W_UPSTREAM[j]}")"; else printf ', "upstream": null'; fi
    printf ', "prunable": %s, "locked": %s' "$( [ "${W_STATE[j]}" = missing ] && echo true || echo false)" "$(json_bool "${W_LOCKED[j]}")"
    if [ -n "${W_LOCKREASON[j]}" ]; then printf ', "lock_reason": %s' "$(json_str "${W_LOCKREASON[j]}")"; fi
    printf ', "reasons": ['
    parts=${W_REASONS[j]}; p=1
    while :; do
      [ $p = 1 ] || printf ', '; p=0
      case $parts in
        *"$US"*) json_str "${parts%%"$US"*}"; parts=${parts#*"$US"} ;;
        *) json_str "$parts"; break ;;
      esac
    done
    printf ']}'
  done
  printf '\n  ],\n'
  xjson=$(run_xcode json)
  cjson=$(run_cargo json)
  [ -n "$xjson" ] || xjson='{"skipped":true,"reason":"scanner failed"}'
  [ -n "$cjson" ] || cjson='{"skipped":true,"reason":"scanner failed"}'
  printf '  "xcode": %s,\n  "cargo": %s\n}\n' "$xjson" "$cjson"
}

case $OUTPUT in
  json) print_json ;;
  plan)
    print_plan
    printf '\n'
    run_xcode plan
    printf '\n'
    run_cargo plan
    ;;
  *)
    print_text
    printf '\n'
    run_xcode text
    printf '\n'
    run_cargo text
    ;;
esac
