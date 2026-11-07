#!/usr/bin/env bash
# VLESS + xHTTP + TLS 管理器。主要目标：Debian 12/13 + systemd。
# 安装：sudo install -m 0755 xy.sh /usr/local/bin/xy && sudo /usr/local/bin/xy
# 配置、证书操作有回滚；软件包/核心升级不属于可回滚事务。
set -uo pipefail
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
umask 077

CONFIG=/usr/local/etc/xray/config.json
XRAY_DIR=/usr/local/etc/xray
CERT_DIR=/etc/xray-cert
CERT=/etc/xray-cert/server.crt
KEY=/etc/xray-cert/server.key
DOMAIN_FILE=/etc/xray-cert/domain.txt
STAGE=/etc/xray-cert/staging
ACME_HOME=/etc/xray-cert/acme
SCRIPT=/usr/local/bin/xy
LOCK=/run/xy/manager.lock
INSTALL_URL=https://raw.githubusercontent.com/XTLS/Xray-install/main/install-release.sh

# 非终端、NO_COLOR 或 TERM=dumb 时禁用颜色。
color_enabled() { [[ -t 1 && ! ${NO_COLOR+x} && ${TERM:-dumb} != dumb ]]; }
paint() {
    if color_enabled; then printf '\033[%sm%s\033[0m' "$1" "$2"
    else printf '%s' "$2"; fi
}
say() { printf '  %s\n' "$*"; }
success() { printf '\n  '; paint 32 "✓ $*"; printf '\n\n'; }
warn() { printf '\n  '; paint 33 "$*"; printf '\n\n'; }
error() { printf '\n  '; paint 31 "$*"; printf '\n\n'; }
die() { error "错误：$*" >&2; exit 1; }
prompt() { printf '\n  '; paint 33 "$1"; printf '\n  › '; }
hint() { printf '\n  '; paint 90 "$*"; printf '\n'; }
ask() { prompt "$2"; read -r "$1" || die '输入已结束。'; }
pause() {
    printf '\n  '; paint 90 '按 Enter 返回菜单…'
    read -r _ || exit 0
    printf '\n'
}
section() {
    printf '\n  '; paint 36 "$*"
    printf '\n  '; paint 36 '────────────────────────────────'; printf '\n'
}
stage() {
    printf '\n  '; paint 36 '────────────────────────────────'
    printf '\n  '; paint 36 "[$1/$2] $3"; printf '\n\n'
}
field() { printf '  %-12s ' "$1"; paint "$3" "$2"; printf '\n'; }

# 只包装外部命令，避免改变 shell 函数中的失败语义。
# 终端收起成功命令的重复输出，失败完整显示；日志/XY_VERBOSE=1 保留输出。
run_logged() (
    if [[ ! -t 1 || ${XY_VERBOSE:-0} == 1 ]]; then "$@"; exit $?; fi
    local output rc=0
    output=$(mktemp)
    trap 'rm -f -- "$output"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    "$@" >"$output" 2>&1 || rc=$?
    if (( rc != 0 )); then
        error "执行失败（退出码 $rc），详细输出：" >&2
        cat "$output" >&2
    fi
    exit "$rc"
)
show_menu() {
    local state domain='尚未配置' tone=33
    state=$(systemctl is-active xray 2>/dev/null) || :
    case $state in
        active) state='运行中'; tone=32;;
        inactive) state='未运行'; tone=31;;
        failed) state='启动失败'; tone=31;;
        *) state='未安装或状态未知';;
    esac
    if [[ -s $DOMAIN_FILE ]]; then
        domain=$(cat "$DOMAIN_FILE")
        domain_valid "$domain" || domain='域名记录异常'
    fi
    section 'XHTTP 节点管理'
    printf '  '; paint 90 'VLESS · xHTTP · TLS'; printf '\n\n'
    field '服务状态' "$state" "$tone"
    field '当前域名' "$domain" 35
    printf '\n'
    say '1. 安装/更新环境（保留现有配置）'
    say '2. 添加用户'
    say '3. 删除用户'
    say '4. 查看所有用户及链接'
    printf '\n'
    say '5. 彻底卸载'
    say '6. 重启 Xray 服务'
    say '7. 更新域名及证书'
    printf '\n'
    say '8. 退出'
}

new_uuid() { cat /proc/sys/kernel/random/uuid; }
uri() { jq -rn --arg value "$1" '$value | @uri'; }
download() { curl --fail --show-error --location --proto '=https' --tlsv1.2 --retry 3 --connect-timeout 20 --max-time 300 "$1" -o "$2"; }
lock() { install -d -o root -g root -m 0700 /run/xy; exec 9>"$LOCK"; flock -w 120 9 || die '另一项操作仍在进行，请稍后再试。'; }

