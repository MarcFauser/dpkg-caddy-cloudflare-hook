#!/bin/bash
# End-to-end test on a real Debian or Ubuntu system, meant for a throwaway container (the
# GitHub Actions workflow runs it in Debian 12, Debian 13 and Ubuntu 24.04). It installs Caddy
# from Caddy's apt repository, adds the Cloudflare module by hand as on a real server,
# installs the hook and checks both upgrade paths. Do not run it on a server that matters:
# it reinstalls caddy. Containers have no systemd, so the service restart is not covered.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$(mktemp -d)"
TAG="dpkg-caddy-cloudflare-hook"
export DEBIAN_FRONTEND=noninteractive

step()
{
    echo
    echo "== $*"
}

fail()
{
    echo "FAIL: $*" >&2
    exit 1
}

has_module()
{
    caddy list-modules | grep -Fxq dns.providers.cloudflare
}

step "install Caddy from Caddy's apt repository (commands from caddyserver.com/docs/install)"
apt-get update -q
apt-get install -y -q debian-keyring debian-archive-keyring apt-transport-https curl gnupg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' > /etc/apt/sources.list.d/caddy-stable.list
chmod o+r /usr/share/keyrings/caddy-stable-archive-keyring.gpg
chmod o+r /etc/apt/sources.list.d/caddy-stable.list
apt-get update -q
apt-get install -y -q caddy
caddy version

step "the stock package has no Cloudflare module (control)"
if has_module
then
    fail "stock caddy already lists dns.providers.cloudflare; the test would prove nothing"
fi

step "add the module by hand, as on a real server"
caddy add-package github.com/caddy-dns/cloudflare > "$LOG_DIR/add-package.log" 2>&1 || { cat "$LOG_DIR/add-package.log"; fail "manual caddy add-package failed"; }
has_module || fail "module missing after the manual add-package"

step "install the hook"
bash "$HERE/../install.sh"
"/usr/local/sbin/$TAG" --version

step "apt path: a reinstall puts the stock binary back, the hook must add the module in the unpack run"
apt-get install -y -q --reinstall caddy 2>&1 | tee "$LOG_DIR/apt.log"
has_module || fail "module missing after apt reinstall"
grep -q "package state: install ok unpacked, dpkg action: unpack" "$LOG_DIR/apt.log" \
    || fail "the hook did not add the module after the unpack run"
grep -q "postinst will restart" "$LOG_DIR/apt.log" \
    || fail "the hook did not leave the restart to the postinst"
grep -q "$TAG: .*package state: install ok unpacked" /var/log/apt/term.log \
    || fail "the hook output is not in /var/log/apt/term.log"

step "dpkg -i path: one run, the hook comes after the postinst"
(cd "$LOG_DIR" && apt-get download caddy)
dpkg -i "$LOG_DIR"/caddy_*.deb 2>&1 | tee "$LOG_DIR/dpkg.log"
has_module || fail "module missing after dpkg -i"
grep -q "package state: install ok installed, dpkg action: install" "$LOG_DIR/dpkg.log" \
    || fail "the hook did not add the module after dpkg -i"

step "a dpkg run that does not touch caddy stays silent"
apt-get install -y -q tree 2>&1 | tee "$LOG_DIR/other.log"
if grep -q "$TAG" "$LOG_DIR/other.log"
then
    fail "the hook printed something although the module was present"
fi

step "uninstall removes both files"
bash "$HERE/../install.sh" --uninstall
[ ! -e "/usr/local/sbin/$TAG" ] && [ ! -e "/etc/dpkg/dpkg.cfg.d/$TAG" ] || fail "files left after --uninstall"

echo
echo "end-to-end test passed"
