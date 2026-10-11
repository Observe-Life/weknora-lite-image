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

本仓库的构建**按上游版本标签**进行，**升级不会自动发生**，需要手动触发。

### 1. 先备份（必做，不是可选项）

```bash
cd /path/to/weknora-lite
tar czf ~/weknora-backup-$(date +%F).tar.gz data/
```

数据库迁移是**单向**的。回退旧镜像时，新版已跑过的迁移不会自动撤销，
可能因 schema 不兼容而失败——那时只能靠这份备份恢复。

### 2. 触发云端构建

**Actions** 页面 → 左侧 **Build WeKnora Lite Image** → 右侧 **Run workflow**

| 输入 | 填什么 |
| --- | --- |
| `upstream_ref` | 新的上游标签，例如 `v0.9.0` |
| `image_tag` | 留空（自动取版本号去掉开头的 v） |

约 10~20 分钟完成（含 Rust 编译 anydoc），镜像自动推到 GHCR。

### 3. 记录当前镜像，留好回退路径

```bash
docker tag ghcr.io/observe-life/weknora-lite-image:0.8.2 weknora-lite:rollback
```

### 4. 检查 `.env.lite` 有没有新字段

`.env.lite` 是**首次启动时从 `.env.lite.example` 复制**出来的，已存在就**不再覆盖**。
所以新版若新增了环境变量，你手上那份不会有：

```bash
docker run --rm ghcr.io/observe-life/weknora-lite-image:<新版本> \
  cat /opt/weknora/.env.lite.example > /tmp/new.env.example

diff /tmp/new.env.example data/.env.lite   # 看有没有新增项
```

### 5. 换版本并重启

```bash
sed -i 's|:0.8.2|:<新版本>|' docker-compose.yml
docker compose pull && docker compose up -d
```

### 6. 验证（重点查两个会「静默失效」的能力）

```bash
# ① anydoc 引擎是否链接进来 —— 返回 1 才对
docker exec weknora-lite sh -c \
  'grep -ac "anydoc: markdown conversion failed" /opt/weknora/WeKnora-lite'

# ② 中文分词词典是否还在 —— 有输出才对
docker exec weknora-lite sh -c \
  'find / -name "jieba.dict.utf8" 2>/dev/null | head -1'

# ③ 服务健康
curl -fsS http://127.0.0.1:18080/health
```

**前两条必须查**：anydoc 缺失只会让 epub/docx/xlsx/pptx 解析失败，
jieba 词典缺失只会让中文检索搜不到——**两者都不报错**，只会安静地不可用。

### 回退

```bash
docker compose down
docker tag weknora-lite:rollback ghcr.io/observe-life/weknora-lite-image:0.8.2
sed -i 's|:<新版本>|:0.8.2|' docker-compose.yml
docker compose up -d
```

⚠️ 若新版已经跑过数据库迁移，回退后可能起不来，**这时用第 1 步的备份恢复 `data/`**。

### 升级时可能失效的三处补丁

`Dockerfile` 里有几处是针对上游**具体结构**的修补，上游若改动就会失效：

| 补丁 | 依赖上游什么 | 上游若改动会怎样 |
| --- | --- | --- |
| `COPY third_party/anydoc-go/go.mod` | `go.mod` 里有一条 `replace` 指向这个本地目录 | 若上游改成 git submodule，需给 checkout 加 `submodules: recursive` |
| `scripts/build-anydoc-lib.sh` | 上游 `third_party/anydoc-go/Cargo.toml` 的版本 pin，以及 `version.go` 与之的一致性校验 | anydoc 版本升级脚本会自动跟随；但若接口变了需调整 |
| 搬运 `/go/pkg/mod/github.com/yanyiwu` | gojieba 的词典路径在**编译期**被写死成模块缓存绝对路径 | 上游若换分词库或改版本号，这行要跟着改 |

---

## 构建细节

`Dockerfile` 是三阶段构建：

| 阶段 | 基础镜像 | 做什么 |
| --- | --- | --- |
| frontend | `node:22-bookworm` | `npm ci` + `npm run build` → 静态资源 |
| backend | `golang:1.26-trixie` | 装 `libsqlite3-dev` 与 Rust 工具链；编译 anydoc 静态库；`CGO_ENABLED=1` + `-tags "sqlite_fts5 anydoc"` |
| runtime | `debian:trixie-slim` | `ca-certificates tzdata curl libsqlite3-0 libstdc++6`；搬运 gojieba 词典 |

### 配方里这些项是「必需」的

每一条都是实际踩出来的坑，**少一条镜像就能构建成功但功能是坏的**：