platform() {
    [[ $EUID -eq 0 ]] || die '请使用 root 或 sudo 运行。'
    [[ $(uname -s) == Linux && -d /run/systemd/system ]] || die '需要以 systemd 启动的 Linux 服务器。'
}

dependencies() {
    if command -v apt-get >/dev/null; then
        run_logged apt-get update || return
        run_logged env DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl jq openssl socat cron util-linux iproute2 unzip tar || return
        systemctl enable --now cron || return
    elif command -v dnf >/dev/null || command -v yum >/dev/null; then
        local pm
        pm=$(command -v dnf || command -v yum)
        run_logged "$pm" install -y ca-certificates curl jq openssl socat cronie util-linux iproute unzip tar || return
        systemctl enable --now crond || return
    else
        say '不支持此包管理器。'; return 1
    fi
}

require_tools() {
    local c
    for c in jq openssl flock runuser ss curl xray; do
        command -v "$c" >/dev/null || die "缺少 $c，请先选择菜单 1 安装/更新。"
    done
}

identity() {
    SERVICE_USER=$(systemctl show xray.service -p User --value)
    SERVICE_GROUP=$(systemctl show xray.service -p Group --value)
    SERVICE_USER=${SERVICE_USER:-root}
    [[ $(systemctl show xray.service -p DynamicUser --value) != yes ]] || die '暂不支持自定义 DynamicUser 服务。'
    id "$SERVICE_USER" >/dev/null || die 'Xray 服务用户不存在。'
    SERVICE_GROUP=${SERVICE_GROUP:-$(id -gn "$SERVICE_USER")}
}

directories() {
    identity
    # 目录由 root 持有，服务用户只有读取权限，不能替换证书。
    install -d -o root -g "$SERVICE_GROUP" -m 0750 "$CERT_DIR"
    install -d -o root -g root -m 0700 "$STAGE"
    install -d -m 0755 "$XRAY_DIR"
}

managed_config() {
    [[ -s $CONFIG ]] || die '没有配置，请先安装。'
    jq -e --arg cert "$CERT" --arg key "$KEY" '
        (.inbounds | length) == 1 and
        .inbounds[0].protocol == "vless" and
        .inbounds[0].streamSettings.network == "xhttp" and
        .inbounds[0].streamSettings.security == "tls" and
        .inbounds[0].streamSettings.tlsSettings.certificates[0].certificateFile == $cert and
        .inbounds[0].streamSettings.tlsSettings.certificates[0].keyFile == $key and
        (.inbounds[0].settings.clients | type == "array" and length > 0)
    ' "$CONFIG" >/dev/null || die '配置不是此脚本支持的单入口 VLESS+xHTTP+TLS 格式，已停止，未覆盖配置。'
}

