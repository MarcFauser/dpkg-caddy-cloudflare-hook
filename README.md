# dpkg-caddy-cloudflare-hook

> **Superseded by [caddy-deb](https://github.com/MarcFauser/caddy-deb)**, an apt repository
> with Caddy and the Cloudflare DNS module built in, so apt manages the binary that runs and
> no hook is needed. This repository is archived. To remove the hook, run
> `./install.sh --uninstall` in its folder as root, then follow caddy-deb's README,
> section "On a server".

[![tests](https://github.com/MarcFauser/dpkg-caddy-cloudflare-hook/actions/workflows/tests.yml/badge.svg)](https://github.com/MarcFauser/dpkg-caddy-cloudflare-hook/actions/workflows/tests.yml)

A dpkg hook for Debian and Ubuntu that puts the Cloudflare DNS module back into
[Caddy](https://caddyserver.com) whenever the `caddy` package is upgraded, **before Caddy is
started again**. If the module cannot be added, it puts the previous binary back, so Caddy
keeps running, retries every 5 minutes through a systemd timer and shows a notice at login
until it has worked.

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
on a copy of the binary, checks the result and puts it in place of `/usr/bin/caddy` with one
rename. It makes up to three attempts of 30 seconds each, 5 seconds apart. It stays silent
when there is nothing to do.

Before every dpkg run that unpacks or installs packages, it saves `/usr/bin/caddy` if that
binary has the module. That copy is the fallback described below.

## When the module cannot be added

`caddy add-package` needs Caddy's build server at `caddyserver.com`. That is a different
service from Caddy's apt repository (hosted on Cloudsmith), so the package upgrade can work
while the build server does not answer; on 2026-10-23 it did not answer for hours.

When all three attempts fail, the hook:

1. keeps the package's stock binary as `/var/lib/dpkg-caddy-cloudflare-hook/caddy.stock`,
2. puts the saved binary with the module back into `/usr/bin/caddy`, so Caddy keeps running
   in its previous version,
3. writes the marker `/var/lib/dpkg-caddy-cloudflare-hook/pending` and reports an error,
4. enables `dpkg-caddy-cloudflare-hook-retry.timer`.

**apt does not offer the update again.** The package upgrade itself succeeded, so dpkg
records the new version as installed; only the binary on disk is the older one. The timer
therefore retries every 5 minutes, outside of any dpkg run: it adds the module to the kept
stock binary (one attempt of up to 300 seconds, in case a first build after a new Caddy
release takes longer), puts the result in place, restarts Caddy and disables itself. dpkg
runs during a fallback only report it. Run by hand as root (`dpkg-caddy-cloudflare-hook --retry`),
it retries at once. If you replace `/usr/bin/caddy` yourself in the meantime, the retries
stop.

**At login** (`/etc/update-motd.d/90-dpkg-caddy-cloudflare-hook`, shown by `pam_motd`, for
example over SSH) a notice says which version is installed and which one runs, as long as the
marker exists. It goes away when a retry has worked. It is a message after login, not an
sshd `Banner`: that would be shown to anyone before authentication and need a change to the
SSH configuration.

If `/usr/bin/caddy` did not have the module before the dpkg run, nothing was saved and there
is nothing to fall back to: Caddy is left with the stock binary and the error is reported.
Without systemd there is no timer; the hook says so, and a retry by hand still works.

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

As root (`apt install git` first on minimal installations):

```bash
git clone https://github.com/MarcFauser/dpkg-caddy-cloudflare-hook.git
cd dpkg-caddy-cloudflare-hook
./install.sh
```

This installs five files and runs the hook once:

| File | Mode | Purpose |
|---|---|---|
| `/usr/local/sbin/dpkg-caddy-cloudflare-hook` | 755 | the script |
| `/etc/dpkg/dpkg.cfg.d/dpkg-caddy-cloudflare-hook` | 644 | calls it before and after every dpkg run |
| `/etc/systemd/system/dpkg-caddy-cloudflare-hook-retry.service` | 644 | one retry |
| `/etc/systemd/system/dpkg-caddy-cloudflare-hook-retry.timer` | 644 | every 5 minutes; installed disabled, enabled only during a fallback |
| `/etc/update-motd.d/90-dpkg-caddy-cloudflare-hook` | 755 | the login notice; prints nothing without a fallback |

The hook keeps its state in `/var/lib/dpkg-caddy-cloudflare-hook`: the saved binary, during
a fallback the stock binary and the marker, and briefly a work copy while `add-package`
runs. That is a few times the size of the caddy binary.

Update: `git pull` and run `./install.sh` again. Remove: `./install.sh --uninstall` (also
removes the state directory). Both as root.

## Checking that it worked

As root:

```bash
journalctl -t dpkg-caddy-cloudflare-hook
grep -n dpkg-caddy-cloudflare-hook /var/log/apt/term.log
caddy list-modules | grep -Fx dns.providers.cloudflare
cat /var/lib/dpkg-caddy-cloudflare-hook/pending   # exists only while a fallback is active
systemctl list-timers --all dpkg-caddy-cloudflare-hook-retry.timer
```

An end-to-end test is `apt install --reinstall caddy` as root: it puts the stock binary back,
and the hook has to add the module before the restart. The old Caddy process keeps running
during the download, and the restart comes from the package's `postinst` afterwards.

## Behaviour worth knowing

- **It never fails dpkg.** A failing invoke hook aborts dpkg, so the script always exits 0.
  Problems go to stderr (shown by apt and kept in `/var/log/apt/term.log`) and to the journal.
  The hook lines in `dpkg.cfg.d` also catch a crash of the script and report it. Failing on
  purpose would not roll anything back either; `HISTORY.md` explains why.
- **It holds a dpkg run for about 1.5 to 2 minutes at most** when the build server does not
  answer: three attempts of 30 seconds (plus 10 seconds if caddy ignores the first signal),
  5 seconds apart (`ADD_PACKAGE_TIMEOUT`, `ADD_PACKAGE_ATTEMPTS`, `ATTEMPT_PAUSE`). With a working build server `add-package` took 0.7 to 1.7 seconds in CI.
- **Timer runs and dpkg runs do not overlap**: both take a lock (`flock`) on
  `/var/lib/dpkg-caddy-cloudflare-hook/lock`; a timer run gives way to a running dpkg hook.
- **The binary can be newer than apt thinks.** `caddy add-package` downloads the latest
  Caddy release with the module, which may be newer than the packaged version. dpkg's
  checksum for `/usr/bin/caddy` no longer matches after that, so `dpkg --verify caddy`
  reports it.
- **It depends on Caddy's build server.** `caddy add-package` downloads from
  `caddyserver.com/api/download` with a plain `http.Get` and no timeout, and the build server
  comes without an SLA. The hook therefore limits every call and falls back as described
  above.
- **This is not a Caddy bug, as far as Caddy is concerned.** The question was raised in
  [caddyserver/dist#106](https://github.com/caddyserver/dist/issues/106) (open since 2023);
  the maintainers' answer is that Caddy's and the OS's package management do not mix, and
  their documented way is `dpkg-divert` with `update-alternatives`
  ([docs](https://caddyserver.com/docs/build#package-support-files-for-custom-builds-for-debianubunturaspbian)).
  With that, apt no longer updates the binary in use at all; this hook keeps apt in charge
  instead.
- **During a fallback, Caddy is older than the package.** `dpkg -s caddy` shows the new
  version, `caddy version` the old one, until a retry succeeds.
- `caddy add-package` is marked experimental, and a Caddy maintainer has proposed moving it
  out of the core binary into a plugin
  ([caddyserver/caddy#7010](https://github.com/caddyserver/caddy/issues/7010), open). If
  that happens, this hook needs a different way to get the module.

## Tests

```bash
bash tests/run-tests.sh
```

The unit tests run the unchanged hook against small test doubles for `caddy`, `systemctl`,
`dpkg-query` and `logger`, covering the unpack and the `dpkg -i` paths, the package states,
download and restart failures, a hanging download, the three attempts and their pause,
saving the binary before the dpkg run, the fallback, the timer being switched on and off,
the retry, the lock, the login notice, the systemd units and the lines in `dpkg.cfg.d`
themselves. They need only bash and the usual text tools, so they also run under Git for
Windows (`tests/bin` has a stand-in for `flock`).

`tests/e2e.sh` is the end-to-end test for a throwaway Debian or Ubuntu machine (it
reinstalls caddy and edits `/etc/hosts`, so not for a server that matters). It installs
Caddy from Caddy's apt repository, adds the module by hand, installs the hook, and checks
that an `apt` reinstall gets the module back in the unpack run, that `dpkg -i` gets it back
too, that with `caddyserver.com` blocked a reinstall falls back to the previous binary after
three attempts while dpkg counts the package as installed, that the login notice appears
and goes away again, that the retry adds the module, that an unrelated dpkg run stays
silent, and that `--uninstall` removes everything. With systemd it also checks that the
running Caddy process has the module after every step, that the hook restarts it after
`dpkg -i`, and that the timer is enabled by the fallback and disabled by the retry. It needs
Caddy's build server, so it fails (within minutes, with a message saying so) while that
server is not answering.

GitHub Actions (`.github/workflows/tests.yml`) runs the unit tests, the end-to-end test in
Debian 12, Debian 13 and Ubuntu 24.04 containers (no systemd), and the end-to-end test on
the Ubuntu 24.04 runner VM itself (with systemd), on every push, weekly and on demand.

## Development

On the machine you commit from, activate the version guard once after cloning:
double-click `install-git-hooks.cmd` on Windows, or run `pwsh ./install-git-hooks.ps1`. It
copies `_git_hooks/pre-commit` into `.git/hooks`, which git does not version. The hook refuses
a commit without a new version section in `CHANGELOG.md` and a matching `VERSION` in the
script. Neither file is needed on the servers.

## License

[MIT](LICENSE)
