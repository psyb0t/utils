# Changelog

All notable changes per release. Versions follow [semver](https://semver.org).

## v0.3.0 - 2026-10-14

`mikrotik-backup.sh` no longer stops for good when the router is unreachable.
Before this release, continuous mode exited with a fatal error if the router did
not answer at startup, and any failed backup run ended the loop through
`set -e`. Under a process supervisor that gives up after a few quick restarts,
one router reboot at the wrong moment stopped backups until the host itself
restarted. Continuous mode now tests the connection on every run, logs an
unreachable router or a failed run as an error, and retries on the next run.
A single run without `--continuous` still exits when the router is
unreachable.

A run now also backs up when the configuration changed. Each run reads
`/export terse show-sensitive` and compares it with the newest saved
`.terse.rsc`, ignoring the comment lines at the top, which carry the export
time. Any difference triggers a backup, so a change is saved on the next run
instead of waiting for `--max-backup-age` to pass. `--force` and the age check
work as before.

The binary `.backup` file is now written mode 600, like the exports. It holds
user password hashes and wireless keys, and scp created it with the default
umask, readable by every local user.

Every `ssh` and `scp` call now uses a 15 second connect timeout and keepalives
that drop a connection after one minute of silence. Before, only the startup
connection test had a timeout, so a router that stopped answering during a
transfer could hang the loop with nothing logged.

## v0.2.0 - 2026-09-13

`mikrotik-backup.sh` now writes a portable configuration export alongside the
binary backup. The binary `.backup` restores only onto the same device running
the same RouterOS version, because it carries and restores MAC addresses. The
new files are text and replay onto different hardware.

Every run writes four files that share one timestamp:

- `.backup`, the binary backup. Restore mode still uses this file, and nothing
  about it changed.
- `.rsc`, the compact export from `/export show-sensitive`. Edit this one and
  replay it onto another router.
- `.terse.rsc`, from `/export terse show-sensitive`. One full command per line
  with its menu path and no line continuations, so two runs diff cleanly.
- `.inventory.txt`, recording the model, architecture, RouterOS version,
  installed packages and interface names. An export records none of them, and
  all of them decide whether it imports onto a given target.

The script reads the exports over SSH to standard output, so they leave no file
on the router. It strips the CR that RouterOS emits, writes through a temporary
file it renames only after a successful non-empty read, and creates the export
files mode 600, because `show-sensitive` writes wireless pre-shared keys, VPN
secrets and PPPoE passwords in cleartext.

The binary backup and the exports fail independently. If one fails the script
still writes the other and warns which one failed. Only both failing fails the
run.

`--max-backups` now counts backup sets instead of individual files, which is an
incompatible change. A run writes four files, so counting files would prune
four times too early and leave a run with some artifacts deleted and the rest
kept. At the same flag value the backup directory holds about four times as
many files. Lower the value if that directory has a size limit.

`/export show-sensitive` is RouterOS v7 syntax. A v6 router shows sensitive
values by default and takes `hide-sensitive` instead, so both exports fail
there and the run still produces the binary backup and the inventory.

An export excludes system user passwords, installed certificates and SSH keys.
RouterOS cannot export user passwords or user SSH keys at all, and certificates
need `/certificate/export-certificate` separately. The binary backup stays the
only artifact that carries them. Replaying an export onto different hardware is
manual, and `--help` documents the procedure.

This release also adds `.gitleaks.toml`, which extends the bundled gitleaks
rules so the secret scan has a committed configuration.

## v0.1.0 — 2026-08-01

First tagged release. This marks the existing contents of the repository as a
released state; it does not add new work.

The repository is a loose collection of small shell and Python utility scripts:
a Borg backup daemon, a MikroTik backup script, an rsync daemon wrapper, an
archive.org publishing script, ffmpeg-as-webcam and video-to-transparent-GIF
helpers, a yt-dlp/VLC launcher, file-organizing and file-finding helpers, and
other one-off tools.

The repository is mirrored to Codeberg and GitLab, and archived to the Wayback
Machine, Software Heritage, and archive.org. The mirrors are force-pushed from
GitHub, so pull requests are disabled on them; issues and forking stay enabled,
and issues opened on either mirror are copied back into GitHub.
