#!/usr/bin/env bash
# deploy-hz.sh — push 本地 Backend/ → HZ ECS，幂等。
#
# 用法：
#   ./deploy-hz.sh             # 真正部署
#   ./deploy-hz.sh --dry-run   # 打印所有 ssh/rsync 命令但不执行（S-2 验收用）
#
# 前置条件（S-3 一次性配置完成后日常发版只跑本脚本）：
#   - HZ 上已有 linowriting 用户、/opt/linowriting/.env (600)、systemd unit、Nginx site
#   - 本地 mac 已配 ssh deploy@118.178.122.194 公钥登录
#   - 本地 git working tree clean（脚本不强制检查，但作者纪律）
#
# 完整 runbook 见 PROJECT_PLAN.md §5.S.5。
# HZ 云端事实文件：/Users/linotsai/hz_info.md（每次 HZ 改动后必须同步更新）。

set -euo pipefail
IFS=$'\n\t'

# ─── 常量 ────────────────────────────────────────────────
HZ="deploy@118.178.122.194"
REMOTE="/opt/linowriting"
SERVICE="linowriting-api"
LOCAL_PORT="8787"

# 脚本住在 Backend/deploy/，repo root = Backend/ 的上一级
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BACKEND_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# ─── 参数 ────────────────────────────────────────────────
DRY_RUN=0
for arg in "$@"; do
    case "$arg" in
        --dry-run|-n)
            DRY_RUN=1
            ;;
        --help|-h)
            sed -n '2,15p' "$0"
            exit 0
            ;;
        *)
            echo "unknown arg: $arg" >&2
            exit 2
            ;;
    esac
done

# ─── 色彩 ────────────────────────────────────────────────
if [ -t 1 ] && command -v tput >/dev/null 2>&1 && [ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]; then
    C_STEP="$(tput setaf 6)"   # cyan
    C_OK="$(tput setaf 2)"     # green
    C_WARN="$(tput setaf 3)"   # yellow
    C_ERR="$(tput setaf 1)"    # red
    C_DIM="$(tput dim 2>/dev/null || true)"
    C_RST="$(tput sgr0)"
else
    C_STEP=""; C_OK=""; C_WARN=""; C_ERR=""; C_DIM=""; C_RST=""
fi

CURRENT_STEP=""
step() {
    CURRENT_STEP="$1"
    echo "${C_STEP}==> ${CURRENT_STEP}${C_RST}"
}
ok() {
    echo "${C_OK}    ok${C_RST}"
}
warn() {
    echo "${C_WARN}    warn: $*${C_RST}"
}
die() {
    echo "${C_ERR}!!! step failed: ${CURRENT_STEP}${C_RST}" >&2
    echo "${C_ERR}!!! $*${C_RST}" >&2
    exit 1
}
trap 'die "aborted (exit $?)"' ERR

# ─── 执行包装：dry-run 模式下只打印 ─────────────────────
run() {
    if [ "$DRY_RUN" -eq 1 ]; then
        # 临时把 IFS 复位，让 echo 的 $* 用空格连接（IFS=$'\n\t' 会换行难读）
        local _IFS="$IFS"
        IFS=' '
        echo "${C_DIM}    [dry-run] $*${C_RST}"
        IFS="$_IFS"
    else
        # shellcheck disable=SC2294
        eval "$@"
    fi
}

# ─── 前置检查（本地，dry-run 也跑）─────────────────────
step "preflight: local checks"
[ -d "$BACKEND_ROOT" ] || die "BACKEND_ROOT not a dir: $BACKEND_ROOT"
[ -f "$BACKEND_ROOT/pyproject.toml" ] || die "missing $BACKEND_ROOT/pyproject.toml — wrong rsync source?"
[ -d "$BACKEND_ROOT/app" ] || die "missing $BACKEND_ROOT/app/ — wrong rsync source?"
[ -d "$BACKEND_ROOT/alembic" ] || die "missing $BACKEND_ROOT/alembic/ — alembic migrations 缺失"
command -v rsync >/dev/null || die "rsync 不在 PATH"
command -v ssh   >/dev/null || die "ssh 不在 PATH"
ok

