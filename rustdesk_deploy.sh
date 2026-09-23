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

# 获取公网IP
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

    info "安装依赖 (wget, unzip, ufw, sqlite3, jq)..."
    apt-get update -qq
    apt-get install -y -qq wget unzip ufw sqlite3 jq > /dev/null 2>&1

    info "创建工作目录 ${WORK_DIR}..."
    mkdir -p ${WORK_DIR}

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

    info "获取公网IP..."
    PUBLIC_IP=$(get_public_ip)
    if [ -n "${PUBLIC_IP}" ]; then
        RELAY_ARG="-r ${PUBLIC_IP}:21117"
        ok "公网IP: ${PUBLIC_IP}"
    else
        RELAY_ARG=""
        warn "无法自动获取公网IP"
    fi

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

    info "等待hbbs生成密钥..."
    KEY_WAIT=0
    while [ ! -f "${WORK_DIR}/id_ed25519.pub" ] && [ ${KEY_WAIT} -lt 10 ]; do
        sleep 1
        KEY_WAIT=$((KEY_WAIT + 1))
    done

    info "配置防火墙端口..."
    ufw allow 21115/tcp comment 'RustDesk NAT' > /dev/null 2>&1 || true
    ufw allow 21116/tcp comment 'RustDesk ID' > /dev/null 2>&1 || true
    ufw allow 21116/udp comment 'RustDesk UDP' > /dev/null 2>&1 || true
    ufw allow 21117/tcp comment 'RustDesk Relay' > /dev/null 2>&1 || true

    if [ -f "${WORK_DIR}/id_ed25519.pub" ]; then
        PUBKEY=$(tr -d '\n' < ${WORK_DIR}/id_ed25519.pub)
    else
        PUBKEY="未生成"
    fi

    if [ -n "${PUBLIC_IP}" ] && [ -n "${PUBKEY}" ] && [ "${PUBKEY}" != "未生成" ]; then
        JSON_STR="{\"host\":\"${PUBLIC_IP}\",\"relay\":\"${PUBLIC_IP}:21117\",\"api\":\"\",\"key\":\"${PUBKEY}\"}"
        B64_STR=$(echo -n "${JSON_STR}" | base64 -w0 | tr '+/' '-_' | tr -d '=')
        IMPORT_STR=$(echo -n "${B64_STR}" | rev)
    else
        IMPORT_STR=""
    fi

    echo ""
    ok "RustDesk Server 安装完成！"
    echo ""
    echo "  公网IP:   ${PUBLIC_IP}"
    echo "  公钥Key:  ${PUBKEY}"
    echo ""
    if [ -n "${IMPORT_STR}" ]; then
        echo "  客户端一键导入串（全选复制）："
        echo ""
        echo "  ${IMPORT_STR}"
        echo ""
    fi
    echo "  运行 rustdesk 命令打开管理菜单"
    echo ""
fi

# ============================================================
# 第二部分：安装/更新管理命令 rustdesk
# ============================================================
RD_CMD="/usr/local/bin/rustdesk"

cat > ${RD_CMD} << 'MENUEOF'
#!/bin/bash
WORK_DIR="/opt/rustdesk"
IP_API="icanhazip.com"
DB_FILE="${WORK_DIR}/db_v2.sqlite3"

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

show_menu() {
    clear
    echo "==================== RustDesk 自建服务管理 ===================="
    echo "工作目录：${WORK_DIR}"
    echo ""
    echo "1.  查看服务状态"
    echo "2.  注册设备列表"
    echo "3.  修改设备备注"
    echo "4.  探测在线设备（清库重读，约10秒）"
    echo "5.  活跃远程连接"
    echo "6.  生成客户端一键导入串"
    echo "7.  客户端下载地址"
    echo "8.  启动服务"
    echo "9.  停止服务"
    echo "10. 重启服务"
    echo "11. 端口连通测试"
    echo "12. 查看监听端口"
    echo "13. 获取服务器公网IP"
    echo "14. 实时日志"
    echo "15. 卸载RustDesk（完全清理）"
    echo "0.  退出"
    echo "==============================================================="
    read -p "请输入选项：" CHOICE
}

pause() {
    echo ""
    read -p "按回车返回菜单..."
}

svc_summary() {
    local svc=$1
    local status=$(systemctl is-active ${svc} 2>/dev/null || echo "未安装")
    local pid=$(systemctl show ${svc} -p MainPID --value 2>/dev/null || echo "-")
    [ "${pid}" = "0" ] && pid="-"
    printf "  状态: %-10s PID: %s\n" "${status}" "${pid}"
}

action_status() {
    echo ""
    echo "==== 服务状态 ===="
    echo "hbbs:"; svc_summary "rustdesk-hbbs"
    echo "hbbr:"; svc_summary "rustdesk-hbbr"
    pause
}

