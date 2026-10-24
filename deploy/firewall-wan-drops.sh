#!/bin/sh
# r4s (OpenWrt fw4) WAN 入站显式 DROP——docker 发布端口兜底
# 2026-10-24「不能公网暴露」收口：noda-static-prod 18080/18081/18443 + immich 2283。
# 背景：本机 docker 为 userland-proxy 模式（无 DNAT），发布端口是路由器本机监听，
# WAN 不可达由 wan zone input=REJECT 保证；本规则是显式兜底——防 input 策略漂移、
# 防 docker 切换 iptables=true（DNAT 走 FORWARD 绕过 zone input）后裸奔。
# 幂等可重复执行；UCI 段名不允许连字符 → 匿名段 + name 选项模式。
# 已在 r4s /etc/config/firewall 落地（option name 'block-wan-docker-published-ports'）。
set -e
RULE="block-wan-docker-published-ports"
if uci show firewall | grep -q "name='$RULE'"; then
    echo "rule already present: $RULE"
    exit 0
fi
uci add firewall rule >/dev/null
uci set firewall.@rule[-1].name="$RULE"
uci set firewall.@rule[-1].src='wan'
uci set firewall.@rule[-1].proto='tcp'
uci set firewall.@rule[-1].dest_port='18080 18081 18443 2283'
uci set firewall.@rule[-1].target='DROP'
uci set firewall.@rule[-1].comment='noda static 18080/18081/18443 + immich 2283: WAN explicit DROP (backstop for input=REJECT; guard vs policy drift / docker iptables-mode switch) 2026-10-24'
uci commit firewall
fw4 reload
echo "rule installed: $RULE"
