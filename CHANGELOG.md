# Changelog

All notable changes to this project are documented in this file.
The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
uses [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-10-23

### Added

- dpkg post-invoke hook that puts the Cloudflare DNS module
  (`github.com/caddy-dns/cloudflare`) back into Caddy after the `caddy` package replaced
  `/usr/bin/caddy`, before the package's postinst restarts the service. With a direct
  `dpkg -i` it restarts Caddy itself.
- `install.sh` to install the two files, or remove them with `--uninstall`.
- Test suite with test doubles for `caddy`, `systemctl`, `dpkg-query` and `logger`.
