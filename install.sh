#!/usr/bin/env bash
# =============================================================================
#  arch-ntfs-fix  -  make Arch mount NTFS external disks the way other distros do
#  SPDX-License-Identifier: MIT
#
#  THE PROBLEM
#    Arch's udisks2 tries the kernel's "ntfs3" driver first. ntfs3 REFUSES to
#    mount an NTFS volume that is marked dirty (Windows Fast Startup, or an
#    unplug during a write). You get:
#      Error mounting /dev/sdb1 ... wrong fs type, bad option, bad superblock
#    while other distros mount the very same disk happily.
#
#  WHY THEY WORK
#    Those distros end up using "ntfs-3g" (the FUSE driver), which is more
#    forgiving. Nothing is wrong with your disk and nothing is wrong with your
#    kernel. It is only a different CHOICE of driver.
#
#  THE FIX
#    One config file that tells udisks2 to prefer ntfs-3g:
#        /etc/udisks2/mount_options.conf   ->   [defaults] ntfs_drivers=ntfs
#
#  SAFETY PROMISES (this script keeps all of them)
#    * It never writes to, formats, or deletes anything on your disks.
#    * It never runs "rm -rf". The only file it ever removes is the one config
#      file it installs (and only with --uninstall).
#    * It never downloads anything except through pacman's signed repositories.
#    * It never pipes a download into a shell (no curl | bash, ever).
#    * It asks before every change and can be told to do nothing (--dry-run).
#    * If anything fails, it prints the exact commands to do it by hand.
# =============================================================================

set -euo pipefail

REPO_URL="https://github.com/eprahemi/arch-ntfs-fix"   # update after publishing
CONFIG_PATH="/etc/udisks2/mount_options.conf"
# Overridable only so the test suite can pretend to be another distro.
OS_RELEASE_FILE="${OS_RELEASE_FILE:-/etc/os-release}"

# ---------------------------------------------------------------- output ----
if [[ -t 1 ]]; then
  C_R=$'\033[1;31m'; C_G=$'\033[1;32m'; C_Y=$'\033[1;33m'
  C_B=$'\033[1;34m'; C_D=$'\033[2m';    C_0=$'\033[0m'
else
  C_R=''; C_G=''; C_Y=''; C_B=''; C_D=''; C_0=''
fi

warn() { spinner_pause; printf '%s  !!%s %s\n' "$C_Y" "$C_0" "$*" >&2; }
say()  { spinner_pause; printf '     %s%s%s\n' "$C_D" "$*" "$C_0"; }
hr()   { printf '%s\n' "------------------------------------------------------------"; }

# ------------------------------------------------------------ pretty bits ---
# Everything below is decoration - plain bash and ANSI escapes, so it works on
# a bare Arch with nothing installed. If stdout is not a terminal (a log file,
# a pipe, CI) every effect switches itself off and the plain lines still work.
PLAIN=0
ANIM=1
[[ -t 1 ]] || ANIM=0
if [[ $PLAIN == 1 ]]; then ANIM=0; fi
SPIN_PID=""
STEP_LABEL=""

# ---------------------------------------------------------------- the pace ---
# When everything is already installed this script finishes in a blink - which
# makes it look like nothing happened. So on a real terminal every step keeps
# its spinner up for about a second before the tick appears, and the five or
# six steps of the install land the run in the 5-10 second window. Two guards
# keep this honest: nothing is added once the run is already 9 seconds old
# (real work is never padded past the window), and in a pipe, a log, --plain
# or the test suite (ANIM is off there) it costs no time at all.
RUN_START=$SECONDS
step_pace() {
  [[ $ANIM == 1 ]] || return 0
  (( SECONDS - RUN_START < 9 )) || return 0
  sleep "1.$(( RANDOM % 4 ))"     # 1.0 - 1.3 seconds
  return 0
}

# The spinner writes straight to the terminal, because some steps run inside
# $( ) where stdout is a pipe - the animation must never end up in the answer
# that gets printed on the tidy line.
TTY=""
if [[ $ANIM == 1 ]]; then
  if { printf '' >/dev/tty; } 2>/dev/null; then TTY=/dev/tty
  else ANIM=0; fi
fi

cleanup() {
  if [[ -n ${SPIN_PID:-} ]]; then
    kill "$SPIN_PID" 2>/dev/null || true
    SPIN_PID=""
  fi
  return 0
}
trap cleanup EXIT

