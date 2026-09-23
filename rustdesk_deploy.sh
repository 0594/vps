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

    info "安装依赖 (wget, unzip, ufw, sqlite3, jq)..."
    apt-get update -qq
    apt-get install -y -qq wget unzip ufw sqlite3 jq > /dev/null 2>&1

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

    # 生成一键导入串
    if [ -n "${PUBLIC_IP}" ] && [ -n "${PUBKEY}" ] && [ "${PUBKEY}" != "未生成（请检查hbbs服务状态）" ]; then
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
        echo "  使用方法：打开RustDesk客户端 → 设置 → 网络 → 点【导入服务器配置】粘贴"
    else
        echo "  导入串生成失败，运行 rustdesk → 选项6 重新生成"
    fi
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

# 从hbbs日志提取设备心跳信息
# 输出格式：设备ID TAB 最后心跳时间(CST)
# 不依赖journalctl的--since时间过滤，脚本内部解析日志时间
get_heartbeat_info() {
    journalctl -u rustdesk-hbbs --since "10 minutes ago" --no-pager 2>/dev/null \
        | grep 'update_pk' \
        | awk '
        BEGIN {
            # 月份缩写转数字
            m["Jan"]=1; m["Feb"]=2; m["Mar"]=3; m["Apr"]=4; m["May"]=5; m["Jun"]=6;
            m["Jul"]=7; m["Aug"]=8; m["Sep"]=9; m["Oct"]=10; m["Nov"]=11; m["Dec"]=12;
        }
        {
            # 日志格式：Sep 24 05:04:59 hostname hbbs[1234]: update_pk 1679009027 ...
            mon = m[$1];
            day = $2;
            split($3, t, ":");
            hour = t[1]; min = t[2]; sec = t[3];

            # 找update_pk位置
            devid = "";
            for(i=1;i<=NF;i++) {
                if($i=="update_pk") {
                    devid = $(i+1);
                    break;
                }
            }

            if(devid != "" && devid ~ /^[0-9]+$/) {
                # 构造时间戳（本年，因为journal不显示年份）
                # 用mktime: YYYY MM DD HH MM SS
                now_year = strftime("%Y");
                ts = mktime(now_year " " mon " " day " " hour " " min " " sec);

                # 只保留每个设备最新的心跳
                if(!(devid in last_ts) || ts > last_ts[devid]) {
                    last_ts[devid] = ts;
                    last_str[devid] = strftime("%Y-%m-%d %H:%M:%S", ts + 8*3600);  # 转CST
                }
            }
        }
        END {
            for(id in last_ts) {
                print id "\t" last_str[id];
            }
        }'
}

show_menu() {
    clear
    echo "==================== RustDesk 自建服务管理 ===================="
    echo "工作目录：${WORK_DIR}"
    echo "公钥路径：${WORK_DIR}/id_ed25519.pub"
    echo ""
    echo "1.  查看服务状态"
    echo "2.  注册设备列表（含在线状态）"
    echo "3.  修改设备备注"
    echo "4.  探测在线设备"
    echo "5.  活跃远程连接"
    echo "6.  生成客户端一键导入串（含公钥）"
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
    echo "==== 注册设备列表（读取SQLite数据库） ===="
    printf "%-15s %-8s %-20s %-20s %-15s %s\n" "设备ID" "状态" "注册时间(CST)" "最后心跳(CST)" "备注" "公网IP"
    echo "-------------------------------------------------------------------------------------------------------------"

    if [ ! -f "${DB_FILE}" ]; then
        echo "（数据库文件不存在，hbbs尚未创建数据库）"
        pause
        return
    fi

    local count=$(sqlite3 "${DB_FILE}" "SELECT count(*) FROM peer;" 2>/dev/null)
    if [ "${count}" = "0" ]; then
        echo "（暂无注册设备）"
    else
        # 获取心跳信息：设备ID TAB 最后心跳时间
        local heartbeat=$(get_heartbeat_info)
        # 2分钟阈值（秒）
        local threshold=120
        local now_epoch=$(date +%s)

        sqlite3 -json "${DB_FILE}" "SELECT id, created_at, note, info FROM peer;" 2>/dev/null \
        | jq -r '.[] | [
            .id,
            (.created_at | strptime("%Y-%m-%d %H:%M:%S") | mktime | . + (8*3600) | strftime("%Y-%m-%d %H:%M:%S")),
            (.note // "-"),
            (.info | fromjson).ip // "-"
        ] | @tsv' \
        | sed 's/::ffff://' \
        | while IFS=$'\t' read -r devid cst_time note ip; do
            # 从心跳信息中查找该设备
            local hb_time=$(echo "${heartbeat}" | grep "^${devid}" | cut -f2)
            local status="离线"
            local hb_display="-"
            if [ -n "${hb_time}" ]; then
                hb_display="${hb_time}"
                # 计算心跳时间和当前时间的差值
                local hb_epoch=$(date -d "${hb_time}" +%s 2>/dev/null || echo 0)
                local diff=$((now_epoch - hb_epoch))
                if [ ${diff} -le ${threshold} ]; then
                    status="在线"
                fi
            fi
            printf "%-15s %-8s %-20s %-20s %-15s %s\n" "$devid" "$status" "$cst_time" "$hb_display" "$note" "$ip"
        done
    fi

    echo "-------------------------------------------------------------------------------------------------------------"
    echo "提示：在线=2分钟内有update_pk心跳；备注可在选项3修改"
    pause
}

