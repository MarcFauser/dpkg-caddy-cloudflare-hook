# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.1.0] - 2026-10-23

### Added

- Fallback to the previous binary: a new `pre-invoke` line saves `/usr/bin/caddy` as
  `/var/lib/dpkg-caddy-cloudflare-hook/caddy.previous` before a dpkg run that unpacks or
  installs packages, if it has the module. When the module cannot be added after the
  package replaced the binary, the hook puts that copy back, so Caddy keeps running with
  the module instead of failing to start. The package's own binary is kept as
  `caddy.stock`, and the marker `pending` says which version waits.
- Retry: dpkg counts the new package version as installed, so apt does not offer it
  again. While the marker exists, the hook adds the module to `caddy.stock` again on a
  later dpkg run, at most once per 60 minutes (`RETRY_INTERVAL`), or at once when run by
  hand. A binary replaced by hand in the meantime ends the retries.
- End-to-end test of the fallback and the retry, with `caddyserver.com` blocked in
  `/etc/hosts`.

### Changed

- `caddy add-package` runs on a copy in `/var/lib/dpkg-caddy-cloudflare-hook/work`, and
  `/usr/bin/caddy` is replaced with one rename only after the module is confirmed. The
  `.tmp` handling next to `/usr/bin/caddy` from 1.0.2 is no longer needed.
- `install.sh --uninstall` also removes `/var/lib/dpkg-caddy-cloudflare-hook`.
- The script takes `--pre-invoke` or `--post-invoke`; without an option it works as
  before (post-invoke).

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
