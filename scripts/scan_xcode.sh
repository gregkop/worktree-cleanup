#!/usr/bin/env bash
# scan_xcode.sh - report Xcode and iOS simulator disk use. READ-ONLY.
#
# Nothing here is ever deleted. --plan only prints commands.
# macOS only, unless XCODE_SCAN_ENABLE=1 (used by tests on Linux).
# Bash 3.2+. Called by scan_worktrees.sh; safe to run on its own.
# License: MIT. https://github.com/gregkop/worktree-cleanup

set -u
export LC_ALL=C

VERSION="1.1.0"
STALE_DAYS=14
OUTPUT="text"
DO_SIZE=1

usage() {
  cat <<'EOF'
Usage: scan_xcode.sh [options]

Report Xcode DerivedData, unavailable iOS simulators, old iOS DeviceSupport
folders, and Archives size. Read-only. macOS only (skipped elsewhere).

Options:
  --json             Machine-readable JSON.
  --plan             Print (do NOT run) cleanup commands for SAFE rows.
  --stale-days N     DerivedData untouched for at least N days is stale
                     (default 14). Source-missing folders are SAFE sooner.
  --no-size          Skip disk-usage measurement.
  -h, --help         Show this help.
  --version          Show version.

DerivedData is regenerable and can be marked SAFE only when Xcode is not
running (`pgrep -x Xcode`, or XCODE_RUNNING=1 to simulate that in tests).
Simulator cleanup is `xcrun simctl delete unavailable`, never rm.
Archives are reported and never included in --plan.

Overrides (absolute paths): XCODE_DERIVED_DATA, XCODE_SIM_DEVICES,
XCODE_DEVICE_SUPPORT, XCODE_ARCHIVES, XCODE_SIM_RUNTIMES.
EOF
}

die() { printf 'scan_xcode: %s\n' "$*" >&2; exit 2; }
warn() { printf 'scan_xcode: %s\n' "$*" >&2; }
is_uint() { case ${1:-} in ''|*[!0-9]*) return 1;; *) return 0;; esac; }

while [ $# -gt 0 ]; do
  case $1 in
    --json) OUTPUT="json" ;;
    --plan) OUTPUT="plan" ;;
    --stale-days) shift; is_uint "${1:-}" || die "--stale-days needs a number"; STALE_DAYS=$1 ;;
    --no-size) DO_SIZE=0 ;;
    -h|--help) usage; exit 0 ;;
    --version) printf '%s\n' "$VERSION"; exit 0 ;;
    --) shift; break ;;
    -*) die "unknown option: $1 (see --help)" ;;
    *) die "unexpected argument: $1" ;;
  esac
  shift
done

[ -n "${HOME:-}" ] || die "HOME is not set"

NOW=$(date +%s)

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

du_kb() {
  [ "$DO_SIZE" = 1 ] && [ -e "$1" ] || return 0
  du -sk "$1" 2>/dev/null | awk '{print $1; exit}'
}

newest_mtime() { # files and dirs passed as args
  local f tm best=0
  for f in "$@"; do
    [ -e "$f" ] || continue
    tm=$(file_mtime "$f") || true
    is_uint "$tm" && [ "$tm" -gt "$best" ] && best=$tm
  done
  printf '%s' "$best"
}

# WorkspacePath from an XML plist, a binary plist (plutil), or a strings dump.
plist_workspace_path() {
  local f=$1 raw
  [ -f "$f" ] || return 0
  if grep -q '<key>WorkspacePath</key>' "$f" 2>/dev/null; then
    awk '
      /<key>[[:space:]]*WorkspacePath[[:space:]]*<\/key>/ { want=1; next }
      want && /<string>/ {
        line=$0
        sub(/^[[:space:]]*<string>/, "", line)
        sub(/<\/string>[[:space:]]*$/, "", line)
        print line
        exit
      }
    ' "$f"
    return 0
  fi
  if command -v plutil >/dev/null 2>&1; then
    raw=$(plutil -extract WorkspacePath raw -o - "$f" 2>/dev/null) || raw=""
    [ -n "$raw" ] && { printf '%s' "$raw"; return 0; }
  fi
  # Binary plists store the key and the path as NUL-separated strings.
  tr -c '[:print:]\n' '\n' < "$f" 2>/dev/null | awk '
    grab && length($0) > 0 { print; exit }
    $0 == "WorkspacePath" { grab=1 }
  '
}

