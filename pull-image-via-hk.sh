#!/bin/bash

# Docker 镜像通过香港服务器中转脚本
# 用法: ./pull-image-via-hk.sh

set -e

echo "🌍 Docker Image Pull via HK Server"
echo "=================================="
echo ""

# 获取用户输入
read -p "📦 Docker image name (e.g., confluentinc/cp-kafka:7.6.0): " IMAGE_NAME
read -p "🔧 Remote server address (e.g., user@hk-server.com): " REMOTE_SERVER
read -p "🔑 SSH port (default 22): " SSH_PORT
SSH_PORT=${SSH_PORT:-22}

read -p "📂 Remote temp directory (default /tmp): " REMOTE_TMPDIR
REMOTE_TMPDIR=${REMOTE_TMPDIR:-/tmp}

# 生成镜像文件名
IMAGE_FILENAME=$(echo "$IMAGE_NAME" | sed 's/[/:.]/-/g').tar.gz

echo ""
echo "📋 Configuration:"
echo "  Image: $IMAGE_NAME"
echo "  Remote: $REMOTE_SERVER (port $SSH_PORT)"
echo "  Remote temp dir: $REMOTE_TMPDIR"
echo "  File: $IMAGE_FILENAME"
echo ""

# 步骤1: 在远程服务器下载镜像
echo "⏳ Step 1: Pulling image on remote server..."
ssh -p "$SSH_PORT" "$REMOTE_SERVER" "docker pull '$IMAGE_NAME'" || {
    echo "❌ Failed to pull image on remote server"
    exit 1
}

# 步骤2: 在远程服务器保存镜像为tar文件
echo ""
echo "⏳ Step 2: Saving image on remote server..."
REMOTE_TAR_PATH="$REMOTE_TMPDIR/$IMAGE_FILENAME"
ssh -p "$SSH_PORT" "$REMOTE_SERVER" "docker save '$IMAGE_NAME' | gzip > '$REMOTE_TAR_PATH'" || {
    echo "❌ Failed to save image on remote server"
    exit 1
}

# 步骤3: 从远程服务器传输到本地
echo ""
echo "⏳ Step 3: Transferring image to local machine..."
echo "  (This may take a while depending on file size and network speed)"
scp -P "$SSH_PORT" "$REMOTE_SERVER:$REMOTE_TAR_PATH" "./$IMAGE_FILENAME" || {
    echo "❌ Failed to transfer image"
    ssh -p "$SSH_PORT" "$REMOTE_SERVER" "rm -f '$REMOTE_TAR_PATH'"
    exit 1
}

# 步骤4: 在本地加载镜像
echo ""
echo "⏳ Step 4: Loading image locally..."
docker load -i "./$IMAGE_FILENAME" || {
    echo "❌ Failed to load image"
    exit 1
}

# 步骤5: 清理
echo ""
echo "🧹 Step 5: Cleaning up..."
rm -f "./$IMAGE_FILENAME"
ssh -p "$SSH_PORT" "$REMOTE_SERVER" "rm -f '$REMOTE_TAR_PATH'" || true

echo ""
echo "✅ Success! Image loaded: $IMAGE_NAME"
docker images | grep -E "^$(echo "$IMAGE_NAME" | cut -d: -f1)" | head -1

echo ""
echo "💡 Tip: You can now use 'docker compose up' to start services with this image"
