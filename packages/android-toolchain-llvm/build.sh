TERMUX_PKG_HOMEPAGE=https://llvm.org
TERMUX_PKG_DESCRIPTION="LLVM 23, Clang and LLD for Android AArch64"
TERMUX_PKG_LICENSE="Apache-2.0, NCSA"
TERMUX_PKG_LICENSE_FILE="llvm/LICENSE.TXT"
TERMUX_PKG_MAINTAINER="Toolchain maintainers"
TERMUX_PKG_VERSION=23.0.0git
TERMUX_PKG_REVISION=1
TERMUX_PKG_SRCURL=git+https://github.com/llvm/llvm-project
TERMUX_PKG_DEPENDS="libc++ (= 30), ndk-sysroot (= 30)"
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
-DCMAKE_PLATFORM_NO_VERSIONED_SONAME=OFF
-DLLVM_PARALLEL_LINK_JOBS=1
-DCMAKE_INSTALL_LIBDIR=lib
-DCMAKE_INSTALL_INCLUDEDIR=include
-DDEFAULT_SYSROOT=${TERMUX_PREFIX%/usr}
"

# shellcheck source=packages/android-toolchain-llvm/runtime.sh
source "$TERMUX_SCRIPTDIR/packages/android-toolchain-llvm/runtime.sh"

termux_step_get_source() {
	termux_android_toolchain_diagnostics_init llvm
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
		-DLLVM_INCLUDE_BENCHMARKS=OFF \
		-DLLVM_INCLUDE_TESTS=OFF -DCLANG_INCLUDE_TESTS=OFF
	cmake --build "$TERMUX_PKG_HOSTBUILD_DIR" --parallel "$TERMUX_PKG_MAKE_PROCESSES" \
		--target llvm-min-tblgen llvm-tblgen clang-tblgen llvm-config
}

termux_step_pre_configure() {
	termux_android_toolchain_diagnostics_init llvm
	local device_cflags
	jq -e --arg target "$TERMUX_HOST_PLATFORM" --argjson api "$TERMUX_PKG_API_LEVEL" \
		'.target == $target and .api_level == $api' "$TERMUX_SCRIPTDIR/scripts/android-toolchain.json" > /dev/null
	termux_android_toolchain_resolve_link_runtimes
	termux_android_toolchain_write_link_runtime_manifest llvm
	device_cflags=$(jq -r .cflags "$TERMUX_SCRIPTDIR/scripts/android-toolchain.json")
	CFLAGS+=" $device_cflags"
	CXXFLAGS+=" $device_cflags"
	local target=${CCTERMUX_HOST_PLATFORM:-$TERMUX_HOST_PLATFORM$TERMUX_PKG_API_LEVEL}
	TERMUX_PKG_EXTRA_CONFIGURE_ARGS+=" -DLLVM_HOST_TRIPLE=${target/-/-unknown-}"
	TERMUX_PKG_EXTRA_CONFIGURE_ARGS+=" -DLLVM_DEFAULT_TARGET_TRIPLE=${target/-/-unknown-}"
	TERMUX_PKG_SRCDIR="$TERMUX_PKG_SRCDIR/llvm"
}

