# dpkg-caddy-cloudflare-hook

A dpkg hook for Debian and Ubuntu that puts the Cloudflare DNS module back into
[Caddy](https://caddyserver.com) whenever the `caddy` package is upgraded, **before Caddy is
started again**.

## The problem

Caddy's official Debian packages contain only the standard modules. The Cloudflare DNS
module (`github.com/caddy-dns/cloudflare`, needed for the ACME DNS challenge) is added with

```bash
caddy add-package github.com/caddy-dns/cloudflare
```

which replaces `/usr/bin/caddy` with a custom build. The next `apt upgrade` puts the stock
binary back, the module is gone, and a Caddyfile that uses `dns cloudflare …` no longer
starts.

## What the hook does

After every dpkg run it checks whether `caddy list-modules` still lists
`dns.providers.cloudflare`. If not, it runs `caddy add-package github.com/caddy-dns/cloudflare`
and checks again. It stays silent when there is nothing to do.

## Why it runs before the restart

| Step of an `apt upgrade` | What happens |
|---|---|
| `dpkg --unpack` | The new stock binary lands on disk. Caddy's package does not stop the service on upgrade (`preremove` stops it only on `remove`), so the old Caddy process keeps running. |
| **this hook** | apt runs unpack and configure as separate dpkg runs (`apt-pkg/deb/dpkgpm.cc`: "Do all actions with the same Op in one run"), and a dpkg post-invoke hook runs after each of them. The hook adds the module and does **not** restart Caddy. |
| `dpkg --configure` | Caddy's `postinst` runs `try-restart` on upgrade, and Caddy starts with the module. |

With a direct `dpkg -i caddy_….deb`, unpack and configure are one run: the package is
already configured when the hook runs, so the hook restarts Caddy itself. It tells the two
cases apart by the package state (`unpacked`/`half-configured` versus `installed`), and it
restarts only a service that is in use (enabled, active or failed).

## Requirements

- Debian or Ubuntu, Caddy installed as the `caddy` package (for example from Caddy's own
  apt repository)
- root
- Internet access to `caddyserver.com` when the module has to be added: `caddy add-package`
  downloads a custom build there

## Install

```bash
git clone https://github.com/MarcFauser/dpkg-caddy-cloudflare-hook.git
cd dpkg-caddy-cloudflare-hook
sudo ./install.sh
```

This installs two files and runs the hook once:

| File | Mode |
|---|---|
| `/usr/local/sbin/dpkg-caddy-cloudflare-hook` | 755 |
| `/etc/dpkg/dpkg.cfg.d/dpkg-caddy-cloudflare-hook` | 644 |

Update: `git pull` and run `sudo ./install.sh` again. Remove: `sudo ./install.sh --uninstall`.

## Checking that it worked

```bash
journalctl -t dpkg-caddy-cloudflare-hook
grep -n dpkg-caddy-cloudflare-hook /var/log/apt/term.log
caddy list-modules | grep -Fx dns.providers.cloudflare
```

An end-to-end test is `sudo apt install --reinstall caddy`: it puts the stock binary back,
and the hook has to add the module before the restart. Caddy is unavailable for as long as
the download from `caddyserver.com` takes.

## Behaviour worth knowing

- **It never fails dpkg.** A failing invoke hook aborts dpkg, so the script always exits 0.
  Problems go to stderr (shown by apt and kept in `/var/log/apt/term.log`) and to the journal,
  and the next dpkg run tries again. The hook line in `dpkg.cfg.d` also catches a crash of
  the script and reports it.
- **The binary can be newer than apt thinks.** `caddy add-package` downloads the latest
  Caddy release with the module, which may be newer than the packaged version. dpkg's
  checksum for `/usr/bin/caddy` no longer matches after that, so `dpkg --verify caddy`
  reports it.
- `caddy add-package` is marked experimental by Caddy.

## Tests

```bash
bash tests/run-tests.sh
```

The tests run the unchanged hook against small test doubles for `caddy`, `systemctl`,
`dpkg-query` and `logger`, covering the unpack and the `dpkg -i` paths, the package states,
download and restart failures and the line in `dpkg.cfg.d` itself. They need only bash and
the usual text tools, so they also run under Git for Windows.

**Status:** tested with the test doubles; not yet run on a real system.

## License

[MIT](LICENSE)
