# vps

1核1G 小内存 VPS 一键初始化脚本（Debian Bookworm）。

## 一键初始化

重装系统后，root 登录执行：

```bash
wget -O /root/vps_init.sh https://raw.githubusercontent.com/0594/vps/main/vps_init.sh && chmod +x /root/vps_init.sh && bash /root/vps_init.sh
```

脚本全自动执行，无需交互，完成后 10 秒自动重启。

## 初始化内容

| 模块 | 说明 |
|---|---|
| 系统优化 | 关闭 cloud-init、journal 日志改为内存模式（16M 上限） |
| 内核加固 | 防 SYN flood、防 IP 欺骗、忽略 ICMP 广播、禁源路由 |
| UFW 防火墙 | 默认拒绝入站，放行 22/80/443 |
| fail2ban | SSH 失败 3 次自动封 IP 1 小时 |
| SSH 加固 | 密钥登录、密码关闭、MaxAuthTries=3、空闲超时断开 |
| 自动更新 | 每月 1 号凌晨 3 点自动安装安全补丁，需要重启则自动 reboot |

## 常用命令

初始化完成后，系统自带两个全局命令：

### `vfw` — 防火墙端口管理

交互式菜单：

```bash
vfw
```

- 1) 开放端口
- 2) 删除端口
- 3) 查看端口列表

### `vupdate` — 安全补丁更新

```bash
vupdate          # 手动模式，列出补丁后确认安装
vupdate --auto   # 全自动模式（cron 每月自动调用）
```

自动更新日志：`/var/log/vupdate.log`

## 仓库结构

```
vps/
├── vps_init.sh   # 一键初始化脚本
└── README.md
```
