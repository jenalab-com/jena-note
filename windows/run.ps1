# Builds and starts the Windows app, like `make run` on macOS. See scripts\run-app.ps1.
#   .\windows\run.ps1
#   .\windows\run.ps1 G:\work\chapter1.md
#   .\windows\run.ps1 -NoBuild
# ASCII only: Windows PowerShell 5.1 misreads BOM-less UTF-8.
& "$PSScriptRoot\scripts\run-app.ps1" @args
exit $LASTEXITCODE
