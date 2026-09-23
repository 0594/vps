#!/bin/bash
# ============================================================ #
#  VPS 初始化脚本（系统优化 + SSH安全加固 + 状态检测）
#  适用：Debian Bookworm 1核1G VPS
#  用法：bash vps_init.sh
# ============================================================ #
set -u

echo_ok()    { echo -e "\033[32m[OK]\033[0m  $1"; }
echo_warn()  { echo -e "\033[33m[WARN]\033[0m  $1"; }
echo_error() { echo -e "\033[31m[ERROR]\033[0m $1"; }
echo_info()  { echo -e "\033[36m[INFO]\033[0m  $1"; }

if [ "$(id -u)" -ne 0 ]; then
    echo_error "必须root运行"
    exit 1
fi

echo "=========================================================="
echo "  VPS 初始化脚本"
echo "  时间：$(date)"
echo "=========================================================="

# ============================================================
#  第一部分：系统优化（低风险，不碰systemd核心组件）
# ============================================================
echo ""
echo "============ 【系统优化】 ============"

# 1. 关闭 cloud-init（云初始化工具，系统装好后不再需要）
echo_info "关闭 cloud-init ..."
systemctl disable --now cloud-init.service cloud-init-local.service cloud-config.service cloud-final.service 2>/dev/null
systemctl mask cloud-init.service cloud-init-local.service cloud-config.service cloud-final.service 2>/dev/null
echo_ok "cloud-init 已禁用"

# 2. journal 日志放内存（Storage=volatile），减少磁盘写入
echo_info "配置 journald 日志为内存模式 ..."
sed -i 's/#Storage=auto/Storage=volatile/' /etc/systemd/journald.conf
sed -i 's/^Storage=auto/Storage=volatile/' /etc/systemd/journald.conf
# 设置日志最大占用16M
sed -i '/^Storage=volatile/a\SystemMaxUse=16M' /etc/systemd/journald.conf
systemctl restart systemd-journald 2>/dev/null
echo_ok "journald 已配置内存模式（最大16M）"

# ============================================================
#  第二部分：备份 sshd 配置
# ============================================================
echo ""
echo_info "备份 sshd_config ..."
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)
echo_ok "已备份"

# ============================================================
#  第三部分：SSH安全加固
# ============================================================
echo ""
echo_info "开始SSH安全加固..."

# 显式启用密钥登录
sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config
# 最大认证尝试次数3次
sed -i 's/^#MaxAuthTries 6/MaxAuthTries 3/' /etc/ssh/sshd_config
sed -i 's/^MaxAuthTries 6/MaxAuthTries 3/' /etc/ssh/sshd_config
# 确保密码登录关闭
sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config

echo_ok "SSH配置已修改"

# ============================================================
#  第四部分：重启 sshd
# ============================================================
echo ""
echo_warn "即将重启 sshd 服务，如配置错误可能断开连接"
read -p "⚠️  已新开SSH窗口确认密钥可登录？输入 y 继续：" CONFIRM
if [ "$CONFIRM" != "y" ]; then
    echo_warn "已取消重启，请手动执行 systemctl restart sshd"
    exit 0
fi

systemctl restart sshd
echo_ok "sshd 已重启"

# ============================================================
#  第五部分：状态检测
# ============================================================
echo ""
echo "=========================================================="
echo "  状态检测结果"
echo "=========================================================="

# 检测 cloud-init
echo ""
echo_info "--- 系统优化状态 ---"
if systemctl is-active --quiet cloud-init.service 2>/dev/null; then
    echo_warn "cloud-init 仍在运行"
else
    echo_ok "cloud-init 已禁用"
fi

# 检测 journald 存储模式
JOURNAL_STORAGE=$(grep -E '^Storage=' /etc/systemd/journald.conf | awk -F= '{print $2}')
if [ "$JOURNAL_STORAGE" = "volatile" ]; then
    echo_ok "journald 日志模式：内存 (volatile)"
else
    echo_warn "journald 日志模式：${JOURNAL_STORAGE:-auto（写磁盘）}"
fi

# 检测密码登录
echo ""
echo_info "--- SSH安全状态 ---"
PWD_AUTH=$(grep -E '^PasswordAuthentication' /etc/ssh/sshd_config | awk '{print $2}')
if [ "$PWD_AUTH" = "no" ]; then
    echo_ok "密码登录：已关闭"
else
    echo_error "密码登录：仍为开启 (${PWD_AUTH:-yes})，存在爆破风险！"
fi

PUB_AUTH=$(grep -E '^PubkeyAuthentication' /etc/ssh/sshd_config | awk '{print $2}')
if [ "$PUB_AUTH" = "yes" ]; then
    echo_ok "密钥登录：已开启"
else
    echo_warn "密钥登录：未显式开启 (${PUB_AUTH:-默认yes})"
fi

MAX_TRIES=$(grep -E '^MaxAuthTries' /etc/ssh/sshd_config | awk '{print $2}')
if [ "$MAX_TRIES" = "3" ]; then
    echo_ok "最大认证次数：3次"
else
    echo_warn "最大认证次数：${MAX_TRIES:-6}（默认6）"
fi

SSH_PORT=$(grep -E '^Port' /etc/ssh/sshd_config | awk '{print $2}')
echo_info "SSH端口：${SSH_PORT:-22}"

echo ""
if systemctl is-active --quiet sshd || systemctl is-active --quiet ssh; then
    echo_ok "sshd服务运行正常"
else
    echo_error "sshd服务异常！"
fi

# 内存状态
echo ""
echo_info "--- 内存状态 ---"
free -h

echo ""
echo "=========================================================="
echo "  ✅ 初始化完成"
echo "=========================================================="
echo_info "提示："
echo_info "  1. 确认当前SSH连接未断开"
echo_info "  2. sshd备份文件：/etc/ssh/sshd_config.bak.*"
echo_info "  3. 防火墙（UFW）、时区、字符集待后续配置"
