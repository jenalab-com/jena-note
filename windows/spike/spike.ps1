# Windows spike runner. ASCII only: Windows PowerShell 5.1 misreads BOM-less UTF-8.
# Usage: spike.ps1 [sync|kiwi|build|test|harness|all]
param([string]$Step = 'all')

$ErrorActionPreference = 'Stop'
$spike = $PSScriptRoot
$repo = (Resolve-Path "$spike\..\..").Path
$interop = "$spike\interop"
$out = "$spike\.out"
$kit = "$repo\Sources\JenaNoteKit"

# winget updates the registry, not the environment of shells that are already open.
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
$sdkRoot = [Environment]::GetEnvironmentVariable('SDKROOT', 'User')
if (-not $sdkRoot) { $sdkRoot = [Environment]::GetEnvironmentVariable('SDKROOT', 'Machine') }
if ($sdkRoot) { $env:SDKROOT = $sdkRoot }

function Invoke-Checked {
    param([string]$Exe, [string[]]$Arguments)
    # PowerShell 5.1 turns redirected native stderr into errors, so trust only the exit code.
    $ErrorActionPreference = 'Continue'
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe failed with exit code $LASTEXITCODE" }
}

function Sync {
    # Unmodified copies: a compile or test failure here is a real portability finding.
    $sources = "$interop\Sources\JenaNoteKit\Imported"
    $tests = "$interop\Tests\JenaNoteKitTests\Imported"
    foreach ($dir in $sources, $tests) {
        if (Test-Path $dir) { Remove-Item $dir -Recurse -Force }
        New-Item -ItemType Directory -Force $dir | Out-Null
    }
    foreach ($file in 'export\DocumentModel.swift', 'export\HwpxWriter.swift', 'export\XMLEscape.swift', 'export\ZipArchive.swift',
                      'proofreading\KiwiProofreadingEngine.swift', 'proofreading\KoreanOrthographyRules.swift',
                      'proofreading\ProofreadingSuggestion.swift', 'proofreading\ProofreadingAnnotations.swift',
                      'ai\AILocalInferenceQueue.swift', 'ai\AISelectionProofreader.swift') {
        Copy-Item "$kit\$file" $sources
    }
    foreach ($file in 'KiwiProofreadingTests.swift', 'HwpxWriterTests.swift', 'ZipArchiveTests.swift') {
        # The only edit: these tests shell out to /usr/bin/unzip. Assertions stay as they are.
        $text = [IO.File]::ReadAllText("$repo\Tests\JenaNoteKitTests\$file", [Text.Encoding]::UTF8)
        $text = $text.Replace('/usr/bin/unzip', 'C:/Program Files/Git/usr/bin/unzip.exe')
        [IO.File]::WriteAllText("$tests\$file", $text, (New-Object Text.UTF8Encoding($false)))
    }
    Copy-Item "$repo\Vendor\Kiwi\source\include\kiwi\capi.h", "$repo\Vendor\Kiwi\source\include\kiwi\Macro.h" "$interop\Modules\Kiwi"
    $model = "$interop\Sources\JenaNoteKit\Resources\KiwiModel"
    if (-not (Test-Path "$model\cong.mdl")) {
        New-Item -ItemType Directory -Force (Split-Path $model) | Out-Null
        Copy-Item "$kit\Resources\KiwiModel" $model -Recurse
    }
}

function Build-Kiwi {
    # Same engine options as Vendor/Kiwi/scripts/build-kiwi.sh, but as a DLL.
    # With cpuinfo off, Kiwi finds x86 through __x86_64__, which MSVC does not define.
    # KIWI_ARCH_X86 selects the same SSE2 path. KIWI_ARCH_X86_64 would assume AVX-512.
    # *_FLAGS_INIT only applies to a fresh build directory and keeps CMake's default /EHsc.
    Invoke-Checked cmake @('-S', "$repo\Vendor\Kiwi\source", '-B', "$out\kiwi", '-G', 'Visual Studio 17 2022', '-A', 'x64',
        '-DCMAKE_C_FLAGS_INIT=/DKIWI_ARCH_X86', '-DCMAKE_CXX_FLAGS_INIT=/DKIWI_ARCH_X86',
        '-DKIWI_BUILD_DYNAMIC=ON', '-DKIWI_BUILD_CLI=OFF', '-DKIWI_BUILD_EVALUATOR=OFF', '-DKIWI_BUILD_MODEL_BUILDER=OFF',
        '-DKIWI_BUILD_TEST=OFF', '-DKIWI_JAVA_BINDING=OFF', '-DKIWI_USE_MIMALLOC=ON', '-DKIWI_USE_CPUINFO=OFF')
    Invoke-Checked cmake @('--build', "$out\kiwi", '--config', 'Release', '--target', 'kiwi', '--parallel', '4')
}

function Add-RuntimePath {
    $products = "$interop\.build\out\Products"
    $env:Path = "$out\kiwi\Release;$products\Release-windows-x86_64;$products\Debug-windows-x86_64;$env:Path"
}

function Build-Interop {
    Push-Location $interop
    try { Invoke-Checked swift @('build', '-c', 'release') } finally { Pop-Location }
}

function Test-Interop {
    Add-RuntimePath
    Push-Location $interop
    try { Invoke-Checked swift @('test') } finally { Pop-Location }
}

function Run-Harness {
    Add-RuntimePath
    Invoke-Checked dotnet @('run', '--project', "$spike\harness", '-c', 'Release', '--', "$kit\Resources\KiwiModel")
}

switch ($Step) {
    'sync' { Sync }
    'kiwi' { Build-Kiwi }
    'build' { Sync; Build-Interop }
    'test' { Sync; Test-Interop }
    'harness' { Run-Harness }
    'all' { Sync; Build-Kiwi; Build-Interop; Test-Interop; Run-Harness }
    default { throw "unknown step: $Step" }
}