on_macos=0
[ "$(uname -s)" = "Darwin" ] && on_macos=1
[ "${XCODE_SCAN_ENABLE:-}" = 1 ] && on_macos=1

emit_skipped() { # $1 reason
  local reason=$1
  case $OUTPUT in
    json)
      printf '{\n  "skipped": true,\n  "reason": %s\n}\n' "$(json_str "$reason")"
      ;;
    plan)
      printf '# Xcode / iOS caches: skipped (%s).\n' "$reason"
      ;;
    *)
      printf 'Xcode / iOS caches: skipped (%s).\n' "$reason"
      ;;
  esac
}

if [ "$on_macos" != 1 ]; then
  emit_skipped "not macOS"
  exit 0
fi

DERIVED=${XCODE_DERIVED_DATA:-$HOME/Library/Developer/Xcode/DerivedData}
if [ -z "${XCODE_DERIVED_DATA:-}" ] && command -v defaults >/dev/null 2>&1; then
  custom=$(defaults read com.apple.dt.Xcode IDECustomDerivedDataLocation 2>/dev/null) || custom=""
  [ -n "$custom" ] && [ -d "$custom" ] && DERIVED=$custom
fi
SIM_DEVICES=${XCODE_SIM_DEVICES:-$HOME/Library/Developer/CoreSimulator/Devices}
DEVICE_SUPPORT=${XCODE_DEVICE_SUPPORT:-$HOME/Library/Developer/Xcode/iOS DeviceSupport}
ARCHIVES=${XCODE_ARCHIVES:-$HOME/Library/Developer/Xcode/Archives}
SIM_RUNTIMES=${XCODE_SIM_RUNTIMES:-$HOME/Library/Developer/CoreSimulator/Profiles/Runtimes}
SYS_RUNTIMES=/Library/Developer/CoreSimulator/Profiles/Runtimes

xcode_running=0
case ${XCODE_RUNNING:-} in
  1) xcode_running=1 ;;
  0) xcode_running=0 ;;
  *)
    if command -v pgrep >/dev/null 2>&1 && pgrep -x Xcode >/dev/null 2>&1; then
      xcode_running=1
    fi
    ;;
esac

# ---- DerivedData -----------------------------------------------------------
DD_NAME=(); DD_PATH=(); DD_SIZE=(); DD_MTIME=(); DD_IDLE=()
DD_WS=(); DD_SOURCE=(); DD_VERDICT=(); DD_REASON=()
N_DD=0
DD_TOTAL=""

