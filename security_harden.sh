#!/bin/bash

# ============================================
# 安全强化脚本 - Ubuntu 24.04
# 功能：
#   1. 配置 fail2ban：SSH 失败 1 次即永久封禁
#   2. 禁用 IPv6 栈（sysctl 方式）
# 作者：AI Assistant
# 注意：请在执行前备份重要数据，确保有控制台访问权限
# ============================================

set -e  # 遇到错误立即退出

# 颜色定义
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
NC='\033[0m' # No Color

# 检查 root 权限
check_root() {
    if [[ $EUID -ne 0 ]]; then
        echo -e "${RED}错误：此脚本需要 root 权限。请使用 sudo 运行。${NC}"
        exit 1
    fi
}

# 通用确认函数
confirm() {
    read -r -p "$1 [y/N] " response
    case "$response" in
        [yY][eE][sS]|[yY]) 
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# ------------------ 1. 配置 fail2ban ------------------
configure_fail2ban() {
    echo -e "${GREEN}>>> 开始配置 fail2ban（一次失败即永久封禁）${NC}"

    # 安装 fail2ban
    if ! command -v fail2ban-client &> /dev/null; then
        echo "fail2ban 未安装，正在安装..."
        apt update
        apt install fail2ban -y
        systemctl enable fail2ban
    else
        echo "fail2ban 已安装，跳过安装步骤。"
    fi

    # 提示用户输入自己的 IP（白名单）
    echo -e "${YELLOW}重要：请将你当前的公网 IP 加入白名单，否则你可能把自己永久封禁！${NC}"
    read -r -p "请输入你当前的公网 IP（多个 IP 用空格分隔，留空则跳过）： " user_ips
    if [[ -n "$user_ips" ]]; then
        ignoreip_list="127.0.0.1/8 ::1 $user_ips"
    else
        ignoreip_list="127.0.0.1/8 ::1"
        echo -e "${RED}警告：未添加任何额外白名单 IP，请确保你当前登录的 IP 已在 127.0.0.1 或 ::1 中，否则一旦误封将无法连接！${NC}"
        confirm "是否继续？" || return 1
    fi

    # 备份原配置（如果存在）
    jail_local="/etc/fail2ban/jail.local"
    if [[ -f "$jail_local" ]]; then
        backup="${jail_local}.bak.$(date +%Y%m%d%H%M%S)"
        cp "$jail_local" "$backup"
        echo "已备份原有 $jail_local 到 $backup"
    fi

    # 写入新配置
    cat > "$jail_local" <<EOF
[DEFAULT]
# 白名单
ignoreip = $ignoreip_list

# 全局封禁时间：永久（-1）
bantime = -1

# 统计窗口：30秒
findtime = 30s

# 最大失败次数：1
maxretry = 1

# 递归封禁（可选）
recidive = true

[sshd]
enabled = true
logpath = /var/log/auth.log
maxretry = 1
findtime = 30s
bantime = -1
EOF

    # 重启 fail2ban
    systemctl restart fail2ban
    echo -e "${GREEN}✓ fail2ban 已重启，配置生效。${NC}"

    # 显示状态
    echo "当前 SSH 封禁状态："
    fail2ban-client status sshd

    echo -e "${YELLOW}提示：若需要手动解封某个 IP，使用命令：sudo fail2ban-client set sshd unbanip <IP>${NC}"
}

# ------------------ 2. 禁用 IPv6（sysctl） ------------------
disable_ipv6() {
    echo -e "${GREEN}>>> 开始禁用 IPv6 栈（sysctl 方式）${NC}"

    # 检查当前是否已禁用
    if [[ $(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null) -eq 1 ]]; then
        echo "IPv6 已经禁用，跳过配置。"
        return 0
    fi

    # 备份 sysctl 配置
    sysctl_conf="/etc/sysctl.conf"
    backup="${sysctl_conf}.bak.$(date +%Y%m%d%H%M%S)"
    cp "$sysctl_conf" "$backup"
    echo "已备份 $sysctl_conf 到 $backup"

    # 检查是否已有相关配置，避免重复添加
    if ! grep -q "net.ipv6.conf.all.disable_ipv6" "$sysctl_conf"; then
        cat >> "$sysctl_conf" <<EOF

# 下面三行由脚本添加：禁用 IPv6
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
        echo "已向 $sysctl_conf 添加禁用 IPv6 参数。"
    else
        echo "sysctl.conf 中已存在 IPv6 禁用配置，跳过添加。"
    fi

    # 立即应用
    sysctl -p

    # 修复重启持久性（Ubuntu 24.04 bug）
    echo "修复重启后配置失效的问题（添加 crontab @reboot 重新加载）..."
    crontab -l 2>/dev/null | grep -q "sysctl --system" || {
        (crontab -l 2>/dev/null; echo "@reboot sleep 15 && /usr/sbin/sysctl --system") | crontab -
        echo "已添加 crontab 任务。"
    }

    # 验证
    if [[ $(sysctl -n net.ipv6.conf.all.disable_ipv6) -eq 1 ]]; then
        echo -e "${GREEN}✓ IPv6 禁用成功，无需重启即可生效。${NC}"
        echo "当前网络接口的 IPv6 地址："
        ip -6 addr show 2>/dev/null || echo "无 IPv6 地址（禁用成功）"
    else
        echo -e "${RED}✗ IPv6 禁用失败，请手动检查。${NC}"
        return 1
    fi

    echo -e "${YELLOW}提示：如果想重新启用 IPv6，请将 /etc/sysctl.conf 中对应的 1 改为 0 或删除，然后执行 sysctl -p，并删除 crontab 中的 @reboot 行。${NC}"
}

# ------------------ 主菜单 ------------------
show_menu() {
    clear
    echo "========================================"
    echo "       Ubuntu 24.04 安全强化脚本"
    echo "========================================"
    echo "1) 配置 fail2ban（一次失败永久封禁）"
    echo "2) 禁用 IPv6 栈"
    echo "3) 同时执行 1 和 2"
    echo "4) 退出"
    echo "========================================"
    read -r -p "请选择 [1-4]: " choice
    case $choice in
        1)
            configure_fail2ban
            ;;
        2)
            disable_ipv6
            ;;
        3)
            configure_fail2ban
            echo ""
            disable_ipv6
            ;;
        4)
            echo "退出。"
            exit 0
            ;;
        *)
            echo -e "${RED}无效选项，请重新运行脚本。${NC}"
            exit 1
            ;;
    esac
    echo -e "${GREEN}操作完成。${NC}"
}

# 主执行
check_root
show_menu
exit 0
