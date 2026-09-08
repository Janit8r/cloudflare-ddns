#!/usr/bin/env bash
# =============================================================================
# 本地复现 Android 交叉编译 (cloudflare-ddns)
# -----------------------------------------------------------------------------
# 与 CI (.github/workflows/android.yml) 使用相同的工具链机制 (cargo-ndk)，
# 以避免 ring 的 cc-rs 构建脚本因 NDK clang 命名差异而失败。
#
# 用法:
#   ./scripts/android-build.sh                  # 构建全部目标 (arm64-v8a + armeabi-v7a)
#   ./scripts/android-build.sh arm64-v8a        # 仅构建指定 ABI
#
# 依赖: curl, unzip, rustup (已添加 aarch64-linux-android / armv7-linux-androideabi)
#       cargo-ndk (脚本会自动检测，缺失时给出安装提示)
# =============================================================================
set -euo pipefail

NDK_VERSION="${NDK_VERSION:-r27c}"
ANDROID_API="${ANDROID_API:-24}"
CARGO_NDK_VERSION="${CARGO_NDK_VERSION:-4.1.2}"

# 根据宿主机选择 NDK 预编译包 (官方仅提供 x86_64 / aarch64 宿主包)
HOST="$(uname -s)"
case "$HOST" in
  Linux)  NDK_OS="linux";;
  Darwin) NDK_OS="darwin";;
  *)      echo "不支持的宿主机系统: $HOST" >&2; exit 1;;
esac
HOST_ARCH="$(uname -m)"
if [ "$HOST_ARCH" = "x86_64" ]; then
  NDK_ARCH="x86_64"
elif [ "$HOST_ARCH" = "aarch64" ] || [ "$HOST_ARCH" = "arm64" ]; then
  NDK_ARCH="aarch64"
else
  echo "不支持的宿主机架构: $HOST_ARCH (官方 NDK 仅提供 x86_64 / aarch64 宿主包)" >&2
  exit 1
fi

NDK_DIR="android-ndk-${NDK_VERSION}"
if [ ! -d "$NDK_DIR" ]; then
  echo "==> 下载 NDK: https://dl.google.com/android/repository/android-ndk-${NDK_VERSION}-${NDK_OS}-${NDK_ARCH}.zip"
  curl -fSL -o ndk.zip "https://dl.google.com/android/repository/android-ndk-${NDK_VERSION}-${NDK_OS}-${NDK_ARCH}.zip"
  unzip -q ndk.zip
  rm -f ndk.zip
fi
export ANDROID_NDK_HOME="$PWD/$NDK_DIR"

# 确保 cargo-ndk 已安装
if ! command -v cargo-ndk >/dev/null 2>&1; then
  echo "==> 未检测到 cargo-ndk，正在安装 (版本 ${CARGO_NDK_VERSION})..."
  cargo install cargo-ndk --version "${CARGO_NDK_VERSION}" --locked
fi

ABIS=("$@")
if [ ${#ABIS[@]} -eq 0 ]; then
  ABIS=(arm64-v8a armeabi-v7a)
fi
TARGET_ARGS=()
for abi in "${ABIS[@]}"; do
  TARGET_ARGS+=(-t "$abi")
done

echo "==> 构建 Android (API ${ANDROID_API}): ${ABIS[*]}"
cargo ndk --platform "$ANDROID_API" "${TARGET_ARGS[@]}" -o ./android-build build --release

mkdir -p out
find ./android-build -type f -name cloudflare-ddns | while read -r bin; do
  abi="$(basename "$(dirname "$bin")")"
  cp "$bin" "out/cloudflare-ddns-$abi"
  echo "    产物: out/cloudflare-ddns-$abi"
done
echo "==> 完成。产物位于 out/ 目录。"