consider_derived_dir() {
  local d=$1 name ws source verdict reason mtime idle
  [ -d "$d" ] || return 0
  name=$(basename "$d")
  case $name in .*|'*') return 0 ;; esac
  ws=$(plist_workspace_path "$d/info.plist")
  source=unknown
  case $ws in
    /*)
      if [ -e "$ws" ]; then source=exists; else source=missing; fi
      ;;
  esac
  mtime=$(newest_mtime "$d" "$d/info.plist" "$d/Build" "$d/Logs" "$d/Index.noindex")
  idle=""
  is_uint "$mtime" && [ "$mtime" -gt 0 ] && idle=$(( (NOW - mtime) / 86400 ))
  reason=""
  verdict=REVIEW
  if [ "$source" = missing ]; then
    reason="source project no longer exists ($ws)"
    verdict=SAFE
  fi
  if is_uint "$idle" && [ "$idle" -ge "$STALE_DAYS" ]; then
    if [ -n "$reason" ]; then
      reason="$reason; untouched ${idle}d"
    else
      reason="untouched ${idle}d"
      verdict=SAFE
    fi
  elif [ "$verdict" != SAFE ]; then
    if is_uint "$idle"; then
      reason="recently used (${idle}d ago)"
    else
      reason="age unknown"
    fi
    [ "$source" = exists ] && reason="$reason; source project still exists"
    [ "$source" = unknown ] && reason="$reason; no WorkspacePath"
  elif [ "$source" = exists ]; then
    reason="$reason; source project still exists"
  fi
  if [ "$xcode_running" = 1 ]; then
    verdict=REVIEW
    reason="Xcode is running; leave DerivedData alone until it quits ($reason)"
  fi
  DD_NAME[N_DD]=$name
  DD_PATH[N_DD]=$d
  DD_SIZE[N_DD]=$(du_kb "$d")
  DD_MTIME[N_DD]=$mtime
  DD_IDLE[N_DD]=$idle
  DD_WS[N_DD]=$ws
  DD_SOURCE[N_DD]=$source
  DD_VERDICT[N_DD]=$verdict
  DD_REASON[N_DD]=$reason
  N_DD=$((N_DD + 1))
}

if [ -d "$DERIVED" ]; then
  DD_TOTAL=$(du_kb "$DERIVED")
  for d in "$DERIVED"/* "$DERIVED"/.[!.]* "$DERIVED"/..?*; do
    [ -d "$d" ] || continue
    consider_derived_dir "$d"
  done
fi

# ---- simulators ------------------------------------------------------------
SIM_NAME=(); SIM_UDID=(); SIM_RUNTIME=(); SIM_PATH=(); SIM_SIZE=()
N_SIM=0
SIM_TOTAL=""
SIM_UNAVAIL_KB=0
HAVE_SIMCTL=0
command -v xcrun >/dev/null 2>&1 && HAVE_SIMCTL=1

if [ -d "$SIM_DEVICES" ]; then
  SIM_TOTAL=$(du_kb "$SIM_DEVICES")
fi

if [ "$HAVE_SIMCTL" = 1 ]; then
  sim_txt=$(xcrun simctl list devices unavailable 2>/dev/null) || sim_txt=""
  current_runtime=""
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case $line in
      --*--)
        current_runtime=$(printf '%s' "$line" | sed -n 's/^--[[:space:]]*//; s/[[:space:]]*--$//p')
        continue
        ;;
    esac
    case $line in
      *'(unavailable)'*) ;;
      *) continue ;;
    esac
    udid=$(printf '%s' "$line" | sed -n 's/.*(\([0-9A-Fa-f]\{8\}-[0-9A-Fa-f]\{4\}-[0-9A-Fa-f]\{4\}-[0-9A-Fa-f]\{4\}-[0-9A-Fa-f]\{12\}\)).*/\1/p')
    [ -n "$udid" ] || continue
    name=$(printf '%s' "$line" | sed -n 's/^[[:space:]]*\(.*\) ([0-9A-Fa-f]\{8\}-[0-9A-Fa-f]\{4\}-[0-9A-Fa-f]\{4\}-[0-9A-Fa-f]\{4\}-[0-9A-Fa-f]\{12\}).*/\1/p')
    dev_path="$SIM_DEVICES/$udid"
    [ -d "$dev_path" ] || dev_path=""
    size=""
    [ -n "$dev_path" ] && size=$(du_kb "$dev_path")
    if is_uint "$size"; then SIM_UNAVAIL_KB=$((SIM_UNAVAIL_KB + size)); fi
    SIM_NAME[N_SIM]=$name
    SIM_UDID[N_SIM]=$udid
    SIM_RUNTIME[N_SIM]=$current_runtime
    SIM_PATH[N_SIM]=$dev_path
    SIM_SIZE[N_SIM]=$size
    N_SIM=$((N_SIM + 1))
  done <<EOF
$sim_txt
EOF
fi

