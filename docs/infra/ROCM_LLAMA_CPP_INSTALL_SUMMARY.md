# ROCm llama.cpp Installation Summary

**Status**: Completed  
**Date**: 2026-09-07

## Purpose

This note records the host-side ROCm installation and `llama.cpp` HIP build troubleshooting needed to run a local AMD-backed llama server alongside the `pi-dev-agent` workflow.

The immediate goal was to compile `llama.cpp` with ROCm support on Ubuntu 24.04 (`noble`) for an AMD GPU reported as `gfx1200`, then use that runtime for a local Qwen-based server.

## Initial symptoms

The first HIP configure attempt failed before compilation with:

```text
The ROCm root directory:
 /opt/rocm
does not contain the HIP runtime CMake package
```

The first package install attempt also failed because the ROCm APT repository was configured for the wrong Ubuntu release and lacked the current signing key:

```text
E: The repository 'https://repo.radeon.com/rocm/apt/6.2 jammy InRelease' is not signed.
E: Unable to locate package rocm-hip-runtime-dev
```

## What was corrected

### 1. ROCm repository configuration

The host is on Ubuntu 24.04 (`noble`), so the stale `jammy` ROCm entry had to be replaced.

Working repository configuration pattern:

```bash
sudo mkdir -p /etc/apt/keyrings
wget https://repo.radeon.com/rocm/rocm.gpg.key -O - | \
  gpg --dearmor | sudo tee /etc/apt/keyrings/rocm.gpg > /dev/null

sudo tee /etc/apt/sources.list.d/rocm.list > /dev/null <<'EOF'
deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/rocm/apt/7.2.4 noble main
deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.gpg] https://repo.radeon.com/graphics/7.2.4/ubuntu noble main
EOF

sudo tee /etc/apt/preferences.d/rocm-pin-600 > /dev/null <<'EOF'
Package: *
Pin: release o=repo.radeon.com
Pin-Priority: 600
EOF

sudo apt update
```

### 2. ROCm developer packages

The following packages were installed successfully:

```bash
sudo apt install rocm-hip-runtime-dev
sudo apt install rocm-hip-sdk
```

That pulled in the relevant HIP tooling, including `hipcc`, `rocm-llvm`, `rocm-cmake`, `hip-dev`, and `hipblas-dev`.

## Verified host layout

The actual ROCm install root is versioned:

```text
/opt/rocm-7.2.4
```

Important files confirmed on disk:

```text
/opt/rocm-7.2.4/lib/cmake/hip-lang/hip-lang-config.cmake
/opt/rocm-7.2.4/lib/cmake/hip/hip-config.cmake
/opt/rocm-7.2.4/lib/cmake/AMDDeviceLibs/AMDDeviceLibsConfig.cmake
/opt/rocm-7.2.4/lib/cmake/hipblas/hipblas-config.cmake
```

The generic `/opt/rocm` path is not a plain symlink to `/opt/rocm-7.2.4`. It is an alternatives-managed wrapper tree containing entries such as `bin`, `lib`, `llvm`, and a separate `core-10.0` subtree. That matters because some ROCm CMake packages still resolve dependencies relative to `/opt/rocm`, which can send `find_package()` into the wrong path.

## HIP build findings

### 1. Wrong compiler path

This configure attempt failed because the compiler path did not exist:

```text
CMAKE_HIP_COMPILER:
  /opt/rocm-7.2.4/bin/clang++
is not a full path to an existing compiler tool.
```

The working compiler path discovered later was:

```text
/opt/rocm-7.2.4/lib/llvm/bin/clang
```

Using `HIPCXX` with that compiler got CMake past HIP compiler detection.

### 2. Package discovery mismatch through `/opt/rocm`

With compiler detection fixed, CMake next failed during ROCm package resolution:

```text
include could not find requested file:
  /opt/rocm/lib/cmake/AMDDeviceLibs/../../llvm/lib/cmake/AMDDeviceLibs/AMDDeviceLibsConfig.cmake
```

At the same time, `hipblas` was initially reported missing until the actual package config location was inspected.

The relevant verified directories are:

```text
/opt/rocm-7.2.4/lib/cmake/AMDDeviceLibs
/opt/rocm-7.2.4/lib/cmake/hipblas
```

This points to a root-resolution problem rather than a missing ROCm install.

## Recommended configure command

At the time of writing, the best next configure attempt is to bypass the ambiguous `/opt/rocm` wrapper and pin the real package locations directly:

```bash
rm -rf build

export ROCM_ROOT=/opt/rocm-7.2.4
export HIP_PATH="$ROCM_ROOT"
export PATH="$ROCM_ROOT/bin:$ROCM_ROOT/lib/llvm/bin:$PATH"
export HIPCXX="$ROCM_ROOT/lib/llvm/bin/clang"
export HIP_DEVICE_LIB_PATH="$(find "$ROCM_ROOT" -name oclc_abi_version_400.bc -printf '%h\n' -quit)"

cmake -S . -B build \
  -DGGML_HIP=ON \
  -DGPU_TARGETS=gfx1200 \
  -DCMAKE_BUILD_TYPE=Release \
  -DCMAKE_PREFIX_PATH="$ROCM_ROOT;$ROCM_ROOT/lib/llvm" \
  -DAMDDeviceLibs_DIR="$(realpath /opt/rocm-7.2.4/lib/cmake/AMDDeviceLibs)" \
  -Dhipblas_DIR="$(realpath /opt/rocm-7.2.4/lib/cmake/hipblas)"

cmake --build build --config Release -j 16
```

## GPU target note

The detected AMD GPU reports as `gfx1200`, so the build should use:

```text
-DGPU_TARGETS=gfx1200
```

Using `gfx1030` would target the wrong architecture for this host.

## Model-loading note

After the ROCm work, a separate runtime issue remained when loading a `Qwen3.8-27B.gguf` model:

```text
llama_model_load: error loading model: missing tensor 'blk.64.ssm_conv1d.weight'
```

Inspection of the GGUF tensor names showed that block `64` contains attention and `nextn.*` tensors but not `blk.64.ssm_conv1d.weight`, which suggests a likely loader or GGUF layout compatibility issue rather than a ROCm installation problem.

That model issue should be treated separately from the HIP toolchain setup.

## Current conclusion

- ROCm package installation is complete enough for HIP development.
- The remaining compile blocker is CMake package resolution across the `/opt/rocm` alternatives wrapper versus the real `/opt/rocm-7.2.4` install root.
- The next meaningful validation step is a fresh `cmake` configure using the explicit `AMDDeviceLibs_DIR` and `hipblas_DIR` values above.
- The GGUF tensor-loading failure is a separate incompatibility investigation and not evidence that the ROCm install failed.