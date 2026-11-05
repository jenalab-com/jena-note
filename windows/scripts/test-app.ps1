# Runs the built app's self test through the real DLL and WebView2. A window appears briefly.
# The toolchains are left off PATH on purpose, so a missing DLL in the app folder fails here.
# ASCII only: Windows PowerShell 5.1 misreads BOM-less UTF-8.
$repo = (Resolve-Path "$PSScriptRoot\..\..").Path
$out = "$repo\windows\.out\selftest"
New-Item -ItemType Directory -Force $out | Out-Null
$corpus = "$out\corpus.json"
$report = "$out\report.txt"
if (Test-Path $report) { Remove-Item $report }

$sdkRoot = [Environment]::GetEnvironmentVariable('SDKROOT', 'User')
$savedPath = $env:Path
$env:Path = [Environment]::GetEnvironmentVariable('Path', 'Machine') + ';' + [Environment]::GetEnvironmentVariable('Path', 'User')
if ($sdkRoot) { $env:SDKROOT = $sdkRoot }
& "$repo\.build\out\Products\Release-windows-x86_64\corpus-dump.exe" $corpus
if ($LASTEXITCODE -ne 0) { throw 'corpus-dump failed' }

$env:Path = "$env:SystemRoot\system32;$env:SystemRoot;$env:ProgramFiles\dotnet"
Remove-Item env:SDKROOT -ErrorAction SilentlyContinue
$process = Start-Process "$repo\windows\JenaNote\bin\Release\net9.0-windows\JenaNote.exe" `
    -ArgumentList '--selftest', "`"$corpus`"", "`"$report`"" -PassThru
$env:Path = $savedPath
if (-not $process.WaitForExit(180000)) {
    Stop-Process -Id $process.Id -Force
    throw 'self test timed out'
}
$code = $process.ExitCode
if (Test-Path $report) { Get-Content $report -Encoding UTF8 } else { Write-Output 'no report written' }
Write-Output "exit=$code"
exit $code
