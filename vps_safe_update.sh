#!/bin/bash
# ============================================================ #
#  1核1G VPS 安全更新脚本（Debian Bookworm）
#  流程：先Swap验证 → 低优先级apt → 安全补丁安装
#  用法：bash vps_safe_update.sh
# ============================================================ #
set -u

echo_info()  { echo -e "\033[32m[INFO]\033[0m  $1"; }
echo_warn()  { echo -e "\033[33m[WARN]\033[0m  $1"; }
echo_error() { echo -e "\033[31m[ERROR]\033[0m $1"; }

if [ "$(id -u)" -ne 0 ]; then
    echo_error "必须root运行"
    exit 1
fi

echo "=========================================================="
echo "  安全更新脚本（先Swap后更新模式）"
echo "  时间：$(date)"
echo "=========================================================="

echo ""
echo "============ 【第一阶段：配置Swap】 ============"
SWAP_NOW=$(free -m | awk '/Swap:/{print $2}')
echo_info "当前Swap总量：${SWAP_NOW}MB"

if [ "$SWAP_NOW" -lt 1000 ]; then
    echo_warn "Swap不足1000M，开始创建/补全..."
    if [ ! -f /swapfile ]; then
        echo_info "创建 /swapfile (1G)..."
        if command -v fallocate &>/dev/null; then
            fallocate -l 1G /swapfile
        else
            dd if=/dev/zero of=/swapfile bs=1M count=1024 status=progress
        fi
        chmod 600 /swapfile
        mkswap /swapfile
    fi
    echo_info "激活swap..."
    swapon /swapfile 2>/dev/null
    grep -q "/swapfile" /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
    echo_info "设置 swappiness=10..."
    sed -i '/^vm.swappiness=/c\vm.swappiness=10' /etc/sysctl.conf
    grep -q "^vm.swappiness=" /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf
    sysctl vm.swappiness=10 &>/dev/null
    sleep 2
else
    echo_info "Swap已≥1000MB，跳过创建"
fi

echo ""
echo_info "验证Swap状态："
free -h
SWAP_AFTER=$(free -m | awk '/Swap:/{print $2}')
if [ "$SWAP_AFTER" -lt 1000 ]; then
    echo_error "Swap创建失败，当前仅 ${SWAP_AFTER}MB，中止更新"
    exit 5
fi
echo_info "✅ Swap生效，总量 ${SWAP_AFTER}MB"

MEM_AVAIL=$(free -m | awk '/Mem:/{print $7}')
echo_info "可用内存：${MEM_AVAIL}MB"

echo ""
echo "============ 【第二阶段：配置apt低优先级】 ============"
echo 'APT::Acquire::Queue-Mode "access";' > /etc/apt/apt.conf.d/99lowmem
echo 'APT::Acquire::Retries "3";' >> /etc/apt/apt.conf.d/99lowmem
echo_info "apt 并行下载限制为1"
if fuser /var/lib/dpkg/lock-frontend &>/dev/null; then
    echo_error "apt进程正在运行，请稍后再试"
    exit 2
fi
echo_info "无dpkg锁，可以继续"

echo ""
echo "============ 【第三阶段：刷新软件源】 ============"
echo_info "apt update（低优先级运行）..."
nice -n 10 ionice -c 3 apt update -o Acquire::Languages=none -o Acquire::Translation=none
if [ $? -ne 0 ]; then
    echo_error "apt update失败，自动修复dpkg..."
    dpkg --configure -a
    exit 3
fi
echo_info "软件源刷新完成"

echo ""
echo "============ 【第四阶段：安全补丁列表】 ============"
SEC_PKGS=$(apt list --upgradable 2>/dev/null | grep "bookworm-security" | cut -d/ -f1 | sort -u)
if [ -z "$SEC_PKGS" ]; then
    echo_info "✅ 没有安全补丁需要安装"
else
    echo_info "待更新安全包："
    echo "$SEC_PKGS"
    PKG_COUNT=$(echo "$SEC_PKGS" | wc -l)
    echo ""
    echo_info "共 ${PKG_COUNT} 个包"
    read -p "⚠️  输入 y 开始安装，其他键取消：" CONFIRM
    if [ "$CONFIRM" != "y" ]; then
        echo_info "已取消"
        exit 0
    fi
    echo ""
    echo "============ 【第五阶段：安装安全补丁】 ============"
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

echo ""
echo "=========================================================="
echo "  最终状态"
echo "=========================================================="
free -h
echo ""
if [ -f /var/run/reboot-required ]; then
    echo_warn "🔴 系统需要重启！低峰期执行 reboot"
    cat /var/run/reboot-required.pkgs 2>/dev/null
else
    echo_info "🟢 无需重启"
fi
echo ""
echo_info "✅ 全部完成"
