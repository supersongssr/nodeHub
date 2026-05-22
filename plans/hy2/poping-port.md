# hy2 动态端口 iptables UDP 映射方案

## 背景

面板端 Hysteria2 (hy2) 支持了**动态端口**（Port Hopping）功能：
- hy2 服务默认监听 **UDP 443** 端口
- 客户端可通过配置 port hopping 范围（如 `30000-32000`），在连接时随机使用该范围内的端口
- 节点侧需要将 `30000-32000/UDP` 的流量全部**映射（DNAT）到 443/UDP**，由 hy2 统一处理

这样客户端连接任意 `30000-32000` 端口的 UDP 包都会到达 hy2 服务，实现端口跳跃抗封锁。

## 方案设计

### 核心思路

使用 `iptables` **PREROUTING DNAT 规则**，在内核网络栈层面将目标端口 `30000-32000/UDP` 重写为 `443/UDP`。

```
Client → [随机端口 30000-32000/UDP] → 节点 PREROUTING DNAT → [443/UDP] → hy2 进程
```

### iptables 规则

```bash
# 将本机收到的 30000-32000/UDP 流量 DNAT 到 443/UDP
iptables -t nat -A PREROUTING -p udp --dport 30000:32000 -j REDIRECT --to-port 443

# IPv6 同理
ip6tables -t nat -A PREROUTING -p udp --dport 30000:32000 -j REDIRECT --to-port 443
```

> **为什么用 `REDIRECT` 而非 `DNAT`？**
> - `REDIRECT` 是 DNAT 的特化版本，等价于 `-j DNAT --to-destination :443`，直接将目标端口改写为本机的 443 端口
> - 无需指定目标 IP，自动使用入接口地址，更简洁
> - 性能开销极低，单条规则覆盖整个端口范围

### 持久化方案

iptables 规则重启后丢失，需要持久化：

#### 方案 A：`iptables-persistent`（推荐）

```bash
apt-get install -y iptables-persistent

# 保存当前规则
netfilter-persistent save
# 规则文件: /etc/iptables/rules.v4 和 /etc/iptables/rules.v6
```

#### 方案 B：`systemd` 服务自动加载

```bash
# 写入规则脚本
cat > /usr/local/bin/hy2-port-hop-rules.sh << 'EOF'
#!/bin/sh
iptables -t nat -C PREROUTING -p udp --dport 30000:32000 -j REDIRECT --to-port 443 2>/dev/null || \
    iptables -t nat -A PREROUTING -p udp --dport 30000:32000 -j REDIRECT --to-port 443
ip6tables -t nat -C PREROUTING -p udp --dport 30000:32000 -j REDIRECT --to-port 443 2>/dev/null || \
    ip6tables -t nat -A PREROUTING -p udp --dport 30000:32000 -j REDIRECT --to-port 443
EOF
chmod +x /usr/local/bin/hy2-port-hop-rules.sh

# 创建 systemd service，开机自动执行
cat > /etc/systemd/system/hy2-port-hop.service << 'EOF'
[Unit]
Description=Hysteria2 Port Hopping iptables rules (30000-32000 → 443/UDP)
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/hy2-port-hop-rules.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable hy2-port-hop
```

## 集成到 proxyInstall.sh

在 `Main()` 流程中，于 `Step3_InstallXray()`（hy2/Xray 启动之后）插入新步骤：

### 新增函数 `Step3_5_SetupHy2PortHop()`

