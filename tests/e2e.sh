#!/bin/bash
# End-to-end test on a real Debian or Ubuntu system, meant for a throwaway container (the
# GitHub Actions workflow runs it in Debian 12, Debian 13 and Ubuntu 24.04). It installs Caddy
# from Caddy's apt repository, adds the Cloudflare module by hand as on a real server,
# installs the hook and checks both upgrade paths and the fallback (caddyserver.com blocked
# in /etc/hosts). Do not run it on a server that matters: it reinstalls caddy and edits
# /etc/hosts. Containers have no systemd, so the service restart is not covered.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
LOG_DIR="$(mktemp -d)"
TAG="dpkg-caddy-cloudflare-hook"
STATE_DIR="/var/lib/$TAG"
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
# caddy downloads without a timeout from a build server without an SLA; the first CI run
# waited six hours here, so the call is limited.
rc=0
timeout --kill-after=10 600 caddy add-package github.com/caddy-dns/cloudflare > "$LOG_DIR/add-package.log" 2>&1 || rc=$?
if [ "$rc" -ne 0 ]
then
    cat "$LOG_DIR/add-package.log"
    if [ "$rc" -eq 124 ] || [ "$rc" -eq 137 ]
    then
        fail "caddy add-package did not finish within 600 s: the build server at caddyserver.com is not answering"
    fi
    fail "manual caddy add-package failed (exit $rc)"
fi
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
"$STATE_DIR/caddy.previous" list-modules | grep -Fxq dns.providers.cloudflare \
    || fail "pre-invoke did not save the binary with the module before the unpack run"

step "dpkg -i path: one run, the hook comes after the postinst"
(cd "$LOG_DIR" && apt-get download caddy)
dpkg -i "$LOG_DIR"/caddy_*.deb 2>&1 | tee "$LOG_DIR/dpkg.log"
has_module || fail "module missing after dpkg -i"
grep -q "package state: install ok installed, dpkg action: install" "$LOG_DIR/dpkg.log" \
    || fail "the hook did not add the module after dpkg -i"

step "fallback: caddyserver.com unreachable, an apt reinstall must put the previous binary back"
cp /etc/hosts "$LOG_DIR/hosts"
echo "0.0.0.0 caddyserver.com" >> /etc/hosts
before="$(sha256sum < /usr/bin/caddy)"
apt-get install -y -q --reinstall caddy 2>&1 | tee "$LOG_DIR/fallback.log"
# /etc/hosts may be a bind mount in a container: write it back in place
cat "$LOG_DIR/hosts" > /etc/hosts
has_module || fail "module missing after the fallback"
[ "$(sha256sum < /usr/bin/caddy)" = "$before" ] || fail "the binary is not the one that ran before the reinstall"
grep -q "put the previous binary" "$LOG_DIR/fallback.log" || fail "the hook did not report the fallback"
grep -q "still waiting" "$LOG_DIR/fallback.log" || fail "the configure run did not report the waiting fallback"
[ -f "$STATE_DIR/pending" ] || fail "no fallback marker"
[ -f "$STATE_DIR/caddy.stock" ] || fail "the stock binary was not kept"
cat "$STATE_DIR/pending"
[ "$(dpkg-query -W -f='${Status}' caddy)" = "install ok installed" ] || fail "caddy is not fully installed after the fallback"
# captured first: with pipefail, grep -q ending the pipe early would turn a hit into a miss
simulated="$(apt-get -s -q upgrade)"
if grep -q '^Inst caddy ' <<< "$simulated"
then
    fail "apt offers caddy again"
fi

step "retry by hand once caddyserver.com is reachable again"
"/usr/local/sbin/$TAG" 2>&1 | tee "$LOG_DIR/retry.log"
has_module || fail "module missing after the retry"
grep -q "module added" "$LOG_DIR/retry.log" || fail "the retry did not add the module"
[ ! -e "$STATE_DIR/pending" ] && [ ! -e "$STATE_DIR/caddy.stock" ] || fail "fallback state left after the retry"

step "a dpkg run that does not touch caddy stays silent"
apt-get install -y -q tree 2>&1 | tee "$LOG_DIR/other.log"
if grep -q "$TAG" "$LOG_DIR/other.log"
then
    fail "the hook printed something although the module was present"
fi

step "uninstall removes both files and the state directory"
bash "$HERE/../install.sh" --uninstall
[ ! -e "/usr/local/sbin/$TAG" ] && [ ! -e "/etc/dpkg/dpkg.cfg.d/$TAG" ] && [ ! -e "$STATE_DIR" ] \
    || fail "files left after --uninstall"

echo
echo "end-to-end test passed"
