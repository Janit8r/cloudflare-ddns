#!/usr/bin/env bash
# =============================================================================
# 本地复现 Android 交叉编译 (cloudflare-ddns)
# -----------------------------------------------------------------------------
# 与 CI (.github/workflows/android.yml) 使用相同的工具链机制：
# 把每个 Android target 的 linker / CC / CXX / AR 作为【真实环境变量】注入
# （CC_<triple> / CARGO_TARGET_<TRIPLE>_LINKER 等指向 NDK 的 clang 包装脚本），
# 规避 ring 的 cc-rs 因 NDK clang 命名差异 (arm-linux-androideabi vs
# armv7a-linux-androideabi) 与 cargo 不支持 [target.<triple>.env] 而失败的坑，正确产出可执行文件。
#
# 注意: 本项目是纯 bin 守护进程，不能使用 cargo-ndk（它只复制 cdylib 产物）；
#       且 cargo 配置不支持 [target.<triple>.env]，必须用真实环境变量注入。
#
# 用法:
#   ./scripts/android-build.sh                  # 构建全部目标 (arm64-v8a + armeabi-v7a + x86)
#   ./scripts/android-build.sh arm64-v8a        # 仅构建指定 ABI
#
# 目标映射:
#   arm64-v8a   -> aarch64-linux-android
#   armeabi-v7a -> armv7-linux-androideabi     (NDK clang 前缀是 armv7a-...)
#   x86         -> i686-linux-android           (32 位 x86；NDK r27 仍支持该 ABI)
#
# 依赖: curl, unzip, rustup (已添加 aarch64-linux-android / armv7-linux-androideabi / i686-linux-android)
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

# 注入工具链环境变量（见 CI 注释）：Cargo 配置不支持 [target.<triple>.env]，且 bash 的
# export 不支持连字符变量名（CC_armv7-linux-androideabi / CC_i686-linux-android），因此必须用
# `env VAR=val ...` 形式注入。变量名用 Rust target triple，值指向 NDK 包装脚本
# （armv7a-linux-androideabi<api>-clang / i686-linux-android<api>-clang），cc-rs 通过 CC_<triple> 读取。
NDK_BIN="$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/${NDK_OS}-${NDK_ARCH}/bin"
echo "==> NDK_BIN = $NDK_BIN"
API="$ANDROID_API"

# 解析每个 target 对应的 NDK clang 包装脚本（API 级别不存在时回退到无 API 的版本）
# 注意 armv7 的 NDK clang 前缀是 armv7a-（多一个 a），而 Rust triple 是 armv7-。
clang_for() {
  local triple="$1" w
  w="$NDK_BIN/${triple}${API}-clang"
  [ -x "$w" ] || w="$NDK_BIN/${triple}-clang"
  echo "$w"
}
CC_A="$(clang_for aarch64-linux-android)"
CC_V7="$(clang_for armv7a-linux-androideabi)"
CC_X86="$(clang_for i686-linux-android)"
echo "==> aarch64 clang: $CC_A"
echo "==> armv7   clang: $CC_V7"
echo "==> i686    clang: $CC_X86"

ABIS=("$@")
if [ ${#ABIS[@]} -eq 0 ]; then
  ABIS=(arm64-v8a armeabi-v7a x86)
fi

# 把 ABI 映射回 Rust target triple
TARGET_ARGS=()
for abi in "${ABIS[@]}"; do
  case "$abi" in
    arm64-v8a)   TARGET_ARGS+=(aarch64-linux-android);;
    armeabi-v7a) TARGET_ARGS+=(armv7-linux-androideabi);;
    x86)         TARGET_ARGS+=(i686-linux-android);;
    *) echo "未知 ABI: $abi (支持 arm64-v8a / armeabi-v7a / x86)" >&2; exit 1;;
  esac
done

echo "==> 构建 Android (API ${ANDROID_API}): ${TARGET_ARGS[*]}"

# 通过 env 注入工具链变量（bash 无法 export 连字符变量名，故用 env 命令）。
# 用数组累积，便于按需为 i686 追加 getifaddrs 垫片链接参数。
ENV_ARGS=(
  CC_aarch64-linux-android="$CC_A"
  CXX_aarch64-linux-android="$CC_A++"
  AR_aarch64-linux-android="$NDK_BIN/llvm-ar"
  RANLIB_aarch64-linux-android="$NDK_BIN/llvm-ranlib"
  CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$CC_A"
  CARGO_TARGET_AARCH64_LINUX_ANDROID_AR="$NDK_BIN/llvm-ar"
  CC_armv7-linux-androideabi="$CC_V7"
  CXX_armv7-linux-androideabi="$CC_V7++"
  AR_armv7-linux-androideabi="$NDK_BIN/llvm-ar"
  RANLIB_armv7-linux-androideabi="$NDK_BIN/llvm-ranlib"
  CARGO_TARGET_ARMV7_LINUX_ANDROIDEABI_LINKER="$CC_V7"
  CARGO_TARGET_ARMV7_LINUX_ANDROIDEABI_AR="$NDK_BIN/llvm-ar"
  CC_i686-linux-android="$CC_X86"
  CXX_i686-linux-android="$CC_X86++"
  AR_i686-linux-android="$NDK_BIN/llvm-ar"
  RANLIB_i686-linux-android="$NDK_BIN/llvm-ranlib"
  CARGO_TARGET_I686_LINUX_ANDROID_LINKER="$CC_X86"
  CARGO_TARGET_I686_LINUX_ANDROID_AR="$NDK_BIN/llvm-ar"
)

# getifaddrs 垫片：部分老旧 Android 固件（如 mangosteen aarch64 机顶盒，内核 3.10.x；
# 以及 AOW-PC x86）bionic 缺 getifaddrs（即便 Rust 预编译 std::net 把它当硬符号引用），
# 动态链接器加载时即报 "cannot locate symbol getifaddrs"。为每个目标编译 no-op 垫片
# （空接口列表）并链入，使二进制不依赖设备 bionic 的该符号。DDNS 用外部服务查公网 IP，
# 不枚举本地网卡，返回空列表无害。
triple_to_env() { echo "$1" | tr '[:lower:]' '[:upper:]' | tr '.-' '__'; }
for t in "${TARGET_ARGS[@]}"; do
  case "$t" in
    aarch64-linux-android)      cc="$CC_A";   obj="$PWD/getifaddrs_shim_aarch64.o";;
    armv7-linux-androideabi)    cc="$CC_V7";  obj="$PWD/getifaddrs_shim_armv7.o";;
    i686-linux-android)         cc="$CC_X86"; obj="$PWD/getifaddrs_shim_i686.o";;
    *) continue;;
  esac
  "$cc" libs/getifaddrs_shim.c -c -o "$obj"
  ENV_ARGS+=( "CARGO_TARGET_$(triple_to_env "$t")_RUSTFLAGS=-Clink-arg=$obj" )
  echo "==> getifaddrs 垫片: $obj"
done

env "${ENV_ARGS[@]}" \
  cargo build --release $(printf -- '--target %s ' "${TARGET_ARGS[@]}")

mkdir -p out
for target in "${TARGET_ARGS[@]}"; do
  src="target/$target/release/cloudflare-ddns"
  case "$target" in
    aarch64-linux-android)  abi=arm64-v8a;;
    armv7-linux-androideabi) abi=armeabi-v7a;;
    i686-linux-android)      abi=x86;;
  esac
  cp -v "$src" "out/cloudflare-ddns-$abi"
  echo "    产物: out/cloudflare-ddns-$abi"
done
echo "==> 完成。产物位于 out/ 目录。"
