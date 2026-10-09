#!/usr/bin/env bash
# scan_cargo.sh - report Cargo target/ directories. READ-ONLY.
#
# Finds target/ next to a Cargo.toml under the given roots (repos and
# worktrees). When CARGO_TARGET_DIR is set and exists, that shared directory
# is reported instead, so project target/ folders are not counted twice.
# ~/.cargo registry cache and git checkouts are measured and never planned.
# --plan prints `cargo clean` when cargo is on PATH, otherwise rm of a
# target that sits next to a Cargo.toml (or of CARGO_TARGET_DIR itself).
# Bash 3.2+. License: MIT.

set -u
export LC_ALL=C

VERSION="1.1.0"
OUTPUT="text"
DO_SIZE=1
READ_STDIN=0
MAX_DEPTH=6
ROOTS=()

usage() {
  cat <<'EOF'
Usage: scan_cargo.sh [options] [ROOT ...]
       scan_cargo.sh [options] --stdin     # one root per line on stdin

Report Cargo target/ directories under each ROOT. Read-only.

A target directory counts only when a Cargo.toml sits in its parent, unless
CARGO_TARGET_DIR is set to an existing directory. In that case the shared
directory is reported instead of per-project target/ folders.

Options:
  --json             Machine-readable JSON.
  --plan             Print (do NOT run) cleanup commands.
  --no-size          Skip disk-usage measurement.
  --stdin            Read roots from stdin.
  --depth N          How deep to look for Cargo.toml under each root (default 6).
  -h, --help         Show this help.
  --version          Show version.

CARGO_BUILD_RUNNING=1 forces the "cargo/rustc is running" warning (tests).
CARGO_HOME overrides the default ~/.cargo location for the report-only caches.
EOF
}

