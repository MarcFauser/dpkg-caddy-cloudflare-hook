#!/bin/bash
# Runs dpkg-caddy-cloudflare-hook against test doubles for caddy, systemctl, dpkg-query, logger.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="${HOOK:-$HERE/../usr/local/sbin/dpkg-caddy-cloudflare-hook}"
CONF="$HERE/../etc/dpkg/dpkg.cfg.d/dpkg-caddy-cloudflare-hook"
BIN="$HERE/bin"
passed=0
failed=0

setup()
{
    STATE="$(mktemp -d)"
    export STATE
    : > "$STATE/calls"
    for flag in "$@"
    do
        case "$flag" in
            module=*) printf '%s\n' "${flag#module=}" > "$STATE/module" ;;
            status=*) printf '%s' "${flag#status=}" > "$STATE/status" ;;
            *)        touch "$STATE/$flag" ;;
        esac
    done
}

run_hook()
{
    ERR="$(CADDY_BIN="${TEST_CADDY_BIN:-$BIN/caddy}" ADD_PACKAGE_TIMEOUT="${TEST_TIMEOUT:-300}" PATH="$BIN:$PATH" bash "$HOOK" 2>&1 >/dev/null)"
    RC=$?
    CALLS="$(cat "$STATE/calls")"
}

check()
{
    if eval "$2"
    then
        passed=$((passed + 1))
        echo "   ok    $1"
    else
        failed=$((failed + 1))
        echo "   FAIL  $1"
        echo "         stderr: $ERR"
        echo "         calls:  $(printf '%s' "$CALLS" | tr '\n' '|')"
    fi
}

echo "1 caddy not installed"
setup notinstalled; run_hook
check "exit 0" '[ "$RC" -eq 0 ]'
check "silent" '[ -z "$ERR" ]'
check "no add-package" '! grep -q add-package <<< "$CALLS"'

echo "2 module present"
setup module=dns.providers.cloudflare enabled active; run_hook
check "exit 0" '[ "$RC" -eq 0 ]'
check "silent" '[ -z "$ERR" ]'
check "no add-package" '! grep -q add-package <<< "$CALLS"'
check "no restart" '! grep -q "systemctl restart" <<< "$CALLS"'

echo "3 module present, line carries an error suffix"
setup "module=dns.providers.cloudflare [provision warning]" enabled; run_hook
check "silent" '[ -z "$ERR" ]'
check "no add-package" '! grep -q add-package <<< "$CALLS"'

echo "4 module missing, service enabled and failed (state after the package's own restart)"
setup enabled failed; run_hook
check "exit 0" '[ "$RC" -eq 0 ]'
check "add-package called" 'grep -q "add-package github.com/caddy-dns/cloudflare" <<< "$CALLS"'
check "restart called" 'grep -q "systemctl restart caddy" <<< "$CALLS"'
check "reports restart" 'grep -q "caddy restarted" <<< "$ERR"'
check "no ERROR" '! grep -q ERROR <<< "$ERR"'

echo "5 module missing, service not in use"
setup; run_hook
check "add-package called" 'grep -q add-package <<< "$CALLS"'
check "no restart" '! grep -q "systemctl restart" <<< "$CALLS"'
check "reports module added" 'grep -q "module added" <<< "$ERR"'

echo "6 module missing, download fails"
setup enabled netfail; run_hook
check "exit 0 despite failure" '[ "$RC" -eq 0 ]'
check "reports ERROR with cause" 'grep -q "ERROR: caddy add-package failed" <<< "$ERR" && grep -q "no such host" <<< "$ERR"'
check "error goes to journal" 'grep -q "logger -t dpkg-caddy-cloudflare-hook -p user.err" <<< "$CALLS"'
check "no restart" '! grep -q "systemctl restart" <<< "$CALLS"'

echo "7 add-package claims success, module still missing"
setup enabled addbroken; run_hook
check "reports still missing" 'grep -q "still missing" <<< "$ERR"'
check "no restart" '! grep -q "systemctl restart" <<< "$CALLS"'

echo "8 restart fails"
setup enabled restartfail; run_hook
check "exit 0" '[ "$RC" -eq 0 ]'
check "reports restart failure" 'grep -q "systemctl restart caddy failed" <<< "$ERR"'

echo "9 restart returns 0, service not active"
setup enabled staysdown; run_hook
check "reports not active" 'grep -q "not active after the restart" <<< "$ERR"'

echo "12 after the unpack run: module missing, service running (apt upgrade path)"
setup "status=install ok unpacked" enabled active; DPKG_HOOK_ACTION=unpack; export DPKG_HOOK_ACTION; run_hook; unset DPKG_HOOK_ACTION
check "exit 0" '[ "$RC" -eq 0 ]'
check "add-package called" 'grep -q add-package <<< "$CALLS"'
check "NO restart, the postinst does it" '! grep -q "systemctl restart" <<< "$CALLS"'
check "says the postinst will restart" 'grep -q "postinst will restart" <<< "$ERR"'
check "names state and action" 'grep -q "package state: install ok unpacked, dpkg action: unpack" <<< "$ERR"'

echo "13 half-configured: module missing"
setup "status=install ok half-configured" enabled; run_hook
check "add-package called" 'grep -q add-package <<< "$CALLS"'
check "NO restart" '! grep -q "systemctl restart" <<< "$CALLS"'

