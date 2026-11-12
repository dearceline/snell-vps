#!/usr/bin/env bash
# Run only on a disposable Linux systemd runner, as root.
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
[[ $EUID == 0 && -d /run/systemd/system ]] || exit 1
export SNELL_SOURCE_ORDER=official
manager() { bash ./snell.sh "$@"; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
reject() { if "$@"; then fail "unexpected success: $*"; fi; }
systemctl() {
    if [[ ${1:-} == restart && ${2:-} == snell-vps-ci-a.service && -f ${FAIL_RESTART_FILE:-} ]]; then
        /usr/bin/systemctl stop "$2"
        rm -f "$FAIL_RESTART_FILE"
        return 1
    fi
    /usr/bin/systemctl "$@"
}

# Legacy sentinel must survive every manager operation.
[[ ! -e /etc/snell && ! -e /usr/local/bin/snell-server ]] || fail 'runner has existing legacy data'
mkdir /etc/snell
printf 'legacy config untouched\n' > /etc/snell/config.conf
printf 'legacy binary untouched\n' > /usr/local/bin/snell-server
legacy_before=$(sha256sum /etc/snell/config.conf /usr/local/bin/snell-server)

manager install --name ci-a --version 5 --port 39841 --bind 127.0.0.1
systemctl is-active --quiet snell-vps-ci-a.service
[[ $(stat -c %a /etc/snell-vps/instances/ci-a/snell.conf) == 640 ]] || fail 'config permissions'
[[ $(systemctl show snell-vps-ci-a.service -p User --value) == snell-vps ]] || fail 'service runs as root'
reject manager install --name ci-a --version 5 --port 39842
reject manager install --name conflict --version 5 --port 39841
manager stop --name ci-a
reject manager install --name reserved --version 5 --port 39841
manager update --name ci-a
reject systemctl is-active --quiet snell-vps-ci-a.service
manager start --name ci-a

manager install --name ci-b --version 4 --port 39842 --bind 127.0.0.1
systemctl is-active --quiet snell-vps-ci-b.service
other_hash=$(sha256sum /opt/snell-vps/instances/ci-b/snell-server /etc/snell-vps/instances/ci-b/snell.conf)
config_before=$(sha256sum /etc/snell-vps/instances/ci-a/snell.conf)
manager update --name ci-a --version 5.0.1
[[ $(sha256sum /etc/snell-vps/instances/ci-a/snell.conf) == "$config_before" ]] || fail 'update changed config'
reject manager update --name ci-a --version 6
manager configure --name ci-a --port 39843
grep -Fxq 'listen = 127.0.0.1:39843' /etc/snell-vps/instances/ci-a/snell.conf
manager rollback --name ci-a
grep -Fxq 'listen = 127.0.0.1:39841' /etc/snell-vps/instances/ci-a/snell.conf

# An occupied port makes restart fail. Manager must restore original config/service.
python3 -c 'import socket,time;s=socket.socket();s.bind(("127.0.0.1",39844));s.listen();time.sleep(60)' &
blocker=$!
trap 'kill "$blocker" 2>/dev/null || true' EXIT
sleep 1
# This is caught before mutation by port_free.
reject manager configure --name ci-a --port 39844
# Inject one failed restart after a config change; the recovery restart is real.
export FAIL_RESTART_FILE=/tmp/snell-ci-fail-restart
touch "$FAIL_RESTART_FILE"
export -f systemctl
reject manager configure --name ci-a --port 39846
systemctl is-active --quiet snell-vps-ci-a.service
grep -Fxq 'listen = 127.0.0.1:39841' /etc/snell-vps/instances/ci-a/snell.conf
unset -f systemctl

manager install --name ci-v6 --version 6 --port 39845 --bind 127.0.0.1
systemctl is-active --quiet snell-vps-ci-v6.service
manager info --name ci-v6 | grep -q 'version=6'
manager list
[[ $(sha256sum /opt/snell-vps/instances/ci-b/snell-server /etc/snell-vps/instances/ci-b/snell.conf) == "$other_hash" ]] || fail 'other instance changed'
[[ $(sha256sum /etc/snell/config.conf /usr/local/bin/snell-server) == "$legacy_before" ]] || fail 'legacy data changed'
manager uninstall --name ci-a --yes
[[ ! -e /etc/snell-vps/instances/ci-a && ! -e /opt/snell-vps/instances/ci-a ]] || fail 'uninstall incomplete'
systemctl is-active --quiet snell-vps-ci-b.service
[[ $(sha256sum /etc/snell/config.conf /usr/local/bin/snell-server) == "$legacy_before" ]] || fail 'legacy data changed after uninstall'
manager uninstall --name ci-b --yes
manager uninstall --name ci-v6 --yes
printf 'PASS: actual official v4/v5/v6 binaries, systemd lifecycle, multi-instance isolation and rollback\n'
