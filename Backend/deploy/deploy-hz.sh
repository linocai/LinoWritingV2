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
        # v0.8 S-3 fix: 直接 exec,不再 eval。
        # eval 会把已经 quoted 的 ssh target 再 tokenize 一次,导致 rsync 在
        # `"$HZ:$REMOTE/staging/"` 这种含字面引号的 arg 上 double-strip 引号,
        # 最终目标变成 `/opt/linowriting/` 父目录而非 `/opt/linowriting/staging/`,
        # rsync --delete 就开始去删本来不该动的根目录文件。S-3 首次 cutover 三次
        # 失败后定位到这里。
        "$@"
    fi
}

# ─── 前置检查（本地，dry-run 也跑）─────────────────────
step "preflight: local checks"
[ -d "$BACKEND_ROOT" ] || die "BACKEND_ROOT not a dir: $BACKEND_ROOT"
[ -f "$BACKEND_ROOT/pyproject.toml" ] || die "missing $BACKEND_ROOT/pyproject.toml — wrong rsync source?"
[ -d "$BACKEND_ROOT/app" ] || die "missing $BACKEND_ROOT/app/ — wrong rsync source?"
[ -d "$BACKEND_ROOT/alembic" ] || die "missing $BACKEND_ROOT/alembic/ — alembic migrations 缺失"
command -v ssh   >/dev/null || die "ssh 不在 PATH"

# v0.8 S-3 fix: macOS 自带的 openrsync (Apple BSD fork, protocol 29) 在 `--delete`
# 解析远程绝对路径时与 GNU rsync 不一致 —— 会把 `staging/` 误识为 source 的
# 子树而非 destination 根,导致 rsync --delete 试图在 `/opt/linowriting/`
# (parent) 创建文件并删 staging/* (Permission denied)。强制走 GNU rsync。
RSYNC_BIN="$(command -v rsync || true)"
if [ -x /opt/homebrew/bin/rsync ]; then
    RSYNC_BIN=/opt/homebrew/bin/rsync   # macOS brew install rsync
elif [ -x /usr/local/bin/rsync ]; then
    RSYNC_BIN=/usr/local/bin/rsync       # macOS Intel brew / Linux 自编译
fi
[ -n "$RSYNC_BIN" ] || die "rsync 不在 PATH"
# 用 $() 捕获而非 pipe head;set -o pipefail + SIGPIPE 会让 pipe-into-head 报假阳。
_rsync_version_first_line=$("$RSYNC_BIN" --version 2>/dev/null | sed -n '1p')
case "$_rsync_version_first_line" in
    rsync*)  ;;
    *) die "rsync at $RSYNC_BIN 不是 GNU rsync (macOS openrsync 与 --delete 不兼容)。先跑 'brew install rsync'。" ;;
esac
ok

if [ "$DRY_RUN" -eq 1 ]; then
    echo "${C_WARN}--- DRY RUN — no remote side-effects ---${C_RST}"
fi

# ─── 1. rsync 代码直接进 /opt/linowriting/(deploy 是 owner)─────
# S-3 调试简化策略:不走 staging 中转。/opt/linowriting/ 是 deploy:linowriting
# 0750,deploy owner 可直接写。.env / .venv 排除 -- .env 600 linowriting:linowriting
# rsync 碰不到(且 --exclude 默认 protect from --delete),.venv 由 step 2 的
# sudo -u linowriting 创建/管理。
step "rsync code → $HZ:$REMOTE/"
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
    --exclude='deploy/'   # 不把 systemd unit / nginx conf rsync 进 /opt/linowriting/
    --exclude='staging/'  # 历史遗留目录,deploy/runtime 用不到
    --exclude='.cache/'   # pip / 其它工具 cache,linowriting-owned,deploy 删不掉
    --exclude='lino_writing_backend.egg-info/'  # pip install -e . 产物,linowriting 拥有
)
run "$RSYNC_BIN" -avz --delete "${RSYNC_EXCLUDES[@]}" \
    "$BACKEND_ROOT/" "$HZ:$REMOTE/"
ok

