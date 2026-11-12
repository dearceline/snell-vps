#!/usr/bin/env bash
# Snell VPS Manager - independent implementation, MIT licensed.
# A single file installer. Never operates on legacy /etc/snell or snell.service.
set -Eeuo pipefail
umask 077

SCRIPT_VERSION=1.0.0
SCRIPT_PATH=$(readlink -f -- "${BASH_SOURCE[0]}")
BASE=/opt/snell-vps/instances
CONFIG=/etc/snell-vps/instances
STATE=/var/lib/snell-vps/instances
BACKUPS=/var/backups/snell-vps
CACHE=/var/cache/snell-vps
UNITS=/etc/systemd/system
TMP=
NAME=default
VERSION=
PORT=
BIND=
YES=false
TX_BACKUP=
TX_ACTIVE=false

say() { printf '%s\n' "$*" >&2; }
die() { say "错误：$*"; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "缺少 $1；请运行 ./snell.sh deps"; }
valid_name() { [[ $1 =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; }
valid_port() { [[ $1 =~ ^[1-9][0-9]{0,4}$ ]] && (( 10#$1 <= 65535 )); }
valid_psk() { [[ $1 =~ ^[A-Za-z0-9_+-]{16,128}$ ]]; }
valid_bind() { [[ $1 == 0.0.0.0 || $1 == 127.0.0.1 || $1 == '[::]' || $1 == '[::1]' ]]; }
arch_name() {
    case "${1:-$(uname -m)}" in
        x86_64|amd64) printf 'amd64\n' ;; i386|i486|i586|i686) printf 'i386\n' ;;
        aarch64|arm64) printf 'aarch64\n' ;; armv7l|armv7) printf 'armv7l\n' ;;
        *) return 1 ;;
    esac
}
resolve_version() {
    case "$1" in
        4|4.1.1) printf '4.1.1\n' ;; 5|5.0.1|'') printf '5.0.1\n' ;;
        6|6.0.0) printf '6.0.0\n' ;;
        *) die "未收录版本 $1；只允许安装已有固定校验值的版本，使用 versions 查看。" ;;
    esac
}

# Maintainer-measured hashes of ZIPs fetched directly over verified official HTTPS.
# Not upstream signatures. Never fetch the expected hash from a mirror at runtime.
archive_sha() {
    case "$1/$2" in
        4.1.1/amd64) echo cc2271b79c7506888b34e651e8741b3aa7fc7d5f60aa65ef8bb096f3313a193b ;;
        4.1.1/i386) echo 09579fceebf69ff291453b8e252a9f74c7ca82246ec8572a6e2376008df25ae1 ;;
        4.1.1/aarch64) echo 38d4cdc03dcdb3608af8594df83e1795265167fafc5d802f815148908902d758 ;;
        4.1.1/armv7l) echo d00b98ed803be4039f0f0630b810932cd3d3d87ee3e6ed224106fdc63347d8e6 ;;
        5.0.1/amd64) echo 9bea1c2b9e35b73b31634856c04d18c393072b9e5dcde6a32781d8b8f908c539 ;;
        5.0.1/i386) echo 6a3e30928315427d6f747f26408d0f74eb88f460344d0e1fcb3f7c32c708a09d ;;
        5.0.1/aarch64) echo 2f178bf5ac468ce1a130454efa40a0603fbbe4e47ecc4880a989f4abc7f824cf ;;
        5.0.1/armv7l) echo 14489f3e857569c8835dd3598b7ea6bca5371d4290ac7cf0f6c8dfb3381c1fb2 ;;
        6.0.0/amd64) echo 8a9c4463ca87cfa5eaa37c6af0d37ab93ea275aa12391985bb2a375ca3abd7f2 ;;
        6.0.0/i386) echo 67060ef79ac4ef0bb64c520302396620b3a06f8f6d5ceb450be283e4fa749335 ;;
        6.0.0/aarch64) echo a0b2915cbc77dc3baf8fa069e741c20808d8a10c3a8a93e709a0a580645c3bd7 ;;
        *) return 1 ;;
    esac
}