action_devices() {
    echo ""
    echo "==== 注册设备列表 ===="
    if [ ! -f "${DB_FILE}" ]; then
        echo "（数据库不存在）"
        pause; return
    fi
    local count=$(sqlite3 "${DB_FILE}" "SELECT count(*) FROM peer;" 2>/dev/null)
    if [ "${count}" = "0" ]; then
        echo "（暂无注册设备）"
    else
        printf "%-15s %-20s %-15s %s\n" "设备ID" "注册时间(CST)" "备注" "公网IP"
        echo "---------------------------------------------------------------"
        sqlite3 -json "${DB_FILE}" "SELECT id, created_at, note, info FROM peer;" 2>/dev/null \
        | jq -r '.[] | [
            .id,
            (.created_at | strptime("%Y-%m-%d %H:%M:%S") | mktime | . + (8*3600) | strftime("%Y-%m-%d %H:%M:%S")),
            (.note // "-"),
            (.info | fromjson).ip // "-"
        ] | @tsv' \
        | sed 's/::ffff://' \
        | while IFS=$'\t' read -r devid cst_time note ip; do
            printf "%-15s %-20s %-15s %s\n" "$devid" "$cst_time" "$note" "$ip"
        done
    fi
    echo "---------------------------------------------------------------"
    pause
}

action_note() {
    echo ""
    echo "==== 修改设备备注 ===="
    if [ ! -f "${DB_FILE}" ]; then err "数据库不存在"; pause; return; fi

    echo "当前设备："
    sqlite3 -json "${DB_FILE}" "SELECT id, note, info FROM peer;" 2>/dev/null \
        | jq -r '.[] | [.id, (.note // "-"), (.info | fromjson).ip // "-"] | @tsv' \
        | sed 's/::ffff://' \
        | while IFS=$'\t' read -r devid note ip; do
            echo "  ${devid}  备注:${note}  IP:${ip}"
        done

    echo ""
    read -p "输入设备ID：" TARGET_ID
    [ -z "${TARGET_ID}" ] && { warn "取消"; pause; return; }

    local exist=$(sqlite3 "${DB_FILE}" "SELECT count(*) FROM peer WHERE id='${TARGET_ID}';" 2>/dev/null)
    if [ "${exist}" = "0" ]; then err "设备 ${TARGET_ID} 不存在"; pause; return; fi

    read -p "新备注（留空=清空）：" NEW_NOTE
    if [ -z "${NEW_NOTE}" ]; then
        sqlite3 "${DB_FILE}" "UPDATE peer SET note = NULL WHERE id='${TARGET_ID}';"
        ok "已清空备注"
    else
        NEW_NOTE_ESC=$(echo "${NEW_NOTE}" | sed "s/'/''/g")
        sqlite3 "${DB_FILE}" "UPDATE peer SET note = '${NEW_NOTE_ESC}' WHERE id='${TARGET_ID}';"
        ok "备注已更新"
    fi
    pause
}

action_online_probe() {
    echo ""
    echo "==== 探测在线设备 ===="
    if [ ! -f "${DB_FILE}" ]; then err "数据库不存在"; pause; return; fi

    warn "原理：清空peer表 → 等10秒 → 在线设备会自动重新注册 → 读库"
    warn "注意：查询期间所有设备会短暂断开重连，约10秒恢复"
    echo ""
    read -p "确认继续？输入 y：" CONFIRM
    [ "${CONFIRM}" != "y" ] && { info "已取消"; pause; return; }

    echo ""
    info "清空peer表..."
    sqlite3 "${DB_FILE}" "DELETE FROM peer;"

    info "等待10秒，在线设备重新注册..."
    for i in 10 9 8 7 6 5 4 3 2 1; do
        printf "\r  倒计时 %d 秒..." ${i}
        sleep 1
    done
    echo ""

    local count=$(sqlite3 "${DB_FILE}" "SELECT count(*) FROM peer;" 2>/dev/null)
    echo ""
    if [ "${count}" = "0" ]; then
        echo "（10秒内无设备重新注册，可能全部离线）"
    else
        echo "==== 在线设备列表 ===="
        printf "%-15s %-20s %-15s %s\n" "设备ID" "注册时间(CST)" "备注" "公网IP"
        echo "---------------------------------------------------------------"
        sqlite3 -json "${DB_FILE}" "SELECT id, created_at, note, info FROM peer;" 2>/dev/null \
        | jq -r '.[] | [
            .id,
            (.created_at | strptime("%Y-%m-%d %H:%M:%S") | mktime | . + (8*3600) | strftime("%Y-%m-%d %H:%M:%S")),
            (.note // "-"),
            (.info | fromjson).ip // "-"
        ] | @tsv' \
        | sed 's/::ffff://' \
        | while IFS=$'\t' read -r devid cst_time note ip; do
            printf "%-15s %-20s %-15s %s\n" "$devid" "$cst_time" "$note" "$ip"
        done
        echo "---------------------------------------------------------------"
        echo "在线设备数：${count}"
    fi
    pause
}

