#!/usr/bin/env bash
# 一键安装入口：下载、检查并安装 xy，然后从终端启动交互菜单。
# 安装命令见 README.md；本文件不会重置已有 Xray 配置。

main() (
    set -euo pipefail
    umask 077
    export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    local url='https://raw.githubusercontent.com/brian952700/xhttp/main/xy.sh'
    local target=/usr/local/bin/xy temp
    local -a elevate=()

    [[ $(uname -s) == Linux && -d /run/systemd/system ]] || {
        printf '错误：需要以 systemd 启动的 Linux 服务器。\n' >&2; exit 1;
    }
    # 通过管道运行时 stdin 是脚本数据，菜单必须单独连接到控制终端。
    if ! (exec 3<>/dev/tty) 2>/dev/null; then
        printf '错误：需要交互终端，请在 SSH 终端中运行安装命令。\n' >&2
        exit 1
    fi
    command -v curl >/dev/null || { printf '错误：请先安装 curl。\n' >&2; exit 1; }
    if (( EUID != 0 )); then
        command -v sudo >/dev/null || { printf '错误：请使用 root 运行，或先安装 sudo。\n' >&2; exit 1; }
        elevate=(sudo)
        sudo -v </dev/tty
    fi

    temp=$(mktemp -d)
    trap 'rm -rf -- "$temp"' EXIT
    trap 'exit 130' INT
    trap 'exit 143' TERM
    printf '正在下载 xy 管理脚本…\n'
    curl --fail --show-error --location --proto '=https' --tlsv1.2 \
        --retry 3 --connect-timeout 20 --max-time 300 "$url" -o "$temp/xy.sh"
    [[ -s $temp/xy.sh ]] || { printf '错误：下载的脚本为空。\n' >&2; exit 1; }
    bash -n "$temp/xy.sh"
    "${elevate[@]}" install -o root -g root -m 0755 "$temp/xy.sh" "$target"
    printf '安装完成。以后使用 sudo xy（root 用户直接输入 xy）打开菜单。\n'
    "${elevate[@]}" "$target" </dev/tty
)

main "$@"