termux_step_post_configure() {
	TERMUX_PKG_SRCDIR="${TERMUX_PKG_SRCDIR%/llvm}"
	# Build matching compiler-rt separately: the Android Clang just built below
	# cannot execute on the x86_64 builder. NDK Clang is the bootstrap compiler.
	(
		local runtime_output="$TERMUX_PKG_BUILDDIR/lib/clang/23"
		local target="${CCTERMUX_HOST_PLATFORM:-$TERMUX_HOST_PLATFORM$TERMUX_PKG_API_LEVEL}"
		TERMUX_PKG_SRCDIR="$TERMUX_PKG_SRCDIR/compiler-rt"
		TERMUX_PKG_BUILDDIR="$TERMUX_PKG_BUILDDIR/compiler-rt"
		mkdir -p "$TERMUX_PKG_BUILDDIR"
		cd "$TERMUX_PKG_BUILDDIR"
		TERMUX_PKG_EXTRA_CONFIGURE_ARGS="
-DLLVM_CMAKE_DIR=$TERMUX_PKG_HOSTBUILD_DIR/lib/cmake/llvm
-DCMAKE_INSTALL_PREFIX=$TERMUX_PREFIX/opt/android-toolchain-llvm
-DCMAKE_INSTALL_LIBDIR=lib
-DCMAKE_INSTALL_INCLUDEDIR=include
-DCMAKE_C_COMPILER_TARGET=$target
-DCMAKE_CXX_COMPILER_TARGET=$target
-DANDROID_PLATFORM_LEVEL=$TERMUX_PKG_API_LEVEL
-DCOMPILER_RT_DEFAULT_TARGET_ONLY=ON
-DCOMPILER_RT_USE_BUILTINS_LIBRARY=ON
-DCOMPILER_RT_BUILD_BUILTINS=ON
-DCOMPILER_RT_BUILD_SANITIZERS=ON
-DCOMPILER_RT_BUILD_PROFILE=ON
-DCOMPILER_RT_BUILD_LIBFUZZER=ON
-DCOMPILER_RT_INCLUDE_TESTS=OFF
-DCOMPILER_RT_USE_LIBCXX=OFF
-DLLVM_ENABLE_PER_TARGET_RUNTIME_DIR=OFF
-DCOMPILER_RT_OUTPUT_DIR=$runtime_output
-DCOMPILER_RT_INSTALL_PATH=lib/clang/23
"
		termux_step_configure_cmake
	)
}

termux_step_make() {
	termux_android_toolchain_diagnostics_init llvm
	# A continued build starts a fresh shell; resolve its current link inputs.
	termux_android_toolchain_resolve_link_runtimes
	termux_android_toolchain_write_link_runtime_manifest llvm
	cmake --build "$TERMUX_PKG_BUILDDIR/compiler-rt" --parallel "$TERMUX_PKG_MAKE_PROCESSES"
	cmake --build "$TERMUX_PKG_BUILDDIR" --parallel "$TERMUX_PKG_MAKE_PROCESSES" \
		--target all llvm-test-depends clang-test-depends lld-test-depends
}

_android_toolchain_check_resources() {
	local resource="$TERMUX_PREFIX/opt/android-toolchain-llvm/lib/clang/23" file
	for file in lib/linux/libclang_rt.builtins-aarch64-android.a \
		lib/linux/libclang_rt.asan-aarch64-android.a \
		lib/linux/libclang_rt.ubsan_standalone-aarch64-android.a \
		lib/linux/libclang_rt.profile-aarch64-android.a \
		share/asan_ignorelist.txt share/hwasan_ignorelist.txt share/cfi_ignorelist.txt; do
		[[ -f "$resource/$file" && ! -L "$resource/$file" ]] || \
			termux_error_exit "Missing owned LLVM 23 runtime resource: $file"
	done
	termux_android_toolchain_check_aarch64 "$resource/lib/linux/libclang_rt.builtins-aarch64-android.a"
}

_android_toolchain_record_resources() {
	local resource="$TERMUX_PREFIX/opt/android-toolchain-llvm/lib/clang/23"
	local manifest="$TERMUX_OUTPUT_DIR/android-toolchain-build-support/llvm-resources.sha256" file digest
	: > "$manifest"
	while IFS= read -r -d '' file; do
		digest=$(sha256sum "$file")
		printf '%s  %s\n' "${digest%% *}" "${file#"$TERMUX_PREFIX/"}" >> "$manifest"
	done < <(find "$resource/lib" "$resource/share" -type f -print0 | sort -z)
}

