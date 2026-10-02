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
