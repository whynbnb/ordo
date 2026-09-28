#!/usr/bin/env bash
# 交叉编译 Ordo 的 Rust 核心到 Android 各 ABI，并放入 jniLibs。
#
# 依赖：
#   rustup target add aarch64-linux-android armv7-linux-androideabi x86_64-linux-android
#   cargo install cargo-ndk
#   Android NDK（通过 ANDROID_NDK_HOME，或 ANDROID_HOME/ndk/<version> 指定）
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ABIS=(arm64-v8a armeabi-v7a x86_64)

ARGS=()
for abi in "${ABIS[@]}"; do
  ARGS+=(-t "$abi")
done

cd "$ROOT/rust"
cargo ndk "${ARGS[@]}" -o "$ROOT/android/app/src/main/jniLibs" build --release

echo "Rust 核心已编译到 android/app/src/main/jniLibs"
