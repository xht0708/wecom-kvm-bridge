param(
    [string]$ShareDrive = 'Z:'
)

$ErrorActionPreference = 'Stop'
$shareRoot = Join-Path ($ShareDrive.TrimEnd('\') + '\') 'WeComBridge'
$source = Join-Path $shareRoot 'wecom-watch.ps1'
if (-not (Test-Path -LiteralPath $source)) {
    throw "Could not find $source. Ensure the VirtioFS drive letter is correct. Example: -ShareDrive 'Y:'"
}

$destDir = Join-Path $env:LOCALAPPDATA 'WeComNotifyBridge'
New-Item -ItemType Directory -Force -Path $destDir | Out-Null
$dest = Join-Path $destDir 'wecom-watch.ps1'
Copy-Item -LiteralPath $source -Destination $dest -Force

$exe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$launchArgs = '-NoProfile -Sta -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $dest + '" -ShareRoot "' + $shareRoot + '"'
$startup = [Environment]::GetFolderPath('Startup')
$link = Join-Path $startup 'WeComNotifyBridge.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($link)
$shortcut.TargetPath = $exe
$shortcut.Arguments = $launchArgs
$shortcut.WorkingDirectory = $destDir
$shortcut.WindowStyle = 7
$shortcut.Description = 'Notify Ubuntu about WeCom incoming calls and taskbar flashing'
$shortcut.Save()

Start-Process -FilePath $exe -ArgumentList $launchArgs -WindowStyle Hidden
Write-Host "Installed: $dest"
Write-Host "Autostart shortcut: $link"
Write-Host "Notify events file: $shareRoot\events.log"
Write-Host "Log: $destDir\bridge.log"
Write-Host 'Note: taskbar flash and incoming call detection require validation with real events.'
Write-Host 'IMPORTANT: If a previous listener is still running, sign out and sign in once to load the updated listener.'