action_note() {
    echo ""
    echo "==== 修改设备备注 ===="

    if [ ! -f "${DB_FILE}" ]; then
        err "数据库文件不存在"
        pause
        return
    fi

    echo "当前设备列表："
    echo "-------------------------------------------------------------------------"
    printf "%-15s %-15s %s\n" "设备ID" "当前备注" "公网IP"
    echo "-------------------------------------------------------------------------"
    sqlite3 -json "${DB_FILE}" "SELECT id, note, info FROM peer;" 2>/dev/null \
        | jq -r '.[] | [.id, (.note // "-"), (.info | fromjson).ip // "-"] | @tsv' \
        | sed 's/::ffff://' \
        | while IFS=$'\t' read -r devid note ip; do
            printf "%-15s %-15s %s\n" "$devid" "$note" "$ip"
        done
    echo "-------------------------------------------------------------------------"

    echo ""
    read -p "输入要修改的设备ID：" TARGET_ID
    if [ -z "${TARGET_ID}" ]; then
        warn "设备ID不能为空"
        pause
        return
    fi

    local exist=$(sqlite3 "${DB_FILE}" "SELECT count(*) FROM peer WHERE id='${TARGET_ID}';" 2>/dev/null)
    if [ "${exist}" = "0" ]; then
        err "设备ID ${TARGET_ID} 不存在"
        pause
        return
    fi

    local old_note=$(sqlite3 "${DB_FILE}" "SELECT note FROM peer WHERE id='${TARGET_ID}';" 2>/dev/null)
    [ -z "${old_note}" ] && old_note="（空）"
    echo "当前备注：${old_note}"
    echo "直接输入新备注（留空回车=清空备注）"
    read -p "新备注：" NEW_NOTE

    if [ -z "${NEW_NOTE}" ]; then
        sqlite3 "${DB_FILE}" "UPDATE peer SET note = NULL WHERE id='${TARGET_ID}';"
        ok "已清空设备 ${TARGET_ID} 的备注"
    else
        NEW_NOTE_ESC=$(echo "${NEW_NOTE}" | sed "s/'/''/g")
        sqlite3 "${DB_FILE}" "UPDATE peer SET note = '${NEW_NOTE_ESC}' WHERE id='${TARGET_ID}';"
        ok "设备 ${TARGET_ID} 备注已更新为：${NEW_NOTE}"
    fi
    pause
}

action_online_probe() {
    echo ""
    echo "==== 探测在线设备（日志update_pk方案） ===="

    if ! systemctl is-active rustdesk-hbbs > /dev/null 2>&1; then
        err "hbbs服务未运行，无法探测"
        pause
        return
    fi

    if [ ! -f "${DB_FILE}" ]; then
        err "数据库文件不存在"
        pause
        return
    fi

    echo "原理：读取hbbs最近10分钟日志，提取update_pk心跳设备"
    echo "      2分钟内有心跳=在线，关联sqlite显示备注和IP"
    echo ""

    local heartbeat=$(get_heartbeat_info)
    local threshold=120
    local now_epoch=$(date +%s)
    local online_count=0

    if [ -z "${heartbeat}" ]; then
        echo "（最近10分钟无update_pk心跳记录）"
        echo ""
        echo "可能原因："
        echo "1. 所有设备离线"
        echo "2. hbbs未输出update_pk日志"
        echo ""
        echo "手动验证命令："
        echo "  journalctl -u rustdesk-hbbs | grep update_pk"
    else
        echo "==== 在线设备列表 ===="
        printf "%-15s %-20s %-15s %s\n" "设备ID" "最后心跳(CST)" "备注" "公网IP"
        echo "-------------------------------------------------------------------------"

        while IFS=$'\t' read -r devid hb_time; do
            [ -z "${devid}" ] && continue
            local hb_epoch=$(date -d "${hb_time}" +%s 2>/dev/null || echo 0)
            local diff=$((now_epoch - hb_epoch))
            if [ ${diff} -le ${threshold} ]; then
                online_count=$((online_count + 1))
                local note=$(sqlite3 "${DB_FILE}" "SELECT note FROM peer WHERE id='${devid}';" 2>/dev/null)
                local info=$(sqlite3 "${DB_FILE}" "SELECT info FROM peer WHERE id='${devid}';" 2>/dev/null)
                local ip=$(echo "${info}" | jq -r '.ip // "-"' 2>/dev/null | sed 's/::ffff://')
                [ -z "${note}" ] && note="-"
                [ -z "${ip}" ] && ip="-"
                printf "%-15s %-20s %-15s %s\n" "$devid" "$hb_time" "$note" "$ip"
            fi
        done <<< "${heartbeat}"

        echo "-------------------------------------------------------------------------"
        echo "在线设备数：${online_count}"
    fi

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
ok "管理命令 rustdesk 已安装"
echo ""
echo "运行 rustdesk 命令打开管理菜单"
echo ""
