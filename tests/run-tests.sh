#!/usr/bin/env bash
# shellcheck disable=SC2015
# ^ The whole harness is written as "<condition> && ok || bad". ShellCheck warns
#   that this is not if/then/else - true in general, but ok() and bad() only
#   print a line and bump a counter, so neither can ever fail and the wrong
#   branch can never run. One deliberate idiom, documented once.
# =============================================================================
#  Test suite for arch-ntfs-fix
#
#  Runs WITHOUT root and WITHOUT touching the real system: every command the
#  script uses (sudo, pacman, udisksctl, systemctl, lsblk, findmnt, ...) is
#  replaced by a small fake, and the paths it writes to are redirected into a
#  throwaway sandbox folder.
#
#  Usage:  ./tests/run-tests.sh
#  Exit code 0 = all tests passed.
# =============================================================================
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(dirname "$HERE")"
SRC="$ROOT/install.sh"
SB="$(mktemp -d)"
trap 'rm -rf "$SB"' EXIT

PASS=0; FAIL=0
ok()   { printf '  \033[1;32mPASS\033[0m %s\n' "$*"; PASS=$((PASS+1)); }
bad()  { printf '  \033[1;31mFAIL\033[0m %s\n' "$*"; FAIL=$((FAIL+1)); }
head_() { printf '\n\033[1m%s\033[0m\n' "$*"; }

[[ -f $SRC ]] || { echo "cannot find $SRC"; exit 1; }

# A copy of the script with all comment lines removed. Safety greps run on
# this, otherwise they match the SAFETY PROMISES written in the comments.
grep -vE '^[[:space:]]*#' "$SRC" > "$SRC.nocomment"
trap 'rm -rf "$SB" "$SRC.nocomment"' EXIT

# --------------------------------------------------------------- sandbox ----
mkdir -p "$SB/bin" "$SB/etc" "$SB/mnt"

cat > "$SB/bin/sudo" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == "-v" ]] && exit 0
[[ ${1:-} == "-n" ]] && shift      # -n: never prompt (status uses this)
[[ ${STUB_SUDO_FAIL:-0} == 1 ]] && { echo "sudo: a password is required" >&2; exit 1; }
export SUDO_RAN=1                  # tells the fakes "this command ran as root"
exec "$@"
EOF

cat > "$SB/bin/pacman" <<'EOF'
#!/usr/bin/env bash
for a in "$@"; do
  case $a in
    ntfs-3g) : > "$STUB_STATE/mount.ntfs"; echo "fake pacman: installed ntfs-3g" ;;
    udisks2)  echo "fake pacman: installed udisks2" ;;
  esac
done
[[ ${STUB_PACMAN_FAIL:-0} == 1 ]] && { echo "fake pacman: error: failed to commit transaction" >&2; exit 1; }
exit 0
EOF

cat > "$SB/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
echo "fake systemctl: $*" >&2
exit "${STUB_SYSTEMCTL_FAIL:-0}"
EOF

cat > "$SB/bin/journalctl" <<'EOF'
#!/usr/bin/env bash
# -k means "the kernel log": the script uses it to detect a disk that dropped
# off the USB bus, which is a different problem from a dirty volume.
if [[ " $* " == *" -k "* ]]; then
  [[ ${STUB_HARDWARE_FAIL:-0} == 1 ]] && cat <<'KMSG'
Oct 02 16:44:38 eprahemi kernel: sd 2:0:0:0: [sdb] tag#0 FAILED Result: hostbyte=DID_ERROR driverbyte=DRIVER_OK
Oct 02 16:44:38 eprahemi kernel: I/O error, dev sdb, sector 64 op 0x0:(READ)
Oct 02 16:44:38 eprahemi kernel: Buffer I/O error on dev sdb1, logical block 0
Oct 02 16:44:38 eprahemi kernel: device offline error, dev sdb, sector 0 op 0x1:(WRITE)
KMSG
  exit 0
fi
if [[ ${STUB_JOURNAL_COMPLAINT:-0} == 1 ]]; then
  echo "udisksd[1]: Error reading global mount options config file /etc/udisks2/mount_options.conf: Key file does not start with a group"
fi
exit 0
EOF

cat > "$SB/bin/getent" <<'EOF'
#!/usr/bin/env bash
exit $(( 1 - ${STUB_NET_OK:-1} ))
EOF

cat > "$SB/bin/curl" <<'EOF'
#!/usr/bin/env bash
exit $(( 1 - ${STUB_NET_OK:-1} ))
EOF

cat > "$SB/bin/lsblk" <<'EOF'
#!/usr/bin/env bash
args=" $* "
if [[ $args == *" -no LABEL "* ]]; then     # the second witness: no root needed
  [[ ${STUB_LSBLK_LABEL_FAIL:-0} == 1 ]] && exit 1
  cat "$STUB_STATE/label.out" 2>/dev/null
  exit 0
fi
[[ -f $STUB_STATE/lsblk.out ]] && cat "$STUB_STATE/lsblk.out"
exit 0
EOF

cat > "$SB/bin/findmnt" <<'EOF'
#!/usr/bin/env bash
args=" $* "
case "$args" in
  *" -no TARGET "*)  echo "${STUB_TARGET:-$STUB_STATE/mnt/500GB}"; exit 0 ;;
  *" -no FSTYPE "*)  echo "${STUB_FSTYPE:-fuseblk}"; exit 0 ;;
  *" -no OPTIONS "*) echo "${STUB_OPTIONS:-rw,nosuid,nodev,relatime}"; exit 0 ;;
  *" -no SOURCE "*)  echo "${STUB_SOURCE:-/dev/sda5}"; exit 0 ;;
esac
if [[ ${STUB_MOUNTED:-0} == 1 ]]; then echo "${STUB_TARGET:-$STUB_STATE/mnt/500GB}"; exit 0; fi
exit 1
EOF

cat > "$SB/bin/udisksctl" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  mount)
    dev=""; for a in "$@"; do [[ $a == -b ]] && dev="${!#}"; done
    echo "mount $dev" >> "$STUB_STATE/label_calls"
    if [[ ${STUB_MOUNT_FAIL:-0} == 1 ]]; then
      echo "Error mounting $dev: GDBus.Error:org.freedesktop.UDisks2.Error.Failed: wrong fs type, bad option, bad superblock" >&2
      exit 1
    fi
    # The volume is already mounted - udisksctl's own words from a real run.
    if [[ ${STUB_MOUNT_ALREADY:-0} == 1 ]]; then
      echo "Error mounting $dev: GDBus.Error:org.freedesktop.UDisks2.Error.AlreadyMounted: Device $dev is already mounted at /run/media/eprahemi/MAYBE." >&2
      exit 1
    fi
    # udisks2 does not know the device at all (it was just restarted, or the
    # disk was re-plugged and got a new name). NOT a filesystem error.
    if [[ ${STUB_MOUNT_LOOKUP_FAIL:-0} == 1 ]]; then
      echo "Error looking up object for device $dev" >&2
      exit 1
    fi
    echo "Mounted $dev at ${STUB_TARGET:-$STUB_STATE/mnt/500GB}"
    exit 0 ;;
  unmount)
    dev=""; for a in "$@"; do [[ $a == -b ]] && dev="${!#}"; done
    echo "unmount $dev" >> "$STUB_STATE/label_calls"
    if [[ ${STUB_UNMOUNT_FAIL:-0} == 1 ]]; then
      echo "Error unmounting $dev: GDBus.Error:org.freedesktop.UDisks2.Error.DeviceBusy: Device is busy" >&2
      exit 1
    fi
    echo "Unmounted $dev"
    exit 0 ;;
  *) echo "fake udisksctl: $*" >&2; exit 0 ;;
esac
EOF

cat > "$SB/bin/mount" <<'EOF'
#!/usr/bin/env bash
[[ ${STUB_FORCE_MOUNT_FAIL:-0} == 1 ]] && { echo "mount: ntfs3: volume is corrupt" >&2; exit 32; }
echo "fake mount: $*" >&2
exit 0
EOF

cat > "$SB/bin/umount" <<'EOF'
#!/usr/bin/env bash
exit ${STUB_UMOUNT_FAIL:-0}
EOF

# --- the four tools that actually write a filesystem label -------------------
# ntfslabel is special: it is the only one with a rehearsal flag (-n), so the
# fake records BOTH the rehearsal and the write, in order, in label_calls.
cat > "$SB/bin/ntfslabel" <<'EOF'
#!/usr/bin/env bash
if [[ ${1:-} == "-n" ]]; then
  shift
  echo "rehearse $*" >> "$STUB_STATE/label_calls"
  if [[ -n ${STUB_REHEARSE_MSG:-} && ! -f "$STUB_STATE/flag_cleared" ]]; then
    printf '%s\n' "$STUB_REHEARSE_MSG" >&2
    exit 1
  fi
  [[ ${STUB_LABEL_FAIL:-0} == 1 ]] && { echo "ntfslabel: volume is dirty" >&2; exit 1; }
  exit 0
fi
dev="${1:-}"; new="${2:-}"
if [[ -z $new ]]; then
  echo "read $dev" >> "$STUB_STATE/label_calls"
  # A raw block device is owned by root:disk, so a read WITHOUT root fails.
  # The real behaviour, and the bug that made a finished rename look failed.
  if [[ ${STUB_LABEL_READ_NEEDS_ROOT:-0} == 1 && ${SUDO_RAN:-0} != 1 ]]; then
    echo "ntfslabel: Error opening '$dev': Permission denied" >&2
    exit 1
  fi
  if [[ ${STUB_LABEL_READ_FAIL:-0} == 1 ]]; then
    echo "ntfslabel: could not read the volume" >&2
    exit 1
  fi
  cat "$STUB_STATE/label.out" 2>/dev/null
  exit 0
fi
echo "write(${0##*/}) $dev $new" >> "$STUB_STATE/label_calls"
if [[ ${STUB_LABEL_FAIL:-0} == 1 || ${STUB_WRITE_FAIL:-0} == 1 ]]; then
  echo "ntfslabel: volume is dirty" >&2
  exit 1
fi
printf '%s\n' "$new" > "$STUB_STATE/label.out"
exit 0
EOF

for _t in exfatlabel fatlabel e2label; do
  cat > "$SB/bin/$_t" <<'EOF'
#!/usr/bin/env bash
dev="${1:-}"; new="${2:-}"
if [[ -z $new ]]; then
  echo "read(${0##*/}) $dev" >> "$STUB_STATE/label_calls"
  if [[ ${STUB_LABEL_READ_NEEDS_ROOT:-0} == 1 && ${SUDO_RAN:-0} != 1 ]]; then
    echo "${0##*/}: Error opening '$dev': Permission denied" >&2
    exit 1
  fi
  if [[ ${STUB_LABEL_READ_FAIL:-0} == 1 ]]; then
    echo "${0##*/}: could not read the volume" >&2
    exit 1
  fi
  cat "$STUB_STATE/label.out" 2>/dev/null
  exit 0
fi
echo "write(${0##*/}) $dev $new" >> "$STUB_STATE/label_calls"
if [[ ${STUB_LABEL_FAIL:-0} == 1 ]]; then
  echo "${0##*/}: refused" >&2
  exit 1
fi
printf '%s\n' "$new" > "$STUB_STATE/label.out"
exit 0
EOF
done

# ntfsfix is what clears the "scheduled for check" flag. `-d` makes the fake
# volume clean, so the next rehearsal stops complaining (that is exactly what
# the real tool did on a throwaway image - see the brain file for the proof).
cat > "$SB/bin/ntfsfix" <<'EOF'
#!/usr/bin/env bash
case "${1:-}" in
  -n|--no-action)
    echo "ntfsfix $*" >> "$STUB_STATE/label_calls"
    echo "Mounting volume... OK"
    exit 0 ;;
  -d|--clear-dirty)
    echo "ntfsfix $*" >> "$STUB_STATE/label_calls"
    if [[ ${STUB_NTFSFIX_FAIL:-0} == 1 ]]; then
      echo "ntfsfix: could not fix the volume" >&2
      exit 1
    fi
    : > "$STUB_STATE/flag_cleared"
    echo "Mounting volume... OK"
    echo "NTFS partition was processed successfully."
    exit 0 ;;
  *)
    echo "ntfsfix $*" >> "$STUB_STATE/label_calls"
    exit 0 ;;
