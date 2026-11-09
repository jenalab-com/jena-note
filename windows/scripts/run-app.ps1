# Builds the app and starts it, like `make run` on macOS. Files given after the options open in it.
#   .\windows\scripts\run-app.ps1
#   .\windows\scripts\run-app.ps1 G:\work\chapter1.md
#   .\windows\scripts\run-app.ps1 -NoBuild
# ASCII only: Windows PowerShell 5.1 misreads BOM-less UTF-8.
param(
    [switch]$NoBuild,
    [Parameter(ValueFromRemainingArguments = $true)][string[]]$Files
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path "$PSScriptRoot\..\..").Path
$exe = "$repo\windows\JenaNote\bin\Release\net9.0-windows\JenaNote.exe"

if (-not $NoBuild) {
    # A running copy locks its files, so the build would fail halfway. It may hold unsaved
    # writing, so it is never closed from here.
    $running = Get-Process JenaNote -ErrorAction SilentlyContinue
    if ($running) {
        Write-Output "JenaNote is running (pid $($running.Id -join ', ')). Close it and run this again, or use -NoBuild."
        exit 1
    }
    & "$PSScriptRoot\build-app.ps1"
    if (-not $?) { exit 1 }
}

if (-not (Test-Path $exe)) { throw "No app at $exe. Run this without -NoBuild first." }
$arguments = @($Files | Where-Object { $_ } | ForEach-Object { '"' + (Resolve-Path -LiteralPath $_).Path + '"' })
if ($arguments.Count -gt 0) { Start-Process $exe -ArgumentList $arguments } else { Start-Process $exe }
Write-Output "Started: $exe"