die() { printf 'scan_cargo: %s\n' "$*" >&2; exit 2; }
warn() { printf 'scan_cargo: %s\n' "$*" >&2; }
is_uint() { case ${1:-} in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

while [ $# -gt 0 ]; do
  case $1 in
    --json) OUTPUT="json" ;;
    --plan) OUTPUT="plan" ;;
    --no-size) DO_SIZE=0 ;;
    --stdin) READ_STDIN=1 ;;
    --depth) shift; is_uint "${1:-}" || die "--depth needs a number"; MAX_DEPTH=$1 ;;
    -h|--help) usage; exit 0 ;;
    --version) printf '%s\n' "$VERSION"; exit 0 ;;
    --) shift; while [ $# -gt 0 ]; do ROOTS+=("$1"); shift; done; break ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *) ROOTS+=("$1") ;;
  esac
  shift
done

if [ "$READ_STDIN" = 1 ]; then
  while IFS= read -r line; do
    [ -n "$line" ] && ROOTS+=("$line")
  done
fi

[ -n "${HOME:-}" ] || die "HOME is not set"

NOW=$(date +%s)
NL='
'

if stat -c %Y / >/dev/null 2>&1; then GNU_STAT=1; else GNU_STAT=0; fi
file_mtime() {
  if [ "$GNU_STAT" = 1 ]; then stat -c %Y "$1" 2>/dev/null; else stat -f %m "$1" 2>/dev/null; fi
}
fmt_date() {
  date -r "$1" +%Y-%m-%d 2>/dev/null || date -d "@$1" +%Y-%m-%d 2>/dev/null || printf '?'
}
canon() { (cd "$1" 2>/dev/null && pwd -P); }
human_kb() {
  awk -v k="${1:-0}" 'BEGIN {
    if (k+0 < 1024) printf "%dK", k+0;
    else if (k+0 < 1048576) printf "%.1fM", k / 1024;
    else if (k+0 < 1073741824) printf "%.1fG", k / 1048576;
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

du_kb() {
  [ "$DO_SIZE" = 1 ] && [ -e "$1" ] || return 0
  du -sk "$1" 2>/dev/null | awk '{print $1; exit}'
}

newest_mtime() {
  local dir=$1 f tm best=0
  for f in "$dir" "$dir/debug" "$dir/release" "$dir/CACHEDIR.TAG" "$dir/.rustc_info.json"; do
    [ -e "$f" ] || continue
    tm=$(file_mtime "$f") || true
    is_uint "$tm" && [ "$tm" -gt "$best" ] && best=$tm
  done
  if [ -d "$dir" ]; then
    for f in "$dir"/*; do
      [ -e "$f" ] || continue
      tm=$(file_mtime "$f") || true
      is_uint "$tm" && [ "$tm" -gt "$best" ] && best=$tm
    done
  fi
  printf '%s' "$best"
}

cargo_busy=0
case ${CARGO_BUILD_RUNNING:-} in
  1) cargo_busy=1 ;;
  0) cargo_busy=0 ;;
  *)
    if command -v pgrep >/dev/null 2>&1; then
      pgrep -x cargo >/dev/null 2>&1 && cargo_busy=1
      pgrep -x rustc >/dev/null 2>&1 && cargo_busy=1
    fi
    ;;
esac

have_cargo=0
command -v cargo >/dev/null 2>&1 && have_cargo=1

SHARED=""
SHARED_NOTE=""
if [ -n "${CARGO_TARGET_DIR:-}" ]; then
  if [ -d "$CARGO_TARGET_DIR" ]; then
    SHARED=$(canon "$CARGO_TARGET_DIR")
    [ -n "$SHARED" ] || SHARED=$CARGO_TARGET_DIR
  else
    SHARED_NOTE="CARGO_TARGET_DIR is set but does not exist ($CARGO_TARGET_DIR); scanning per-project target/ directories"
  fi
fi

T_PATH=(); T_MANIFEST=(); T_SIZE=(); T_MTIME=(); T_IDLE=(); T_SHARED=(); T_VERDICT=(); T_REASON=(); T_LINK=()
N_T=0
SEEN=""
MANIFESTS=""

add_manifest() {
  [ -f "$1" ] || return 0
  in_list "$1" "$MANIFESTS" || MANIFESTS="$MANIFESTS${MANIFESTS:+$NL}$1"
}

add_target() { # $1 target dir, $2 manifest or empty, $3 shared 0/1
  local t=$1 manifest=$2 shared=$3 c mtime idle size verdict reason link=0
  [ -d "$t" ] || return 0
  [ -L "$t" ] && link=1
  c=$(canon "$t")
  [ -n "$c" ] || c=$t
  in_list "$c" "$SEEN" && return 0
  SEEN="$SEEN${SEEN:+$NL}$c"
  mtime=$(newest_mtime "$t")
  idle=""
  is_uint "$mtime" && [ "$mtime" -gt 0 ] && idle=$(( (NOW - mtime) / 86400 ))
  size=$(du_kb "$t")
  if [ "$cargo_busy" = 1 ]; then
    verdict=REVIEW
    reason="cargo or rustc is running; leave this target until the build finishes"
  else
    verdict=SAFE
    if [ "$shared" = 1 ]; then
      reason="CARGO_TARGET_DIR; regenerable shared build output"
    else
      reason="regenerable cargo build output next to Cargo.toml"
    fi
  fi
  T_PATH[N_T]=$c
  T_MANIFEST[N_T]=$manifest
  T_SIZE[N_T]=$size
  T_MTIME[N_T]=$mtime
  T_IDLE[N_T]=$idle
  T_SHARED[N_T]=$shared
  T_VERDICT[N_T]=$verdict
  T_REASON[N_T]=$reason
  T_LINK[N_T]=$link
  N_T=$((N_T + 1))
}

find_manifests() { # $1 root
  [ -d "$1" ] || return 0
  find "$1" -maxdepth "$MAX_DEPTH" \
    \( -type d \( -name target -o -name node_modules -o -name .git -o -name .venv -o -name venv \
       -o -name Pods -o -name DerivedData \) -prune \) -o \
    \( -type f -name Cargo.toml -print \) 2>/dev/null
}

scan_root() {
  local root=$1 manifest dir
  [ -d "$root" ] || { warn "skipping $root (not a directory)"; return 0; }
  while IFS= read -r manifest; do
    [ -n "$manifest" ] || continue
    [ -f "$manifest" ] || continue
    add_manifest "$manifest"
    [ -n "$SHARED" ] && continue
    dir=$(dirname "$manifest")
    [ -d "$dir/target" ] || continue
    add_target "$dir/target" "$manifest" 0
  done <<EOF
$(find_manifests "$root")
EOF
}

for r in ${ROOTS[@]+"${ROOTS[@]}"}; do
  scan_root "$r"
done

if [ -n "$SHARED" ]; then
  first_manifest=""
  if [ -n "$MANIFESTS" ]; then
    first_manifest=${MANIFESTS%%"$NL"*}
  fi
  add_target "$SHARED" "$first_manifest" 1
fi

# Report-only caches. Never planned.
CARGO_HOME_DIR=${CARGO_HOME:-$HOME/.cargo}
CACHE_REG="$CARGO_HOME_DIR/registry/cache"
CACHE_GIT="$CARGO_HOME_DIR/git/checkouts"
REG_SIZE=""
GIT_SIZE=""
[ -d "$CACHE_REG" ] && REG_SIZE=$(du_kb "$CACHE_REG")
[ -d "$CACHE_GIT" ] && GIT_SIZE=$(du_kb "$CACHE_GIT")

# A path we are willing to delete by hand: direct target/ beside Cargo.toml,
# or exactly the resolved CARGO_TARGET_DIR. Never a symlink.
safe_to_remove() {
  local t=$1 shared_flag=$2 c parent
  c=$(canon "$t") || return 1
  [ -n "$c" ] && [ -d "$c" ] && [ ! -L "$t" ] || return 1
  case $c in
    /*/*) ;;
    *) return 1 ;;
  esac
  [ "$c" != "$HOME" ] && [ "$c" != "$HOME_C" ] && [ "$c" != "/" ] || return 1
  if [ "$shared_flag" = 1 ]; then
    [ -n "$SHARED" ] && [ "$c" = "$SHARED" ]
    return $?
  fi
  [ "$(basename "$c")" = "target" ] || return 1
  parent=$(dirname "$c")
  [ -f "$parent/Cargo.toml" ]
}

