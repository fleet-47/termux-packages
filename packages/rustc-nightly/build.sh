# Derived from TUR rustc-nightly at 1ab367227ea5788377ba38a6d166c4b7102e2ec1.
TERMUX_PKG_HOMEPAGE=https://www.rust-lang.org/
TERMUX_PKG_DESCRIPTION="Rust compiler and utilities (nightly version)"
TERMUX_PKG_LICENSE="MIT"
TERMUX_PKG_MAINTAINER="Toolchain maintainers"
TERMUX_PKG_VERSION="1.100.0-2026.08.24-nightly"
TERMUX_PKG_REVISION=2
_RUST_VERSION=$(echo $TERMUX_PKG_VERSION | cut -d- -f1)
_DATE="$(echo $TERMUX_PKG_VERSION | cut -d- -f2 | sed 's|\.|-|g')"
TERMUX_PKG_SRCURL=https://static.rust-lang.org/dist/$_DATE/rustc-nightly-src.tar.xz
TERMUX_PKG_SHA256=9b576e815e607528fd79903f96ad9e3065cf466343874e02589afbbbb20ace37
TERMUX_PKG_DEPENDS="libandroid-execinfo, libc++, android-toolchain-llvm (= 23.0.0git-1), openssl, zlib"
TERMUX_PKG_EXCLUDED_ARCHES="arm, i686, x86_64"
TERMUX_PKG_NO_REPLACE_GUESS_SCRIPTS=true
TERMUX_PKG_NO_STATICSPLIT=true
TERMUX_PKG_AUTO_UPDATE=false
_UPSTREAM_TEST_PATHS=(
	tests src/tools
	src/bootstrap/src/core/android.rs
	src/bootstrap/src/core/session.rs
	src/bootstrap/src/core/build_steps/test.rs
	src/bootstrap/src/core/build_steps/test
)
TERMUX_PKG_RM_AFTER_INSTALL="
bin/llc
bin/llvm-*
bin/opt
bin/sh
share/wasi-sysroot
opt/android-toolchain-llvm/bin/llvm-config-build-host
"

source "$TERMUX_SCRIPTDIR/packages/android-toolchain-llvm/runtime.sh"

termux_step_post_get_source() {
	termux_android_toolchain_diagnostics_init rust
	local _rust_version="$(cat version | cut -d- -f1)"
	if [ "$_rust_version" != "$_RUST_VERSION" ]; then
		termux_error_exit "Version mismatch: Expected $_RUST_VERSION, got $_rust_version."
	fi
	mkdir -p "$TERMUX_PKG_TMPDIR/upstream-test-sources"
	cp -a --parents "${_UPSTREAM_TEST_PATHS[@]}" "$TERMUX_PKG_TMPDIR/upstream-test-sources/"
}

