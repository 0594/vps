#!/bin/bash
# ============================================================ #
#  VPS 初始化脚本（系统优化 + SSH加固 + UFW防火墙 + 状态检测）
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
#  第一部分：系统优化
# ============================================================
echo ""
echo "============ 【系统优化】 ============"

echo_info "关闭 cloud-init ..."
systemctl disable --now cloud-init.service cloud-init-local.service cloud-config.service cloud-final.service 2>/dev/null
systemctl mask cloud-init.service cloud-init-local.service cloud-config.service cloud-final.service 2>/dev/null
echo_ok "cloud-init 已禁用"

echo_info "配置 journald 日志为内存模式 ..."
sed -i 's/#Storage=auto/Storage=volatile/' /etc/systemd/journald.conf
sed -i 's/^Storage=auto/Storage=volatile/' /etc/systemd/journald.conf
sed -i '/^Storage=volatile/a\SystemMaxUse=16M' /etc/systemd/journald.conf
systemctl restart systemd-journald 2>/dev/null
echo_ok "journald 已配置内存模式（最大16M）"

# ============================================================
#  第二部分：UFW 防火墙
# ============================================================
echo ""
echo "============ 【UFW防火墙】 ============"

echo_info "安装 ufw ..."
apt install -y ufw >/dev/null 2>&1

echo_info "设置默认策略：拒绝入站，允许出站 ..."
ufw default deny incoming
ufw default allow outgoing

echo_info "放行基础端口：SSH / HTTP / HTTPS ..."
ufw allow ssh
ufw allow 80/tcp
ufw allow 443/tcp

echo_warn "即将启用防火墙，SSH(22)已放行，不会断开连接"
read -p "⚠️  输入 y 启用防火墙：" CONFIRM
if [ "$CONFIRM" = "y" ]; then
    ufw --force enable
    echo_ok "UFW 已启用"
else
    echo_warn "跳过启用，手动执行 ufw enable"
fi

# ============================================================
#  第三部分：安装 vfw 端口管理命令
# ============================================================
echo ""
echo_info "安装 vfw 端口管理命令 ..."
cat > /usr/local/bin/vfw <<'VFW_EOF'
#!/bin/bash
# vfw - VPS 防火墙端口管理（交互式菜单）
if [ "$(id -u)" -ne 0 ]; then
    echo "必须root运行"
    exit 1
fi

while true; do
    clear
    echo "============================================"
    echo "  VPS 防火墙端口管理"
    echo "============================================"
    echo ""
    echo "  1) 开放端口"
    echo "  2) 删除端口"
    echo "  3) 查看端口列表"
    echo "  0) 退出"
    echo ""
    read -p "请选择 [0-3]: " CHOICE

    case "$CHOICE" in
        1)
            echo ""
            read -p "输入要开放的端口号: " PORT
            if [ -z "$PORT" ]; then
                read -p "端口不能为空，按回车继续..." DUMMY
                continue
            fi
            read -p "协议 (tcp/udp，默认tcp): " PROTO
            PROTO="${PROTO:-tcp}"
            ufw allow ${PORT}/${PROTO}
            echo ""
            echo "✅ 已开放 ${PORT}/${PROTO}"
            read -p "按回车继续..." DUMMY
            ;;
        2)
            echo ""
            ufw status numbered
            echo ""
            read -p "输入要删除的规则序号(数字): " NUM
            if [ -z "$NUM" ]; then
                read -p "序号不能为空，按回车继续..." DUMMY
                continue
            fi
            ufw --force delete ${NUM}
            echo ""
            echo "✅ 已删除规则 #${NUM}"
            read -p "按回车继续..." DUMMY
            ;;
        3)
            echo ""
            echo "--- 防火墙状态 ---"
            ufw status verbose
            echo ""
            read -p "按回车继续..." DUMMY
            ;;
        0)
            echo "再见"
            break
            ;;
        *)
            read -p "无效选择，按回车继续..." DUMMY
            ;;
    esac
done
VFW_EOF
chmod +x /usr/local/bin/vfw
echo_ok "vfw 命令已安装"

# ============================================================
#  第四部分：安装 vupdate 安全补丁命令
# ============================================================
echo ""
echo_info "安装 vupdate 安全补丁命令 ..."
cat > /usr/local/bin/vupdate <<'VUPDATE_EOF'
#!/bin/bash
# vupdate - VPS 安全补丁更新（1核1G优化版）
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
echo "  安全补丁更新"
echo "  时间：$(date)"
echo "=========================================================="

# --- 检查并配置swap ---
echo ""
echo_info "检查Swap状态..."
SWAP_NOW=$(free -m | awk '/Swap:/{print $2}')
if [ "$SWAP_NOW" -lt 1000 ]; then
    echo_warn "Swap不足，自动创建1G swapfile..."
    if [ ! -f /swapfile ]; then
        if command -v fallocate &>/dev/null; then
            fallocate -l 1G /swapfile
        else
            dd if=/dev/zero of=/swapfile bs=1M count=1024 status=progress
        fi
        chmod 600 /swapfile
        mkswap /swapfile
    fi
    swapon /swapfile 2>/dev/null
    grep -q "/swapfile" /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    sed -i '/^vm.swappiness=/c\vm.swappiness=10' /etc/sysctl.conf
    grep -q "^vm.swappiness=" /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
    sysctl vm.swappiness=10 &>/dev/null
    sleep 2
else
    echo_ok "Swap已就绪 (${SWAP_NOW}MB)"
fi

SWAP_AFTER=$(free -m | awk '/Swap:/{print $2}')
if [ "$SWAP_AFTER" -lt 1000 ]; then
    echo_error "Swap创建失败，中止更新"
    exit 5
