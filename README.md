# WeKnora Lite — 非官方 Docker 镜像

> **声明：本仓库不是腾讯官方项目。** 它只是把开源的 [Tencent/WeKnora](https://github.com/Tencent/WeKnora)
> 的 **Lite（单二进制版）** 打包成 Docker 镜像，方便在 NAS 上部署。源码版权归腾讯所有，遵循 Apache-2.0。

---

## 为什么会有这个仓库

上游的 WeKnora 有两条产品线：

| | Lite | 标准版 |
| --- | --- | --- |
| 形态 | **单二进制**，零外部依赖 | 多服务，Docker Compose |
| 数据库 | 内置 SQLite | PostgreSQL 等 |
| 官方容器支持 | ❌ **没有** | ✅ 有 |

也就是说，**官方只给了 Lite 的裸机交付物**（一个可执行文件 + `web/` + `config/`，配一个 systemd 服务文件），
`docker/` 目录里的 Dockerfile 全是标准版的。而官方发布的 40 个 Release 里，
**一个二进制附件都没有上传过**。

想在 NAS 上用容器跑 Lite，就只能自己编译。本仓库用 GitHub Actions 把这件事自动化了：
**编译全程跑在 GitHub 的云端机器上，你的 NAS 不需要安装 Go、Node 或任何编译工具，也不占用 NAS 的内存。**

---

## 镜像里是什么

一个容器，跑起来就是完整的 WeKnora Lite：

```
/opt/weknora
├── WeKnora-lite        # Go 编译产物（CGO + sqlite_fts5）
├── web/                # Vite 打包出的前端
├── config/             # 默认配置
├── migrations/sqlite/  # SQLite 迁移脚本
└── .env.lite.example   # 配置模板

/data                   # 数据卷：数据库、上传的文件、生成的配置
```

几个关键决策：

- **带 `sqlite_fts5` 编译标签**：不加的话中文关键词检索会静默失效（不报错，只是搜不到）。
- **编译与运行同为 Debian trixie**：CGO 产物依赖 glibc，两阶段版本不一致会导致二进制直接起不来。
- **首次启动自动生成 `SYSTEM_AES_KEY` 和 `JWT_SECRET`**：上游留空时会用不安全的默认值，
  这里随机生成并落盘到数据卷，重建容器也不会导致已加密的凭据解不开。

---

## 用法

### 方式一：docker compose（推荐）

```bash
mkdir weknora-lite && cd weknora-lite
curl -O https://raw.githubusercontent.com/Observe-Life/weknora-lite-image/main/docker-compose.yml
docker compose up -d
```

### 方式二：docker run

```bash
docker run -d \
  --name weknora-lite \
  --restart unless-stopped \
  -p 18080:8080 \
  -v /vol1/docker/weknora-lite/data:/data \
  -e TZ=Asia/Shanghai \
  ghcr.io/observe-life/weknora-lite-image:0.8.2
```

然后浏览器打开：**http://你的NAS地址:18080**

> 容器内固定监听 8080，对外端口在运行参数里映射即可。
> 上面用 18080 是为了避开常见的端口占用。

---

## 配置

配置文件在 **`./data/.env.lite`**（首次启动自动生成），随数据卷一起持久化。

**优先级：容器环境变量 > `.env.lite`**。
所以临时改个参数用 `-e` 最方便，长期配置就写进 `.env.lite`。

常见项：

| 变量 | 说明 | 默认值 |
| --- | --- | --- |
| `OLLAMA_BASE_URL` | 本地 LLM / 向量模型地址 | `http://127.0.0.1:11434` |
| `LOG_LEVEL` | `debug` / `info` / `warn` / `error` | `debug` |
| `GIN_MODE` | `debug` / `release` | `debug` |
| `DB_PATH` | SQLite 数据库路径 | `/data/weknora.db` |
| `LOCAL_STORAGE_BASE_DIR` | 上传文件存放目录 | `/data/files` |
| `SYSTEM_AES_KEY` | 凭据加密密钥（首次启动自动生成） | 随机 |
| `JWT_SECRET` | 登录令牌签名密钥（首次启动自动生成） | 随机 |

> ⚠️ Lite 默认指向 `127.0.0.1:11434` 的 Ollama。容器里的 `127.0.0.1` 指的是容器自己，
> 所以要么把 Ollama 也放进同一个网络，要么把地址改成 NAS 的局域网 IP。

---

## 数据备份

全部数据都在 `./data` 目录里，直接打包即可：

```bash
tar czf weknora-lite-backup-$(date +%F).tar.gz data/
```

---

## 升级到新的上游版本

本仓库的构建是**按上游版本标签**来的。升级步骤：

1. 打开仓库的 **Actions** 页面 → 左侧选 **Build WeKnora Lite Image** → 右侧 **Run workflow**
2. `upstream_ref` 填新的上游标签（例如 `v0.9.0`），`image_tag` 留空
3. 等构建完成（约 10~15 分钟），镜像自动推到 GHCR
4. NAS 上改 `docker-compose.yml` 里的镜像标签，然后：

```bash
docker compose pull && docker compose up -d
```

---

## 构建细节

`Dockerfile` 是三阶段构建：

| 阶段 | 基础镜像 | 做什么 |
| --- | --- | --- |
| frontend | `node:22-bookworm` | `npm ci` + `npm run build` → 静态资源 |
| backend | `golang:1.26-trixie` | `CGO_ENABLED=1` + `-tags sqlite_fts5` → 二进制 |
| runtime | `debian:trixie-slim` | 只装 ca-certificates / tzdata / curl |

> 注意：上游源码根目录的 `.dockerignore` **排除了整个 `frontend/` 目录**，
> 直接沿用会导致前端编译阶段拿不到源码。本仓库用 `dockerignore` 文件在构建时覆盖它。

---

## 已知限制

- 仅构建 `linux/amd64`。需要 arm64 请自行在 workflow 里加平台。
- 非官方镜像，上游的 Dockerfile / Compose 变更不会自动同步到这里。
- Lite 版本身的能力边界（无共享空间、仅 Simple 解析引擎、中文分词为 bigram）由上游决定，与本镜像无关。

---

## 许可

镜像内包含的 WeKnora 代码遵循 [Apache-2.0](https://github.com/Tencent/WeKnora/blob/main/LICENSE)。
本仓库的构建脚本同样以 Apache-2.0 提供。