esac
EOF

# ntfsinfo is the READ-ONLY look that --check-disk and --first-aid use. It fakes
# what the real tool did on throwaway images: a healthy volume prints
# "Volume Flags: 0x0000" and exits 0; a volume waiting for a Windows check stops
# on STDERR with "Volume is scheduled for check." and exits 1; a broken volume
# says the NTFS signature is missing. Once ntfsfix -d has run, the fake volume
# becomes clean - exactly like the real one did (the proof is in the brain file).
cat > "$SB/bin/ntfsinfo" <<'EOF'
#!/usr/bin/env bash
echo "ntfsinfo -m ${!#}" >> "$STUB_STATE/label_calls"
if [[ ${STUB_NTFSINFO_NEEDS_ROOT:-0} == 1 && ${SUDO_RAN:-0} != 1 ]]; then
  echo "ntfsinfo: Error opening '${!#}': Permission denied" >&2
  exit 1
fi
if [[ ${STUB_NTFSINFO_DAMAGED:-0} == 1 ]]; then
  echo "Failed to open '${!#}'."
  echo "NTFS signature is missing." >&2
  exit 1
fi
if [[ ${STUB_NTFSINFO_DIRTY:-0} == 1 && ! -f "$STUB_STATE/flag_cleared" ]]; then
  printf '%s\n' "Volume is scheduled for check." \
                "Please boot into Windows TWICE, or use the 'force' option." >&2
  exit 1
fi
printf 'Volume Information\n\tDevice state: 3\n\tVolume Name: 500GB\n\tVolume Flags: 0x0000\n'
exit 0
EOF