termux_step_pre_configure() {
	# The dependency was built by the normal Termux build-order machinery.
	# Its build-host metadata executable is not part of the Android package.
	install -m755 "$TERMUX_OUTPUT_DIR/android-toolchain-build-support/llvm-config" \
		"$TERMUX_PREFIX/opt/android-toolchain-llvm/bin/llvm-config-build-host"
	termux_setup_cmake
	termux_setup_rust

	# default rust-nightly-std package to be installed
	TERMUX_PKG_DEPENDS+=", rust-nightly-std-${CARGO_TARGET_NAME/_/-}"

	local p="${TERMUX_PKG_BUILDER_DIR}/0001-set-TERMUX_PKG_API_LEVEL.diff"
	echo "Applying patch: $(basename "${p}")"
	sed "s|@TERMUX_PKG_API_LEVEL@|${TERMUX_PKG_API_LEVEL}|g" "${p}" \
		| patch --silent -p1

	# assist with downstream patch methods that bulk-replace
	# string 'com.termux' throughout the repository
	local original_prefix_component_one="/data/data/com."
	local original_prefix_component_two="termux/files/usr"
	local original_prefix="${original_prefix_component_one}${original_prefix_component_two}"
	if [[ "$TERMUX_PREFIX" != "$original_prefix" ]]; then
		local patch="$TERMUX_PKG_BUILDER_DIR/force-allow-edit-vendor.diff"
		echo "Applying patch: $(basename "$patch")"
		patch --silent -p1 < "$patch"

		local crate=openssl-probe
		local crate_src_dir="$(realpath "$(find "$TERMUX_PKG_SRCDIR/vendor" -name "$crate"'*' | sort | tail -n1)")"
		local crate_dest_dir="$crate_src_dir-custom-termux-prefix"
		cp -r "$crate_src_dir" "$crate_dest_dir"

		echo "Replacing '$original_prefix' with '$TERMUX_PREFIX' in '$crate_dest_dir/src/lib.rs'"
		sed -i -e "s|$original_prefix|$TERMUX_PREFIX|g" "$crate_dest_dir/src/lib.rs"

		local dir
		for dir in "$TERMUX_PKG_SRCDIR"/{,src/tools/cargo,src/tools/miri}; do
			echo '' >> "$dir/Cargo.toml"
			echo '[patch.crates-io]' >> "$dir/Cargo.toml"
			echo "$crate = { path = \"${crate_dest_dir}\" }" >> "$dir/Cargo.toml"
		done
	fi

	export RUST_LIBDIR=$TERMUX_PKG_BUILDDIR/_lib
	mkdir -p $RUST_LIBDIR

	# Isolate LLVM and Android link libraries from the build-host library search.
	ln -vfst "${RUST_LIBDIR}" \
		"${TERMUX_PREFIX}/opt/android-toolchain-llvm/lib"/libLLVM*.so*

	# https://github.com/termux/termux-packages/issues/18379
	# NDK r26 multiple ld.lld: error: undefined symbol: __cxa_*
	ln -vfst "${RUST_LIBDIR}" "${TERMUX_PREFIX}"/lib/libc++_shared.so

	# https://github.com/termux/termux-packages/issues/11640
	# https://github.com/termux/termux-packages/issues/11658
	# The build system somehow tries to link binaries against a wrong libc,
	# leading to build failures for arm and runtime errors for others.
	# The following command is equivalent to
	#	ln -vfst $RUST_LIBDIR \
	#		$TERMUX_STANDALONE_TOOLCHAIN/sysroot/usr/lib/$TERMUX_HOST_PLATFORM/$TERMUX_PKG_API_LEVEL/lib{c,dl}.so
	# but written in a future-proof manner.
	ln -vfst $RUST_LIBDIR $(echo | $CC -x c - -Wl,-t -shared | grep '\.so$')

	ln -vfst "${RUST_LIBDIR}" "${TERMUX_PREFIX}"/lib/libandroid-execinfo.so
}

