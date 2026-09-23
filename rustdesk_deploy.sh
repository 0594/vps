#!/bin/bash
# ============================================================
# RustDesk Server 一键部署脚本
# 适用: Debian 12 Bookworm / 1核1G VPS
# 版本: RustDesk Server 1.1.16 (hbbs + hbbr)
# 用法: wget -O rustdesk_deploy.sh <url> && bash rustdesk_deploy.sh
# ============================================================

RD_VERSION="1.1.16"
WORK_DIR="/opt/rustdesk"
IP_API="icanhazip.com"

info()  { echo -e "\033[1;34m[INFO]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()   { echo -e "\033[1;31m[ERROR]\033[0m $*"; }

# 检查root
[ "$(id -u)" -ne 0 ] && { err "必须用root运行"; exit 1; }

# 获取公网IP（纯文本接口，不返回HTML）
get_public_ip() {
    wget -qO- --timeout=5 "${IP_API}" 2>/dev/null \
        || wget -qO- --timeout=5 "api.ipify.org" 2>/dev/null \
        || echo ""
}

# ============================================================
# 第一部分：安装（首次运行自动执行）
# ============================================================
if [ ! -f "${WORK_DIR}/hbbs" ]; then
    echo ""
    echo "============================================"
    echo "  RustDesk Server ${RD_VERSION} 安装"
    echo "============================================"
    echo ""

    info "安装依赖 (wget, unzip, ufw, sqlite3)..."
    apt-get update -qq
    apt-get install -y -qq wget unzip ufw sqlite3 > /dev/null 2>&1

    info "创建工作目录 ${WORK_DIR}..."
    mkdir -p ${WORK_DIR}

    # 检测架构
    ARCH=$(uname -m)
    case ${ARCH} in
        x86_64)  BIN_ARCH="amd64" ;;
        aarch64) BIN_ARCH="arm64v8" ;;
        *)       err "不支持的架构: ${ARCH}"; exit 1 ;;
    esac

    BIN_URL="https://github.com/rustdesk/rustdesk-server/releases/download/${RD_VERSION}/rustdesk-server-linux-${BIN_ARCH}.zip"

    info "下载 RustDesk Server (${BIN_ARCH})..."
    cd /tmp
    wget -q --show-progress -O rustdesk-server.zip "${BIN_URL}"
    unzip -o rustdesk-server.zip -d /tmp/rustdesk-src > /dev/null

    HBBS_PATH=$(find /tmp/rustdesk-src -name hbbs -type f | head -1)
    HBBR_PATH=$(find /tmp/rustdesk-src -name hbbr -type f | head -1)
    cp "${HBBS_PATH}" ${WORK_DIR}/hbbs
    cp "${HBBR_PATH}" ${WORK_DIR}/hbbr
    chmod +x ${WORK_DIR}/hbbs ${WORK_DIR}/hbbr
    rm -rf /tmp/rustdesk-server.zip /tmp/rustdesk-src

    # 获取公网IP
    info "获取公网IP..."
    PUBLIC_IP=$(get_public_ip)
    if [ -n "${PUBLIC_IP}" ]; then
        RELAY_ARG="-r ${PUBLIC_IP}:21117"
        ok "公网IP: ${PUBLIC_IP}"
    else
        RELAY_ARG=""
        warn "无法自动获取公网IP，中继地址留空"
    fi

    # 创建systemd服务
    info "创建systemd服务..."
    cat > /etc/systemd/system/rustdesk-hbbs.service << EOF
[Unit]
Description=RustDesk hbbs (ID/Rendezvous Server)
After=network.target

[Service]
Type=simple
WorkingDirectory=${WORK_DIR}
ExecStart=${WORK_DIR}/hbbs ${RELAY_ARG}
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    cat > /etc/systemd/system/rustdesk-hbbr.service << EOF
[Unit]
Description=RustDesk hbbr (Relay Server)
After=network.target