cleanup() {
    case "$TMP" in /tmp/snell-vps.*) [[ ! -L $TMP ]] && rm -rf -- "$TMP" ;; esac
    return 0
}
finish() {
    local code=$1
    trap - EXIT
    set +e
    if [[ -n $TX_BACKUP && $code != 0 ]]; then
        say "操作中断，尝试从 $TX_BACKUP 恢复。"
        restore_snapshot "$TX_BACKUP"
        local restored=$?
        if (( restored == 0 )) && "$TX_ACTIVE"; then
            systemctl reset-failed "$UNIT"
            systemctl restart "$UNIT" && health_check
            restored=$?
        fi
        if (( restored != 0 )); then say "自动恢复未完成，请使用备份 $TX_BACKUP 手动恢复。"; fi
    fi
    cleanup
    exit "$code"
}
temp_dir() { [[ -n $TMP ]] || TMP=$(mktemp -d /tmp/snell-vps.XXXXXXXX); }
root_check() { (( EUID == 0 )) || die '请使用 root 或 sudo bash snell.sh。'; }
platform_check() {
    [[ $(uname -s) == Linux ]] || die '只支持 Linux VPS。'
    [[ ! -e /etc/alpine-release ]] || die '官方程序需要 glibc；本脚本支持 systemd，暂不支持 Alpine/OpenRC。'
    [[ -d /run/systemd/system ]] || die '当前环境没有运行 systemd。'
    need systemctl
    arch_name "$(uname -m)" >/dev/null || die "不支持的架构：$(uname -m)"
}
lock_manager() {
    need flock
    exec 9>/run/lock/snell-vps.lock
    flock -n 9 || die '另一个管理操作正在运行，请稍后重试。'
}
paths() {
    valid_name "$NAME" || die '实例名需以小写字母开头，最多 32 位，只含 a-z、0-9、_、-。'
    DIR=$BASE/$NAME
    CONF=$CONFIG/$NAME/snell.conf
    META=$STATE/$NAME
    UNIT=snell-vps-$NAME.service
    UNIT_FILE=$UNITS/$UNIT
}
managed_check() {
    [[ -f $META/managed && ! -L $META/managed ]] || die "实例 $NAME 不存在或不属于本脚本。"
    [[ $(cat "$META/managed") == snell-vps-v1 ]] || die '实例标记不匹配。'
    local path
    for path in "$BASE" "$CONFIG" "$STATE" "$DIR" "$CONFIG/$NAME" "$META" "$CONF" "$DIR/snell-server" "$UNIT_FILE"; do
        [[ -e $path && ! -L $path ]] || die "受管路径异常：$path"
    done
    grep -Fxq '# Managed by snell-vps-v1' "$UNIT_FILE" || die '服务文件不属于本脚本。'
    CURRENT=$(cat "$META/version")
    [[ $CURRENT =~ ^[456]\.[0-9]+\.[0-9]+$ ]] || die '版本记录无效。'
}
legacy_notice() {
    if [[ -e /etc/snell || -e /usr/local/bin/snell-server || -e /etc/systemd/system/snell.service || -e /etc/systemd/system/snell-server.service ]]; then
        say '检测到旧版 Snell。将保留其文件和服务；新实例需使用其他空闲端口。'
    fi
}
dependencies() {
    root_check
    [[ $(uname -s) == Linux && ! -e /etc/alpine-release ]] || die '依赖安装只支持使用 glibc 的 Linux。'
    if command -v apt-get >/dev/null; then
        apt-get update
        DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl unzip openssl iproute2 util-linux passwd
    elif command -v dnf >/dev/null; then
        dnf install -y ca-certificates curl unzip openssl iproute util-linux shadow-utils
    elif command -v yum >/dev/null; then
        yum install -y ca-certificates curl unzip openssl iproute util-linux shadow-utils
    else die '请手动安装 curl、unzip、openssl、iproute2、util-linux 和 useradd。'; fi
}
ensure_dependencies() {
    local cmd missing=false
    for cmd in curl unzip sha256sum openssl ss flock useradd groupadd getent timeout od; do
        command -v "$cmd" >/dev/null || missing=true
    done
    if "$missing"; then dependencies; fi
    for cmd in curl unzip sha256sum openssl ss flock useradd groupadd getent timeout od; do need "$cmd"; done
}
service_user() {
    if ! getent group snell-vps >/dev/null; then groupadd --system snell-vps; fi
    if ! getent passwd snell-vps >/dev/null; then
        local shell=/usr/sbin/nologin
        [[ -x $shell ]] || shell=/sbin/nologin
        useradd --system --gid snell-vps --no-create-home --home-dir /nonexistent --shell "$shell" snell-vps
    fi
    local uid gid shell expected_gid
    IFS=: read -r _ _ uid gid _ _ shell < <(getent passwd snell-vps)
    expected_gid=$(getent group snell-vps | cut -d: -f3)
    [[ $uid != 0 && $gid == "$expected_gid" && $shell == */nologin ]] || die '已有 snell-vps 系统账号不符合专用服务账号要求。'
}
http_get() {
    local url=$1 dest=$2
    [[ $url == https://* ]] || return 1
    if command -v curl >/dev/null; then
        curl --fail --location --silent --show-error --proto '=https' --proto-redir '=https' \
            --connect-timeout 3 --max-time 25 --speed-limit 1024 --speed-time 8 --retry 0 --output "$dest" "$url"
    else
        timeout 30 wget --quiet --https-only --timeout=5 --tries=1 -O "$dest" "$url"
    fi
}
source_urls() {
    local ver=$1 file="snell-server-v$1-linux-$2.zip" cn official github
    cn="https://gitee.com/ten/Others/raw/master/snell/v$ver/$file"
    official="https://dl.nssurge.com/snell/$file"
    github="https://raw.githubusercontent.com/xOS/Others/master/snell/v$ver/$file"
    case "${SNELL_SOURCE_ORDER:-cn}" in
        cn) printf '%s\n' "$cn" "$official" "$github" ;;
        official) printf '%s\n' "$official" "$cn" "$github" ;;
        *) die 'SNELL_SOURCE_ORDER 只支持 cn 或 official。' ;;
    esac
}
checksum_ok() { [[ -s $1 && $(sha256sum "$1" | cut -d' ' -f1) == "$2" ]]; }
download_archive() {
    local ver=$1 arch=$2 output=$3 sha url found=false
    sha=$(archive_sha "$ver" "$arch") || die "v$ver 没有 $arch 的已校验安装包。"
    if checksum_ok "$CACHE/$sha.zip" "$sha"; then
        cp -- "$CACHE/$sha.zip" "$output"
        say '使用已校验的本地缓存。'
        return
    fi
    while IFS= read -r url; do
        say "尝试下载：$url"
        if http_get "$url" "$output" && checksum_ok "$output" "$sha"; then found=true; break; fi
        say '此源下载失败或校验不符，切换下一个源。'
        rm -f -- "$output"
    done < <(source_urls "$ver" "$arch")
    "$found" || die '全部下载源失败；已有实例未作改动。可尝试 SNELL_SOURCE_ORDER=official。'
    install -d -m 700 "$CACHE"
    install -m 600 "$output" "$CACHE/$sha.zip"
}
prepare_binary() {
    local ver=$1 arch output
    arch=$(arch_name "$(uname -m)") || die '未知架构。'
    temp_dir
    download_archive "$ver" "$arch" "$TMP/snell.zip"
    [[ $(unzip -Z1 "$TMP/snell.zip" | grep -Fxc snell-server) == 1 ]] || die '压缩包缺少唯一的 snell-server。'
    # Stream only the pinned member; never extract archive paths onto the host.
    unzip -p "$TMP/snell.zip" snell-server > "$TMP/snell-server"
    [[ $(od -An -tx1 -N4 "$TMP/snell-server" | tr -d ' \n') == 7f454c46 ]] || die '程序不是 ELF 文件。'
    chmod 755 "$TMP/snell-server"
    output=$(timeout 5 "$TMP/snell-server" -v 2>&1) || die '官方程序无法运行，请检查 glibc/CPU 兼容性。'
    [[ $output == *"$ver"* ]] || die "程序报告版本与 $ver 不一致。"
}
port_free() {
    local output path used
    need ss
    output=$(ss -H -lntu) || die '无法检查监听端口。'
    if awk -v port="$1" '$5 ~ (":" port "$") {found=1} END {exit !found}' <<< "$output"; then return 1; fi
    for path in "$CONFIG"/*/snell.conf; do
        [[ -f $path && $path != "${2:-}" ]] || continue
        used=$(config_value listen "$path")
        [[ ${used##*:} != "$1" ]] || return 1
    done
}
random_port() {
    local attempt port
    for ((attempt=0; attempt<80; attempt++)); do
        port=$(( 10000 + $(od -An -N2 -tu2 /dev/urandom) % 50000 ))
        if port_free "$port"; then printf '%s\n' "$port"; return; fi
    done
    die '未能找到空闲端口，请用 --port 指定。'
}
config_value() {
    awk -F= -v key="$1" '$1 ~ ("^[[:space:]]*" key "[[:space:]]*$") {sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*$/, ""); print; exit}' "$2"
}
write_config() {
    local path=$1 port=$2 psk=$3 bind=$4 ver=$5
    valid_port "$port" && valid_psk "$psk" && valid_bind "$bind" || die '端口、PSK 或监听地址无效。'
    {
        printf '[snell-server]\nlisten = %s:%s\npsk = %s\n' "$bind" "$port" "$psk"
        if [[ ${ver%%.*} == 6 ]]; then printf 'mode = default\n'; else printf 'ipv6 = true\n'; fi
    } > "$path"
}
write_unit() {
    cat > "$UNIT_FILE" <<EOF
# Managed by snell-vps-v1
[Unit]
Description=Snell VPS instance $NAME
Wants=network-online.target
After=network-online.target
StartLimitIntervalSec=60
StartLimitBurst=3

[Service]
Type=simple
User=snell-vps
Group=snell-vps
ExecStart=$DIR/snell-server -c $CONF
Restart=on-failure
RestartSec=3
LimitNOFILE=65536
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
    chmod 644 "$UNIT_FILE"
}
health_check() {
    local attempt
    for ((attempt=0; attempt<3; attempt++)); do
        sleep 1
        systemctl is-active --quiet "$UNIT" || return 1
    done
}
install_instance() {
    platform_check
    legacy_notice
    [[ ! -e $DIR && ! -L $DIR && ! -e $CONFIG/$NAME && ! -L $CONFIG/$NAME && ! -e $META && ! -L $META && ! -e $UNIT_FILE && ! -L $UNIT_FILE ]] || die '同名路径已存在；安装不会覆盖。请选择其他 --name。'
    [[ -z $(systemctl show -p FragmentPath --value "$UNIT" 2>/dev/null) ]] || die '同名服务已存在，拒绝覆盖。'
    VERSION=$(resolve_version "$VERSION")
    BIND=${BIND:-0.0.0.0}
    ensure_dependencies
    [[ -n $PORT ]] || PORT=$(random_port)
    valid_port "$PORT" && port_free "$PORT" || die "端口 $PORT 已被监听或被其他受管实例保留。"
    local psk=${SNELL_PSK:-}
    [[ -n $psk ]] || psk=$(openssl rand -hex 16)
    valid_psk "$psk" || die 'PSK 必须为 16–128 位字母、数字、_、+、-。'
    prepare_binary "$VERSION"
    service_user
    install -d -m 755 /opt/snell-vps "$BASE" /etc/snell-vps "$CONFIG"
    install -d -m 700 /var/lib/snell-vps "$STATE" "$META"
    install -d -m 755 "$DIR"
    install -d -m 750 -g snell-vps "$CONFIG/$NAME"
    install -m 755 "$TMP/snell-server" "$DIR/snell-server"
    write_config "$TMP/snell.conf" "$PORT" "$psk" "$BIND" "$VERSION"
    install -m 640 -g snell-vps "$TMP/snell.conf" "$CONF"
    printf '%s\n' "$VERSION" > "$META/version"
    printf 'snell-vps-v1\n' > "$META/managed"
    write_unit
    systemctl daemon-reload
    if systemctl enable --now "$UNIT" && health_check; then
        say "安装成功：$NAME，Snell $VERSION，端口 $PORT。"
        say "请在 VPS 安全组及防火墙中放行 TCP/UDP $PORT；脚本不会更改防火墙规则。"
        show_info
    else
        systemctl disable --now "$UNIT" >/dev/null 2>&1 || true
        die "新实例启动失败，文件保留供排查。运行 logs --name $NAME；已有其他实例未变更。"
    fi
}
snapshot() {
    local target
    install -d -m 700 "$BACKUPS" "$BACKUPS/$NAME" || die '无法创建备份目录，原实例未改动。'
    target=$(mktemp -d "$BACKUPS/$NAME/$(date -u +%Y%m%dT%H%M%SZ).XXXXXXXX") || die '无法创建备份，原实例未改动。'
    cp -p -- "$DIR/snell-server" "$target/snell-server" || die '程序备份失败，原实例未改动。'
    cp -p -- "$CONF" "$target/snell.conf" || die '配置备份失败，原实例未改动。'
    cp -p -- "$META/version" "$target/version" || die '版本备份失败，原实例未改动。'
    printf '%s\n' "$target"
}
restore_snapshot() {
    local target=$1
    [[ $target == "$BACKUPS/$NAME/"* && $target != *'..'* && -d $target && ! -L $target ]] || die '备份路径不合法。'
    local file
    for file in snell-server snell.conf version; do [[ -f $target/$file && ! -L $target/$file ]] || die '备份不完整。'; done
    # Rename within the destination filesystem to replace executables atomically.
    install -m 755 "$target/snell-server" "$DIR/.snell-server.new" || return 1
    mv -f -- "$DIR/.snell-server.new" "$DIR/snell-server" || return 1
    install -m 640 -g snell-vps "$target/snell.conf" "$CONFIG/$NAME/.snell.conf.new" || return 1
    mv -f -- "$CONFIG/$NAME/.snell.conf.new" "$CONF" || return 1
    install -m 600 "$target/version" "$META/.version.new" || return 1
    mv -f -- "$META/.version.new" "$META/version" || return 1
}
activate_or_restore() {
    local backup=$1 active=$2
    if "$active"; then
        if ! { systemctl reset-failed "$UNIT" && systemctl restart "$UNIT" && health_check; }; then
            say '新配置或程序启动失败，恢复原备份。'
            restore_snapshot "$backup"
            systemctl reset-failed "$UNIT"
            systemctl restart "$UNIT"
            health_check || die "原实例也未能恢复，请检查 journalctl -u $UNIT。备份：$backup"
            TX_BACKUP=
            die '已自动恢复原程序与配置；本次修改未生效。'
        fi
    fi
    printf '%s\n' "$backup" > "$META/last-backup"
    TX_BACKUP=
}
update_instance() {
    platform_check
    managed_check
    VERSION=$(resolve_version "${VERSION:-${CURRENT%%.*}}")
    [[ ${CURRENT%%.*} == "${VERSION%%.*}" ]] || die '跨协议版本请新建实例验证，脚本不自动改变现有客户端协议。'
    ensure_dependencies
    prepare_binary "$VERSION"
    local backup active=false
    systemctl is-active --quiet "$UNIT" && active=true
    backup=$(snapshot)
    TX_BACKUP=$backup TX_ACTIVE=$active
    install -m 755 "$TMP/snell-server" "$DIR/.snell-server.new"
    mv -f -- "$DIR/.snell-server.new" "$DIR/snell-server"
    printf '%s\n' "$VERSION" > "$META/.version.new"
    mv -f -- "$META/.version.new" "$META/version"
    activate_or_restore "$backup" "$active"
    say "已更新 $NAME 到 $VERSION；原本停止的服务保持停止。备份：$backup"
}
configure_instance() {
    platform_check
    managed_check
    need ss
    local listen old_port psk backup active=false
    listen=$(config_value listen "$CONF")
    BIND=${BIND:-${listen%:*}}
    old_port=${listen##*:}
    [[ -n $PORT ]] || PORT=$old_port
    valid_port "$PORT" || die '无效端口。'
    [[ $PORT == "$old_port" ]] || port_free "$PORT" "$CONF" || die '目标端口已被监听或保留。'
    psk=${SNELL_PSK:-$(config_value psk "$CONF")}
    valid_psk "$psk" || die '无效 PSK。'
    # Preserve all user-added options; only replace listen/PSK on explicit configure.
    temp_dir
    awk -v listen="$BIND:$PORT" -v psk="$psk" '
        /^[[:space:]]*listen[[:space:]]*=/ {print "listen = " listen; next}
        /^[[:space:]]*psk[[:space:]]*=/ {print "psk = " psk; next} {print}' "$CONF" > "$TMP/snell.conf"
    backup=$(snapshot)
    systemctl is-active --quiet "$UNIT" && active=true
    TX_BACKUP=$backup TX_ACTIVE=$active
    install -m 640 -g snell-vps "$TMP/snell.conf" "$CONFIG/$NAME/.snell.conf.new"
    mv -f -- "$CONFIG/$NAME/.snell.conf.new" "$CONF"
    activate_or_restore "$backup" "$active"
    say "配置已保存。请放行 TCP/UDP $PORT。"
}
rollback_instance() {
    platform_check
    managed_check
    [[ -f $META/last-backup ]] || die '没有可回滚的备份。'
    local previous backup active=false
    previous=$(cat "$META/last-backup")
    backup=$(snapshot)
    systemctl is-active --quiet "$UNIT" && active=true
    TX_BACKUP=$backup TX_ACTIVE=$active
    restore_snapshot "$previous"
    activate_or_restore "$backup" "$active"
    say '已恢复上一份程序、配置和版本记录。'
}
uninstall_instance() {
    platform_check
    managed_check
    if ! "$YES"; then
        [[ -t 0 ]] || die '非交互卸载需显式传入 --yes。'
        local answer
        read -r -p "卸载实例 $NAME？其他实例会保留 [y/N]：" answer
        [[ $answer == y || $answer == Y ]] || return 0
    fi
    local backup
    backup=$(snapshot)
    systemctl disable --now "$UNIT"
    rm -f -- "$UNIT_FILE"
    systemctl daemon-reload
    systemctl reset-failed "$UNIT" 2>/dev/null || true
    # Fixed roots + validated instance name + managed marker; never follow symlinks.
    rm -rf -- "${DIR:?}" "${CONFIG:?}/${NAME:?}" "${META:?}"
    say "已卸载 $NAME；备份保留在 $backup（含密钥，请妥善保管）。"
}
list_instances() {
    local file name ver status
    printf '%-32s %-10s %s\n' 实例 版本 状态
    for file in "$STATE"/*/managed; do
        [[ -f $file && ! -L $file ]] || continue
        name=${file%/managed}; name=${name##*/}
        valid_name "$name" || continue
        ver=$(cat "$STATE/$name/version")
        status=$(systemctl is-active "snell-vps-$name.service" 2>/dev/null) || true
        printf '%-32s %-10s %s\n' "$name" "$ver" "$status"
    done
    legacy_notice
}
show_info() {
    managed_check
    local listen psk
    listen=$(config_value listen "$CONF")
    psk=$(config_value psk "$CONF")
    printf '实例：%s\n版本：%s\n监听：%s\n配置：%s\n服务：%s\n' "$NAME" "$CURRENT" "$listen" "$CONF" "$UNIT"
    printf 'Surge 配置（把 YOUR_VPS_IP 换成 VPS 公网 IP 或域名）：\n'
    printf '%s = snell, YOUR_VPS_IP, %s, psk=%s, version=%s\n' "$NAME" "${listen##*:}" "$psk" "${CURRENT%%.*}"
}
versions() {
    printf '离线校验目录（非联网最新版本查询）：\n4.1.1  amd64/i386/aarch64/armv7l\n5.0.1  amd64/i386/aarch64/armv7l（默认）\n6.0.0  amd64/i386/aarch64（官方文档标记测试阶段；客户端需兼容）\n'
}
doctor() {
    printf '管理脚本：%s\n系统：%s\n架构：%s\n' "$SCRIPT_VERSION" "$(uname -s)" "$(uname -m)"
    local cmd
    for cmd in systemctl curl wget unzip sha256sum openssl ss flock useradd timeout; do
        if command -v "$cmd" >/dev/null; then printf '[OK] %s\n' "$cmd"; else printf '[缺少] %s\n' "$cmd"; fi
    done
    legacy_notice
    say '此检查不访问网络、不修改实例。菜单启动也不查询公网 IP。'
}
usage() {
    cat <<'EOF'
Snell VPS 管理脚本
  ./snell.sh                         中文菜单（启动时不联网）
  ./snell.sh install --name default --port 12345 [--version 4|5|6]
  ./snell.sh update --name default [--version 5.0.1]
  ./snell.sh configure --name default --port 23456 [--bind 0.0.0.0|127.0.0.1|[::]|[::1]]
  ./snell.sh start|stop|restart|status|logs|info --name default
  ./snell.sh rollback --name default
  ./snell.sh uninstall --name default [--yes]
  ./snell.sh list|versions|doctor|check-online|deps|help
环境变量：SNELL_SOURCE_ORDER=cn（默认）或 official；SNELL_PSK=自定义密钥。
不指定 PSK 自动生成 32 位随机密钥。info 会显示密钥，勿公开输出。
仅管理 snell-vps-* 服务，保留旧版实例。更新默认保持协议大版本。
EOF
}
check_online() {
    need curl
    temp_dir
    http_get 'https://kb.nssurge.com/surge-knowledge-base/release-notes/snell.md' "$TMP/releases.md" || die '无法访问官网；离线目录仍可使用。'
    say '官网列出的版本（不自动信任新下载包、不自动安装）：'
    grep -Eo 'snell-server-v[0-9][A-Za-z0-9.]*-linux-' "$TMP/releases.md" | sed -e 's/snell-server-v//' -e 's/-linux-//' | sort -Vu
}
menu() {
    [[ -t 0 ]] || { usage; return; }
    local choice name ver port psk
    while true; do
        printf '\nSnell VPS %s · 菜单启动不联网\n' "$SCRIPT_VERSION"
        printf '1 安装/新增实例   2 更新实例       3 卸载实例\n4 启动            5 停止           6 重启\n7 修改端口/密钥   8 查看连接配置   9 状态/日志\n10 列出实例       11 回滚          12 已校验版本\n13 手动官网检查   14 环境检查      0 退出\n'
        read -r -p '请选择：' choice || return
        case "$choice" in
            0) return ;; 10) bash "$SCRIPT_PATH" list; continue ;; 12) versions; continue ;;
            13) bash "$SCRIPT_PATH" check-online || true; continue ;; 14) doctor; continue ;;
        esac
        [[ $choice =~ ^([1-9]|11)$ ]] || { say '无效选项。'; continue; }
        read -r -p '实例名 [default]：' name || return
        name=${name:-default}
        case "$choice" in
            1)
                read -r -p '协议版本 4/5/6 [5]：' ver || return
                read -r -p '端口 [回车自动选择]：' port || return
                local args=(install --name "$name" --version "${ver:-5}")
                [[ -z $port ]] || args+=(--port "$port")
                bash "$SCRIPT_PATH" "${args[@]}" || true ;;
            2) bash "$SCRIPT_PATH" update --name "$name" || true ;;
            3) bash "$SCRIPT_PATH" uninstall --name "$name" || true ;;
            4) bash "$SCRIPT_PATH" start --name "$name" || true ;;
            5) bash "$SCRIPT_PATH" stop --name "$name" || true ;;
            6) bash "$SCRIPT_PATH" restart --name "$name" || true ;;
            7)
                read -r -p '新端口 [保持]：' port || return
                read -r -s -p '新密钥 [保持，输入不可见]：' psk || return; printf '\n'
                local opts=(configure --name "$name")
                [[ -z $port ]] || opts+=(--port "$port")
                SNELL_PSK=$psk bash "$SCRIPT_PATH" "${opts[@]}" || true ;;
            8) bash "$SCRIPT_PATH" info --name "$name" || true ;;
            9) bash "$SCRIPT_PATH" status --name "$name" || true; bash "$SCRIPT_PATH" logs --name "$name" || true ;;
            11) bash "$SCRIPT_PATH" rollback --name "$name" || true ;;
        esac
    done
}
main() {
    (( BASH_VERSINFO[0] >= 4 )) || die '需要 Bash 4 或更新版本。'
    local command=${1:-menu} action
    (( $# == 0 )) || shift
    while (( $# )); do
        case "$1" in
            --name|--version|--port|--bind)
                (( $# >= 2 )) || die "缺少 $1 的值。"
                case "$1" in --name) NAME=$2 ;; --version) VERSION=$2 ;; --port) PORT=$2 ;; --bind) BIND=$2 ;; esac
                shift 2 ;;
            --yes) YES=true; shift ;;
            *) die "未知参数 $1；使用 help 查看用法。" ;;
        esac
    done
    [[ -z $VERSION ]] || VERSION=$(resolve_version "$VERSION")
    [[ -z $PORT ]] || valid_port "$PORT" || die '端口必须是 1–65535 的十进制整数。'
    valid_bind "${BIND:-0.0.0.0}" || die '监听地址只允许 0.0.0.0、127.0.0.1、[::]、[::1]。'
    trap 'finish "$?"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    case "$command" in
        help|-h|--help) usage; return ;; --version) echo "$SCRIPT_VERSION"; return ;;
        versions) versions; return ;; doctor) doctor; return ;;
    esac
    root_check
    paths
    case "$command" in
        install|update|configure|rollback|uninstall|start|stop|restart) lock_manager ;;
    esac
    case "$command" in
        menu) menu ;; install) install_instance ;; update) update_instance ;;
        configure) configure_instance ;; rollback) rollback_instance ;; uninstall) uninstall_instance ;;
        list) list_instances ;; info) show_info ;; versions) versions ;; deps) dependencies ;;
        check-online) check_online ;;
        status|logs|start|stop|restart)
            platform_check; managed_check
            action=$command
            case "$action" in
                logs) journalctl -u "$UNIT" -n 60 --no-pager ;;
                status) systemctl status "$UNIT" --no-pager --full ;;
                *) systemctl "$action" "$UNIT"; [[ $action == stop ]] || health_check ;;
            esac ;;
        *) die "未知命令 $command；使用 help 查看用法。" ;;
    esac
}
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
