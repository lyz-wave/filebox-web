#!/usr/bin/env bash
# filebox 新设备一键配置（macOS / Linux）
# 用法: bash bootstrap.sh [--repo-dir DIR] [--token TOKEN] [--skip-auth] [--skip-install] [--json]

set -euo pipefail

REPO_URL="https://github.com/lyz-wave/filebox.git"
PAGE_URL="https://lyz-wave.github.io/filebox-web/"
CLIENT_ID="178c6fc778ccc68e1d6a"
REPO_DIR="${FILEBOX_REPO_DIR:-$HOME/filebox}"
TOKEN="${GH_TOKEN:-}"
SKIP_AUTH=0
SKIP_INSTALL=0
JSON=0

usage() {
  echo "用法: bash bootstrap.sh [--repo-dir DIR] [--token TOKEN] [--skip-auth] [--skip-install] [--json]"
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --repo-dir) REPO_DIR="${2:-}"; shift 2 ;;
    --token) TOKEN="${2:-}"; shift 2 ;;
    --skip-auth) SKIP_AUTH=1; shift ;;
    --skip-install) SKIP_INSTALL=1; shift ;;
    --json) JSON=1; shift ;;
    -h|--help) usage; exit 0 ;;
    *) echo "未知参数: $1" >&2; usage; exit 1 ;;
  esac
done

OS_NAME="unknown"
case "$(uname -s)" in
  Darwin*) OS_NAME="macos" ;;
  Linux*) OS_NAME="linux" ;;
esac

echo ""
echo "=== filebox 配置脚本（macOS / Linux）==="
echo "系统: $OS_NAME ($(uname -m))"
echo "仓库目标目录: $REPO_DIR"
echo ""

# ---------- git ----------
if ! command -v git >/dev/null 2>&1; then
  if [ "$SKIP_INSTALL" -eq 1 ]; then
    echo "[FAIL] 缺少 git（--skip-install 跳过了安装）" >&2
    exit 1
  fi
  echo "[..] 未检测到 git，尝试安装 ..."
  if [ "$OS_NAME" = "macos" ] && command -v brew >/dev/null 2>&1; then
    brew install git || true
  elif [ "$OS_NAME" = "linux" ]; then
    if command -v apt-get >/dev/null 2>&1; then
      sudo apt-get update -y && sudo apt-get install -y git || true
    elif command -v dnf >/dev/null 2>&1; then
      sudo dnf install -y git || true
    elif command -v yum >/dev/null 2>&1; then
      sudo yum install -y git || true
    elif command -v pacman >/dev/null 2>&1; then
      sudo pacman -Sy --noconfirm git || true
    fi
  fi
fi
if ! command -v git >/dev/null 2>&1; then
  echo "[FAIL] 缺少 git，请手动安装：https://git-scm.com/downloads" >&2
  exit 1
fi
echo "[OK] git 就绪: $(git --version)"

# ---------- gh ----------
if ! command -v gh >/dev/null 2>&1; then
  if [ "$SKIP_INSTALL" -eq 1 ]; then
    echo "[FAIL] 缺少 gh（--skip-install 跳过了安装）" >&2
    exit 1
  fi
  echo "[..] 未检测到 GitHub CLI，尝试安装 ..."
  if [ "$OS_NAME" = "macos" ] && command -v brew >/dev/null 2>&1; then
    brew install gh || true
  elif [ "$OS_NAME" = "linux" ] && command -v apt-get >/dev/null 2>&1; then
    sudo apt-get install -y gh || true
  elif [ "$OS_NAME" = "linux" ] && command -v dnf >/dev/null 2>&1; then
    sudo dnf install -y gh || true
  elif [ "$OS_NAME" = "linux" ] && command -v pacman >/dev/null 2>&1; then
    sudo pacman -Sy --noconfirm github-cli || true
  fi
fi
if ! command -v gh >/dev/null 2>&1; then
  echo "[FAIL] 缺少 GitHub CLI，请手动安装：https://cli.github.com/" >&2
  exit 1
fi
echo "[OK] gh 就绪: $(gh --version | head -n 1)"

