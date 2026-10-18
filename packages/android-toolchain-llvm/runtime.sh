# Shared build-time validation for the LLVM and Rust Android packages.

termux_android_toolchain_check_aarch64() {
	local library=$1 headers line machines=0
	headers=$("${READELF:-llvm-readelf}" --file-headers "$library") || \
		termux_error_exit "Cannot inspect Android runtime library: $library"
	while IFS= read -r line; do
		if [[ "$line" =~ ^[[:space:]]*Machine:[[:space:]]*(.*) ]]; then
			[[ "${BASH_REMATCH[1]}" =~ ^AArch64[[:space:]]*$ ]] || \
				termux_error_exit "Non-AArch64 runtime member in $library: $line"
			machines=$((machines + 1))
		fi
	done <<< "$headers"
	[[ "$machines" -gt 0 ]] || termux_error_exit "No ELF runtime members found in $library"
}

termux_android_toolchain_resolve_link_runtimes() {
	local unwind
	# Expand the same flag strings used by Termux compiler invocations.
	# shellcheck disable=SC2086
	unwind=$("$CC" ${CPPFLAGS:-} ${CFLAGS:-} ${LDFLAGS:-} -print-file-name=libunwind.a) || \
		termux_error_exit "Android compiler could not resolve libunwind.a"
	[[ "$unwind" == /* && -f "$unwind" ]] || \
		termux_error_exit "Android compiler selected an unresolved or missing libunwind.a: $unwind"
	_ANDROID_TOOLCHAIN_UNWIND=$(realpath -e "$unwind")
	_ANDROID_TOOLCHAIN_CXX_SHARED=$(realpath -e "$TERMUX_PREFIX/lib/libc++_shared.so") || \
		termux_error_exit "Missing Android libc++: $TERMUX_PREFIX/lib/libc++_shared.so"
	termux_android_toolchain_check_aarch64 "$_ANDROID_TOOLCHAIN_UNWIND"
	termux_android_toolchain_check_aarch64 "$_ANDROID_TOOLCHAIN_CXX_SHARED"
	_ANDROID_TOOLCHAIN_DIAGNOSTIC_CC=$CC
	_ANDROID_TOOLCHAIN_DIAGNOSTIC_CPPFLAGS=${CPPFLAGS:-}
	_ANDROID_TOOLCHAIN_DIAGNOSTIC_CFLAGS=${CFLAGS:-}
	_ANDROID_TOOLCHAIN_DIAGNOSTIC_LDFLAGS=${LDFLAGS:-}
}

termux_android_toolchain_write_link_runtime_manifest() {
	local name=$1 support="$TERMUX_OUTPUT_DIR/android-toolchain-build-support" digest current recorded
	[[ -f "${_ANDROID_TOOLCHAIN_UNWIND:-}" && -f "${_ANDROID_TOOLCHAIN_CXX_SHARED:-}" ]] || \
		termux_error_exit "Resolve Android link runtimes before recording their identity"
	mkdir -p "$support"
	current=$(
		digest=$(sha256sum "$_ANDROID_TOOLCHAIN_UNWIND") || exit 1
		printf '%s  lib/libunwind.a\n' "${digest%% *}"
		digest=$(sha256sum "$_ANDROID_TOOLCHAIN_CXX_SHARED") || exit 1
		printf '%s  lib/libc++_shared.so\n' "${digest%% *}"
	) || termux_error_exit "Cannot hash Android link runtimes"
	if [[ "${TERMUX_CONTINUE_BUILD:-false}" == true ]]; then
		[[ -s "$support/$name-link-runtimes.sha256" ]] || \
			termux_error_exit "Missing original $name runtime provenance; start a fresh build"
		recorded=$(cat "$support/$name-link-runtimes.sha256")
		[[ "$recorded" == "$current" ]] || \
			termux_error_exit "Android link runtimes changed during $name continuation; start a fresh build"
		return
	fi
	printf '%s\n' "$current" > "$support/$name-link-runtimes.sha256"
	printf 'unwind_selected=%s\ncxx_shared_selected=%s\n' \
		"$_ANDROID_TOOLCHAIN_UNWIND" "$_ANDROID_TOOLCHAIN_CXX_SHARED" \
		> "$support/$name-link-runtime-paths.txt"
}

termux_android_toolchain_diagnostics_init() {
	local name=$1 existing
	if [[ -n "${_ANDROID_TOOLCHAIN_DIAGNOSTIC_NAME:-}" ]]; then
		[[ "$_ANDROID_TOOLCHAIN_DIAGNOSTIC_NAME" == "$name" ]] || \
			termux_error_exit "Android diagnostic collector already belongs to $_ANDROID_TOOLCHAIN_DIAGNOSTIC_NAME"
		return
	fi
	existing=$(trap -p EXIT)
	[[ -z "$existing" ]] || termux_error_exit "Cannot replace an existing EXIT trap for Android diagnostics"
	_ANDROID_TOOLCHAIN_DIAGNOSTIC_NAME=$name
	_ANDROID_TOOLCHAIN_DIAGNOSTIC_HELPER="${BASH_SOURCE[0]}"
	_ANDROID_TOOLCHAIN_DIAGNOSTIC_DIR="$TERMUX_OUTPUT_DIR/android-toolchain-diagnostics/$name"
	mkdir -p "$_ANDROID_TOOLCHAIN_DIAGNOSTIC_DIR"
	printf 'kind=partial-build-diagnostics\ncollection=pending\n' \
		> "$_ANDROID_TOOLCHAIN_DIAGNOSTIC_DIR/status.txt"
	trap 'termux_android_toolchain_diagnostics_exit "$?"' EXIT
}

termux_android_toolchain_diagnostics_exit() {
	local build_status=$1 diagnostic_status
	trap - EXIT
	# A fresh shell preserves errexit: an OR-list around a function disables it
	# throughout that function and could hide failed exports.
	set +e
	bash -euo pipefail "$_ANDROID_TOOLCHAIN_DIAGNOSTIC_HELPER" --collect-diagnostics \
		"$_ANDROID_TOOLCHAIN_DIAGNOSTIC_DIR" "$_ANDROID_TOOLCHAIN_DIAGNOSTIC_NAME" "$build_status" \
		"${CC:-${_ANDROID_TOOLCHAIN_DIAGNOSTIC_CC:-}}" "${READELF:-llvm-readelf}" \
		"${CPPFLAGS:-${_ANDROID_TOOLCHAIN_DIAGNOSTIC_CPPFLAGS:-}}" \
		"${CFLAGS:-${_ANDROID_TOOLCHAIN_DIAGNOSTIC_CFLAGS:-}}" \
		"${LDFLAGS:-${_ANDROID_TOOLCHAIN_DIAGNOSTIC_LDFLAGS:-}}" \
		"${TERMUX_PKG_HOSTBUILD_DIR:-}" "${TERMUX_PKG_BUILDDIR:-}" \
		"${TERMUX_PKG_SRCDIR:-}" "${TERMUX_PREFIX:-}"
	diagnostic_status=$?
	if [[ "$diagnostic_status" -ne 0 ]]; then
		printf 'Android diagnostic export failed with status %s (original build status %s)\n' \
			"$diagnostic_status" "$build_status" >&2
		if [[ "$build_status" -eq 0 ]]; then build_status=$diagnostic_status; fi
	fi
	exit "$build_status"
}

_termux_android_toolchain_diagnostic_command() {
	local output=$1 status
	shift
	if "$@" > "$output.txt" 2>&1; then status=0; else status=$?; fi
	printf '%s\n' "$status" > "$output.status"
}

termux_android_toolchain_collect_diagnostics() {
	local output=$1 name=$2 build_status=$3 cc=$4 readelf=$5
	local cppflags=$6 cflags=$7 ldflags=$8 host=$9 target=${10} source=${11} prefix=${12}
	local label directory path unwind
	mkdir -p "$output"
	printf 'kind=partial-build-diagnostics\npackage=%s\nbuild_exit_status=%s\ncollection=in-progress\n' \
		"$name" "$build_status" > "$output/status.txt"
	printf 'cc=%s\ncppflags=%s\ncflags=%s\nldflags=%s\nsource=%s\nhost_build=%s\ntarget_build=%s\n' \
		"$cc" "$cppflags" "$cflags" "$ldflags" "$source" "$host" "$target" > "$output/build-paths.txt"
	if [[ -n "$cc" ]]; then
		_termux_android_toolchain_diagnostic_command "$output/compiler-version" "$cc" --version
		_termux_android_toolchain_diagnostic_command "$output/compiler-target" "$cc" -dumpmachine
		_termux_android_toolchain_diagnostic_command "$output/compiler-resource-dir" "$cc" --print-resource-dir
		# shellcheck disable=SC2086
		_termux_android_toolchain_diagnostic_command "$output/compiler-unwind-query" \
			"$cc" $cppflags $cflags $ldflags -print-file-name=libunwind.a
		unwind=$(cat "$output/compiler-unwind-query.txt")
		if [[ "$unwind" == /* && -f "$unwind" ]]; then
			_termux_android_toolchain_diagnostic_command "$output/unwind-file-headers" "$readelf" --file-headers "$unwind"
			_termux_android_toolchain_diagnostic_command "$output/unwind-sha256" sha256sum "$unwind"
		fi
	else
		printf 'Compiler not configured at the failing build stage\n' > "$output/compiler-unavailable.txt"
	fi
	if [[ -f "$prefix/lib/libc++_shared.so" ]]; then
		_termux_android_toolchain_diagnostic_command "$output/libcxx-file-headers" "$readelf" --file-headers "$prefix/lib/libc++_shared.so"
		_termux_android_toolchain_diagnostic_command "$output/libcxx-sha256" sha256sum "$prefix/lib/libc++_shared.so"
	fi
	for label in host target runtime; do
		case "$label" in
			host) directory=$host ;;
			target) directory=$target ;;
			runtime) directory=${target:+$target/compiler-rt} ;;
		esac
		[[ -n "$directory" && -d "$directory" ]] || continue
		for path in CMakeCache.txt CMakeFiles/CMakeConfigureLog.yaml CMakeFiles/CMakeError.log CMakeFiles/CMakeOutput.log; do
			if [[ -f "$directory/$path" ]]; then
				mkdir -p "$output/$label/$(dirname "$path")"
				cp "$directory/$path" "$output/$label/$path"
			fi
		done
	done
	printf 'kind=partial-build-diagnostics\npackage=%s\nbuild_exit_status=%s\ncollection=complete\n' \
		"$name" "$build_status" > "$output/status.txt"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
	[[ "${1:-}" == --collect-diagnostics ]] || exit 2
	shift
	termux_android_toolchain_collect_diagnostics "$@"
fi
