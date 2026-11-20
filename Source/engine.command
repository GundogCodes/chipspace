#!/bin/zsh -f
# Uses only utilities shipped with macOS. No sudo, downloads, or scheduled cleanup.
emulate -LR zsh
setopt PIPE_FAIL
unsetopt BG_NICE
umask 077
export PATH=/usr/bin:/bin:/usr/sbin:/sbin
export LC_ALL=C

typeset -g BASE=${0:A:h} ACCOUNT_HOME=${HOME:A} WORK='' REPORT_DIR=''
typeset -g SCAN_ONLY=0 LIMIT=45 PREVIOUS='' ACTION='' EXPLANATION='' ADVICE=''
typeset -ga ITEMS SIZES COMPLETE IDENTITIES
typeset -gA SEEN
typeset -g ACTIVE_PID='' TIMER_PID=''

say() { print -r -- "$*"; }
human() { /usr/bin/awk -v n="$1" 'BEGIN {printf "%.2f GiB", n/1048576}'; }
identity() { /usr/bin/stat -f '%d:%i:%u:%m:%c' "$1" 2>/dev/null; }
clean_exit() {
  [[ -n $ACTIVE_PID ]] && kill "$ACTIVE_PID" 2>/dev/null
  [[ -n $TIMER_PID ]] && kill "$TIMER_PID" 2>/dev/null
  [[ -n $WORK && $WORK == /private/tmp/mac-storage.* && -d $WORK && ! -L $WORK ]] && /bin/rm -rf -- "$WORK"
  return 0
}
trap clean_exit EXIT
trap 'exit 130' INT TERM HUP

# Bound each filesystem scan; never mistake a timeout for a complete result.
bounded_du() {
  local target=$1 depth=$2 output=$3 errors=$4 rc
  /usr/bin/du -x -k -d "$depth" "$target" >"$output" 2>"$errors" &
  ACTIVE_PID=$!
  ( /bin/sleep "$LIMIT"; kill -TERM "$ACTIVE_PID" 2>/dev/null ) &
  TIMER_PID=$!
  wait "$ACTIVE_PID"; rc=$?
  kill "$TIMER_PID" 2>/dev/null
  wait "$TIMER_PID" 2>/dev/null
  ACTIVE_PID=''; TIMER_PID=''
  return "$rc"
}

