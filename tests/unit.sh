#!/usr/bin/env bash
# shellcheck disable=SC2034
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
source ./snell.sh
count=0
ok() { count=$((count+1)); printf 'ok %d - %s\n' "$count" "$1"; }
equal() { [[ $1 == "$2" ]] || { printf 'expected <%s>, got <%s>\n' "$2" "$1" >&2; exit 1; }; }
reject() { if "$@"; then printf 'unexpected success: %s\n' "$*" >&2; exit 1; fi; }

equal "$(arch_name x86_64)" amd64
equal "$(arch_name arm64)" aarch64
equal "$(arch_name i686)" i386
equal "$(arch_name armv7l)" armv7l
reject arch_name riscv64
ok 'CPU architecture mapping and unsupported CPU rejection'
for name in default edge-1 node_2; do valid_name "$name"; done
for name in ../snell /etc/snell '' '-bad' 'a b' 'a;id' 'a@b' A; do reject valid_name "$name"; done
ok 'instance names cannot escape managed directories or inject systemd arguments'
for port in 1 443 65535; do valid_port "$port"; done
for port in 0 65536 00080 08 -1 80x '80;id' 999999999999999; do reject valid_port "$port"; done
ok 'strict decimal port validation, including leading zeros and overflow'
valid_psk '0123456789abcdef0123456789abcdef'
reject valid_psk $'0123456789abcdef\nmode = unsafe-raw'
reject valid_psk 'bad,password,key'
reject valid_psk 'short'
ok 'PSK blocks newlines and profile delimiters'
valid_bind '[::]'
reject valid_bind $'0.0.0.0\npsk = bad'
ok 'listening address validation'
equal "$(resolve_version 4)" 4.1.1
equal "$(resolve_version '')" 5.0.1
equal "$(resolve_version 6)" 6.0.0
reject bash ./snell.sh install --version '6;id'
reject bash ./snell.sh install --name '../../snell'
reject bash ./snell.sh configure --port
ok 'CLI rejects invalid version, path traversal and missing option values'
equal "$(archive_sha 5.0.1 amd64)" 9bea1c2b9e35b73b31634856c04d18c393072b9e5dcde6a32781d8b8f908c539
reject archive_sha 6.0.0 armv7l
reject archive_sha 99.0.0 amd64
ok 'no installation of unpinned version or unavailable architecture'

fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
# Windows Git Bash cannot enforce Linux modes; real permission tests run in CI.
if [[ ${OSTYPE:-} == msys* || ${OSTYPE:-} == cygwin* ]]; then
    install() {
        local args=()
        local directory=false
        while (( $# )); do
            case "$1" in -m|-g) shift 2 ;; -d) directory=true; shift ;; *) args+=("$1"); shift ;; esac
        done
        if "$directory"; then mkdir -p -- "${args[@]}"; else cp -- "${args[@]}"; fi
    }
fi
write_config "$fixture/config" 12345 '0123456789abcdef0123456789abcdef' '[::]' 6.0.0
equal "$(config_value listen "$fixture/config")" '[::]:12345'
equal "$(config_value psk "$fixture/config")" '0123456789abcdef0123456789abcdef'
grep -Fxq 'mode = default' "$fixture/config"
reject grep -q '^ipv6' "$fixture/config"
write_config "$fixture/config" 23456 '0123456789abcdef0123456789abcdef' 0.0.0.0 5.0.1
grep -Fxq 'ipv6 = true' "$fixture/config"
ok 'protocol-specific config and IPv6 address rendering'

SNELL_SOURCE_ORDER=cn
mapfile -t urls < <(source_urls 5.0.1 amd64)
[[ ${urls[0]} == https://gitee.com/* && ${urls[1]} == https://dl.nssurge.com/* ]]
SNELL_SOURCE_ORDER=official
mapfile -t urls < <(source_urls 5.0.1 amd64)
[[ ${urls[0]} == https://dl.nssurge.com/* ]]
ok 'China mirror and official source fallback order'

printf 'valid fixture' > "$fixture/valid"
fixture_sha=$(sha256sum "$fixture/valid" | cut -d' ' -f1)
checksum_ok "$fixture/valid" "$fixture_sha"
printf '<html>blocked</html>' > "$fixture/invalid"
reject checksum_ok "$fixture/invalid" "$fixture_sha"
reject checksum_ok "$fixture/missing" "$fixture_sha"
ok 'HTML block page, changed payload and missing cache are rejected'

# Exercise the real fallback loop with transport and hash catalogue substituted.
# No network, services or host directories are touched.
CACHE=$fixture/cache
archive_sha() { printf '%s\n' "$fixture_sha"; }
source_urls() { printf 'https://failed/\nhttps://tampered/\nhttps://valid/\n'; }
http_get() {
    printf '%s\n' "$1" >> "$fixture/requests"
    case "$1" in
        https://failed/) return 1 ;;
        https://tampered/) cp "$fixture/invalid" "$2" ;;
        https://valid/) cp "$fixture/valid" "$2" ;;
    esac
}
download_archive 5.0.1 amd64 "$fixture/download"
checksum_ok "$fixture/download" "$fixture_sha"
equal "$(wc -l < "$fixture/requests" | tr -d ' ')" 3
download_archive 5.0.1 amd64 "$fixture/download-again"
equal "$(wc -l < "$fixture/requests" | tr -d ' ')" 3
ok 'network failure and tampering trigger fallback; verified cache avoids requests'

CONFIG=$fixture/instances
mkdir -p "$CONFIG/offline"
printf '[snell-server]\nlisten = [::]:34567\n' > "$CONFIG/offline/snell.conf"
ss() { printf 'tcp LISTEN 0 128 0.0.0.0:12345 0.0.0.0:*\n'; }
reject port_free 12345
reject port_free 34567
port_free 34567 "$CONFIG/offline/snell.conf"
port_free 45678
ok 'listening ports and stopped-instance reservations cannot be reused'

UNITS=$fixture/units; mkdir "$UNITS"
NAME=testing; paths
write_unit
grep -Fq "ExecStart=$DIR/snell-server -c $CONF" "$UNIT_FILE"
grep -Fxq 'User=snell-vps' "$UNIT_FILE"
grep -Fxq 'NoNewPrivileges=true' "$UNIT_FILE"
reject grep -q '/etc/snell/' "$UNIT_FILE"
ok 'instance-specific unprivileged systemd unit never uses legacy paths'
printf 'PASS: %d test groups\n' "$count"
