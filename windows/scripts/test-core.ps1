# Runs the shared library tests. Needs build-kiwi.ps1 to have run once.
# ASCII only: Windows PowerShell 5.1 misreads BOM-less UTF-8.
param([switch]$Release)

$repo = (Resolve-Path "$PSScriptRoot\..\..").Path
$kiwi = "$repo\windows\.out\kiwi\Release"
if (-not (Test-Path "$kiwi\kiwi.lib")) { throw 'Kiwi is not built. Run windows\scripts\build-kiwi.ps1 first.' }

# winget updates the registry, not the environment of shells that are already open.
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
$sdkRoot = [Environment]::GetEnvironmentVariable('SDKROOT', 'User')
if ($sdkRoot) { $env:SDKROOT = $sdkRoot }

# kiwi.dll must be findable when the test bundle loads.
$env:Path = "$kiwi;$env:Path"

Push-Location $repo
try {
    if ($Release) { & swift build -c release --product JenaNoteCore } else { & swift test }
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
} finally {
    Pop-Location
}