termux_step_make_install() {
	cmake --install "$TERMUX_PKG_BUILDDIR"
	# Apply the framework's API-level cleanup before recording identities.
	termux_step_elf_cleaner__from_paths "$TERMUX_PKG_BUILDDIR/lib/clang/23"
	cmake --install "$TERMUX_PKG_BUILDDIR/compiler-rt"
	_android_toolchain_check_resources
	_android_toolchain_record_resources
	local manifests="$TERMUX_PREFIX/opt/android-toolchain-llvm/share/android-toolchain-runtime"
	mkdir -p "$manifests"
	install -m644 "$TERMUX_OUTPUT_DIR/android-toolchain-build-support/llvm-resources.sha256" \
		"$TERMUX_OUTPUT_DIR/android-toolchain-build-support/llvm-link-runtimes.sha256" "$manifests/"
	printf '%s\n' 592953beff733a1e28f6c6e5e39f948fb035a329 > "$manifests/source-commit.txt"
	ln -s clang "$TERMUX_PREFIX/opt/android-toolchain-llvm/bin/cc"
	ln -s clang++ "$TERMUX_PREFIX/opt/android-toolchain-llvm/bin/c++"
	local runtime_archive="$TERMUX_PREFIX/opt/android-toolchain-llvm/lib/clang/23/lib/linux/libclang_rt.builtins-aarch64-android.a"
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
	cp "$TERMUX_PKG_BUILDDIR/CMakeCache.txt" \
		"$TERMUX_OUTPUT_DIR/android-toolchain-build-support/llvm-CMakeCache.txt"
	{
		printf 'target=%s\napi=%s\nndk=%s\n' "$TERMUX_HOST_PLATFORM" "$TERMUX_PKG_API_LEVEL" "$TERMUX_NDK_VERSION"
		"$CC" --version
		"$CC" -dumpmachine
		cmake --version
		"$TERMUX_PKG_HOSTBUILD_DIR/bin/llvm-config" --version --host-target
		git -C "$TERMUX_PKG_SRCDIR" rev-parse HEAD
		git -C "$TERMUX_SCRIPTDIR" rev-parse HEAD
		printf 'cflags=%s\ncxxflags=%s\n' "$CFLAGS" "$CXXFLAGS"
		sha256sum "$TERMUX_SCRIPTDIR/scripts/android-toolchain.json" "$TERMUX_PKG_BUILDER_DIR"/*.patch "$TERMUX_PKG_BUILDER_DIR"/*.patch.beforehostbuild \
			"$runtime_archive" "$_ANDROID_TOOLCHAIN_UNWIND" "$TERMUX_PREFIX/lib/libc++_shared.so"
		printf 'compiler_rt_commit=592953beff733a1e28f6c6e5e39f948fb035a329\n'
		sha256sum "$TERMUX_SCRIPTDIR/packages/android-toolchain-llvm/runtime.sh"
		cp "$TERMUX_PKG_BUILDDIR/compiler-rt/CMakeCache.txt" \
			"$TERMUX_OUTPUT_DIR/android-toolchain-build-support/compiler-rt-CMakeCache.txt"
	} > "$TERMUX_OUTPUT_DIR/android-toolchain-build-support/llvm-build-info.txt"
	cat "$TERMUX_OUTPUT_DIR/android-toolchain-build-support/llvm-build-info.txt"
	local test_paths=(llvm/test llvm/unittests llvm/utils/lit clang/test clang/unittests lld/test lld/unittests compiler-rt/test)
	git -C "$TERMUX_PKG_SRCDIR" diff --exit-code HEAD -- "${test_paths[@]}"
	[[ -z "$(git -C "$TERMUX_PKG_SRCDIR" ls-files --others --exclude-standard -- "${test_paths[@]}")" ]]
	tar -C / --zstd -cf "$TERMUX_OUTPUT_DIR/android-toolchain-build-support/llvm-tests.tar.zst" \
		--exclude=.git --exclude=CMakeFiles \
		"${TERMUX_PKG_SRCDIR#/}/llvm" "${TERMUX_PKG_SRCDIR#/}/clang" \
		"${TERMUX_PKG_SRCDIR#/}/lld" "${TERMUX_PKG_SRCDIR#/}/cmake" \
		"${TERMUX_PKG_SRCDIR#/}/third-party" "${TERMUX_PKG_SRCDIR#/}/compiler-rt" "${TERMUX_PKG_BUILDDIR#/}"
	(
		cd "$TERMUX_OUTPUT_DIR/android-toolchain-build-support"
		sha256sum llvm-tests.tar.zst llvm-test-paths llvm-config llvm-build-info.txt llvm-CMakeCache.txt compiler-rt-CMakeCache.txt llvm-link-runtimes.sha256 llvm-link-runtime-paths.txt llvm-resources.sha256 > llvm-support.sha256
	)
}

# Resource files were cleaned before hashing. Packaging must not alter them.
termux_step_post_massage() {
	(
		cd "$TERMUX_PKG_MASSAGEDIR/$TERMUX_PREFIX_CLASSICAL"
		sha256sum -c "$TERMUX_OUTPUT_DIR/android-toolchain-build-support/llvm-resources.sha256"
	)
}
