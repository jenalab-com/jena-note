# Opens a document in the built app, types with real key events, saves with Ctrl+S and checks the
# file. The self test cannot catch this: it drives the page directly, without native focus.
# Keys are only sent while the app is in front. Do not use the keyboard while this runs.
# ASCII only: Windows PowerShell 5.1 misreads BOM-less UTF-8.
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot\..\..").Path
Add-Type -AssemblyName System.Windows.Forms, Microsoft.VisualBasic
Add-Type -Namespace JenaKeyboardTest -Name Native -MemberDefinition '[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();'

$folder = Join-Path $env:TEMP ("jena-keyboard-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $folder | Out-Null
$path = Join-Path $folder 'sample.md'
$env:JENANOTE_TEST_DATA = Join-Path $folder 'data'
[IO.File]::WriteAllText($path, "second`n", (New-Object Text.UTF8Encoding($false)))

$process = Start-Process "$repo\windows\JenaNote\bin\Release\net9.0-windows\JenaNote.exe" -ArgumentList "`"$path`"" -PassThru
$failures = 0

function Check([string]$Name, [bool]$Passed, [string]$Detail = '') {
    if (-not $Passed) { $script:failures++ }
    Write-Output "$(if ($Passed) { 'PASS' } else { 'FAIL' })  $Name  $Detail"
}

function Title { (Get-Process -Id $process.Id).MainWindowTitle }

function Send([string]$Keys) {
    [Microsoft.VisualBasic.Interaction]::AppActivate($process.Id) | Out-Null
    Start-Sleep -Milliseconds 300
    $process.Refresh()
    if ([JenaKeyboardTest.Native]::GetForegroundWindow() -ne $process.MainWindowHandle) { throw 'The app is not in front. No keys were sent.' }
    [System.Windows.Forms.SendKeys]::SendWait($Keys)
    Start-Sleep -Milliseconds 400
}

try {
    $deadline = (Get-Date).AddSeconds(30)
    while ($process.MainWindowHandle -eq 0 -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 200; $process.Refresh() }
    Start-Sleep -Seconds 4

    Check 'opens clean' (-not (Title).StartsWith([string][char]0x25CF)) (Title)
    Send 'first{ENTER}'
    Check 'typing marks the document changed' ((Title).StartsWith([string][char]0x25CF)) (Title)
    Send '^b'
    Send 'bold'
    Send '^b'
    Send '{ENTER}'
    Send '^s'
    Start-Sleep -Milliseconds 600
    Check 'Ctrl+S clears the mark' (-not (Title).StartsWith([string][char]0x25CF)) (Title)
    $saved = [IO.File]::ReadAllText($path)
    $expected = "first`n**bold**`nsecond`n"
    Check 'typed text reaches the file' ($saved -ceq $expected) ($saved -replace "`n", '\n')

    # An abrupt end must not lose typing that was never saved.
    Send 'lost{ENTER}'
    Start-Sleep -Seconds 8
    Stop-Process -Id $process.Id -Force
    $process.WaitForExit()
    Check 'the killed app did not touch the file' ([IO.File]::ReadAllText($path) -ceq $expected)

    $process = Start-Process "$repo\windows\JenaNote\bin\Release\net9.0-windows\JenaNote.exe" -PassThru
    Start-Sleep -Seconds 3
    $process.Refresh()
    Send 'y'
    Start-Sleep -Seconds 4
    $process.Refresh()
    Check 'recovered text opens as unsaved' ((Title).StartsWith([string][char]0x25CF)) (Title)
    Send '^s'
    Start-Sleep -Milliseconds 600
    $recovered = [IO.File]::ReadAllText($path)
    Check 'recovered text saves' ($recovered -cmatch 'lost') ($recovered -replace "`n", '\n')
}
finally {
    if (-not $process.HasExited) { $process.CloseMainWindow() | Out-Null; Start-Sleep -Milliseconds 800 }
    if (-not $process.HasExited) { Stop-Process -Id $process.Id -Force }
    Remove-Item $folder -Recurse -Force
}
exit $failures