action_active() {
    echo ""
    echo "==== 最近中继连接（10分钟内） ===="
    journalctl -u rustdesk-hbbr --since "10 minutes ago" --no-pager 2>/dev/null \
        | grep -i 'relay conn' \
        | sed 's/::ffff://g' \
        | sed 's/^.*hbbr\[[0-9]*\]://' \
        | tail -10 || echo "（无）"
    pause
}

action_import() {
    echo ""
    PUBKEY=$(get_pubkey)
    IP=$(get_ip)
    if [ -z "${PUBKEY}" ]; then err "公钥不存在"; pause; return; fi
    JSON="{\"host\":\"${IP}\",\"relay\":\"${IP}:21117\",\"api\":\"\",\"key\":\"${PUBKEY}\"}"
    B64=$(echo -n "${JSON}" | base64 -w0 | tr '+/' '-_' | tr -d '=')
    IMPORT_STR=$(echo -n "${B64}" | rev)
    echo "ID服务器:   ${IP}"
    echo "中继服务器: ${IP}:21117"
    echo "Key:        ${PUBKEY}"
    echo ""
    echo "一键导入串："
    echo "${IMPORT_STR}"
    pause
}

action_download() {
    echo ""
    echo "RustDesk 1.4.9 客户端下载："
    echo "  Windows:  https://github.com/rustdesk/rustdesk/releases/download/1.4.9/rustdesk-1.4.9-x86_64.exe"
    echo "  macOS:    https://github.com/rustdesk/rustdesk/releases/download/1.4.9/rustdesk-1.4.9-x86_64.dmg"
    echo "  Linux:    https://github.com/rustdesk/rustdesk/releases/download/1.4.9/rustdesk-1.4.9-x86_64.deb"
    echo "  Android:  https://github.com/rustdesk/rustdesk/releases/download/1.4.9/rustdesk-1.4.9-universal-signed.apk"
    echo "  iOS:      App Store 搜索 RustDesk"
    echo "  全部:     https://github.com/rustdesk/rustdesk/releases/latest"
    pause
}

action_start() {
    echo ""
    systemctl start rustdesk-hbbs rustdesk-hbbr
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
    sleep 1
    systemctl is-active rustdesk-hbbs > /dev/null && ok "hbbs 运行中" || err "hbbs 未运行"
    systemctl is-active rustdesk-hbbr > /dev/null && ok "hbbr 运行中" || err "hbbr 未运行"
    pause
}

action_test() {
    echo ""
    ss -tln | grep -q ":21115 " && ok "21115/tcp" || err "21115/tcp"
    ss -tln | grep -q ":21116 " && ok "21116/tcp" || err "21116/tcp"
    ss -uln | grep -q ":21116 " && ok "21116/udp" || err "21116/udp"
    ss -tln | grep -q ":21117 " && ok "21117/tcp" || err "21117/tcp"
    pause
}

action_ports() {
    echo ""
    ss -tulnp | grep -E "hbbs|hbbr" || warn "未找到进程"
    pause
}

action_ip() {
    echo ""
    echo "公网IP：$(get_ip)"
    pause
}

action_logs() {
    echo ""
    echo "实时日志（Ctrl+C退出）"
    journalctl -u rustdesk-hbbs -u rustdesk-hbbr -f 2>/dev/null | sed 's/::ffff://g'
    pause
}

action_uninstall() {
    echo ""
    warn "将完全删除RustDesk：服务+程序+防火墙+菜单命令"
    read -p "输入 yes 确认：" CONFIRM
    if [ "${CONFIRM}" = "yes" ]; then
        systemctl stop rustdesk-hbbs rustdesk-hbbr 2>/dev/null || true
        systemctl disable rustdesk-hbbs rustdesk-hbbr 2>/dev/null || true
        rm -f /etc/systemd/system/rustdesk-hbbs.service /etc/systemd/system/rustdesk-hbbr.service
        systemctl daemon-reload
        ufw delete allow 21115/tcp 2>/dev/null || true
        ufw delete allow 21116/tcp 2>/dev/null || true
        ufw delete allow 21116/udp 2>/dev/null || true
        ufw delete allow 21117/tcp 2>/dev/null || true
        rm -rf ${WORK_DIR}
        rm -f /usr/local/bin/rustdesk
        rm -rf /tmp/rustdesk* 2>/dev/null || true
        ok "已完全卸载"
        exit 0
    else
        info "已取消"
    fi
    pause
}

while true; do
    show_menu
    case ${CHOICE} in
        1) action_status ;;
        2) action_devices ;;
        3) action_note ;;
        4) action_online_probe ;;
        5) action_active ;;
        6) action_import ;;
        7) action_download ;;
        8) action_start ;;
        9) action_stop ;;
        10) action_restart ;;
        11) action_test ;;
        12) action_ports ;;
        13) action_ip ;;
        14) action_logs ;;
        15) action_uninstall ;;
        0) echo "退出"; exit 0 ;;
        *) warn "无效选项" ;;
    esac
done
MENUEOF

chmod +x ${RD_CMD}
ok "rustdesk 命令已安装"
echo "运行 rustdesk 打开菜单"