if [ "$DRY_RUN" -eq 1 ]; then
    echo "${C_WARN}--- DRY RUN — no remote side-effects ---${C_RST}"
fi

# ─── 1. rsync 代码到 HZ staging ─────────────────────────
step "rsync code → $HZ:$REMOTE/staging/"
RSYNC_EXCLUDES=(
    --exclude='.venv'
    --exclude='.env'
    --exclude='__pycache__'
    --exclude='*.pyc'
    --exclude='*.db'
    --exclude='*.db-journal'
    --exclude='.pytest_cache'
    --exclude='*.egg-info'
    --exclude='.mypy_cache'
    --exclude='.ruff_cache'
    --exclude='deploy/'   # 不把 systemd unit / nginx conf rsync 进 /opt/linowriting/ —— 那些手动放到 /etc/
)
# 注意尾部 / —— 同步 Backend/ 的内容，不是 Backend/ 这个目录本身
run rsync -avz --delete "${RSYNC_EXCLUDES[@]}" \
    "$BACKEND_ROOT/" "\"$HZ:$REMOTE/staging/\""
ok

# ─── 2. 远端原子切换 + venv + 依赖 + alembic ────────────
step "remote: atomic switch + venv + deps + alembic upgrade"
# 把多行远端命令拼成单 string；linowriting 用户做应用层操作。
# 注意：在 deploy 用户下用 sudo -u linowriting 切到业务用户；
#       业务用户没有 sudo，所以 systemctl reload 留给步骤 3 的 deploy 用户做。
REMOTE_CMD='set -euo pipefail
cd '"$REMOTE"'
sudo -u linowriting bash -lc "
    set -euo pipefail
    cd '"$REMOTE"'
    # 2a. 原子切换 staging → current
    rsync -a --delete staging/ ./
    # 2b. 准备 venv（首次创建；已存在则跳过）
    if [ ! -d .venv ]; then
        python3 -m venv .venv
    fi
    # 2c. 装依赖（pip install -e .；HZ 没 uv，刻意不用）
    .venv/bin/pip install --quiet --upgrade pip
    .venv/bin/pip install --quiet -e .
    # 2d. 跑迁移（手动 cutover；不在 systemd ExecStartPre 自动跑）
    .venv/bin/alembic upgrade head
"'
run ssh "$HZ" "'$REMOTE_CMD'"
ok

# ─── 3. reload service ──────────────────────────────────
step "remote: systemctl reload-or-restart $SERVICE"
run ssh "$HZ" "'sudo systemctl reload-or-restart $SERVICE'"
ok

# ─── 4. smoke check ─────────────────────────────────────
# 不用 curl + Bearer —— shell 里没 \$API_TOKEN，避免 cat .env。
# 用 systemctl is-active：简单、可靠、不碰 secret。
# HTTPS smoke（https://lw.linotsai.top/api/v1/health）由作者人工跑 + LinoI 客户端跑。
step "remote: systemctl is-active $SERVICE"
if [ "$DRY_RUN" -eq 1 ]; then
    echo "${C_DIM}    [dry-run] ssh $HZ 'systemctl is-active $SERVICE'${C_RST}"
else
    sleep 2
    if ssh "$HZ" "systemctl is-active $SERVICE" | grep -qx active; then
        ok
    else
        die "service not active；ssh $HZ 'journalctl -u $SERVICE -n 50 --no-pager' 看日志"
    fi
fi

# ─── 完成 ────────────────────────────────────────────────
CURRENT_STEP="done"
if [ "$DRY_RUN" -eq 1 ]; then
    echo "${C_OK}=== dry-run complete (no remote side-effects) ===${C_RST}"
else
    echo "${C_OK}=== deploy complete ===${C_RST}"
    echo "    人工 smoke：curl -fsS https://lw.linotsai.top/api/v1/health -H 'Authorization: Bearer <prod-token>'"
fi