chmod +x "$SB"/bin/*

# --- a copy of the script that writes into the sandbox instead of /etc -------
build_script() {
  sed -e "s|^CONFIG_PATH=.*|CONFIG_PATH=\"$SB/etc/mount_options.conf\"|" \
      -e "s|/usr/bin/mount.ntfs|$SB/mount.ntfs|g" \
      -e "s|install -m 644 -o root -g root|install -m 644|" \
      "$SRC" > "$SB/fix.sh"
  chmod +x "$SB/fix.sh"
}

fake_os_release() {  # $1 = arch | other
  cat > "$SB/os-release" <<EOF
NAME="$1"
ID="${1%linux}"
ID_LIKE=""
PRETTY_NAME="$1 (sandbox)"
EOF
}

fake_os() {   # $1=ID  $2=ID_LIKE  $3=PRETTY_NAME
  cat > "$SB/os-release" <<EOF
NAME="$3"
ID="$1"
ID_LIKE="$2"
PRETTY_NAME="$3"
EOF
}

# A PATH that has every stub EXCEPT pacman, and no real pacman either - so
# pretending to be another distro is honest instead of a half-truth.
no_pacman_path() {
  rm -rf "$SB/nopacman"; mkdir -p "$SB/nopacman"
  local b
  for b in "$SB"/bin/*; do
    [[ $(basename "$b") == pacman ]] && continue
    ln -s "$b" "$SB/nopacman/$(basename "$b")"
  done
  for t in bash env cat sed grep tr cut ls cp rm mkdir rmdir dirname basename \
           awk date head tail wc id chmod install mktemp tee uname printf column; do
    command -v "$t" >/dev/null 2>&1 && ln -sf "$(command -v "$t")" "$SB/nopacman/$t"
  done
  printf '%s' "$SB/nopacman"
}

# A PATH with every stub (pacman included) and the basic tools, minus ONE tool -
# so a test can prove what happens when that tool is genuinely absent. Never do
# this by deleting a stub from $SB/bin: PATH would fall through to the real
# /usr/bin, and the real tool could then touch a real disk.
path_without() {   # $1 = the tool that must not be found
  local dir="$SB/without-$1" b
  rm -rf "$dir"; mkdir -p "$dir"
  for b in "$SB"/bin/*; do
    [[ $(basename "$b") == "$1" ]] && continue
    ln -s "$b" "$dir/$(basename "$b")"
  done
  for t in bash env cat sed grep tr cut ls cp rm mkdir rmdir dirname basename \
           awk date head tail wc id chmod install mktemp tee uname printf column; do
    command -v "$t" >/dev/null 2>&1 && ln -sf "$(command -v "$t")" "$dir/$t"
  done
  printf '%s' "$dir"
}

# The label tools are fakes: this resets what they think the disk is called and
# clears the call log, so every test starts from the same place.
label_reset() {
  printf '500GB\n' > "$SB/label.out"
  : > "$SB/label_calls"
  rm -f "$SB/flag_cleared"
}

base_env() {
  export PATH="$SB/bin:$PATH"
  export STUB_STATE="$SB"
  export STUB_NET_OK=1 STUB_MOUNTED=0 STUB_MOUNT_FAIL=0 STUB_PACMAN_FAIL=0
  export STUB_SYSTEMCTL_FAIL=0 STUB_JOURNAL_COMPLAINT=0 STUB_FORCE_MOUNT_FAIL=0
  export STUB_HARDWARE_FAIL=0
  export STUB_MOUNT_ALREADY=0 STUB_MOUNT_LOOKUP_FAIL=0
  # The mount step waits a second between retries so a slow udisks2 gets a real
  # chance. The suite must not sit through that wait: 0 seconds, same code path.
  export MOUNT_RETRY_DELAY=0
  export STUB_OPTIONS="rw,nosuid,nodev,relatime" STUB_FSTYPE=fuseblk
  export STUB_TARGET="$SB/mnt/500GB"
  export STUB_SOURCE=/dev/sda5
  export STUB_LABEL_FAIL=0 STUB_UNMOUNT_FAIL=0 STUB_UMOUNT_FAIL=0 STUB_WRITE_FAIL=0
  export STUB_REHEARSE_MSG=""
  export STUB_NTFSFIX_FAIL=0
  export STUB_NTFSINFO_DIRTY=0 STUB_NTFSINFO_DAMAGED=0 STUB_NTFSINFO_NEEDS_ROOT=0
  export STUB_LABEL_READ_NEEDS_ROOT=0 STUB_LABEL_READ_FAIL=0 STUB_LSBLK_LABEL_FAIL=0
  export STUB_SUDO_FAIL=0
  export OS_RELEASE_FILE="$SB/os-release"
  : > "$SB/lsblk.out"                      # start with: no disks
  rm -f "$SB/etc/mount_options.conf" "$SB/etc/mount_options.conf.bak"
  label_reset
}

one_disk() {
  cat > "$SB/lsblk.out" <<EOF
NAME="/dev/vda" FSTYPE="ext4" LABEL="archroot" SIZE="88G" TRAN="sata" RM="0" MOUNTPOINT="/"
NAME="/dev/sdb" FSTYPE="" LABEL="" SIZE="465.8G" TRAN="usb" RM="1" MOUNTPOINT=""
NAME="/dev/sdb1" FSTYPE="ntfs" LABEL="500GB" SIZE="465.8G" TRAN="usb" RM="1" MOUNTPOINT=""
EOF
}

two_disks() {
  cat > "$SB/lsblk.out" <<EOF
NAME="/dev/sdb1" FSTYPE="ntfs" LABEL="500GB" SIZE="465.8G" TRAN="usb" RM="1" MOUNTPOINT=""
NAME="/dev/sdc1" FSTYPE="ntfs" LABEL="BACKUP" SIZE="931.5G" TRAN="usb" RM="1" MOUNTPOINT=""
EOF
}

run() { "$SB/fix.sh" "$@" </dev/null 2>&1; }

# ---- fixtures for --rename --------------------------------------------------
# Real lsblk reports TRAN and RM on the WHOLE DISK, never on the partition, so
# these fixtures copy that exactly: the parent says usb, the child says nothing.
usb_ntfs() {   # one removable NTFS disk, currently mounted
  cat > "$SB/lsblk.out" <<EOF
NAME="/dev/sda" FSTYPE="" LABEL="" SIZE="238.5G" TRAN="sata" RM="0" MOUNTPOINT="" TYPE="disk"
NAME="/dev/sda1" FSTYPE="vfat" LABEL="" SIZE="600M" TRAN="" RM="0" MOUNTPOINT="/boot/efi" TYPE="part"
NAME="/dev/sdb" FSTYPE="" LABEL="" SIZE="465.8G" TRAN="usb" RM="0" MOUNTPOINT="" TYPE="disk"
NAME="/dev/sdb1" FSTYPE="ntfs" LABEL="500GB" SIZE="465.8G" TRAN="" RM="0" MOUNTPOINT="$SB/mnt/500GB" TYPE="part"
EOF
}

usb_two() {    # two removable disks: NTFS first, exFAT second
  cat > "$SB/lsblk.out" <<EOF
NAME="/dev/sda" FSTYPE="" LABEL="" SIZE="238.5G" TRAN="sata" RM="0" MOUNTPOINT="" TYPE="disk"
NAME="/dev/sda1" FSTYPE="ext4" LABEL="" SIZE="91.1G" TRAN="" RM="0" MOUNTPOINT="/" TYPE="part"
NAME="/dev/sdb" FSTYPE="" LABEL="" SIZE="465.8G" TRAN="usb" RM="0" MOUNTPOINT="" TYPE="disk"
NAME="/dev/sdb1" FSTYPE="ntfs" LABEL="500GB" SIZE="465.8G" TRAN="" RM="0" MOUNTPOINT="" TYPE="part"
NAME="/dev/sdc" FSTYPE="" LABEL="" SIZE="931.5G" TRAN="usb" RM="1" MOUNTPOINT="" TYPE="disk"
NAME="/dev/sdc1" FSTYPE="exfat" LABEL="BACKUP" SIZE="931.5G" TRAN="" RM="0" MOUNTPOINT="" TYPE="part"
EOF
}

usb_ntfs_closed() {   # the same disk, but NOT open right now
  cat > "$SB/lsblk.out" <<EOF
NAME="/dev/sda" FSTYPE="" LABEL="" SIZE="238.5G" TRAN="sata" RM="0" MOUNTPOINT="" TYPE="disk"
NAME="/dev/sda1" FSTYPE="vfat" LABEL="" SIZE="600M" TRAN="" RM="0" MOUNTPOINT="/boot/efi" TYPE="part"
NAME="/dev/sdb" FSTYPE="" LABEL="" SIZE="465.8G" TRAN="usb" RM="0" MOUNTPOINT="" TYPE="disk"
NAME="/dev/sdb1" FSTYPE="ntfs" LABEL="500GB" SIZE="465.8G" TRAN="" RM="0" MOUNTPOINT="" TYPE="part"
EOF
}

usb_ntfs_two() {   # two removable NTFS disks - the script must ask which one
  cat > "$SB/lsblk.out" <<EOF
NAME="/dev/sda" FSTYPE="" LABEL="" SIZE="238.5G" TRAN="sata" RM="0" MOUNTPOINT="" TYPE="disk"
NAME="/dev/sda1" FSTYPE="ext4" LABEL="" SIZE="91.1G" TRAN="" RM="0" MOUNTPOINT="/" TYPE="part"
NAME="/dev/sdb" FSTYPE="" LABEL="" SIZE="465.8G" TRAN="usb" RM="1" MOUNTPOINT="" TYPE="disk"
NAME="/dev/sdb1" FSTYPE="ntfs" LABEL="500GB" SIZE="465.8G" TRAN="" RM="0" MOUNTPOINT="" TYPE="part"
NAME="/dev/sdc" FSTYPE="" LABEL="" SIZE="931.5G" TRAN="usb" RM="1" MOUNTPOINT="" TYPE="disk"
NAME="/dev/sdc1" FSTYPE="ntfs" LABEL="BACKUP" SIZE="931.5G" TRAN="" RM="0" MOUNTPOINT="" TYPE="part"
EOF
}

usb_only() {   # the internal disk only - nothing external to offer
  cat > "$SB/lsblk.out" <<EOF
NAME="/dev/sda" FSTYPE="" LABEL="" SIZE="238.5G" TRAN="sata" RM="0" MOUNTPOINT="" TYPE="disk"
NAME="/dev/sda1" FSTYPE="ext4" LABEL="" SIZE="91.1G" TRAN="" RM="0" MOUNTPOINT="/" TYPE="part"
NAME="/dev/sda4" FSTYPE="swap" LABEL="" SIZE="8G" TRAN="" RM="0" MOUNTPOINT="[SWAP]" TYPE="part"
EOF
}

usb_btrfs() {  # a removable disk with a filesystem no label tool here can name
  cat > "$SB/lsblk.out" <<EOF
NAME="/dev/sda" FSTYPE="" LABEL="" SIZE="238.5G" TRAN="sata" RM="0" MOUNTPOINT="" TYPE="disk"
NAME="/dev/sda1" FSTYPE="ext4" LABEL="" SIZE="91.1G" TRAN="" RM="0" MOUNTPOINT="/" TYPE="part"
NAME="/dev/sdb" FSTYPE="" LABEL="" SIZE="465.8G" TRAN="usb" RM="0" MOUNTPOINT="" TYPE="disk"
NAME="/dev/sdb1" FSTYPE="btrfs" LABEL="stuff" SIZE="465.8G" TRAN="" RM="0" MOUNTPOINT="" TYPE="part"
EOF
}

usb_system() { # a USB disk that carries the running system (the trap case)
  cat > "$SB/lsblk.out" <<EOF
NAME="/dev/sda" FSTYPE="" LABEL="" SIZE="238.5G" TRAN="usb" RM="0" MOUNTPOINT="" TYPE="disk"
NAME="/dev/sda1" FSTYPE="ext4" LABEL="" SIZE="91.1G" TRAN="" RM="0" MOUNTPOINT="/" TYPE="part"
NAME="/dev/sda4" FSTYPE="swap" LABEL="" SIZE="8G" TRAN="" RM="0" MOUNTPOINT="[SWAP]" TYPE="part"
EOF
}

build_script
base_env
fake_os_release arch
: > "$SB/mount.ntfs"          # pretend ntfs-3g is installed

# ================================================================ tests =====
head_ "1. the basics (no system changes at all)"

out=$(run --help); rc=$?
[[ $rc -eq 0 ]] && [[ $out == *"WHAT IT PROMISES"* ]] && ok "--help works and lists its promises" \
  || bad "--help (rc=$rc)"

out=$(run --version); rc=$?
[[ $rc -eq 0 ]] && [[ $out == *"arch-ntfs-fix"* ]] && ok "--version works" || bad "--version (rc=$rc)"

out=$(run --nonsense); rc=$?
[[ $rc -eq 2 ]] && [[ $out == *"I do not know the option"* ]] \
  && ok "an unknown option is refused politely (rc=2)" || bad "unknown option (rc=$rc)"
[[ $out == *"For the full list"* ]] && ok "  ...and shows how to get the help" || bad "no way out offered"
[[ $out != *"WHAT IT PROMISES"* ]] && [[ $out != *"USAGE"* ]] \
  && ok "  ...and does NOT dump the whole 40-line help at you" || bad "still dumps the manual"

head_ "2. the config file it installs"

run --show-config > "$SB/cfg" 2>/dev/null
[[ -s $SB/cfg ]] && grep -q '^\[defaults\]$' "$SB/cfg" \
  && grep -q '^ntfs_drivers=ntfs$' "$SB/cfg" \
  && ok "config starts with [defaults] and sets ntfs_drivers=ntfs" \
  || bad "config content is wrong"

if [[ -f $ROOT/mount_options.conf ]]; then
  if diff -q <(grep -v '^\s*$' "$ROOT/mount_options.conf") <(grep -v '^\s*$' "$SB/cfg") >/dev/null; then
    ok "the copy in the repo is identical to what the script installs (no drift)"
  else
    bad "repo mount_options.conf differs from --show-config output"
  fi
else
  bad "repo mount_options.conf is missing"
fi

head_ "3. safety checks (the refusal paths)"

# A non-Arch system is defined by having NO pacman (that is what check_os
# asks), so the sandbox PATH has to hide the real /usr/bin/pacman too.
fake_os_release otherlinux
NP=$(no_pacman_path)
out=$(PATH="$NP" "$SB/fix.sh" --dry-run </dev/null 2>&1); rc=$?
[[ $rc -eq 2 ]] && [[ $out == *"isn't an Arch-based system"* ]] \
  && ok "refuses to touch a non-Arch system (rc=2)" \
  || bad "non-Arch guard (rc=$rc)"
out=$(run --dry-run); rc=$?
[[ $out == *"I don't know this one by name"* ]] && [[ $out != *"won't touch"* ]] \
  && ok "an unknown system that HAS pacman is admitted, not refused" \
  || bad "pacman fallback (rc=$rc)"
[[ ! -f $SB/etc/mount_options.conf ]] && ok "  ...and wrote nothing on the way out" || bad "wrote something anyway!"
fake_os_release arch

export STUB_NET_OK=0
out=$(run --dry-run); rc=$?
export STUB_NET_OK=1
[[ $rc -eq 4 ]] && [[ $out == *"No working internet"* ]] && ok "detects no internet and explains why (rc=4)" \
  || bad "internet check (rc=$rc)"
[[ $out == *"DO IT BY HAND"* ]] && ok "  ...and prints manual instructions on failure" || bad "no manual instructions"

rm -f "$SB/mount.ntfs"     # now pretend ntfs-3g is missing
one_disk                  # ...and there is a disk waiting, so the rehearsal can finish
out=$(run --dry-run); rc=$?
[[ $rc -eq 0 ]] && [[ $out == *"ntfs-3g"* ]] && ok "dry run REHEARSES a missing package instead of dying" \
  || bad "dry run should not stop for a missing package (rc=$rc)"
[[ $out == *"pacman -S --needed ntfs-3g"* ]] && ok "  ...and shows the exact pacman command" || bad "no pacman hint"
[[ $out == *"no password asked"* ]] && ok "  ...and never asks for a sudo password" || bad "dry run asked for a password"

out=$(run); rc=$?      # a REAL run, no --yes, no terminal -> must stop and teach
[[ $rc -eq 5 ]] && [[ $out == *"You said no to installing"* ]] && ok "a real run stops and teaches when it may not install" \
  || bad "real missing-package path (rc=$rc)"

one_disk
out=$(run --yes); rc=$?
[[ $rc -eq 0 ]] && ok "with --yes it installs what is missing and continues" || bad "--yes happy path (rc=$rc)"
[[ $out == *"READ-WRITE"* ]] && ok "  ...and proves the mount is read-write" || bad "no rw proof"
[[ -f $SB/etc/mount_options.conf ]] && ok "  ...and the config file exists" || bad "config not written"
grep -q '^ntfs_drivers=ntfs$' "$SB/etc/mount_options.conf" 2>/dev/null && ok "  ...with the right content" || bad "wrong config content"

head_ "4. the tricky real-world failures"
# This one needs the WRITE path: the config is written, udisks2 is restarted and
# the log is read back. So the config must NOT already be there - a run with an
# identical config is deliberately a no-op now.
base_env; one_disk

export STUB_JOURNAL_COMPLAINT=1
out=$(run --yes); rc=$?
unset STUB_JOURNAL_COMPLAINT
[[ $rc -eq 1 ]] && [[ $out == *"udisks2 rejected the file"* ]] && ok "detects when udisks2 rejects the file (the [defaults] trap)" \
  || bad "rejected-config detection (rc=$rc)"

export STUB_MOUNTED=1 STUB_OPTIONS="ro,nosuid,nodev,relatime"
out=$(run --yes); rc=$?
unset STUB_MOUNTED STUB_OPTIONS
[[ $rc -eq 7 ]] && [[ $out == *"still read-only"* ]] && ok "a still read-only mount is reported as a failure (rc=7)" \
  || bad "read-only detection (rc=$rc)"
[[ $out == *"chkdsk"* ]] && ok "  ...and points at the real fix (chkdsk / powercfg)" || bad "no chkdsk advice"

export STUB_MOUNT_FAIL=1
out=$(run --yes); rc=$?
unset STUB_MOUNT_FAIL
[[ $rc -eq 7 ]] && [[ $out == *"could not mount"* ]] && ok "a mount failure is explained, not hidden (rc=7)" \
  || bad "mount failure path (rc=$rc)"

export STUB_MOUNT_FAIL=1 STUB_HARDWARE_FAIL=1
out=$(run --yes); rc=$?
unset STUB_MOUNT_FAIL STUB_HARDWARE_FAIL
[[ $rc -eq 7 ]] && [[ $out == *"HARDWARE / power problem"* ]] \
  && ok "a disk that dropped off the bus is called HARDWARE, not filesystem" \
  || bad "hardware detection (rc=$rc)"
[[ $out == *"DID_ERROR"* ]] && ok "  ...and quotes the kernel's own words" || bad "no kernel evidence shown"
[[ $out == *"lsusb -t"* ]] && ok "  ...and checks the USB speed (5000M vs 480M)" || bad "no USB speed advice"
[[ $out != *"chkdsk X: /f /x"* ]] \
  && ok "  ...and does NOT tell them to run chkdsk on a dying cable" \
  || bad "wrong advice: suggests chkdsk for a hardware fault"
[[ $out == *"power-off"* ]] && ok "  ...and tells them how to unplug safely" || bad "no safe-unplug advice"

export STUB_HARDWARE_FAIL=1
export STUB_FORCE_MOUNT_FAIL=0
out=$(run --try-force --yes); rc=$?
unset STUB_HARDWARE_FAIL
[[ $rc -ne 0 && $out == *"REFUSING"* ]] \
  && ok "--try-force REFUSES to write to a disk that keeps disconnecting" \
  || bad "force-mount safety guard missing (rc=$rc)"
[[ $out == *"really destroy your data"* ]] && ok "  ...and says why in plain words" || bad "no reason given"

export STUB_FORCE_MOUNT_FAIL=1
out=$(run --try-force --yes); rc=$?
unset STUB_FORCE_MOUNT_FAIL
[[ $out == *"real damage"* ]] && ok "a failing force mount is called damage, not just a flag" \
  || bad "force-failure wording"

head_ "4b. failures that are NOT the disk's fault"

# Every one of these came out of a real run on a real laptop with two disks
# plugged in (2026-10-03). The old code answered all of them with the
# dirty-volume speech and offered --try-force - a "repair" that WRITES to the
# disk. For a device udisks2 simply could not resolve, that is the wrong advice,
# and one of them was a plain code bug: a prompt leaked into the device name.

# 1) udisks2 does not know the device. It had just been restarted (the script
#    does that on purpose) and the disk was not in its list yet.
base_env; one_disk
export STUB_MOUNT_LOOKUP_FAIL=1
out=$(run --yes); rc=$?
unset STUB_MOUNT_LOOKUP_FAIL
[[ $rc -eq 7 ]] && ok "a device udisks2 cannot resolve is a failure, not a silent pass (rc=7)" \
  || bad "unknown-device path (rc=$rc)"
[[ $out == *"UDISKS2 DOES NOT KNOW THIS DEVICE"* ]] && ok "  ...and names the real cause" \
  || bad "wrong diagnosis shown"
[[ $out != *"chkdsk X: /f /x"* ]] && ok "  ...and does NOT send them to Windows for it" \
  || bad "chkdsk advice for a device-lookup error"
[[ $out != *"./install.sh --try-force"* ]] \
  && ok "  ...and never tells them to run it (that writes to the disk)" \
  || bad "recommended --try-force for a device-lookup error"
[[ $(grep -c '^mount ' "$SB/label_calls") -eq 3 ]] \
  && ok "  ...and it tried three times first (udisks2 can just be slow)" \
  || bad "retry count wrong: $(grep -c '^mount ' "$SB/label_calls")"

# 2) something already has the volume mounted and udisksctl says so. That is a
#    SUCCESS - anything else turns a perfectly good disk into a red error on
#    screen (which is exactly what happened on the laptop).
base_env; one_disk
export STUB_MOUNT_ALREADY=1
out=$(run --yes); rc=$?
unset STUB_MOUNT_ALREADY
[[ $rc -eq 0 && $out == *"READ-WRITE"* ]] \
  && ok "a disk that is already mounted counts as success (rc=0)" \
  || bad "already-mounted reported as a failure (rc=$rc)"
[[ $out != *"could not open it"* ]] && ok "  ...and is never called a failure on screen" \
  || bad "said 'could not open it' for a disk that was open"

# 3) a second run with the very same config must be a true no-op: no rewrite, no
#    pointless .bak, and above all NO udisks2 restart - a restart makes every
#    mounted disk briefly disappear from udisks2's list and come back.
base_env; one_disk
out=$(run --yes); rc=$?
[[ $rc -eq 0 && $out == *"written, udisks2 restarted"* ]] \
  && ok "the first run writes the fix and restarts udisks2" || bad "first run (rc=$rc)"
calls_before=$(grep -c . "$SB/label_calls")
export STUB_MOUNTED=1        # pretend something has it mounted already
out=$(run --yes); rc=$?
unset STUB_MOUNTED
[[ $rc -eq 0 && $out == *"already in place"* ]] \
  && ok "a second run says the fix is already in place" || bad "second run (rc=$rc)"
[[ $out != *"udisks2 restarted"* ]] \
  && ok "  ...and does NOT restart udisks2 for nothing" || bad "restarted udisks2 for nothing"
[[ ! -f $SB/etc/mount_options.conf.bak ]] \
  && ok "  ...and makes no pointless .bak copy" || bad "a needless backup was made"
[[ $(grep -c . "$SB/label_calls") -eq $calls_before ]] \
  && ok "  ...and does not touch the disk again either" || bad "the second run touched the disk"

# 4) THE CODE BUG ITSELF. The disk chooser is called as $(choose_disk), so its
#    stdout IS the device name - and the "which disk?" prompt was printed to
#    stdout by say(). The device name therefore became
#    "which disk should I test? ... /dev/sdb1", and udisksctl answered
#    "Error looking up object for device". The prompt only exists on a real
#    terminal, so this test needs a pty: script(1) makes one.
if command -v script >/dev/null 2>&1; then
  base_env; two_disks
  printf '1\n' | timeout 30 script -qec \
    "env PATH='$SB/bin:/usr/bin:/bin' STUB_STATE='$SB' '$SB/fix.sh' --plain --yes" \
    /dev/null >/dev/null 2>&1
  raw=$(grep '^mount ' "$SB/label_calls" || true)
  [[ $raw == 'mount /dev/sdb1' ]] \
    && ok "the disk prompt never leaks into the device name (real pty run)" \
    || bad "device name leaked into the mount call: [$raw]"
fi

head_ "5. finding the disk by itself (nothing hardcoded)"

two_disks
out=$(run --yes --disk 1)
[[ $out == *"/dev/sdc1"* ]] && ok "every device is reported as a FULL path (lsblk -p)" \
  || bad "device paths are not full paths (would break udisksctl)"
out=$(run --yes); rc=$?
[[ $rc -eq 6 ]] && [[ $out == *"--disk"* ]] && ok "two NTFS disks + no terminal -> asks for --disk (rc=6)" \
  || bad "ambiguous disk handling (rc=$rc)"
[[ $out == *"/dev/sdb1"* && $out == *"/dev/sdc1"* ]] && ok "  ...and lists both disks" || bad "disk list missing"

out=$(run --yes --disk 2); rc=$?
[[ $rc -eq 0 ]] && [[ $out == *"/dev/sdc1"* ]] && ok "--disk 2 picks the second disk by itself" \
  || bad "--disk selection (rc=$rc)"

out=$(run --yes --disk 9); rc=$?
[[ $rc -eq 6 ]] && ok "--disk 99 is rejected, nothing guessed" || bad "bad --disk value (rc=$rc)"

out=$("$SB/fix.sh" --list </dev/null 2>&1); rc=$?
[[ $rc -eq 0 && $out == *BACKUP* ]] && ok "--list works on its own" || bad "--list (rc=$rc)"

head_ "6. dry run changes nothing"

base_env; : > "$SB/mount.ntfs"; one_disk
out=$(run --dry-run --yes); rc=$?
[[ $rc -eq 0 ]] && ok "--dry-run finishes cleanly" || bad "--dry-run (rc=$rc)"
[[ ! -f $SB/etc/mount_options.conf ]] && ok "  ...and wrote NO config file" || bad "dry run wrote a file!"
[[ $out == *"ntfs_drivers=ntfs"* ]] && ok "  ...but still showed exactly what it would write" || bad "dry run not informative"

head_ "7. uninstall"

base_env; : > "$SB/mount.ntfs"
install -m 644 /dev/null "$SB/etc/mount_options.conf"
printf '[defaults]\nntfs_drivers=ntfs\n' >> "$SB/etc/mount_options.conf"
out=$(run --uninstall --yes); rc=$?
[[ $rc -eq 0 && ! -f $SB/etc/mount_options.conf ]] && ok "--uninstall removes the config" || bad "--uninstall (rc=$rc)"
[[ -f $SB/etc/mount_options.conf.bak ]] && ok "  ...and keeps a .bak copy first" || bad "no backup kept"
out=$(run --uninstall --yes); rc=$?
[[ $rc -eq 0 ]] && ok "--uninstall is safe to run twice" || bad "uninstall not idempotent (rc=$rc)"

# --purge: a clean removal with NO trace, for people who do not want a copy
base_env; one_disk
cp "$SB/etc/mount_options.conf" /dev/null 2>/dev/null || true
printf '[defaults]\nntfs_drivers=ntfs\n' > "$SB/etc/mount_options.conf"
out=$(run --uninstall --purge --yes); rc=$?
[[ $rc -eq 0 && ! -f $SB/etc/mount_options.conf ]] && ok "--purge removes the config" \
  || bad "--purge (rc=$rc)"
[[ ! -f $SB/etc/mount_options.conf.bak ]] \
  && ok "  ...and keeps NO .bak copy at all (that is what purge means)" \
  || bad "--purge left a backup behind"
[[ $out == *"nothing kept"* ]] && ok "  ...and says so out loud" || bad "purge not announced"
[[ $out == *"no copy will be kept"* ]] && ok "  ...and warns you BEFORE deleting" || bad "no pre-warning"

# a stale .bak must not survive --purge, or purge would be a lie
printf 'old junk\n' > "$SB/etc/mount_options.conf.bak"
printf '[defaults]\nntfs_drivers=ntfs\n' > "$SB/etc/mount_options.conf"
out=$(run --uninstall --purge --yes); rc=$?
[[ ! -f $SB/etc/mount_options.conf.bak ]] \
  && ok "--purge also deletes a leftover .bak from an earlier run" \
  || bad "stale .bak survived --purge"

# the default path must still offer the one-command undo
base_env
printf '[defaults]\nntfs_drivers=ntfs\n' > "$SB/etc/mount_options.conf"
out=$(run --uninstall --yes); rc=$?
[[ -f $SB/etc/mount_options.conf.bak && $out == *"UNDO:"* && $out == *"sudo mv"* ]] \
  && ok "without --purge you get the .bak AND the exact undo command" \
  || bad "undo hint missing"
[[ $out == *"--uninstall --purge"* ]] \
  && ok "  ...and it still tells you about --purge, in case you want no leftovers" \
  || bad "purge not mentioned in the uninstall summary"

out=$(run --purge --yes); rc=$?
[[ $rc -eq 2 && $out == *"only makes sense together with --uninstall"* ]] \
  && ok "--purge on its own is refused with an example (rc=2)" \
  || bad "--purge alone (rc=$rc)"

out=$(run --uninstall --purge --dry-run); rc=$?
[[ $rc -eq 0 && ! -f $SB/etc/mount_options.conf ]] \
  && ok "--dry-run --purge deletes nothing" || bad "dry-run purge (rc=$rc)"

head_ "8. the script itself must stay safe"

if grep -nE 'rm[[:space:]]+-rf|mkfs|dd[[:space:]]+if=|wipefs|shred[[:space:]]|>[[:space:]]*/dev/sd[a-z]' "$SRC.nocomment" >/dev/null; then
  bad "the script contains a dangerous command!"
  grep -nE 'rm[[:space:]]+-rf|mkfs|dd[[:space:]]+if=|wipefs|shred[[:space:]]|>[[:space:]]*/dev/sd[a-z]' "$SRC.nocomment" | sed 's/^/        /'
