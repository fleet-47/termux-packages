#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
mapfile -t test_paths < "$1"
source_dir=${test_paths[0]}
build_dir=${test_paths[1]}
prefix=/data/data/com.termux/files/usr
export PATH="$build_dir/bin:$prefix/opt/android-toolchain-llvm/bin:$PATH"
export LD_LIBRARY_PATH="$build_dir/lib:$prefix/opt/android-toolchain-llvm/lib:$prefix/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
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
