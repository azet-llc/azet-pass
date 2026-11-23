#!/bin/zsh
# Builds libbitwarden_uniffi.so (arm64) from ~/Code/sdk-internal-android with the NDK clang, then the Kotlin bindings.
set -e
export PATH=$HOME/.cargo/bin:$PATH
NDK=~/Library/Android/sdk/ndk/27.1.12297006; TC=$NDK/toolchains/llvm/prebuilt/darwin-x86_64/bin
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER=$TC/aarch64-linux-android29-clang
export CC_aarch64_linux_android=$TC/aarch64-linux-android29-clang CXX_aarch64_linux_android=$TC/aarch64-linux-android29-clang++
export AR_aarch64_linux_android=$TC/llvm-ar RANLIB_aarch64_linux_android=$TC/llvm-ranlib
export ANDROID_NDK_HOME=$NDK
TB=$(dirname $(rustup which --toolchain 1.97.1 rustc)); export PATH=$TB:$PATH RUSTC=$TB/rustc RUSTDOC=$TB/rustdoc
SDK=${SDK:-$HOME/Code/sdk-internal-android}; cd "$SDK"
# SDK = a sdk-internal checkout at 9794da58 with ../sdk-patches/0001-azet-uniffi-helpers.patch applied
$TB/cargo build -p bitwarden-uniffi --release --target aarch64-linux-android
K=crates/bitwarden-uniffi/kotlin; mkdir -p $K/sdk/src/main/jniLibs/arm64-v8a
cp target/aarch64-linux-android/release/libbitwarden_uniffi.so $K/sdk/src/main/jniLibs/arm64-v8a/
$TB/cargo run -p uniffi-bindgen generate $K/sdk/src/main/jniLibs/arm64-v8a/libbitwarden_uniffi.so --language kotlin --no-format --out-dir $K/sdk/src/main/java
G=$(cd "$(dirname "$0")/.." && pwd)/app/sdk-gen; rm -rf "$G"; mkdir -p "$G"; cp -R $K/sdk/src/main/java $K/sdk/src/main/jniLibs "$G"/
echo "SDK bindings and .so in $G"
