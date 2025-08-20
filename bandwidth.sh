#!/usr/bin/env bash
# 自动监控所有活动网卡带宽（非 lo），动态增删
# 用法：INTERVAL=1 ./bandwidth_all.sh 或 ./bandwidth_all.sh 1

set -euo pipefail

INTERVAL="${1:-${INTERVAL:-1}}"

# 将比特/秒转为人类可读
bits_to_human() {
  local bits="$1"
  awk -v b="$bits" 'BEGIN{
    if (b>=1073741824)      {printf "%.2f Gbps", b/1073741824}
    else if (b>=1048576)    {printf "%.2f Mbps", b/1048576}
    else if (b>=1024)       {printf "%.2f Kbps", b/1024}
    else                    {printf "%d bps", b}
  }'
}

# 获取“活动”网卡列表：state UP，排除 lo
get_active_ifaces() {
  ip -o link show up 2>/dev/null \
   | awk -F': ' '{print $2}' \
   | awk '{print $1}' \
   | grep -vE '^lo$' || true
}

declare -A RX_OLD TX_OLD

echo "正在自动监控所有活动网卡的带宽使用情况...（按 Ctrl+C 退出）"
sleep 0.2

# 初始化
for i in $(get_active_ifaces); do
  read -r rx tx < <(awk -v IF="$i" '$1 ~ ("^"IF":"){print $2, $10}' /proc/net/dev)
  [[ -n "${rx:-}" && -n "${tx:-}" ]] || continue
  RX_OLD["$i"]="$rx"
  TX_OLD["$i"]="$tx"
done

while :; do
  # 每轮都刷新一次活动网卡集合
  mapfile -t IFACES < <(get_active_ifaces)

  # 将新网卡加入监控；下线网卡自然不会再显示
  for i in "${IFACES[@]}"; do
    if [[ -z "${RX_OLD[$i]:-}" || -z "${TX_OLD[$i]:-}" ]]; then
      read -r rx tx < <(awk -v IF="$i" '$1 ~ ("^"IF":"){print $2, $10}' /proc/net/dev)
      [[ -n "${rx:-}" && -n "${tx:-}" ]] || continue
      RX_OLD["$i"]="$rx"
      TX_OLD["$i"]="$tx"
    fi
  done

  # 采样间隔
  sleep "$INTERVAL"

  clear
  printf "时间：%s  |  采样间隔：%ss\n" "$(date '+%F %T')" "$INTERVAL"
  printf "%s\n" "-----------------------------------------------------------------------"
  printf "%-12s | %22s | %22s\n" "网卡" "接收 (Rx)" "发送 (Tx)"
  printf "%s\n" "-----------------------------------------------------------------------"

  for i in "${IFACES[@]}"; do
    # 读取当前字节数
    if ! read -r rx_new tx_new < <(awk -v IF="$i" '$1 ~ ("^"IF":"){print $2, $10}' /proc/net/dev); then
      continue
    fi
    [[ -n "${rx_new:-}" && -n "${tx_new:-}" ]] || continue

    # 计算差值与速率（转为 bit/s）
    rx_diff=$(( rx_new - ${RX_OLD[$i]:-rx_new} ))
    tx_diff=$(( tx_new - ${TX_OLD[$i]:-tx_new} ))
    (( rx_diff < 0 )) && rx_diff=0
    (( tx_diff < 0 )) && tx_diff=0

    rx_bps=$(( rx_diff * 8 / INTERVAL ))
    tx_bps=$(( tx_diff * 8 / INTERVAL ))

    RX_HUMAN="$(bits_to_human "$rx_bps")"
    TX_HUMAN="$(bits_to_human "$tx_bps")"

    printf -- "%-12s | %22s | %22s\n" "$i" "$RX_HUMAN" "$TX_HUMAN"

    # 更新旧值
    RX_OLD["$i"]="$rx_new"
    TX_OLD["$i"]="$tx_new"
  done

  printf "%s\n" "-----------------------------------------------------------------------"
  printf "提示：仅显示状态为 UP 的网卡（不含 lo），网卡上下线会自动更新。\n"
done