[Service]
Type=simple
WorkingDirectory=${WORK_DIR}
ExecStart=${WORK_DIR}/hbbr
Restart=always
RestartSec=5
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable --now rustdesk-hbbs rustdesk-hbbr

    # 轮询等待密钥生成（最多10秒）
    info "等待hbbs生成密钥..."
    KEY_WAIT=0
    while [ ! -f "${WORK_DIR}/id_ed25519.pub" ] && [ ${KEY_WAIT} -lt 10 ]; do
        sleep 1
        KEY_WAIT=$((KEY_WAIT + 1))
    done

    # 防火墙放行
    info "配置防火墙端口..."
    ufw allow 21115/tcp comment 'RustDesk NAT' > /dev/null 2>&1 || true
    ufw allow 21116/tcp comment 'RustDesk ID' > /dev/null 2>&1 || true
    ufw allow 21116/udp comment 'RustDesk UDP' > /dev/null 2>&1 || true
    ufw allow 21117/tcp comment 'RustDesk Relay' > /dev/null 2>&1 || true

    if [ -f "${WORK_DIR}/id_ed25519.pub" ]; then
        PUBKEY=$(tr -d '\n' < ${WORK_DIR}/id_ed25519.pub)
    else
        PUBKEY="未生成（请检查hbbs服务状态）"
    fi

    echo ""
    ok "RustDesk Server 安装完成！"
    echo ""
    echo "  公网IP:   ${PUBLIC_IP}"
    echo "  公钥Key:  ${PUBKEY}"
    echo ""
    echo "  运行 rustdesk 命令打开管理菜单"
    echo ""
fi

# ============================================================
# 第二部分：安装/更新管理命令 rustdesk
# ============================================================
RD_CMD="/usr/local/bin/rustdesk"

cat > ${RD_CMD} << 'MENUEOF'
#!/bin/bash
# RustDesk 管理菜单
WORK_DIR="/opt/rustdesk"
IP_API="icanhazip.com"

info()  { echo -e "\033[1;34m[INFO]\033[0m $*"; }
ok()    { echo -e "\033[1;32m[OK]\033[0m $*"; }
warn()  { echo -e "\033[1;33m[WARN]\033[0m $*"; }
err()   { echo -e "\033[1;31m[ERROR]\033[0m $*"; }

get_pubkey() {
    tr -d '\n' < ${WORK_DIR}/id_ed25519.pub 2>/dev/null
}

get_ip() {
    wget -qO- --timeout=5 "${IP_API}" 2>/dev/null \
        || wget -qO- --timeout=5 "api.ipify.org" 2>/dev/null \
        || echo "获取失败"
}

# 自动探测db文件
find_db() {
    for f in "${WORK_DIR}/db_v2.sqlite3" "${WORK_DIR}/db.sqlite3" "${WORK_DIR}/db_v2" "${WORK_DIR}/db"; do
        if [ -f "$f" ]; then
            echo "$f"
            return
        fi
    done
    echo ""
}

show_menu() {
    clear
    echo "==================== RustDesk 自建服务管理 ===================="
    echo "工作目录：${WORK_DIR}"
    echo "公钥路径：${WORK_DIR}/id_ed25519.pub"
    echo ""
    echo "1.  查看服务状态"
    echo "2.  注册设备列表（含离线）"
    echo "3.  活跃远程连接"
    echo "4.  生成客户端一键导入串（含公钥）"
    echo "5.  客户端下载地址"
    echo "6.  启动服务"
    echo "7.  停止服务"
    echo "8.  重启服务"
    echo "9.  端口连通测试"
    echo "10. 查看监听端口"
    echo "11. 获取服务器公网IP"
    echo "12. 实时日志"
    echo "13. 卸载RustDesk（完全清理）"
    echo "0.  退出"
    echo "==============================================================="
    read -p "请输入选项：" CHOICE
}

pause() {
    echo ""
    read -p "按回车返回菜单..."
}

# 获取服务摘要信息
svc_summary() {
    local svc=$1
    local status=$(systemctl is-active ${svc} 2>/dev/null || echo "未安装")
    local pid=$(systemctl show ${svc} -p MainPID --value 2>/dev/null || echo "-")
    local uptime=$(systemctl show ${svc} -p ActiveEnterTimestamp --value 2>/dev/null || echo "-")
    local mem=$(systemctl show ${svc} -p MemoryCurrent --value 2>/dev/null || echo "-")
    [ "${mem}" = "not-found" ] && mem="-"
    [ "${pid}" = "0" ] && pid="-"
    printf "  状态: %-10s PID: %-8s 内存: %-8s 启动: %s\n" "${status}" "${pid}" "${mem}" "${uptime}"
}

