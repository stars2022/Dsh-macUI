#!/bin/bash
set -euo pipefail

PORT=3080
STATE_DIR="$HOME/.dsh/run"
NORMAL_PID_FILE="$STATE_DIR/dsh-web.pid"
LAN_PID_FILE="$STATE_DIR/dsh-web-lan.pid"

pid_alive() {
  local pid="$1"
  [[ -n "$pid" ]] && kill -0 "$pid" 2>/dev/null
}

stop_pid() {
  local pid="$1"
  if ! pid_alive "$pid"; then
    return 0
  fi
  echo "正在停止 dsh web (PID $pid) ..."
  kill "$pid" 2>/dev/null || true
  for _ in {1..30}; do
    if ! pid_alive "$pid"; then
      return 0
    fi
    sleep 1
  done
  echo "进程未在 30 秒内退出，强制结束 ..."
  kill -9 "$pid" 2>/dev/null || true
}

for file in "$NORMAL_PID_FILE" "$LAN_PID_FILE"; do
  if [[ -f "$file" ]]; then
    pid="$(cat "$file" 2>/dev/null || true)"
    if [[ -n "$pid" ]]; then
      stop_pid "$pid" || true
    fi
    rm -f "$file"
  fi
done

# 兜底：关闭仍在监听端口的进程
pids="$(lsof -ti tcp:"$PORT" 2>/dev/null || true)"
if [[ -n "$pids" ]]; then
  echo "关闭仍在监听端口 $PORT 的进程: $pids"
  for pid in $pids; do
    stop_pid "$pid" || true
  done
fi

echo "dsh web 已停止（普通模式与局域网模式均已处理）。"