domain_valid() {
    local d=$1 label
    [[ ${#d} -le 253 && $d == *.* && $d != *[!a-zA-Z0-9.-]* ]] || return 1
    [[ $d != .* && $d != *. && $d != *..* ]] || return 1
    local -a labels
    IFS=. read -r -a labels <<< "$d"
    for label in "${labels[@]}"; do
        [[ ${#label} -le 63 && $label != -* && $label != *- ]] || return 1
    done
}

test_config() { run_logged xray run -test -config "$1"; }
healthy_restart() {
    # 失败的候选配置可能触发 systemd 启动限流；恢复旧配置后须清除计数。
    systemctl reset-failed xray || return 1
    systemctl restart xray || return 1
    sleep 2
    systemctl is-active --quiet xray
}

# 在目标文件所在文件系统创建临时文件，然后原子替换单个文件。
atomic_copy() {
    local tmp
    tmp=$(mktemp "${2}.xy.XXXXXX") || return 1
    if cp --preserve=mode,ownership -- "$1" "$tmp" && mv -f -- "$tmp" "$2"; then
        return 0
    fi
    rm -f -- "$tmp"
    return 1
}

# 调用方持有锁。多文件事务在普通错误、INT/TERM 时恢复；断电/SIGKILL 不在此保证内。
apply_config() (
    set -e
    local candidate=$1 with_cert=${2:-no} new_domain=${3:-} host_check backup armed=0 was_active=0 failed=0 f
    identity
    backup=$(mktemp -d "$XRAY_DIR/.xy-backup.XXXXXX")
    systemctl is-active --quiet xray && was_active=1
    finish() {
        local rc=$?
        trap - EXIT INT TERM
        if (( armed )); then
            for f in config.json server.crt server.key domain.txt; do
                local target
                case $f in config.json) target=$CONFIG;; server.crt) target=$CERT;; server.key) target=$KEY;; domain.txt) target=$DOMAIN_FILE;; esac
                if [[ -f $backup/$f ]]; then
                    atomic_copy "$backup/$f" "$target" || failed=1
                elif [[ -f $backup/$f.absent ]]; then
                    rm -f -- "$target" || failed=1
                fi
            done
            if (( was_active )); then
                healthy_restart || failed=1
            else
                systemctl stop xray || failed=1
            fi
            if (( failed )); then
                say "自动恢复未完全成功，备份保留于：$backup。请检查 journalctl -u xray -n 50。" >&2
                exit 1
            fi
            say '操作失败，已恢复操作前的配置/证书及服务状态。' >&2
        fi
        rm -rf -- "$backup"
        exit "$rc"
    }
    trap finish EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM

    jq -e . "$candidate" >/dev/null
    cp "$candidate" "$backup/new.json"
    if [[ $with_cert == yes ]]; then
        cp "$STAGE/server.crt" "$backup/staged.crt"
        cp "$STAGE/server.key" "$backup/staged.key"
        run_logged openssl x509 -in "$backup/staged.crt" -noout -checkend 86400
        host_check=$(openssl x509 -in "$backup/staged.crt" -noout -checkhost "${new_domain:-$(cat "$DOMAIN_FILE")}")
        [[ $host_check == *" does match certificate" ]] || die '证书与目标域名不匹配。'
        openssl x509 -in "$backup/staged.crt" -pubkey -noout > "$backup/cert.pub"
        openssl pkey -in "$backup/staged.key" -pubout > "$backup/key.pub"
        cmp -s "$backup/cert.pub" "$backup/key.pub" || die '证书和私钥不匹配。'
        jq --arg cert "$backup/staged.crt" --arg key "$backup/staged.key" '
            .inbounds[0].streamSettings.tlsSettings.certificates[0].certificateFile=$cert |
            .inbounds[0].streamSettings.tlsSettings.certificates[0].keyFile=$key
        ' "$candidate" > "$backup/test.json"
        test_config "$backup/test.json"
    else
        test_config "$backup/new.json"
    fi

    for f in "$CONFIG" "$CERT" "$KEY" "$DOMAIN_FILE"; do
        if [[ -e $f ]]; then cp -p -- "$f" "$backup/$(basename "$f")";
        else touch "$backup/$(basename "$f").absent"; fi
    done
    armed=1
    if [[ $with_cert == yes ]]; then
        install -o root -g "$SERVICE_GROUP" -m 0640 "$backup/staged.crt" "$backup/new.crt"
        install -o root -g "$SERVICE_GROUP" -m 0640 "$backup/staged.key" "$backup/new.key"
        atomic_copy "$backup/new.crt" "$CERT"
        atomic_copy "$backup/new.key" "$KEY"
    fi
    chown root:"$SERVICE_GROUP" "$backup/new.json"
    chmod 0640 "$backup/new.json"
    atomic_copy "$backup/new.json" "$CONFIG"
    # 以实际服务身份检查文件可读性与配置，避免 root 检查通过而服务打不开私钥。
    run_logged runuser -u "$SERVICE_USER" -g "$SERVICE_GROUP" -- "$(command -v xray)" run -test -config "$CONFIG"
    if [[ -n $new_domain ]]; then
        printf '%s\n' "$new_domain" > "$backup/new.domain"
        chmod 0600 "$backup/new.domain"
        atomic_copy "$backup/new.domain" "$DOMAIN_FILE"
    fi
    healthy_restart
    armed=0
)

select_acme() {
    ACME=$ACME_HOME/acme.sh
    ACME_BASE=$ACME_HOME
    ECC=(--ecc)
    # 兼容原脚本的 root acme.sh，只处理当前域名，不删除共享 ACME 环境。
    if [[ ! -x $ACME && -f /root/.acme.sh/acme.sh ]]; then
        if [[ -f /root/.acme.sh/${DOMAIN}_ecc/${DOMAIN}.conf ]]; then
            ACME=/root/.acme.sh/acme.sh; ACME_BASE=/root/.acme.sh
        elif [[ -f /root/.acme.sh/${DOMAIN}/${DOMAIN}.conf ]]; then
            ACME=/root/.acme.sh/acme.sh; ACME_BASE=/root/.acme.sh; ECC=()
        fi
    fi
}

prepare_certificate() {
    select_acme
    local rc acme_cert_dir
    if [[ ! -f $ACME ]]; then
        install -d -m 0700 "$ACME_HOME"
        download https://raw.githubusercontent.com/acmesh-official/acme.sh/master/acme.sh "$work/acme.sh"
        sh -n "$work/acme.sh"
        cd "$work"
        run_logged sh ./acme.sh --install --home "$ACME_HOME" --no-cron --no-profile --accountemail "admin@$DOMAIN"
    fi
    if [[ $ACME_BASE == "$ACME_HOME" ]]; then
        # 单独的 cron 文件，避免 acme.sh 管理 root crontab 时影响其他安装。
        printf '%s\n' 'SHELL=/bin/sh' 'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin' \
            '17 3 * * * root /etc/xray-cert/acme/acme.sh --cron --home /etc/xray-cert/acme >>/var/log/xy-acme.log 2>&1' > "$work/xy-acme"
        install -o root -g root -m 0644 "$work/xy-acme" /etc/cron.d/xy-acme
    fi
    run_logged "$ACME" --home "$ACME_BASE" --upgrade --auto-upgrade
    # 不强制刷新未到期证书，避免重复运行触发 CA 限额。
    acme_cert_dir=$ACME_BASE/$DOMAIN
    [[ ${#ECC[@]} -eq 0 ]] || acme_cert_dir=${acme_cert_dir}_ecc
    # acme.sh --remove 将续期配置改名；切回曾使用的域名时恢复完整配置。
    if [[ ! -f $acme_cert_dir/$DOMAIN.conf && -f $acme_cert_dir/$DOMAIN.conf.removed ]]; then
        cp -p -- "$acme_cert_dir/$DOMAIN.conf.removed" "$acme_cert_dir/$DOMAIN.conf"
    fi
    if [[ ! -s $acme_cert_dir/fullchain.cer ]]; then
        [[ -z $(ss -H -ltn 'sport = :80') ]] || die 'TCP 80 已被占用，无法使用 standalone 验证。'
        say '申请证书：公网 TCP 80 必须可达；如有 AAAA 记录，IPv6 也须正确。'
        rc=0
        run_logged "$ACME" --home "$ACME_BASE" --issue --server letsencrypt --standalone --keylength ec-256 -d "$DOMAIN" || rc=$?
        [[ $rc -eq 0 || $rc -eq 2 ]] || die "证书申请失败（退出码 $rc）。"
    fi
    # 每个域名单独暂存；回调检查当前域名，防止旧域名覆盖新证书。
    STAGE=$CERT_DIR/staging/$DOMAIN
    install -d -o root -g root -m 0700 "$STAGE"
    # 永久保存正式回调；仅本次子进程继承跳过标志，由下方事务完成部署。
    # 标志不会写入 acme 配置/cron，即使本次部署失败，后续回调仍然有效。
    XY_STAGE_ONLY=1 run_logged "$ACME" --home "$ACME_BASE" --install-cert -d "$DOMAIN" "${ECC[@]}" \
        --key-file "$STAGE/server.key" --fullchain-file "$STAGE/server.crt" --reloadcmd "$SCRIPT --renew-reload $DOMAIN"
    if [[ ${FORCE_RENEW:-no} == yes ]] || ! openssl x509 -in "$STAGE/server.crt" -noout -checkend 86400 >/dev/null; then
        [[ -z $(ss -H -ltn 'sport = :80') ]] || die 'TCP 80 已被占用，证书无法续期。'
        local -a force_args=()
        [[ ${FORCE_RENEW:-no} != yes ]] || force_args=(--force)
        rc=0
        XY_STAGE_ONLY=1 run_logged "$ACME" --home "$ACME_BASE" --renew -d "$DOMAIN" "${ECC[@]}" "${force_args[@]}" || rc=$?
        [[ $rc -eq 0 || $rc -eq 2 ]] || die "证书续期失败（退出码 $rc）。"
    fi
}

# 首次安装先收集并确认参数；输入错误在当前项目重试。
installation_inputs() {
    local confirm
    INSTALL_CONFIRMED=no
    while true; do
        section '配置节点'
        hint '域名需要提前解析到这台服务器，不含协议、端口或路径。'
        while true; do
            ask DOMAIN '请输入域名（已解析到本服务器）：'
            DOMAIN=${DOMAIN,,}
            if domain_valid "$DOMAIN"; then break; fi
            warn '域名格式错误，请使用普通域名或 Punycode，不含协议/端口/路径。'
        done
        hint '回车使用默认端口 443；80 端口留给证书申请及续期。'
        while true; do
            ask PORT '监听端口 [443]：'; PORT=${PORT:-443}
            if [[ ! $PORT =~ ^[0-9]{1,5}$ ]]; then
                warn '端口必须是 1–65535 的整数。'; continue
            fi
            PORT=$((10#$PORT))
            if (( PORT < 1 || PORT > 65535 || PORT == 80 )); then
                warn '端口须为 1–65535，且保留 80 给证书验证。'; continue
            fi
            if [[ -n $(ss -H -ltn "sport = :$PORT") ]]; then
                warn "TCP $PORT 已被占用，请选择其他端口。"; continue
            fi
            break
        done
        hint '回车使用默认路径 /；客户端需要填写相同路径。'
        while true; do
            ask XPATH 'xHTTP 路径 [/]：'; XPATH=${XPATH:-/}
            if [[ $XPATH == /* && $XPATH != *[[:space:]]* && $XPATH != *\?* && $XPATH != *\#* ]]; then break; fi
            warn '路径须以 / 开头，且不包含空白、? 或 #。'
        done
        section '请确认节点信息'
        field '服务器地址' "$DOMAIN" 35
        field '监听端口' "$PORT" 94
        field 'xHTTP 路径' "$XPATH" 94
        field 'TLS' '已启用' 32
        hint '公网 TCP 80 和节点端口须放行。确认后开始安装 Xray 并准备证书。'
        while true; do
            ask confirm '确认并继续？[Y/n]（输入 e 重新填写）：'
            case $confirm in
                ''|y|Y) INSTALL_CONFIRMED=yes; return 0;;
                n|N) say '已取消安装，未安装 Xray 或申请证书。'; return 0;;
                e|E) break;;
                *) warn '请输入 Y、N 或 E；回车确认。';;
            esac
        done
    done
}

installation_failure() {
    local phase=$1 rc=$2
    error "安装未完成：$phase（退出码 $rc）。"
    say '具体错误请查看上方输出。'
    case $phase in
        '检查系统及依赖') hint '请检查软件源、服务器网络及 apt/dpkg 是否被其他进程占用。';;
        '配置节点') hint '请输入有效的域名、未被占用的端口和 xHTTP 路径。';;
        '安装 / 更新 Xray') hint '请检查服务器能否访问 GitHub；可用 XY_VERBOSE=1 xy 查看详细输出。';;
        '准备域名证书') hint '请核对域名 A/AAAA 解析、TCP 80 放行及占用情况，并查看上方 ACME 错误。';;
        *) hint '请运行 journalctl -u xray -n 50 --no-pager 查看服务日志；如显示备份路径，请保留备份。';;
    esac
}

install_xray() (
    set -e
    local work= existing=0 PORT XPATH UUID INSTALL_CONFIRMED phase='检查系统及依赖'
    finish_install() {
        local rc=$?
        trap - EXIT
        if (( rc != 0 )); then installation_failure "$phase" "$rc" >&2; fi
        [[ -z $work ]] || rm -rf -- "$work"
        exit "$rc"
    }
    trap finish_install EXIT
    section '安装 / 更新环境'
    hint '按阶段完成依赖、Xray、证书和服务部署，请等待每一步结束。'
    stage 1 4 '检查系统及依赖…'
    dependencies
    success '系统依赖检查完成。'
    lock
    work=$(mktemp -d)
    [[ -f $CONFIG ]] && existing=1
    if (( existing )); then
        managed_config
    else
        phase='配置节点'
        installation_inputs
        [[ $INSTALL_CONFIRMED == yes ]] || exit 0
    fi
    phase='安装 / 更新 Xray'
    stage 2 4 '安装 / 更新 Xray…'
    download "$INSTALL_URL" "$work/install-release.sh"
    bash -n "$work/install-release.sh"
    # 官方安装器可能升级并重启核心；现有配置不重新生成。
    hint '正在下载或更新 Xray 核心，请稍候…'
    run_logged bash "$work/install-release.sh" install
    success 'Xray 核心安装 / 更新完成。'
    if (( ! existing )); then
        # 官方安装器可能写入空配置；失败重试时不能把它误认成已有节点。
        rm -f -- "$CONFIG"
    fi
    require_tools
    directories
    if (( existing )); then
        [[ -s $DOMAIN_FILE ]] || die '旧配置缺少 /etc/xray-cert/domain.txt，请先补入实际域名。'
        DOMAIN=$(cat "$DOMAIN_FILE")
        domain_valid "$DOMAIN" || die '保存的域名格式无效。'
        cp "$CONFIG" "$work/candidate.json"
        say '已有配置：保留全部用户、UUID、端口和路径。'
    else
        UUID=$(new_uuid)
        jq -n --argjson port "$PORT" --arg id "$UUID" --arg path "$XPATH" --arg cert "$CERT" --arg key "$KEY" '
          {log:{loglevel:"warning"},inbounds:[{port:$port,protocol:"vless",
          settings:{clients:[{id:$id,email:"admin"}],decryption:"none"},
          streamSettings:{network:"xhttp",security:"tls",xhttpSettings:{path:$path},
          tlsSettings:{certificates:[{certificateFile:$cert,keyFile:$key}]}}}],
          outbounds:[{protocol:"freedom"}]}
        ' > "$work/candidate.json"
        printf '%s\n' "$DOMAIN" > "$DOMAIN_FILE"
    fi
    phase='准备域名证书'
    stage 3 4 '准备域名证书…'
    hint '正在申请、续期或复用证书；公网验证可能需要一些时间，请稍候…'
    prepare_certificate
    success '域名证书已准备完成。'
    phase='检查配置并启动服务'
    stage 4 4 '检查配置并启动服务…'
    apply_config "$work/candidate.json" yes
    systemctl enable xray
    section '安装结果'
    success '安装/更新完成；证书续期回调已注册。'
    field '服务状态' '运行中' 32
    list_users
    hint '以后输入 xy 打开管理菜单；普通用户使用 sudo xy。'
)

renew_reload() (
    set -e
    [[ ${XY_STAGE_ONLY:-0} != 1 ]] || exit 0
    lock
    require_tools
    managed_config
    if [[ -n ${1:-} ]]; then
        domain_valid "$1" || die '续期回调域名无效。'
        [[ $1 == "$(cat "$DOMAIN_FILE")" ]] || { say '忽略旧域名的续期回调。'; exit 0; }
        STAGE=$CERT_DIR/staging/$1
    fi
    directories
    apply_config "$CONFIG" yes
)

restart_xray() (
    set -e
    require_tools
    lock
    managed_config
    identity
    section '重启 Xray 服务'
    stage 1 2 '检查现有配置…'
    run_logged runuser -u "$SERVICE_USER" -g "$SERVICE_GROUP" -- "$(command -v xray)" run -test -config "$CONFIG"
    stage 2 2 '正在重启 Xray，连接会短暂中断…'
    if healthy_restart; then
        success 'Xray 服务已重启并正常运行。'
    else
        error 'Xray 重启失败，请查看 journalctl -u xray -n 50 --no-pager。' >&2
        exit 1
    fi
)

# 调用方持有管理锁；只清理已停止续期的旧域名单个证书目录。
cleanup_old_domain_cert() {
    local old_domain=$1 old_base=$2 suffix=$3 archive staging target legacy=no
    domain_valid "$old_domain" || return 1
    [[ $old_domain != "$(cat "$DOMAIN_FILE")" ]] || return 1
    systemctl is-active --quiet xray || return 1
    [[ $old_base == "$ACME_HOME" || $old_base == /root/.acme.sh ]] || return 1
    [[ $suffix == "" || $suffix == _ecc ]] || return 1
    archive=$old_base/$old_domain$suffix
    staging=$CERT_DIR/staging/$old_domain
    # 保留仍在续期或归属不明的存档，不能因清理绕过停止续期失败。
    [[ ! -e $archive/$old_domain.conf && -f $archive/$old_domain.conf.removed ]] || return 1
    # 拒绝符号链接及目录重定向，删除目标必须精确位于预期路径。
    for target in "$archive" "$staging"; do
        [[ ! -L $target ]] || return 1
        if [[ -e $target ]]; then
            [[ $(readlink -f -- "$target") == "$target" ]] || return 1
        fi
    done
    # 兼容早期版本的公共暂存文件：仅在证书与旧存档完全相同时清理。
    if cmp -s "$archive/fullchain.cer" "$CERT_DIR/staging/server.crt"; then
        for target in "$CERT_DIR/staging/server.crt" "$CERT_DIR/staging/server.key"; do
            [[ ! -L $target ]] || return 1
            if [[ -e $target ]]; then
                [[ $(readlink -f -- "$target") == "$target" ]] || return 1
            fi
        done
        legacy=yes
    fi
    rm -rf -- "$archive" "$staging" || return 1
    if [[ $legacy == yes ]]; then
        rm -f -- "$CERT_DIR/staging/server.crt" "$CERT_DIR/staging/server.key" || return 1
    fi
    say "已清理旧域名 $old_domain 的证书存档和暂存文件。"
}

update_domain_cert() (
    set -e
    require_tools
    local OLD_DOMAIN DOMAIN CONFIRM FORCE_RENEW=no work old_acme old_base
    local -a old_ecc
    managed_config
    OLD_DOMAIN=$(cat "$DOMAIN_FILE")
    domain_valid "$OLD_DOMAIN" || die '保存的域名格式无效。'
    section '更新域名及证书'
    field '当前域名' "$OLD_DOMAIN" 35
    ask DOMAIN '请输入新域名（留空保留当前域名，仅更新证书）：'
    DOMAIN=${DOMAIN:-$OLD_DOMAIN}
    DOMAIN=${DOMAIN,,}
    domain_valid "$DOMAIN" || die '域名格式错误，请使用普通域名或 Punycode，不含协议/端口/路径。'
    if [[ $DOMAIN == "$OLD_DOMAIN" ]]; then
        ask CONFIRM '强制重新签发证书？重复操作可能触发 CA 限额 [y/N]：'
        [[ ! $CONFIRM =~ ^[Yy]$ ]] || FORCE_RENEW=yes
    fi
    field '目标域名' "$DOMAIN" 35
    warn '请确认域名已解析到本服务器，公网 TCP 80 可达；部署时连接会短暂中断。'
    ask CONFIRM '确定更新域名及证书？[y/N]：'
    [[ $CONFIRM =~ ^[Yy]$ ]] || exit 0
    lock
    managed_config
    [[ $(cat "$DOMAIN_FILE") == "$OLD_DOMAIN" ]] || die '域名已被其他操作修改，请重新打开此功能。'
    directories
    work=$(mktemp -d)
    trap 'rm -rf -- "$work"' EXIT
    cp "$CONFIG" "$work/candidate.json"

    stage 1 3 '准备原域名续期配置…'
    # 先迁移旧域名的回调；后续申请/部署失败时旧域名仍可续期。
    local target_domain=$DOMAIN
    DOMAIN=$OLD_DOMAIN
    select_acme
    old_acme=$ACME; old_base=$ACME_BASE; old_ecc=("${ECC[@]}")
    [[ -f $old_acme ]] || die '找不到原 ACME 环境，请先选择菜单 1 安装/更新。'
    install -d -o root -g root -m 0700 "$CERT_DIR/staging/$OLD_DOMAIN"
    XY_STAGE_ONLY=1 run_logged "$old_acme" --home "$old_base" --install-cert -d "$OLD_DOMAIN" "${old_ecc[@]}" \
        --key-file "$CERT_DIR/staging/$OLD_DOMAIN/server.key" \
        --fullchain-file "$CERT_DIR/staging/$OLD_DOMAIN/server.crt" \
        --reloadcmd "$SCRIPT --renew-reload $OLD_DOMAIN"
    DOMAIN=$target_domain
    stage 2 3 '准备目标域名证书…'
    prepare_certificate
    stage 3 3 '检查并部署域名及证书…'
    apply_config "$work/candidate.json" yes "$DOMAIN"
    if [[ $DOMAIN != "$OLD_DOMAIN" ]]; then
        # 成功切换后才停止旧域名续期，旧证书存档保留。
        if ! "$old_acme" --home "$old_base" --remove -d "$OLD_DOMAIN" "${old_ecc[@]}"; then
            say '提示：旧域名续期未能停止，其回调会被忽略；请检查 ACME 日志。' >&2
        fi
    fi
    success '域名及证书更新完成。用户、UUID、端口和路径已保留。'
    say '如更换了域名，请使用下方新链接更新客户端：'
    list_users
    if [[ $DOMAIN != "$OLD_DOMAIN" ]]; then
        field '待清理旧域名' "$OLD_DOMAIN" 35
        warn '请先使用新链接确认客户端可以连接；清理后切回旧域名需要重新申请证书。'
        CONFIRM=
        prompt '是否清理旧域名证书？[y/N]：'
        if ! read -r CONFIRM; then
            say '未确认清理，已保留旧域名证书。'
        elif [[ $CONFIRM =~ ^[Yy]$ ]]; then
            local old_suffix=
            [[ ${#old_ecc[@]} -eq 0 ]] || old_suffix=_ecc
            if ! cleanup_old_domain_cert "$OLD_DOMAIN" "$old_base" "$old_suffix"; then
                say '旧证书未能安全清理，已保留未删除的文件；新域名更新已完成。' >&2
            fi
        else
            say '已保留旧域名证书。'
        fi
    fi
)

add_user() (
    set -e
    require_tools
    local EMAIL UUID temp
    section '添加用户'
    ask EMAIL '请输入新用户名/邮箱：'
    [[ -n $EMAIL && ${#EMAIL} -le 128 && $EMAIL != *[[:cntrl:]]* ]] || die '用户名须为 1–128 字符且不含控制字符。'
    lock
    managed_config
    jq -e --arg email "$EMAIL" 'any(.inbounds[0].settings.clients[]; .email==$email)' "$CONFIG" >/dev/null && die '此用户名已存在。'
    temp=$(mktemp "$XRAY_DIR/.xy-candidate.XXXXXX")
    trap 'rm -f -- "$temp"' EXIT
    UUID=$(new_uuid)
    jq --arg id "$UUID" --arg email "$EMAIL" '.inbounds[0].settings.clients += [{id:$id,email:$email}]' "$CONFIG" > "$temp"
    apply_config "$temp"
    success "已添加用户：$EMAIL"
    print_link "$EMAIL" "$UUID"
)

del_user() (
    set -e
    require_tools
    local EMAIL CONFIRM temp
    managed_config
    section '删除用户'
    say '现有用户：'
    jq -r '.inbounds[0].settings.clients[].email' "$CONFIG"
    ask EMAIL '请输入要删除的用户名/邮箱：'
    [[ -n $EMAIL ]] || exit 0
    field '待删除用户' "$EMAIL" 94
    warn '删除后，该用户的客户端将无法连接。'
    ask CONFIRM "确定删除 $EMAIL？[y/N]："
    [[ $CONFIRM =~ ^[Yy]$ ]] || exit 0
    lock
    managed_config
    jq -e --arg email "$EMAIL" 'any(.inbounds[0].settings.clients[]; .email==$email)' "$CONFIG" >/dev/null || die '用户不存在。'
    temp=$(mktemp "$XRAY_DIR/.xy-candidate.XXXXXX")
    trap 'rm -f -- "$temp"' EXIT
    jq --arg email "$EMAIL" '.inbounds[0].settings.clients |= map(select(.email!=$email))' "$CONFIG" > "$temp"
    jq -e '.inbounds[0].settings.clients | length > 0' "$temp" >/dev/null || die '至少需要保留一个用户。'
    apply_config "$temp"
    success "已删除用户：$EMAIL"
)

print_link() {
    local domain port path
    domain=$(cat "$DOMAIN_FILE") || return
    port=$(jq -r '.inbounds[0].port' "$CONFIG") || return
    path=$(jq -r '.inbounds[0].streamSettings.xhttpSettings.path' "$CONFIG") || return
    local link
    link="vless://$2@$domain:$port?encryption=none&security=tls&sni=$(uri "$domain")&type=xhttp&path=$(uri "$path")#$(uri "$1")"
    printf '\n'
    field '用户名' "$1" 94
    # 链接独立一行，方便复制导入。
    paint 32 "$link"
    printf '\n'
}

list_users() (
    set -e
    require_tools
    managed_config
    local row email uuid
    while IFS= read -r row; do
        email=$(jq -r '.email' <<< "$row")
        uuid=$(jq -r '.id' <<< "$row")
        print_link "$email" "$uuid"
    done < <(jq -c '.inbounds[0].settings.clients[]' "$CONFIG")
)

uninstall_all() (
    set -e
    local CONFIRM work
    section '彻底卸载'
    if [[ -s $DOMAIN_FILE ]]; then field '当前域名' "$(cat "$DOMAIN_FILE")" 35; fi
    warn '将删除 Xray、所有 Xray 用户配置、此脚本管理的证书和 xy 命令。共享的 /root/.acme.sh 保留。'
    ask CONFIRM '确定彻底卸载？[y/N]：'
    [[ $CONFIRM =~ ^[Yy]$ ]] || exit 0
    lock
    work=$(mktemp -d)
    trap 'rm -rf -- "$work"' EXIT
    # 先下载并校验，避免网络失败后才发现服务已经停止。
    download "$INSTALL_URL" "$work/install-release.sh"
    bash -n "$work/install-release.sh"
    if [[ -s $DOMAIN_FILE ]]; then
        DOMAIN=$(cat "$DOMAIN_FILE")
        domain_valid "$DOMAIN" || die '域名记录无效，停止卸载。'
        select_acme
        if [[ $ACME_BASE == /root/.acme.sh ]]; then
            "$ACME" --home "$ACME_BASE" --remove -d "$DOMAIN" "${ECC[@]}"
        fi
    fi
    rm -f -- /etc/cron.d/xy-acme
    run_logged bash "$work/install-release.sh" remove --purge
    # 固定目录；不删除共享 acme.sh、系统依赖、其他站点或其他 crontab 条目。
    rm -rf -- /usr/local/etc/xray /etc/xray-cert
    rm -f -- /var/log/xray_cron_error.log /var/log/xy-acme.log /usr/local/bin/xy
    systemctl daemon-reload
    success '卸载完成。'
)

main() {
    platform
    if [[ ${1:-} == --renew-reload ]]; then
        [[ $# -le 2 ]] || die '续期回调参数过多。'
        renew_reload "${2:-}" >>/var/log/xray_cron_error.log 2>&1
        return $?
    fi
    [[ $# -eq 0 ]] || die '未知参数。'
    [[ -t 0 ]] || die '菜单需要交互终端。请保存脚本后运行，不要通过管道执行。'
    [[ $(readlink -f -- "$0") == "$SCRIPT" ]] || die '请先执行：sudo install -m 0755 xy.sh /usr/local/bin/xy，再运行 sudo xy。'
    if [[ ! -f $CONFIG ]]; then
        install_xray
        [[ $? -eq 0 ]] || say '安装未完成；请根据上方错误修正后重试。'
        pause
    fi
    local CHOICE rc
    while true; do
        show_menu
        ask CHOICE '请选择 [1-8]：'
        case $CHOICE in
            1) install_xray;;
            2) add_user;;
            3) del_user;;
            4) list_users;;
            5) uninstall_all; rc=$?; [[ -f $SCRIPT ]] || return "$rc"; (exit "$rc");;
            6) restart_xray;;
            7) update_domain_cert;;
            8) return 0;;
            *) warn '无效选项，请输入 1–8。'; continue;;
        esac
        rc=$?
        (( rc == 0 )) || error "操作未完成（退出码 $rc），请查看上方错误。"
        pause
    done
}

# 可被测试工具 source；正常运行时进入菜单。
if [[ ${BASH_SOURCE[0]} == "$0" ]]; then main "$@"; fi
