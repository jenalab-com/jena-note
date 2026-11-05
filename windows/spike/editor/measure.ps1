# Runs each editor candidate at each size. Windows appear on screen while it runs.
# ASCII only: Windows PowerShell 5.1 misreads BOM-less UTF-8.
param([int[]]$Sizes = @(100000, 1000000), [int]$TimeoutSeconds = 300, [string[]]$Only = @('wpf', 'web', 'winui'))

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
$root = $PSScriptRoot
$out = "$root\..\.out\editor"
New-Item -ItemType Directory -Force $out | Out-Null
$out = (Resolve-Path $out).Path
$wpf = "$root\wpf\bin\Release\net9.0-windows\EditorWpf.exe"
$winui = "$root\winui\bin\Release\net9.0-windows10.0.26100.0\win-x64\EditorWinUI.exe"

function Save-Screen([string]$Path) {
    $bounds = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
    $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
    $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
    $graphics.CopyFromScreen($bounds.Location, [System.Drawing.Point]::Empty, $bounds.Size)
    $bitmap.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $graphics.Dispose(); $bitmap.Dispose()
}

$runs = @(
    @{ name = 'wpf'; exe = $wpf; prefix = @('wpf') },
    @{ name = 'web'; exe = $wpf; prefix = @('web') },
    @{ name = 'winui'; exe = $winui; prefix = @() }
)

foreach ($size in $Sizes) {
    foreach ($run in ($runs | Where-Object { $Only -contains $_.name })) {
        $json = "$out\$($run.name)-$size.json"
        if (Test-Path $json) { Remove-Item $json }
        $arguments = $run.prefix + @('--chars', "$size", '--out', "`"$json`"")
        $process = Start-Process $run.exe -ArgumentList $arguments -PassThru
        $deadline = (Get-Date).AddSeconds($TimeoutSeconds)
        while (-not (Test-Path $json) -and -not $process.HasExited -and (Get-Date) -lt $deadline) { Start-Sleep -Milliseconds 500 }
        if (Test-Path $json) { Start-Sleep -Milliseconds 1200; Save-Screen "$out\$($run.name)-$size.png"; $state = 'done' }
        elseif ($process.HasExited) { $state = "crashed exit=$($process.ExitCode)" }
        else { $state = "timeout after $TimeoutSeconds s" }
        if (-not $process.WaitForExit(8000)) { Stop-Process -Id $process.Id -Force }
        "$($run.name) $size $state"
    }
}
