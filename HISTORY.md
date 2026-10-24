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

## 2026-10-23 - shorter attempts, a retry timer and a login notice

The weak point of 1.1 was not the 300-second limit but the retry: it only happened at a
later dpkg run, and on a quiet server that can be days away. Measured in CI, `add-package`
takes 0.7 to 1.7 seconds when the build server works, so a dpkg run now makes three
attempts of 30 seconds and then falls back right away; apt is held for about two minutes at
most.
Twenty short attempts inside the dpkg run were considered and rejected, because they would
hold apt for ten minutes during an outage, and the fallback makes waiting there pointless.

The retries moved out of dpkg into a systemd timer, every 5 minutes, enabled by the fallback
and disabled by the first retry that works. A cron.d entry was the first idea; the timer
won because systemd is always there where Caddy runs as a service (cron is a separate
package, and a cron.d file without cron does nothing, silently), because a timer does not
start a run that is still going (cron would need its own lock against the 300-second
attempts), and because the unit files can be installed once and only switched on and off,
instead of being written and deleted at runtime. The retries outside dpkg keep the long
limit, in case a first build after a new Caddy release takes longer than 30 seconds; that
case has not been measured.

The login notice comes from `/etc/update-motd.d`, which `pam_motd` runs at every login. The
script is installed once and prints the marker only while it exists, so nothing has to be
created or removed when the state changes. An sshd `Banner` was not used: it is shown to
anyone before authentication and would need a change to the SSH configuration.

The question whether Caddy treats the lost plugins as a bug has an answer:
caddyserver/dist#106 (open since 2023) asks for exactly this, and the maintainers reply that
Caddy's own package management and the OS's do not mix; their documented way is
`dpkg-divert` with `update-alternatives`, which takes the binary in use out of apt's hands.
This hook keeps apt in charge instead.

## 2026-10-25 - superseded by caddy-deb

The hook worked and was well tested, but it remained a workaround: it wrote into a file that
belongs to dpkg, behind dpkg's back, and depended on `caddy add-package`, which Caddy marks
as experimental, and on Caddy's build server. The clean way is to package Caddy with the
plugin built in, the way Caddy packages itself, so that apt manages exactly the binary that
runs. That is [caddy-deb](https://github.com/MarcFauser/caddy-deb), an apt repository built
and signed in GitHub Actions; its HISTORY.md has the reasoning. The servers were moved to it
on 2026-10-25, and this repository was archived.
