# Backend/deploy/ — HZ 部署三件套

> **🗄️ ARCHIVED (2026-07-11) — 生产环境已下线。** 本目录三件套仅为历史发版留档，**请勿再对 HZ 执行 `deploy-hz.sh`**：`lw.linotsai.top` 的 systemd / Nginx / 证书 / PostgreSQL 库+role / `/opt/linowriting` / 系统用户均已于 2026-07-11 彻底删除，目标已不存在。退役前 DB 已 `pg_dump` 归档至 `~/Lino/Archive/linowriting_decommission_20260711/`。云端现状见 `~/Lino/hz_info.md`。
>
> 生产环境自 v0.8 起曾运行于 HZ 阿里云 ECS（`lw.linotsai.top`，systemd + Nginx + certbot + PostgreSQL 16，无 Docker）。
> `~/Lino/hz_info.md` 是 HZ 云端**单一事实文件**，任何 HZ 改动后必须同步更新（PROJECT_PLAN §0.2.1 铁律）。

## 三件套

| 文件 | 用途 | HZ 上的位置 |
|---|---|---|
| `linowriting-api.service` | systemd unit；uvicorn **单 worker（硬约束，永不得加 `--workers`）**，监听 `127.0.0.1:8787` | `/etc/systemd/system/linowriting-api.service` |
| `nginx-linowriting.conf` | Nginx site；HTTP→HTTPS + 443 反代；SSE 友好（`proxy_buffering off`、`proxy_read_timeout 300s`） | `/etc/nginx/sites-available/linowriting` + sites-enabled symlink |
| `deploy-hz.sh` | 日常发版：rsync 代码 → venv `pip install -e .` → `alembic upgrade head` → `systemctl reload-or-restart`。支持 `--dry-run` | 留在本目录，从本机执行 |

> ⚠️ **单 worker 硬约束（v1.3.2 起）**：写作任务在进程内内存注册表（`app/services/write_jobs.py` 的 `WriteJobRegistry`），断开后仍继续跑、可跨请求重附着/取消。**systemd unit 永不得加 `--workers N` 或换多进程 gunicorn**——第二个进程有自己的空注册表，重附着/取消会静默错过 live job。部署重启会丢弃当时在写的内存 job（预期窗口，`deploy-hz.sh` 重启前会查 `status='writing'` 的章数并提示）。

> ⚠️ **已知遗留**：`deploy-hz.sh` 的 rsync 排除 `deploy/` 目录——本目录文件（unit/nginx conf）改动不随发版自动同步，需手动 scp + reload（v1.3.2 收口记录在案）。

## 日常发版

```bash
./Backend/deploy/deploy-hz.sh          # 正式
./Backend/deploy/deploy-hz.sh --dry-run
# 发版后验证：curl https://lw.linotsai.top/api/v1/health（带 Bearer）看 version
```
