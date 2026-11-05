# Builds the vendored Kiwi engine as a DLL into windows\.out\kiwi. Takes about 10 minutes on a slow CPU.
# ASCII only: Windows PowerShell 5.1 misreads BOM-less UTF-8.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot\..\..").Path
$build = "$repo\windows\.out\kiwi"

# With cpuinfo off, Kiwi finds x86 through __x86_64__, which MSVC does not define.
# KIWI_ARCH_X86 selects the same SSE2 path as an Intel Mac. KIWI_ARCH_X86_64 would assume AVX-512.
# *_FLAGS_INIT only applies to a fresh build directory and keeps CMake's default /EHsc.
$configure = @(
    '-S', "$repo\Vendor\Kiwi\source", '-B', $build, '-G', 'Visual Studio 17 2022', '-A', 'x64',
    '-DCMAKE_C_FLAGS_INIT=/DKIWI_ARCH_X86', '-DCMAKE_CXX_FLAGS_INIT=/DKIWI_ARCH_X86',
    '-DKIWI_BUILD_DYNAMIC=ON', '-DKIWI_BUILD_CLI=OFF', '-DKIWI_BUILD_EVALUATOR=OFF', '-DKIWI_BUILD_MODEL_BUILDER=OFF',
    '-DKIWI_BUILD_TEST=OFF', '-DKIWI_JAVA_BINDING=OFF', '-DKIWI_USE_MIMALLOC=ON', '-DKIWI_USE_CPUINFO=OFF'
)

# PowerShell 5.1 turns redirected native stderr into errors, so trust only the exit code.
$ErrorActionPreference = 'Continue'
& cmake @configure
if ($LASTEXITCODE -ne 0) { throw "cmake configure failed with exit code $LASTEXITCODE" }
& cmake --build $build --config Release --target kiwi --parallel 4
if ($LASTEXITCODE -ne 0) { throw "cmake build failed with exit code $LASTEXITCODE" }