# ---- unavailable runtimes (report only) ------------------------------------
RT_LINE=(); RT_PATH=(); RT_SIZE=()
N_RT=0
if [ "$HAVE_SIMCTL" = 1 ]; then
  rt_txt=$(xcrun simctl list runtimes 2>/dev/null) || rt_txt=""
  while IFS= read -r line; do
    case $line in
      *'(unavailable)'*) ;;
      *) continue ;;
    esac
    match=""
    size=""
    for root in "$SIM_RUNTIMES" "$SYS_RUNTIMES"; do
      [ -d "$root" ] || continue
      for bundle in "$root"/*.simruntime "$root"/*; do
        [ -d "$bundle" ] || continue
        base=$(basename "$bundle")
        base=${base%.simruntime}
        case $line in
          *"$base"*) match=$bundle; break ;;
        esac
      done
      [ -n "$match" ] && break
    done
    [ -n "$match" ] && size=$(du_kb "$match")
    RT_LINE[N_RT]=$line
    RT_PATH[N_RT]=$match
    RT_SIZE[N_RT]=$size
    N_RT=$((N_RT + 1))
  done <<EOF
$rt_txt
EOF
fi

# ---- iOS DeviceSupport (report only) ---------------------------------------
DS_NAME=(); DS_PATH=(); DS_SIZE=(); DS_IDLE=(); DS_OLD=()
N_DS=0
DS_TOTAL=""
DS_OLD_COUNT=0
if [ -d "$DEVICE_SUPPORT" ]; then
  DS_TOTAL=$(du_kb "$DEVICE_SUPPORT")
  for d in "$DEVICE_SUPPORT"/*; do
    [ -d "$d" ] || continue
    name=$(basename "$d")
    mtime=$(newest_mtime "$d")
    idle=""
    old=0
    is_uint "$mtime" && [ "$mtime" -gt 0 ] && idle=$(( (NOW - mtime) / 86400 ))
    if is_uint "$idle" && [ "$idle" -ge "$STALE_DAYS" ]; then old=1; DS_OLD_COUNT=$((DS_OLD_COUNT + 1)); fi
    DS_NAME[N_DS]=$name
    DS_PATH[N_DS]=$d
    DS_SIZE[N_DS]=$(du_kb "$d")
    DS_IDLE[N_DS]=$idle
    DS_OLD[N_DS]=$old
    N_DS=$((N_DS + 1))
  done
fi

# ---- Archives (report only, never planned) ---------------------------------
ARCH_TOTAL=""
[ -d "$ARCHIVES" ] && ARCH_TOTAL=$(du_kb "$ARCHIVES")

is_direct_child() { # $1 parent, $2 child (both canonical)
  local parent=$1 child=$2 rel
  case $child in
    "$parent"/*) ;;
    *) return 1 ;;
  esac
  rel=${child#"$parent"/}
  case $rel in
    ""|*/*) return 1 ;;
  esac
  case $child in
    /|/*/*) ;;
    *) return 1 ;;
  esac
  [ "$child" != "/" ] && [ "$child" != "$HOME" ] && [ "$child" != "$HOME_C" ]
}

order_dd() {
  local j rank
  for ((j = 0; j < N_DD; j++)); do
    if [ "${DD_VERDICT[j]}" = SAFE ]; then rank=0; else rank=1; fi
    printf '%s\t%s\t%s\n' "$rank" "${DD_SIZE[j]:-0}" "$j"
  done | sort -t "$(printf '\t')" -k1,1n -k2,2nr | cut -f3
}

count_dd() { # $1 verdict
  local j c=0
  for ((j = 0; j < N_DD; j++)); do [ "${DD_VERDICT[j]}" = "$1" ] && c=$((c + 1)); done
  printf '%s' "$c"
}
sum_dd() { # $1 verdict or ALL
  local j t=0 v
  for ((j = 0; j < N_DD; j++)); do
    [ "$1" = ALL ] || [ "${DD_VERDICT[j]}" = "$1" ] || continue
    v=${DD_SIZE[j]:-0}
    is_uint "$v" && t=$((t + v))
  done
  printf '%s' "$t"
}

print_text() {
  local j size idle
  printf 'Xcode / iOS caches (read-only) - stale after %sd\n' "$STALE_DAYS"
  if [ "$xcode_running" = 1 ]; then
    printf 'Xcode is running. DerivedData is left as REVIEW until it quits.\n'
  else
    printf 'Xcode is not running.\n'
  fi

  if [ ! -d "$DERIVED" ]; then
    printf '\nDerivedData: not present (%s)\n' "$(pretty_path "$DERIVED")"
  else
    printf '\nDerivedData: %s in %s folder(s)' "$( [ "$DO_SIZE" = 1 ] && human_kb "${DD_TOTAL:-0}" || printf '-' )" "$N_DD"
    printf '  %s\n' "$(pretty_path "$DERIVED")"
    if [ "$N_DD" -eq 0 ]; then
      printf '  (empty)\n'
    else
      printf '%-7s %7s %5s  %-28s  %s\n' VERDICT SIZE IDLE FOLDER WHY
      for j in $(order_dd); do
        if [ -n "${DD_SIZE[j]}" ]; then size=$(human_kb "${DD_SIZE[j]}"); else size="-"; fi
        if [ -n "${DD_IDLE[j]}" ]; then idle="${DD_IDLE[j]}d"; else idle="-"; fi
        printf '%-7s %7s %5s  %-28s  %s\n' "${DD_VERDICT[j]}" "$size" "$idle" "${DD_NAME[j]}" "${DD_REASON[j]}"
      done
      if [ "$DO_SIZE" = 1 ]; then
        printf '  SAFE %s (%s), REVIEW %s (%s)\n' \
          "$(count_dd SAFE)" "$(human_kb "$(sum_dd SAFE)")" \
          "$(count_dd REVIEW)" "$(human_kb "$(sum_dd REVIEW)")"
      fi
    fi
  fi

  printf '\nUnavailable simulators'
  if [ "$HAVE_SIMCTL" != 1 ]; then
    printf ': xcrun not on PATH, skipped\n'
  else
    printf ': %s device(s)' "$N_SIM"
    if [ "$DO_SIZE" = 1 ]; then
      printf ', %s on disk' "$(human_kb "$SIM_UNAVAIL_KB")"
      [ -n "$SIM_TOTAL" ] && printf ' (Devices folder %s)' "$(human_kb "$SIM_TOTAL")"
    fi
    printf '\n'
    if [ "$N_SIM" -eq 0 ]; then
      printf '  none\n'
    else
      for ((j = 0; j < N_SIM; j++)); do
        if [ -n "${SIM_SIZE[j]}" ]; then size=$(human_kb "${SIM_SIZE[j]}"); else size="-"; fi
        printf '  SAFE %7s  %-38s  %s%s\n' "$size" "${SIM_UDID[j]}" "${SIM_NAME[j]}" \
          "${SIM_RUNTIME[j]:+  (${SIM_RUNTIME[j]})}"
      done
      printf '  After approval: xcrun simctl delete unavailable\n'
    fi
  fi

  printf '\nUnavailable runtimes (report only):\n'
  if [ "$HAVE_SIMCTL" != 1 ]; then
    printf '  xcrun not on PATH, skipped\n'
  elif [ "$N_RT" -eq 0 ]; then
    printf '  none\n'
  else
    for ((j = 0; j < N_RT; j++)); do
      if [ -n "${RT_SIZE[j]}" ]; then size=$(human_kb "${RT_SIZE[j]}"); else size="-"; fi
      printf '  %7s  %s\n' "$size" "$(printf '%s' "${RT_LINE[j]}" | sed 's/^[[:space:]]*//')"
    done
  fi

  printf '\niOS DeviceSupport (report only)'
  if [ ! -d "$DEVICE_SUPPORT" ]; then
    printf ': not present\n'
  else
    printf ': %s, %s version(s), %s older than %sd\n' \
      "$( [ "$DO_SIZE" = 1 ] && human_kb "${DS_TOTAL:-0}" || printf '-' )" \
      "$N_DS" "$DS_OLD_COUNT" "$STALE_DAYS"
    for ((j = 0; j < N_DS; j++)); do
      if [ -n "${DS_SIZE[j]}" ]; then size=$(human_kb "${DS_SIZE[j]}"); else size="-"; fi
      if [ -n "${DS_IDLE[j]}" ]; then idle="${DS_IDLE[j]}d"; else idle="-"; fi
      if [ "${DS_OLD[j]}" = 1 ]; then note=old; else note=recent; fi
      printf '  %-6s %7s %5s  %s\n' "$note" "$size" "$idle" "${DS_NAME[j]}"
    done
  fi

  printf '\nArchives (report only, never deleted here)'
  if [ ! -d "$ARCHIVES" ]; then
    printf ': not present (%s)\n' "$(pretty_path "$ARCHIVES")"
  else
    printf ': %s  %s\n' "$( [ "$DO_SIZE" = 1 ] && human_kb "${ARCH_TOTAL:-0}" || printf '-' )" "$(pretty_path "$ARCHIVES")"
  fi
}

