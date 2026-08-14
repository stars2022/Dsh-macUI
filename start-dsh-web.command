#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${DSH_SOURCE_DIR:-$SCRIPT_DIR/deepseek-harness-master}"
URL="http://127.0.0.1:3080"
PORT=3080
STATE_DIR="$HOME/.dsh/run"
PID_FILE="$STATE_DIR/dsh-web.pid"
LAN_PID_FILE="$STATE_DIR/dsh-web-lan.pid"
LOG_FILE="$STATE_DIR/dsh-web.log"

# Homebrew 的 Node 24 是可选路径；其他安装方式由当前 PATH 解析。
if [[ -d "/opt/homebrew/opt/node@24/bin" ]]; then
  export PATH="/opt/homebrew/opt/node@24/bin:$PATH"
fi

if [[ ! -f "$PROJECT_DIR/apps/cli/src/bin.ts" ]]; then
  echo "找不到 DeepSeek Harness 源码: $PROJECT_DIR"
  echo "请克隆到 deepseek-harness-master，或设置 DSH_SOURCE_DIR。"
  exit 1
fi

mkdir -p "$STATE_DIR"
cd "$PROJECT_DIR"

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

stop_current() {
  for file in "$PID_FILE" "$LAN_PID_FILE"; do
    if [[ -f "$file" ]]; then
      local pid
      pid="$(cat "$file" 2>/dev/null || true)"
      if [[ -n "$pid" ]]; then
        stop_pid "$pid" || true
      fi
      rm -f "$file"
    fi
  done
  local pids
  pids="$(lsof -ti tcp:"$PORT" 2>/dev/null || true)"
  if [[ -n "$pids" ]]; then
    echo "关闭仍在监听端口 $PORT 的进程: $pids"
    for pid in $pids; do
      stop_pid "$pid" || true
    done
  fi
}

# 普通模式已在运行：直接打开
if pid_alive "$(cat "$PID_FILE" 2>/dev/null || true)"; then
  echo "dsh web（普通模式）已在运行，直接打开 $URL"
  open "$URL" || true
  exit 0
fi

# 局域网模式或端口被旧实例占用：先停止，再以普通模式启动
if pid_alive "$(cat "$LAN_PID_FILE" 2>/dev/null || true)" || lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "检测到局域网模式/旧实例正在使用端口 ${PORT}，先停止再启动普通模式 ..."
  stop_current
fi

echo "正在启动 dsh web（普通模式，仅本机 127.0.0.1）..."
nohup node --import tsx/esm apps/cli/src/bin.ts web > "$LOG_FILE" 2>&1 &
pid=$!
echo "$pid" > "$PID_FILE"

for _ in {1..60}; do
  if curl -fsS -o /dev/null "$URL" 2>/dev/null; then
    echo "dsh web 已启动: $URL"
    echo "进程 PID: $pid"
    echo "日志文件: $LOG_FILE"
    open "$URL" || true
    exit 0
  fi
  if ! pid_alive "$pid"; then
    echo "启动失败，日志如下："
    cat "$LOG_FILE" || true
    rm -f "$PID_FILE"
    exit 1
  fi
  sleep 1
done

echo "等待服务就绪超时，日志如下："
cat "$LOG_FILE" || true
exit 1