action_status() {
    echo ""
    echo "==== 服务状态摘要 ===="
    echo ""
    echo "--- hbbs (ID/信标服务器) ---"
    svc_summary "rustdesk-hbbs"
    echo ""
    echo "--- hbbr (中继服务器) ---"
    svc_summary "rustdesk-hbbr"
    echo ""
    echo "提示：按回车展开最近20条事件日志（自动过滤启动杂项）"
    read -r
    echo ""
    echo "--- hbbs 最近日志 ---"
    journalctl -u rustdesk-hbbs -n 20 --no-pager 2>/dev/null \
        | grep -iE "update_pk|peer|register|login" \
        | sed 's/::ffff://g' \
        | sed 's/^.*hbbs\[[0-9]*\]://' \
        | tail -10 || echo "（无日志）"
    echo ""
    echo "--- hbbr 最近日志 ---"
    journalctl -u rustdesk-hbbr -n 20 --no-pager 2>/dev/null \
        | grep -iE "relay conn|session|connect|close" \
        | grep -vE "Listening|blacklist|blocklist|DOWNGRADE|LIMIT_SPEED|BANDWIDTH" \
        | sed 's/::ffff://g' \
        | sed 's/^.*hbbr\[[0-9]*\]://' \
        | tail -10 || echo "（无日志）"
    pause
}

action_devices() {
    echo ""
    echo "==== 全部注册设备（SQLite读取，含离线） ===="
    echo "设备ID           公网IP                状态"
    echo "---------------------------------------------------------"

    DB_FILE=$(find_db)
    if [ -z "${DB_FILE}" ]; then
        warn "未找到数据库文件，回退到日志模式"
        journalctl -u rustdesk-hbbs --no-pager --since "24 hours ago" 2>/dev/null \
            | grep 'update_pk' \
            | awk '{id=$10; ip=$11; gsub(/\[::ffff:/,"",ip); gsub(/\]:.*/,"",ip); print id"  "ip}' \
            | sort -u || echo "（无数据）"
    elif ! command -v sqlite3 > /dev/null 2>&1; then
        warn "sqlite3未安装，回退到日志模式"
        journalctl -u rustdesk-hbbs --no-pager --since "24 hours ago" 2>/dev/null \
            | grep 'update_pk' \
            | awk '{id=$10; ip=$11; gsub(/\[::ffff:/,"",ip); gsub(/\]:.*/,"",ip); print id"  "ip}' \
            | sort -u || echo "（无数据）"
    else
        SQL_RESULT=$(sqlite3 "${DB_FILE}" "SELECT id, info, status FROM peer ORDER BY status DESC;" 2>/dev/null || echo "")
        if [ -z "${SQL_RESULT}" ]; then
            SQL_TABLES=$(sqlite3 "${DB_FILE}" ".tables" 2>/dev/null)
            warn "peer表查询失败，数据库表：${SQL_TABLES}"
            echo "回退到日志模式："
            journalctl -u rustdesk-hbbs --no-pager --since "24 hours ago" 2>/dev/null \
                | grep 'update_pk' \
                | awk '{id=$10; ip=$11; gsub(/\[::ffff:/,"",ip); gsub(/\]:.*/,"",ip); print id"  "ip}' \
                | sort -u || echo "（无数据）"
        else
            echo "${SQL_RESULT}" | while IFS='|' read -r id info status; do
                ip=$(echo "${info}" | grep -oP '"ip":"[^"]*"' | head -1 | cut -d'"' -f4)
                ip=$(echo "${ip}" | sed 's/^::ffff://')
                [ -z "${ip}" ] && ip="未知"
                [ "${status}" = "1" ] && st="在线" || st="离线"
                printf "%-15s %-20s %s\n" "${id}" "${ip}" "${st}"
            done
        fi
    fi
    echo "---------------------------------------------------------"
    pause
}

