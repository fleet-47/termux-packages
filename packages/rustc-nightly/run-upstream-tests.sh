#!/usr/bin/env bash
set -euo pipefail

source_dir=$(realpath "$1")
profile=$(realpath "$2")
jobs=${3:-$(nproc)}
recipe_dir=$(cd "$(dirname "$0")" && pwd)
llvm_prefix="$PREFIX/opt/android-toolchain-llvm"
rust_prefix="$PREFIX/opt/rust-nightly"
export PATH="$rust_prefix/bin:$llvm_prefix/bin:$PATH"

python3 - "$recipe_dir/bootstrap.toml" "$source_dir/bootstrap.toml" "$profile" "$PREFIX" <<'PY'
import json
import pathlib
import shlex
import sys

source, destination, profile_path, prefix = sys.argv[1:]
profile = json.loads(pathlib.Path(profile_path).read_text())
llvm = prefix + '/opt/android-toolchain-llvm'
rust = prefix + '/opt/rust-nightly'
config = pathlib.Path(source).read_text()
config = config.replace('[build]\n', '[build]\nbuild = "aarch64-linux-android"\ncompiletest-allow-stage0 = true\nrustfmt = "' + rust + '/bin/rustfmt"\nrustdoc = "' + rust + '/bin/rustdoc"\n')
config = config.replace('android-ndk = "@TERMUX_STANDALONE_TOOLCHAIN@"\n', '')
config = config.replace('[target.x86_64-unknown-linux-gnu]\nllvm-config = "/usr/bin/llvm-config-21"\nrpath = true\n\n', '')
config = config.replace('llvm-config-build-host', 'llvm-config')
config = config.replace('[target.aarch64-linux-android]\n', '[target.aarch64-linux-android]\nllvm-filecheck = "' + llvm + '/bin/FileCheck"\n')
for key, value in {
    '@RUST_PREFIX@': rust,
    '@TERMUX_PREFIX@': prefix,
    '@CARGO_TARGET_NAME@': 'aarch64-linux-android',
    '@RUSTC@': rust + '/bin/rustc',
    '@CARGO@': rust + '/bin/cargo',
    '@CC@': llvm + '/bin/clang',
    '@CXX@': llvm + '/bin/clang++',
    '@AR@': llvm + '/bin/llvm-ar',
    '@TARGET_RUSTFLAGS@': json.dumps(shlex.split(profile['rustflags'])),
}.items():
    config = config.replace(key, value)
pathlib.Path(destination).write_text(config)
PY

export CC_aarch64_linux_android="$llvm_prefix/bin/clang"
export CXX_aarch64_linux_android="$llvm_prefix/bin/clang++"
export AR_aarch64_linux_android="$llvm_prefix/bin/llvm-ar"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_LINKER="$CC_aarch64_linux_android"
export CFLAGS_aarch64_linux_android="$(jq -r .cflags "$profile")"
export CXXFLAGS_aarch64_linux_android="$CFLAGS_aarch64_linux_android"
export AARCH64_LINUX_ANDROID_OPENSSL_DIR="$PREFIX"
link_dir="$source_dir/runtime-link"
mkdir -p "$link_dir"
"$CC_aarch64_linux_android" $CFLAGS_aarch64_linux_android -c "$recipe_dir/syncfs.c" -o "$link_dir/syncfs.o"
"$AR_aarch64_linux_android" rcs "$link_dir/libsyncfs.a" "$link_dir/syncfs.o"
export CARGO_TARGET_AARCH64_LINUX_ANDROID_RUSTFLAGS="$(jq -r .rustflags "$profile") -L$link_dir -L$PREFIX/lib -C link-arg=-lc++_shared -C link-arg=-landroid-execinfo -C link-arg=-l:libsyncfs.a -C link-arg=-Wl,-rpath=$rust_prefix/lib -C link-arg=-Wl,-rpath=$llvm_prefix/lib"
cd "$source_dir"
python3 x.py build --stage 1 --host aarch64-linux-android --target aarch64-linux-android -j "$jobs" src/tools/remote-test-server
export TEST_DEVICE_ADDR=127.0.0.1:12345
build/aarch64-linux-android/stage1-tools-bin/remote-test-server --bind "$TEST_DEVICE_ADDR" &
server_pid=$!
trap 'kill "$server_pid"; wait "$server_pid" || test "$?" -eq 143' EXIT
python3 x.py test --stage 0 --host aarch64-linux-android --target aarch64-linux-android -j "$jobs" --no-fail-fast
