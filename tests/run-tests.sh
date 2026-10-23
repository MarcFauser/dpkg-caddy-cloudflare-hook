#!/bin/bash
# Runs dpkg-caddy-cloudflare-hook against test doubles for caddy, systemctl, dpkg-query, logger.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
HOOK="${HOOK:-$HERE/../usr/local/sbin/dpkg-caddy-cloudflare-hook}"
CONF="$HERE/../etc/dpkg/dpkg.cfg.d/dpkg-caddy-cloudflare-hook"
BIN="$HERE/bin"
passed=0
failed=0

# A copy of the caddy double; $2 and $3 write the module and the version into the copy.
mkbin()
{
    mkdir -p "$(dirname "$1")"
    cp "$BIN/caddy" "$1"
    if [ -n "${2:-}" ]
    then
        echo "# fake-module: $2" >> "$1"
    fi
    if [ -n "${3:-}" ]
    then
        echo "# fake-version: $3" >> "$1"
    fi
    chmod 755 "$1"
}

# Every test gets its own caddy binary $CB (a stock copy) and state directory $SD.
setup()
{
    STATE="$(mktemp -d)"
    export STATE
    CB="$STATE/bin/caddy"
    SD="$STATE/var"
    : > "$STATE/calls"
    mkbin "$CB"
    for flag in "$@"
    do
        case "$flag" in
            module=*) printf '%s\n' "${flag#module=}" > "$STATE/module" ;;
            status=*) printf '%s' "${flag#status=}" > "$STATE/status" ;;
            *)        touch "$STATE/$flag" ;;
        esac
    done
}

# A fallback is active: the previous binary (v2.11.6, with the module) runs, the stock
# binary is kept, the marker is there.
mkpending()
{
    mkdir -p "$SD"
    mkbin "$CB" dns.providers.cloudflare v2.11.6
    cp "$CB" "$SD/caddy.previous"
    cp "$BIN/caddy" "$SD/caddy.stock"
    echo "caddy package 2.11.7 is installed, the previous binary v2.11.6 runs instead" > "$SD/pending"
}

# Runs the hook with the options given; ACT sets DPKG_HOOK_ACTION, unset means "by hand".
run_hook()
{
    local envs=(CADDY_BIN="$CB" HOOK_STATE_DIR="$SD" ADD_PACKAGE_TIMEOUT="${TEST_TIMEOUT:-300}" RETRY_INTERVAL="${TEST_RETRY:-60}" PATH="$BIN:$PATH")
    if [ -n "${ACT:-}" ]
    then
        envs+=(DPKG_HOOK_ACTION="$ACT")
    fi
    ERR="$(env -u DPKG_HOOK_ACTION "${envs[@]}" bash "$HOOK" "$@" 2>&1 >/dev/null)"
    RC=$?
    CALLS="$(cat "$STATE/calls")"
}