# rsync -a (含 -p -g) 会把源端 (mac) 的目录 perm/group 复刻到 /opt/linowriting/,
# 把我们一次性配的 2770 deploy:linowriting 改回 0755 user:user。每次 deploy
# 之后强制 normalize 权限,确保 linowriting (group member) 能在里面写 egg-info /
# .pyc / __pycache__ 等。
step "remote: normalize /opt/linowriting/ perms (2770 deploy:linowriting)"
run ssh "$HZ" "sudo chown -R deploy:linowriting $REMOTE && sudo chmod 2770 $REMOTE && sudo find $REMOTE -type d -not -path '*/.venv*' -exec chmod g+ws {} + && sudo find $REMOTE -type f -not -path '*/.venv*' -exec chmod g+r {} +"
ok

# ─── 2. 远端 venv + 依赖 + alembic(切 linowriting 用户)─────
step "remote: venv + deps + alembic upgrade (as linowriting)"
# linowriting 拥有 .venv 子目录(下面 sudo install -d 创建);其它代码文件
# 由 deploy 拥有,linowriting 通过 group=linowriting 0750 group-read 即可。
REMOTE_CMD='set -euo pipefail
# 一次性确保 .venv 目录归 linowriting 所有(parent /opt/linowriting/ 是
# deploy:linowriting 0750,linowriting 没 write 权限不能在里面 mkdir)。
sudo install -d -o linowriting -g linowriting -m 0755 '"$REMOTE"'/.venv
sudo -u linowriting bash -lc '"'"'
    set -euo pipefail
    cd '"$REMOTE"'
    if [ ! -f .venv/bin/python ]; then
        python3 -m venv .venv
    fi
    # PyPI 跨墙极慢 (S-3 首次部署 60 分钟只装出 pip 自己)。HZ 是阿里云 ECS,
    # 走阿里云镜像 (同网络无墙阻断)。--default-timeout 30 防个别包卡死。
    PIP_INDEX="https://mirrors.aliyun.com/pypi/simple/"
    PIP_HOST="mirrors.aliyun.com"
    .venv/bin/pip install --no-cache-dir --upgrade pip \
        -i "$PIP_INDEX" --trusted-host "$PIP_HOST" --default-timeout 30
    .venv/bin/pip install --no-cache-dir -e . \
        -i "$PIP_INDEX" --trusted-host "$PIP_HOST" --default-timeout 30
    .venv/bin/alembic upgrade head
'"'"
run ssh "$HZ" "$REMOTE_CMD"
ok

# ─── 3. reload service ──────────────────────────────────
# v1.3.2 (LL) P1 (🔵3): writing-as-a-job keeps in-flight writes in *process
# memory* (single-worker WriteJobRegistry). A restart drops any write that is
# mid-generation right now — its daemon thread dies with the process. That's an
# accepted deploy-window loss (author decision, PROJECT_PLAN §4 已决议 #1), but
# surface how many chapters are currently `writing` so the operator can wait for
# a quiet moment. Read-only SELECT via the linowriting DB role; never prints secrets.
step "remote: check for in-flight writes (status='writing') before restart"
if [ "$DRY_RUN" -eq 1 ]; then
    echo "${C_DIM}    [dry-run] ssh $HZ 'sudo -u linowriting psql -tAc \"SELECT count(*) FROM chapters WHERE status='\\''writing'\\''\"'${C_RST}"
else
    WRITING_COUNT=$(ssh "$HZ" "sudo -u linowriting psql -d linowriting -tAc \"SELECT count(*) FROM chapters WHERE status='writing'\"" 2>/dev/null | tr -d '[:space:]')
    if ! echo "$WRITING_COUNT" | grep -qE '^[0-9]+$'; then
        # 审后修复 #7: query failed / returned non-numeric — show "?" (unknown),
        # never a misleading "0" that would read as "no in-flight writes".
        echo "${C_DIM}    ⚠ 无法确认进行中的写作数（查询失败，计数=?）；请手动确认后再重启（Ctrl-C 中止）。5 秒后继续…${C_RST}"
        sleep 5
    elif [ "$WRITING_COUNT" != "0" ]; then
        echo "${C_DIM}    ⚠ $WRITING_COUNT 章正处于 writing 状态；重启会丢弃这些进行中的写作（内存 job 随进程退出）。${C_RST}"
        echo "${C_DIM}      若不想丢，可等这些写作完成后再部署（Ctrl-C 中止）。5 秒后继续…${C_RST}"
        sleep 5
    fi
fi

step "remote: systemctl reload-or-restart $SERVICE"
run ssh "$HZ" "sudo systemctl reload-or-restart $SERVICE"
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