order_t() {
  local j rank=0
  for ((j = 0; j < N_T; j++)); do
    if [ "${T_VERDICT[j]}" = SAFE ]; then rank=0; else rank=1; fi
    printf '%s\t%s\t%s\n' "$rank" "${T_SIZE[j]:-0}" "$j"
  done | sort -t "$(printf '\t')" -k1,1n -k2,2nr | cut -f3
}

sum_t() {
  local j t=0 v
  for ((j = 0; j < N_T; j++)); do
    [ "${T_VERDICT[j]}" = SAFE ] || continue
    v=${T_SIZE[j]:-0}
    is_uint "$v" && t=$((t + v))
  done
  printf '%s' "$t"
}
count_v() {
  local j c=0
  for ((j = 0; j < N_T; j++)); do [ "${T_VERDICT[j]}" = "$1" ] && c=$((c + 1)); done
  printf '%s' "$c"
}

print_text() {
  local j size idle
  printf 'Cargo build output (read-only, regenerable)\n'
  if [ -n "$SHARED" ]; then
    printf 'CARGO_TARGET_DIR is set (%s).\n' "$(pretty_path "$SHARED")"
    printf 'Reporting that shared directory only, so per-project target/ folders are not counted again.\n'
  elif [ -n "$SHARED_NOTE" ]; then
    printf '%s\n' "$SHARED_NOTE"
  fi
  if [ "$cargo_busy" = 1 ]; then
    printf 'A cargo or rustc process is running. Targets are REVIEW until it exits.\n'
  fi
  if [ "$N_T" -eq 0 ]; then
    printf 'No Cargo target directories in the scanned repos and worktrees.\n'
  else
    printf '%-7s %7s %5s  %s\n' VERDICT SIZE IDLE TARGET
    for j in $(order_t); do
      if [ -n "${T_SIZE[j]}" ]; then size=$(human_kb "${T_SIZE[j]}"); else size="-"; fi
      if [ -n "${T_IDLE[j]}" ]; then idle="${T_IDLE[j]}d"; else idle="-"; fi
      printf '%-7s %7s %5s  %s\n' "${T_VERDICT[j]}" "$size" "$idle" "$(pretty_path "${T_PATH[j]}")"
      if [ "${T_SHARED[j]}" = 1 ]; then
        printf '         shared CARGO_TARGET_DIR'
      else
        printf '         next to %s' "$(pretty_path "${T_MANIFEST[j]}")"
      fi
      printf ' - %s\n' "${T_REASON[j]}"
    done
    if [ "$DO_SIZE" = 1 ]; then
      printf '  SAFE %s (%s reclaimable), REVIEW %s\n' "$(count_v SAFE)" "$(human_kb "$(sum_t)")" "$(count_v REVIEW)"
    else
      printf '  SAFE %s, REVIEW %s (sizes skipped)\n' "$(count_v SAFE)" "$(count_v REVIEW)"
    fi
    if [ "$have_cargo" = 1 ]; then
      printf '  Cleanup uses cargo clean (after approval).\n'
    else
      printf '  cargo is not on PATH. Cleanup removes the target directory (after approval).\n'
    fi
  fi
  printf '\nCargo caches (report only, not deleted by the plan):\n'
  if [ -d "$CACHE_REG" ]; then
    printf '  %-40s %s\n' "$(pretty_path "$CACHE_REG")" "$( [ "$DO_SIZE" = 1 ] && human_kb "${REG_SIZE:-0}" || printf '-' )"
  else
    printf '  %s  (not present)\n' "$(pretty_path "$CACHE_REG")"
  fi
  if [ -d "$CACHE_GIT" ]; then
    printf '  %-40s %s\n' "$(pretty_path "$CACHE_GIT")" "$( [ "$DO_SIZE" = 1 ] && human_kb "${GIT_SIZE:-0}" || printf '-' )"
  else
    printf '  %s  (not present)\n' "$(pretty_path "$CACHE_GIT")"
  fi
}

