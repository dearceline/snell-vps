#!/usr/bin/env bash
# shellcheck disable=SC2034
set -Eeuo pipefail
cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.."
if [[ ${1:-} == --child ]]; then
    scenario=$2
    fixture=$3
    source ./snell.sh
    BASE=$fixture/bin CONFIG=$fixture/config STATE=$fixture/state BACKUPS=$fixture/backups
    UNITS=$fixture/units NAME=tx
    paths
    platform_check() { :; }
    managed_check() { CURRENT=5.0.1; }
    ensure_dependencies() { :; }
    prepare_binary() { TMP=$fixture/temp; mkdir -p "$TMP"; printf 'new binary\n' > "$TMP/snell-server"; }
    systemctl() { :; }
    health_check() {
        if [[ -f $fixture/fail-health ]]; then rm "$fixture/fail-health"; return 1; fi
    }
    # Discard Linux owner/mode operations only on Windows; tests use real file IO.
    if [[ ${OSTYPE:-} == msys* || ${OSTYPE:-} == cygwin* ]]; then
        install() {
            local args=() directory=false
            while (( $# )); do
                case "$1" in -m|-g) shift 2 ;; -d) directory=true; shift ;; *) args+=("$1"); shift ;; esac
            done
            if "$directory"; then mkdir -p -- "${args[@]}"; else cp -- "${args[@]}"; fi
        }
    fi
    mv() {
        if [[ ${*: -1} == "$META/version" && -f $fixture/fail-io ]]; then
            rm "$fixture/fail-io"
            return 1
        fi
        command mv "$@"
    }
    cp() {
        if [[ ${*: -1} == "$BACKUPS/tx/"*/snell.conf && -f $fixture/fail-backup ]]; then
            rm "$fixture/fail-backup"
            return 1
        fi
        command cp "$@"
    }
    case "$scenario" in
        health-failure) touch "$fixture/fail-health" ;;
        io-failure) touch "$fixture/fail-io" ;;
        backup-failure) touch "$fixture/fail-backup" ;;
    esac
    trap 'finish "$?"' EXIT
    update_instance
    exit
fi

fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT
for scenario in success health-failure io-failure backup-failure; do
    target=$fixture/$scenario
    mkdir -p "$target/bin/tx" "$target/config/tx" "$target/state/tx"
    printf 'original binary\n' > "$target/bin/tx/snell-server"
    printf 'original config\n' > "$target/config/tx/snell.conf"
    printf '5.0.1\n' > "$target/state/tx/version"
    result=0
    bash tests/transaction.sh --child "$scenario" "$target" || result=$?
    if [[ $scenario == success ]]; then
        [[ $result == 0 && $(cat "$target/bin/tx/snell-server") == 'new binary' ]]
    else
        [[ $result != 0 && $(cat "$target/bin/tx/snell-server") == 'original binary' ]]
    fi
    [[ $(cat "$target/config/tx/snell.conf") == 'original config' ]]
    [[ $(cat "$target/state/tx/version") == 5.0.1 ]]
    printf 'ok - update transaction: %s\n' "$scenario"
done
printf 'PASS: successful update, failed health check, interrupted metadata write and backup failure\n'
