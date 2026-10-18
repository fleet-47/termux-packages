# Android AArch64 toolchain

## Sources

Use these revisions:

| Component | Source | Revision |
| --- | --- | --- |
| Package framework | `termux/termux-packages` | `685583badd4d5992fe091a14f0461f1ce49e0c01` |
| LLVM, Clang, LLD | `llvm/llvm-project` | `592953beff733a1e28f6c6e5e39f948fb035a329` (`23.0.0git`) |
| LLVM source selection | Termux Emscripten 6.0.3 recipe | `45c392725145ab57550adf7f1512e24cb219887b` |
| Rust recipe | `termux-user-repository/tur` | `1ab367227ea5788377ba38a6d166c4b7102e2ec1` |
| Rust source | `https://static.rust-lang.org/dist/2026-08-24/rustc-nightly-src.tar.xz` | SHA256 `9b576e815e607528fd79903f96ad9e3065cf466343874e02589afbbbb20ace37` |

Apply the patches in `packages/android-toolchain-llvm/` and
`packages/rustc-nightly/` through the Termux package framework. The LLVM patches
adapt the Termux `packages/libllvm/` Android integration patches to the pinned
LLVM source. Emscripten and Binaryen are not build components.

## Target configuration

Use `android-toolchain.json` for the Android target flags. The target is
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

Use the existing `master` branch of `fleet-47/termux-packages`.
The workflow accepts manual dispatch only and builds the two fixed package
recipes and their dependencies.

```sh
gh workflow run packages.yml --repo fleet-47/termux-packages --ref master
gh run list --repo fleet-47/termux-packages --workflow packages.yml
gh run watch RUN_ID --repo fleet-47/termux-packages --exit-status
```

For the build stage on an x86_64 Linux host with Docker, run from the repository
root:

```sh
./scripts/run-docker.sh ./build-package.sh -I -a aarch64 android-toolchain-llvm rustc-nightly
```

The framework fetches sources, applies package patches, builds the required host
helpers, cross-compiles Android binaries and creates Debian packages in `output/`.
LLVM, Clang and LLD install beneath `$PREFIX/opt/android-toolchain-llvm`.
Rust installs beneath `$PREFIX/opt/rust-nightly`. Use the existing Termux libc++,
Android sysroot and compiler-rt package; Clang's resource directory links to the
installed compiler-rt library directory.

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
  /rust-source /workspace/android-toolchain.json
```

The LLVM runner updates generated interpreter and compiler paths for the test
container and invokes the upstream LLVM, Clang and LLD lit suites. Upstream lit
selects tests applicable to the configured AArch64 backend and Android system.
The Rust runner configures a native Android bootstrap using the newly built
compiler and invokes `x.py test --stage 2 --host aarch64-linux-android
--target aarch64-linux-android --no-fail-fast`. The native Android test patch
uses direct execution when the bootstrap host and target are both Android.

The workflow attempts both suites and returns failure if either fails. The
container uses the runner's CPU and kernel; CPU-dependent execution requires
the instructions enabled by the target profile.

## Retrieve artifacts

```sh
gh run download RUN_ID --repo fleet-47/termux-packages \
  --name android-aarch64-toolchain --dir output
gh run download RUN_ID --repo fleet-47/termux-packages \
  --name android-aarch64-upstream-tests --dir test-output
```

The build artifact contains Debian packages, test inputs, the target profile and
the builder image ID. The test artifact contains upstream test output and the
runtime image digest. To select the toolchain after installing its packages:

```sh
export PATH="$PREFIX/opt/rust-nightly/bin:$PREFIX/opt/android-toolchain-llvm/bin:$PATH"
```