print_plan() {
  local j n=0 manifest
  printf '# Cargo targets (generated %s). NOTHING HAS BEEN RUN.\n' "$(fmt_date "$NOW")"
  printf '# Only a target/ next to a Cargo.toml, or the CARGO_TARGET_DIR directory.\n'
  if [ "$cargo_busy" = 1 ]; then
    printf '# cargo or rustc is running. No cleanup commands generated.\n'
  fi
  for j in $(order_t); do
    [ "${T_VERDICT[j]}" = SAFE ] || continue
    manifest=${T_MANIFEST[j]}
    if [ "${T_LINK[j]}" = 1 ] && { [ "$have_cargo" != 1 ] || [ -z "$manifest" ] || [ ! -f "$manifest" ]; }; then
      warn "skipping ${T_PATH[j]} (symlink; cargo is not on PATH, so it was not removed)"
      continue
    fi
    if [ "$have_cargo" != 1 ] || [ -z "$manifest" ] || [ ! -f "$manifest" ]; then
      if ! safe_to_remove "${T_PATH[j]}" "${T_SHARED[j]}"; then
        warn "skipping ${T_PATH[j]} (not an adjacent target/ or CARGO_TARGET_DIR)"
        continue
      fi
    fi
    printf '# %s  %s  %s\n' "$(human_kb "${T_SIZE[j]:-0}")" "$(pretty_path "${T_PATH[j]}")" "${T_REASON[j]}"
    if [ "$have_cargo" = 1 ] && [ -n "$manifest" ] && [ -f "$manifest" ]; then
      printf 'cargo clean --manifest-path %s\n' "$(shq "$manifest")"
    else
      if [ "$have_cargo" = 1 ]; then
        printf '# cargo is on PATH but no Cargo.toml was found for this directory.\n'
      else
        printf '# cargo is not on PATH; removing the target directory.\n'
      fi
      printf 'rm -rf %s\n' "$(shq "${T_PATH[j]}")"
    fi
    n=$((n + 1))
  done
  [ "$n" -eq 0 ] && printf '# No SAFE Cargo targets.\n'
  printf '# ~/.cargo registry cache and git checkouts are report-only and omitted.\n'
}