else
  ok "no rm -rf, no mkfs, no dd, no direct writes to /dev/sdX"
fi

if grep -nE 'curl[^|]*\|[[:space:]]*(ba)?sh|wget[^|]*\|[[:space:]]*(ba)?sh' "$SRC.nocomment" >/dev/null; then
  bad "the script pipes a download into a shell!"
else
  ok "no curl|bash / wget|sh anywhere"
fi

bash -n "$SRC" && ok "bash syntax check passes" || bad "syntax error in the script"

head_ "9. it must not care about the user's shell or environment"

head -1 "$SRC" | grep -q '^#!/usr/bin/env bash' \
  && ok "shebang pins bash, so the login shell (fish/zsh/...) is irrelevant" \
  || bad "the shebang does not name bash"

out=$(env -i PATH="$SB/bin:/usr/bin:/bin" HOME="$SB" "$SB/fix.sh" --version 2>&1); rc=$?
[[ $rc -eq 0 && $out == *"arch-ntfs-fix"* ]] \
  && ok "runs with an EMPTY environment (no USER, no PATH extras, nothing)" \
  || bad "empty-environment run (rc=$rc)"

for sh_bin in bash fish; do
  if command -v "$sh_bin" >/dev/null; then
    out=$("$sh_bin" -c "$SB/fix.sh --version" 2>&1); rc=$?
    [[ $rc -eq 0 && $out == *"arch-ntfs-fix"* ]] \
      && ok "runs when invoked from $sh_bin as the calling shell" \
      || bad "invoking from $sh_bin (rc=$rc)"
  fi
done

head_ "10. which systems does it accept, and which does it refuse?"

# CachyOS shipped os-release with NO ID_LIKE for years (their issue #177), so
# detection must not rely on ID_LIKE alone or CachyOS users get refused.
fake_os cachyos "" "CachyOS"
out=$(run --self-check); rc=$?
[[ $rc -eq 0 && $out == *"Arch-based"* ]] \
  && ok "CachyOS accepted even with no ID_LIKE (the real-world trap)" \
  || bad "CachyOS (rc=$rc)"

for d in "manjaro arch Manjaro" "endeavouros arch EndeavourOS" "steamos arch SteamOS" \
         "garuda arch GarudaLinux" "artix arch Artix"; do
  # shellcheck disable=SC2086   # deliberate: the "id like Name" triple splits into 3 words
  set -- $d
  fake_os "$1" "$2" "$3"
  out=$(run --self-check); rc=$?
  [[ $rc -eq 0 && $out == *"Arch-based"* ]] \
    && ok "$3 accepted (ID=$1, ID_LIKE=$2)" || bad "$3 (rc=$rc)"
done

fake_os my-weird-respin "" "Some Respins 3000"
out=$(run --self-check); rc=$?
[[ $rc -eq 0 && $out == *"I don't know this one"* && $out == *"pacman is here"* ]] \
  && ok "an unknown Arch respin is admitted (with a warning, not a refusal)" \
  || bad "unknown respin (rc=$rc)"
[[ $out == *"Ctrl+C"* ]] && ok "  ...and it warns that nothing has changed yet" || bad "no warning"

[[ $out == *"GNOME, KDE, Hyprland"* ]] \
  && ok "it states the desktop environment does not matter" || bad "no DE note"

fake_os otherlinux "" "Synthetic Linux"
NP=$(no_pacman_path)
out=$(PATH="$NP" "$SB/fix.sh" --self-check </dev/null 2>&1); rc=$?
[[ $rc -eq 2 && $out == *"isn't an Arch-based system"* ]] \
  && ok "a non-Arch system refused politely (rc=2, nothing touched)" || bad "non-Arch (rc=$rc)"
[[ $out == *"dnf install ntfs-3g"* ]] && ok "  ...and gives the dnf command" || bad "no dnf hint"
[[ $out == *"apt install ntfs-3g"* ]] && ok "  ...and the apt one too" || bad "no apt hint"
[[ $out == *"/etc/udisks2/mount_options.conf"* ]] \
  && ok "  ...and says the config file itself works anywhere" || bad "no universal-fix hint"

fake_os example exampleos "Example Linux"
out=$(PATH="$NP" "$SB/fix.sh" --self-check </dev/null 2>&1); rc=$?
[[ $rc -eq 2 ]] && ok "a system with a foreign ID_LIKE refused politely (rc=2)" || bad "foreign ID_LIKE (rc=$rc)"