action_active() {
    echo ""
    echo "==== 当前活跃中继会话 ===="
    echo "说明：远程窗口右上角 Direct=P2P直连(不走服务器) / Relay=中继(走服务器)"
    echo ""
    echo "提示：按回车展开最近10分钟中继连接日志"
    read -r
    echo ""
    journalctl -u rustdesk-hbbr --since "10 minutes ago" --no-pager 2>/dev/null \
        | grep -i 'relay conn' \
        | sed 's/::ffff://g' \
        | sed 's/^.*hbbr\[[0-9]*\]://' \
        | tail -10 || echo "（无活跃中继会话）"
    pause
}

action_import() {
    echo ""
    PUBKEY=$(get_pubkey)
    IP=$(get_ip)
    if [ -z "${PUBKEY}" ]; then
        err "公钥文件不存在，请先启动hbbs服务"
        pause
        return
    fi
    JSON="{\"host\":\"${IP}\",\"relay\":\"${IP}:21117\",\"api\":\"\",\"key\":\"${PUBKEY}\"}"
    B64=$(echo -n "${JSON}" | base64 -w0 | tr '+/' '-_' | tr -d '=')
    IMPORT_STR=$(echo -n "${B64}" | rev)
    echo "--------------------------"
    echo "ID服务器:   ${IP}"
    echo "中继服务器: ${IP}:21117"
    echo "公钥Key:    ${PUBKEY}"
    echo ""
    echo "客户端一键导入字符串（全选复制）："
    echo ""
    echo "${IMPORT_STR}"
    echo ""
    echo "使用方法："
    echo "1. 打开RustDesk客户端 → 设置 → 网络 → ID/中继服务器"
    echo "2. 点右上角【导入服务器配置】"
    echo "3. 粘贴上面整串，自动填充IP+Key"
    echo "--------------------------"
    pause
}

action_download() {
    echo ""
    echo "--------------------------"
    echo "RustDesk 最新版 1.4.9 客户端下载："
    echo ""
    echo "Windows (64位 EXE):"
    echo "  https://github.com/rustdesk/rustdesk/releases/download/1.4.9/rustdesk-1.4.9-x86_64.exe"
    echo ""
    echo "Windows (64位 MSI):"
    echo "  https://github.com/rustdesk/rustdesk/releases/download/1.4.9/rustdesk-1.4.9-x86_64.msi"
    echo ""
    echo "macOS (Intel):"
    echo "  https://github.com/rustdesk/rustdesk/releases/download/1.4.9/rustdesk-1.4.9-x86_64.dmg"
    echo ""
    echo "macOS (Apple Silicon):"
    echo "  https://github.com/rustdesk/rustdesk/releases/download/1.4.9/rustdesk-1.4.9-aarch64.dmg"
    echo ""
    echo "Linux (Debian/Ubuntu):"
    echo "  https://github.com/rustdesk/rustdesk/releases/download/1.4.9/rustdesk-1.4.9-x86_64.deb"
    echo ""
    echo "Android (通用):"
    echo "  https://github.com/rustdesk/rustdesk/releases/download/1.4.9/rustdesk-1.4.9-universal-signed.apk"
    echo ""
    echo "iOS: App Store 搜索 RustDesk"
    echo ""
    echo "完整下载页:"
    echo "  https://github.com/rustdesk/rustdesk/releases/latest"
    echo "--------------------------"
    pause
}

action_start() {
    echo ""
    systemctl start rustdesk-hbbs rustdesk-hbbr
    ok "服务启动命令已发送"
    sleep 1
    systemctl is-active rustdesk-hbbs > /dev/null && ok "hbbs 运行中" || err "hbbs 未运行"
    systemctl is-active rustdesk-hbbr > /dev/null && ok "hbbr 运行中" || err "hbbr 未运行"
    pause
}

action_stop() {
    echo ""
    systemctl stop rustdesk-hbbs rustdesk-hbbr
    ok "服务已停止"
    pause
}

action_restart() {
    echo ""
    systemctl restart rustdesk-hbbs rustdesk-hbbr
    ok "服务重启命令已发送"
    sleep 1
    systemctl is-active rustdesk-hbbs > /dev/null && ok "hbbs 运行中" || err "hbbs 未运行"
    systemctl is-active rustdesk-hbbr > /dev/null && ok "hbbr 运行中" || err "hbbr 未运行"
    pause
}

