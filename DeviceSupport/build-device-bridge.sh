#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
if [ -z "${ANDROID_NDK_ROOT:-}" ]; then
  echo "ANDROID_NDK_ROOT must point to an Android NDK installation" >&2
  exit 1
fi
NDK_ROOT=$ANDROID_NDK_ROOT
TOOLCHAIN="$NDK_ROOT/toolchains/llvm/prebuilt/darwin-x86_64/bin"

"$TOOLCHAIN/clang" \
  --target=armv7a-linux-android21 \
  -march=armv7-a \
  -mfloat-abi=soft \
  -Oz \
  -fomit-frame-pointer \
  -fno-stack-protector \
  -fno-unwind-tables \
  -fno-asynchronous-unwind-tables \
  -fno-builtin \
  -nostdlib \
  -static \
  -Wl,-e,_start \
  -Wl,--build-id=none \
  -Wl,--gc-sections \
  "$SCRIPT_DIR/codex-micro-bridge.c" \
  -o "$SCRIPT_DIR/codex-micro-bridge"

echo "Built $SCRIPT_DIR/codex-micro-bridge"
