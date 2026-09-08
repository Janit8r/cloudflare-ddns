#!/usr/bin/env bash
# =============================================================================
# 本地复现 Android 交叉编译 (cloudflare-ddns)
# -----------------------------------------------------------------------------
# 用于在本地 Linux/macOS 上复现 CI 中的 Android 构建，便于本地调试。
#
# 用法:
#   ./scripts/android-build.sh                # 构建全部目标 (arm64-v8a + armeabi-v7a)
#   ./scripts/android-build.sh arm64-v8a      # 仅构建指定 ABI
#
# 依赖: curl, unzip, rustup (已添加对应 target)
# =============================================================================
set -euo pipefail

NDK_VERSION="${NDK_VERSION:-r27c}"
ANDROID_API="${ANDROID_API:-24}"

# 根据宿主机选择 NDK 预编译包
HOST="$(uname -s)"
case "$HOST" in
  Linux)  NDK_OS="linux";;
  Darwin) NDK_OS="darwin";;
  *)      echo "不支持的宿主机系统: $HOST" >&2; exit 1;;
esac

# 宿主机架构 (x86_64 或 aarch64)。32 位 armv8l 无官方 NDK 包。
HOST_ARCH="$(uname -m)"
if [ "$HOST_ARCH" = "x86_64" ]; then
  NDK_ARCH="x86_64"
elif [ "$HOST_ARCH" = "aarch64" ] || [ "$HOST_ARCH" = "arm64" ]; then
  NDK_ARCH="aarch64"
else
  echo "不支持的宿主机架构: $HOST_ARCH (官方 NDK 仅提供 x86_64 / aarch64 宿主机包)" >&2
  exit 1
fi

NDK_DIR="android-ndk-${NDK_VERSION}"
NDK_URL="https://dl.google.com/android/repository/android-ndk-${NDK_VERSION}-${NDK_OS}-${NDK_ARCH}.zip"

# 若 NDK 不存在则下载
if [ ! -d "$NDK_DIR" ]; then
  echo "==> 下载 NDK: $NDK_URL"
  curl -fSL -o ndk.zip "$NDK_URL"
  unzip -q ndk.zip
  rm -f ndk.zip
fi

NDK_BIN="$PWD/$NDK_DIR/toolchains/llvm/prebuilt/${NDK_OS}-${NDK_ARCH}/bin"
export ANDROID_NDK_HOME="$PWD/$NDK_DIR"

declare -A TARGETS=(
  [arm64-v8a]="aarch64-linux-android|aarch64-linux-android"
  [armeabi-v7a]="armv7-linux-androideabi|armv7a-linux-androideabi"
)

TARGETS_TO_BUILD=("$@")
if [ ${#TARGETS_TO_BUILD[@]} -eq 0 ]; then
  TARGETS_TO_BUILD=(arm64-v8a armeabi-v7a)
fi

mkdir -p out
for abi in "${TARGETS_TO_BUILD[@]}"; do
  IFS='|' read -r target clang <<< "${TARGETS[$abi]}"
  [ -z "${target:-}" ] && { echo "未知 ABI: $abi" >&2; exit 1; }

  # 配置该 target 的链接器/编译器 (与 CI 一致)
  export "CARGO_TARGET_$(echo "$target" | tr '[:lower:]' '[:upper:]' | tr '-' '_')_LINKER=$NDK_BIN/${clang}${ANDROID_API}-clang"
  export "CC_$(echo "$target" | tr '[:lower:]' '[:upper:]' | tr '-' '_')=${NDK_BIN}/${clang}${ANDROID_API}-clang"
  export "AR_$(echo "$target" | tr '[:lower:]' '[:upper:]' | tr '-' '_')=${NDK_BIN}/llvm-ar"

  echo "==> 构建 $abi ($target, API $ANDROID_API)"
  cargo build --release --target "$target"
  cp "target/$target/release/cloudflare-ddns" "out/cloudflare-ddns-$abi"
  echo "    产物: out/cloudflare-ddns-$abi"
done

echo "==> 完成。产物位于 out/ 目录。"