print_json() {
  local j first
  printf '{\n'
  printf '  "skipped": false,\n'
  if [ -n "$SHARED" ]; then printf '  "cargo_target_dir": %s,\n' "$(json_str "$SHARED")"
  elif [ -n "${CARGO_TARGET_DIR:-}" ]; then printf '  "cargo_target_dir": %s,\n' "$(json_str "$CARGO_TARGET_DIR")"
  else printf '  "cargo_target_dir": null,\n'; fi
  printf '  "shared_only": %s,\n' "$( [ -n "$SHARED" ] && printf true || printf false )"
  printf '  "cargo_on_path": %s,\n' "$(json_bool "$have_cargo")"
  printf '  "build_running": %s,\n' "$(json_bool "$cargo_busy")"
  printf '  "safe": %s,\n  "review": %s,\n' "$(count_v SAFE)" "$(count_v REVIEW)"
  if [ "$DO_SIZE" = 1 ]; then printf '  "safe_kb": %s,\n' "$(sum_t)"; fi
  printf '  "targets": ['
  first=1
  if [ "$N_T" -gt 0 ]; then
    for j in $(order_t); do
      [ $first = 1 ] || printf ','
      first=0
      printf '\n    {"verdict": %s, "path": %s, "shared": %s, "size_kb": %s' \
        "$(json_str "${T_VERDICT[j]}")" "$(json_str "${T_PATH[j]}")" \
        "$(json_bool "${T_SHARED[j]}")" "$(json_num_or_null "${T_SIZE[j]}")"
      if [ -n "${T_MANIFEST[j]}" ]; then printf ', "manifest": %s' "$(json_str "${T_MANIFEST[j]}")"; else printf ', "manifest": null'; fi
      if is_uint "${T_MTIME[j]}" && [ "${T_MTIME[j]}" -gt 0 ]; then
        printf ', "last_modified": %s, "idle_days": %s' "$(json_str "$(fmt_date "${T_MTIME[j]}")")" "${T_IDLE[j]}"
      else
        printf ', "last_modified": null, "idle_days": null'
      fi
      printf ', "reason": %s}' "$(json_str "${T_REASON[j]}")"
    done
    printf '\n  '
  fi
  printf '],\n'
  printf '  "caches": {\n'
  printf '    "registry_cache": {"path": %s, "present": %s, "size_kb": %s, "report_only": true},\n' \
    "$(json_str "$CACHE_REG")" "$( [ -d "$CACHE_REG" ] && printf true || printf false )" "$(json_num_or_null "$REG_SIZE")"
  printf '    "git_checkouts": {"path": %s, "present": %s, "size_kb": %s, "report_only": true}\n' \
    "$(json_str "$CACHE_GIT")" "$( [ -d "$CACHE_GIT" ] && printf true || printf false )" "$(json_num_or_null "$GIT_SIZE")"
  printf '  }\n'
  printf '}\n'
}

case $OUTPUT in
  json) print_json ;;
  plan) print_plan ;;
  *) print_text ;;
esac
exit 0
