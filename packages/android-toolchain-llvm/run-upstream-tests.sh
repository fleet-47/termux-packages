#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
prefix=${PREFIX:-/data/data/com.termux/files/usr}
llvm_prefix="$prefix/opt/android-toolchain-llvm"

if [[ "${1:-}" == --runtime-only ]]; then
	[[ "$#" -eq 2 ]]
	python3 - "$2" "$prefix" <<'PY'
import json
import os
import pathlib
import re
import shlex
import subprocess
import sys
import tempfile

profile = json.loads(pathlib.Path(sys.argv[1]).read_text())
assert profile["target"] == "aarch64-linux-android", profile["target"]
assert profile["api_level"] == 24, profile["api_level"]
prefix = pathlib.Path(sys.argv[2])
llvm = prefix / "opt/android-toolchain-llvm"
resource = llvm / "lib/clang/23"
metadata = llvm / "share/android-toolchain-runtime"
work = pathlib.Path(os.environ.get("TOOLCHAIN_RUNTIME_LOG_DIR") or tempfile.mkdtemp(prefix="llvm23-runtime-gate-"))
work.mkdir(parents=True, exist_ok=True)
work = work.resolve()
environment = os.environ.copy()
environment["PATH"] = f"{llvm}/bin:" + environment["PATH"]
environment["LD_LIBRARY_PATH"] = f"{llvm}/lib:{prefix}/lib:" + environment.get("LD_LIBRARY_PATH", "")
cc = str(llvm / "bin/clang")
cxx = str(llvm / "bin/clang++")

def run(args, log=None, expected=0, diagnostic=None, extra_env=None, cwd=None):
    env = environment.copy()
    env.update(extra_env or {})
    print("+ " + shlex.join(map(str, args)), flush=True)
    result = subprocess.run(list(map(str, args)), stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, text=True, env=env, cwd=cwd)
    if log:
        work.joinpath(log).write_text(result.stdout)
    print(result.stdout, end="", flush=True)
    assert result.returncode == expected, (args, result.returncode, expected)
    if diagnostic:
        assert diagnostic in result.stdout, (diagnostic, result.stdout)
    return result.stdout

assert run([cc, "-dumpversion"]).strip().split(".")[0] == "23"
assert run([cc, "-print-resource-dir"]).strip() == str(resource)
assert resource.resolve() == resource, f"resource directory is redirected: {resource}"
assert metadata.joinpath("source-commit.txt").read_text().strip() == profile["llvm_commit"]
for name in ("llvm-resources.sha256", "llvm-link-runtimes.sha256"):
    manifest = metadata / name
    assert manifest.is_file() and manifest.stat().st_size > 0, manifest
    run(["sha256sum", "-c", manifest], cwd=prefix)
run([cc, "--version"])
search_dirs = run([cc, "-print-search-dirs"], "search-dirs.txt")
native = prefix / "aarch64-linux-android/lib"
assert str(native) in search_dirs, (native, search_dirs)
flags = shlex.split(profile["cflags"])
common = flags + ["-O0", "-g", "-fno-omit-frame-pointer", "-fuse-ld=lld", "-Wl,-t"]
sources = {
    "builtins.c": r"""
#include <stdatomic.h>
static _Atomic unsigned long counter = 7;
static volatile __int128 dividend = (__int128)1234567890123456789LL * 19 + 5;
static volatile __int128 divisor = 19;
int main(void) {
  unsigned long before = atomic_fetch_add_explicit(&counter, 5, memory_order_acq_rel);
  __int128 quotient = dividend / divisor;
  return !(before == 7 && atomic_load(&counter) == 12 &&
           quotient == (__int128)1234567890123456789LL);
}
""",
    "unwind.cpp": r"""
#include <stdexcept>
#include <string>
static int destroyed;
struct Guard { ~Guard() { ++destroyed; } };
__attribute__((noinline)) static void fail() {
  Guard guard;
  throw std::runtime_error("unwind reached catch");
}
int main() {
  try { fail(); }
  catch (const std::runtime_error &error) {
    return !(destroyed == 1 && std::string(error.what()) == "unwind reached catch");
  }
  return 2;
}
""",
    "asan.c": r"""
#include <stdlib.h>
int main(int argc, char **argv) {
  (void)argv;
  volatile int *value = malloc(sizeof(int));
  if (!value) return 2;
  *value = 42;
  if (argc > 1) {
    free((void *)value);
    return *value;
  }
  int result = *value;
  free((void *)value);
  return result != 42;
}
""",
    "ubsan.c": r"""
#include <limits.h>
int main(int argc, char **argv) {
  (void)argv;
  volatile int value = INT_MAX;
  volatile int increment = argc > 1 ? 1 : 0;
  volatile int result = value + increment;
  return argc > 1 ? result == 0 : result != INT_MAX;
}
""",
    "profile.c": "int main(void) { return 0; }\n",
    "cfi.c": r"""
typedef int (*callback)(int);
static int good(int value) { return value + 1; }
static long bad(long value) { return value + 2; }
int main(int argc, char **argv) {
  (void)argv;
  callback volatile target = argc > 1 ? (callback)(void *)bad : good;
  return target(41) != 42;
}
""",
}
for name, content in sources.items():
    work.joinpath(name).write_text(content)