| 项 | 缺了会怎样 |
| --- | --- |
| `-tags sqlite_fts5` | 中文关键词检索**静默失效**（不报错，只是搜不到） |
| `libsqlite3-dev`（编译阶段） | `sqlite-vec.h:7:10: fatal error: sqlite3.h: No such file or directory` |
| `libsqlite3-0` + `libstdc++6`（运行阶段） | 容器启动即报 `error while loading shared libraries` |
| 编译与运行同为 Debian **trixie** | glibc 版本不匹配，二进制直接起不来 |
| `-X ...protoregistry.conflictPolicy=warn` | qdrant / milvus 生成代码的 proto 描述符注册冲突 |
| 搬运 `/go/pkg/mod/github.com/yanyiwu` | 中文分词**静默失效**（词典路径编译期写死） |
| `COPY third_party/anydoc-go/go.mod` | `go mod download` 报 `no such file or directory` 直接退出 |
| 覆盖上游的 `.dockerignore` | 上游排除了整个 `frontend/` 目录，前端编译阶段拿不到源码 |
| `WITH_ANYDOC=1` + Rust 工具链 | epub / docx / xlsx / pptx 无法在进程内解析（退化为必须有 docreader） |

> **关于 anydoc**：它是**可选**引擎，上游 `docker/Dockerfile.app` 默认开启。
> 不带这个标签时走 `backend_stub.go` 空实现，引擎列表里会显示"不可用"。
> 注意 **anydoc 不支持 PDF**——上游明确排除，因为它没有 PDF 文档模型，
> 硬转会丢掉图片、表格与版式。PDF 仍需 docreader / MinerU / PaddleOCR-VL。

> **关于 `.dockerignore`**：上游源码根目录的那份排除了整个 `frontend/` 目录
> （因为官方其他镜像的 Dockerfile 都不引用它）。本仓库用 `dockerignore` 文件在构建时覆盖。

---

## 解析引擎的真实可用性

Lite 注册了全部 8 个解析引擎，但开箱只有两个真正可用：

| 引擎 | 默认状态 | 说明 |
| --- | --- | --- |
| **Simple** | ✅ 可用 | Go 原生，处理 md / txt / csv / json / 图片 / 音频，**零依赖** |
| **anydoc** | ✅ 可用（本镜像已开启） | 进程内解析 epub / docx / xlsx / pptx 等 |
| 内置（builtin） | ⚠️ 界面显示"可用"，实际连不上 | 见下 |
| MinerU / MinerU Cloud / PaddleOCR-VL / PaddleOCR-VL Cloud / WeKnora Cloud | ❌ 不可用 | 需自行配置服务地址或 API Key |

### ⚠️「内置」引擎的可用性显示不准

`.env.lite` 模板默认写着 `DOCREADER_ADDR=127.0.0.1:50051`。而代码里
`IsConnected()` 只判断"连接对象是否存在"，gRPC 又是**懒连接**（创建对象时不真正拨号），
所以**只要地址非空，界面就永远显示"内置可用"，哪怕根本没有 docreader 在跑**。
等你真的上传文件，它才去拨号，然后撞上 `dial tcp 127.0.0.1:50051: connection refused`。

**建议把地址留空**，让它如实显示"不可用"，也就不会误选：

```env
DOCREADER_ADDR=
```

### 解析能力的真实边界

| 格式 | 本镜像默认能解析吗 |
| --- | --- |
| md / txt / csv / json | ✅ Simple |
| epub / docx / xlsx / pptx | ✅ anydoc |
| 图片（jpg/png/…） | ✅ Simple（OCR / 描述需另配视觉模型） |
| 音频（mp3/wav/…） | ✅ Simple（转写需另配 ASR 模型） |
| **PDF** | ❌ anydoc 不支持，需 docreader / MinerU / PaddleOCR-VL |
| html / mhtml / xmind | ❌ 仅内置引擎支持，需 docreader |

### 上传时的引擎选择有个坑

上传对话框会把引擎规则写进**每个文件自己**的
`metadata.process_overrides.parser_engine_rules`，而**文件级规则会覆盖知识库级配置**。

所以一旦某个文件被标成 `builtin`，**重试多少次都还是走 `builtin`**——
必须重新上传（或在重解析时改规则）才能换引擎。

---

## 已知限制

- 仅构建 `linux/amd64`。需要 arm64 请自行在 workflow 里加平台。
- 非官方镜像，上游的 Dockerfile / Compose 变更不会自动同步到这里。
- **anydoc 不支持 PDF**（上游设计如此，因其没有 PDF 文档模型，硬转会丢图片/表格/版式）。
- Lite 版的能力边界（无共享空间、无多空间协作）由上游决定，与本镜像无关。
- **模型网关若有速率限制**，大批量导入会撞 429。WeKnora **没有事前限速器**，
  `ingest_batch_size` / `ingest_map_parallel` / `ingest_reduce_parallel` / `ingest_max_inflight`
  只控制**并发 worker 数**，不能精确控制每分钟请求数。建议关闭 wiki 抽取与问题生成
  （两者失败不影响文档被检索到，只影响召回质量），或改用不限流的模型服务。

---

## 许可

镜像内包含的 WeKnora 代码遵循 [Apache-2.0](https://github.com/Tencent/WeKnora/blob/main/LICENSE)。
本仓库的构建脚本同样以 Apache-2.0 提供。