out=$(PATH="$NP" "$SB/fix.sh" --self-check --skip-os-check --dry-run </dev/null 2>&1); rc=$?
[[ $out != *"isn't an Arch-based system"* ]] \
  && ok "--skip-os-check is the escape hatch for exotic systems" || bad "escape hatch missing"

fake_os_release arch

head_ "11. no version numbers, and the summary is complete"

for args in "--version" "--help" "--show-config"; do
  out=$(run $args); rc=$?
  if grep -qE '[0-9]+\.[0-9]+\.[0-9]+' <<< "$out"; then
    bad "$args prints a version number (the user hates those)"
  else
    ok "$args prints no version number"
  fi
done

out=$(run --dry-run --yes --skip-net-check); rc=$?
[[ $out != *[0-9].[0-9].[0-9]* ]] && ok "a full run prints no version number anywhere" \
  || bad "version number leaked into a run"

fake_os_release arch; : > "$SB/mount.ntfs"; one_disk
out=$(run --yes); rc=$?
[[ $rc -eq 0 ]] || bad "clean run (rc=$rc)"
[[ $out == *"WHAT YOU HAVE NOW"* ]] && ok "the ending shows a tidy summary block" || bad "no summary block"
[[ $out == *"UNDO:"* && $out == *"--uninstall --purge"* ]] \
  && ok "  ...that names both the undo AND --purge" || bad "summary does not mention --purge"
[[ $out != *"Step 1"* && $out != *"Step 2"* ]] \
  && ok "  ...and no robot-speak like 'Step 1 checks' anywhere" || bad "still robot-speak"

head_ "11b. sudo without a terminal gets a usable message"

cat > "$SB/bin/sudo" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$SB/bin/sudo"
base_env
out=$(run --yes); rc=$?
[[ $rc -eq 3 && $out == *"no terminal here to type it in"* ]] \
  && ok "no terminal for the password -> says exactly that (rc=3)" \
  || bad "misleading sudo message (rc=$rc)"
[[ $out == *"ordinary terminal window"* ]] && ok "  ...and tells you to use a normal terminal" || bad "no usable advice"
cat > "$SB/bin/sudo" <<'EOF'
#!/usr/bin/env bash
[[ ${1:-} == "-v" ]] && exit 0
[[ ${1:-} == "-n" ]] && shift
export SUDO_RAN=1                  # back to the normal fake, for everything after
exec "$@"
EOF
chmod +x "$SB/bin/sudo"

head_ "11c. every dash style works for help and status"

for f in help -help --help -h h --h; do
  out=$(run "$f"); rc=$?
  [[ $rc -eq 0 && $out == *"USAGE"* ]] && ok "\"./install.sh $f\" shows the help" \
    || bad "\"./install.sh $f\" (rc=$rc)"
done

for f in status -status --status s -s --s; do
  base_env
  printf '[defaults]\nntfs_drivers=ntfs\n' > "$SB/etc/mount_options.conf"
  out=$(run "$f"); rc=$?
  [[ $rc -eq 0 ]] && ok "\"./install.sh $f\" reports the state (rc=0 when the fix is in)" \
    || bad "\"./install.sh $f\" (rc=$rc)"
done

# status must be honest when the fix is NOT there
base_env
out=$(run status); rc=$?
[[ $rc -eq 1 ]] && ok "status exits 1 when the fix is missing (usable in a script)" \
  || bad "status exit code when missing (rc=$rc)"
[[ $out == *"NOT installed"* ]] && ok "  ...and says NOT installed" || bad "status lies"
[[ $out == *"Arch will refuse"* ]] && ok "  ...and explains what that means" || bad "no consequence named"
[[ $out == *"./install.sh          (puts the fix in place)"* ]] \
  && ok "  ...and tells you the next step" || bad "no next step"
[[ $out == *"WHAT THIS MACHINE IS"* && $out == *"YOUR DISKS"* ]] \
  && ok "status is a readable report (sections, aligned)" || bad "status layout"

# a config file that exists but is not our fix must be called out
printf '[defaults]\nother_option=1\n' > "$SB/etc/mount_options.conf"
out=$(run status); rc=$?
[[ $rc -eq 1 && $out == *"does NOT say ntfs_drivers=ntfs"* ]] \
  && ok "status notices a config file that is not actually the fix" || bad "wrong-config detection"
[[ $out == *"not doing anything for you"* ]] && ok "  ...in plain words" || bad "unclear wrong-config wording"

# status must never stop to ask for a password
base_env
printf '[defaults]\nntfs_drivers=ntfs\n' > "$SB/etc/mount_options.conf"
out=$(run status); rc=$?
[[ $rc -eq 0 && $out != *"password:"* ]] \
  && ok "status never prompts for a password (no sudo -v, only sudo -n)" || bad "status waited for sudo"

# non-Arch: status must refuse to pretend
NP=$(no_pacman_path)
out=$(PATH="$NP" "$SB/fix.sh" status </dev/null 2>&1); rc=$?
[[ $rc -eq 2 && $out == *"not an Arch system"* ]] \
  && ok "status on a non-Arch system says so (rc=2)" || bad "status on non-Arch (rc=$rc)"

head_ "12. when there is simply nothing to do, it says so quietly"

base_env; : > "$SB/lsblk.out"      # no disk plugged in at all
out=$(run --yes); rc=$?
[[ $rc -eq 6 ]] && ok "no disk plugged in -> exit 6" || bad "no-disk exit code (rc=$rc)"
[[ $out == *"no NTFS disk to test yet"* ]] && ok "  ...said in plain words" || bad "no-disk wording"
[[ $out == *"already installed"* ]] \
  && ok "  ...and it says the fix stays installed" || bad "does not say the fix is in"
[[ $out != *"RATHER NOT RUN A SCRIPT"* ]] \
  && ok "  ...and does NOT dump the 30-line by-hand list at you" || bad "manual dump on a non-failure"
[[ $out != *"that did not work"* ]] \
  && ok "  ...and never calls it a failure" || bad "calls it a failure"

one_disk
export STUB_NET_OK=0
out=$(run --dry-run); rc=$?
export STUB_NET_OK=1
[[ $out == *"the script just did all of this for you"* ]] \
  && ok "when the by-hand list DOES appear, it says the script already did it" \
  || bad "the optional note is missing"

head_ "13. the big reveal follows the disk's own name"

# Pull just the pretty helpers out of the script (no main, no traps, no
# side effects) so the reveal can be checked directly instead of through a
# fake terminal. If the extraction ever breaks, the calls below fail loudly.
sed -n '/^declare -A FONT=(/,/^)/p;/^big_text()/,/^}/p;/^font_safe()/,/^}/p;/^box_text()/,/^}/p;/^reveal_name()/,/^}/p;/^repeat_char()/,/^}/p;/^note()/,/^}/p;/^spinner_pause()/,/^}/p' \
  "$SRC" > "$SB/pretty.sh"
# shellcheck source=/dev/null
source "$SB/pretty.sh"
# Read by the pretty.sh sourced just above: it was cut out of install.sh at run
# time, so the linter cannot see who uses them. Exported for that reason - the
# sandbox copy of the script sets its own anyway.
export C_B='' C_D='' C_0=''
export ANIM=1 TTY=/dev/null SPIN_PID=""    # keep the box; no spinner to stop

font_safe "EPRAHEMI"      && ok "a plain name can be drawn in big letters" || bad "font_safe rejected EPRAHEMI"
font_safe "500GB"         && ok "  ...letters and digits"                  || bad "font_safe rejected 500GB"
font_safe "my disk_1.0"   && ok "  ...lowercase, a space, and marks"       || bad "font_safe rejected lowercase/marks"
font_safe "BACKUP (2)"    && bad "brackets must NOT be drawn big"          || ok "brackets fall back instead of ? blocks"
font_safe "写真"           && bad "other scripts must NOT be drawn big"     || ok "other languages fall back too"
font_safe "THIRTEENCHARS" && bad "13 characters must NOT be drawn big"     || ok "a name longer than 12 falls back"
font_safe ""              && bad "an empty name must NOT be drawn big"     || ok "an empty name falls back"

out=$(reveal_name "EPRAHEMI")
[[ $out == *"████"* ]] \
  && ok "the reveal draws the disk's OWN name in big letters" || bad "no big letters drawn"

out=$(reveal_name "写真")
[[ $out == *"╭──────╮"* && $out == *"│ 写真 │"* ]] \
  && ok "  ...a name the font cannot draw gets a clean, lined-up box" || bad "box fallback wrong"

out=$(reveal_name "50% OFF")
[[ $out == *"50% OFF"* ]] \
  && ok "  ...and a % in the name cannot break the box" || bad "a percent broke the box"

out=$(reveal_name "")
[[ $(printf '%s\n' "$out" | grep -c '█') -eq 5 ]] \
  && ok "  ...a disk with no name gets big READY" || bad "no READY fallback"

# The titled note box (used when a config is already there and gets backed up).
# Two things must hold: it goes to stderr (never into the captured answer), and
# its top and bottom borders line up.
box=$(note "keeping a backup" "$SB/etc/mount_options.conf" \
  "is already there. I am keeping your old one at" \
  "$SB/etc/mount_options.conf.bak" 2>&1 >/dev/null)