termux_step_configure() {
	termux_android_toolchain_diagnostics_init rust
	CC=$(command -v "$CC")
	CXX=$(command -v "$CXX")
	AR=$(command -v "$AR")
	local prerequisite
	for prerequisite in "$CC" "$CXX" "$AR" \
		"$TERMUX_PREFIX/opt/android-toolchain-llvm/bin/llvm-config-build-host"; do
		[[ -x "$prerequisite" ]] || termux_error_exit "Missing build tool: $prerequisite"
	done
	for prerequisite in "$TERMUX_PREFIX/opt/android-toolchain-llvm/include/llvm/Config/llvm-config.h" \
		"$TERMUX_PREFIX/opt/android-toolchain-llvm/lib/libLLVM.so" \
		"$TERMUX_PREFIX/lib/libc++_shared.so"; do
		[[ -f "$prerequisite" ]] || termux_error_exit "Missing Android LLVM prerequisite: $prerequisite"
	done
	termux_android_toolchain_resolve_link_runtimes
	termux_android_toolchain_write_link_runtime_manifest rust
	rustup install nightly-$_DATE-x86_64-unknown-linux-gnu
	export PATH="${HOME}/.rustup/toolchains/nightly-$_DATE-x86_64-unknown-linux-gnu/bin:${PATH}"
	local RUSTC=$(command -v rustc)
	local CARGO=$(command -v cargo)


	RUST_NIGHTLY_PREFIX="$TERMUX_PREFIX"/opt/rust-nightly
	mkdir -p "$RUST_NIGHTLY_PREFIX"

	sed \
		-e "s|@RUST_PREFIX@|${RUST_NIGHTLY_PREFIX}|g" \
		-e "s|@TERMUX_PREFIX@|${TERMUX_PREFIX}|g" \
		-e "s|@TERMUX_STANDALONE_TOOLCHAIN@|${TERMUX_STANDALONE_TOOLCHAIN}|g" \
		-e "s|@CARGO_TARGET_NAME@|${CARGO_TARGET_NAME}|g" \
		-e "s|@RUSTC@|${RUSTC}|g" \
		-e "s|@CARGO@|${CARGO}|g" \
		-e "s|@CC@|${CC}|g" \
		-e "s|@CXX@|${CXX}|g" \
		-e "s|@AR@|${AR}|g" \
		"${TERMUX_PKG_BUILDER_DIR}"/bootstrap.toml > bootstrap.toml

	local profile="$TERMUX_SCRIPTDIR/scripts/android-toolchain.json"
	local target_rustflags target_cflags
	jq -e --arg target "$CARGO_TARGET_NAME" --argjson api "$TERMUX_PKG_API_LEVEL" \
		'.target == $target and .api_level == $api' "$profile" > /dev/null
	export CC_aarch64_linux_android="$CC"
	export CXX_aarch64_linux_android="$CXX"
	export AR_aarch64_linux_android="$AR"
	target_rustflags=$(jq -r .rustflags "$profile")
	target_cflags=$(jq -r .cflags "$profile")
	export CFLAGS_aarch64_linux_android="${CFLAGS} ${target_cflags}"
	export CXXFLAGS_aarch64_linux_android="${CXXFLAGS} ${target_cflags}"
	python3 - "$profile" bootstrap.toml <<'PYFLAGS'
import json, pathlib, shlex, sys
profile = json.loads(pathlib.Path(sys.argv[1]).read_text())
config = pathlib.Path(sys.argv[2])
config.write_text(config.read_text().replace('@TARGET_RUSTFLAGS@', json.dumps(shlex.split(profile['rustflags']))))
PYFLAGS

	local env_host=$(printf $CARGO_TARGET_NAME | tr a-z A-Z | sed s/-/_/g)
	export ${env_host}_OPENSSL_DIR=$TERMUX_PREFIX
	export CARGO_TARGET_${env_host}_LINKER="$CC"
	export RUST_LIBDIR=$TERMUX_PKG_BUILDDIR/_lib
	export CARGO_TARGET_${env_host}_RUSTFLAGS="${target_rustflags} -L${RUST_LIBDIR}"

	# NDK r26
	export CARGO_TARGET_${env_host}_RUSTFLAGS+=" -C link-arg=-lc++_shared"

	# rust 1.79.0
	# note: ld.lld: error: undefined reference due to --no-allow-shlib-undefined: syncfs
	"${CC}" ${CPPFLAGS} ${CFLAGS_aarch64_linux_android} -c "${TERMUX_PKG_BUILDER_DIR}/syncfs.c"
	"${AR}" rcu "${RUST_LIBDIR}/libsyncfs.a" syncfs.o
	export CARGO_TARGET_${env_host}_RUSTFLAGS+=" -C link-arg=-l:libsyncfs.a"

	# rust 1.87.0
	# note: ld.lld: error: undefined reference due to --no-allow-shlib-undefined: backtrace
	export CARGO_TARGET_${env_host}_RUSTFLAGS+=" -C link-arg=-landroid-execinfo"

	# Add rpath
	export CARGO_TARGET_${env_host}_RUSTFLAGS+=" -C link-arg=-Wl,-rpath=\$ORIGIN/../lib"
	export CARGO_TARGET_${env_host}_RUSTFLAGS+=" -C link-arg=-Wl,-rpath=$RUST_NIGHTLY_PREFIX/lib"
	export CARGO_TARGET_${env_host}_RUSTFLAGS+=" -C link-arg=-Wl,-rpath=${TERMUX_PREFIX}/lib -C link-arg=-Wl,--enable-new-dtags"

	mkdir -p "$TERMUX_OUTPUT_DIR/android-toolchain-build-support"
	{
		printf 'target=%s\napi=%s\nndk=%s\n' "$CARGO_TARGET_NAME" "$TERMUX_PKG_API_LEVEL" "$TERMUX_NDK_VERSION"
		printf 'source_sha256=%s\n' "$TERMUX_PKG_SHA256"
		git -C "$TERMUX_SCRIPTDIR" rev-parse HEAD
		"$RUSTC" -vV
		"$CARGO" -V
		"$CC" --version
		"$CC" -dumpmachine
		"$TERMUX_PREFIX/opt/android-toolchain-llvm/bin/llvm-config-build-host" --version
		printf 'cc=%s\ncxx=%s\nar=%s\ncflags=%s\ncxxflags=%s\n' \
			"$CC" "$CXX" "$AR" "$CFLAGS_aarch64_linux_android" "$CXXFLAGS_aarch64_linux_android"
		local rustflags_var="CARGO_TARGET_${env_host}_RUSTFLAGS"
		printf 'rustflags=%s\n' "${!rustflags_var}"
		sha256sum "$profile" bootstrap.toml "$TERMUX_PKG_BUILDER_DIR"/*.patch "$TERMUX_PKG_BUILDER_DIR"/*.diff
	} > "$TERMUX_OUTPUT_DIR/android-toolchain-build-support/rust-build-info.txt"
	cat "$TERMUX_OUTPUT_DIR/android-toolchain-build-support/rust-build-info.txt"
	cp bootstrap.toml "$TERMUX_OUTPUT_DIR/android-toolchain-build-support/rust-bootstrap.toml"

	unset CC CFLAGS CFLAGS_${env_host} CPP CPPFLAGS CXX CXXFLAGS LD LDFLAGS PKG_CONFIG RANLIB

}

termux_step_make() {
	local path
	for path in "${_UPSTREAM_TEST_PATHS[@]}"; do
		diff -r --no-dereference "$TERMUX_PKG_TMPDIR/upstream-test-sources/$path" "$TERMUX_PKG_SRCDIR/$path"
	done
	mkdir -p "$TERMUX_OUTPUT_DIR/android-toolchain-build-support"
	tar -C "$TERMUX_PKG_SRCDIR" -cJf \
		"$TERMUX_OUTPUT_DIR/android-toolchain-build-support/rust-source.tar.xz" .
	(
		cd "$TERMUX_OUTPUT_DIR/android-toolchain-build-support"
		sha256sum rust-source.tar.xz rust-build-info.txt rust-bootstrap.toml \
			rust-link-runtimes.sha256 rust-link-runtime-paths.txt > rust-support.sha256
	)
}

termux_step_make_install() {
	# rust 1.87.0
	# https://github.com/termux/termux-packages/issues/25360
	# build to stage 2 to fix rust-analyzer error
	"${TERMUX_PKG_SRCDIR}/x.py" install -j "${TERMUX_PKG_MAKE_PROCESSES}" --stage 2


	# Capture std paths before rustc-dev adds libraries to the same directory.
	local std_libdir="$RUST_NIGHTLY_PREFIX/lib/rustlib/$CARGO_TARGET_NAME/lib"
	local std_lib
	for std_lib in "$std_libdir"/*.rlib; do
		[[ -f "$std_lib" ]] || termux_error_exit "Missing installed std library: $std_lib"
		basename "$std_lib"
	done > "$TERMUX_PKG_BUILDDIR/rustlib-rlib.txt"
	for std_lib in "$std_libdir"/*.so; do
		[[ -f "$std_lib" ]] || termux_error_exit "Missing installed std shared library: $std_lib"
		basename "$std_lib"
	done > "$TERMUX_PKG_BUILDDIR/rustlib-so.txt"
	export _STD_INCLUDED="$(
		for std_lib in "$std_libdir"/*.rlib "$std_libdir"/libstd-*.so; do
			printf '%s\n' "${std_lib#"$TERMUX_PREFIX"/}"
		done
	)"

	"${TERMUX_PKG_SRCDIR}/x.py" dist -j "${TERMUX_PKG_MAKE_PROCESSES}" --stage 2 rustc-dev

	local VERSION=nightly

	ls build/dist/*-${VERSION}*.tar.gz | xargs -P${TERMUX_PKG_MAKE_PROCESSES} -n1 -t -r tar -xf
	local tgz
	for tgz in $(ls build/dist/*-${VERSION}*.tar.gz); do
		echo "INFO: ${tgz}"
		./$(basename "${tgz}" | sed -e "s|.tar.gz$||")/install.sh --prefix=${RUST_NIGHTLY_PREFIX}
	done

	cd "$TERMUX_PREFIX/lib"
	rm -fv libc.so libdl.so

	cd "$RUST_NIGHTLY_PREFIX/lib"
	while IFS= read -r std_lib; do
		if [[ ! -e "$std_lib" && ! -L "$std_lib" ]]; then
			ln -vs "rustlib/$CARGO_TARGET_NAME/lib/$std_lib" "$std_lib"
		fi
	done < "$TERMUX_PKG_BUILDDIR/rustlib-so.txt"
	ln -vfs "$TERMUX_PREFIX"/opt/android-toolchain-llvm/bin/lld ${RUST_NIGHTLY_PREFIX}/bin/rust-lld

	cd "$RUST_NIGHTLY_PREFIX/lib/rustlib"
	rm -fr \
		components \
		install.log \
		uninstall.sh \
		rust-installer-version \
		manifest-* \
		x86_64-unknown-linux-gnu

	cd "${RUST_NIGHTLY_PREFIX}/lib/rustlib/${CARGO_TARGET_NAME}/lib"
	echo "INFO: ${TERMUX_PKG_BUILDDIR}/rustc-dev-${VERSION}-${CARGO_TARGET_NAME}/rustc-dev/manifest.in"
	cat "${TERMUX_PKG_BUILDDIR}/rustc-dev-${VERSION}-${CARGO_TARGET_NAME}/rustc-dev/manifest.in" | tee "${TERMUX_PKG_BUILDDIR}/manifest.in"

	sed -e 's/^.....//' -i "${TERMUX_PKG_BUILDDIR}/manifest.in"
	local _included=$(cat "${TERMUX_PKG_BUILDDIR}/manifest.in")
	local _included_rlib=$(echo "${_included}" | grep '\.rlib$')
	local _included_so=$(echo "${_included}" | grep '\.so$')
	local _included=$(echo "${_included}" | grep -v "/rustc-src/")
	local _included=$(echo "${_included}" | grep -v '\.rlib$')
	local _included=$(echo "${_included}" | grep -v '\.so$')

	echo "INFO: _rlib"
	while IFS= read -r _rlib; do
		echo "${_rlib}"
		local _included_rlib=$(echo "${_included_rlib}" | grep -v "${_rlib}")
	done < "${TERMUX_PKG_BUILDDIR}/rustlib-rlib.txt"
	echo "INFO: _so"
	while IFS= read -r _so; do
		echo "${_so}"
		local _included_so=$(echo "${_included_so}" | grep -v "${_so}")
	done < "${TERMUX_PKG_BUILDDIR}/rustlib-so.txt"

	export _INCLUDED="$(echo -e "${_included}\n${_included_rlib}\n${_included_so}" | xargs -I {} echo "opt/rust-nightly/{}")"
	echo -e "INFO: _INCLUDED:\n${_INCLUDED}"
}

termux_step_post_make_install() {

	mkdir -p $TERMUX_PREFIX/etc/profile.d
	echo "#!$TERMUX_PREFIX/bin/sh" > $TERMUX_PREFIX/etc/profile.d/rust-nightly.sh
	echo "export PATH=$RUST_NIGHTLY_PREFIX/bin:$TERMUX_PREFIX/opt/android-toolchain-llvm/bin:\$PATH" >> $TERMUX_PREFIX/etc/profile.d/rust-nightly.sh
}

termux_step_create_debscripts() {
	echo "#!$TERMUX_PREFIX/bin/sh" > postinst
	echo "echo 'source \$PREFIX/etc/profile.d/rust-nightly.sh to use nightly'" >> postinst
	echo "echo 'or export RUSTC=\$PREFIX/opt/rust-nightly/bin/rustc'" >> postinst
}
