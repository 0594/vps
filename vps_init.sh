#!/bin/bash
# ============================================================ #
#  VPS 初始化脚本（SSH安全加固 + 安全状态检测）
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
echo "  VPS 初始化脚本（SSH安全加固）"
echo "  时间：$(date)"
echo "=========================================================="

# ========== 1. 备份sshd配置 ==========
echo ""
echo_info "备份 sshd_config ..."
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)
echo_ok "已备份"

# ========== 2. SSH安全加固 ==========
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

# ========== 3. 重启sshd ==========
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
#  安全状态检测
# ============================================================
echo ""
echo "=========================================================="
echo "  安全状态检测结果"
echo "=========================================================="

# 检测密码登录
PWD_AUTH=$(grep -E '^PasswordAuthentication' /etc/ssh/sshd_config | awk '{print $2}')
if [ "$PWD_AUTH" = "no" ]; then
    echo_ok "密码登录：已关闭 (PasswordAuthentication no)"
else
    echo_error "密码登录：仍为开启 (当前值: ${PWD_AUTH:-yes})，存在爆破风险！"
fi

# 检测密钥登录
PUB_AUTH=$(grep -E '^PubkeyAuthentication' /etc/ssh/sshd_config | awk '{print $2}')
if [ "$PUB_AUTH" = "yes" ]; then
    echo_ok "密钥登录：已开启 (PubkeyAuthentication yes)"
else
    echo_warn "密钥登录：未显式开启 (当前值: ${PUB_AUTH:-默认yes})"
fi

# 检测最大认证次数
MAX_TRIES=$(grep -E '^MaxAuthTries' /etc/ssh/sshd_config | awk '{print $2}')
if [ "$MAX_TRIES" = "3" ]; then
    echo_ok "最大认证次数：3次 (MaxAuthTries 3)"
else
    echo_warn "最大认证次数：当前值 ${MAX_TRIES:-6}（默认6）"
fi

# 检测SSH端口
SSH_PORT=$(grep -E '^Port' /etc/ssh/sshd_config | awk '{print $2}')
echo_info "SSH端口：${SSH_PORT:-22}（默认22）"

# 检测sshd服务状态
echo ""
if systemctl is-active --quiet sshd || systemctl is-active --quiet ssh; then
    echo_ok "sshd服务运行正常"
else
    echo_error "sshd服务异常！请检查配置"
fi

echo ""
echo "=========================================================="
echo "  ✅ 初始化完成"
echo "=========================================================="
echo ""
echo_info "提示："
echo_info "  1. 确认当前SSH连接未断开"
echo_info "  2. 备份文件在 /etc/ssh/sshd_config.bak.*"
echo_info "  3. 防火墙配置（UFW）待后续手动添加"
