# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.2] - 2026-10-23

### Fixed

- `caddy add-package` could hold the whole dpkg run indefinitely: Caddy downloads with a
  plain `http.Get` without a timeout, and its build server comes without an SLA (the first
  CI run waited six hours). The call is now limited to 300 seconds (`ADD_PACKAGE_TIMEOUT`).
  If it is killed after caddy moved the old binary to `<binary>.tmp`, the hook puts it back.
- The CI jobs have time limits, and the end-to-end test limits its own `add-package` call,
  so an unreachable build server fails the run within minutes instead of hours.

## [1.0.1] - 2026-10-23

### Added

- GitHub Actions workflow: the unit tests, and an end-to-end test with the real caddy
  package in Debian 12, Debian 13 and Ubuntu 24.04 containers (`tests/e2e.sh`), on every
  push, weekly and on demand.
- README sections on the end-to-end test and on development, explaining what
  `install-git-hooks.ps1` and `install-git-hooks.cmd` are for.

## [1.0.0] - 2026-10-23

### Added

- dpkg post-invoke hook that puts the Cloudflare DNS module
  (`github.com/caddy-dns/cloudflare`) back into Caddy after the `caddy` package replaced
  `/usr/bin/caddy`, before the package's postinst restarts the service. With a direct
  `dpkg -i` it restarts Caddy itself.
- `install.sh` to install the two files, or remove them with `--uninstall`.
- Test suite with test doubles for `caddy`, `systemctl`, `dpkg-query` and `logger`.
