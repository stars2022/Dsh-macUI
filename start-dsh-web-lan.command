#!/bin/bash
set -euo pipefail

# 局域网开放模式：绑定 0.0.0.0，供手机等本地网络设备临时访问。
# 警告：这会把 dsh 的 /api 暴露给整个局域网，等同开放远程执行能力。
# 测试完成后请运行 stop-dsh-web.command，再运行 start-dsh-web.command 恢复普通模式。

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="${DSH_SOURCE_DIR:-$SCRIPT_DIR/deepseek-harness-master}"
URL="http://127.0.0.1:3080"
PORT=3080
STATE_DIR="$HOME/.dsh/run"
NORMAL_PID_FILE="$STATE_DIR/dsh-web.pid"
PID_FILE="$STATE_DIR/dsh-web-lan.pid"
LOG_FILE="$STATE_DIR/dsh-web-lan.log"
PATCH_FILE="$SCRIPT_DIR/dsh-web-lan.patch.yml"

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
  for file in "$NORMAL_PID_FILE" "$PID_FILE"; do
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

# 已经在局域网模式运行：直接给出地址
if pid_alive "$(cat "$PID_FILE" 2>/dev/null || true)"; then
  echo "dsh web（局域网模式）已在运行。"
  echo "本机访问: $URL"
  LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
  [[ -n "$LAN_IP" ]] && echo "局域网访问: http://$LAN_IP:$PORT"
  open "$URL" || true
  exit 0
fi

# 普通模式或其他旧实例占用端口：先停止
if lsof -nP -iTCP:"$PORT" -sTCP:LISTEN >/dev/null 2>&1; then
  echo "检测到已有 dsh web 正在使用端口 ${PORT}，先停止再以局域网模式启动 ..."
  stop_current
fi

if [[ ! -f "$PATCH_FILE" ]]; then
  echo "找不到 patch 文件: $PATCH_FILE"
  exit 1
fi

echo "正在启动 dsh web（局域网开放模式，0.0.0.0:${PORT}）..."
nohup node --import tsx/esm apps/cli/src/bin.ts web --patch "$PATCH_FILE" > "$LOG_FILE" 2>&1 &
pid=$!
echo "$pid" > "$PID_FILE"

for _ in {1..60}; do
  if curl -fsS -o /dev/null "$URL" 2>/dev/null; then
    LAN_IP="$(ipconfig getifaddr en0 2>/dev/null || ipconfig getifaddr en1 2>/dev/null || true)"
    echo "dsh web 已以局域网模式启动。"
    echo "进程 PID: $pid"
    echo "日志文件: $LOG_FILE"
    echo "本机访问: $URL"
    if [[ -n "$LAN_IP" ]]; then
      echo "局域网访问: http://$LAN_IP:${PORT}（手机/其他设备用这个地址）"
    else
      echo "未检测到局域网 IPv4，请自行查看当前 IP。"
    fi
    echo "警告：局域网内任何设备都可访问，测试完请运行 stop-dsh-web.command。"
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
