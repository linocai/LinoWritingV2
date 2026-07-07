# Backend/deploy/ — HZ 部署三件套

> ⚠️ **S-3 尚未执行；本目录文件是 S-2 阶段产出的草稿。**
> HZ 上的实际部署在 S-3 phase 执行时落地。
> 在 S-3 落地之前 / 期间 / 之后，`/Users/linotsai/hz_info.md` 是 HZ 云端的**单一事实文件**，每次 HZ 改动后必须同步更新（见 PROJECT_PLAN.md §0.2.1 铁律）。

## 三件套清单

| 文件 | 用途 | S-3 部署到 HZ 的位置 |
|---|---|---|
| `linowriting-api.service` | systemd unit；uvicorn **单 worker（硬约束，永不得加 `--workers`）**，监听 `127.0.0.1:8787`，依赖 `postgresql@16-main.service`。`EnvironmentFile=/opt/linowriting/.env` | `/etc/systemd/system/linowriting-api.service`（root 拥有，0644） |

> ⚠️ **单 worker 硬约束（v1.3.2 LL P1，写作作业化）**：写作任务在进程内内存态注册表（`app/services/write_jobs.py` 的 `WriteJobRegistry`）里，一次写作在客户端断开后仍继续跑、并可跨请求重附着/取消。**systemd unit 永不得加 `--workers N` 或换多进程 gunicorn**——第二个进程有自己的空注册表，重附着/取消会静默错过 live job。启动 log 会打印一行提醒；`hz_info.md` 同步记死。部署重启会丢弃当时正在写作的内存 job（daemon 线程随进程退出），属预期部署窗口——`deploy-hz.sh` 重启前会查 `status='writing'` 的章数并提示。
| `nginx-linowriting.conf` | Nginx site；`lw.linotsai.top` HTTP→HTTPS + 443 反代 `127.0.0.1:8787`；SSE 友好（`proxy_buffering off` / 120s timeout） | `/etc/nginx/sites-available/linowriting`（root，0644）+ `sites-enabled/linowriting` symlink |
| `deploy-hz.sh` | 本地 → HZ 日常发版：rsync 代码 → 原子切换 → venv + `pip install -e .` → `alembic upgrade head` → `systemctl reload-or-restart`。支持 `--dry-run` | 留在 repo `Backend/deploy/` 下；从作者 mac 本地执行 |

## 使用

```bash
# S-2 阶段（本目录草稿）：本地静态验证三件套
cd Backend/deploy
bash -n deploy-hz.sh
./deploy-hz.sh --dry-run

# S-3 阶段（HZ 一次性配置完成后）：日常发版
./Backend/deploy/deploy-hz.sh
```

## 验收 / 本地静态检查（S-2）

```bash
cd Backend/deploy

# 1. bash 语法
bash -n deploy-hz.sh

# 2. shellcheck（可选；mac 装：brew install shellcheck）
command -v shellcheck && shellcheck deploy-hz.sh || echo "shellcheck not installed"

# 3. dry-run 跑到底
./deploy-hz.sh --dry-run

# 4. systemd unit 静态语法（mac 没有 systemd-analyze，可用 docker）
docker run --rm -v "$PWD/linowriting-api.service:/u.service:ro" \
    debian:bookworm-slim systemd-analyze verify /u.service

# 5. Nginx 语法（docker）
docker run --rm -v "$PWD/nginx-linowriting.conf:/etc/nginx/conf.d/test.conf:ro" \
    nginx:alpine nginx -t
```

systemd-analyze 可能 warn `/opt/linowriting` 不存在 —— 那是预期的（本地 mac 没有该路径）。
Nginx 可能 warn ssl_certificate 文件不存在 —— 也是预期的。
只要 `bash -n` 干净 + dry-run 跑到底 + nginx -t 报 `syntax is ok` / `test is successful` 即可放过。

## 完整 runbook

- **首次部署一次性配置（adduser / createdb / DNS / certbot / .env / systemd / sites-enabled）+ 日常发版流程**：见 `PROJECT_PLAN.md §5.S.5`。
- **HZ 云端真相文件**：`/Users/linotsai/hz_info.md`。
- **设计决策表（domain / db user / port / PG role / certbot）**：见 `PROJECT_PLAN.md §5.S.2`。
- **S-2 ↔ S-3 边界**：本目录文件 = S-2；任何 SSH 进 HZ 的动作 = S-3。