# A step line that spins while the real work runs.
step_begin() {
  STEP_LABEL=$1
  [[ $ANIM == 1 ]] || return 0
  (
    local i=0 frames=(⠋ ⠙ ⠹ ⠸ ⠼ ⠴ ⠦ ⠧ ⠇ ⠏)
    while :; do
      printf '\r  %s%s%s %s' "$C_D" "${frames[$i]}" "$C_0" "$STEP_LABEL" >"$TTY"
      i=$(( (i + 1) % ${#frames[@]} ))
      sleep 0.06
    done
  ) &
  SPIN_PID=$!
}

# One tidy line: a tick, a label, the answer.
line_ok()   { printf '  %s✓%s %-33s %s\n' "$C_G" "$C_0" "$1" "$2"; }
line_warn() { printf '  %s!%s %-33s %s\n' "$C_Y" "$C_0" "$1" "$2"; }

# Stop the spinner and wipe its line. Called before anything the user should
# actually READ (a warning, a password prompt, an explanation), so that a
# spinning line can never type over it.
spinner_pause() {
  if [[ -n ${SPIN_PID:-} ]]; then
    kill "$SPIN_PID" 2>/dev/null || true
    wait "$SPIN_PID" 2>/dev/null || true
    SPIN_PID=""
    if [[ $ANIM == 1 ]]; then printf '\r\033[K' >"$TTY"; fi
  fi
  return 0
}

# Finish that step: let the spinner turn for a moment, then print the line.
step_done() {
  local result=$1 kind=${2:-ok}
  step_pace
  spinner_pause
  if [[ $kind == warn ]]; then line_warn "$STEP_LABEL" "$result"
  else line_ok "$STEP_LABEL" "$result"; fi
}

BOOLINE="$(printf '%s' '──────────────────────────────────────────────────────────')"

# A boxed heading. Plain text only - colour escapes would break the padding.
banner() {
  local title=$1 sub=${2:-}
  printf '\n  %s┌%s┐%s\n' "$C_D" "$BOOLINE" "$C_0"
  printf '  %s│%s %s%-56s%s %s│%s\n' "$C_D" "$C_0" "$C_B" "$title" "$C_0" "$C_D" "$C_0"
  if [[ -n $sub ]]; then
    printf '  %s│%s %-56s %s│%s\n' "$C_D" "$C_0" "$sub" "$C_D" "$C_0"
  fi
  printf '  %s└%s┘%s\n' "$C_D" "$BOOLINE" "$C_0"
}

# Print one character N times. Deliberately not `seq`: no dependency, no
# unquoted expansion, works on the most minimal Arch install.
repeat_char() {
  local ch=$1 n=$2
  while (( n-- > 0 )); do printf '%s' "$ch"; done
}

# A titled box for a side-note: something worth reading that is NOT a problem
# (a backup being kept, a choice that was made for you). Wider than the widest
# line, never narrower than the heading box above so the page stays aligned,
# and it always goes to stderr - these notes happen inside $( ) where stdout is
# the answer that gets printed on the tidy line. In a pipe, a log or --plain it
# collapses to one `!!` line instead, so logs stay clean and greppable.
note() {
  local title=$1; shift
  spinner_pause
  if [[ $ANIM != 1 ]]; then
    printf '  !! %s: %s\n' "$title" "$*" >&2
    return 0
  fi
  local w=$(( ${#title} + 1 )) line
  for line in "$@"; do
    (( ${#line} > w )) && w=${#line}
  done
  (( w < 54 )) && w=54
  local inner=$(( w + 2 ))
  local fill; fill=$(repeat_char '─' "$(( w - ${#title} - 1 ))")
  {
    printf '\n  %s┌─ %s%s%s %s┐%s\n' "$C_D" "$C_B" "$title" "$C_D" "$fill" "$C_0"
    for line in "$@"; do
      printf '  %s│%s %-*s %s│%s\n' "$C_D" "$C_0" "$w" "$line" "$C_D" "$C_0"
    done
    printf '  %s└%s┘%s\n\n' "$C_D" "$(repeat_char '─' "$inner")" "$C_0"
  } >&2
}

# A bar that fills up. Used once, at the moment the disk comes to life.
progress_bar() {
  local label=$1 i width=28 filled empty
  if [[ $ANIM != 1 ]]; then printf '  %s ... done\n' "$label"; return 0; fi
  for (( i = 0; i <= width; i++ )); do
    filled=""; empty=""
    (( i > 0 )) && filled=$(repeat_char '█' "$i")
    (( width - i > 0 )) && empty=$(repeat_char '░' "$(( width - i ))")
    printf '\r  %s  %s%s%s%s%s%s %3d%%' "$label" \
      "$C_G" "$filled" "$C_0" "$C_D" "$empty" "$C_0" \
      $(( i * 100 / width ))
    sleep 0.014
  done
  printf '\r\033[K'
}

# The disk's own name, drawn in big letters. A tiny five-row font, hand-drawn.
# Nothing to install and nothing to download: just the block character U+2588.
declare -A FONT=(
  [A]=" ██  /█  █/████/█  █/█  █"
  [B]="███ /█  █/███ /█  █/███ "
  [C]="████/█   /█   /█   /████"
  [D]="███ /█  █/█  █/█  █/███ "
  [E]="████/█   /███ /█   /████"
  [F]="████/█   /███ /█   /█   "
  [G]="████/█   /█ ██/█  █/████"
  [H]="█  █/█  █/████/█  █/█  █"
  [I]="███/ █ / █ / █ /███"
  [J]="  ██/   █/   █/█  █/████"
  [K]="█  █/█ █ /██  /█ █ /█  █"
  [L]="█   /█   /█   /█   /████"
  [M]="█   █/██ ██/█ █ █/█   █/█   █"
  [N]="█   █/██  █/█ █ █/█  ██/█   █"
  [O]="████/█  █/█  █/█  █/████"
  [P]="███ /█  █/███ /█   /█   "
  [Q]="████/█  █/█  █/████/   █"
  [R]="███ /█  █/███ /█ █ /█  █"
  [S]="████/█   /████/   █/████"
  [T]="████/  █ /  █ /  █ /  █ "
  [U]="█  █/█  █/█  █/█  █/████"
  [V]="█  █/█  █/█  █/ ██ / ██ "
  [W]="█   █/█   █/█ █ █/██ ██/█   █"
  [X]="█  █/ ██ / ██ / ██ /█  █"
  [Y]="█  █/ ██ / ██ /  █ /  █ "
  [Z]="████/  █ / █  /█   /████"
  [0]="████/█  █/█  █/█  █/████"
  [1]="  █ / ██ /  █ /  █ /████"
  [2]="████/   █/████/█   /████"
  [3]="████/   █/████/   █/████"
  [4]="█  █/█  █/████/   █/   █"
  [5]="████/█   /████/   █/████"
  [6]="████/█   /████/█  █/████"
  [7]="████/   █/  █ / █  /█   "
  [8]="████/█  █/████/█  █/████"
  [9]="████/█  █/████/   █/████"
  [" "]="  /  /  /  /  "
  ["-"]="    /    /████/    /    "
  ["."]="  /  /  /  /██"
  ["_"]="    /    /    /    /████"
  ["?"]="████/   █/ ██ /    / ██ "
)

big_text() {
  local text=${1^^} rows r0 r1 r2 r3 r4 i ch r
  local -a big=("" "" "" "" "")
  for (( i = 0; i < ${#text}; i++ )); do
    ch=${text:i:1}
    rows=${FONT[$ch]:-${FONT[?]}}
    IFS='/' read -r r0 r1 r2 r3 r4 <<< "$rows"
    big[0]+="$r0 "; big[1]+="$r1 "; big[2]+="$r2 "
    big[3]+="$r3 "; big[4]+="$r4 "
  done
  for r in "${big[@]}"; do
    printf '      %s\n' "$r"
  done
}

# Not every disk name can be drawn in big letters. The little font above only
# knows A-Z, 0-9 and a few marks, and block letters need room. So:
#   * a short, font-safe name  -> big letters
#   * any other name           -> a clean box (fits any language, any symbol)
#   * no name at all           -> READY
font_safe() {
  local text=${1^^} i ch
  [[ -n $text && ${#text} -le 12 ]] || return 1
  for (( i = 0; i < ${#text}; i++ )); do
    ch=${text:i:1}
    case $ch in
      [A-Z0-9]|' '|'-'|'.'|'_') ;;   # keep this list in step with FONT above
      *) return 1 ;;
    esac
  done
  return 0
}

# A name the font cannot draw still deserves to look deliberate. One clean box,
# width measured in real display columns (wc -L counts wide CJK runes as two),
# so the right edge lines up no matter the language.
box_text() {
  local text=$1 w inner bar
  w=$(printf '%s' "$text" | wc -L 2>/dev/null || true)
  [[ $w =~ ^[0-9]+$ ]] || w=${#text}
  (( w < 1 )) && w=1
  inner=$(( w + 2 ))
  bar=$(repeat_char '─' "$inner")
  printf '\n'
  printf '      %s╭%s╮%s\n' "$C_B" "$bar" "$C_0"
  printf '      %s│%s %s %s│%s\n' "$C_B" "$C_0" "$text" "$C_B" "$C_0"
  printf '      %s╰%s╯%s\n' "$C_B" "$bar" "$C_0"
}

# Pick the right way to show the disk's own name.
reveal_name() {
  local label=$1
  if [[ -z $label ]]; then
    printf '\n'; big_text "READY"
  elif font_safe "$label"; then
    printf '\n'; big_text "$label"
  else
    box_text "$label"
  fi
}

# We never name a specific file manager. Every desktop has its own, plenty of
# programs register themselves as the handler for folders, and the reader
# knows which one they use - so the honest words are simply "your file manager".
# This keeps the tool the same on every Arch-based system.
die() {
  local code=$1; shift
  spinner_pause
  printf '\n%s  that did not work:%s %s\n' "$C_R" "$C_0" "$*" >&2
  manual_instructions
  exit "$code"
}

# A soft ending: nothing is broken and nothing was changed, so there is no
# reason to dump the whole "do it by hand" list at the reader.
soft_stop() {
  local code=$1; shift
  spinner_pause
  printf '\n%s  %s%s\n\n' "$C_Y" "$*" "$C_0" >&2
  exit "$code"
}

have()     { command -v "$1" >/dev/null 2>&1; }
have_file(){ [[ -e "$1" ]]; }

confirm() {   # confirm "question" -> returns 0 for yes
  local prompt=$1 reply
  [[ ${ASSUME_YES:-0} == 1 ]] && return 0
  if [[ ! -t 0 ]]; then
    warn "No terminal to ask. Re-run with --yes, or follow the manual steps below."
    return 1
  fi
  spinner_pause
  read -rp "     $prompt [y/N] " reply
  [[ $reply =~ ^[Yy]([Ee][Ss])?$ ]]
}

# ----------------------------------------------------- manual instructions ---
manual_instructions() {
  cat >&2 <<'EOF'

  --------------------------------------------------------------------------
   IF YOU WOULD RATHER NOT RUN A SCRIPT - DO IT BY HAND

   (the script just did all of this for you - this list is here only so you
    can see every step and repeat it yourself if you ever want to)
  --------------------------------------------------------------------------
   1) install anything that is missing:
        sudo pacman -S --needed ntfs-3g udisks2

   2) write the config file. The [defaults] line is REQUIRED - without it
      udisks2 quietly throws the whole file away:
        sudo tee /etc/udisks2/mount_options.conf >/dev/null <<'CONF'
        [defaults]
        ntfs_drivers=ntfs
        CONF

   3) make udisks2 read it:
        sudo systemctl restart udisks2

   4) check it was accepted (no output here is the good answer):
        journalctl -u udisks2 --since '-1 min' | grep -i 'mount options'

   5) mount your disk:
        ./install.sh --list          # see the disk numbers
        udisksctl mount -b /dev/sdX1

   UNDO:
        sudo rm -f /etc/udisks2/mount_options.conf
        sudo systemctl restart udisks2
   (or just run:  ./install.sh --uninstall          keeps a .bak copy
                  ./install.sh --uninstall --purge  keeps nothing at all)
  --------------------------------------------------------------------------
EOF
}

# Read a filesystem's name back. Reading a raw block device needs root just as
# much as writing one does: the device belongs to root:disk, and a normal user
# is not allowed to open it ("Permission denied"). So this asks the same tool,
# with the same sudo, that did the write.
# If sudo cannot answer (no password cached yet, no terminal), fall back to the
# name the kernel already knows - lsblk reads that from udev, no root needed.
# Two witnesses, so a good rename is never reported as a failure.
label_now() {
  local d=$1 t=$2 v=""
  v=$(sudo "$t" "$d" 2>/dev/null | tail -1) || v=""
  if [[ -z $v ]]; then
    v=$(lsblk -no LABEL "$d" 2>/dev/null | head -1) || v=""
  fi
  printf '%s' "$v"
}

# The by-hand list for a rename. The failure path must still teach, and this
# has nothing to do with the udisks2 config, so it gets its own short list.
manual_label() {
  cat >&2 <<EOF

  --------------------------------------------------------------------------
   IF YOU WOULD RATHER RENAME IT BY HAND

     lsblk -o NAME,SIZE,TRAN,LABEL,TYPE     find it (TRAN=usb, TYPE=part)
     udisksctl unmount -b ${NEWDEV:-/dev/sdX1}
     sudo ${NEWTOOL:-ntfslabel} ${NEWDEV:-/dev/sdX1}             read the name it has now
     sudo ${NEWTOOL:-ntfslabel} ${NEWDEV:-/dev/sdX1} NEWNAME     write the new name
     udisksctl mount -b ${NEWDEV:-/dev/sdX1}

   Two rules, and they matter:
     * the volume MUST be unmounted first (a mounted volume is opened
       exclusively, and the tool will refuse - that is a safety feature)
     * never add --force. If the tool refuses, it has a real reason.

   Other filesystems use other tools: exfatlabel (exFAT), fatlabel (FAT),
   e2label (ext2/3/4), ntfslabel (NTFS).
  --------------------------------------------------------------------------
EOF
}

die_rename() {
  local code=$1; shift
  spinner_pause
  printf '\n%s  that did not work:%s %s\n' "$C_R" "$C_0" "$*" >&2
  manual_label
  exit "$code"
}

# If we closed the disk, we open it again - even when we are leaving because of
# a failure. A tool that leaves a stranger's disk shut is worse than a tool that
# fails. Reads $dev/$was_mounted from rename_disk (bash scoping reaches them).
put_back() {
  local d=${dev:-${NEWDEV:-}}
  [[ -n $d && ${was_mounted:-0} == 1 ]] || return 0
  if udisksctl mount -b "$d" >/dev/null 2>&1; then
    say "I opened $d again - it was open when you started."
  else
    say "open it again yourself with:   udisksctl mount -b $d"
  fi
}

# The one refusal that has a real, calm fix: a volume waiting for a Windows
# check. Windows sets that flag when it is not shut down cleanly (Fast Startup
# leaves the disk half-open) or when the disk was unplugged while it was writing.
# Linux can clear it as well - verified on a THROWAWAY image: plain `ntfsfix`
# SETS this flag, `ntfsfix -d` clears it, and ntfslabel then works. But clearing
# it is a REPAIR, not part of renaming, so it never happens unless the person
# asked for it (the prompt below, or --clear-check-flag).
explain_check_flag() {
  printf '\n'
  say "this volume is waiting for a WINDOWS CHECK - the NTFS flag inside it says"
  say "'check me first'. Windows Fast Startup sets it (Windows never really shuts"
  say "the disk down), and so does unplugging the disk while it was writing."
  say "renaming writes into the disk's own bookkeeping, so the tool refuses while"
  say "that flag is up. That is a safety feature, not a fault - nothing is broken."
  printf '\n'
  say "TWO WAYS TO CLEAR IT - either one works"
  say "  1) with Windows:  plug the disk in and let it check the disk"
  say "         chkdsk X: /f /x     then eject it safely, shut Windows down cleanly"
  say "     Windows can also replay changes it had not written yet - Linux cannot."
  say "  2) without Windows:  Linux can clear the flag itself"
  say "         sudo ntfsfix -n ${dev:-/dev/sdX1}     look first, changes nothing"
  say "         sudo ntfsfix -d ${dev:-/dev/sdX1}     then clear it"
  say "     ntfsfix comes with ntfsprogs - you already have it if you can rename."
  printf '\n'
}

# Clear that flag ourselves - but only when asked. --yes answers "rename it?",
# it does NOT answer "repair the disk?".
clear_check_flag() {
  local reply="" out2=""
  explain_check_flag
  if ! have ntfsfix; then
    check_flag_die "ntfsfix is not installed here, so I cannot do it for you."
  fi
  if [[ ${CLEAR_FLAG:-0} != 1 ]]; then
    if [[ ${ASSUME_YES:-0} == 1 ]]; then
      check_flag_die "--yes answered the renaming question, not this one: clearing
       the check flag is a repair, and a repair needs a yes of its own. Add
       --clear-check-flag if you want me to do that for you."
    fi
    printf '     clear that flag on %s now? [y/N] ' "$dev"
    read -r reply || reply=""
    if [[ ! $reply =~ ^[Yy] ]]; then
      check_flag_die "nothing was changed."
    fi
  fi
  step_begin "clearing the check flag"
  if out2=$(sudo ntfsfix -d "$dev" 2>&1); then
    step_done "the flag is cleared"
    say "$out2"
  else
    step_done "ntfsfix could not fix it" warn
    say "$out2"
    put_back
    die_rename 1 "Linux could not fix this volume, so it really needs a Windows check:
       plug it into a Windows machine and let chkdsk finish there.
       Nothing was changed, and the name it has now is still there."
  fi
}

# Every "I cannot go on" path for the check flag ends here: put the disk back,
# then stop - with the same words every time, so nothing is left half-said.
check_flag_die() {   # $1 = an extra sentence to print first (may be empty)
  if [[ -n ${1:-} ]]; then say "$1"; fi
  put_back
  die_rename 1 "this volume is waiting for a WINDOWS CHECK, so $NEWTOOL will not
       name it - the two ways to clear it are above.
       Nothing was changed, and the name it has now is still there.
       Do NOT add --force: it writes anyway, on a disk the system doubts."
}

die_waiting_for_check() {
  explain_check_flag
  check_flag_die
}

# ------------------------------------------------------------- checks --------
# Arch-based systems do NOT all announce themselves properly. CachyOS, for
# example, shipped /etc/os-release with no ID_LIKE for a long time (their own
# issue #177 asked for it). So detection is layered:
#   1. ID=arch                       -> Arch itself
#   2. ID_LIKE contains the word arch -> honest relatives
#   3. a known family ID              -> relatives with unhelpful metadata
#   4. pacman exists                  -> assume Arch-based, but SAY we are guessing
#   5. none of the above              -> refuse, and hand out the right commands
ARCH_FAMILY_IDS="arch arch32 archarm garuda cachyos cachyos-rolling manjaro
                 endeavouros artix arcolinux steamos archlabs archman
                 blendsos redcoreos"

os_field() {   # os_field ID  -> prints that field from /etc/os-release
  local v=""
  # shellcheck disable=SC1090
  . "$OS_RELEASE_FILE" 2>/dev/null || true
  v=${!1:-}
  printf '%s' "$v"
}

# Print what the visitor should run instead, for a non-Arch system.
foreign_hint() {
  cat >&2 <<'EOF'

  --------------------------------------------------------------------------
   THIS SCRIPT IS FOR ARCH-BASED SYSTEMS (it installs packages with pacman)
  --------------------------------------------------------------------------
   Good news: the fix has nothing to do with Arch. Any distro that uses udisks2
   can be fixed the same way - only the package line is different:

     dnf     :  sudo dnf install ntfs-3g fuse3
     apt     :  sudo apt install ntfs-3g udisks2
     zypper  :  sudo zypper install ntfs-3g
     apk     :  sudo apk add ntfs-3g

   ...then the same two steps, which work everywhere:

     sudo tee /etc/udisks2/mount_options.conf >/dev/null <<'CONF'
     [defaults]
     ntfs_drivers=ntfs
     CONF
     sudo systemctl restart udisks2

   (On most distros you do not even need ntfs-3g: their udisks2 already picks a
    working driver. The config file is the part that does the job.)
  --------------------------------------------------------------------------
EOF
}

# Returns a short answer on stdout ("Arch Linux") and keeps the explaining on
# stderr, so the caller can put it on one tidy step line.
check_os() {
  if [[ ${SKIP_OS_CHECK:-0} == 1 ]]; then
    warn "ok, skipping the system check - you asked for that"
    printf 'skipped (you asked)'
    return 0
  fi

  local id idlike name
  id=$(os_field ID); idlike=$(os_field ID_LIKE); name=$(os_field PRETTY_NAME)
  [[ -z $name ]] && name="${id:-unknown}"

  if ! have pacman; then
    warn "there is no pacman here, so this isn't an Arch-based system (ID=$id)"
    foreign_hint
    die 2 "I won't touch a system I don't understand."
  fi

  if [[ $id == arch ]]; then
    printf '%s' "$name"
  elif [[ " $idlike " == *" arch "* ]] || grep -qw -- "${id:-none}" <<< "$ARCH_FAMILY_IDS"; then
    printf 'Arch-based (%s)' "$name"
  else
    warn "I don't know this one by name (ID=$id, ID_LIKE=$idlike)"
    warn "but pacman is here, so I'll treat it as Arch-based."
    warn "if that's wrong: press Ctrl+C now. Nothing has changed yet."
    printf 'pacman is here - assuming Arch-based'
  fi
}

check_not_root() {
  if [[ ${EUID:-$(id -u)} -eq 0 ]]; then
    warn "you're running this as root. Please run it as your normal user -"
    warn "it will ask for sudo itself on the few steps that need it."
  fi
}

check_sudo() {
  if [[ ${DRY_RUN:-0} == 1 ]]; then
    # A rehearsal must be free: --dry-run must never ask for a password,
    # so a newcomer can read the whole plan before trusting it with sudo.
    printf 'dry run - no password asked'
    return 0
  fi
  have sudo || die 3 "sudo is not installed.
       Install it:   sudo pacman -S sudo
       Then re-run this script."
  spinner_pause
  if ! sudo -v; then
    if [[ ! -t 0 ]]; then
      die 3 "sudo needs your password, but there is no terminal here to type it in.
       Run this script from an ordinary terminal window, like this:
           cd ~/Projects/arch-ntfs-fix && ./install.sh"
    fi
    die 3 "sudo did not accept your password.
       (Too many wrong tries can lock sudo for a few minutes - wait and retry.)"
  fi
  printf 'ready'
}

check_network() {
  local host
  if [[ ${SKIP_NET_CHECK:-0} == 1 ]]; then
    warn "skipping the internet check"
    printf 'skipped (you asked)'
    return 0
  fi
  for host in archlinux.org mirror.rackspace.com geo.mirror.pkgbuild.com; do
    if timeout 6 getent hosts "$host" >/dev/null 2>&1; then
      if timeout 8 curl -fsSI --max-time 6 "https://$host" >/dev/null 2>&1; then
        printf 'fine (%s)' "$host"
        return 0
      fi
    fi
  done
  die 4 "No working internet right now. That is only needed to install missing
       packages (ntfs-3g, udisks2) - everything else is local.
         * get online:   nmcli dev wifi list
         * already have both?  ./install.sh --skip-net-check"
}

# ------------------------------------------------------------- packages ------
missing_packages() {
  local -a miss=()
  have_file /usr/bin/mount.ntfs || miss+=(ntfs-3g)   # provides /usr/bin/mount.ntfs
  have udisksctl                || miss+=(udisks2)    # mounts disks for the file manager
  if [[ ${#miss[@]} -gt 0 ]]; then printf '%s\n' "${miss[@]}"; fi
}

install_packages() {
  local -a miss=()
  mapfile -t miss < <(missing_packages)

  if [[ ${#miss[@]} -eq 0 ]]; then
    printf 'ntfs-3g and udisks2 already here'
    return 0
  fi

  say "nothing else is needed: ntfs3 is built into the kernel, not a package" >&2

  # A rehearsal must never stop to ask anything, and never needs a password.
  if [[ ${DRY_RUN:-0} == 1 ]]; then
    say "[dry-run] would run: sudo pacman -S --needed ${miss[*]}" >&2
    printf 'dry run - would install: %s' "${miss[*]}"
    return 0
  fi

  if ! confirm "Install ${miss[*]} now?"; then
    die 5 "You said no to installing ${miss[*]}, so I'll stop here.
       The exact commands are printed above if you change your mind."
  fi

  if sudo pacman -S --needed "${miss[@]}" >&2; then
    printf 'installed: %s' "${miss[*]}"
  else
    die 5 "pacman could not install ${miss[*]}.
       Common causes: no internet, a mirror is down, or you said no to a
       import of a PGP key. pacman prints the reason - fix it and re-run."
  fi
}

# ------------------------------------------------------------- the fix -------
config_content() {
  cat <<'CONF'
# /etc/udisks2/mount_options.conf
#
# WHY THIS FILE EXISTS
#   udisks2 normally tries the kernel's ntfs3 driver first, and ntfs3 refuses
#   to mount an NTFS volume that is marked "dirty" (for example after Windows
#   Fast Startup, or unplugging the disk while a file was being written).
#   Pointing udisks2 at "ntfs" (the ntfs-3g FUSE driver) makes it mount those
#   disks read-write instead, which is what other distros do for you.
#
# IMPORTANT
#   The FIRST non-comment line must be a group header such as [defaults].
#   Without it udisks2 discards the whole file and only writes this to its log:
#       Error reading global mount options config file ...:
#       Key file does not start with a group
#
# DOCS
#   /etc/udisks2/mount_options.conf.example
#   https://storaged.org/udisks/docs/mount_options.html
#
# UNDO
#   sudo rm /etc/udisks2/mount_options.conf && sudo systemctl restart udisks2
#   (after fixing the volume with Windows "chkdsk X: /f /x" you may prefer
#    Arch's faster kernel driver and no longer need this file)

[defaults]
ntfs_drivers=ntfs
CONF
}

install_config() {
  if [[ ${DRY_RUN:-0} == 1 ]]; then
    say "[dry-run] would write $CONFIG_PATH :" >&2
    config_content | sed 's/^/       /' >&2
    say "[dry-run] would run: sudo systemctl restart udisks2" >&2
    printf 'dry run - nothing written'
    return 0
  fi

  # Written through a temp file so a crash can never leave a half-written
  # config behind (a half-written config = udisks2 ignores it).
  local tmp
  tmp=$(mktemp) || die 1 "could not create a temporary file"
  config_content > "$tmp"

  # Already exactly right? Then change NOTHING: no backup, no rewrite, and no
  # udisks2 restart. A restart is not free - every mounted disk briefly
  # disappears from udisks2's list while it comes back, and a disk that was
  # already open can then be reported as "could not be opened". A no-op run
  # must be a no-op.
  if have_file "$CONFIG_PATH" && cmp -s "$tmp" "$CONFIG_PATH"; then
    rm -f "$tmp"
    printf 'already in place - nothing to change'
    return 0
  fi

  if have_file "$CONFIG_PATH"; then
    note "keeping a backup" \
      "$CONFIG_PATH" \
      "is already there. I am keeping your old one at" \
      "$CONFIG_PATH.bak"
    sudo cp -a "$CONFIG_PATH" "$CONFIG_PATH.bak"
  fi

  sudo install -m 644 -o root -g root "$tmp" "$CONFIG_PATH"
  rm -f "$tmp"

  if ! sudo systemctl restart udisks2 >&2; then
    die 5 "udisks2 could not be restarted.
       Look at:  sudo journalctl -u udisks2 -n 30"
  fi

  # The single most useful check in this whole script.
  local complaints
  complaints=$(sudo journalctl -u udisks2 --since '-1 min' --no-pager 2>/dev/null \
               | grep -i 'mount options' || true)
  if [[ -n $complaints ]]; then
    printf '%s\n' "$complaints" >&2
    die 1 "udisks2 rejected the file the moment it read it (line above)."
  fi
  printf 'written, udisks2 restarted, log is clean'
}

uninstall_config() {
  if ! have_file "$CONFIG_PATH"; then
    line_ok "the fix" "is not installed - nothing to remove"
    return 0
  fi
  line_ok "removing" "$CONFIG_PATH"
  if [[ ${DRY_RUN:-0} == 1 ]]; then
    say "[dry-run] would run: sudo rm -f $CONFIG_PATH"
    say "[dry-run] would run: sudo systemctl restart udisks2"
    return 0
  fi

  warn "this deletes only this one file, and nothing else:"
  sudo sed -n '/^\[/,$p' "$CONFIG_PATH" | sed 's/^/       /'
  if [[ ${PURGE:-0} == 1 ]]; then
    say "you asked for --purge, so no copy will be kept"
  else
    say "a copy is saved first as $CONFIG_PATH.bak, so you can put it back"
  fi
  confirm "Delete $CONFIG_PATH and restart udisks2?" \
    || { say "cancelled - nothing was changed"; return 0; }

  # A copy is kept by default: one mv brings everything back. And if this
  # machine already had its OWN mount options, that copy is the only thing
  # standing between that person and losing them for good.
  local kept=""
  if [[ ${PURGE:-0} != 1 ]]; then
    if sudo cp -a "$CONFIG_PATH" "$CONFIG_PATH.bak" 2>/dev/null; then
      kept=$CONFIG_PATH.bak
    fi
  fi

  # A stale .bak from an earlier run must not survive --purge, or "purge"
  # would be a lie.
  local also_wiped=0
  if [[ ${PURGE:-0} == 1 && -e $CONFIG_PATH.bak ]]; then
    sudo rm -f "$CONFIG_PATH.bak" 2>/dev/null || true
    also_wiped=1
  fi

  sudo rm -f "$CONFIG_PATH"
  if sudo systemctl restart udisks2 >&2; then
    line_ok "udisks2" "restarted"
  else
    line_warn "udisks2" "could not restart - a reboot will finish the job"
  fi

  printf '\n'
  hr
  printf '  what happened\n'
  hr
  printf '  %-14s %s\n' "removed:" "$CONFIG_PATH"
  if [[ -n $kept ]]; then
    printf '  %-14s %s\n' "kept:" "$kept"
    printf '  %-14s %s\n' "note:" "udisks2 ignores that copy - it is only a spare"
    printf '\n'
    printf '  %-14s %s\n' "UNDO:" "sudo mv $kept $CONFIG_PATH"
    printf '  %-14s %s\n' "" "sudo systemctl restart udisks2"
  else
    printf '  %-14s %s\n' "kept:" "nothing kept (--purge)"
    if [[ $also_wiped == 1 ]]; then
      printf '  %-14s %s\n' "also:" "deleted an old .bak from an earlier run"
    fi
    printf '\n'
    printf '  %-14s %s\n' "want it back?" "./install.sh"
  fi
  printf '\n'
  if [[ ${PURGE:-0} == 1 ]]; then
    printf '  %-14s %s\n' "note:" "without --purge, a .bak copy would have been kept"
  else
    printf '  %-14s %s\n' "no leftovers?" "./install.sh --uninstall --purge"
  fi
  hr
}

# ------------------------------------------------------- disk detection ------
# Reads lsblk machine-readable output. No hardcoded /dev/sdX1 anywhere.
# NOTE -p is essential: without it lsblk prints "sdb1" and udisksctl
# (which needs a full device path) would reject it.
# One lsblk scan, shared by the install path and by --rename.
#   ntfs  -> every NTFS partition (the install path wants all of them)
#   label -> only REMOVABLE/USB disks, and only filesystems we can name
#   any   -> every partition with a filesystem (used for the swap check)
# lsblk reports TRAN and RM on the WHOLE DISK, never on the partition, so the
# parent is worked out from the name here (/dev/sdb1 -> /dev/sdb). Without that
# step a USB disk looks internal and every removable check fails silently.
lsblk_scan() {
  local want=$1
  lsblk -pPno NAME,FSTYPE,LABEL,SIZE,TRAN,RM,MOUNTPOINT,TYPE 2>/dev/null | awk -v want="$want" '
    function val(line, key,   m, pat) {
      # The key must sit at the START of the line or after a space, otherwise
      # TYPE="part" would happily match inside FSTYPE="ntfs" and every
      # partition would be read as its own filesystem type.
      pat = "(^| )" key "=\"[^\"]*\""
      if (!match(line, pat)) return ""
      m = substr(line, RSTART, RLENGTH)
      sub(/^ /, "", m)          # drop the joining space
      sub(/^[^=]*="/, "", m)    # drop KEY="
      sub(/"$/, "", m)          # drop the closing quote
      return m
    }
    function parent_of(dev,   n, a, i, base, out) {
      n = split(dev, a, "/")
      base = a[n]
      if (base ~ /^(nvme[0-9]+n[0-9]+|mmcblk[0-9]+)p[0-9]+$/)      sub(/p[0-9]+$/, "", base)
      else if (base ~ /^[a-z]+[0-9]+$/)                            sub(/[0-9]+$/, "", base)
      else return ""
      out = ""
      for (i = 1; i <= n; i++) out = out (i > 1 ? "/" : "") (i == n ? base : a[i])
      return out
    }
    {
      n++
      nm[n]=val($0,"NAME"); fs[n]=tolower(val($0,"FSTYPE")); lb[n]=val($0,"LABEL")
      sz[n]=val($0,"SIZE"); tr[n]=val($0,"TRAN"); rm[n]=val($0,"RM")
      mp[n]=val($0,"MOUNTPOINT"); ty[n]=val($0,"TYPE")
    }
    END {
      for (k = 1; k <= n; k++) {
        if (fs[k] == "") continue
        # The rename path is strict: only real partitions, and only removable
        # disks. The install path only skips rows lsblk itself called a whole
        # disk, so simplified/older output still works.
        if (want == "label") { if (ty[k] != "part") continue }
        else                 { if (ty[k] == "disk") continue }
        t = tr[k]; r = rm[k]
        p = parent_of(nm[k])
        if (p != "") for (j = 1; j <= n; j++)
          if (nm[j] == p) { if (t == "") t = tr[j]; if (r == "") r = rm[j] }
        removable = (t == "usb" || r == "1")
        if (want == "ntfs") {
          if (fs[k] ~ /^ntfs/) printf "%s|%s|%s|%s|%s|%s\n", nm[k], lb[k], sz[k], t, (removable?"yes":"no"), mp[k]
        } else if (want == "label") {
          if (removable && fs[k] ~ /^(ntfs3?|exfat|vfat|fat|msdos|ext[234])$/)
            printf "%s|%s|%s|%s|%s|%s\n", nm[k], fs[k], lb[k], sz[k], t, mp[k]
        } else {
          printf "%s|%s|%s|%s|%s|%s\n", nm[k], fs[k], lb[k], sz[k], t, mp[k]
        }
      }
    }'
}

list_ntfs_disks()   { lsblk_scan ntfs;  }
list_rename_disks() { lsblk_scan label; }

disk_field() {   # disk_field /dev/sdb1 1 -> label ; 2 -> size
  local want=$1 col=$2
  list_ntfs_disks | awk -F'|' -v w="$want" -v c="$col" '$1 == w { print $c; exit }'
}

show_disks() {
  local rows
  rows=$(list_ntfs_disks)

  if [[ -z $rows ]]; then
    say "I don't see any NTFS partitions."
    say "plug the disk in and run:  ./install.sh --list"
    say "(a Windows disk is only NTFS if it was formatted NTFS; exFAT needs"
    say " none of this - the exfat driver opens it without complaining.)"
    return 0
  fi

  local i=1
  printf '     %-3s %-14s %-9s %-6s %-5s %-6s %s\n' "#" "DEVICE" "SIZE" "TYPE" "USB?" "MOUNTED" "LABEL"
  while IFS='|' read -r name label size tran usb mp; do
    [[ -n $name ]] || continue
    printf '     %-3s %-14s %-9s %-6s %-5s %-6s %s\n' \
           "$i" "$name" "$size" "${tran:-?}" "$usb" "${mp:--}" "${label:-(no label)}"
    i=$((i + 1))
  done <<< "$rows"
  return 0
}

choose_disk() {
  # NOTE: everything except the final device name is printed to STDERR on
  # purpose. main() captures this function's stdout with $( ) to get the
  # device, and the table must still be visible to the user.
  local -a names=() rows
  rows=$(list_ntfs_disks)
  [[ -z $rows ]] && soft_stop 6 "there is no NTFS disk to test yet.

     Nothing is wrong, and the fix above is already installed - there is
     simply no disk plugged in. Check with:  lsblk -f
     Plug it in later and just run this script again."
  # (the fix stays installed either way; undo any time with --uninstall)
  while IFS='|' read -r name _label _size _tran _usb _mp; do
    [[ -n $name ]] || continue
    names+=("$name")
  done <<< "$rows"

  local total=${#names[@]} pick="" reply=""
  # The table only earns its place when there is a choice to make.
  if (( total > 1 )); then
    { printf '\n'; show_disks; printf '\n'; } >&2
  fi

  if [[ -n ${DISK_CHOICE:-} ]]; then
    if ! [[ $DISK_CHOICE =~ ^[0-9]+$ ]] || (( DISK_CHOICE < 1 || DISK_CHOICE > total )); then
      soft_stop 6 "--disk has to be a number between 1 and $total, nothing was done."
    fi
    pick=${names[$((DISK_CHOICE - 1))]}
  elif [[ $total -eq 1 ]]; then
    pick=${names[0]}
  elif [[ ! -t 0 ]]; then
    soft_stop 6 "there is more than one NTFS disk here and no terminal to ask
     which one you mean. Nothing was done - run it again like:
         ./install.sh --disk 1"
  else
    # NOT via say(): main() captures this function's stdout to get the device
    # name, and say() writes to stdout, so anything said here becomes part of
    # that name. That really happened once: the device became
    # "which disk should I test? ... /dev/sdb1" and udisksctl answered
    # "Error looking up object for device". A prompt is story, not an answer.
    printf '     %swhich disk should I test? (a number, or Enter for the first one):%s ' \
      "$C_B" "$C_0" >&2
    read -r reply || reply=""
    reply=${reply:-1}
    if ! [[ $reply =~ ^[0-9]+$ ]] || (( reply < 1 || reply > total )); then
      soft_stop 6 "\"$reply\" is not a number between 1 and $total - nothing was done."
    fi
    pick=${names[$((reply - 1))]}
  fi

  printf '%s\n' "$pick"
}

# ------------------------------------------------------ rename a disk ------
# A label is the name written INSIDE the filesystem: the one Windows, macOS
# and every file manager show, and the one udisks2 turns into the mount folder
# (/run/media/you/NAME). Only removable/USB disks are ever offered here, the
# volume is unmounted first, and only the NAME changes - no file is touched.
#
# The character limits below are not guesses; they were checked on throwaway
# images in /tmp, because e2label silently TRUNCATES instead of complaining:
#   ntfslabel  - ntfs-3g accepts up to 128, but Windows only shows the first 32
#   fatlabel   - refuses anything past 11
#   exfatlabel - refuses anything past 11
#   e2label    - accepts 16, then quietly chops the rest off

label_tool() {   # $1 = filesystem -> the tool that writes a label on it
  case ${1,,} in
    ntfs|ntfs3)     printf 'ntfslabel\n'  ;;
    exfat)          printf 'exfatlabel\n' ;;
    vfat|fat|msdos) printf 'fatlabel\n'   ;;
    ext2|ext3|ext4) printf 'e2label\n'    ;;
  esac
}

label_max() {    # the longest name the OTHER systems still show correctly
  case ${1,,} in
    ntfs|ntfs3)     printf '32\n' ;;
    exfat)          printf '11\n' ;;
    vfat|fat|msdos) printf '11\n' ;;
    ext2|ext3|ext4) printf '16\n' ;;
  esac
}

label_pkg() {    # which package brings that tool
  case $1 in
    ntfslabel)  printf 'ntfsprogs\n'  ;;
    exfatlabel) printf 'exfatprogs\n' ;;
    fatlabel)   printf 'dosfstools\n' ;;
    e2label)    printf 'e2fsprogs\n'  ;;
  esac
}

# The whole disk a partition lives on: /dev/sdb1 -> /dev/sdb, plus the two
# awkward families where the partition number is glued on with a 'p'
# (/dev/nvme0n1p1 -> /dev/nvme0n1, /dev/mmcblk0p1 -> /dev/mmcblk0).
disk_of() {
  local d=$1 base p
  base=$(basename "$d")
  if [[ $base =~ ^(nvme[0-9]+n[0-9]+|mmcblk[0-9]+)p[0-9]+$ ]]; then
    p=${BASH_REMATCH[1]}
  elif [[ $base =~ ^([a-z]+)[0-9]+$ ]]; then
    p=${BASH_REMATCH[1]}
  else
    printf '%s\n' "$d"; return 0
  fi
  printf '%s/%s\n' "$(dirname "$d")" "$p"
}

# Every device that runs THIS system: root, /boot, the ESP, /home, and swap.
protected_devices() {
  {
    findmnt -no SOURCE /          2>/dev/null
    findmnt -no SOURCE /boot      2>/dev/null
    findmnt -no SOURCE /boot/efi  2>/dev/null
    findmnt -no SOURCE /home      2>/dev/null
    lsblk_scan any | awk -F'|' '$6 == "[SWAP]" { print $1 }'
  } | grep '^/dev/' | sort -u
}

# Refuses a partition that runs the system - and also any OTHER partition on
# the same physical disk, so a boot or EFI partition can never be reached by
# accident. This is the guard that protects the internal disk.
disk_is_protected() {   # $1 = device ; 0 = hands off
  local dev=$1 disk p
  [[ -n $dev ]] || return 1
  disk=$(disk_of "$dev")
  while read -r p; do
    [[ -n $p ]] || continue
    [[ $p == "$dev" || $p == "$disk" ]] && return 0
    [[ $(disk_of "$p") == "$disk" ]] && return 0
  done < <(protected_devices)
  return 1
}

show_rename_disks() {
  local rows name fs label size _tran mp tool brand i=1
  rows=$(list_rename_disks)
  printf '     %-3s %-14s %-9s %-6s %-26s %s\n' \
         "#" "DEVICE" "SIZE" "TYPE" "MOUNTED" "NAME IT HAS NOW"
  while IFS='|' read -r name fs label size _tran mp; do
    [[ -n $name ]] || continue
    tool=$(label_tool "$fs")
    brand=""
    have "$tool" || brand="  (needs $(label_pkg "$tool"))"
    printf '     %-3s %-14s %-9s %-6s %-26s %s%s\n' \
           "$i" "$name" "$size" "$fs" "${mp:--}" "${label:-(no name)}" "$brand"
    i=$((i + 1))
  done <<< "$rows"
  return 0
}

# The whole mode. Story on stdout (it is called directly, not inside $( )),
# prompts read from stdin, so it also works when driven by a pipe.
rename_disk() {
  local rows dev fs label size _tran mp tool cap name reply i
  local was_mounted=0 target="" out="" got=""
  local -a devs=() fss=() labels=() sizes=() mps=()

  rows=$(list_rename_disks)
  if [[ -z $rows ]]; then
    soft_stop 6 "I cannot see a removable disk I could name.

     Plug the disk in and look with:   lsblk -o NAME,SIZE,TRAN,LABEL
     Only disks that say TRAN=usb (or that report themselves as removable)
     are offered here, and only if they already have a filesystem on them -
     there is nothing to name on a brand new, empty disk."
  fi
  while IFS='|' read -r dev fs label size _tran mp; do
    [[ -n $dev ]] || continue
    devs+=("$dev"); fss+=("$fs"); labels+=("$label"); sizes+=("$size"); mps+=("$mp")
  done <<< "$rows"
  local total=${#devs[@]}

  printf '\n'
  show_rename_disks
  printf '\n'
  if [[ $total -eq 1 ]]; then
    printf '     %s(that is the only removable disk here)%s\n' "$C_D" "$C_0"
  fi

  # ---- the new name (asked first, like a person would) ---------------------
  name=${NEWNAME:-}
  if [[ -z $name ]]; then
    say "the safe characters are  letters, digits, space, - . _"
    say "keep it short and plain: Windows, macOS and Linux all read those"
    printf '     what name do you want? '
    read -r name || name=""
  fi
  # trailing/leading spaces are a classic Windows headache - trim them off
  name="${name#"${name%%[![:space:]]*}"}"
  name="${name%"${name##*[![:space:]]}"}"

  if [[ -z $name ]]; then
    soft_stop 6 "no name was typed, so nothing was changed."
  fi
  case $name in
    .|..) soft_stop 6 "\"$name\" cannot be a disk name: it is what a folder is
     called for \"here\" and \"up one level\". Nothing was changed." ;;
    */*|*\\*)
      soft_stop 6 "a disk name cannot contain / or \\ - those characters mean
     folders. Nothing was changed." ;;
  esac
  if printf '%s' "$name" | LC_ALL=C grep -q '[[:cntrl:]]'; then
    soft_stop 6 "that name contains a control character (a tab, maybe). Nothing
     was changed - type it again by hand."
  fi

  # ---- which disk ----------------------------------------------------------
  if [[ -n ${DISK_CHOICE:-} ]]; then
    if ! [[ $DISK_CHOICE =~ ^[0-9]+$ ]] || (( DISK_CHOICE < 1 || DISK_CHOICE > total )); then
      soft_stop 6 "--disk has to be a number between 1 and $total, nothing was changed."
    fi
    i=$DISK_CHOICE
  elif [[ $total -eq 1 ]]; then
    i=1
  else
    printf '     %swhich disk should I rename? (a number, or Enter for the first one):%s ' "$C_B" "$C_0"
    read -r reply || reply=""
    reply=${reply:-1}
    if ! [[ $reply =~ ^[0-9]+$ ]] || (( reply < 1 || reply > total )); then
      soft_stop 6 "\"$reply\" is not a number between 1 and $total - nothing was changed."
    fi
    i=$reply
  fi

  dev=${devs[$((i - 1))]};   fs=${fss[$((i - 1))]}
  label=${labels[$((i - 1))]}; size=${sizes[$((i - 1))]}; mp=${mps[$((i - 1))]}
  tool=$(label_tool "$fs"); cap=$(label_max "$fs")
  NEWDEV=$dev; NEWTOOL=$tool

  # ---- the guards ----------------------------------------------------------
  if disk_is_protected "$dev"; then
    soft_stop 6 "$dev is on the disk this system runs from. This script only
     renames EXTERNAL disks - that is the rule that keeps your boot and your
     other operating system safe. Nothing was changed."
  fi
  if (( ${#name} > cap )); then
    if [[ ${fs,,} == ntfs || ${fs,,} == ntfs3 ]]; then
      soft_stop 6 "that name is ${#name} characters. Windows only shows the first
     $cap characters of an NTFS name, so I stop at $cap on purpose - a longer
     name would look broken once you plug it into Windows. Nothing was changed."
    else
      soft_stop 6 "a $fs name can be at most $cap characters (the tool refuses
     anything longer), and \"$name\" is ${#name}. Nothing was changed."
    fi
  fi
  if ! have "$tool"; then
    die_rename 5 "the tool that writes a $fs name is not installed.
       Install it, then run this again:   sudo pacman -S $(label_pkg "$tool")"
  fi
  if { [[ $fs == vfat || $fs == fat || $fs == msdos ]]; } && [[ $name == *[a-z]* ]]; then
    warn "this is a FAT disk: some systems show FAT names in CAPITALS. That is a
     FAT rule, not something this script chose - the name you typed is saved."
  fi

  printf '\n'
  line_ok "the disk"   "$dev  ${size:+($size)}"
  line_ok "name now"   "${label:-(no name)}"
  line_ok "name after" "$name"
  printf '\n'
  say "only the NAME inside the filesystem changes - no file is touched."
  say "the disk is closed for a moment and opened again when it is done."
  if ! confirm "rename $dev to \"$name\"?"; then
    soft_stop 1 "nothing was changed."
  fi

  [[ -n $mp && $mp != "-" ]] && was_mounted=1

  # ---- a rehearsal changes nothing ----------------------------------------
  if [[ ${DRY_RUN:-0} == 1 ]]; then
    printf '\n'
    if [[ $was_mounted == 1 ]]; then
      say "[dry-run] would run:  udisksctl unmount -b $dev"
    fi
    if [[ $tool == ntfslabel ]]; then
      say "[dry-run] would run:  sudo $tool -n $dev $name     (rehearse)"
    fi
    say "[dry-run] would run:  sudo $tool $dev $name"
    if [[ $was_mounted == 1 ]]; then
      say "[dry-run] would run:  udisksctl mount -b $dev"
    fi
    printf '\n'
    say "the rehearsal ends here - nothing was changed."
    exit 0
  fi

  # ---- unmount -------------------------------------------------------------
  step_begin "unmounting it"
  if [[ $was_mounted == 1 ]]; then
    if udisksctl unmount -b "$dev" >/dev/null 2>&1 \
    || sudo umount "$dev" >/dev/null 2>&1; then
      step_done "unmounted $dev"
    else
      step_done "it is still open" warn
      die_rename 1 "the disk could not be unmounted - something still has a file
       open on it. Close the file manager, the player or the downloader using
       $dev, then run this again."
    fi
  else
    step_done "was not open - nothing to close"
  fi

  # ---- rehearse (only ntfslabel can) --------------------------------------
  if [[ $tool == ntfslabel ]]; then
    step_begin "rehearsing the name"
    if out=$(sudo "$tool" -n "$dev" "$name" 2>&1); then
      step_done "the tool said this name is fine"
    else
      step_done "the tool said no" warn
      say "$out"
      if [[ $out != *"scheduled for check"* ]]; then
        put_back
        die_rename 1 "ntfslabel refused the rehearsal for $dev, so I stopped before
       writing anything. This is usually the DIRTY flag (Windows Fast Startup, or
       a disk that was unplugged while it was writing). Fix it once with a Windows
       'chkdsk X: /f /x', then run this again.
       Nothing was changed, and the name it has now is still there.
       Do NOT add --force."
      fi
      # The check flag: explain both ways, ask, maybe clear it, then rehearse again.
      clear_check_flag
      printf '\n'
      step_begin "rehearsing the name again"
      if out=$(sudo "$tool" -n "$dev" "$name" 2>&1); then
        step_done "the tool is happy now"
      else
        say "$out"
        put_back
        die_rename 1 "$tool still refuses $dev after the check flag was cleared.
       This volume needs a real Windows check - plug it into a Windows machine and
       let chkdsk finish.
       Nothing was changed, and the name it has now is still there.
       Do NOT add --force."
      fi
    fi
  fi

  # ---- write the name ------------------------------------------------------
  step_begin "writing the name"
  if out=$(sudo "$tool" "$dev" "$name" 2>&1); then
    step_done "${label:-(no name)}  ->  $name"
  else
    step_done "the tool refused" warn
    say "$out"
    if [[ $out == *"scheduled for check"* ]]; then
      die_waiting_for_check
    fi
    put_back
    die_rename 1 "$tool could not write the name onto $dev.
       Nothing was deleted and the name it has now is still there - read the
       message above, and never add --force."
  fi

  # ---- prove it ------------------------------------------------------------
  step_begin "checking it really changed"
  # The read needs root too (see label_now): without it the read gets
  # "Permission denied" and we would wrongly say the rename never happened.
  got=$(label_now "$dev" "$tool")
  if [[ -n $got && $got == *"$name"* ]]; then
    step_done "the disk now says: $name"
  else
    step_done "could not read the name back" warn
    put_back
    die_rename 1 "the name could not be read back from $dev, so I do not trust
       that the change happened. Check it by hand:   sudo $tool $dev"
  fi

  # ---- open it again -------------------------------------------------------
  if [[ $was_mounted == 1 ]]; then
    step_begin "opening it again"
    if udisksctl mount -b "$dev" >/dev/null 2>&1; then
      target=$(findmnt -no TARGET "$dev" 2>/dev/null)
      step_done "mounted at ${target:-/run/media/${USER:-you}/$name}"
    else
      step_done "could not open it again" warn
      say "that is not a problem - open it yourself with:"
      say "    udisksctl mount -b $dev"
    fi
  fi

  printf '\n'
  progress_bar "spinning up $dev"
  if [[ $ANIM == 1 ]]; then
    reveal_name "$name"
  fi
  printf '\n'
  hr
  printf '  WHAT YOU HAVE NOW\n'
  hr
  printf '  %s%s%s is the new name of %s\n' "$C_G" "$name" "$C_0" "$dev"
  printf '  Windows, macOS and every Linux file manager will show that name.\n'
  printf '\n'
  printf '  %-16s %s\n' "see the names:" "lsblk -o NAME,SIZE,LABEL"
  printf '  %-16s %s\n' "rename again:" "./install.sh --rename"
  printf '  %-16s %s\n' "the fix itself:" "./install.sh status"
  hr
  printf '\n'
}

# ------------------------------------ looking at a disk, and the one repair ---
# Two small modes that answer the question every NTFS owner asks sooner or
# later: "is my disk dirty, or is it really broken?". Everything they print was
# checked on throwaway images in /tmp - none of it is guessed:
#
#   * a volume waiting for a Windows check makes every ntfs read tool stop on
#     stderr with "Volume is scheduled for check." - so the flag is visible
#     WITHOUT writing a single byte;
#   * `ntfsinfo -m` prints "Volume Flags: 0x....", and bit 0 of that is the
#     dirty flag (the same thing Windows calls "check me");
#   * a broken structure says "NTFS signature is missing" / "Failed to open";
#   * `ntfsfix -n` writes nothing and only tells us whether the basic structure
#     can be read. `ntfsfix -d` is the one small repair: it clears that flag, or
#     rebuilds a boot sector from its backup copy. It is NOT chkdsk;
#   * `ntfsclone` cannot open a structurally broken volume at all, and refuses a
#     dirty one without --force - which it itself calls DANGEROUS. So this
#     script never promises a stranger "we will copy your files off".
#
# --check-disk only ever reads. --first-aid writes, and only after its own yes.

list_external_ntfs() {
  list_rename_disks | awk -F'|' '$2 ~ /^ntfs/'
}

show_look_disks() {
  local rows name fs label size _tran mp open i=1
  rows=$(list_external_ntfs)
  printf '     %-3s %-14s %-9s %-6s %s\n' "#" "DEVICE" "SIZE" "OPEN?" "NAME IT HAS NOW"
  while IFS='|' read -r name fs label size _tran mp; do
    [[ -n $name ]] || continue
    if [[ -n $mp ]]; then open="yes"; else open="no"; fi
    printf '     %-3s %-14s %-9s %-6s %s\n' "$i" "$name" "$size" "$open" "${label:-(no name)}"
    i=$((i + 1))
  done <<< "$rows"
  return 0
}

# One external NTFS disk, chosen the way --rename chooses. The device goes to
# stdout; everything the human must SEE goes to stderr, so the answer the caller
# captures stays clean. The guards run before any question is asked.
choose_external_ntfs() {
  local -a devs=()
  local rows dev fs label size _tran mp reply="" total
  rows=$(list_external_ntfs)
  if [[ -z $rows ]]; then
    soft_stop 6 "I cannot see an external NTFS disk to look at.

     Plug the Windows disk in, then check with:   lsblk -f
     Only disks that say TRAN=usb (or report themselves as removable) are
     looked at here - never the disk this system runs from."
  fi
  while IFS='|' read -r dev fs label size _tran mp; do
    [[ -n $dev ]] || continue
    devs+=("$dev")
  done <<< "$rows"
  total=${#devs[@]}

  if (( total > 1 )); then
    { printf '\n'; show_look_disks; printf '\n'; } >&2
  fi

  if [[ -n ${DISK_CHOICE:-} ]]; then
    if ! [[ $DISK_CHOICE =~ ^[0-9]+$ ]] || (( DISK_CHOICE < 1 || DISK_CHOICE > total )); then
      soft_stop 6 "--disk has to be a number between 1 and $total, nothing was done."
    fi
    printf '%s\n' "${devs[$((DISK_CHOICE - 1))]}"
    return 0
  fi
  if (( total == 1 )); then
    printf '%s\n' "${devs[0]}"
    return 0
  fi
  if [[ ! -t 0 ]]; then
    soft_stop 6 "there is more than one external NTFS disk here, and no terminal
     to ask which one you mean. Nothing was done - run it again like:
         ./install.sh --check-disk --disk 1"
  fi
  printf '     %swhich disk? (a number from the table, or Enter for the first):%s ' "$C_B" "$C_0" >&2
  read -r reply || reply=""
  reply=${reply:-1}
  if ! [[ $reply =~ ^[0-9]+$ ]] || (( reply < 1 || reply > total )); then
    soft_stop 6 "\"$reply\" is not a number between 1 and $total - nothing was done."
  fi
  printf '%s\n' "${devs[$((reply - 1))]}"
}

# Look at the volume itself - READ ONLY. Prints exactly one word:
#   healthy | dirty | damaged | busy | unknown
volume_state() {   # $1 = device
  local dev=$1 out="" flags="" rc=0
  out=$(sudo ntfsinfo -m "$dev" 2>&1) || rc=$?
  if (( rc == 0 )); then
    # bit 0 of the volume flags is the Windows "check me" flag
    flags=$(grep -oE 'Volume Flags:[[:space:]]*0x[0-9a-fA-F]+' <<< "$out" \
            | head -1 | grep -oE '0x[0-9a-fA-F]+') || flags=""
    if [[ -n $flags ]] && (( (flags & 1) == 1 )); then
      printf 'dirty\n'
    else
      printf 'healthy\n'
    fi
    return 0
  fi
  if grep -qiE 'scheduled for (a )?check|shutdown uncleanly' <<< "$out"; then
    printf 'dirty\n'; return 0
  fi
  if grep -qiE 'signature is missing|failed to open|as NTFS failed' <<< "$out"; then
    printf 'damaged\n'; return 0
  fi
  if grep -qiE 'busy|exclusively|already mounted' <<< "$out"; then
    printf 'busy\n'; return 0
  fi
  printf 'unknown\n'
  return 0
}

# Is the udisks2 fix installed? The same test --status uses.
fix_in_place() {
  local ok=1
  if [[ -f $CONFIG_PATH ]] \
  && grep -qE '^[[:space:]]*ntfs_drivers[[:space:]]*=[[:space:]]*ntfs' "$CONFIG_PATH" 2>/dev/null; then
    ok=0
  fi
  return $ok
}

# The by-hand list for the repair, in the same spirit as manual_label.
manual_first_aid() {
  cat >&2 <<'EOF'

  --------------------------------------------------------------------------
   IF YOU WOULD RATHER DO IT BY HAND

     lsblk -o NAME,SIZE,TRAN,LABEL         find the disk (TRAN=usb)
     sudo ntfsinfo -m /dev/sdX1            look - what is actually wrong?
     sudo ntfsfix -n /dev/sdX1             rehearse it (writes nothing)
     sudo ntfsfix -d /dev/sdX1             clear the "check me first" flag
     udisksctl mount -b /dev/sdX1          open it again

   ntfsfix is NOT chkdsk. It clears that flag and can rebuild a bad boot sector
   from its backup copy, but real damage is repaired on Windows:
       chkdsk X: /f /x        and once:   powercfg /h off
   --------------------------------------------------------------------------
EOF
}

die_aid() {
  local code=$1; shift
  spinner_pause
  printf '\n%s  that did not work:%s %s\n' "$C_R" "$C_0" "$*" >&2
  manual_first_aid
  exit "$code"
}

# --check-disk: the read-only look. Says which of a few things is true, and what
# the next step is. Exit code: 0 = fine, 1 = something is wrong, 6 = no disk (or
# a refused one). It never writes.
check_disk() {
  local dev="" label="" size="" desc="" state="" target="" opts="" mnt="" mounted=0 hw=0 rc=0 rows=""

  dev=$(choose_external_ntfs)
  if disk_is_protected "$dev"; then
    soft_stop 6 "$dev is on the disk this system runs from - this only ever looks
     at EXTERNAL disks. Nothing was done."
  fi
  rows=$(list_external_ntfs)
  label=$(awk -F'|' -v d="$dev" '$1 == d { print $3; exit }' <<< "$rows")
  size=$(awk -F'|'  -v d="$dev" '$1 == d { print $4; exit }' <<< "$rows")
  mnt=$(awk -F'|'   -v d="$dev" '$1 == d { print $6; exit }' <<< "$rows")
  desc="${label:-no name}"
  if [[ -n $size ]]; then desc="$desc, $size"; fi

  printf '\n'
  printf '  %sLOOKING AT %s%s  (%s)\n' "$C_B" "$dev" "$C_0" "$desc"
  say "reading only - this never writes a byte to the disk"
  printf '\n'

  # lsblk knows WHERE a partition is mounted (the same field --rename trusts);
  # findmnt knows with which OPTIONS, which is what tells rw from read-only.
  if [[ -n $mnt ]]; then
    mounted=1
    target=$mnt
    opts=$(findmnt -no OPTIONS "$dev" 2>/dev/null) || opts=""
    if [[ ,$opts, == *,rw,* ]]; then
      line_ok   "open right now" "yes, read-write at $target"
    else
      line_warn "open right now" "yes, but READ-ONLY at $target"
    fi
  else
    line_ok "open right now" "no, it is closed"
  fi

  if hardware_disconnect; then
    hw=1
    line_warn "the connection" "the kernel recorded I/O errors just now"
  else
    line_ok "the connection" "no I/O errors in the last few minutes"
  fi

  # Never probe a volume that is open: the ntfs tools refuse a mounted one.
  if (( mounted == 1 )); then
    if [[ ,$opts, == *,rw,* ]]; then
      state="open-rw"
      line_ok   "the volume itself" "writable right now - nothing to repair"
    else
      state="open-ro"
      line_warn "the volume itself" "it opened READ-ONLY"
    fi
  elif ! have ntfsinfo; then
    state="no-tool"
    line_warn "the volume itself" "cannot look deeper (ntfsinfo is not installed)"
  else
    state=$(volume_state "$dev")
    case $state in
      healthy) line_ok   "the volume itself" "healthy - nothing wrong with the filesystem" ;;
      dirty)   line_warn "the volume itself" "waiting for a WINDOWS CHECK (the dirty flag)" ;;
      damaged) line_warn "the volume itself" "the filesystem structure is damaged" ;;
      busy)    line_warn "the volume itself" "it is in use somewhere else" ;;
      *)       line_warn "the volume itself" "could not tell from the outside" ;;
    esac
  fi

  if fix_in_place; then
    line_ok   "the Arch fix" "installed - this is what makes Arch open ntfs disks"
  else
    line_warn "the Arch fix" "NOT installed - run:  ./install.sh"
  fi

  printf '\n  WHAT THIS MEANS\n'
  case $state in
    healthy|open-rw)
      say "this disk is fine. There is nothing to repair and nothing to change."
      if [[ $state == open-rw ]]; then
        say "it is open read-write right now at $target."
      fi
      ;;
    open-ro)
      say "it opened, but READ-ONLY. The two usual causes are:"
      say "  1) the check flag Windows leaves behind (Fast Startup, or a disk"
      say "     unplugged while it was writing) - Linux can clear that:"
      say "         ./install.sh --first-aid"
      say "  2) Windows is hibernated, or Fast Startup is still on - then the disk"
      say "     stays read-only on purpose. Boot Windows, shut it down properly,"
      say "     then run, as Administrator:   powercfg /h off"
      rc=1
      ;;
    dirty)
      say "the volume is healthy - only its 'check me first' flag is up."
      say "Linux can clear that in one small step, with your yes:"
      say "    ./install.sh --first-aid"
      say "with Windows instead:   chkdsk X: /f /x"
      rc=1
      ;;
    damaged)
      say "the filesystem structure is damaged. No Linux tool can repair this,"
      say "and they cannot read it at all - so nothing can be copied off with them."
      say "the repair is done on Windows:"
      say "    chkdsk X: /f /x"
      say "if the files on it matter a lot, stop using the disk and ask a recovery"
      say "tool (or service) before writing anything more to it."
      rc=1
      ;;
    no-tool)
      say "I could not look inside the volume: ntfsinfo is not installed."
      say "install it with:   sudo pacman -S ntfsprogs"
      rc=1
      ;;
    busy)
      say "something else is using the disk right now. Close whatever shows it"
      say "(file manager, player, downloader), then run this again."
      rc=1
      ;;
    *)
      say "I could not reach a verdict from the outside. Try again, or let"
      say "'./install.sh --first-aid' examine it - it looks before it writes."
      rc=1
      ;;
  esac

  if (( hw == 1 )); then
    explain_hardware
    rc=1
  fi

  printf '\n'
  printf '  %-14s %s\n' "mount it:" "udisksctl mount -b $dev"
  printf '  %-14s %s\n' "look again:" "./install.sh --check-disk"
  printf '\n'
  return $rc
}

# --first-aid: the one repair Linux can do safely. It looks first, rehearses,
# asks, then clears the "check me first" flag with ntfsfix -d. It never touches
# your files, and it refuses outright if the disk is dropping off the USB bus.
# Exit code: 0 = fixed or already fine, 1 = could not fix, 5 = ntfsfix missing,
# 6 = no disk, 7 = hardware (refused on purpose).
first_aid() {
  # shellcheck disable=SC2034  # read by put_back(), which relies on this scope
  local dev="" label="" size="" desc="" state="" out="" rc=0 after=""
  local target="" opts="" mnt="" was_mounted=0 verdict=""

  if ! have ntfsfix; then
    die_aid 5 "the tool that does this (ntfsfix) is not installed here.
       Install it, then run this again:   sudo pacman -S ntfsprogs"
  fi

  dev=$(choose_external_ntfs)
  if disk_is_protected "$dev"; then
    soft_stop 6 "$dev is on the disk this system runs from - this only ever
     touches EXTERNAL disks. Nothing was changed."
  fi
  label=$(list_external_ntfs | awk -F'|' -v d="$dev" '$1 == d { print $3; exit }')
  size=$(list_external_ntfs  | awk -F'|' -v d="$dev" '$1 == d { print $4; exit }')
  desc="${label:-no name}"
  if [[ -n $size ]]; then desc="$desc, $size"; fi

  printf '\n'
  line_ok "the disk" "$dev  ($desc)"

  # Never write filesystem bookkeeping to a disk that keeps falling off the bus.
  # That is how data is really lost - the same rule --try-force follows.
  if hardware_disconnect; then
    warn "REFUSING to touch this disk."
    explain_hardware
    die 7 "REFUSING: repairing WRITES to the disk, and this disk is dropping off
       the USB bus. Fix the cable or the port first, then run this again."
  fi

  # Same rule as --rename: lsblk's MOUNTPOINT field is what says "open", and
  # findmnt says whether it is writable. (findmnt on its own answers for ANY
  # device name, which is how a closed disk could look open.)
  mnt=$(list_external_ntfs | awk -F'|' -v d="$dev" '$1 == d { print $6; exit }')
  if [[ -n $mnt ]]; then
    was_mounted=1
    target=$mnt
    opts=$(findmnt -no OPTIONS "$dev" 2>/dev/null) || opts=""
    if [[ ,$opts, == *,rw,* ]]; then
      printf '\n'
      say "this disk already opens READ-WRITE at $target."
      say "there is nothing to repair, so I will not write to a working disk."
      exit 0
    fi
    printf '\n'
    say "it is open read-only. I will close it, look, and open it again."
  fi

  if [[ ${DRY_RUN:-0} == 1 ]]; then
    printf '\n'
    if (( was_mounted == 1 )); then say "[dry-run] would run:  udisksctl unmount -b $dev"; fi
    say "[dry-run] would run:  sudo ntfsinfo -m $dev      (read-only look)"
    say "[dry-run] would run:  sudo ntfsfix -n $dev       (rehearsal - writes nothing)"
    say "[dry-run] would run:  sudo ntfsfix -d $dev       (the one repair, after asking)"
    if (( was_mounted == 1 )); then say "[dry-run] would run:  udisksctl mount -b $dev"; fi
    printf '\n'
    say "the rehearsal ends here - nothing was changed."
    exit 0
  fi

  if (( was_mounted == 1 )); then
    step_begin "closing it"
    if udisksctl unmount -b "$dev" >/dev/null 2>&1 \
    || sudo umount "$dev" >/dev/null 2>&1; then
      step_done "closed $dev"
    else
      step_done "it is still open" warn
      die_aid 1 "the disk could not be closed - something still has a file open
       on it. Close the file manager, the player or the downloader using $dev,
       then run this again. Nothing was changed."
    fi
  fi

  printf '\n'
  step_begin "looking at the volume"
  state=$(volume_state "$dev")
  case $state in
    healthy) step_done "healthy" ;;
    dirty)   step_done "the check flag is up" warn ;;
    damaged) step_done "the structure is damaged" warn ;;
    busy)    step_done "it is in use somewhere else" warn ;;
    *)       step_done "could not tell" warn ;;
  esac

  case $state in
    healthy)
      printf '\n'
      say "this volume is healthy - it is not waiting for a check, so there is"
      say "nothing to repair. I will not write to a disk that does not need it."
      put_back
      exit 0 ;;
    busy)
      put_back
      die_aid 1 "something else is still using $dev, so I stopped before writing
       anything. Nothing was changed." ;;
    damaged)
      printf '\n'
      warn "this volume's filesystem structure is damaged (no valid NTFS found)."
      say "Linux cannot repair this, and it cannot even read the files on it."
      say "ntfsfix may still fix one thing - a boot sector can be rebuilt from its"
      say "backup copy - but it is NOT chkdsk, and it may well do nothing."
      printf '\n'
      say "STOP AND THINK FIRST: if the files on this disk matter, do not write"
      say "anything. A Windows 'chkdsk X: /f /x', or a recovery tool, is the safe"
      say "route - writing to a damaged filesystem can make it worse."
      say "If you still want me to try, answer yes at the question below."
      ;;
  esac

  printf '\n'
  step_begin "rehearsing (writes nothing)"
  out=$(sudo ntfsfix -n "$dev" 2>&1) || rc=$?
  say "$out"
  if (( rc == 0 )); then
    step_done "the basic structure can be read"
  else
    step_done "ntfsfix cannot read the basic structure" warn
  fi

  printf '\n'
  say "about to run:   sudo ntfsfix -d $dev"
  say "this clears the 'check me first' flag, or rebuilds a bad boot sector from"
  say "its backup. It writes filesystem bookkeeping - it does NOT touch your files."
  if ! confirm "repair $dev now?"; then
    put_back
    soft_stop 1 "nothing was changed."
  fi

  step_begin "doing the one repair"
  rc=0
  out=$(sudo ntfsfix -d "$dev" 2>&1) || rc=$?
  say "$out"
  if (( rc != 0 )); then
    step_done "ntfsfix could not fix it" warn
    put_back
    die_aid 1 "Linux could not fix this volume, so it needs a real Windows check:
       plug it into a Windows machine and let chkdsk finish there.
       Your files were not touched - read the message above."
  fi
  step_done "ntfsfix finished"

  step_begin "checking it worked"
  after=$(volume_state "$dev")
  if [[ $after == healthy ]]; then
    step_done "the flag is gone - the volume now reads as healthy"
  else
    step_done "it still does not read as healthy" warn
    say "the read-only look now says: $after"
  fi

  put_back
  printf '\n'
  hr
  printf '  WHAT YOU HAVE NOW\n'
  hr
  if [[ $after == healthy ]]; then verdict="is clean and ready"; else verdict="was repaired as far as Linux can"; fi
  printf '  %s%s %s%s\n' "$C_G" "$dev" "$verdict" "$C_0"
  printf '\n'
  printf '  %-14s %s\n' "mount it:" "udisksctl mount -b $dev"
  printf '  %-14s %s\n' "look again:" "./install.sh --check-disk"
  printf '  %-14s %s\n' "on Windows:" "chkdsk X: /f /x   and   powercfg /h off   (once)"
  hr
  printf '\n'
}

# ------------------------------------------------------------ mount + test ---
# Opens the disk the same way a file manager does, then proves it is read-write.
# On success it prints the mount point (and nothing else) so the caller can put
# it on a single tidy line. Every failure explains itself and returns 1.
mount_and_verify() {
  local dev=$1 target="" opts="" out="" kind="" ok=0 tries=0

  # Already open? Then there is nothing to mount - just prove it is read-write.
  if findmnt -n "$dev" >/dev/null 2>&1; then
    target=$(findmnt -no TARGET "$dev")
  else
    if [[ ${DRY_RUN:-0} == 1 ]]; then
      say "[dry-run] would run: udisksctl mount -b $dev" >&2
      printf 'dry run - nothing mounted'
      return 0
    fi

    # udisks2 can be a moment late: this script restarts it on purpose, and a
    # disk that was just plugged in may not be in its list yet. "Error looking
    # up object for device" is that, not a filesystem problem - so try a few
    # times before believing it. (MOUNT_RETRY_DELAY exists so the test suite
    # does not have to sit through the wait; it changes nothing else.)
    while (( tries < 3 )); do
      tries=$((tries + 1))
      if out=$(udisksctl mount -b "$dev" 2>&1); then ok=1; break; fi
      kind=$(mount_error_kind "$out")
      if [[ $kind == already ]]; then ok=1; break; fi   # open already = success
      [[ $kind == missing ]] || break                   # a real error: no spinning
      sleep "${MOUNT_RETRY_DELAY:-1}"
    done

    # The tool said no - but if the volume is open anyway (something else may
    # have mounted it in the meantime), that is a success, not a failure.
    if (( ok == 0 )) && findmnt -n "$dev" >/dev/null 2>&1; then ok=1; fi

    if (( ok == 0 )); then
      warn "udisksctl could not mount it: $out"
      explain_failure "$dev" "$out"
      return 1
    fi

    target=$(findmnt -no TARGET "$dev" 2>/dev/null || true)
    if [[ -z $target ]]; then
      warn "mount reported success but nothing is mounted"
      return 1
    fi
  fi

  opts=$(findmnt -no OPTIONS "$dev")
  if [[ ,$opts, != *,rw,* ]]; then
    warn "still read-only."
    explain_failure "$dev" "read-only"
    return 1
  fi

  printf '%s' "$target"
}

# Did the disk physically drop off the bus in the last few minutes?
# A disk that keeps disconnecting is a power/cable problem, and no amount of
# filesystem theory will help it. Detecting this is what stops the script from
# sending people to run chkdsk on a dying cable.
hardware_disconnect() {
  local log
  log=$(journalctl -k --since '-3 min' --no-pager 2>/dev/null | tail -40 || true)
  if [[ -z $log ]]; then return 1; fi   # cannot tell -> stay quiet
  grep -qE 'DID_ERROR|DID_NO_CONNECT|device offline|I/O error, dev|Buffer I/O error|uas.*abort|reset high-speed' <<< "$log"
}

explain_hardware() {
  warn "This looks like a HARDWARE / power problem, not a filesystem problem."
  say "the kernel recorded I/O errors and the disk dropping off the bus:" >&2
  { journalctl -k --since '-3 min' --no-pager 2>/dev/null \
    | grep -E 'DID_ERROR|DID_NO_CONNECT|device offline|I/O error, dev|Buffer I/O error' \
    | tail -5 | sed 's/^/        /' ; } >&2
  cat >&2 <<'EOF'

  --------------------------------------------------------------------------
   NO chkdsk, NO DRIVER AND NO CONFIG FILE WILL FIX THIS
  --------------------------------------------------------------------------
   A connection that keeps breaking is hardware. Check these four, in order:

   1) Is it on a USB 2 port? A 2.5" spinning drive often needs more current
      than USB 2 can promise (500 mA) to spin up, and browns out instead.
      Move it to a USB 3 port (the blue one) and check:
          lsusb -t | grep -i mass          # want 5000M, not 480M

   2) Is the cable too thin or too long? Try a short, thick, shielded cable.
      This is the most common cause and the cheapest to fix.

   3) Is the USB-SATA bridge/enclosure failing? Try another enclosure or
      another port on the same machine.

   4) Is the disk itself dying? Test it on another machine (or Windows) and
      read its health:
          sudo pacman -S smartmontools
          sudo smartctl -a /dev/sdX

   Until this is sorted out:
     * browse it READ-ONLY:   udisksctl mount -b /dev/sdX1 -o ro
     * copy anything irreplaceable off it NOW, while it is mounted
     * unplug it cleanly:     udisksctl power-off -b /dev/sdX
  --------------------------------------------------------------------------
EOF
}

# Which kind of mount error is this? ONE word, so the advice can match the
# error instead of always blaming the volume. Getting this wrong is worse than
# saying nothing: telling someone to force-mount (which WRITES filesystem
# metadata) because udisks2 merely did not know the device name is exactly the
# kind of advice that costs data.
mount_error_kind() {   # $1 = what the tool said
  local e=${1,,}
  if [[ $e == *alreadymounted* || $e == *"already mounted"* ]]; then
    printf 'already'
  elif [[ $e == *"looking up object"* || $e == *"no such device"* \
       || $e == *"not found"* || $e == *"no object"* \
       || $e == *"unknown device"* || $e == *"does not exist"* ]]; then
    printf 'missing'
  elif [[ $e == *read-only* || $e == *readonly* || $e == *"scheduled for check"* \
       || $e == *dirty* || $e == *"wrong fs type"* || $e == *"bad superblock"* \
       || $e == *"bad option"* || $e == *hibernat* || $e == *"not a valid ntfs"* ]]; then
    printf 'dirty'
  else
    printf 'other'
  fi
}

# Every failure explains itself - but it has to explain the RIGHT thing.
# $1 = the device, $2 = what the tool actually said (optional; shown as-is when
# the error is not one we recognise, because a guess is worse than the truth).
explain_failure() {
  local dev=${1:-/dev/sdX1} err=${2:-} kind

  # Ask the kernel first: did the disk physically fall off the bus? If it did,
  # blaming the filesystem would send the user down the wrong road.
  if hardware_disconnect; then
    explain_hardware
    return 0
  fi

  kind=$(mount_error_kind "$err")

  case $kind in
    already)
      cat >&2 <<EOF

  --------------------------------------------------------------------------
   IT IS ALREADY OPEN - nothing is wrong
  --------------------------------------------------------------------------
   Something has this volume mounted right now, so there was nothing left for
   this step to do. Check it yourself with:
        findmnt $dev
   If it says "rw" in the options, you are done - open it in your file manager.
  --------------------------------------------------------------------------
EOF
      ;;
    missing)
      cat >&2 <<EOF

  --------------------------------------------------------------------------
   UDISKS2 DOES NOT KNOW THIS DEVICE
  --------------------------------------------------------------------------
   The tool said:  ${err:-no message}

   This is not a filesystem problem, so chkdsk would not help and neither
   would --try-force (which writes to the disk). The usual causes:
     1) the disk was re-plugged and got a new name - look with:  lsblk -f
     2) udisks2 is still waking up (this script restarts it on purpose) -
        wait a second and simply run the script again
     3) something else already opened it - check with:  findmnt $dev
   The kernel log says whether the disk itself is fine:
        journalctl -k | tail -30
  --------------------------------------------------------------------------
EOF
      ;;
    dirty)
      cat >&2 <<EOF

  --------------------------------------------------------------------------
   WHY IT STILL REFUSES
  --------------------------------------------------------------------------
   The kernel log is where the truth is:
        journalctl -k | grep -i ntfs | tail
   If you see:  volume is dirty and "force" flag is not set
   then Windows did not shut the disk down cleanly (Fast Startup, or the cable
   was pulled during a write). Windows is the tool that repairs this:

        (on the Windows PC, Command Prompt as Administrator)
            chkdsk X: /f /x
            powercfg /h off        <- stops Fast Startup dirtying it again

   There is also a Linux-only route this script can try for you:
        ./install.sh --try-force
   It mounts the volume once with ntfs3's force flag (which clears the dirty
   flag) and unmounts it again. It writes filesystem metadata, so it asks first.
  --------------------------------------------------------------------------
EOF
      ;;
    *)
      cat >&2 <<EOF

  --------------------------------------------------------------------------
   WHY IT STILL REFUSES
  --------------------------------------------------------------------------
   The tool's own words:
        ${err:-no message}

   Two things cover almost every case:
     - the volume is marked "check me first" (Windows Fast Startup, or a disk
       unplugged while it was writing). On the Windows PC, as Administrator:
            chkdsk X: /f /x
            powercfg /h off        <- stops Fast Startup dirtying it again
       (a Linux-only route for that flag is:  ./install.sh --try-force)
     - the connection, not the disk: unplug it, try another port and a shorter
       cable, then look at what the kernel said:
            journalctl -k | tail -30
  --------------------------------------------------------------------------
EOF
      ;;
  esac
}

try_force() {
  local dev=$1 tmp

  # SAFETY: never write filesystem metadata to a disk that keeps falling off
  # the bus. That is how data is really lost - not a dirty flag, not chkdsk.
  if hardware_disconnect; then
    warn "REFUSING to force-mount."
    explain_hardware
    die 1 "REFUSING: a force mount WRITES to the disk, and this disk is
       dropping off the USB bus. Writing to a connection that keeps breaking
       is the one thing that can really destroy your data.
       Fix the cable/port first (see the advice above), then try again."
  fi

  warn "About to mount $dev read-write with the force flag."
  say "this tells ntfs3 to accept a dirty volume and clear the flag;"
  say "it WRITES filesystem metadata, but it does not touch your files."
  confirm "Continue?" || { say "cancelled - nothing changed"; return 1; }
  [[ ${DRY_RUN:-0} == 1 ]] && { say "[dry-run] would do the force mount"; return 0; }

  tmp=$(mktemp -d) || die 1 "could not create a temporary folder"
  # shellcheck disable=SC2064
  trap "cleanup; sudo umount '$tmp' 2>/dev/null || true; rmdir '$tmp' 2>/dev/null || true" EXIT

  if sudo mount -t ntfs3 -o force,remove_hiberfile "$dev" "$tmp"; then
    line_ok "force mount" "worked - the dirty flag is cleared"
    sudo umount "$tmp"
    rmdir "$tmp" 2>/dev/null || true
    trap cleanup EXIT
    say "now mount it normally:  udisksctl mount -b $dev"
    return 0
  fi
  warn "the force mount failed too."
  say "that usually means real damage, not just a dirty flag."
  say "the safe path is Windows chkdsk (see above)."
  sudo umount "$tmp" 2>/dev/null || true
  rmdir "$tmp" 2>/dev/null || true
  trap cleanup EXIT
  return 1
}

# --------------------------------------------------------------- status -----
# Read-only report: what this machine is, what is installed, whether the fix is
# in place, and what the disks look like. It never asks for a password - if it
# needs one it just says so.
show_status() {
  local id idlike name cfg="no" content="" complaints="" spare="" rc=0

  hr
  printf '  arch-ntfs-fix status\n'
  hr

  # --- the machine ------------------------------------------------------
  id=$(os_field ID); idlike=$(os_field ID_LIKE); name=$(os_field PRETTY_NAME)
  [[ -z $name ]] && name="${id:-unknown}"
  printf '  WHAT THIS MACHINE IS\n'
  printf '  %-14s %s\n' "system:" "$name"
  if have pacman; then
    if [[ $id == arch ]] || [[ " $idlike " == *" arch "* ]] \
       || grep -qw -- "${id:-none}" <<< "$ARCH_FAMILY_IDS"; then
      printf '  %-14s %s\n' "pacman:" "yes, and this is Arch-based"
    else
      printf '  %-14s %s\n' "pacman:" "yes (unusual name, but Arch-based enough)"
    fi
  else
    printf '  %-14s %s\n' "pacman:" "NO - this is not an Arch system"
    printf '\n  This script only works on Arch-based systems. Nothing here was changed.\n'
    printf '  (for other distros see: ./install.sh --help, or read the README)\n\n'
    return 2
  fi

  # --- packages ---------------------------------------------------------
  printf '\n  WHAT IS INSTALLED\n'
  if have_file /usr/bin/mount.ntfs; then
    printf '  %-14s %s\n' "ntfs-3g:" "yes"
  else
    printf '  %-14s %s\n' "ntfs-3g:" "NO - the fix cannot work without it"
    rc=1
  fi
  if have udisksctl; then
    printf '  %-14s %s\n' "udisks2:" "yes"
  else
    printf '  %-14s %s\n' "udisks2:" "NO - nothing will mount your disk"
    rc=1
  fi

  # --- the fix ----------------------------------------------------------
  printf '\n  THE FIX\n'
  if have_file "$CONFIG_PATH"; then
    content=$(grep -vE '^[[:space:]]*(#|$)' "$CONFIG_PATH" 2>/dev/null || true)
    if grep -qE '^[[:space:]]*ntfs_drivers[[:space:]]*=[[:space:]]*ntfs' "$CONFIG_PATH" 2>/dev/null; then
      cfg="yes"
      printf '  %-14s %s\n' "config file:" "installed ($CONFIG_PATH)"
      printf '  %-14s %s\n' "it says:" "ntfs_drivers=ntfs  <- this is the fix"
    else
      printf '  %-14s %s\n' "config file:" "there, but it does NOT say ntfs_drivers=ntfs"
      printf '  %-14s %s\n' "so:" "it is not doing anything for you"
      [[ -n $content ]] && printf '  %-14s %s\n' "it contains:" "$(tr '\n' ' ' <<< "$content")"
      rc=1
    fi
    if [[ -e $CONFIG_PATH.bak ]]; then
      spare=$CONFIG_PATH.bak
      printf '  %-14s %s\n' "spare copy:" "$spare (safe to delete, or use to undo)"
    fi
    # Only ask for sudo if it is already unlocked: status must never prompt.
    if sudo -n true 2>/dev/null; then
      complaints=$(sudo -n journalctl -u udisks2 -b --no-pager 2>/dev/null \
                   | grep -i 'mount options' \
                   | grep -iE 'error|does not start with a group' || true)
      if [[ -n $complaints ]]; then
        printf '  %-14s %s\n' "udisks2 log:" "it complained about the file (a reboot will fix)"
        rc=1
      else
        printf '  %-14s %s\n' "udisks2 log:" "no complaints"
      fi
    else
      printf '  %-14s %s\n' "udisks2 log:" "cannot check without a password"
    fi
  else
    printf '  %-14s %s\n' "config file:" "NOT installed"
    printf '  %-14s %s\n' "so:" "Arch will refuse a dirty NTFS disk (that is the bug)"
    rc=1
  fi

  # --- the disks --------------------------------------------------------
  printf '\n  YOUR DISKS\n'
  show_disks

  # --- what to do -------------------------------------------------------
  printf '\n  WHAT TO DO\n'
  if [[ $cfg != yes ]]; then
    printf '  %-14s %s\n' "run:" "./install.sh          (puts the fix in place)"
  elif [[ -z $(list_ntfs_disks) ]]; then
    printf '  %-14s %s\n' "nothing:" "the fix is in place, just plug an NTFS disk in"
  else
    printf '  %-14s %s\n' "ready:" "plug in a disk and run ./install.sh to mount it"
  fi
  if [[ $cfg == yes ]]; then
    printf '  %-14s %s\n' "undo:" "./install.sh --uninstall          (keeps a copy)"
    printf '  %-14s %s\n' "" "./install.sh --uninstall --purge    (keeps nothing)"
  fi
  hr
  return $rc
}

# ------------------------------------------------------------------ help -----
usage() {
  cat <<EOF

  ${C_B}arch-ntfs-fix${C_0}
  ${C_D}Make Arch open your NTFS disk the way other distros do.${C_0}

  One small config file, no guessing. It works on any desktop - GNOME,
  KDE, Hyprland, XFCE, i3 - and there is nothing to remember afterwards:
  plug the disk in and your file manager opens it.

  ${C_B}USAGE${C_0}
  ./install.sh         install the fix (it asks before every change)
  ./install.sh --list  show the NTFS disks it can see
  ./install.sh --help  this text

  You can also just say what you want:  help, status, rename, check-disk,
  first-aid. Dashes are optional, so "h", "-h" and "--h" are the same.
  While it works you get a small spinner; --plain turns that off and prints
  plain lines instead (nice when you want a log).

  ${C_B}LOOK AT YOUR DISK  (these two only read - they never write)${C_0}
  --check-disk         what is wrong with my disk, and what do I do next?
                       It says if the disk is open or closed, read-write or
                       read-only, if the cable is healthy, and if the volume
                       itself is fine, waiting for a Windows check, or really
                       damaged - then it gives you the next step.
                       It ONLY READS: it can never change anything.
                       (--self-check is about your system, not your disk.)
  --first-aid          the one repair Linux can do safely, and only when you
                       ask. It looks first, rehearses (which writes nothing),
                       asks you, then clears the "check me first" flag. Your
                       files are never touched. If it cannot fix the volume it
                       stops and says so - real damage needs Windows chkdsk.
                       --first-aid is itself the request to repair; --yes only
                       skips the last question.
  --list               just list the NTFS disks it can see, then exit
  --disk N             use disk number N from that list
  --status             read-only report: is the fix installed, and what
                       disks are plugged in?

  ${C_B}GIVE YOUR DISK A NAME${C_0}
  --rename [NAME]      give an EXTERNAL disk a name every system can read -
                       the name Windows and macOS will show. It asks you for
                       the name, and asks which disk when you have more than
                       one. Only removable/USB disks are ever offered - never
                       the disk this system runs from.
  --clear-check-flag   a disk that was unplugged while writing (or last
                       opened by Windows Fast Startup) carries a "check me
                       first" flag and refuses to be renamed. This clears
                       the flag so the rename can go ahead. --yes does not
                       cover this one: repairing a disk is a different
                       question from naming it.

  ${C_B}BE CAREFUL, OR BE QUIET${C_0}
  --dry-run            print everything it would do, change nothing
  --yes                do not ask questions (for scripts)
  --plain              no colour, no spinner, no big letters (nice in logs)
  --skip-net-check     skip the internet test
  --skip-os-check      do not refuse a system it does not recognise as
                       Arch-based (useful on Arch respins with unusual
                       os-release data)

  ${C_B}FIX IT, UNDO IT, LOOK INSIDE${C_0}
  --show-config        print the config file this script installs, then exit
  --self-check         run only the checks: system, sudo, internet, packages
  --try-force          also try ntfs3's force mount to clear a dirty flag
  --uninstall          remove the config file again (an old one stays as .bak)
  --purge              with --uninstall: delete with NO backup copy at all

  ${C_B}WHAT HAPPENS WHEN YOU RUN IT${C_0}
  1. checks the system, sudo and the internet
  2. installs what is missing (ntfs-3g, udisks2)
  3. writes /etc/udisks2/mount_options.conf (an old one is kept as a .bak)
  4. finds your NTFS disk by itself - nothing is hardcoded
  5. opens it and PROVES it really is read-write

  ${C_B}WHAT IT PROMISES${C_0}
  It never formats, never repartitions, and never touches a file of yours.
  The only things it ever writes are: the config file it installs, and -
  only when you ask for them - the disk's NAME (--rename) and the NTFS
  check flag (--rename --clear-check-flag, or --first-aid).
  --check-disk only reads.
  The only file it ever removes is the one config file it installs.
  It downloads nothing outside pacman's signed repositories.
  Run it as your normal user: it asks for sudo only where it needs it.

  ${C_B}SOURCE${C_0}
  $REPO_URL
EOF
}

# ------------------------------------------------------------------ main -----
main() {
  ASSUME_YES=0 DRY_RUN=0 CLEAR_FLAG=0 DISK_CHOICE="" ACTION="install" PURGE=0

  NEWNAME=""

  while [[ $# -gt 0 ]]; do
    case $1 in
      h|-h|--h|help|-help|--help)      usage; exit 0 ;;
      --version)        printf 'arch-ntfs-fix\n'; exit 0 ;;
      --list)           printf '\n'; show_disks; exit 0 ;;
      s|-s|--s|status|-status|--status) ACTION="status" ;;
      --show-config)    config_content; exit 0 ;;
      --dry-run)        DRY_RUN=1 ;;
      --clear-check-flag) CLEAR_FLAG=1 ;;
      --plain)          PLAIN=1; ANIM=0
                        C_R=''; C_G=''; C_Y=''; C_B=''; C_D=''; C_0='' ;;
      -y|--yes)         ASSUME_YES=1 ;;
      --skip-net-check) SKIP_NET_CHECK=1 ;;
      --skip-os-check)  SKIP_OS_CHECK=1 ;;
      --self-check)     ACTION="check" ;;
      --try-force)      ACTION="force" ;;
      check-disk|-check-disk|--check-disk|checkdisk|-checkdisk|--checkdisk)
                        ACTION="check-disk" ;;
      first-aid|firstaid|-first-aid|-firstaid|--first-aid|--firstaid)
                        ACTION="first-aid" ;;
      --uninstall)      ACTION="uninstall" ;;
      rename|-rename|--rename|r|-r|--r)
                        ACTION="rename"
                        if [[ -n ${2:-} && ${2:0:1} != "-" ]]; then NEWNAME=$2; shift; fi ;;
      --rename=*)       ACTION="rename"; NEWNAME=${1#*=} ;;
      label|-label|--label|name|-name|--name)
                        ACTION="rename"
                        if [[ -n ${2:-} && ${2:0:1} != "-" ]]; then NEWNAME=$2; shift; fi ;;
      --label=*)        ACTION="rename"; NEWNAME=${1#*=} ;;
      --name=*)         ACTION="rename"; NEWNAME=${1#*=} ;;
      --purge)          PURGE=1 ;;
      --disk)
        [[ -n ${2:-} ]] || die 2 "--disk needs a number, for example: --disk 1"
        DISK_CHOICE=$2; shift ;;
      --disk=*)         DISK_CHOICE=${1#*=} ;;
      *)
        printf '\n  I do not know the option: %s\n' "$1" >&2
        printf '  For the full list:  ./install.sh --help     (or just: help, -help, h)\n\n' >&2
        exit 2 ;;
    esac
    shift
  done

  if [[ $ACTION == status ]]; then
    show_status; exit $?
  fi

  if [[ $PURGE == 1 && $ACTION != uninstall ]]; then
    die 2 "--purge only makes sense together with --uninstall, for example:
       ./install.sh --uninstall --purge"
  fi

  local r dev label size target

  # ------------------------------------------------------------- rename -----
  # Its own small world: no packages, no internet, no config file. It only
  # ever offers removable disks, and it never touches the disk this system
  # runs from (see disk_is_protected).
  if [[ $ACTION == rename ]]; then
    banner "arch-ntfs-fix" "give the disk a name every system can read"
    step_begin "your system"; r=$(check_os);   step_done "$r"
    check_not_root
    step_begin "sudo";        r=$(check_sudo); step_done "$r"
    rename_disk
    exit 0
  fi

  # --------------------------------------------------------- check-disk -----
  # A read-only look at an external disk: what is wrong with it, and what the
  # next step is. Nothing here writes anything, ever.
  if [[ $ACTION == check-disk ]]; then
    banner "arch-ntfs-fix" "looking at an external disk (reads only)"
    step_begin "your system"; r=$(check_os);   step_done "$r"
    check_not_root
    step_begin "sudo";        r=$(check_sudo); step_done "$r"
    check_disk; exit $?
  fi

  # ---------------------------------------------------------- first-aid -----
  # The one repair Linux can do safely: clear the "check me first" flag. It is a
  # separate request on purpose - it never happens during an install or a rename.
  if [[ $ACTION == first-aid ]]; then
    banner "arch-ntfs-fix" "the one repair Linux can do - with your yes"
    step_begin "your system"; r=$(check_os);   step_done "$r"
    check_not_root
    step_begin "sudo";        r=$(check_sudo); step_done "$r"
    first_aid; exit $?
  fi

  # ---------------------------------------------------------- uninstall -----
  if [[ $ACTION == uninstall ]]; then
    banner "arch-ntfs-fix" "putting your system back the way it was"
    step_begin "your system"; r=$(check_os);   step_done "$r"
    step_begin "sudo";        r=$(check_sudo); step_done "$r"
    uninstall_config
    printf '\n'
    exit 0
  fi

  # ------------------------------------------------------------ install -----
  if [[ $ACTION == force ]]; then SKIP_NET_CHECK=1; fi

  banner "arch-ntfs-fix" "Arch refuses your NTFS disk. Other distros open it."
  printf '  %syour desktop does not matter (GNOME, KDE, Hyprland, XFCE, i3, Sway):%s\n' "$C_D" "$C_0"
  printf '  %sthis only ever talks to udisks2, and they all use that.%s\n' "$C_D" "$C_0"

  step_begin "your system";       r=$(check_os);         step_done "$r"
  check_not_root
  step_begin "sudo";              r=$(check_sudo);       step_done "$r"
  step_begin "internet";          r=$(check_network);    step_done "$r"
  step_begin "ntfs-3g + udisks2"; r=$(install_packages); step_done "$r"

  if [[ $ACTION == check ]]; then
    printf '\n  Everything needed is already here. Nothing was changed.\n'
    printf '  Run it again without --self-check to apply the fix.\n\n'
    exit 0
  fi

  step_begin "writing the fix"; r=$(install_config); step_done "$r"

  dev=$(choose_disk)
  label=$(disk_field "$dev" 2)
  size=$(disk_field "$dev" 3)
  line_ok "your disk" "$dev  ${label:+$label }${size:+($size)}"

  if [[ ${DRY_RUN:-0} == 1 ]]; then
    say "the rehearsal ends here - nothing was changed"
    exit 0
  fi

  if [[ $ACTION == force ]]; then
    try_force "$dev" || exit 7
  fi

  step_begin "opening it"
  if target=$(mount_and_verify "$dev"); then
    step_done "mounted read-write"
  else
    step_done "could not open it" warn
    exit 7
  fi

  printf '\n'
  progress_bar "spinning up $dev"
  if [[ $ANIM == 1 ]]; then
    reveal_name "$label"
  fi

  printf '\n'
  hr
  printf '  WHAT YOU HAVE NOW\n'
  hr
  printf '  %s%s is ready - READ-WRITE%s\n' "$C_G" "${label:-$dev}" "$C_0"
  printf '  mounted at %s\n' "$target"
  printf '  open it with your file manager - or just double-click the disk\n'
  printf '\n'
  printf '  %-15s %s\n' "nicer name:" "./install.sh --rename   (the name other systems show)"
  printf '  %-15s %s\n' "UNDO:" "./install.sh --uninstall   (keeps a copy)"
  printf '  %-15s %s\n' "NO LEFTOVERS:" "./install.sh --uninstall --purge   (keeps nothing)"
  printf '  %-15s %s\n' "check:" "./install.sh status"
  printf '  %-15s %s\n' "on Windows:" "chkdsk X: /f /x   and   powercfg /h off   (once)"
  hr
  printf '\n'
}

main "$@"
