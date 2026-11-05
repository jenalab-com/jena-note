# Builds the Windows app with its native libraries into windows\JenaNote\bin\Release\...
# Needs build-kiwi.ps1 to have run once. ASCII only: PowerShell 5.1 misreads BOM-less UTF-8.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot\..\..").Path
$kiwi = "$repo\windows\.out\kiwi\Release"
if (-not (Test-Path "$kiwi\kiwi.lib")) { throw 'Kiwi is not built. Run windows\scripts\build-kiwi.ps1 first.' }

# winget updates the registry, not the environment of shells that are already open.
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
$sdkRoot = [Environment]::GetEnvironmentVariable('SDKROOT', 'User')
if ($sdkRoot) { $env:SDKROOT = $sdkRoot }
$env:DOTNET_CLI_TELEMETRY_OPTOUT = '1'

function Invoke-Checked([string]$Exe, [string[]]$Arguments) {
    # PowerShell 5.1 turns redirected native stderr into errors, so trust only the exit code.
    $ErrorActionPreference = 'Continue'
    & $Exe @Arguments
    if ($LASTEXITCODE -ne 0) { throw "$Exe failed with exit code $LASTEXITCODE" }
}

Push-Location $repo
try {
    Invoke-Checked swift @('build', '-c', 'release', '--product', 'JenaNoteBridge')
    Invoke-Checked swift @('build', '-c', 'release', '--product', 'corpus-dump')
} finally {
    Pop-Location
}

Invoke-Checked dotnet @('build', "$repo\windows\JenaNote\JenaNote.csproj", '-c', 'Release', '--nologo', '-v', 'q')

$output = "$repo\windows\JenaNote\bin\Release\net9.0-windows"
Copy-Item "$repo\.build\out\Products\Release-windows-x86_64\JenaNoteBridge.dll" $output -Force
Copy-Item "$kiwi\kiwi.dll" $output -Force

# The Swift runtime the bridge loads. Measured with dumpbin; check it again when the toolchain changes.
$runtime = Get-ChildItem "$env:LOCALAPPDATA\Programs\Swift\Runtimes\*\usr\bin" | Select-Object -First 1
foreach ($name in '_FoundationICU', 'BlocksRuntime', 'dispatch', 'Foundation', 'FoundationEssentials',
                  'FoundationInternationalization', 'msvcp140', 'swift_Concurrency', 'swift_RegexParser',
                  'swift_StringProcessing', 'swiftCore', 'swiftCRT', 'swiftDispatch', 'swiftObservation',
                  'swiftSynchronization', 'swiftWinSDK', 'vcruntime140', 'vcruntime140_1') {
    Copy-Item (Join-Path $runtime.FullName "$name.dll") $output -Force
}
# The proofreading model is large and rarely changes, so it is only copied when missing.
if (-not (Test-Path "$output\KiwiModel\cong.mdl")) {
    Copy-Item "$repo\shared\JenaNoteCore\Resources\KiwiModel" "$output\KiwiModel" -Recurse
}
# License notices for the bundled engine.
Copy-Item "$repo\Sources\JenaNoteKit\Resources\ThirdParty" $output -Recurse -Force

Write-Output "Built: $output\JenaNote.exe"