action_test() {
    echo ""
    echo "==== 本地端口连通性测试 ===="
    ss -tln | grep -q ":21115 " && ok "21115/tcp 监听中" || err "21115/tcp 未监听"
    ss -tln | grep -q ":21116 " && ok "21116/tcp 监听中" || err "21116/tcp 未监听"
    ss -uln | grep -q ":21116 " && ok "21116/udp 监听中" || err "21116/udp 未监听"
    ss -tln | grep -q ":21117 " && ok "21117/tcp 监听中" || err "21117/tcp 未监听"
    pause
}

action_ports() {
    echo ""
    echo "==== 监听端口 ===="
    ss -tulnp | grep -E "hbbs|hbbr" || warn "未找到hbbs/hbbr进程"
    echo ""
    echo "预期端口："
    echo "  21115/tcp - NAT类型测试"
    echo "  21116/tcp - ID注册/心跳"
    echo "  21116/udp - UDP打洞"
    echo "  21117/tcp - 中继"
    pause
}

action_ip() {
    echo ""
    IP=$(get_ip)
    echo "服务器公网IP：${IP}"
    pause
}

action_logs() {
    echo ""
    echo "==== 实时日志（按 Ctrl+C 退出） ===="
    echo "提示：IP已自动清理::ffff:前缀"
    echo ""
    journalctl -u rustdesk-hbbs -u rustdesk-hbbr -f 2>/dev/null | sed 's/::ffff://g'
    echo ""
    pause
}

action_uninstall() {
    echo ""
    warn "即将完全卸载RustDesk Server！"
    echo "将删除：服务 → systemd文件 → 程序目录 → 防火墙端口 → 本菜单命令"
    read -p "确认卸载？输入 yes 继续：" CONFIRM
    if [ "${CONFIRM}" = "yes" ]; then
        echo ""
        info "停止并禁用服务..."
        systemctl stop rustdesk-hbbs rustdesk-hbbr 2>/dev/null || true
        systemctl disable rustdesk-hbbs rustdesk-hbbr 2>/dev/null || true
        info "删除systemd服务文件..."
        rm -f /etc/systemd/system/rustdesk-hbbs.service
        rm -f /etc/systemd/system/rustdesk-hbbr.service
        systemctl daemon-reload
        info "删除防火墙规则..."
        ufw delete allow 21115/tcp 2>/dev/null || true
        ufw delete allow 21116/tcp 2>/dev/null || true
        ufw delete allow 21116/udp 2>/dev/null || true
        ufw delete allow 21117/tcp 2>/dev/null || true
        info "删除程序目录 ${WORK_DIR}..."
        rm -rf ${WORK_DIR}
        info "删除管理命令 /usr/local/bin/rustdesk..."
        rm -f /usr/local/bin/rustdesk
        info "清理临时文件..."
        rm -rf /tmp/rustdesk* 2>/dev/null || true
        echo ""
        ok "RustDesk已完全卸载，所有文件已清理"
        echo "如需重新安装，运行："
        echo "  wget -O /root/rustdesk_deploy.sh https://raw.githubusercontent.com/0594/vps/main/rustdesk_deploy.sh && chmod +x /root/rustdesk_deploy.sh && bash /root/rustdesk_deploy.sh"
        exit 0
    else
        info "已取消"
    fi
    pause
}

# 主循环
while true; do
    show_menu
    case ${CHOICE} in
        1) action_status ;;
        2) action_devices ;;
        3) action_active ;;
        4) action_import ;;
        5) action_download ;;
        6) action_start ;;
        7) action_stop ;;
        8) action_restart ;;
        9) action_test ;;
        10) action_ports ;;
        11) action_ip ;;
        12) action_logs ;;
        13) action_uninstall ;;
        0) echo "退出"; exit 0 ;;
        *) warn "无效选项" ;;
    esac
done
MENUEOF

chmod +x ${RD_CMD}
ok "管理命令 rustdesk 已安装"
echo ""
echo "运行 rustdesk 打开管理菜单"
echo ""