# ---------- 登录 ----------
if [ "$SKIP_AUTH" -ne 1 ]; then
  if gh auth status >/dev/null 2>&1; then
    echo "[OK] 本机已登录 GitHub，跳过授权"
  elif [ -n "$TOKEN" ]; then
    echo "[..] 使用提供的 token 登录 ..."
    echo "$TOKEN" | gh auth login --with-token -h github.com || {
      echo "[FAIL] token 登录失败（gh 需要 repo/read:org 权限）" >&2
      exit 1
    }
    echo "[OK] token 登录完成"
  else
    DEVICE_CODE_URL="https://github.com/login/device/code"
    TOKEN_URL="https://github.com/login/oauth/access_token"
    SCOPE="repo read:org workflow gist"
    GRANT_TYPE="urn:ietf:params:oauth:grant-type:device_code"
    json="$(curl -sS -X POST "$DEVICE_CODE_URL" -H "Accept: application/json" --data-urlencode "client_id=$CLIENT_ID" --data-urlencode "scope=$SCOPE")"
    device_code="$(echo "$json" | sed -n 's/.*"device_code":"\([^"]*\)".*/\1/p' | head -n 1)"
    user_code="$(echo "$json" | sed -n 's/.*"user_code":"\([^"]*\)".*/\1/p' | head -n 1)"
    verify_uri="$(echo "$json" | sed -n 's/.*"verification_uri":"\([^"]*\)".*/\1/p' | head -n 1)"
    if [ -z "$device_code" ] || [ -z "$user_code" ]; then
      echo "[FAIL] 无法获取 GitHub 授权码: $json" >&2
      exit 1
    fi
    echo ""
    echo "=== 需要 GitHub 授权（15 分钟内有效）==="
    echo "  1) 打开: $verify_uri"
    echo "  2) 输入验证码: $user_code"
    echo ""
    if command -v xdg-open >/dev/null 2>&1; then xdg-open "$verify_uri" >/dev/null 2>&1 || true; fi
    if command -v open >/dev/null 2>&1; then open "$verify_uri" >/dev/null 2>&1 || true; fi
    i=0
    token=""
    while [ "$i" -lt 180 ]; do
      sleep 5
      resp="$(curl -sS -X POST "$TOKEN_URL" -H "Accept: application/json" --data-urlencode "client_id=$CLIENT_ID" --data-urlencode "device_code=$device_code" --data-urlencode "grant_type=$GRANT_TYPE")"
      case "$resp" in
        *authorization_pending*) i=$((i + 1)); continue ;;
        *slow_down*) sleep 5; i=$((i + 1)); continue ;;
        *error*) echo "[FAIL] GitHub 授权失败: $resp" >&2; exit 1 ;;
      esac
      token="$(echo "$resp" | sed -n 's/.*"access_token":"\([^"]*\)".*/\1/p' | head -n 1)"
      if [ -n "$token" ]; then break; fi
      i=$((i + 1))
    done
    if [ -z "$token" ]; then
      echo "[FAIL] 等待 GitHub 授权超时" >&2
      exit 1
    fi
    echo "$token" | gh auth login --with-token -h github.com || {
      echo "[FAIL] gh 登录失败" >&2
      exit 1
    }
    echo "[OK] GitHub 授权完成"
  fi
  gh auth setup-git >/dev/null 2>&1 || true
else
  echo "[WARN] 已跳过登录步骤（--skip-auth）"
fi

gh_user_field() {
  local field="$1"
  local i=0
  local out=""
  while [ "$i" -lt 3 ]; do
    out="$(gh api user --jq ".$field" 2>/dev/null || true)"
    if [ -n "$out" ]; then
      printf "%s" "$out"
      return 0
    fi
    i=$((i + 1))
    sleep 2
  done
  return 1
}

LOGIN="$(gh_user_field login || true)"
if [ -z "$LOGIN" ]; then
  echo "[FAIL] 无法读取 GitHub 账号（gh api user 失败）。请检查网络后重跑，或手动执行 gh auth login。" >&2
  exit 1
fi
if [ "$LOGIN" != "lyz-wave" ]; then
  echo "[WARN] 当前登录账号是 $LOGIN，不是 lyz-wave；没有仓库权限时 clone/push 会失败"
fi
echo "[OK] GitHub 账号: $LOGIN"

# ---------- git 身份 ----------
if [ -z "$(git config --global user.name 2>/dev/null || true)" ]; then
  git config --global user.name "$LOGIN"
fi
if [ -z "$(git config --global user.email 2>/dev/null || true)" ]; then
  USER_ID="$(gh_user_field id || true)"
  git config --global user.email "$USER_ID+$LOGIN@users.noreply.github.com"
fi
echo "[OK] Git 身份: $(git config --global user.name) <$(git config --global user.email)>"

# ---------- 仓库 ----------
if [ -d "$REPO_DIR/.git" ]; then
  echo "[..] 更新已有仓库 ..."
  ( cd "$REPO_DIR" && git pull --rebase --autostash --quiet )
elif [ -e "$REPO_DIR" ]; then
  echo "[FAIL] 目录已存在但不是 git 仓库：$REPO_DIR" >&2
  exit 1
else
  echo "[..] 克隆仓库 ..."
  git clone "$REPO_URL" "$REPO_DIR"
fi
( cd "$REPO_DIR" && git config core.autocrlf false && git config core.quotepath false && git config pull.rebase true )
chmod +x "$REPO_DIR/send.sh" "$REPO_DIR/recv.sh" "$REPO_DIR/clean.sh" "$REPO_DIR/text.sh" 2>/dev/null || true
echo "[OK] 仓库: $REPO_DIR"

for f in send.ps1 recv.ps1 clean.ps1 send.sh recv.sh clean.sh; do
  if [ ! -f "$REPO_DIR/$f" ]; then
    echo "[FAIL] 仓库缺少脚本：$f" >&2
    exit 1
  fi
done
echo "[OK] 脚本文件齐全"

SMOKE="$(cd "$REPO_DIR" && bash recv.sh 2>&1 | head -n 1 || true)"
echo "[OK] 冒烟测试 recv.sh: $SMOKE"

echo ""
echo "=== 配置完成 ==="
echo "  仓库: $REPO_DIR"
echo "  账号: $LOGIN"
echo "  发送: cd \"$REPO_DIR\" && ./send.sh 文件名"
echo "  接收: cd \"$REPO_DIR\" && ./recv.sh"
echo "  网页: $PAGE_URL"
echo ""
echo "下一步："
echo "  - 手机或临时电脑用网页版（第一次要填令牌）：$PAGE_URL"
echo "  - 想验证链路：发送一个小文件，再到网页 inbox 查看"
echo ""

if [ "$JSON" -eq 1 ]; then
  echo "RESULT_JSON {\"ok\":true,\"repo_dir\":\"$REPO_DIR\",\"login\":\"$LOGIN\",\"page\":\"$PAGE_URL\"}"
fi
exit 0