version_of()
{
    "$1" version | awk '{ print $1 }'
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

echo "0 control: the caddy double itself"
setup
check "a stock copy has no module" '! "$CB" list-modules | grep -q cloudflare'
check "a stock copy reports v2.11.7" '[ "$(version_of "$CB")" = v2.11.7 ]'
mkbin "$STATE/marked" dns.providers.cloudflare v2.11.6
check "a marked copy has the module" '"$STATE/marked" list-modules | grep -qx dns.providers.cloudflare'
check "a marked copy reports its version" '[ "$(version_of "$STATE/marked")" = v2.11.6 ]'

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
check "add-package ran on the copy in the work directory" 'grep -q "on $SD/work/caddy" <<< "$CALLS"'
check "binary now has the module" '"$CB" list-modules | grep -qx dns.providers.cloudflare'
check "binary is the new build" '[ "$(version_of "$CB")" = v2.11.8 ]'
check "work directory removed" '[ ! -e "$SD/work" ]'
check "no fallback marker" '[ ! -e "$SD/pending" ]'
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
setup "status=install ok unpacked" enabled active; ACT=unpack run_hook
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

echo "19 killed after caddy parked its copy as .tmp, nothing saved to fall back to"
setup enabled hangafterrename; TEST_TIMEOUT=2; run_hook; unset TEST_TIMEOUT
check "reports the time limit" 'grep -q "did not finish within 2 s" <<< "$ERR"'
check "says there is nothing to fall back to" 'grep -q "no saved binary with the module" <<< "$ERR"'
check "binary untouched" 'cmp -s "$BIN/caddy" "$CB"'
check "no .tmp next to the binary" '[ ! -e "$CB.tmp" ]'
check "work directory removed" '[ ! -e "$SD/work" ]'

echo "20 a .tmp next to the binary is not ours"
setup enabled netfail; echo stale > "$CB.tmp"; run_hook
check "reports the failure" 'grep -q "caddy add-package failed" <<< "$ERR"'
check "old .tmp untouched" '[ "$(cat "$CB.tmp")" = stale ]'
check "binary untouched" 'cmp -s "$BIN/caddy" "$CB"'

echo "21 pre-invoke before an unpack run saves the binary with the module"
setup; mkbin "$CB" dns.providers.cloudflare v2.11.6; ACT=unpack run_hook --pre-invoke
check "exit 0" '[ "$RC" -eq 0 ]'
check "silent" '[ -z "$ERR" ]'
check "saved copy equals the binary" 'cmp -s "$CB" "$SD/caddy.previous"'
check "noted in the journal" 'grep -q "saved .* as $SD/caddy.previous" <<< "$CALLS"'
check "no add-package" '! grep -q add-package <<< "$CALLS"'

echo "22 pre-invoke before dpkg -i saves it too"
setup; mkbin "$CB" dns.providers.cloudflare v2.11.6; ACT=install run_hook --pre-invoke
check "saved copy equals the binary" 'cmp -s "$CB" "$SD/caddy.previous"'

echo "23 pre-invoke before a configure run saves nothing"
setup; mkbin "$CB" dns.providers.cloudflare v2.11.6; ACT=configure run_hook --pre-invoke
check "nothing saved" '[ ! -e "$SD/caddy.previous" ]'

echo "24 pre-invoke ignores the stock binary and keeps the saved one"
setup; mkbin "$SD/caddy.previous" dns.providers.cloudflare v2.11.6; ACT=unpack run_hook --pre-invoke
check "saved copy is still v2.11.6" '[ "$(version_of "$SD/caddy.previous")" = v2.11.6 ]'
check "no save noted" '! grep -q saved <<< "$CALLS"'

echo "25 pre-invoke does not copy an unchanged binary again"
setup; mkbin "$CB" dns.providers.cloudflare v2.11.6; mkdir -p "$SD"; cp "$CB" "$SD/caddy.previous"; ACT=unpack run_hook --pre-invoke
check "no save noted" '! grep -q saved <<< "$CALLS"'
check "silent" '[ -z "$ERR" ]'

echo "26 pre-invoke saves nothing while a fallback is active"
setup; mkpending; mkbin "$CB" dns.providers.cloudflare v2.11.9; ACT=unpack run_hook --pre-invoke
check "saved copy is still v2.11.6" '[ "$(version_of "$SD/caddy.previous")" = v2.11.6 ]'

echo "27 pre-invoke with caddy not installed"
setup notinstalled; ACT=unpack run_hook --pre-invoke
check "silent" '[ -z "$ERR" ]'
check "no state directory" '[ ! -e "$SD" ]'

echo "28 add-package fails after the unpack run: the previous binary goes back (apt path)"
setup "status=install ok unpacked" enabled active netfail; mkbin "$SD/caddy.previous" dns.providers.cloudflare v2.11.6; ACT=unpack run_hook
check "exit 0" '[ "$RC" -eq 0 ]'
check "reports the cause" 'grep -q "ERROR: caddy add-package failed" <<< "$ERR" && grep -q "no such host" <<< "$ERR"'
check "reports the fallback" 'grep -q "put the previous binary (v2.11.6, with the module) back" <<< "$ERR"'
check "says apt will not offer it again" 'grep -q "apt will not offer it again" <<< "$ERR"'
check "binary is the previous one" 'cmp -s "$SD/caddy.previous" "$CB"'
check "stock binary kept" 'cmp -s "$BIN/caddy" "$SD/caddy.stock"'
check "marker names both versions" 'grep -q "caddy package 2.11.7 is installed, the previous binary v2.11.6" "$SD/pending"'
check "work directory removed" '[ ! -e "$SD/work" ]'
check "NO restart, the postinst does it" '! grep -q "systemctl restart" <<< "$CALLS"'
check "says the postinst will restart" 'grep -q "postinst will restart" <<< "$ERR"'

echo "29 add-package fails after dpkg -i: previous binary back and Caddy restarted"
setup enabled failed netfail; mkbin "$SD/caddy.previous" dns.providers.cloudflare v2.11.6; ACT=install run_hook
check "binary is the previous one" 'cmp -s "$SD/caddy.previous" "$CB"'
check "restart called" 'grep -q "systemctl restart caddy" <<< "$CALLS"'
check "reports restart" 'grep -q "caddy restarted" <<< "$ERR"'

echo "30 add-package hangs: falls back within the limit"
setup enabled hang; mkbin "$SD/caddy.previous" dns.providers.cloudflare v2.11.6; TEST_TIMEOUT=2; started=$SECONDS; ACT=unpack run_hook; took=$((SECONDS - started)); unset TEST_TIMEOUT
check "reports the time limit" 'grep -q "did not finish within 2 s" <<< "$ERR"'
check "binary is the previous one" 'cmp -s "$SD/caddy.previous" "$CB"'
check "returns within the limit (took ${took}s)" '[ "$took" -lt 20 ]'

echo "31 add-package claims success without the module: falls back"
setup enabled addbroken; mkbin "$SD/caddy.previous" dns.providers.cloudflare v2.11.6; ACT=unpack run_hook
check "reports still missing" 'grep -q "still missing" <<< "$ERR"'
check "binary is the previous one" 'cmp -s "$SD/caddy.previous" "$CB"'

echo "32 a saved binary without the module is not used"
setup enabled netfail; mkbin "$SD/caddy.previous"; ACT=unpack run_hook
check "says there is nothing to fall back to" 'grep -q "no saved binary with the module" <<< "$ERR"'
check "binary untouched" 'cmp -s "$BIN/caddy" "$CB"'
check "no marker" '[ ! -e "$SD/pending" ]'

echo "33 fallback active, dpkg run within the interval: no retry yet"
setup enabled active; mkpending; ACT=configure run_hook
check "exit 0" '[ "$RC" -eq 0 ]'
check "no add-package" '! grep -q add-package <<< "$CALLS"'
check "says it is still waiting" 'grep -q "still waiting: caddy package 2.11.7" <<< "$ERR"'
check "marker kept" '[ -f "$SD/pending" ]'
check "binary untouched" 'cmp -s "$SD/caddy.previous" "$CB"'

echo "34 fallback active, interval over: the retry adds the module to the stock binary"
setup enabled active; mkpending; TEST_RETRY=0; ACT=configure run_hook; unset TEST_RETRY
check "add-package ran on a copy of the stock binary" 'grep -q "add-package github.com/caddy-dns/cloudflare on $SD/work/caddy" <<< "$CALLS"'
check "binary is the new build with the module" '[ "$(version_of "$CB")" = v2.11.8 ] && "$CB" list-modules | grep -qx dns.providers.cloudflare'
check "marker removed" '[ ! -e "$SD/pending" ]'
check "stock copy removed" '[ ! -e "$SD/caddy.stock" ]'
check "restart called" 'grep -q "systemctl restart caddy" <<< "$CALLS"'
check "no ERROR" '! grep -q ERROR <<< "$ERR"'

echo "35 fallback active, run by hand: retries at once"
setup; mkpending; run_hook
check "add-package called" 'grep -q add-package <<< "$CALLS"'
check "marker removed" '[ ! -e "$SD/pending" ]'

echo "36 retry fails: the previous binary keeps running, the next try waits again"
setup enabled active netfail; mkpending; touch -d "2 hours ago" "$SD/pending"; ACT=configure run_hook
check "reports the cause" 'grep -q "ERROR: caddy add-package failed" <<< "$ERR"'
check "says the previous binary keeps running" 'grep -q "previous binary keeps running" <<< "$ERR"'
check "binary untouched" 'cmp -s "$SD/caddy.previous" "$CB"'
check "marker kept and touched" '[ -n "$(find "$SD/pending" -mmin -5)" ]'
check "stock copy kept" '[ -f "$SD/caddy.stock" ]'
check "no restart" '! grep -q "systemctl restart" <<< "$CALLS"'

echo "37 binary replaced by hand during a fallback: retries stop"
setup; mkpending; mkbin "$CB" dns.providers.cloudflare v2.11.9; run_hook
check "says it changed" 'grep -q "changed since the fallback" <<< "$ERR"'
check "no add-package" '! grep -q add-package <<< "$CALLS"'
check "marker removed" '[ ! -e "$SD/pending" ]'
check "binary untouched" '[ "$(version_of "$CB")" = v2.11.9 ]'

echo "38 stock copy gone: retries stop with a hint"
setup; mkpending; rm "$SD/caddy.stock"; run_hook
check "points to a reinstall" 'grep -q "apt install --reinstall caddy" <<< "$ERR"'
check "marker removed" '[ ! -e "$SD/pending" ]'

echo "39 a new package arrives during a fallback and the module can be added: fallback over"
setup "status=install ok unpacked"; mkpending; mkbin "$CB"; ACT=unpack run_hook
check "binary has the module" '"$CB" list-modules | grep -qx dns.providers.cloudflare'
check "marker removed" '[ ! -e "$SD/pending" ]'
check "old stock copy removed" '[ ! -e "$SD/caddy.stock" ]'

echo "40 unknown option"
setup; run_hook --frobnicate
check "exit 2" '[ "$RC" -eq 2 ]'
check "names the option" 'grep -q "unknown option --frobnicate" <<< "$ERR"'

echo "10 control: the old check misses a present module"
setup module=dns.providers.cloudflare
ERR=""; CALLS=""
"$BIN/caddy" list-modules --packages | grep -Fxq github.com/caddy-dns/cloudflare
OLD=$?
"$BIN/caddy" list-modules | awk -v id=dns.providers.cloudflare '$1 == id { found = 1 } END { exit !found }'
NEW=$?
check "old grep -Fx check: no match (exit 1)" '[ "$OLD" -eq 1 ]'
check "new awk check: match (exit 0)" '[ "$NEW" -eq 0 ]'

echo "11 the dpkg.cfg.d command lines"
CRASH="$(mktemp -d)/crash-hook"
printf '#!/bin/bash\nexit 3\n' > "$CRASH"
chmod +x "$CRASH"
check "exactly one pre-invoke and one post-invoke line" '[ "$(grep -c "^pre-invoke=" "$CONF")" -eq 1 ] && [ "$(grep -c "^post-invoke=" "$CONF")" -eq 1 ]'
for hook in pre post
do
    CMD="$(sed -n "s/^$hook-invoke=//p" "$CONF")"; CALLS=""
    check "$hook: command extracted" '[ -n "$CMD" ]'
    check "$hook: passes --$hook-invoke" 'grep -q -- "dpkg-caddy-cloudflare-hook --$hook-invoke ||" <<< "$CMD"'
    check "$hook: shorter than dpkg's 1024 characters" '[ "${#CMD}" -lt 1000 ]'
    ERR="$(sh -c "${CMD//\/usr\/local\/sbin\/dpkg-caddy-cloudflare-hook/$CRASH}" 2>&1)"; RC=$?
    check "$hook: crashing script: dpkg sees 0" '[ "$RC" -eq 0 ]'
    check "$hook: crashing script: message shown" 'grep -q "unexpected failure" <<< "$ERR"'
    ERR="$(sh -c "${CMD//\/usr\/local\/sbin\/dpkg-caddy-cloudflare-hook//nonexistent/hook}" 2>&1)"; RC=$?
    check "$hook: missing script: dpkg sees 0" '[ "$RC" -eq 0 ]'
    check "$hook: missing script: silent" '[ -z "$ERR" ]'
done

echo
echo "passed: $passed  failed: $failed"
[ "$failed" -eq 0 ]
