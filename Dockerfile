# syntax=docker/dockerfile:1
#
# ============================================================================
#  WeKnora Lite —— 非官方 Docker 镜像构建文件
# ----------------------------------------------------------------------------
#  上游项目：https://github.com/Tencent/WeKnora   (Apache-2.0)
#
#  背景：上游只为 Lite 版提供「单二进制 + web/ + config/ + migrations/」的
#        裸机交付物（配 systemd 服务文件），官方并未提供 Lite 的容器方案。
#        本文件由社区自行编写，不隶属于腾讯。
#
#  构建上下文必须是 WeKnora 源码根目录，例如：
#      docker build -t weknora-lite:local .
#
#  两个必须守住的点（否则镜像能构建但功能是坏的）：
#    1. 后端必须带 -tags sqlite_fts5，否则中文关键词检索会静默失效；
#    2. 编译阶段与运行阶段必须同为 Debian trixie，否则 glibc 版本不匹配，
#       二进制在容器里直接起不来。
# ============================================================================


# ============================================================================
#  阶段 1 / 前端：Vite 打包出 web/ 静态资源
# ============================================================================
FROM node:22-bookworm AS frontend

WORKDIR /build/frontend

# 先只复制依赖清单，让 npm ci 这层能被缓存复用
COPY frontend/package.json frontend/package-lock.json ./
RUN npm ci --no-audit --no-fund

COPY frontend/ ./
RUN npm run build


# ============================================================================
#  阶段 2 / 后端：Go + CGO 静态编译
# ============================================================================
FROM golang:1.26-trixie AS backend

ARG WK_VERSION=dev
ARG WK_COMMIT=unknown
ARG WK_BUILD_TIME=unknown

ENV CGO_ENABLED=1 \
    EDITION=lite \
    CGO_CFLAGS=-Wno-deprecated-declarations

# 编译阶段必须装 libsqlite3-dev：
# sqlite-vec 这个 cgo 包直接 #include "sqlite3.h"，要的是系统 SQLite 头文件，
# mattn/go-sqlite3 自带的 amalgamation 顶不上。缺了它会报
#   ./sqlite-vec.h:7:10: fatal error: sqlite3.h: No such file or directory
# 官方 docker/Dockerfile.app 的编译阶段同样装了 libsqlite3-dev。
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends libsqlite3-dev; \
    rm -rf /var/lib/apt/lists/*

WORKDIR /build

# 依赖层单独缓存，源码改动不会触发重新下载模块。
#
# 注意这里的第二行 COPY，缺了它构建必定失败：
# go.mod 末尾有一条 replace，把 github.com/firecrawl/anydoc/go 指向本地目录
# ./third_party/anydoc-go。go mod download 解析到这条 replace 时会去读那个
# 目录下的 go.mod，目录不存在就报 "no such file or directory" 直接退出。
#
# 只复制它的 go.mod 就够（官方 docker/Dockerfile.app 也是这么做的），
# 不必把整个 Rust 源码塞进依赖层 —— 而且 anydoc 是可选功能，
# 只有带 anydoc 构建标签才会真正链接那个 Rust 静态库，本镜像不带该标签。
COPY go.mod go.sum ./
COPY third_party/anydoc-go/go.mod ./third_party/anydoc-go/go.mod
RUN go mod download

COPY . .
# 前端产物落到 web/，运行时由 WEKNORA_WEB_DIR 指向
COPY --from=frontend /build/frontend/dist ./web

RUN set -eux; \
    LDFLAGS="-w -s \
      -X github.com/Tencent/WeKnora/internal/handler.Version=${WK_VERSION} \
      -X github.com/Tencent/WeKnora/internal/handler.Edition=lite \
      -X github.com/Tencent/WeKnora/internal/handler.CommitID=${WK_COMMIT} \
      -X github.com/Tencent/WeKnora/internal/handler.BuildTime=${WK_BUILD_TIME} \
      -X google.golang.org/protobuf/reflect/protoregistry.conflictPolicy=warn"; \
    go build -tags "sqlite_fts5" -ldflags "$LDFLAGS" -o /out/WeKnora-lite ./cmd/server; \
    ls -lh /out/WeKnora-lite


# ============================================================================
#  阶段 3 / 运行：debian trixie-slim（与编译阶段同代，glibc 对齐）
# ============================================================================
FROM debian:trixie-slim AS runtime

ARG WK_VERSION=dev
ARG WK_COMMIT=unknown

LABEL org.opencontainers.image.title="WeKnora Lite (unofficial)" \
      org.opencontainers.image.description="Unofficial container image for Tencent WeKnora Lite, the single-binary edition. Not affiliated with Tencent." \
      org.opencontainers.image.source="https://github.com/Observe-Life/weknora-lite-image" \
      org.opencontainers.image.url="https://github.com/Tencent/WeKnora" \
      org.opencontainers.image.licenses="Apache-2.0" \
      org.opencontainers.image.version="${WK_VERSION}" \
      org.opencontainers.image.revision="${WK_COMMIT}"

RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates tzdata curl libsqlite3-0; \
    rm -rf /var/lib/apt/lists/*; \
    groupadd -g 1000 weknora; \
    useradd -u 1000 -g 1000 -M -s /usr/sbin/nologin weknora

WORKDIR /opt/weknora

# 运行期必需的四件套。路径全部保持相对工作目录 ——
# internal/database/migration.go 里写死了 "file://migrations/sqlite"，
# 是相对路径，所以 WORKDIR 不能随意改。
COPY --from=backend /out/WeKnora-lite ./WeKnora-lite
COPY --from=frontend /build/frontend/dist ./web
COPY config ./config
COPY migrations/sqlite ./migrations/sqlite
COPY .env.lite.example ./.env.lite.example
COPY entrypoint.sh /usr/local/bin/entrypoint.sh

# gojieba（中文分词）在编译期把词典目录的绝对路径写死成模块缓存路径，
# 运行时必须能在同一个路径下找到那些词典文件，否则中文分词静默失效。
# 官方 docker/Dockerfile.app 也做了同样的一次搬运。
COPY --from=backend /go/pkg/mod/github.com/yanyiwu /go/pkg/mod/github.com/yanyiwu

RUN set -eux; \
    chmod 0755 /usr/local/bin/entrypoint.sh ./WeKnora-lite; \
    mkdir -p /data/files; \
    chown -R weknora:weknora /opt/weknora /data

# 默认值。注意 WEKNORA_ENV_FILE 指向 /data，配置随数据卷一起持久化。
ENV WEKNORA_WEB_DIR=/opt/weknora/web \
    WEKNORA_ENV_FILE=/data/.env.lite \
    DB_PATH=/data/weknora.db \
    LOCAL_STORAGE_BASE_DIR=/data/files \
    TZ=Asia/Shanghai

VOLUME ["/data"]
EXPOSE 8080

HEALTHCHECK --interval=30s --timeout=5s --start-period=25s --retries=3 \
    CMD curl -fsS http://127.0.0.1:8080/health || exit 1

USER weknora
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