```sh
# ============================================================
# Step 3.5: hy2 动态端口 iptables UDP 映射 (30000-32000 → 443)
# 条件: 仅当 ~/.env 中 HY2_PORT_HOP="yes" 时执行
# ============================================================
Step3_5_SetupHy2PortHop() {
    # 开关控制 — 未启用则跳过
    if [ "${HY2_PORT_HOP:-}" != "yes" ]; then
        log info "Step 3.5 跳过 — HY2_PORT_HOP 未启用"
        return 0
    fi

    _hop_start="${HY2_PORT_HOP_START:-30000}"
    _hop_end="${HY2_PORT_HOP_END:-32000}"
    _hop_target="${HY2_PORT_HOP_TARGET:-443}"

    log info "Step 3.5: 配置 hy2 动态端口映射 ${_hop_start}-${_hop_end}/UDP → ${_hop_target}/UDP"

    # 安装 iptables-persistent
    apt-get install -y -qq iptables-persistent

    # IPv4 规则 (幂等: -C 检查存在则跳过)
    if ! iptables -t nat -C PREROUTING -p udp --dport "${_hop_start}:${_hop_end}" -j REDIRECT --to-port "${_hop_target}" 2>/dev/null; then
        iptables -t nat -A PREROUTING -p udp --dport "${_hop_start}:${_hop_end}" -j REDIRECT --to-port "${_hop_target}"
        log info "IPv4 iptables 规则已添加"
    else
        log info "IPv4 iptables 规则已存在，跳过"
    fi

    # IPv6 规则 (幂等)
    if ! ip6tables -t nat -C PREROUTING -p udp --dport "${_hop_start}:${_hop_end}" -j REDIRECT --to-port "${_hop_target}" 2>/dev/null; then
        ip6tables -t nat -A PREROUTING -p udp --dport "${_hop_start}:${_hop_end}" -j REDIRECT --to-port "${_hop_target}"
        log info "IPv6 iptables 规则已添加"
    else
        log info "IPv6 iptables 规则已存在，跳过"
    fi

    # 持久化
    netfilter-persistent save
    log info "iptables 规则已持久化 (netfilter-persistent)"

    # 备用: 写入 systemd service 确保重启后生效
    _rule_script="/usr/local/bin/hy2-port-hop-rules.sh"
    cat > "$_rule_script" << RULE_EOF
#!/bin/sh
iptables -t nat -C PREROUTING -p udp --dport ${_hop_start}:${_hop_end} -j REDIRECT --to-port ${_hop_target} 2>/dev/null || \\
    iptables -t nat -A PREROUTING -p udp --dport ${_hop_start}:${_hop_end} -j REDIRECT --to-port ${_hop_target}
ip6tables -t nat -C PREROUTING -p udp --dport ${_hop_start}:${_hop_end} -j REDIRECT --to-port ${_hop_target} 2>/dev/null || \\
    ip6tables -t nat -A PREROUTING -p udp --dport ${_hop_start}:${_hop_end} -j REDIRECT --to-port ${_hop_target}
RULE_EOF
    chmod +x "$_rule_script"

    _service_file="/etc/systemd/system/hy2-port-hop.service"
    cat > "$_service_file" << SVC_EOF
[Unit]
Description=Hysteria2 Port Hopping iptables rules (${_hop_start}-${_hop_end} → ${_hop_target}/UDP)
After=network.target

[Service]
Type=oneshot
ExecStart=${_rule_script}
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SVC_EOF

    systemctl daemon-reload
    systemctl enable hy2-port-hop
    log info "hy2-port-hop systemd service 已启用"

    log info "Step 3.5 完成 — 端口映射: ${_hop_start}-${_hop_end}/UDP → ${_hop_target}/UDP"
}
```

### ~/.env 配置项

```bash
# hy2 动态端口支持 (可选)
HY2_PORT_HOP="yes"              # 启用动态端口映射
HY2_PORT_HOP_START="30000"      # 起始端口 (默认 30000)
HY2_PORT_HOP_END="32000"        # 结束端口 (默认 32000)
HY2_PORT_HOP_TARGET="443"       # 目标端口 (默认 443)
```

### Main() 调用顺序

```sh
Main() {
    LoadEnv
    InitSystem
    Step0_ApplyId
    Step1_Register
    Step1_5_DownloadSSL
    Step3_InstallNginx
    Step3_InstallXray
    Step3_5_SetupHy2PortHop    # ← 新增：hy2 动态端口
    Step2_ResolveDns
    Step4_DeployCrontab
    ...
}
```

## 验证方法

```bash
# 1. 检查 iptables 规则是否生效
iptables -t nat -L PREROUTING -n -v | grep 443

# 2. 验证规则统计计数（发送 UDP 包后计数器应增长）
watch -n1 'iptables -t nat -L PREROUTING -n -v'

# 3. 使用 ncat/hy2 客户端测试随机端口连通性
#    hy2 客户端配置中设置 port hopping:
#    hops: 30000-32000
#    确认连接成功

# 4. 检查 systemd service 状态
systemctl status hy2-port-hop

# 5. 验证持久化规则文件
cat /etc/iptables/rules.v4 | grep 30000
```

## 注意事项

| 项目 | 说明 |
|------|------|
| **端口冲突** | 确保 30000-32000 范围内没有其他 UDP 服务监听，否则流量会被 DNAT 劫持到 443 |
| **性能** | iptables DNAT 是内核态操作，2001 个端口仅生成 1 条规则，对性能影响可忽略 |
| **conntrack** | UDP 是无连接协议，但内核 conntrack 会跟踪 UDP 流，确保同一流的回包正确 NAT |
| **防火墙** | 如果节点有 INPUT 白名单防火墙，需要放行 30000-32000/UDP 入站 |
| **云厂商安全组** | 需要在云控制台安全组中放行 **UDP 443 + UDP 30000-32000** |
| **幂等性** | 使用 `-C`（check）先检测规则是否存在，避免重复安装产生冗余规则 |
| **卸载** | 移除规则：`iptables -t nat -D PREROUTING -p udp --dport 30000:32000 -j REDIRECT --to-port 443` |

## 防火墙放行规则（如需要）

```bash
# iptables 放行 30000-32000/UDP 入站
iptables -A INPUT -p udp --dport 30000:32000 -j ACCEPT
ip6tables -A INPUT -p udp --dport 30000:32000 -j ACCEPT
```