def link(name, source, options=(), compiler=cc, runtime="builtins"):
    trace = run([compiler, *common, *options, work / source, "-o", work / name], f"{name}-link.log")
    selected = set(re.findall(r"(/[^\s()]*libclang_rt[^\s()]*\.(?:a|so(?:\.\d+)*))", trace))
    assert selected, f"no compiler-rt library in {name} linker trace"
    for archive in selected:
        path = pathlib.Path(archive)
        assert path.is_file() and path.resolve().is_relative_to(resource), f"foreign runtime: {archive}"
    assert any(re.search(r"/libclang_rt\." + re.escape(runtime) + r"[-_.].*\.a$", path)
               for path in selected), (name, runtime, selected)
    print(f"verified LLVM 23 {runtime} archive selection", flush=True)
    return trace

# Override LSE features here so outline atomics must come from compiler-rt.
run([cc, *flags, "-march=armv8-a", "-moutline-atomics", "-O0", "-c",
     work / "builtins.c", "-o", work / "builtins.o"])
symbols = run([llvm / "bin/llvm-nm", "-u", work / "builtins.o"], "builtins-symbols.txt")
assert "__divti3" in symbols and "__aarch64_ldadd8_acq_rel" in symbols, symbols
link("builtins", "builtins.o")
run([work / "builtins"])
link("unwind", "unwind.cpp", compiler=cxx)
run([work / "unwind"])
static_trace = link("unwind-static", "unwind.cpp", ["-static-libstdc++"], compiler=cxx)
assert str(native / "libc++_static.a") in static_trace, static_trace
assert str(native / "libc++abi.a") in static_trace, static_trace
run([work / "unwind-static"])

link("asan", "asan.c", ["-fsanitize=address"], runtime="asan")
asan = {"ASAN_OPTIONS": "detect_leaks=0:halt_on_error=1:abort_on_error=0:exitcode=86"}
run([work / "asan"], extra_env=asan)
run([work / "asan", "invalid"], "asan-negative.log", expected=86,
    diagnostic="AddressSanitizer: heap-use-after-free", extra_env=asan)

link("ubsan", "ubsan.c", ["-fsanitize=undefined", "-fno-sanitize-recover=all"], runtime="ubsan_standalone")
ubsan = {"UBSAN_OPTIONS": "halt_on_error=1:abort_on_error=0:exitcode=87"}
run([work / "ubsan"], extra_env=ubsan)
run([work / "ubsan", "invalid"], "ubsan-negative.log", expected=87,
    diagnostic="runtime error: signed integer overflow", extra_env=ubsan)

link("profile", "profile.c", ["-fprofile-instr-generate"], runtime="profile")
run([work / "profile"], extra_env={"LLVM_PROFILE_FILE": str(work / "profile.profraw")})
run([llvm / "bin/llvm-profdata", "merge", "-sparse", work / "profile.profraw",
     "-o", work / "profile.profdata"])
counts = run([llvm / "bin/llvm-profdata", "show", "--all-functions", "--counts",
              work / "profile.profdata"], "profile-counts.txt")
assert re.search(r"(?s)\bmain:\n.*?Function count:\s+1\b", counts), counts

link("cfi", "cfi.c", ["-flto=thin", "-fvisibility=hidden", "-fsanitize=cfi-icall",
     "-fno-sanitize-trap=cfi-icall", "-fno-sanitize-recover=cfi-icall"], runtime="ubsan_standalone")
cfi = {"UBSAN_OPTIONS": "halt_on_error=1:abort_on_error=0:exitcode=88"}
run([work / "cfi"], extra_env=cfi)
run([work / "cfi", "invalid"], "cfi-negative.log", expected=88,
    diagnostic="runtime error: control flow integrity check", extra_env=cfi)

# Link compatibility only; execution certification requires a supported device/kernel.
for sanitizer, archive in (("hwaddress", "hwasan"), ("thread", "tsan")):
    link(f"{archive}-link-only", "profile.c", [f"-fsanitize={sanitizer}"], runtime=archive)
message = "LLVM 23 execution gates passed; HWASan/TSan link checks passed (execution not certified).\n"
work.joinpath("result.txt").write_text(message)
print(message, end="", flush=True)
PY
	exit
fi

[[ "$#" -eq 1 ]]
mapfile -t test_paths < "$1"
[[ "${#test_paths[@]}" -eq 2 ]]
source_dir=${test_paths[0]}
build_dir=${test_paths[1]}
export PATH="$build_dir/bin:$llvm_prefix/bin:$PATH"
export LD_LIBRARY_PATH="$build_dir/lib:$llvm_prefix/lib:$prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
python - "$build_dir" "$prefix" <<'PY'
import pathlib
import re
import shutil
import sys

build = pathlib.Path(sys.argv[1])
prefix = pathlib.Path(sys.argv[2])
replacements = {
    "python_executable": sys.executable,
    "perl_executable": shutil.which("perl"),
    "host_cc": str(build / "bin/clang"),
    "host_cxx": str(build / "bin/clang++"),
    "host_ldflags": f"-L{prefix}/lib -Wl,-rpath,{prefix}/lib",
}
for path in build.rglob("lit.site.cfg.py"):
    content = path.read_text()
    for key, value in replacements.items():
        content = re.sub(
            rf"^config\.{key}\s*=.*$",
            lambda match, key=key, value=value: f"config.{key} = {value!r}",
            content,
            flags=re.MULTILINE,
        )
    path.write_text(content)
PY
exec python "$source_dir/llvm/utils/lit/lit.py" -sv \
	"$build_dir/test" "$build_dir/tools/clang/test" "$build_dir/tools/lld/test"
