# Android AArch64 toolchain

## Sources

Use these revisions:

| Component | Source | Revision |
| --- | --- | --- |
| Package framework | `termux/termux-packages` | `685583badd4d5992fe091a14f0461f1ce49e0c01` |
| LLVM, Clang, LLD | `llvm/llvm-project` | `592953beff733a1e28f6c6e5e39f948fb035a329` (`23.0.0git`) |
| LLVM source selection | Termux Emscripten 6.0.3 recipe | `45c392725145ab57550adf7f1512e24cb219887b` |
| Secondary build reference | [guysoft/opencode-termux](https://github.com/guysoft/opencode-termux/tree/20fe9d28c473e329722a63610ac0254652a8382a) | `20fe9d28c473e329722a63610ac0254652a8382a` |
| Android API feature reference | [rust-mobile/ndk](https://github.com/rust-mobile/ndk/tree/5ae5c56f68165ce902845b646b63a7cb15a92ead) | `5ae5c56f68165ce902845b646b63a7cb15a92ead` |
| Rust recipe | `termux-user-repository/tur` | `1ab367227ea5788377ba38a6d166c4b7102e2ec1` |
| Rust source | `https://static.rust-lang.org/dist/2026-08-24/rustc-nightly-src.tar.xz` | SHA256 `9b576e815e607528fd79903f96ad9e3065cf466343874e02589afbbbb20ace37` |

Apply the patches in `packages/android-toolchain-llvm/` and
`packages/rustc-nightly/` through the Termux package framework. The LLVM patches
adapt the Termux `packages/libllvm/` Android integration patches to the pinned
LLVM source. Emscripten and Binaryen are not build components.

## Target configuration

Use `scripts/android-toolchain.json` for the Android target flags. The target is
`aarch64-linux-android`, API 24. Build only the AArch64 LLVM backend.

C and C++ flags:

```text
-march=armv8-a+crc+crypto+lse+dotprod+fp16+i8mm+bf16 -mtune=cortex-x3
```

Rust flags:

```text
-C target-cpu=generic -C target-feature=+neon,+crc,+aes,+sha2,+lse,+dotprod,+fp16,+i8mm,+bf16
```

Apply these flags to Android binaries, libraries and Rust bootstrap target
configuration. Build the x86_64 TableGen and llvm-config helpers with build-host
flags. Do not use `-mcpu=native` or `target-cpu=native` in the CI build.

## Run the workflow

Keep recipes under `packages/` and the profile at `scripts/android-toolchain.json`.
Update affected package recipes alongside profile or framework changes so the
upstream changed-package selection rebuilds them. CI copies the profile to
`android-toolchain.json` for the build.

After reviewing and publishing the `termux-toolchain` branch to
`fleet-47/termux-packages`, dispatch that branch explicitly:

```sh
gh workflow run packages.yml --repo fleet-47/termux-packages --ref termux-toolchain
gh run list --repo fleet-47/termux-packages --workflow packages.yml
```

Dispatch with packages `android-toolchain-llvm rustc-nightly` and `free-space=true`
(the defaults). The build uses `scripts/run-docker.sh -d ./build-package.sh -I -C
-a aarch64`, two build processes, and one LLVM link process. Run the upstream zram
action and load the builder before `scripts/free-space.sh`.

Packages are archived under `artifacts/`; test inputs remain under `output/`.

LLVM, Clang and LLD install beneath `$PREFIX/opt/android-toolchain-llvm`.
Rust installs beneath `$PREFIX/opt/rust-nightly`. Use the existing Termux libc++,
Android sysroot, libc++ and unwind libraries from NDK 30. Build compiler-rt
from the exact same LLVM commit in a separate Android CMake tree, using the
NDK compiler to bootstrap it. Install its libraries, headers and sanitizer
ignorelists in this package's LLVM 23 resource tree. Runtime links explicitly
use the builtins target from that compiler-rt build; there is no resource
symlink or compiler-rt 21 dependency.

This exact-source contract replaces an unsupported cross-version assumption.
The pinned LLVM 23 profiling records/raw format differ from LLVM 21's records.
No general compiler/runtime version range is claimed. libc++ and libunwind
retain their separate NDK ABI contracts.

## Run upstream tests

The LLVM recipe builds `llvm-test-depends`, `clang-test-depends` and
`lld-test-depends`. It exports the patched source and compiled test trees as
`output/android-toolchain-build-support/llvm-tests.tar.zst`, with their original
paths in `llvm-test-paths`. Extract the archive beneath a staging directory and
mount its `home/builder` directory at `/home/builder` in the AArch64 Termux
container. Preserve the paths required by generated lit configuration.

The Rust recipe exports its patched source, including vendored dependencies, as
`output/android-toolchain-build-support/rust-source.tar.xz`. Extract this archive
at `/rust-source` in the container.

Install the generated packages and the test dependencies listed in
`.github/workflows/packages.yml`. Mount the repository at `/workspace`, then run:

```sh
bash packages/android-toolchain-llvm/run-upstream-tests.sh \
  /workspace/output/android-toolchain-build-support/llvm-test-paths
bash packages/rustc-nightly/run-upstream-tests.sh \
  /rust-source /workspace/output/android-toolchain.json 2
```

The LLVM runner updates generated interpreter and compiler paths for the test
container and invokes the upstream LLVM, Clang and LLD lit suites. Upstream lit
selects tests applicable to the configured AArch64 backend and Android system.
The Rust runner configures a native Android bootstrap using the newly built
compiler and invokes `x.py test --stage 0 --host aarch64-linux-android
--target aarch64-linux-android --no-fail-fast`. Stage 0 selects the installed compiler; `compiletest-allow-stage0` enables its
compiletest suites. Bootstrap still builds test harnesses and test inputs.
The Rust runner builds and starts upstream `remote-test-server`, sets
`TEST_DEVICE_ADDR`, and uses a writable `/data/local/tmp/work` mount.

The workflow runs suites for the compiler packages in the build artifacts and
returns failure if any selected suite fails. The
container uses the runner's CPU and kernel; CPU-dependent execution requires
the instructions enabled by the target profile.

## Retrieve artifacts

```sh
gh run download RUN_ID --repo fleet-47/termux-packages \
  --name android-aarch64-toolchain --dir output
gh run download RUN_ID --repo fleet-47/termux-packages \
  --pattern 'debs-aarch64-*' --dir artifacts
tar -xf artifacts/debs-aarch64-*/debs-aarch64-*.tar --strip-components=1 -C output
gh run download RUN_ID --repo fleet-47/termux-packages \
  --name android-aarch64-upstream-tests --dir test-output
```

To select the toolchain after installing its packages:

```sh
export PATH="$PREFIX/opt/rust-nightly/bin:$PREFIX/opt/android-toolchain-llvm/bin:$PATH"
```

Inspect `upstream-tests.log` for `file` and `readelf` output before suite execution.
ELF diagnostics adapt the secondary reference’s `.github/workflows/build.yml`;
program and dynamic headers expose interpreter, TLS segments and library dependencies.
The compiler-runtime presence check applies the resource setup requirement from
its `scripts/build-bun-android.sh` to Termux’s existing runtime layout.

Use the `llvm-build-info.txt`, `llvm-CMakeCache.txt`, `rust-build-info.txt` and
`rust-bootstrap.toml` support artifacts to inspect source revisions, target
compiler selection, API level, flags and runtime-library identities. CI verifies
`llvm-support.sha256` and `rust-support.sha256` before extracting test inputs;
PR reuse retains these files from the producing run.

Nested Rust builds use target-specific `CC`, `CXX`, `AR` and Cargo linker
variables. Keep host compiler settings separate. Cross builds resolve unwind through the actual compiler and flags, since
Termux deliberately skips installing `ndk-sysroot` in that build path. Native
testing verifies that archive's hash against the installed `ndk-sysroot`
file. Verify libc++ and the owned LLVM 23 runtime resources in the same way.

The package installs `llvm-resources.sha256`, `llvm-link-runtimes.sha256` and
`source-commit.txt` under `opt/android-toolchain-llvm/share/android-toolchain-runtime`.
CI validates these before testing, including Rust-only builds, and records
runtime linker traces. Packaging also verifies resource hashes after cleanup.

The runner's `--runtime-only PROFILE` mode tests builtins, outlined atomics,
C++ exceptions, ASan/UBSan clean and expected-failure cases, profile
write/read, CFI valid/invalid indirect calls and optional native static C++
lookup. HWASan/TSan are link checked; device execution remains unqualified.

Partial diagnostic artifacts are independent of complete test-support archives.
`android-aarch64-build-diagnostics` includes the build log, available host,
target and compiler-rt CMake logs/caches, and compiler/runtime inventory even
when source acquisition, configuration or compilation fails.

For consumers of `rust-mobile/ndk`, select API-level features compatible with
API 24. Its `--all-features` configuration enables newer Android APIs and is not
an API-24 compatibility check. Retain the AArch64-only CI target.
