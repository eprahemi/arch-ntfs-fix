# Contributing

Thanks for helping.

## The rules

1. **Never break a safety promise.** The README lists them. No `rm -rf`, no
   `mkfs`/`dd`/`wipefs`/`shred`, no writing straight to `/dev/sdX`, no
   `curl | bash`. The test suite fails if you try.
2. **Ask before changing the system, even inside the script.** `--yes` must stay
   an opt-in.
3. **On failure, teach.** Every `die` must explain the reason and print manual
   instructions.
4. **Add a test with every change.**
5. **stdout is the answer, stderr is the story.** Several functions are called as
   `$(...)` to capture their one-word answer, so anything else they print must go
   to **stderr**. This is not hypothetical — a prompt printed to stdout once
   leaked into a device name, and the tool then tried to open a disk called
   `which disk should I test? ...` (`Error looking up object for device`).
   Prompts, warnings and explanations go to stderr; only the answer goes to
   stdout.

```bash
shellcheck install.sh tests/run-tests.sh     # no output = clean
./tests/run-tests.sh     # all green before you open a pull request
```

## How the test suite works (so you can extend it)

It never needs root and never touches your machine. `tests/run-tests.sh` builds a
sandbox in `mktemp -d` and puts **fake** `sudo`, `pacman`, `udisksctl`, `systemctl`,
`journalctl`, `lsblk`, `findmnt`, `getent`, `curl`, `mount`, `umount` first in
`PATH`. It then runs a `sed`-patched copy of `install.sh` whose `CONFIG_PATH` and
`/usr/bin/mount.ntfs` point into that sandbox.

To test a new scenario: set the relevant `STUB_*` variable (see `base_env`), call
`run --some-flag`, and assert on the exit code and the output.

A few details before you write a test:

* `base_env` sets `MOUNT_RETRY_DELAY=0`. The real script waits a second between
  mount retries (udisks2 can be slow to notice a device); the suite must not sit
  through that wait. Same code path, no sleeping.
* `base_env` also empties `lsblk.out` ("no disk plugged in"), so a fixture
  (`one_disk`, `two_disks`, `three_disks`, …) must be called **after** it. Set one
  disk to fail with `STUB_MOUNT_FAIL_DEV=/dev/sdc1` when you want to prove that a
  bad disk does not hide the good ones.
* The two checks that need a real **terminal** — the disk prompt only exists when
  stdin is a tty — build a pty with `script(1)`, and skip themselves if `script`
  is missing.

Exit codes are meaningful, so tests can assert on them:

| code | meaning |
|------|---------|
| 0 | done |
| 1 | generic failure (config rejected, IO) |
| 2 | not an Arch system / bad option |
| 3 | no working sudo |
| 4 | no internet |
| 5 | packages could not be installed |
| 6 | no NTFS disk, or disk choice invalid |
| 7 | could not mount read-write |

The two disk modes reuse the same numbers: `--check-disk` returns 0 (fine),
1 (something is wrong) or 6 (no disk / refused to touch it). `--first-aid`
returns 1 when Linux could not fix the volume, 5 when `ntfsfix` is not installed,
6 when there is no disk, and 7 when it refuses because the disk is dropping off
the bus — writing to a disk that is failing is how disks die.