classify() {
  local p=$1 rel=${1#"$ACCOUNT_HOME/"}
  ACTION=inspect
  EXPLANATION='Unclassified application or system data. A folder name cannot establish whether its contents are disposable.'
  ADVICE='Inspect the folder and use its owning app to manage it. Direct cleanup is disabled.'
  case "$rel" in
    Library/Developer/Xcode/DerivedData/*)
      if [[ ${p:h} == "$ACCOUNT_HOME/Library/Developer/Xcode/DerivedData" ]]; then
        ACTION=conditional
        EXPLANATION='Xcode generated build output, indexes, and downloaded build dependencies.'
        ADVICE='Quit Xcode and all builds first. Rebuilds/indexing take time; dependencies may need internet. Source projects elsewhere are retained.'
      fi ;;
    'Library/Developer/Xcode/iOS DeviceSupport/'*)
      if [[ ${p:h} == "$ACCOUNT_HOME/Library/Developer/Xcode/iOS DeviceSupport" ]]; then
        ACTION=conditional
        EXPLANATION='Symbols and support files for debugging a particular physical-device OS version.'
        ADVICE='Quit Xcode. Remove only a version you no longer need; old crash logs may become harder to symbolicate. Reconnecting a matching device can regenerate support.'
      fi ;;
    Library/Developer/Xcode/Archives*)
      EXPLANATION='Archived app builds and debug symbols; may be needed for distribution or crash diagnosis.'
      ADVICE='Keep or back up archives; review in Xcode Organizer. Not treated as cache.' ;;
    Library/Developer/CoreSimulator*)
      EXPLANATION='Simulated devices, installed test apps, and their local data.'
      ADVICE='Use the simulator menu in this script. Deleting a device destroys its test data; runtime removal is separate.' ;;
    Library/Caches/pip|Library/Caches/uv|Library/Caches/node-gyp|Library/Caches/go-build|Library/Caches/org.swift.swiftpm|.npm/_cacache|.npm/_npx|.cache/pip|.cache/uv)
      ACTION=conditional
      EXPLANATION='Package downloads or generated development cache.'
      ADVICE='Stop package installs and builds. Future work may redownload packages or rebuild. Offline work may fail until restored.' ;;
    Library/Caches/Dia|Library/Caches/Arc|Library/Caches/Codex|Library/Caches/company.thebrowser.dia|Library/Caches/company.thebrowser.Browser)
      ACTION=conditional
      EXPLANATION='Known application cache; a browser updater cache may contain staged app versions.'
      ADVICE='Fully quit the owning app and finish any update first. Cached/offline content may disappear and downloads will recur. Do not remove an active updater staging area.' ;;
    Library/Caches/*|.cache/*)
      EXPLANATION='Cache or runtime directory. Some apps store large models or required runtimes here; the name alone is not a safety guarantee.'
      ADVICE='Inspect contents. Only recognized cache locations get direct deletion controls.' ;;
    Library/Logs/*)
      if [[ ${p:h} == "$ACCOUNT_HOME/Library/Logs" && ${p:t} != com.apple.* ]]; then
        ACTION=conditional
        EXPLANATION='User application diagnostic logs; useful for troubleshooting.'
        ADVICE='Quit the owning app. Deletion loses diagnostic history; active or faulty apps can generate logs again.'
      fi ;;
    .codex*)
      EXPLANATION='Codex application state, chat/session history, installed plugins, and supporting files.'
      ADVICE='Not a blanket cache. Preserve history and settings; manage through Codex or inspect individual files.' ;;
    .ollama/models)
      ACTION=conditional
      EXPLANATION='The ENTIRE local Ollama model store: downloaded weights, imported/custom models, and manifests.'
      ADVICE='This removes ALL local Ollama models. Quit Ollama and dependent apps. Back up custom/imported models first. For individual models, use Ollama rm instead. This is optional data, not disposable cache.' ;;
    .ollama*|.lmstudio*)
      EXPLANATION='Local AI models and application state; model weights can occupy many gigabytes.'
      ADVICE='Remove unused models through the model application. Keep models needed for offline use.' ;;
    'Library/Application Support/MobileSync'*)
      EXPLANATION='Local iPhone/iPad backups, which may be the only recoverable copy of device data.'
      ADVICE='Review backups in Finder > connected device > General > Manage Backups.' ;;
    'Library/Application Support/minecraft'*)
      EXPLANATION='Minecraft installation data, mods, worlds, and world backups.'
      ADVICE='Worlds and backups are personal data. Manage through the launcher/game; do not clear this as cache.' ;;
    Library/Containers/com.docker.docker*)
      EXPLANATION='Docker virtual disk and app data, including container images and possibly databases.'
      ADVICE='Use Docker Desktop storage controls or docker system df -v. Never delete its virtual disk as generic cache.' ;;
    Library/Containers/*|Library/Group\ Containers/*|'Library/Application Support/'*)
      EXPLANATION='Application support or sandbox data: may include databases, profiles, downloads, credentials, or documents.'
      ADVICE='Use the owning app to remove downloads/data. Direct deletion is disabled for unclassified app state.' ;;
    Library/Mail*|Library/Messages*|Library/Mobile\ Documents*|Library/CloudStorage*)
      EXPLANATION='Personal messages, email, or cloud-synced files; removal can affect synced copies.'
      ADVICE='Manage in the owning application. Never use cache cleanup for this data.' ;;
    .Trash*)
      EXPLANATION='Items already in Trash; they still occupy storage.'
      ADVICE='Review in Finder before emptying. This script never empties your existing Trash.' ;;
  esac
  # Apply model rule after the broader .cache rule.
  if [[ ${p:h} == "$ACCOUNT_HOME/.cache/huggingface/hub" && ${p:t} == models--* ]]; then
    ACTION=conditional
    EXPLANATION='One downloaded Hugging Face model repository, including cached revisions and weights.'
    ADVICE='Stop model servers first. Delete only an unused downloadable model with no local-only edits. Offline use stops; downloading again may need access credentials.'
  fi
  if [[ $p != "$ACCOUNT_HOME/"* ]]; then
    ACTION=inspect
    case "$p" in
      /System/Library/AssetsV2/*iOSSimulatorRuntime*)
        EXPLANATION='Apple-managed iOS simulator runtime packages, separate from simulated device data.'
        ADVICE='Use the runtime menu in this script or Xcode Settings > Components; never remove protected assets by hand.' ;;
      /Library/Developer/CoreSimulator*)
        EXPLANATION='Shared simulator support, runtime images, and generated simulator caches.'
        ADVICE='Manage with Xcode/simctl. Keep system-owned cache and runtime directories intact.' ;;
      /Library/Developer/CommandLineTools*)
        EXPLANATION='Compiler tools, SDKs, and headers used by development tools.'
        ADVICE='Not disposable cache. Removing this breaks tools that depend on it.' ;;
      /System/Library/AssetsV2*)
        EXPLANATION='Downloaded Apple system assets, such as speech models, developer documentation, and optional features.'
        ADVICE='Manage the corresponding feature/component through its application or System Settings.' ;;
      /System/Volumes/VM*|/private/var/vm*)
        EXPLANATION='macOS virtual-memory swap and related runtime storage.'
        ADVICE='Do not delete. Reduce memory pressure by closing heavy apps; macOS manages these files.' ;;
      /private/var*)
        EXPLANATION='System databases, temporary working files, logs, and service state.'
        ADVICE='Do not clear this directory. Identify the specific service if it grows excessively.' ;;
    esac
  fi
}

# Direct cleanup only within a recognized location, with no symlink ancestors.
guard_path() {
  local p=$1 expected=$2 q=$1
  [[ -n $p && -e $p && ! -L $p && $p == "$ACCOUNT_HOME/"* ]] || return 1
  [[ $p != *$'\n'* && $p != *$'\t'* && $p != *$'\r'* ]] || return 1
  [[ ${p:A} == "$p" ]] || return 1
  while [[ $q != / ]]; do
    [[ ! -L $q ]] || return 1
    q=${q:h}
  done
  [[ $(/usr/bin/stat -f '%u' "$p") == $EUID ]] || return 1
  [[ $(/usr/bin/stat -f '%d' "$p") == $(/usr/bin/stat -f '%d' "${p:h}") ]] || return 1
  [[ $(identity "$p") == "$expected" ]] || return 1
  classify "$p"
  [[ $ACTION == conditional ]]
}

add_scope() {
  local root=$1 depth=${2:-1} code=0 kb p ok
  [[ -e $root && ! -L $root ]] || return
  say "Scanning ${(V)root} ..."
  bounded_du "$root" "$depth" "$WORK/du" "$WORK/errors" || code=$?
  ok=yes
  if (( code != 0 )) || [[ -s $WORK/errors ]]; then
    ok=no
    { say "PARTIAL OR UNREADABLE: $root (exit $code)"; /bin/cat "$WORK/errors"; } >> "$REPORT_DIR/scan-errors.txt"
  fi
  while IFS=$'\t' read -r kb p; do
    [[ $kb == <-> && $p == /* && $p != *$'\n'* && $p != *$'\r'* && $p != *$'\t'* ]] || continue
    [[ ${SEEN[$p]:-} == yes ]] && continue
    SEEN[$p]=yes
    ITEMS+=("$p"); SIZES+=("$kb"); COMPLETE+=("$ok"); IDENTITIES+=("$(identity "$p")")
  done < "$WORK/du"
}

write_report() {
  local i p
  print -r -- $'id\tallocated_KiB\tcomplete\taction\tpath' > "$REPORT_DIR/inventory.tsv"
  {
    say 'MAC STORAGE INSPECTOR'
    say "Created: $(/bin/date)"
    say "macOS: $(/usr/bin/sw_vers -productVersion) | CPU: $(/usr/bin/uname -m)"
    say 'GiB means 1024^3 bytes. These are allocated-file measurements, not guaranteed reclaimable bytes.'
    say 'This is an inventory of common contributors, NOT an exact reconstruction of Apple System Data.'
    say 'Nested rows overlap: NEVER add parent and child rows. APFS clones/snapshots can retain shared blocks.'
    say 'Other user accounts, custom model locations, and unreadable folders may be missing.'
    say 'PARTIAL rows are lower bounds, not zero/complete measurements. See scan-errors.txt.'
    say 'Only explicitly recognized user-owned data gets conditional cleanup; nothing is universally safe.'
    say ''
    /bin/cat "$REPORT_DIR/disk-and-snapshots.txt"
    say ''
    for i in {1..${#ITEMS}}; do
      p=$ITEMS[$i]; classify "$p"
      printf '%s\t%s\t%s\t%s\t%s\n' "$i" "$SIZES[$i]" "$COMPLETE[$i]" "$ACTION" "$p" >> "$REPORT_DIR/inventory.tsv"
      say "[$i] $(human "$SIZES[$i]") | $ACTION | complete=$COMPLETE[$i]"
      say "  ${(V)p}"
      say "  What it does: $EXPLANATION"
      say "  Deletion/prevention: $ADVICE"
    done
  } > "$REPORT_DIR/report.txt"
  if [[ -n $PREVIOUS && -f $PREVIOUS/inventory.tsv ]]; then
    /usr/bin/awk -F '\t' 'NR==FNR {if(FNR>1){old[$5]=$2;complete[$5]=$3}next} FNR>1 && ($5 in old) && $3=="yes" && complete[$5]=="yes" {printf "%.0f\t%s\n",$2-old[$5],$5}' "$PREVIOUS/inventory.tsv" "$REPORT_DIR/inventory.tsv" | /usr/bin/sort -nr > "$REPORT_DIR/growth-KiB.tsv"
  fi
}

show_largest() {
  say ''; say 'Largest measured locations (nested rows overlap; do not add them):'
  /usr/bin/awk -F '\t' 'NR>1 {print}' "$REPORT_DIR/inventory.tsv" | /usr/bin/sort -t $'\t' -k2,2nr | /usr/bin/head -35 | while IFS=$'\t' read -r id kb complete action p; do
    printf '[%s] %10s  %-11s %s%s\n' "$id" "$(human "$kb")" "$action" "${(V)p}" "${${complete/no/ [PARTIAL]}/yes/}"
  done
}

inspect_item() {
  local id=$1 p=$ITEMS[$1]
  classify "$p"
  say ''; say "[$id] ${(V)p} | $(human "$SIZES[$id]") | $ACTION"
  say "$EXPLANATION"; say "$ADVICE"
  say "Scan complete: $COMPLETE[$id]"
}

cleanup_item() {
  local id=$1 mode=$2 p=$ITEMS[$1] reply rc=0 before after current_id kb unused
  inspect_item "$id"
  if ! guard_path "$p" "$IDENTITIES[$id]"; then
    say 'Cleanup refused: unclassified/protected, symlink, ownership, or changed path. Rescan if needed.'; return
  fi
  # A parent scan can have unrelated permission errors. Require a complete scan
  # of the exact selected candidate before permitting any operation.
  bounded_du "$p" 0 "$WORK/recheck" "$WORK/recheck-errors" || { say 'Could not fully remeasure; cancelled.'; return; }
  [[ ! -s $WORK/recheck-errors ]] || { say 'Unreadable content; cancelled.'; return; }
  IFS=$'\t' read -r kb unused < "$WORK/recheck"
  [[ $kb == <-> ]] || { say 'Invalid measurement; cancelled.'; return; }
  say "Current allocation: $(human "$kb"). Actual freed space can be lower."
  say 'Fully quit the owning app, builds/model servers, and any updater before continuing.'
  say 'No process check can prove a cache is unused. You must confirm it is not in use.'
  read -r "reply?Type CLOSED to confirm you have stopped everything using this item: "
  [[ $reply == CLOSED ]] || { say 'Cancelled.'; return; }
  if [[ $mode == delete ]]; then
    say 'PERMANENT DELETION: this does not go to Trash and has no undo.'
    read -r "reply?Type DELETE $id to permanently remove exactly this item: "
    [[ $reply == "DELETE $id" ]] || { say 'Cancelled.'; return; }
  else
    say 'Moving to Trash is reversible but DOES NOT free disk space until removed from Trash.'
    read -r "reply?Type TRASH $id to move exactly this item to Trash: "
    [[ $reply == "TRASH $id" ]] || { say 'Cancelled.'; return; }
  fi
  guard_path "$p" "$IDENTITIES[$id]" || { say 'Path changed since scan; cancelled.'; return; }
  before=$(/bin/df -k "$ACCOUNT_HOME" | /usr/bin/awk 'END {print $4}')
  if [[ $mode == delete ]]; then
    /bin/rm -rfx -- "$p" || rc=$?
  else
    local trash="$ACCOUNT_HOME/.Trash" dest
    [[ -d $trash && ! -L $trash && ${trash:A} == "$trash" && $(/usr/bin/stat -f '%u' "$trash") == $EUID ]] || { say 'Trash is unavailable or redirected; cancelled.'; return; }
    dest="$trash/${p:t}.storage-inspector.$(/bin/date +%Y%m%d-%H%M%S).$$"
    [[ ! -e $dest && ! -L $dest ]] || { say 'Destination exists; cancelled.'; return; }
    /bin/mv -n -- "$p" "$dest" || rc=$?
    say "Trash destination: ${(V)dest}"
  fi
  after=$(/bin/df -k "$ACCOUNT_HOME" | /usr/bin/awk 'END {print $4}')
  if (( rc != 0 )) || [[ -e $p || -L $p ]]; then
    say 'Operation failed, was partial, or the app recreated the item. Inspect before retrying.'
  else
    say 'Selected item removed from its original location.'
  fi
  say "Observed free-space change: $((after-before)) KiB (other apps/snapshots can affect this)."
  printf '%s\t%s\t%s\texit=%s\tfree_delta_KiB=%s\n' "$(/bin/date -u +%FT%TZ)" "$mode" "$p" "$rc" "$((after-before))" >> "$REPORT_DIR/actions.tsv"
  COMPLETE[$id]=no
  IDENTITIES[$id]='removed-or-attempted'
  say 'The saved report is a pre-cleanup snapshot. Run another scan for current sizes.'
}

simulator_menu() {
  local kind reply uuid listing helptext
  /usr/bin/xcode-select -p >/dev/null 2>&1 || { say 'Xcode tools are unavailable.'; return; }
  read -r 'kind?Manage [r] runtime packages or [d] simulated devices (anything else cancels): '
  case $kind in
    r) listing=$(/usr/bin/xcrun simctl runtime list 2>&1) || { say "$listing"; say 'Use Xcode Settings > Components on this version.'; return; } ;;
    d) listing=$(/usr/bin/xcrun simctl list devices 2>&1) || { say "$listing"; return; } ;;
    *) return ;;
  esac
  say "$listing"
  say 'Select one UUID from this live list. Bulk aliases such as all are forbidden.'
  read -r 'uuid?UUID to review (blank cancels): '
  [[ $uuid =~ '^[0-9A-Fa-f]{8}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{4}-[0-9A-Fa-f]{12}$' ]] || { say 'Cancelled: expected one UUID.'; return; }
  uuid=${(U)uuid}
  print -r -- "$listing" | /usr/bin/grep -F -- "$uuid" || { say 'UUID not in current inventory.'; return; }
  if [[ $kind == r ]]; then
    say 'This removes a simulator OS package. Devices depending on it cannot run until you reinstall it; running simulators may stop.'
    helptext=$(/usr/bin/xcrun simctl help runtime 2>&1)
    if [[ $helptext == *--dry-run* ]]; then
      /usr/bin/xcrun simctl runtime delete "$uuid" --dry-run || { say 'Preview failed; cancelled.'; return; }
    fi
  else
    say 'This permanently deletes ONE simulated device and ALL of its apps/test data. It does not uninstall its OS runtime.'
  fi
  say 'Quit Xcode, Simulator, and all tests before proceeding.'
  read -r "reply?Type DELETE $uuid to proceed, or anything else to cancel: "
  [[ $reply == "DELETE $uuid" ]] || { say 'Cancelled.'; return; }
  local rc=0
  if [[ $kind == r ]]; then
    /usr/bin/xcrun simctl runtime delete "$uuid" || rc=$?
  else
    /usr/bin/xcrun simctl delete "$uuid" || rc=$?
  fi
  printf '%s\tsimctl-%s\t%s\texit=%s\n' "$(/bin/date -u +%FT%TZ)" "$kind" "$uuid" "$rc" >> "$REPORT_DIR/actions.tsv"
  say "Apple's tool returned exit $rc. Rescan to verify storage; no raw system files were removed by this script."
}

self_test() {
  # Disposable fixtures only. This mode never scans or modifies the real home directory.
  local saved_home=$ACCOUNT_HOME testroot p sig failures=0
  testroot=$(/usr/bin/mktemp -d /private/tmp/mac-storage-tests.XXXXXXXX) || return 1
  ACCOUNT_HOME="$testroot/home"
  /bin/mkdir -p "$ACCOUNT_HOME/Library/Caches/pip" "$ACCOUNT_HOME/Documents" "$ACCOUNT_HOME/Library/Developer/Xcode/DerivedData/Example"
  p="$ACCOUNT_HOME/Library/Caches/pip"; sig=$(identity "$p")
  guard_path "$p" "$sig" || (( failures++ ))
  guard_path "$ACCOUNT_HOME/Documents" "$(identity "$ACCOUNT_HOME/Documents")" && (( failures++ ))
  guard_path "$ACCOUNT_HOME/Library/Caches" "$(identity "$ACCOUNT_HOME/Library/Caches")" && (( failures++ ))
  /bin/mv "$p" "$ACCOUNT_HOME/Library/Caches/old-pip"
  /bin/ln -s "$ACCOUNT_HOME/Documents" "$p"
  guard_path "$p" "$sig" && (( failures++ ))
  /bin/rm "$p"
  /bin/mkdir "$p"
  guard_path "$p" "$sig" && (( failures++ ))
  # Symlink ancestors are also refused.
  /bin/mv "$ACCOUNT_HOME/Library/Caches" "$ACCOUNT_HOME/cache-target"
  /bin/ln -s "$ACCOUNT_HOME/cache-target" "$ACCOUNT_HOME/Library/Caches"
  guard_path "$p" "$(identity "$p")" && (( failures++ ))
  # Verify actual deletion mechanism does not follow an internal symlink.
  p="$ACCOUNT_HOME/Library/Developer/Xcode/DerivedData/Example"
  print -r -- 'keep' > "$ACCOUNT_HOME/Documents/keep.txt"
  /bin/ln -s "$ACCOUNT_HOME/Documents" "$p/link"
  sig=$(identity "$p")
  if guard_path "$p" "$sig"; then /bin/rm -rfx -- "$p"; else (( failures++ )); fi
  [[ -f "$ACCOUNT_HOME/Documents/keep.txt" && ! -e $p ]] || (( failures++ ))
  # Exercise the real confirmation flow, including a partial parent scan.
  /bin/mkdir -p "$p" "$testroot/report" "$testroot/work" "$ACCOUNT_HOME/.Trash"
  local saved_work=$WORK saved_report=$REPORT_DIR
  WORK="$testroot/work"; REPORT_DIR="$testroot/report"
  ITEMS=("$p"); SIZES=(0); COMPLETE=(no); IDENTITIES=("$(identity "$p")")
  printf 'CLOSED\nNO\n' | cleanup_item 1 delete > "$testroot/cancel.log"
  [[ -d $p ]] || (( failures++ ))
  printf 'CLOSED\nDELETE 1\n' | cleanup_item 1 delete > "$testroot/delete.log"
  [[ ! -e $p ]] || (( failures++ ))
  /bin/mkdir -p "$p"
  IDENTITIES=("$(identity "$p")")
  printf 'CLOSED\nTRASH 1\n' | cleanup_item 1 trash > "$testroot/trash.log"
  local -a trashed=("$ACCOUNT_HOME"/.Trash/Example.storage-inspector.*(N))
  [[ ! -e $p && ${#trashed} == 1 && -d $trashed[1] ]] || (( failures++ ))
  WORK=$saved_work; REPORT_DIR=$saved_report
  ITEMS=(); SIZES=(); COMPLETE=(); IDENTITIES=()
  ACCOUNT_HOME=$saved_home
  /bin/rm -rf -- "$testroot"
  say "Guard/deletion fixture tests: $failures failures"
  (( failures == 0 ))
}

main() {
  [[ $(/usr/bin/uname -s) == Darwin ]] || { say 'This script requires macOS.'; return 1; }
  (( EUID != 0 )) || { say 'Run as your normal user, without sudo.'; return 1; }
  local out="$BASE/Reports" arg id mode
  while (( $# )); do
    case $1 in
      --scan-only) SCAN_ONLY=1 ;;
      --output) shift; (( $# )) || return 2; out=${1:A} ;;
      --previous) shift; (( $# )) || return 2; PREVIOUS=${1:A} ;;
      --timeout) shift; (( $# )) || return 2; [[ $1 == <-> ]] && (( $1 >= 1 && $1 <= 600 )) || return 2; LIMIT=$1 ;;
      --self-test) self_test; return $? ;;
      --help) say 'Usage: zsh "Mac Storage Inspector.command" [--scan-only] [--output DIRECTORY] [--previous REPORT_DIRECTORY] [--timeout SECONDS] [--self-test]'; return 0 ;;
      *) say "Unknown option: $1"; return 2 ;;
    esac
    shift
  done
  [[ -d $ACCOUNT_HOME && $ACCOUNT_HOME != / ]] || return 1
  [[ $out != *$'\n'* && $out != *$'\t'* ]] || return 2
  /bin/mkdir -p "$out" || return 1
  REPORT_DIR=$(/usr/bin/mktemp -d "$out/scan-$(/bin/date +%Y%m%d-%H%M%S).XXXXXX") || return 1
  WORK=$(/usr/bin/mktemp -d /private/tmp/mac-storage.XXXXXXXX) || return 1
  say 'Mac Storage Inspector: scan first; nothing is deleted automatically.'
  say "Reports: $REPORT_DIR"
  say 'Common locations only. Unreadable locations and timeouts are explicitly reported.'
  {
    /bin/df -h / "$ACCOUNT_HOME"
    /usr/sbin/diskutil info /
    /usr/bin/tmutil listlocalsnapshots /
    /usr/sbin/diskutil apfs listSnapshots /System/Volumes/Data
    /usr/sbin/sysctl vm.swapusage
  } > "$REPORT_DIR/disk-and-snapshots.txt" 2>&1
  # Disjoint scopes where possible. Detailed rows and aggregate rows can still overlap.
  add_scope "$ACCOUNT_HOME/Library/Caches" 1
  add_scope "$ACCOUNT_HOME/Library/Logs" 1
  add_scope "$ACCOUNT_HOME/Library/Developer/Xcode" 2
  add_scope "$ACCOUNT_HOME/Library/Developer/CoreSimulator" 2
  add_scope "$ACCOUNT_HOME/Library/Application Support" 2
  add_scope "$ACCOUNT_HOME/Library/Containers" 1
  add_scope "$ACCOUNT_HOME/Library/Group Containers" 1
  add_scope "$ACCOUNT_HOME/Library/Mail" 1
  add_scope "$ACCOUNT_HOME/Library/Messages" 1
  add_scope "$ACCOUNT_HOME/Library/CloudStorage" 1
  add_scope "$ACCOUNT_HOME/Library/Mobile Documents" 1
  add_scope "$ACCOUNT_HOME/.cache" 1
  add_scope "$ACCOUNT_HOME/.cache/huggingface/hub" 1
  add_scope "$ACCOUNT_HOME/.npm" 1
  add_scope "$ACCOUNT_HOME/.codex" 1
  add_scope "$ACCOUNT_HOME/.ollama" 2
  add_scope "$ACCOUNT_HOME/.lmstudio" 2
  add_scope "$ACCOUNT_HOME/.Trash" 1
  add_scope /Library 2
  add_scope /System/Library/AssetsV2 1
  add_scope /private/var 1
  add_scope /System/Volumes/VM 1
  write_report
  show_largest
  say "Full explanations: $REPORT_DIR/report.txt"
  if [[ -s $REPORT_DIR/scan-errors.txt ]]; then
    say 'Some results are PARTIAL. See scan-errors.txt; permissions are not bypassed.'
    say 'For broader coverage, allow Terminal Full Disk Access in System Settings > Privacy & Security, reopen Terminal, then rerun. Some system files can remain protected.'
  fi
  (( SCAN_ONLY )) && return 0
  [[ -t 0 ]] || { say 'Noninteractive input: cleanup disabled. Run directly in Terminal for the menu.'; return 0; }
  while true; do
    say ''; say 'Enter an item number to inspect; L = largest, S = simulators, R = full report, Q = quit.'
    read -r 'arg?> ' || return 0
    case ${(U)arg} in
      Q|'') return 0 ;;
      L) show_largest ;;
      R) /usr/bin/less "$REPORT_DIR/report.txt" ;;
      S) simulator_menu ;;
      *)
        [[ $arg == <-> && ${#arg} -le 6 ]] || { say 'Use an item number or menu letter.'; continue; }
        id=$((10#$arg))
        (( id >= 1 && id <= ${#ITEMS} )) || continue
        inspect_item "$id"
        say 'I = list immediate contents, T = move to Trash, D = permanently delete, Enter = back.'
        read -r 'mode?> ' || return 0
        case ${(U)mode} in
          I) /bin/ls -lah -- "$ITEMS[$id]" ;;
          T) cleanup_item "$id" trash ;;
          D) cleanup_item "$id" delete ;;
        esac ;;
    esac
  done
}

main "$@"