body=${box#$'\n'}
top=${body%%$'\n'*}
bottom=${body##*$'\n'}
[[ ${#top} -eq ${#bottom} ]] \
  && ok "the backup note is a box whose edges line up" || bad "note box edges differ (${#top} vs ${#bottom})"
[[ $box == *"keeping a backup"* && $box == *".bak"* ]] \
  && ok "  ...and it says what happened, in full paths" || bad "note text missing"
out=$(note "keeping a backup" "x" 2>/dev/null)
[[ -z $out ]] \
  && ok "  ...and it never leaks into the answer on stdout" || bad "note leaked to stdout"
err=$(ANIM=0 note "keeping a backup" "x" 2>&1 >/dev/null)
[[ $err != *"┌"* && $err == *"!!"* ]] \
  && ok "  ...and in a log it collapses to one clean line" || bad "note stayed boxed in a log"

# ============================================================================
head_ "14. renaming an external disk (--rename)"

# --- the USB parent lookup (a real bug this caught) -------------------------
# lsblk puts TRAN and RM on the WHOLE DISK, never on the partition. If the code
# only looked at the partition it would see "internal disk" and refuse a real
# USB disk, so prove it looks at the parent.
base_env; fake_os_release arch; label_reset; usb_ntfs
out=$(printf 'X\n' | "$SB/fix.sh" --rename --yes 2>&1)
[[ $out == *"/dev/sdb1"* ]] \
  && ok "a USB disk is found even though TRAN sits on the parent disk" || bad "parent lookup failed"
out=$(run --list)
line=$(printf '%s\n' "$out" | grep '/dev/sdb1')
[[ $line == *"yes"* ]] \
  && ok "--list marks that disk as USB too (it used to say no)" || bad "--list USB column wrong: $line"

# --- the happy path ---------------------------------------------------------
base_env; fake_os_release arch; label_reset; usb_ntfs
out=$(printf 'MEMORIES\n' | "$SB/fix.sh" --rename --yes 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "--rename renames a single external disk (rc=0)" || bad "--rename (rc=$rc)"
[[ $out == *"MEMORIES is the new name of /dev/sdb1"* ]] \
  && ok "  ...and says what the disk is called now" || bad "no new-name line"
[[ $(cat "$SB/label.out") == "MEMORIES" ]] && ok "  ...and the name was really written" || bad "name not written"
grep -q '^rehearse' "$SB/label_calls" && ok "  ...after rehearsing first (ntfslabel -n)" || bad "no rehearsal"
r_line=$(grep -n '^rehearse' "$SB/label_calls" | head -1 | cut -d: -f1)
w_line=$(grep -n '^write' "$SB/label_calls" | head -1 | cut -d: -f1)
[[ -n $r_line && -n $w_line && $r_line -lt $w_line ]] \
  && ok "  ...and the rehearsal really came BEFORE the write" || bad "write happened before the rehearsal"
grep -q '^unmount /dev/sdb1' "$SB/label_calls" \
  && ok "  ...closing the disk before touching it" || bad "the disk was not unmounted first"
[[ $out == *"WHAT YOU HAVE NOW"* ]] && ok "  ...and ends with the tidy summary" || bad "no summary"
[[ $out == *"lsblk -o NAME,SIZE,LABEL"* ]] && ok "  ...showing how to see the names" || bad "no next step"
[[ $out != *"0.4"* ]] && ok "  ...with no version number anywhere" || bad "a version number leaked"

# --- names that must be refused ---------------------------------------------
label_reset
out=$(printf 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA\n' | "$SB/fix.sh" --rename --yes 2>&1); rc=$?
[[ $rc -eq 6 && $out == *"Windows only shows the first"* && $out == *"32 characters of an NTFS name"* ]] \
  && ok "a 33-character NTFS name is refused, with the reason (rc=6)" || bad "over-long name (rc=$rc)"
[[ ! -s $SB/label_calls ]] && ok "  ...and nothing was written" || bad "wrote despite refusing"

label_reset
out=$(printf 'A/B\n' | "$SB/fix.sh" --rename --yes 2>&1); rc=$?
[[ $rc -eq 6 && $out == *"cannot contain /"* ]] \
  && ok "a name with a / in it is refused" || bad "slash name (rc=$rc)"

label_reset
out=$(printf '\n' | "$SB/fix.sh" --rename --yes 2>&1); rc=$?
[[ $rc -eq 6 && $out == *"no name was typed"* ]] \
  && ok "an empty name changes nothing (rc=6)" || bad "empty name (rc=$rc)"

label_reset
out=$(printf '.\n' | "$SB/fix.sh" --rename --yes 2>&1); rc=$?
[[ $rc -eq 6 && $out == *"here"* ]] \
  && ok "a name of \".\" is refused (it would break the mount folder)" || bad "dot name (rc=$rc)"

# --- two disks: it has to ask -----------------------------------------------
base_env; fake_os_release arch; label_reset; usb_two
out=$(printf 'ARCHIVE\n2\n' | "$SB/fix.sh" --rename --yes 2>&1); rc=$?
[[ $rc -eq 0 ]] && ok "with two external disks it asks which one" || bad "two-disk rename (rc=$rc)"
[[ $out == *"exfat"* && $out == *"BACKUP"* ]] \
  && ok "  ...and the table shows each disk's filesystem and name" || bad "table missing detail"
[[ $(cat "$SB/label.out") == "ARCHIVE" ]] && ok "  ...and renames the one you picked (the 2nd)" || bad "wrong disk renamed"
grep -q '^write(exfatlabel) /dev/sdc1 ARCHIVE' "$SB/label_calls" \
  && ok "  ...using the tool that fits that filesystem (exfatlabel)" || bad "wrong tool used"

label_reset
out=$(printf 'DIRECT\n' | "$SB/fix.sh" --rename --yes --disk 2 2>&1); rc=$?
[[ $rc -eq 0 && $(cat "$SB/label.out") == "DIRECT" ]] \
  && ok "--disk 2 picks the second disk without asking" || bad "--disk in rename (rc=$rc)"

out=$(printf 'X\n' | "$SB/fix.sh" --rename --yes --disk 9 2>&1); rc=$?
[[ $rc -eq 6 && $out == *"between 1 and 2"* ]] \
  && ok "--disk 9 is refused, nothing is guessed" || bad "bad --disk in rename (rc=$rc)"

# --- when there is nothing to offer ----------------------------------------
base_env; fake_os_release arch; label_reset; usb_only
out=$(printf 'X\n' | "$SB/fix.sh" --rename --yes 2>&1); rc=$?
[[ $rc -eq 6 && $out == *"cannot see a removable disk"* ]] \
  && ok "no removable disk -> exit 6, quietly" || bad "no removable disk (rc=$rc)"
[[ ! -s $SB/label_calls ]] && ok "  ...and no label tool was called" || bad "called a tool with no disk"

base_env; fake_os_release arch; label_reset; usb_btrfs
out=$(printf 'X\n' | "$SB/fix.sh" --rename --yes 2>&1); rc=$?
[[ $rc -eq 6 ]] && ok "a removable disk with btrfs is not offered (no label tool here)" \
  || bad "btrfs was offered (rc=$rc)"

base_env; fake_os_release arch; label_reset; usb_system
out=$(printf 'ROOT\n' | "$SB/fix.sh" --rename --yes 2>&1); rc=$?
[[ $rc -eq 6 && $out == *"the disk this system runs from"* ]] \
  && ok "the disk the system runs from is refused, even when it is USB" || bad "protected disk (rc=$rc)"
[[ $(cat "$SB/label.out") == "500GB" ]] && ok "  ...and its name was not touched" || bad "system disk was renamed!"

# --- missing tool, refusing tool, busy disk ---------------------------------
base_env; fake_os_release arch; label_reset; usb_ntfs
# The tool has to be missing FOR REAL here. Do not just move the stub away:
# PATH also holds the real /usr/bin, and this machine really does have
# ntfsprogs installed - the script would then run the real ntfslabel against a
# real disk. Instead, build a PATH made of the stubs (plus the plain tools)
# with ntfslabel left out.
np=$(path_without ntfslabel)
out=$(printf 'X\n' | PATH="$np" "$SB/fix.sh" --rename --yes 2>&1); rc=$?
[[ $rc -eq 5 && $out == *"pacman -S ntfsprogs"* ]] \
  && ok "a missing label tool names the exact package (rc=5)" || bad "missing tool (rc=$rc)"

base_env; fake_os_release arch; label_reset; usb_ntfs
export STUB_LABEL_FAIL=1
out=$(printf 'X\n' | "$SB/fix.sh" --rename --yes 2>&1); rc=$?
export STUB_LABEL_FAIL=0
[[ $rc -eq 1 && $out == *"that did not work"* ]] \
  && ok "a tool that refuses is reported, never hidden (rc=1)" || bad "tool refusal (rc=$rc)"
[[ $out == *"RENAME IT BY HAND"* ]] && ok "  ...with the by-hand steps" || bad "no by-hand list"
[[ $(cat "$SB/label.out") == "500GB" ]] && ok "  ...and the old name is still there" || bad "name changed anyway"
grep -q '^mount /dev/sdb1' "$SB/label_calls" \
  && ok "  ...and the disk is opened again, not left closed" || bad "the disk was left closed after a failure"

# The user hit this one for real (2026-10-02): Windows left the volume
# "scheduled for check", so ntfslabel refuses the rehearsal. His disk was also
# left CLOSED by the old code, because die_rename exited without reopening it.
base_env; fake_os_release arch; label_reset; usb_ntfs
export STUB_REHEARSE_MSG="Volume is scheduled for check.
Please boot into Windows TWICE, or use the 'force' option."
out=$(printf 'I LOVE MY MUM\n' | "$SB/fix.sh" --rename --yes 2>&1); rc=$?
export STUB_REHEARSE_MSG=""
[[ $rc -eq 1 ]] && ok "a volume waiting for a Windows check is refused (rc=1)" || bad "waiting-for-check (rc=$rc)"
[[ $out == *"WINDOWS CHECK"* && $out == *"chkdsk"* ]] \
  && ok "  ...and the reason and the fix are spelled out, not guessed" || bad "no clear advice"
[[ $out == *"Do NOT add --force"* ]] && ok "  ...and it warns against --force" || bad "force warning missing"
[[ $out == *"opened /dev/sdb1 again"* ]] \
  && ok "  ...and the disk is opened again (his run left it closed)" || bad "disk left closed"
[[ $(grep -c '^write' "$SB/label_calls") -eq 0 ]] && ok "  ...and nothing was written" || bad "wrote after refusing"

# --- the no-Windows answer: let the script clear the flag ---------------------
# Verified for real on a throwaway image (2026-10-02): plain ntfsfix SETS this
# flag, ntfsfix -d clears it, and ntfslabel then works. So the script may offer.
CHECK_MSG="Volume is scheduled for check.
Please boot into Windows TWICE, or use the 'force' option."

base_env; fake_os_release arch; label_reset; usb_ntfs
export STUB_REHEARSE_MSG="$CHECK_MSG"
out=$(printf 'I LOVE MY MUM\n' | "$SB/fix.sh" --rename --yes --clear-check-flag 2>&1); rc=$?
export STUB_REHEARSE_MSG=""
[[ $rc -eq 0 && $(cat "$SB/label.out") == "I LOVE MY MUM" ]] \
  && ok "--clear-check-flag: a no-Windows user can still rename" || bad "clear-check-flag (rc=$rc)"
grep -q '^ntfsfix -d /dev/sdb1$' "$SB/label_calls" \
  && ok "  ...clearing the flag with ntfsfix -d" || bad "ntfsfix -d never called"
[[ $(grep -c '^rehearse' "$SB/label_calls") -eq 2 ]] \
  && ok "  ...then rehearsing again, before writing" || bad "no second rehearsal"
grep -q '^write(ntfslabel) /dev/sdb1 I LOVE MY MUM$' "$SB/label_calls" \
  && ok "  ...and only then writing the name" || bad "name not written"

base_env; fake_os_release arch; label_reset; usb_ntfs
export STUB_REHEARSE_MSG="$CHECK_MSG"
out=$(printf 'X\n' | "$SB/fix.sh" --rename --yes 2>&1); rc=$?
export STUB_REHEARSE_MSG=""
[[ $rc -eq 1 && $out == *"--clear-check-flag"* ]] \
  && ok "--yes does NOT secretly repair a disk; it points at --clear-check-flag" || bad "--yes repaired without consent (rc=$rc)"
[[ $(grep -c '^ntfsfix' "$SB/label_calls") -eq 0 ]] \
  && ok "  ...and ntfsfix was never called" || bad "ntfsfix ran without consent"

base_env; fake_os_release arch; label_reset; usb_ntfs
export STUB_REHEARSE_MSG="$CHECK_MSG" STUB_NTFSFIX_FAIL=1
out=$(printf 'X\n' | "$SB/fix.sh" --rename --yes --clear-check-flag 2>&1); rc=$?
export STUB_REHEARSE_MSG="" STUB_NTFSFIX_FAIL=0
[[ $rc -eq 1 && $out == *"needs a Windows check"* ]] \
  && ok "if Linux cannot fix the volume, it says so and stops" || bad "ntfsfix failure (rc=$rc)"
[[ $(cat "$SB/label.out") == "500GB" ]] && ok "  ...and the name is untouched" || bad "name changed anyway"
grep -q '^mount /dev/sdb1$' "$SB/label_calls" && ok "  ...and the disk is put back" || bad "disk left closed"

base_env; fake_os_release arch; label_reset; usb_ntfs
export STUB_REHEARSE_MSG="$CHECK_MSG"
out=$(printf 'X\n' | env PATH="$(path_without ntfsfix)" "$SB/fix.sh" --rename --yes --clear-check-flag 2>&1); rc=$?
export STUB_REHEARSE_MSG=""
[[ $rc -eq 1 && $out == *"not installed here"* ]] \
  && ok "if ntfsfix is missing, it says so instead of pretending" || bad "missing ntfsfix (rc=$rc)"

base_env; fake_os_release arch; label_reset; usb_ntfs
out=$(printf 'PLAIN\n' | "$SB/fix.sh" --rename --yes --clear-check-flag 2>&1); rc=$?
[[ $rc -eq 0 && $(cat "$SB/label.out") == "PLAIN" ]] \
  && ok "--clear-check-flag on a healthy disk changes nothing extra" || bad "healthy disk with the flag (rc=$rc)"
[[ $(grep -c '^ntfsfix' "$SB/label_calls") -eq 0 ]] \
  && ok "  ...and ntfsfix is never called for nothing" || bad "ntfsfix ran for nothing"

base_env; fake_os_release arch; label_reset; usb_ntfs
export STUB_REHEARSE_MSG="$CHECK_MSG"
out=$(printf 'X\n' | "$SB/fix.sh" --rename --yes --clear-check-flag --dry-run 2>&1); rc=$?
export STUB_REHEARSE_MSG=""
[[ $rc -eq 0 && $out == *"nothing was changed"* ]] && ok "dry-run still stops before any repair" || bad "dry-run with the flag (rc=$rc)"
[[ $(grep -c '^ntfsfix' "$SB/label_calls") -eq 0 ]] \
  && ok "  ...and the dry-run called no tool at all" || bad "dry-run called something"

base_env; fake_os_release arch; label_reset; usb_ntfs
export STUB_WRITE_FAIL=1
out=$(printf 'X\n' | "$SB/fix.sh" --rename --yes 2>&1); rc=$?
export STUB_WRITE_FAIL=0
[[ $rc -eq 1 && $out == *"volume is dirty"* ]] \
  && ok "if the write itself fails, the tool's own message is shown" || bad "write failure (rc=$rc)"
[[ $(cat "$SB/label.out") == "500GB" ]] && ok "  ...and the old name survives" || bad "name changed anyway"

base_env; fake_os_release arch; label_reset; usb_ntfs
export STUB_UNMOUNT_FAIL=1 STUB_UMOUNT_FAIL=1
out=$(printf 'X\n' | "$SB/fix.sh" --rename --yes 2>&1); rc=$?
export STUB_UNMOUNT_FAIL=0 STUB_UMOUNT_FAIL=0
[[ $rc -eq 1 && $out == *"still has a file"* ]] \
  && ok "a disk that cannot be unmounted is left alone (rc=1)" || bad "unmount failure (rc=$rc)"
[[ $(grep -c '^write' "$SB/label_calls") -eq 0 ]] \
  && ok "  ...and no name was written to a busy disk" || bad "touched a busy disk"

# --- the rehearsal ----------------------------------------------------------
base_env; fake_os_release arch; label_reset; usb_ntfs
out=$(printf 'TRIAL\n' | "$SB/fix.sh" --rename --dry-run --yes 2>&1); rc=$?
[[ $rc -eq 0 && $out == *"[dry-run] would run:"* ]] \
  && ok "--dry-run shows the exact commands it would run" || bad "rename dry-run (rc=$rc)"
[[ ! -s $SB/label_calls ]] && ok "  ...and calls no tool at all" || bad "the dry run ran a tool"
[[ $(cat "$SB/label.out") == "500GB" ]] && ok "  ...and the name is untouched" || bad "the dry run renamed the disk"
[[ $out == *"udisksctl unmount"* ]] && ok "  ...including the unmount, since the disk was open" || bad "dry run hid the unmount"

# --- aliases and the argument form ------------------------------------------
for a in --label --name -rename rename r; do
  base_env; fake_os_release arch; label_reset; usb_ntfs
  out=$(printf 'ALIAS\n' | "$SB/fix.sh" "$a" --yes 2>&1); rc=$?
  [[ $rc -eq 0 && $(cat "$SB/label.out") == "ALIAS" ]] \
    && ok "\"$a\" works the same as --rename" || bad "\"$a\" (rc=$rc)"
done

base_env; fake_os_release arch; label_reset; usb_ntfs
out=$("$SB/fix.sh" --rename DIRECT --yes </dev/null 2>&1); rc=$?
[[ $rc -eq 0 && $(cat "$SB/label.out") == "DIRECT" ]] \
  && ok "--rename NAME takes the name straight from the command line" || bad "--rename NAME (rc=$rc)"

base_env; fake_os_release arch; label_reset; usb_ntfs
out=$("$SB/fix.sh" --rename=DIRECT2 --yes </dev/null 2>&1); rc=$?
[[ $rc -eq 0 && $(cat "$SB/label.out") == "DIRECT2" ]] \
  && ok "--rename=NAME works too" || bad "--rename=NAME (rc=$rc)"

# --- one more legal name, and a limit that belongs to the filesystem --------
base_env; fake_os_release arch; label_reset; usb_ntfs
out=$(printf 'THIRTEENCHARS\n' | "$SB/fix.sh" --rename --yes 2>&1); rc=$?
[[ $rc -eq 0 && $(cat "$SB/label.out") == "THIRTEENCHARS" ]] \
  && ok "a 13-character NTFS name is fine (the limit is 32)" || bad "13-char ntfs name (rc=$rc)"

base_env; fake_os_release arch; label_reset; usb_two
out=$(printf 'TWELVECHARSX\n' | "$SB/fix.sh" --rename --yes --disk 2 2>&1); rc=$?
[[ $rc -eq 6 && $out == *"at most 11"* ]] \
  && ok "a 12-character exFAT name is refused with its own limit (rc=6)" || bad "exfat limit (rc=$rc)"

# --- the read-back must not cry wolf ----------------------------------------
# Reading a raw block device needs root just like writing one does (it belongs
# to root:disk). Before this was fixed, the write worked but the check said
# "could not read the name back" - a false alarm that made a good rename look
# like a failure. These tests pin that down for good.
base_env; fake_os_release arch; label_reset; usb_ntfs
export STUB_LABEL_READ_NEEDS_ROOT=1
out=$(printf 'SIXTEENCHARS\n' | "$SB/fix.sh" --rename --yes 2>&1); rc=$?
[[ $rc -eq 0 && $out == *"the disk now says: SIXTEENCHARS"* ]] \
  && ok "the read-back asks for root too, so a good rename is confirmed" || bad "false alarm on read-back (rc=$rc)"
[[ $out != *"could not read the name back"* ]] \
  && ok "  ...and it does not cry wolf when a plain user could not read" || bad "still crying wolf"

base_env; fake_os_release arch; label_reset; usb_ntfs
export STUB_LABEL_READ_NEEDS_ROOT=1 STUB_LABEL_READ_FAIL=1
out=$(printf 'SEVENTEEN\n' | "$SB/fix.sh" --rename --yes 2>&1); rc=$?
[[ $rc -eq 0 && $out == *"the disk now says: SEVENTEEN"* ]] \
  && ok "if the label tool stays silent, lsblk is a second witness (no root)" || bad "no fallback witness (rc=$rc)"

base_env; fake_os_release arch; label_reset; usb_ntfs
export STUB_LABEL_READ_FAIL=1 STUB_LSBLK_LABEL_FAIL=1
out=$(printf 'EIGHTEEN\n' | "$SB/fix.sh" --rename --yes 2>&1); rc=$?
[[ $rc -eq 1 && $out == *"could not be read back from /dev/sdb1"* && $out == *"sudo ntfslabel /dev/sdb1"* ]] \
  && ok "if nobody can read the name back, it still warns - with sudo in the hint" || bad "silent doubt (rc=$rc)"

# --- it must be findable ----------------------------------------------------
base_env; fake_os_release arch
out=$(run --help)
[[ $out == *"--rename"* ]] && ok "the help lists --rename" || bad "help does not mention --rename"
[[ $out == *"--clear-check-flag"* ]] && ok "  ...and --clear-check-flag for the no-Windows case" || bad "help does not mention --clear-check-flag"
[[ $out == *"removable"* ]] && ok "  ...and says only external disks are ever offered" || bad "help hides the rule"

base_env; fake_os_release arch; one_disk; : > "$SB/mount.ntfs"
out=$(run --yes)
[[ $out == *"nicer name:"* && $out == *"--rename"* ]] \
  && ok "the install summary points at --rename" || bad "no --rename hint in the summary"

# --- the plain fix must never repair anything --------------------------------
# The install path only installs packages and writes one config file. Clearing
# the "scheduled for check" flag is a REPAIR: it belongs to --rename alone, and
# even there it needs a yes of its own. This pins that rule down.
base_env; fake_os_release arch; one_disk; : > "$SB/mount.ntfs"
export STUB_REHEARSE_MSG="Volume is scheduled for check.
Please boot into Windows TWICE, or use the 'force' option."
out=$(run --yes); rc=$?
export STUB_REHEARSE_MSG=""
[[ $rc -eq 0 && $out == *"WHAT YOU HAVE NOW"* ]] \
  && ok "the plain fix finishes, even with a check flag up on the disk" || bad "plain fix with the flag (rc=$rc)"
[[ $(grep -c '^ntfsfix' "$SB/label_calls") -eq 0 ]] \
  && ok "  ...and never runs ntfsfix - the fix is a config choice, not a repair" || bad "the install path repaired the disk!"
[[ $(grep -c '^rehearse\|^write' "$SB/label_calls") -eq 0 ]] \
  && ok "  ...and never touches the disk's name either (that is --rename's job)" || bad "the install path wrote to a filesystem"

# ===================== 15. looking at a disk, and the one repair ==============
# --check-disk only reads; --first-aid is the one repair, and it must ask. The
# rule that matters most here is the same one section 14 pins down: nothing that
# is not explicitly asked for may write to a filesystem.
head_ "15. looking at a disk (--check-disk), and the one repair (--first-aid)"

# --- a dirty disk ------------------------------------------------------------
base_env; fake_os_release arch; label_reset; usb_ntfs_closed; : > "$SB/mount.ntfs"
export STUB_NTFSINFO_DIRTY=1
out=$(run --check-disk); rc=$?
export STUB_NTFSINFO_DIRTY=0
[[ $rc -eq 1 ]] && ok "--check-disk: a dirty disk is reported as a problem (rc=1)" || bad "dirty (rc=$rc)"
[[ $out == *"waiting for a WINDOWS CHECK"* ]] && ok "  ...in plain words, naming the check flag" || bad "no dirty verdict"
[[ $out == *"--first-aid"* ]] && ok "  ...pointing at the one repair" || bad "no next step"
[[ $out == *"chkdsk X: /f /x"* ]] && ok "  ...and at Windows chkdsk as the other route" || bad "no chkdsk hint"
grep -q '^ntfsinfo -m /dev/sdb1$' "$SB/label_calls" \
  && ok "  ...after READING the volume with ntfsinfo" || bad "ntfsinfo never ran"
[[ $(grep -c '^ntfsfix' "$SB/label_calls") -eq 0 && $(grep -c '^write' "$SB/label_calls") -eq 0 ]] \
  && ok "  ...and it wrote NOTHING: no repair, no name" || bad "check-disk wrote to the disk!"

# --- a healthy disk ----------------------------------------------------------
base_env; fake_os_release arch; label_reset; usb_ntfs_closed; : > "$SB/mount.ntfs"
out=$(run --check-disk); rc=$?
[[ $rc -eq 0 && $out == *"healthy"* && $out == *"nothing to repair"* ]] \
  && ok "--check-disk: a healthy disk is a clean report (rc=0)" || bad "healthy (rc=$rc)"
[[ $(grep -c '^ntfsfix' "$SB/label_calls") -eq 0 ]] && ok "  ...and still writes nothing" || bad "wrote something"

# --- a really damaged disk ---------------------------------------------------
base_env; fake_os_release arch; label_reset; usb_ntfs_closed; : > "$SB/mount.ntfs"
export STUB_NTFSINFO_DAMAGED=1
out=$(run --check-disk); rc=$?
export STUB_NTFSINFO_DAMAGED=0
[[ $rc -eq 1 && $out == *"structure is damaged"* && $out == *"chkdsk X: /f /x"* ]] \
  && ok "--check-disk: real damage is called damage, and chkdsk is named" || bad "damage (rc=$rc)"
[[ $out == *"cannot read it at all"* ]] \
  && ok "  ...and it never pretends files can be copied off" || bad "a false promise in the damage case"

# --- a disk that opened read-only -------------------------------------------
base_env; fake_os_release arch; label_reset; usb_ntfs; : > "$SB/mount.ntfs"
export STUB_OPTIONS="ro,nosuid,nodev"
out=$(run --check-disk); rc=$?
export STUB_OPTIONS="rw,nosuid,nodev,relatime"
[[ $rc -eq 1 && $out == *"READ-ONLY"* ]] && ok "--check-disk: a read-only mount is a problem (rc=1)" || bad "ro (rc=$rc)"
[[ $out == *"powercfg /h off"* ]] && ok "  ...and shows the Fast Startup / hibernation route" || bad "no hibernation hint"
[[ $(grep -c '^ntfsinfo' "$SB/label_calls") -eq 0 ]] \
  && ok "  ...without probing a mounted volume (the ntfs tools refuse those)" || bad "probed a mounted volume"

# --- no ntfsinfo, and the root lesson ---------------------------------------
base_env; fake_os_release arch; label_reset; usb_ntfs_closed; : > "$SB/mount.ntfs"
out=$(env PATH="$(path_without ntfsinfo)" "$SB/fix.sh" --check-disk </dev/null 2>&1); rc=$?
[[ $rc -eq 1 && $out == *"ntfsinfo is not installed"* && $out == *"sudo pacman -S ntfsprogs"* ]] \
  && ok "--check-disk: missing ntfsinfo is said out loud, with the package" || bad "missing ntfsinfo (rc=$rc)"

base_env; fake_os_release arch; label_reset; usb_ntfs_closed; : > "$SB/mount.ntfs"
export STUB_NTFSINFO_DIRTY=1 STUB_NTFSINFO_NEEDS_ROOT=1
out=$(run --check-disk); rc=$?
export STUB_NTFSINFO_DIRTY=0 STUB_NTFSINFO_NEEDS_ROOT=0
[[ $rc -eq 1 && $out == *"waiting for a WINDOWS CHECK"* ]] \
  && ok "--check-disk: reads the raw device AS ROOT (the permission lesson)" || bad "read without root (rc=$rc)"

# --- which disk --------------------------------------------------------------
base_env; fake_os_release arch; label_reset; usb_only
out=$(run --check-disk); rc=$?
[[ $rc -eq 6 && $out == *"cannot see an external NTFS disk"* ]] \
  && ok "--check-disk: no external disk -> a clear stop, rc=6" || bad "no-disk (rc=$rc)"

base_env; fake_os_release arch; label_reset; usb_ntfs_closed
export STUB_SOURCE=/dev/sdb1
out=$(run --check-disk); rc=$?
export STUB_SOURCE=/dev/sda5
[[ $rc -eq 6 && $out == *"EXTERNAL disks"* ]] \
  && ok "--check-disk: refuses the disk the system runs from" || bad "protected disk (rc=$rc)"

base_env; fake_os_release arch; label_reset; usb_ntfs_two
out=$(run --check-disk); rc=$?
[[ $rc -eq 6 && $out == *"more than one external NTFS disk"* ]] \
  && ok "--check-disk: two disks, no terminal -> asks for --disk instead of guessing" || bad "two disks (rc=$rc)"
out=$(run --check-disk --disk 2); rc=$?
grep -q '^ntfsinfo -m /dev/sdc1$' "$SB/label_calls" \
  && ok "  ...and --disk 2 looks at the second one" || bad "--disk 2 picked the wrong disk"
out=$(run --check-disk --disk 9); rc=$?
[[ $rc -eq 6 && $out == *"between 1 and 2"* ]] && ok "  ...while --disk 9 is refused" || bad "--disk 9 (rc=$rc)"

# --- the one repair: the happy path -----------------------------------------
base_env; fake_os_release arch; label_reset; usb_ntfs_closed; : > "$SB/mount.ntfs"
export STUB_NTFSINFO_DIRTY=1
out=$(run --first-aid --yes); rc=$?
export STUB_NTFSINFO_DIRTY=0
[[ $rc -eq 0 ]] && ok "--first-aid: clears the flag on a dirty disk (rc=0)" || bad "first-aid (rc=$rc)"
grep -q '^ntfsfix -n /dev/sdb1$' "$SB/label_calls" && ok "  ...rehearsing first with ntfsfix -n" || bad "no rehearsal"
grep -q '^ntfsfix -d /dev/sdb1$' "$SB/label_calls" && ok "  ...then doing the repair with ntfsfix -d" || bad "no ntfsfix -d"
n_line=$(grep -n '^ntfsfix -n ' "$SB/label_calls" | head -1 | cut -d: -f1)
d_line=$(grep -n '^ntfsfix -d ' "$SB/label_calls" | head -1 | cut -d: -f1)
[[ -n $n_line && -n $d_line && $n_line -lt $d_line ]] \
  && ok "  ...and the rehearsal really came FIRST" || bad "repair before the rehearsal"
[[ $out == *"the flag is gone"* ]] && ok "  ...then proving it worked, read-only" || bad "no proof of success"
[[ $out == *"WHAT YOU HAVE NOW"* ]] && ok "  ...and ending with the tidy summary" || bad "no summary"
[[ $out != *[0-9].[0-9].[0-9]* ]] && ok "  ...with no version number anywhere" || bad "a version number leaked"

# --- a healthy disk is never written to --------------------------------------
base_env; fake_os_release arch; label_reset; usb_ntfs_closed; : > "$SB/mount.ntfs"
out=$(run --first-aid --yes); rc=$?
[[ $rc -eq 0 && $out == *"nothing to repair"* ]] && ok "--first-aid: a healthy disk is left alone (rc=0)" || bad "healthy (rc=$rc)"
[[ $(grep -c '^ntfsfix' "$SB/label_calls") -eq 0 ]] \
  && ok "  ...and no repair tool is run at all" || bad "a repair ran on a healthy disk"

# --- no consent, no repair ---------------------------------------------------
base_env; fake_os_release arch; label_reset; usb_ntfs_closed; : > "$SB/mount.ntfs"
export STUB_NTFSINFO_DIRTY=1
out=$(run --first-aid); rc=$?
export STUB_NTFSINFO_DIRTY=0
[[ $rc -eq 1 && $out == *"nothing was changed"* ]] \
  && ok "--first-aid: no terminal and no --yes -> it asks, then stops (rc=1)" || bad "unattended repair (rc=$rc)"
[[ $(grep -c '^ntfsfix -d' "$SB/label_calls") -eq 0 ]] \
  && ok "  ...and never writes without the yes" || bad "repaired without consent"

# --- a disk that already works ----------------------------------------------
base_env; fake_os_release arch; label_reset; usb_ntfs; : > "$SB/mount.ntfs"
export STUB_NTFSINFO_DIRTY=1 STUB_OPTIONS="rw,nosuid,nodev,relatime"
out=$(run --first-aid --yes); rc=$?
export STUB_NTFSINFO_DIRTY=0
[[ $rc -eq 0 && $out == *"already opens READ-WRITE"* ]] \
  && ok "--first-aid: a disk that already works is never written to" || bad "touched a working disk (rc=$rc)"
[[ $(grep -c '^ntfsfix\|^unmount' "$SB/label_calls") -eq 0 ]] \
  && ok "  ...not even unmounted or probed" || bad "fiddled with a working disk"

# --- read-only: close it, repair it, give it back ----------------------------
base_env; fake_os_release arch; label_reset; usb_ntfs; : > "$SB/mount.ntfs"
export STUB_NTFSINFO_DIRTY=1 STUB_OPTIONS="ro,nosuid,nodev"
out=$(run --first-aid --yes); rc=$?
export STUB_NTFSINFO_DIRTY=0 STUB_OPTIONS="rw,nosuid,nodev,relatime"
[[ $rc -eq 0 ]] && ok "--first-aid: a read-only disk is closed, repaired, reopened" || bad "ro first-aid (rc=$rc)"
grep -q '^unmount /dev/sdb1$' "$SB/label_calls" && ok "  ...it was closed first" || bad "not unmounted"
grep -q '^mount /dev/sdb1$' "$SB/label_calls" && ok "  ...and opened again afterwards" || bad "not reopened"

# --- when Linux cannot fix it ------------------------------------------------
base_env; fake_os_release arch; label_reset; usb_ntfs_closed; : > "$SB/mount.ntfs"
export STUB_NTFSINFO_DIRTY=1 STUB_NTFSFIX_FAIL=1
out=$(run --first-aid --yes); rc=$?
export STUB_NTFSINFO_DIRTY=0 STUB_NTFSFIX_FAIL=0
[[ $rc -eq 1 && $out == *"needs a real Windows check"* ]] \
  && ok "--first-aid: if Linux cannot fix it, it says so and stops (rc=1)" || bad "failed repair (rc=$rc)"

# --- real damage is a loud warning first -------------------------------------
base_env; fake_os_release arch; label_reset; usb_ntfs_closed; : > "$SB/mount.ntfs"
export STUB_NTFSINFO_DAMAGED=1
out=$(run --first-aid --yes); rc=$?
export STUB_NTFSINFO_DAMAGED=0
[[ $out == *"STOP AND THINK FIRST"* && $out == *"chkdsk X: /f /x"* ]] \
  && ok "--first-aid: real damage is a loud warning BEFORE anything is written" || bad "no damage warning"
grep -q '^ntfsfix -d /dev/sdb1$' "$SB/label_calls" \
  && ok "  ...and with an explicit yes it still tries (that is the ask)" || bad "never tried at all"

# --- a disk that drops off the bus -------------------------------------------
base_env; fake_os_release arch; label_reset; usb_ntfs_closed; : > "$SB/mount.ntfs"
export STUB_HARDWARE_FAIL=1
out=$(run --first-aid --yes); rc=$?
export STUB_HARDWARE_FAIL=0
[[ $rc -eq 7 && $out == *"REFUSING"* ]] \
  && ok "--first-aid: refuses a disk that drops off the bus (rc=7)" || bad "hardware refusal (rc=$rc)"
[[ $(grep -c '^ntfsfix' "$SB/label_calls") -eq 0 ]] && ok "  ...writing nothing at all" || bad "wrote to a dying disk"

# --- the tool it needs, and the disk it must refuse --------------------------
base_env; fake_os_release arch; label_reset; usb_ntfs_closed; : > "$SB/mount.ntfs"
out=$(env PATH="$(path_without ntfsfix)" "$SB/fix.sh" --first-aid --yes </dev/null 2>&1); rc=$?
[[ $rc -eq 5 && $out == *"not installed here"* && $out == *"sudo pacman -S ntfsprogs"* ]] \
  && ok "--first-aid: missing ntfsfix -> rc=5 and the package name" || bad "missing ntfsfix (rc=$rc)"

base_env; fake_os_release arch; label_reset; usb_ntfs_closed
export STUB_SOURCE=/dev/sdb1
out=$(run --first-aid --yes); rc=$?
export STUB_SOURCE=/dev/sda5
[[ $rc -eq 6 && $out == *"EXTERNAL disks"* ]] \
  && ok "--first-aid: refuses the disk the system runs from" || bad "protected first-aid (rc=$rc)"

base_env; fake_os_release arch; label_reset; usb_ntfs_two
out=$(run --first-aid --yes); rc=$?
[[ $rc -eq 6 && $out == *"more than one external NTFS disk"* ]] \
  && ok "--first-aid: same chooser rules as --check-disk" || bad "first-aid chooser (rc=$rc)"

# --- dry-run -----------------------------------------------------------------
base_env; fake_os_release arch; label_reset; usb_ntfs_closed; : > "$SB/mount.ntfs"
export STUB_NTFSINFO_DIRTY=1
out=$(run --first-aid --yes --dry-run); rc=$?
export STUB_NTFSINFO_DIRTY=0
[[ $rc -eq 0 && $out == *"[dry-run]"* && $out == *"nothing was changed"* ]] \
  && ok "--first-aid --dry-run: shows the plan, changes nothing" || bad "dry-run (rc=$rc)"
[[ $(grep -c '^ntfsfix' "$SB/label_calls") -eq 0 ]] && ok "  ...and really did nothing" || bad "dry-run wrote"

# --- it must work in the house style ----------------------------------------
for a in "--check-disk" "-check-disk" "check-disk" "--first-aid" "first-aid"; do
  base_env; fake_os_release arch; label_reset; usb_ntfs_closed
  out=$(run "$a"); rc=$?
  [[ $rc -eq 0 || $rc -eq 1 ]] \
    && ok "every dash style works: $a" || bad "$a did not run (rc=$rc)"
done

base_env; fake_os_release arch
out=$(env PATH="$(no_pacman_path)" "$SB/fix.sh" --check-disk </dev/null 2>&1); rc=$?
[[ $rc -eq 2 ]] && ok "--check-disk: a non-Arch system is politely refused (rc=2)" || bad "os check (rc=$rc)"

base_env; fake_os_release arch
out=$(run --help)
[[ $out == *"--check-disk"* && $out == *"--first-aid"* ]] \
  && ok "the help lists both new modes" || bad "help hides the new modes"
[[ $out == *"ONLY READS"* ]] && ok "  ...and says --check-disk only reads" || bad "read-only promise missing"
[[ $out == *"--rename --clear-check-flag, or --first-aid"* ]] \
  && ok "  ...and lists the flag-clearing writes it may do" || bad "promise list not updated"

# ================================================================= result ====
printf '\n============================================================\n'
printf '  passed: %s   failed: %s\n' "$PASS" "$FAIL"
printf '============================================================\n'
[[ $FAIL -eq 0 ]] || exit 1
printf '\n  All green. The script is safe to share.\n\n'