echo "14 only config files left (package removed)"
setup "status=deinstall ok config-files" enabled; run_hook
check "silent" '[ -z "$ERR" ]'
check "no add-package" '! grep -q add-package <<< "$CALLS"'

echo "15 held package, installed, module missing (dpkg -i path)"
setup "status=hold ok installed" enabled failed; run_hook
check "add-package called" 'grep -q add-package <<< "$CALLS"'
check "restart called" 'grep -q "systemctl restart caddy" <<< "$CALLS"'

echo "16 after the unpack run, module already there"
setup "status=install ok unpacked" module=dns.providers.cloudflare enabled active; run_hook
check "silent" '[ -z "$ERR" ]'
check "no add-package" '! grep -q add-package <<< "$CALLS"'

echo "17 version and syntax"
VER_OUT="$(bash "$HOOK" --version)"
VER="${VER_OUT##* }"
CHG="$(sed -n 's/^## \[\([0-9][0-9.]*\)\].*/\1/p' "$HERE/../CHANGELOG.md" | head -n 1)"
ERR="version: $VER_OUT, changelog: $CHG"; CALLS=""
check "--version names the tool" 'case "$VER_OUT" in "dpkg-caddy-cloudflare-hook "*) true ;; *) false ;; esac'
check "script version equals newest CHANGELOG version" '[ -n "$VER" ] && [ "$VER" = "$CHG" ]'
check "hook script parses" 'bash -n "$HOOK"'
check "install.sh parses" 'bash -n "$HERE/../install.sh"'
echo "18 add-package hangs (build server not answering)"
setup enabled hang; TEST_TIMEOUT=2; started=$SECONDS; run_hook; took=$((SECONDS - started)); unset TEST_TIMEOUT
check "exit 0" '[ "$RC" -eq 0 ]'
check "reports the time limit" 'grep -q "did not finish within 2 s" <<< "$ERR"'
check "returns within the limit (took ${took}s)" '[ "$took" -lt 20 ]'
check "no restart" '! grep -q "systemctl restart" <<< "$CALLS"'

echo "19 killed after caddy parked its binary as .tmp"
setup enabled hangafterrename; mkdir "$STATE/bin"; cp "$BIN/caddy" "$STATE/bin/caddy"
TEST_CADDY_BIN="$STATE/bin/caddy"; TEST_TIMEOUT=2; run_hook; unset TEST_CADDY_BIN TEST_TIMEOUT
check "reports the time limit" 'grep -q "did not finish within 2 s" <<< "$ERR"'
check "reports the restore" 'grep -q "put the previous binary back" <<< "$ERR"'
check "previous binary is back" 'cmp -s "$BIN/caddy" "$STATE/bin/caddy"'
check "no .tmp left" '[ ! -e "$STATE/bin/caddy.tmp" ]'

echo "20 a .tmp that was there before is not ours"
setup enabled netfail; mkdir "$STATE/bin"; cp "$BIN/caddy" "$STATE/bin/caddy"; echo stale > "$STATE/bin/caddy.tmp"
TEST_CADDY_BIN="$STATE/bin/caddy"; run_hook; unset TEST_CADDY_BIN
check "reports the failure" 'grep -q "caddy add-package failed" <<< "$ERR"'
check "does not restore" '! grep -q "put the previous binary back" <<< "$ERR"'
check "old .tmp untouched" '[ "$(cat "$STATE/bin/caddy.tmp")" = stale ]'
check "binary untouched" 'cmp -s "$BIN/caddy" "$STATE/bin/caddy"'

echo "10 control: the old check misses a present module"
setup module=dns.providers.cloudflare
ERR=""; CALLS=""
"$BIN/caddy" list-modules --packages | grep -Fxq github.com/caddy-dns/cloudflare
OLD=$?
"$BIN/caddy" list-modules | awk -v id=dns.providers.cloudflare '$1 == id { found = 1 } END { exit !found }'
NEW=$?
check "old grep -Fx check: no match (exit 1)" '[ "$OLD" -eq 1 ]'
check "new awk check: match (exit 0)" '[ "$NEW" -eq 0 ]'

echo "11 the dpkg.cfg.d command line"
CMD="$(sed -n 's/^post-invoke=//p' "$CONF")"
check "command extracted" '[ -n "$CMD" ]'
CRASH="$(mktemp -d)/crash-hook"
printf '#!/bin/bash\nexit 3\n' > "$CRASH"
chmod +x "$CRASH"
ERR="$(sh -c "${CMD//\/usr\/local\/sbin\/dpkg-caddy-cloudflare-hook/$CRASH}" 2>&1)"; RC=$?; CALLS=""
check "crashing script: apt sees 0" '[ "$RC" -eq 0 ]'
check "crashing script: message shown" 'grep -q "unexpected failure" <<< "$ERR"'
ERR="$(sh -c "${CMD//\/usr\/local\/sbin\/dpkg-caddy-cloudflare-hook//nonexistent/hook}" 2>&1)"; RC=$?
check "missing script: apt sees 0" '[ "$RC" -eq 0 ]'
check "missing script: silent" '[ -z "$ERR" ]'

echo
echo "passed: $passed  failed: $failed"
[ "$failed" -eq 0 ]
