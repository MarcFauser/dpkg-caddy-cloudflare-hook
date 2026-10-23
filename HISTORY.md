# History

A narrative log of how this project came to be. The structured, versioned list of changes
lives in CHANGELOG.md; this file records the reasoning.

## 2026-10-23 - why it exists and why it looks like this

Caddy runs on several servers here, installed from Caddy's own apt repository so that it is
always the newest release, with the Cloudflare DNS module for the ACME DNS challenge. After
every Caddy upgrade the module was gone and Caddy did not start until
`caddy add-package github.com/caddy-dns/cloudflare` was run by hand.

An earlier attempt to automate this had been worked out in a chat with another assistant.
It went through three variants:

- `dpkg-divert` plus `update-alternatives`, keeping a custom binary next to the packaged one.
  Rejected as a hack.
- An apt `DPkg::Post-Invoke` hook that runs `caddy add-package` and restarts Caddy, with a
  version stamp. Chosen at the time with the remark that a newer binary than apt thinks is
  better than an outdated one.
- Dropping the package and upgrading a standalone binary daily by cron, with validation,
  rollback and mail.

None of them could be found on any server anymore, so the hook was rebuilt. Reading the
Caddy source (v2.11.7) showed why the earlier scripts were fragile: both checked for the
plugin with `caddy list-modules --packages | grep -Fx github.com/caddy-dns/cloudflare`, but
that command prints `<module id> <package>` on each line, so the exact match never hit. The
apt hook therefore called `add-package` after every dpkg run and only worked because
`add-package` refuses with "package is already added" when the plugin is present; the cron
variant would never have upgraded at all. The rebuilt hook compares the module ID
`dns.providers.cloudflare` instead.

The first rebuild was an apt hook. It moved to dpkg's own `post-invoke` for two reasons:
apt sits on top of dpkg, so a dpkg hook also fires for a direct `dpkg -i`, and its output
ends up in `/var/log/apt/term.log` - apt runs its `DPkg::Post-Invoke` only after closing
that log (`dpkgpm.cc`).

The requirement that shaped the logic: the module must be back **before Caddy is started
again**. That works because apt runs unpack and configure as separate dpkg runs, Caddy's
package does not stop the service on upgrade, and its `postinst` restarts it only in the
configure run. So the hook adds the module after the unpack run and leaves the restart to
the `postinst`; only when the package is already configured (direct `dpkg -i`) does it
restart Caddy itself.

Two properties are deliberate. The script never exits non-zero, because a failing invoke
hook aborts dpkg and could leave an upgrade half done; failures are reported instead. And
both installed files carry the same name, `dpkg-caddy-cloudflare-hook`, so that one search
finds both and the name in `/usr/local/sbin` says what the script belongs to.

## 2026-10-23 - the build server, and falling back to the previous binary

The first GitHub Actions run hung for six hours in the end-to-end test, at the manual
`caddy add-package`. Caddy downloads its custom builds with a plain `http.Get` without a
timeout, and the build server at caddyserver.com did not answer for hours that night while
Caddy's apt repository on Cloudsmith worked fine - the two are separate services, so a
working `apt update` says nothing about the build server. On a server the hook would have
held the whole dpkg run, so 1.0.2 limited the call to 300 seconds.

That left Caddy with the stock binary and without the module, which means it does not start
with a configuration that uses Cloudflare. The question that led to 1.1.0 was whether it
would not be better to keep the old binary. It is, but by the time the post-invoke hook
runs, dpkg has already replaced it. dpkg also runs pre-invoke hooks before each action, so
the hook now saves the binary with the module there and puts it back when adding the module
fails.

The fallback raised the next question: does apt offer the update again? It does not. The
package upgrade itself succeeded, so dpkg records the new version as installed; only the
binary on disk is older. The hook therefore keeps the stock binary and the marker `pending`,
and retries by itself. It adds the module to the stock binary again rather than running
`caddy upgrade` on the old one, because `upgrade` pins every plugin to the version it
already has. Retries run at most once an hour from dpkg, so that an unanswering build server
does not hold every dpkg run for five minutes, and at once when the hook is run by hand.

While at it, `add-package` moved to a copy in the state directory. Caddy replaces the file
it runs from, so running it on `/usr/bin/caddy` meant a half-written or missing binary
there if it was killed; now `/usr/bin/caddy` is replaced with one rename after the module is
confirmed.

## 2026-10-23 - why there is no "fail and roll back", and no strict mode

The obvious alternative to the fallback was to let the hook fail, so that the installation is
marked as broken and rolled back. dpkg does not work that way. It restores old files only while
it is still unpacking; once a package is "Unpacked", the backups are gone (Debian Policy 6.6
calls this a point of no return), and errors during configuration are not unwound at all. The
post-invoke hook runs after the unpack is complete, so a failing hook only makes dpkg exit with
an error. apt then stops (`Dpkg::StopOnError`) without the configure run, for every package in
that run. Caddy would be left half-installed with the stock binary, and the `apt --fix-broken
install` that apt asks for next would start it without the module.

Other hooks were compared before deciding:

- apt's `DPkg::Pre-Install-Pkgs` runs before dpkg touches anything and knows which packages and
  versions are coming. It could build the new binary in advance and abort the apt run if that
  fails - a strict mode that refuses the upgrade instead of falling back. Rejected: an abort
  stops all other updates of that run as long as the build server is down, it does not cover
  `dpkg -i`, and for Caddy the result is the same as the fallback (the old binary with the
  module keeps running). The only gain would be that dpkg still lists the old version.
- apt's `DPkg::Post-Invoke` runs after all dpkg runs, which is after Caddy's restart.
- A dpkg file trigger on `/usr/bin/caddy` needs a package of its own, and apt passes
  `--no-triggers` to every dpkg run but the last, so it would also run after the restart.
- A systemd `ExecStartPre` runs only after the old process was stopped, so Caddy would be down
  during the download.

So the fallback with the two dpkg hooks stays.
