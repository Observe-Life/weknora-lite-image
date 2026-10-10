#!/bin/sh
# ============================================================================
#  WeKnora Lite 容器入口脚本（非官方镜像）
#
#  做三件事：
#    1. 首次启动时生成持久化配置，并写入随机安全密钥；
#    2. 载入配置（显式传入的容器环境变量优先级更高）；
#    3. 兜底关键路径，然后启动服务。
# ============================================================================
set -eu

WORKDIR=/opt/weknora
ENV_FILE="${WEKNORA_ENV_FILE:-/data/.env.lite}"

cd "$WORKDIR"

# ---------------------------------------------------------------------------
# 1. 首次启动：生成配置文件 + 随机密钥
#
#    SYSTEM_AES_KEY / JWT_SECRET 若为空，上游会使用不安全的默认值。
#    这里在首次启动时随机生成并落盘到数据卷，之后一直复用，
#    这样重建容器不会导致已加密的凭据解不开。
# ---------------------------------------------------------------------------
if [ ! -f "$ENV_FILE" ]; then
    echo "[entrypoint] 未找到配置文件，正在生成：$ENV_FILE"
    mkdir -p "$(dirname "$ENV_FILE")"
    cp "$WORKDIR/.env.lite.example" "$ENV_FILE"

    AES_KEY="$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    JWT_KEY="$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')"

    sed -i "s|^SYSTEM_AES_KEY=.*|SYSTEM_AES_KEY=${AES_KEY}|" "$ENV_FILE"
    sed -i "s|^JWT_SECRET=.*|JWT_SECRET=${JWT_KEY}|" "$ENV_FILE"

    echo "[entrypoint] 已生成随机 SYSTEM_AES_KEY 与 JWT_SECRET"
    echo "[entrypoint] 如需调整 LLM 地址等参数，编辑：$ENV_FILE"
fi

# ---------------------------------------------------------------------------
# 2. 载入配置
#
#    逐行解析而不是直接 source，是为了让「docker run -e」传入的变量优先。
#    （直接 source 会把文件里的值盖到环境变量上，容器用户会觉得莫名其妙。）
# ---------------------------------------------------------------------------
while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
        ''|'#'*) continue ;;
    esac
    key="${line%%=*}"
    val="${line#*=}"
    # 跳过非法键名
    case "$key" in
        *[!A-Za-z0-9_]*) continue ;;
    esac
    # 环境里已有值就不覆盖
    if [ -z "$(printenv "$key" 2>/dev/null || true)" ]; then
        export "$key=$val"
    fi
done < "$ENV_FILE"

# ---------------------------------------------------------------------------
# 3. 关键路径兜底
# ---------------------------------------------------------------------------
export WEKNORA_WEB_DIR="${WEKNORA_WEB_DIR:-$WORKDIR/web}"
export DB_PATH="${DB_PATH:-/data/weknora.db}"
export LOCAL_STORAGE_BASE_DIR="${LOCAL_STORAGE_BASE_DIR:-/data/files}"

mkdir -p "$(dirname "$DB_PATH")" "$LOCAL_STORAGE_BASE_DIR"

# ---------------------------------------------------------------------------
# 4. 启动
# ---------------------------------------------------------------------------
echo "[entrypoint] 版本     : ${WK_VERSION:-unknown}"
echo "[entrypoint] 工作目录 : $WORKDIR"
echo "[entrypoint] 数据库   : $DB_PATH"
echo "[entrypoint] 文件存储 : $LOCAL_STORAGE_BASE_DIR"
echo "[entrypoint] 前端资源 : $WEKNORA_WEB_DIR"
echo "[entrypoint] 监听     : 容器内 8080（对外端口请在运行参数里映射）"

exec "$WORKDIR/WeKnora-lite"