fi
echo_ok "Swap: ${SWAP_AFTER}MB"

# --- apt低优先级配置 ---
echo 'APT::Acquire::Queue-Mode "access";' > /etc/apt/apt.conf.d/99lowmem
echo 'APT::Acquire::Retries "3";' >> /etc/apt/apt.conf.d/99lowmem

if fuser /var/lib/dpkg/lock-frontend &>/dev/null; then
    echo_error "apt进程正在运行，请稍后再试"
    exit 2
fi

# --- 刷新软件源 ---
echo ""
echo_info "刷新软件源（低优先级运行）..."
nice -n 10 ionice -c 3 apt update -o Acquire::Languages=none -o Acquire::Translation=none
if [ $? -ne 0 ]; then
    echo_error "apt update失败，自动修复dpkg..."
    dpkg --configure -a
    exit 3
fi

# --- 列出安全补丁 ---
echo ""
echo_info "检查安全补丁..."
SEC_PKGS=$(apt list --upgradable 2>/dev/null | grep "bookworm-security" | cut -d/ -f1 | sort -u)

if [ -z "$SEC_PKGS" ]; then
    echo_ok "✅ 没有安全补丁需要安装"
else
    echo_info "待更新安全包："
    echo "$SEC_PKGS"
    PKG_COUNT=$(echo "$SEC_PKGS" | wc -l)
    echo ""
    echo_info "共 ${PKG_COUNT} 个包"
    read -p "⚠️  输入 y 开始安装：" CONFIRM
    if [ "$CONFIRM" != "y" ]; then
        echo_info "已取消"
        exit 0
    fi

    echo ""
    echo_info "安装安全补丁（低优先级运行）..."
    DEBIAN_FRONTEND=noninteractive nice -n 10 ionice -c 3 \
        apt install -y --only-upgrade $SEC_PKGS \
        -o Dpkg::Options::="--force-confold"
    if [ $? -ne 0 ]; then
        echo_error "安装出错，自动修复dpkg..."
        dpkg --configure -a
        exit 4
    fi
    echo_info "清理apt缓存..."
    apt clean
    apt autoremove -y
fi

# --- 结果 ---
echo ""
echo_info "最终状态："
free -h
if [ -f /var/run/reboot-required ]; then
    echo_warn "🔴 系统需要重启！低峰期执行 reboot"
else
    echo_ok "🟢 无需重启"
fi
echo ""
echo_ok "完成"
VUPDATE_EOF
chmod +x /usr/local/bin/vupdate
echo_ok "vupdate 命令已安装"

# ============================================================
#  第五部分：备份 sshd 配置
# ============================================================
echo ""
echo_info "备份 sshd_config ..."
cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak.$(date +%Y%m%d%H%M%S)
echo_ok "已备份"

# ============================================================
#  第六部分：SSH安全加固
# ============================================================
echo ""
echo_info "开始SSH安全加固..."
sed -i 's/#PubkeyAuthentication yes/PubkeyAuthentication yes/' /etc/ssh/sshd_config
sed -i 's/^#MaxAuthTries 6/MaxAuthTries 3/' /etc/ssh/sshd_config
sed -i 's/^MaxAuthTries 6/MaxAuthTries 3/' /etc/ssh/sshd_config
sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config
echo_ok "SSH配置已修改"

echo ""
echo_warn "即将重启 sshd"
read -p "⚠️  已新开SSH窗口确认密钥可登录？输入 y 继续：" CONFIRM
if [ "$CONFIRM" != "y" ]; then
    echo_warn "已取消重启"
    exit 0
fi
systemctl restart sshd
echo_ok "sshd 已重启"

# ============================================================
#  第七部分：状态检测
# ============================================================
echo ""
echo "=========================================================="
echo "  状态检测结果"
echo "=========================================================="

echo ""
echo_info "--- 系统优化状态 ---"
if systemctl is-active --quiet cloud-init.service 2>/dev/null; then
    echo_warn "cloud-init 仍在运行"
else
    echo_ok "cloud-init 已禁用"
fi
JOURNAL_STORAGE=$(grep -E '^Storage=' /etc/systemd/journald.conf | awk -F= '{print $2}')
if [ "$JOURNAL_STORAGE" = "volatile" ]; then
    echo_ok "journald 日志：内存模式"
else
    echo_warn "journald 日志：${JOURNAL_STORAGE:-写磁盘}"
fi

echo ""
echo_info "--- 防火墙状态 ---"
ufw status

echo ""
echo_info "--- SSH安全状态 ---"
PWD_AUTH=$(grep -E '^PasswordAuthentication' /etc/ssh/sshd_config | awk '{print $2}')
if [ "$PWD_AUTH" = "no" ]; then
    echo_ok "密码登录：已关闭"
else
    echo_error "密码登录：仍为开启 (${PWD_AUTH:-yes})"
fi
PUB_AUTH=$(grep -E '^PubkeyAuthentication' /etc/ssh/sshd_config | awk '{print $2}')
if [ "$PUB_AUTH" = "yes" ]; then
    echo_ok "密钥登录：已开启"
else
    echo_warn "密钥登录：未显式开启"
fi
MAX_TRIES=$(grep -E '^MaxAuthTries' /etc/ssh/sshd_config | awk '{print $2}')
echo_info "最大认证次数：${MAX_TRIES:-6}"

echo ""
echo_info "--- 已安装命令 ---"
echo_info "  vfw      防火墙端口管理菜单"
echo_info "  vupdate  安全补丁更新"

echo ""
echo_info "--- 内存状态 ---"
free -h

echo ""
echo "=========================================================="
echo "  ✅ 初始化完成"
echo "=========================================================="
