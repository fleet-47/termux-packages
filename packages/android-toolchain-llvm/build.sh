TERMUX_PKG_HOMEPAGE=https://llvm.org
TERMUX_PKG_DESCRIPTION="LLVM 23, Clang and LLD for Android AArch64"
TERMUX_PKG_LICENSE="Apache-2.0, NCSA"
TERMUX_PKG_LICENSE_FILE="llvm/LICENSE.TXT"
TERMUX_PKG_MAINTAINER="Toolchain maintainers"
TERMUX_PKG_VERSION=23.0.0git
TERMUX_PKG_SRCURL=git+https://github.com/llvm/llvm-project
TERMUX_PKG_DEPENDS="libc++, libcompiler-rt"
TERMUX_PKG_EXCLUDED_ARCHES="arm, i686, x86_64"
TERMUX_PKG_HOSTBUILD=true
TERMUX_PKG_FORCE_CMAKE=true
TERMUX_PKG_NO_STATICSPLIT=true
TERMUX_PKG_AUTO_UPDATE=false
TERMUX_PKG_EXTRA_CONFIGURE_ARGS="
-DLLVM_ENABLE_PROJECTS=clang;lld
-DLLVM_TARGETS_TO_BUILD=AArch64
-DLLVM_TARGET_ARCH=AArch64
-DLLVM_BUILD_LLVM_DYLIB=ON
-DLLVM_LINK_LLVM_DYLIB=ON
-DLLVM_ENABLE_ASSERTIONS=ON
-DLLVM_ENABLE_BINDINGS=OFF
-DLLVM_ENABLE_LIBEDIT=OFF
-DLLVM_ENABLE_LIBPFM=OFF
-DLLVM_ENABLE_LIBXML2=OFF
-DLLVM_ENABLE_ZLIB=OFF
-DLLVM_ENABLE_ZSTD=OFF
-DLLVM_INCLUDE_BENCHMARKS=OFF
-DLLVM_INCLUDE_EXAMPLES=OFF
-DLLVM_INCLUDE_TESTS=ON
-DCLANG_INCLUDE_TESTS=ON
-DLLVM_INSTALL_UTILS=ON
-DCLANG_DEFAULT_CXX_STDLIB=libc++
-DCLANG_DEFAULT_LINKER=lld
-DLLVM_NATIVE_TOOL_DIR=$TERMUX_PKG_HOSTBUILD_DIR/bin
-DCMAKE_INSTALL_PREFIX=$TERMUX_PREFIX/opt/android-toolchain-llvm
-DCMAKE_INSTALL_LIBDIR=lib
-DCMAKE_INSTALL_INCLUDEDIR=include
-DDEFAULT_SYSROOT=${TERMUX_PREFIX%/usr}
"

termux_step_get_source() {
	mkdir -p "$TERMUX_PKG_SRCDIR"
	git -C "$TERMUX_PKG_SRCDIR" init
	git -C "$TERMUX_PKG_SRCDIR" remote add origin https://github.com/llvm/llvm-project
	git -C "$TERMUX_PKG_SRCDIR" fetch --depth=1 origin 592953beff733a1e28f6c6e5e39f948fb035a329
	git -C "$TERMUX_PKG_SRCDIR" checkout --detach FETCH_HEAD
	[[ "$(git -C "$TERMUX_PKG_SRCDIR" rev-parse HEAD)" == 592953beff733a1e28f6c6e5e39f948fb035a329 ]]
}

termux_step_host_build() {
	termux_setup_cmake
	termux_setup_ninja
	cmake -G Ninja -S "$TERMUX_PKG_SRCDIR/llvm" -B "$TERMUX_PKG_HOSTBUILD_DIR" \
		-DCMAKE_BUILD_TYPE=Release -DLLVM_TARGETS_TO_BUILD=AArch64 \
		-DLLVM_ENABLE_PROJECTS=clang -DLLVM_ENABLE_ASSERTIONS=ON \
		-DLLVM_BUILD_LLVM_DYLIB=ON -DLLVM_LINK_LLVM_DYLIB=OFF \
		-DLLVM_ENABLE_ZLIB=OFF -DLLVM_ENABLE_ZSTD=OFF \
		-DLLVM_ENABLE_LIBXML2=OFF -DLLVM_ENABLE_LIBEDIT=OFF \
		-DLLVM_INCLUDE_TESTS=OFF -DCLANG_INCLUDE_TESTS=OFF
	cmake --build "$TERMUX_PKG_HOSTBUILD_DIR" --parallel "$TERMUX_PKG_MAKE_PROCESSES" \
		--target llvm-min-tblgen llvm-tblgen clang-tblgen llvm-config
}

termux_step_pre_configure() {
	local device_cflags
	device_cflags=$(jq -r .cflags "$TERMUX_SCRIPTDIR/android-toolchain.json")
	CFLAGS+=" $device_cflags"
	CXXFLAGS+=" $device_cflags"
	TERMUX_PKG_EXTRA_CONFIGURE_ARGS+=" -DLLVM_HOST_TRIPLE=${CCTERMUX_HOST_PLATFORM/-/-unknown-}"
	TERMUX_PKG_EXTRA_CONFIGURE_ARGS+=" -DLLVM_DEFAULT_TARGET_TRIPLE=${CCTERMUX_HOST_PLATFORM/-/-unknown-}"
	TERMUX_PKG_SRCDIR="$TERMUX_PKG_SRCDIR/llvm"
}

termux_step_post_configure() {
	TERMUX_PKG_SRCDIR="${TERMUX_PKG_SRCDIR%/llvm}"
}

termux_step_make() {
	cmake --build "$TERMUX_PKG_BUILDDIR" --parallel "$TERMUX_PKG_MAKE_PROCESSES" \
		--target all llvm-test-depends clang-test-depends lld-test-depends
}

termux_step_make_install() {
	cmake --install "$TERMUX_PKG_BUILDDIR"
	local runtime_archive
	runtime_archive=$(find "$TERMUX_PREFIX/lib/clang" -name 'libclang_rt.builtins-aarch64-android.a' -print -quit)
	ln -s "$(dirname "$(dirname "$runtime_archive")")" \
		"$TERMUX_PREFIX/opt/android-toolchain-llvm/lib/clang/23/lib"
	ln -s "$(dirname "$(dirname "$runtime_archive")")" \
		"$TERMUX_PKG_BUILDDIR/lib/clang/23/lib"
	local lib
	for lib in "$TERMUX_PREFIX"/opt/android-toolchain-llvm/lib/libLLVM.so.*; do
		[[ -f "$lib" && ! -L "$lib" ]]
		ln -s "../opt/android-toolchain-llvm/lib/$(basename "$lib")" "$TERMUX_PREFIX/lib/$(basename "$lib")"
	done
	mkdir -p "$TERMUX_OUTPUT_DIR/android-toolchain-build-support"
	cp "$TERMUX_PKG_HOSTBUILD_DIR/bin/llvm-config" \
		"$TERMUX_OUTPUT_DIR/android-toolchain-build-support/llvm-config"
	printf '%s\n%s\n' "$TERMUX_PKG_SRCDIR" "$TERMUX_PKG_BUILDDIR" \
		> "$TERMUX_OUTPUT_DIR/android-toolchain-build-support/llvm-test-paths"
	tar -C / --zstd -cf "$TERMUX_OUTPUT_DIR/android-toolchain-build-support/llvm-tests.tar.zst" \
		--exclude=.git --exclude=CMakeFiles \
		"${TERMUX_PKG_SRCDIR#/}" "${TERMUX_PKG_BUILDDIR#/}"
}