print_plan() {
  local j parent cpath nsafe=0
  printf '# Xcode / iOS caches (generated %s). NOTHING HAS BEEN RUN.\n' "$(fmt_date "$NOW")"
  if [ "$xcode_running" = 1 ]; then
    printf '# Xcode is running (pgrep -x Xcode). DerivedData was not marked SAFE.\n'
    printf '# Quit Xcode and re-scan before removing any DerivedData.\n'
  elif [ -d "$DERIVED" ]; then
    parent=$(canon "$DERIVED")
    printf '# DerivedData folders below are regenerable. Remove only these direct children.\n'
    for j in $(order_dd); do
      [ "${DD_VERDICT[j]}" = SAFE ] || continue
      cpath=$(canon "${DD_PATH[j]}")
      [ -n "$cpath" ] || continue
      if ! is_direct_child "$parent" "$cpath"; then
        warn "skipping ${DD_PATH[j]} (not a direct child of DerivedData)"
        continue
      fi
      printf '# %s  %s  %s\n' "$(human_kb "${DD_SIZE[j]:-0}")" "${DD_NAME[j]}" "${DD_REASON[j]}"
      printf 'rm -rf %s\n' "$(shq "$cpath")"
      nsafe=$((nsafe + 1))
    done
    [ "$nsafe" -eq 0 ] && printf '# No SAFE DerivedData folders.\n'
  else
    printf '# DerivedData directory is not present.\n'
  fi
  if [ "$N_SIM" -gt 0 ]; then
    printf '\n# Unavailable simulators (%s). simctl only; do not rm device directories.\n' "$N_SIM"
    printf 'xcrun simctl delete unavailable\n'
  else
    printf '\n# No unavailable simulators to delete.\n'
  fi
  printf '\n# Archives and iOS DeviceSupport are report-only and are not listed here.\n'
  printf '# Unavailable runtimes are report-only. Delete one only if the user names it\n'
  printf '# (xcrun simctl runtime delete <identifier>).\n'
}

