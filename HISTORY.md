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
