# arch-ntfs-fix

**Make Arch mount NTFS external disks the way other distros do — automatically, safely, and with proof.**

[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)
[![Bash](https://img.shields.io/badge/shell-bash-4%2B-blue.svg)](install.sh)
[![Tests](https://img.shields.io/badge/tests-294%20passing-brightgreen.svg)](tests/run-tests.sh)

---

## The problem

You plug in an NTFS external disk. Arch refuses:

```
Error mounting /dev/sdb1: GDBus.Error:org.freedesktop.UDisks2.Error.Failed:
wrong fs type, bad option, bad superblock on /dev/sdb1
```

The disk is fine. You open a terminal and find the truth:

```bash
journalctl -k | grep -i ntfs
ntfs3(sdb1): It is recommended to use chkdsk.
ntfs3(sdb1): volume is dirty and "force" flag is not set!
```

You go read-only (data is safe), plug the same disk into **another distro**, and it just works.
So why?

## Which systems does it work on?

**Any Arch-based system, with any desktop.** The script only ever talks to
`udisks2`, so the desktop makes no difference: GNOME, KDE Plasma, Hyprland,
XFCE, i3, Sway, Cinnamon.

| System | Works? | How it is detected |
|---|---|---|
| Arch Linux | yes | `ID=arch` |
| CachyOS | yes | recognised by name — **it ships no `ID_LIKE`**, so detection cannot rely on it |
| Manjaro, EndeavourOS, Garuda, Artix, ArcoLinux | yes | `ID_LIKE=arch` |
| SteamOS 3, Arch Linux ARM | yes | `ID_LIKE=arch` / known family id |
| an unusual respin with odd metadata | yes | `pacman` is present → admitted **with a warning** |
| any non-Arch system | **refuses (exit 2)** | no `pacman` → it refuses *before touching anything* and prints the equivalent commands for your package manager |

Detection is deliberately layered, because real-world `os-release` files are
messy. If your system is Arch-based and still gets refused, use:

```bash
./install.sh --skip-os-check
```

The **fix itself is universal**: any distro that uses `udisks2` can be given the
same `/etc/udisks2/mount_options.conf`. Only the package-install line differs,
and the refusal message prints it for you.

## Why other distros work and Arch does not

Both run the same Linux kernel. **The difference is only which NTFS driver gets picked.**

| | `ntfs3` (Arch's first choice) | `ntfs-3g` (what other distros end up using) |
|---|---|---|
| What it is | built **into the kernel** (C) | a **FUSE** program (userspace) |
| "Dirty" volume | **refuses** to mount it | mounts it, then schedules a `chkdsk` |
| Speed | faster | slower |
| Who picks it | udisks2's built-in order `ntfs3,ntfs` | the fallback in that same order |

`udisks2` ships with this built-in preference:

```
ntfs_drivers=ntfs3,ntfs      # try ntfs3 first, then ntfs-3g
```

So Arch *tries* ntfs3, ntfs3 says no, and — because the volume is dirty — it never
gets to the driver that would have coped. Most distros end up on `ntfs-3g`.

> **The fix is one config file.** It does not touch your kernel, your disk, or your data.

## Quick start

```bash
git clone https://github.com/eprahemi/arch-ntfs-fix.git
cd arch-ntfs-fix
./install.sh
```

Read it first if you like — that is the point of it being a script you can open:

```bash
less install.sh          # ~2,300 lines of plain bash, nothing hidden
./install.sh --dry-run   # prints everything it would do, changes nothing
./install.sh --list      # just show the NTFS disks it can see
```

It checks each step out loud, then shows you the disk it opened:

```
  ┌──────────────────────────────────────────────────────────┐
  │ arch-ntfs-fix                                            │
  │ Arch refuses your NTFS disk. Other distros open it.      │
  └──────────────────────────────────────────────────────────┘
  your desktop does not matter (GNOME, KDE, Hyprland, XFCE, i3, Sway):
  this only ever talks to udisks2, and they all use that.
  ✓ your system                       Arch Linux
  ✓ sudo                              ready
  ✓ internet                          fine (archlinux.org)
  ✓ ntfs-3g + udisks2                 ntfs-3g and udisks2 already here
  ✓ writing the fix                   written, udisks2 restarted, log is clean
  ✓ your disk                         /dev/sdb1  500GB (465.8G)
  ✓ opening it                        mounted read-write

      ████ ████ ████ ████ ███
      █    █  █ █  █ █    █  █
      ████ █  █ █  █ █ ██ ███
         █ █  █ █  █ █  █ █  █
      ████ ████ ████ ████ ███
------------------------------------------------------------
  WHAT YOU HAVE NOW
------------------------------------------------------------
  500GB is ready - READ-WRITE
  mounted at /run/media/eprahemi/500GB
  open it with your file manager - or just double-click the disk
```

Everything there is a terminal spinner, a progress bar and a hand-drawn
five-row font — plain bash, no `figlet`, no `lolcat`, nothing to install. If
you pipe the output into a file it turns itself off and prints plain lines
instead, so logs stay readable (`--plain` does the same thing on purpose).

The big reveal is your own disk's name, not a stock word. The little font only
knows letters, numbers and a few marks, so a name it cannot draw simply goes
in a clean box instead — any language, any brackets:

```
      ╭──────────────────╮
      │ BACKUP (2)       │
      ╰──────────────────╯
```

A disk with no name at all gets big `READY`.

## Several disks at once

Plug in two disks and the script asks which one to test. Plug in a hundred and
that question is useless, so there is `--all` — or just type `a` at the prompt.
Every disk gets its own turn, its own line and its own result, so one disk that
refuses to open can never hide the ones that work:

```
     #   DEVICE         SIZE      TYPE   USB?  MOUNTED LABEL
     1   /dev/sdb1      465.8G    usb    yes   -      500GB
     2   /dev/sdc1      931.5G    usb    yes   -      BACKUP

  ✓ disk 1                            /dev/sdb1  500GB (465.8G)
  ✓ disk 2                            /dev/sdc1  BACKUP (931.5G)
  ✓ opening /dev/sdb1                 mounted read-write
  ✓ opening /dev/sdc1                 mounted read-write

------------------------------------------------------------
  WHAT YOU HAVE NOW
------------------------------------------------------------
  ✓ 500GB                  mounted read-write at /run/media/you/500GB
  ✓ BACKUP                 mounted read-write at /run/media/you/BACKUP

  2 of 2 disks ready
```

If one of them cannot be opened, the run keeps going, names the one that failed,
and ends with **exit code 7** so a script can still tell that something is wrong.
`--disk N` and `--all` together are refused instead of guessed at.

Small side-notes — like an existing config that has to be backed up first — get
their own titled box, with room above and below, instead of loose `!!` lines
stuck together:

```
  ┌─ keeping a backup ─────────────────────────────────────┐
  │ /etc/udisks2/mount_options.conf                        │
  │ is already there. I am keeping your old one at         │
  │ /etc/udisks2/mount_options.conf.bak                    │
  └────────────────────────────────────────────────────────┘
```

The run is deliberately **paced**. Even when everything is already installed —
the common case — each step keeps its spinner up for about a second, so the
whole thing takes roughly 5–10 seconds and you can watch it work instead of
seeing a blink. It is honest about it too: if a step really is slow (a package
download, a slow disk) no time is added on top, and once the run is already
9 seconds old the padding stops. In a pipe, a log, `--plain` or the test suite
it costs no time at all — the whole script finishes in about a tenth of a
second.

## What it does

1. **Checks** it really is Arch, that `sudo` works, and that the internet is up (needed only to install packages).
2. **Installs what is missing** — `ntfs-3g` and `udisks2` — asking first.
3. **Writes the fix**: `/etc/udisks2/mount_options.conf` with `ntfs_drivers=ntfs`, keeping a `.bak` if a *different* file was there. If the file is already exactly right, it changes **nothing at all** — no rewrite, no `.bak`, and no udisks2 restart, so running it twice is safe.
4. **Restarts udisks2** (only after a real write) and then **reads its log** to prove the file was accepted.
5. **Finds your NTFS disk by itself** (nothing hardcoded — ask for `sdb1`, it finds `sdb1`), handles several disks, and works whether it is plugged in or not. With more than one disk it asks which; `--all` (or just `a` at the prompt) does every one of them.
6. **Mounts it and proves it is read-write**, printing the driver, mount point and options. If it cannot, it explains *that* error — a disk udisks2 cannot resolve is not the same problem as a dirty volume, and it is never treated as one.

## Options

| Option | What it does |
|---|---|
| `--list` | list the NTFS disks it can see, then exit |
| `--disk N` | use disk number N (needed when there are several) |
| `--all` | test **every** NTFS disk it finds, one after the other — two disks or a hundred. One that refuses to open never hides the ones that work (also `all`) |
| `--dry-run` | print everything, change nothing |
| `--yes` | do not ask questions (for scripts/CI) |
| `--show-config` | print the config file it installs, then exit |
| `--status` | read-only report: is the fix in place, what disks are here (also `status`, `-status`) |
| `--self-check` | run only the checks, change nothing |
| `--check-disk` | **look** at an external NTFS disk and say what is wrong with it — open, healthy, waiting for a check, or really damaged — and what the next step is. It **only reads** |
| `--first-aid` | the one repair Linux can do safely, and only when you ask: look, rehearse, then ask, then clear the "check me first" flag. `--first-aid` **is** the request to repair; `--yes` only skips the last question |
| `--try-force` | also try ntfs3's force mount to clear a dirty flag |
| `--uninstall` | remove the config file again (keeps a `.bak` copy + prints the undo command) |
| `--purge` | with `--uninstall`: delete with **no** backup copy at all |
| `--rename [NAME]` | give an **external** disk a readable name (also `--label`, `--name`, `rename`, `r`) |
| `--clear-check-flag` | with `--rename`: clear a disk's pending "check me first" flag (NTFS) instead of stopping. `--yes` does **not** cover this one |
| `--skip-net-check` | skip the internet test |
| `--skip-os-check` | do not refuse on a system it does not recognise as Arch-based |
| `--plain` | no colour, no spinner, no big letters, no pacing - instant (nice in logs) |
| `-h`, `help`, `-help`, `--help` | the same list |

There are no version numbers on purpose: it is one script, either it works for
you or it does not. `--version` prints the name and nothing else.

Dashes are optional, and so are long names. All of these are the same command:

```bash
./install.sh help      ./install.sh h      ./install.sh -h      ./install.sh --help
./install.sh status    ./install.sh s      ./install.sh -s      ./install.sh --status
./install.sh rename    ./install.sh r      ./install.sh -r      ./install.sh --rename
```

A wrong option gets one short line and the hint, not the whole help text.

## Safety

This tool is written to be handed to a stranger, so:

* **The fix never writes to, formats, or deletes anything on your disks.** No
  `mkfs`, no `dd`, no `wipefs`, no `shred` — the fix is one config file for
  udisks2. It never *repairs* a filesystem either: a disk that is waiting for a
  Windows check still mounts read-write after the fix, and nothing is touched.
* **`--rename` writes exactly one thing per disk: the name you asked for.** If
  that disk's own tool refuses because the volume is waiting for a check,
  clearing that flag is a *repair* — a separate question, asked separately. It
  happens only with your own yes (or `--clear-check-flag`).
* **The two never mix:** a plain `./install.sh` never runs `ntfsfix` and never
  writes a disk name. A test fails the build if anyone ever puts a repair into
  the install path.
* **Repairing is a separate mode, and it is honest about what it is.**
  `--check-disk` only reads (it never writes a byte). `--first-aid` does the one
  repair Linux can do safely — clearing the "check me first" flag with
  `ntfsfix -d` — and only after it has looked (read-only) and rehearsed with
  `ntfsfix -n` (which writes nothing). It never uses `--force`, never formats,
  and never touches a disk that already works. It refuses a disk that is
  dropping off the USB bus (writing to one is how disks die) and refuses the
  disk the system runs from. If it cannot fix the volume it says so and stops —
  real damage needs Windows `chkdsk`. It cannot repair files; no Linux tool can.
* **The only file it ever removes** is the one config file it installs (and only with `--uninstall`, after showing you its contents).
* **It never downloads anything except through pacman's signed repositories.** No `curl | bash`, ever.
* **It asks before every change**, and `--dry-run` changes nothing at all.
* **It fails loudly and helpfully**: if something is wrong it stops, explains it, and prints the exact commands to do it by hand.
* The test suite **grep-fails the build** if a dangerous command (`rm -rf`, `mkfs`,
  `dd if=`, `wipefs`, `shred`, writing straight to `/dev/sdX`) ever appears in the
  script, or if a download is ever piped into a shell.

## The one rule that bites everyone

The config file **must start with a group header**. Without `[defaults]` on the
first non-comment line, udisks2 throws the file away **silently**:

```
Error reading global mount options config file /etc/udisks2/mount_options.conf:
Key file does not start with a group
```

That single missing line cost me an hour, which is why the script checks udisks2's
log after writing the file:

```bash
journalctl -u udisks2 --since '-1 min' | grep -i 'mount options'   # no output = good
```

**Learn the pattern: change a config → restart the service → read its log.** A
config that fails to parse is usually ignored in silence.

## If you would rather do it by hand

That is completely fine — the script is only a convenience:

```bash
sudo pacman -S --needed ntfs-3g udisks2

sudo tee /etc/udisks2/mount_options.conf >/dev/null <<'CONF'
[defaults]
ntfs_drivers=ntfs
CONF

sudo systemctl restart udisks2
journalctl -u udisks2 --since '-1 min' | grep -i 'mount options'   # no output = good

udisksctl mount -b /dev/sdX1
findmnt -no FSTYPE,OPTIONS /run/media/$USER/YOUR_LABEL             # want: fuseblk rw,...
```

Undo:

```bash
sudo rm -f /etc/udisks2/mount_options.conf && sudo systemctl restart udisks2
```

## Giving a disk a name every system can read

A *label* is the name written inside the filesystem — the one Windows, macOS and
every Linux file manager show, and the one udisks2 turns into the mount folder
(`/run/media/you/NAME`). Nothing to do with the fix above; you can rename any
time you like.

```bash
./install.sh --rename        # also: --label, --name, rename, r
```

It will:

1. list only the **removable / USB** disks it can find — never the disk the
   system is running from, and never another partition on that disk;
2. ask what name you want;
3. ask *which* disk, if there is more than one (press Enter to take the first);
4. show you `name now  →  name after`, then ask once more before touching
   anything;
5. unmount the disk, **rehearse** the change where the tool allows it, write the
   name, read it back to prove it, and mount the disk again.

The read-back at the end is not decoration: a tool that reports success can
still be wrong, so the name is fetched from the disk afterwards. Reading a raw
disk needs root just as much as writing one does — a block device belongs to
`root:disk` — so the read-back uses `sudo` too, and falls back to the name the
kernel already knows (`lsblk`) if sudo cannot answer. It warns only when *both*
come back empty.

```
     #   DEVICE         SIZE      TYPE   MOUNTED                  NAME IT HAS NOW
     1   /dev/sdb1      465.8G    ntfs   /run/media/you/500GB     500GB

     what name do you want? MEMORIES

  ✓ the disk                          /dev/sdb1  (465.8G)
  ✓ name now                          500GB
  ✓ name after                        MEMORIES
```

The name is checked *before* anything is touched, and the limits are the real
ones — measured with throwaway images, not copied from a wiki:

| Filesystem | Tool | Longest name kept |
|---|---|---|
| NTFS | `ntfslabel` | **32** — ntfs-3g accepts 128, but Windows only shows the first 32 |
| exFAT | `exfatlabel` | 11 |
| FAT | `fatlabel` | 11 |
| ext2/3/4 | `e2label` | 16 — it silently *truncates* past that, so it is checked first |

Two rules, and they matter:

* **The volume has to be unmounted** while its name is written. A mounted volume
  is opened exclusively and the tool refuses — a safety feature, not a bug.
  `--rename` closes and re-opens the disk for you.
* **Never add `--force`.** If the tool refuses, it has a reason.
* **"Volume is scheduled for check"** — the disk carries a "check me first" flag,
  set by Windows Fast Startup (Windows never really shuts the disk down) or by
  unplugging the disk while it was writing. Renaming writes into the disk's own
  bookkeeping, so `ntfslabel` refuses while that flag is up. Nothing is broken and
  no file of yours is touched. There are two ways to clear it and **Windows is not
  required** — see [the section below](#volume-is-scheduled-for-check-without-windows).
  `--rename` explains both and offers to do the Linux one; `--yes` deliberately
  does **not** cover it, because repairing a disk is a different question from
  renaming it.

By hand it is four commands:

```bash
udisksctl unmount -b /dev/sdX1
sudo ntfslabel /dev/sdX1              # read the name it has now (reading needs root)
sudo ntfslabel /dev/sdX1 MEMORIES     # write the new name
udisksctl mount -b /dev/sdX1
```

Other filesystems are the same shape with `exfatlabel`, `fatlabel` or `e2label`.
If a tool is missing, the script names the package (`ntfsprogs`, `exfatprogs`,
`dosfstools`, `e2fsprogs`) instead of guessing — and `--dry-run` prints the exact
commands without calling anything at all.

### "Volume is scheduled for check" without Windows

`ntfslabel` refuses to name a volume that is waiting for a check, because renaming
writes into the filesystem's own bookkeeping. Both of these work, pick one:

**1 — with Windows (safest).** Plug the disk in, let it check the disk
(`chkdsk X: /f /x` in an admin prompt), eject it safely, and shut Windows down
cleanly. Windows can also replay changes it had not written yet; Linux cannot.

**2 — without Windows, on Linux.** Verified on a throwaway image, not taken from
a forum post: plain `ntfsfix` *sets* this flag, and `ntfsfix -d` clears it, after
which `ntfslabel` works.

```bash
udisksctl unmount -b /dev/sdX1
sudo ntfsfix -n /dev/sdX1     # look first - this changes nothing at all
sudo ntfsfix -d /dev/sdX1     # then clear the flag
udisksctl mount -b /dev/sdX1
```

`./install.sh --rename` prints both routes and, if you say yes (or add
`--clear-check-flag`), clears the flag itself with `ntfsfix -d` and then rehearses
the rename again. It never repairs a disk silently: `--yes` answers the *renaming*
question only. If Linux cannot fix the volume, the script says so and stops rather
than guessing. `ntfsfix` comes with `ntfsprogs`, the same package as `ntfslabel`,
so anyone who can rename at all already has it.

> **Careful:** plain `sudo ntfsfix /dev/sdX1` (no `-d`) does the *opposite* — it
> deliberately sets that flag so Windows will check the disk. That is a common
> piece of internet advice, and it makes the rename impossible.
>
> Clearing the flag drops changes Windows was still holding in its cache. The files
> already on the disk are fine; the last few minutes of Windows work may not be.

## Looking at a disk, and the one repair Linux can do

Two modes that are about the *disk*, not the config file. They are for the moment
the fix has not worked and you want to know why.

### First, look: `./install.sh --check-disk`

It reads. That is the whole point — it can tell you what is wrong without
changing anything. Choose a disk by name or with `--disk N`, and it prints:

* **is it open right now** — and if so, read-write or read-only;
* **the connection** — whether the kernel log shows recent I/O errors, which
  means the cable, the port or the enclosure, not the filesystem;
* **the volume itself** — healthy, or carrying the "check me first" flag, or
  damaged beyond what Linux can fix;
* **what to do next**, and the exact command.

It never probes a volume that is mounted (the NTFS tools refuse those anyway), so
it says "it is open" and stops there.

Exit codes: `0` = nothing wrong, `1` = something is wrong, `6` = no external
NTFS disk (or a disk it refuses to touch).

### Then, the one repair: `./install.sh --first-aid`

Linux has exactly one safe repair for NTFS: `ntfsfix -d`. Everything else people
find online (`ntfsfix` without `-d`, `--force` mounts) either makes things worse
or hides the problem.

`--first-aid` runs in this order, and stops at the first step that says stop:

1. **Look** — the same read-only inspection as `--check-disk`.
2. **Refuse if the hardware is bad** — if the disk is dropping off the bus, it
   stops with exit code `7`. Writing to a disk that is failing is how data dies.
3. **Rehearse** — `sudo ntfsfix -n` (writes nothing at all).
4. **Ask** — unless you already said `--first-aid`, which *is* the request to
   repair. `--yes` only skips this last question; it does not turn anything on.
5. **Repair** — `sudo ntfsfix -d`, and nothing else on the disk.
6. **Prove it** — read the volume again, read-only, and tell you whether the flag
   is really gone.

If the disk is already mounted read-write it does nothing at all — there is
nothing to repair, so it will not write to a working disk. If it is open
read-only, it closes it first, then gives it back when it is done.

Exit codes: `0` = fixed (or already fine), `1` = could not fix it, `5` = `ntfsfix`
is not installed, `6` = no external NTFS disk, `7` = refused because of hardware.

`--dry-run` works with both: it prints every step it would take and touches
nothing.

**What it is not.** `ntfsfix` is first aid, not a repair. It clears the flag and
rebuilds a damaged boot sector from its backup copy. It cannot rebuild a
filesystem, and it cannot recover files. If `--check-disk` says *damaged*, the
answer is Windows `chkdsk X: /f /x` — or copy the files off with a data-recovery
tool. The script tells you that instead of pretending.

## Troubleshooting

<details>
<summary><b>The disk keeps disconnecting, or you see I/O errors</b></summary>

This is **hardware or power**, not a filesystem problem, and no config file can
fix it. The script detects it from the kernel log and says so:

```bash
journalctl -k --since '-3 min' | grep -E 'DID_ERROR|I/O error|device offline'
```

Those lines mean the disk fell off the USB bus. In order of likelihood:

1. **It is on a USB 2 port.** A 2.5" spinning drive often needs more current than
   USB 2 promises (500 mA) to spin up, and browns out instead. Move it to a USB 3
   port and verify:
   ```bash
   lsusb -t | grep -i mass      # want 5000M, NOT 480M
   ```
2. **The cable is too thin or too long.** Short, thick, shielded. Most common,
   cheapest fix.
3. **The USB-SATA bridge or enclosure is failing.** `lsusb` shows the chip
   (many cheap ASMedia/JMicron bridges drop connections). Try another enclosure.
4. **The disk itself is dying.** Test on another machine and read its health:
   ```bash
   sudo pacman -S smartmontools && sudo smartctl -a /dev/sdX
   ```

Until it is sorted: browse **read-only** (`udisksctl mount -b /dev/sdX1 -o ro`),
copy anything irreplaceable **now**, and unplug cleanly with
`udisksctl power-off -b /dev/sdX`.

`--try-force` **refuses to run** in this situation on purpose: it writes
filesystem metadata, and writing to a connection that keeps breaking is how data
is really lost.
</details>

<details>
<summary><b>"volume is dirty and force flag is not set"</b></summary>

Windows did not shut the disk down cleanly (Fast Startup, or the cable was pulled
mid-write). Windows is the tool that repairs this:

```cmd
REM Command Prompt as Administrator
chkdsk X: /f /x
powercfg /h off        REM stops Fast Startup dirtying it again
```

The same flag is what stops `--rename` from naming the disk, and it can be
cleared from Linux with no Windows at all — see
[the rename notes](#volume-is-scheduled-for-check-without-windows).

After that you can run `./install.sh --uninstall` and go back to Arch's faster
kernel driver.

This script can also try the Linux-only route for you (`./install.sh --try-force`):
it mounts once with ntfs3's `force` flag, which clears the flag, then unmounts.
It writes filesystem metadata, so it asks first.
</details>

<details>
<summary><b>"AlreadyMounted: Device ... is already mounted"</b></summary>

That is a **success**, not a failure — the volume you asked for is open. The
script treats it as one, and reports it read-write. If you want it somewhere
else:

```bash
udisksctl unmount -b /dev/sdX1
udisksctl mount   -b /dev/sdX1
```
</details>

<details>
<summary><b>"Error looking up object for device"</b></summary>

udisks2 does not know that device *right now*. That is **not** a filesystem
problem, so `chkdsk` and `--try-force` (which writes to the disk) are both the
wrong tool — the script says so and stops instead of guessing. The usual causes:

1. **udisks2 was just restarted.** Installing the fix restarts it on purpose, and
   for a moment its device list is empty. The script retries three times for
   exactly this reason; if it still fails, wait a second and run it again.
2. **The disk was re-plugged and got a new name.** Look with `lsblk -f`, or let
   the script find it: `./install.sh --list`.
3. **Something else already has it open** — `findmnt /dev/sdX1` tells you where.

The kernel log says whether the disk itself is fine:
`journalctl -k | tail -30`.
</details>

<details>
<summary><b>"no NTFS partition found"</b></summary>

* `lsblk -f` — is the disk visible at all? A **USB-SATA adapter** shows up as `sdb`, not `usb`.
* Is it actually NTFS? A disk formatted **exFAT needs no such fix** — the kernel's exfat driver mounts it happily, and exFAT has no dirty-flag problem. Nothing to fix here.
* Re-run `./install.sh --list` after plugging it in.
</details>

<details>
<summary><b>findmnt prints <code>user_id=0</code></b></summary>

That is FUSE's own field name, **not** root ownership. Check the truth:

```bash
ls -l /run/media/$USER/YOUR_LABEL | head -3     # should show your user
```
</details>

<details>
<summary><b>"no working internet connection"</b></summary>

Needed only to install missing packages. Connect, or:

```bash
./install.sh --skip-net-check     # if you already have ntfs-3g + udisks2
```
</details>

<details>
<summary><b>It fixed the mount but I want the fast driver back</b></summary>

Run `chkdsk X: /f /x` in Windows, then `./install.sh --uninstall`.
`ntfs3` is faster than `ntfs-3g` because it has no FUSE layer.
</details>

## Tests

```bash
./tests/run-tests.sh
```

294 checks, and **no root and no real system changes needed**: every command the
script uses (`sudo`, `pacman`, `udisksctl`, `systemctl`, `lsblk`, `findmnt`, …)
is replaced by a fake, and the paths it writes to point at a throwaway sandbox.
CI runs the same suite on every push. Because the tests capture the output, the
spinner and the big letters switch themselves off — the checks assert the plain
lines, which is exactly what you get in a log too.

`shellcheck` is clean on both files — not one finding, even at its noisiest level:

```bash
sudo pacman -S shellcheck
shellcheck install.sh tests/run-tests.sh     # no output = clean
```

## FAQ

**Does it work on other distros?**
No, and it says so politely before touching anything: it prints the equivalent
commands for `dnf`, `apt` or `zypper` so you can do it yourself. It only runs on
Arch-based systems — Arch, CachyOS, Manjaro, EndeavourOS, Garuda, Artix,
ArcoLinux, SteamOS and friends.

**Do I even need it on Manjaro or EndeavourOS?**
Maybe not — those are Arch-based and accepted, but they often already end up on
`ntfs-3g`. Run `./install.sh --status` and see; if your NTFS disk already mounts
read-write, there is nothing to fix.

**How do I know if the fix is still in place?**
```bash
./install.sh --status       # or: status, -status
```
It prints what the machine is, what is installed, whether the config file is
really *the fix* (it checks the contents, not just that the file exists), what
disks it can see, and the undo lines. Exit code is `0` when the fix is in place
and `1` when it is not, so you can use it in a script. It never asks for a
password.

**It printed a "do it by hand" list. Do I have to do that?**
No. The script did every step itself - that list is there so you can *see* what it
did, and repeat it by hand if you ever prefer not to run a script. The script only
prints it when a step genuinely failed (for example, no internet to fetch a
package). If there is simply no disk plugged in, it now says that in one line
instead and leaves the by-hand list out.

**Does my shell matter (fish, zsh, bash)?**
No. The first line of the script, `#!/usr/bin/env bash`, is read by the **kernel**,
not by your shell, so the script always runs in bash no matter what your login
shell is. Just run it as `./install.sh` — do **not** `source install.sh` (that
would run bash code inside your shell, and fish is not bash). Bash is also not
optional on Arch in practice: `pacman` and `systemd` both depend on it
(`pacman -Qi bash` → *Required By*).

**Does it need to be published? Can I just copy the file?**
Yes. It is one self-contained bash script with no dependencies of its own. Copy
`install.sh` anywhere and run it.

**Will it break my dual boot?**
No. It writes one file under `/etc/udisks2/` and restarts one service. Nothing
touches partitions or bootloaders.

**Is ntfs-3g as good as ntfs3?**
No — it is slower (FUSE). That is why this is a fix, not a permanent upgrade.
Once the volume is clean, prefer ntfs3 and `--uninstall`.

**Which NTFS is affected?** Any NTFS volume: external disks, Windows-formatted
partitions, disks that Windows was hibernated on.

## Contributing

Issues and pull requests are welcome — especially from other distros, other
locales, and anyone with a disk shape that breaks the detection. Please keep the
safety promises above intact and add a test with your change:

```bash
./tests/run-tests.sh     # must stay 294/294 (or more)
```

## License

MIT — see [LICENSE](LICENSE). The idea came from one real rescue: a 500 GB NTFS
disk that mounted read-only on Arch and perfectly on another distro, and one line of
config that made the two distros agree.

## Author

[eprahemi](https://github.com/eprahemi) — Arch + Hyprland user, learning out loud.