json_reasons() { # $1 reason string, pieces separated by "; "
  local rest=$1 first=1 part
  printf '['
  while [ -n "$rest" ]; do
    case $rest in
      *"; "*) part=${rest%%"; "*}; rest=${rest#*"; "} ;;
      *) part=$rest; rest="" ;;
    esac
    [ $first = 1 ] || printf ', '
    first=0
    json_str "$part"
  done
  printf ']'
}

print_json() {
  local j first
  printf '{\n'
  printf '  "skipped": false,\n'
  printf '  "reason": null,\n'
  printf '  "stale_days": %s,\n' "$STALE_DAYS"
  printf '  "xcode_running": %s,\n' "$(json_bool "$xcode_running")"
  printf '  "derived_data": {\n'
  printf '    "path": %s,\n' "$(json_str "$DERIVED")"
  printf '    "present": %s,\n' "$( [ -d "$DERIVED" ] && printf true || printf false )"
  printf '    "total_kb": %s,\n' "$(json_num_or_null "$DD_TOTAL")"
  printf '    "safe": %s,\n    "review": %s,\n' "$(count_dd SAFE)" "$(count_dd REVIEW)"
  printf '    "folders": ['
  first=1
  if [ "$N_DD" -gt 0 ]; then
    for j in $(order_dd); do
      [ $first = 1 ] || printf ','
      first=0
      printf '\n      {"name": %s, "path": %s, "size_kb": %s' \
        "$(json_str "${DD_NAME[j]}")" "$(json_str "${DD_PATH[j]}")" "$(json_num_or_null "${DD_SIZE[j]}")"
      if is_uint "${DD_MTIME[j]}" && [ "${DD_MTIME[j]}" -gt 0 ]; then
        printf ', "last_modified": %s, "idle_days": %s' "$(json_str "$(fmt_date "${DD_MTIME[j]}")")" "${DD_IDLE[j]}"
      else
        printf ', "last_modified": null, "idle_days": null'
      fi
      if [ -n "${DD_WS[j]}" ]; then printf ', "workspace_path": %s' "$(json_str "${DD_WS[j]}")"; else printf ', "workspace_path": null'; fi
      printf ', "source": %s, "verdict": %s, "reasons": ' \
        "$(json_str "${DD_SOURCE[j]}")" "$(json_str "${DD_VERDICT[j]}")"
      json_reasons "${DD_REASON[j]}"
      printf '}'
    done
    printf '\n    '
  fi
  printf ']\n  },\n'
  printf '  "simulators": {\n'
  printf '    "devices_path": %s,\n' "$(json_str "$SIM_DEVICES")"
  printf '    "xcrun": %s,\n' "$(json_bool "$HAVE_SIMCTL")"
  printf '    "devices_total_kb": %s,\n' "$(json_num_or_null "$SIM_TOTAL")"
  printf '    "unavailable_kb": %s,\n' "$( [ "$DO_SIZE" = 1 ] && printf '%s' "$SIM_UNAVAIL_KB" || printf null )"
  printf '    "unavailable": ['
  first=1
  for ((j = 0; j < N_SIM; j++)); do
    [ $first = 1 ] || printf ','
    first=0
    printf '\n      {"name": %s, "udid": %s, "runtime": %s, "path": %s, "size_kb": %s, "verdict": "SAFE"}' \
      "$(json_str "${SIM_NAME[j]}")" "$(json_str "${SIM_UDID[j]}")" \
      "$( [ -n "${SIM_RUNTIME[j]}" ] && json_str "${SIM_RUNTIME[j]}" || printf null )" \
      "$( [ -n "${SIM_PATH[j]}" ] && json_str "${SIM_PATH[j]}" || printf null )" \
      "$(json_num_or_null "${SIM_SIZE[j]}")"
  done
  [ "$N_SIM" -gt 0 ] && printf '\n    '
  printf ']\n  },\n'
  printf '  "runtimes": {"unavailable": ['
  first=1
  for ((j = 0; j < N_RT; j++)); do
    [ $first = 1 ] || printf ','
    first=0
    printf '\n      {"line": %s, "path": %s, "size_kb": %s}' \
      "$(json_str "${RT_LINE[j]}")" \
      "$( [ -n "${RT_PATH[j]}" ] && json_str "${RT_PATH[j]}" || printf null )" \
      "$(json_num_or_null "${RT_SIZE[j]}")"
  done
  [ "$N_RT" -gt 0 ] && printf '\n    '
  printf ']},\n'
  printf '  "device_support": {\n'
  printf '    "path": %s,\n' "$(json_str "$DEVICE_SUPPORT")"
  printf '    "present": %s,\n' "$( [ -d "$DEVICE_SUPPORT" ] && printf true || printf false )"
  printf '    "total_kb": %s,\n' "$(json_num_or_null "$DS_TOTAL")"
  printf '    "old": %s,\n' "$DS_OLD_COUNT"
  printf '    "report_only": true,\n'
  printf '    "versions": ['
  first=1
  for ((j = 0; j < N_DS; j++)); do
    [ $first = 1 ] || printf ','
    first=0
    printf '\n      {"name": %s, "path": %s, "size_kb": %s, "idle_days": %s, "old": %s}' \
      "$(json_str "${DS_NAME[j]}")" "$(json_str "${DS_PATH[j]}")" \
      "$(json_num_or_null "${DS_SIZE[j]}")" "$(json_num_or_null "${DS_IDLE[j]}")" \
      "$(json_bool "${DS_OLD[j]}")"
  done
  [ "$N_DS" -gt 0 ] && printf '\n    '
  printf ']\n  },\n'
  printf '  "archives": {\n'
  printf '    "path": %s,\n' "$(json_str "$ARCHIVES")"
  printf '    "present": %s,\n' "$( [ -d "$ARCHIVES" ] && printf true || printf false )"
  printf '    "total_kb": %s,\n' "$(json_num_or_null "$ARCH_TOTAL")"
  printf '    "report_only": true\n'
  printf '  }\n'
  printf '}\n'
}

case $OUTPUT in
  json) print_json ;;
  plan) print_plan ;;
  *) print_text ;;
esac
exit 0
