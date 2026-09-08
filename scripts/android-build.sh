#!/usr/bin/env bash
# =============================================================================
# 本地复现 Android 交叉编译 (cloudflare-ddns)
# -----------------------------------------------------------------------------
# 与 CI (.github/workflows/android.yml) 使用相同的工具链机制：
# 把每个 Android target 的 linker / CC / CXX / AR 指向 NDK 的 clang 包装脚本，
# 规避 ring 的 cc-rs 因 NDK clang 命名差异 (arm-linux-androideabi vs
# armv7a-linux-androideabi) 而失败的坑，并正确产出可执行文件。
#
# 注意: 本项目是纯 bin 守护进程，不能使用 cargo-ndk（它只复制 cdylib 产物），
#       因此这里直接生成 .cargo/config.toml 后用 cargo build --target 构建。
#
# 用法:
#   ./scripts/android-build.sh                  # 构建全部目标 (arm64-v8a + armeabi-v7a)
#   ./scripts/android-build.sh arm64-v8a        # 仅构建指定 ABI
#
# 依赖: curl, unzip, rustup (已添加 aarch64-linux-android / armv7-linux-androideabi)
# =============================================================================
set -euo pipefail

NDK_VERSION="${NDK_VERSION:-r27c}"
ANDROID_API="${ANDROID_API:-24}"

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

# 生成 .cargo/config.toml：复刻 cargo-ndk 的工具链配置（见 CI 文件头注释）
NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/${NDK_OS}-${NDK_ARCH}/bin"
echo "==> NDK_BIN = $NDK_BIN"
API="$ANDROID_API"

# 解析每个 target 对应的 NDK clang 包装脚本（API 级别不存在时回退到无 API 的版本）
clang_for() {
  local triple="$1" w
  w="$NDK_BIN/${triple}${API}-clang"
  [ -x "$w" ] || w="$NDK_BIN/${triple}-clang"
  echo "$w"
}
CC_AARCH64="$(clang_for aarch64-linux-android)"
CC_ARMV7="$(clang_for armv7a-linux-androideabi)"
echo "==> CC_AARCH64 = $CC_AARCH64"
echo "==> CC_ARMV7  = $CC_ARMV7"

mkdir -p .cargo
cat > .cargo/config.toml <<EOF
# 本地自动生成：NDK ${NDK_VERSION} 交叉编译工具链配置（Android targets）。
[target.aarch64-linux-android]
linker = "$CC_AARCH64"

[target.aarch64-linux-android.env]
CC_aarch64-linux-android     = "$CC_AARCH64"
CXX_aarch64-linux-android    = "${CC_AARCH64}++"
AR_aarch64-linux-android     = "$NDK_BIN/llvm-ar"
RANLIB_aarch64-linux-android = "$NDK_BIN/llvm-ranlib"

[target.armv7-linux-androideabi]
linker = "$CC_ARMV7"

[target.armv7-linux-androideabi.env]
CC_armv7-linux-androideabi     = "$CC_ARMV7"
CXX_armv7-linux-androideabi    = "${CC_ARMV7}++"
AR_armv7-linux-androideabi     = "$NDK_BIN/llvm-ar"
RANLIB_armv7-linux-androideabi = "$NDK_BIN/llvm-ranlib"
EOF

ABIS=("$@")
if [ ${#ABIS[@]} -eq 0 ]; then
  ABIS=(arm64-v8a armeabi-v7a)
fi

# 把 ABI 映射回 Rust target triple
TARGET_ARGS=()
for abi in "${ABIS[@]}"; do
  case "$abi" in
    arm64-v8a)   TARGET_ARGS+=(aarch64-linux-android);;
    armeabi-v7a) TARGET_ARGS+=(armv7-linux-androideabi);;
    *) echo "未知 ABI: $abi (支持 arm64-v8a / armeabi-v7a)" >&2; exit 1;;
  esac
done

echo "==> 构建 Android (API ${ANDROID_API}): ${TARGET_ARGS[*]}"
cargo build --release $(printf -- '--target %s ' "${TARGET_ARGS[@]}")

mkdir -p out
for target in "${TARGET_ARGS[@]}"; do
  src="target/$target/release/cloudflare-ddns"
  case "$target" in
    aarch64-linux-android)  abi=arm64-v8a;;
    armv7-linux-androideabi) abi=armeabi-v7a;;
  esac
  cp -v "$src" "out/cloudflare-ddns-$abi"
  echo "    产物: out/cloudflare-ddns-$abi"
done
echo "==> 完成。产物位于 out/ 目录。"
