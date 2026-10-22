# setup.ps1 - one-time setup (run setup.cmd).
# 1. Stores your personal Moodle key encrypted in token.dat (Windows DPAPI: only your Windows user
#    on this computer can decrypt it). The key is never written in plain text and never leaves your
#    computer except to the Moodle site itself.
# 2. Finds your Google Drive folder and writes config.json.
# 3. Creates a scheduled task that syncs every hour (07:00-23:00) and runs the first sync.

$ErrorActionPreference = 'Stop'
$root     = $PSScriptRoot
$taskName = 'TAU-Moodle-Sync'
$cfgFile  = Join-Path $root 'config.json'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

function Ask-YesNo([string]$q) { do { $a = (Read-Host "$q [y/n]").Trim().ToLower() } until ($a -in 'y','n'); return $a -eq 'y' }

$cfg = if (Test-Path $cfgFile) { Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json } else { Get-Content (Join-Path $root 'config.example.json') -Raw -Encoding UTF8 | ConvertFrom-Json }
$base = ([string]$cfg.moodleUrl).TrimEnd('/')

Write-Host ''
Write-Host '=== Step 1/3: your Moodle key ===' -ForegroundColor Cyan
$tokenFile = Join-Path $root 'token.dat'
$needKey = $true
if (Test-Path $tokenFile) { $needKey = Ask-YesNo 'A Moodle key is already saved. Replace it?' }
function Test-MoodleKey([string]$key) {
    $r = Invoke-RestMethod -Uri "$base/webservice/rest/server.php" -Method Post -TimeoutSec 60 `
           -Body @{ wstoken = $key; wsfunction = 'core_webservice_get_site_info'; moodlewsrestformat = 'json' }
    if ($r.PSObject.Properties['exception']) { throw $r.message }
    return $r
}

function Get-KeyViaBrowser {
    # Moodle shows key names, not the keys. The official app gets its key by opening
    # admin/tool/mobile/launch.php, which redirects to moodlemobile://token=... with your EXISTING key
    # (nothing is reset, the phone app keeps working). We register a temporary handler for
    # moodlemobile:// (current user only, removed right after) to catch that redirect.
    $catch   = Join-Path $env:TEMP ('moodle-key-' + [guid]::NewGuid().ToString('N'))
    $handler = "$catch.ps1"; $out = "$catch.txt"
    Set-Content -Path $handler -Encoding UTF8 -Value "param([string]`$u) Set-Content -LiteralPath '$out' -Value `$u"
    $reg = 'HKCU\Software\Classes\moodlemobile'; $backup = "$catch.reg"
    $k = 'HKCU:\Software\Classes\moodlemobile'
    $hadKey = Test-Path $k
    if ($hadKey) { cmd.exe /c "reg export `"$reg`" `"$backup`" /y >nul 2>&1" }
    try {
        New-Item -Path "$k\shell\open\command" -Force | Out-Null
        Set-ItemProperty -Path $k -Name '(default)' -Value 'URL:moodlemobile'
        Set-ItemProperty -Path $k -Name 'URL Protocol' -Value ''
        Set-ItemProperty -Path "$k\shell\open\command" -Name '(default)' -Value "powershell.exe -NoProfile -WindowStyle Hidden -ExecutionPolicy Bypass -File `"$handler`" `"%1`""
        $passport = Get-Random -Minimum 100000 -Maximum 999999
        Start-Process "$base/admin/tool/mobile/launch.php?service=moodle_mobile_app&passport=$passport&urlscheme=moodlemobile"
        Write-Host 'Your browser opened Moodle. Log in if asked.'
        Write-Host 'When the browser asks to open "Windows PowerShell" (or "Open link?"), click Open / Allow.' -ForegroundColor Yellow
        for ($i = 0; $i -lt 180 -and -not (Test-Path $out); $i++) { Start-Sleep -Seconds 1 }
        if (-not (Test-Path $out)) { return $null }
        $url = (Get-Content -LiteralPath $out -Raw).Trim()
        $raw = $url -replace '^moodlemobile://token=', '' -replace '[^A-Za-z0-9+/=]', ''
        foreach ($b64 in @($raw, $raw.TrimEnd('/'))) {
            try {
                while ($b64.Length % 4) { $b64 += '=' }
                $parts = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($b64)) -split ':::'
                if ($parts.Count -ge 2 -and $parts[1] -match '^[0-9a-f]{32}$') { return $parts[1] }
            } catch {}
        }
        return $null
    } finally {
        Remove-Item -LiteralPath $out, $handler -Force -ErrorAction SilentlyContinue
        Remove-Item -Path $k -Recurse -Force -ErrorAction SilentlyContinue
        if ($hadKey -and (Test-Path $backup)) { cmd.exe /c "reg import `"$backup`" >nul 2>&1" }
        Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    }
}

if ($needKey) {
    Write-Host 'Getting your existing Moodle key (nothing is reset - the Moodle app on your phone keeps working).'
    Write-Host 'Do NOT click "Reset" on the Moodle "Security keys" page: that would log out the Moodle app on your phone/tablet.' -ForegroundColor Yellow
    $saved = $false
    for ($try = 1; $try -le 2 -and -not $saved; $try++) {
        $key = Get-KeyViaBrowser
        if (-not $key) { Write-Host 'Did not receive the key from the browser.' -ForegroundColor Yellow; continue }
        try {
            $r = Test-MoodleKey $key
            Write-Host "OK - connected to Moodle as $($r.fullname)" -ForegroundColor Green
            ConvertTo-SecureString $key -AsPlainText -Force | ConvertFrom-SecureString | Set-Content -Path $tokenFile
            $saved = $true
        } catch { Write-Host "The key did not work ($($_.Exception.Message))." -ForegroundColor Yellow }
        $key = $null
    }
    if (-not $saved) { Write-Host 'Could not get the Moodle key. Run setup.cmd again, or see "Troubleshooting" in README.md.' -ForegroundColor Red; exit 1 }
}

Write-Host ''
Write-Host '=== Step 2/3: where to save the files ===' -ForegroundColor Cyan
$drives = @(Get-PSDrive -PSProvider FileSystem | ForEach-Object {
    foreach ($n in 'My Drive', 'האחסון שלי') { $p = Join-Path $_.Root $n; if (Test-Path -LiteralPath $p) { $p } }
})
$target = $null
if ($drives.Count -eq 1) {
    if (Ask-YesNo "Found Google Drive at $($drives[0]). Save the course files in $($drives[0])\Moodle?") { $target = Join-Path $drives[0] 'Moodle' }
} elseif ($drives.Count -gt 1) {
    Write-Host 'Found several Google Drive accounts:'
    for ($i = 0; $i -lt $drives.Count; $i++) { Write-Host "  $($i + 1). $($drives[$i])" }
    Write-Host '  0. none of these (choose another folder)'
    do { $n = (Read-Host "Which one should hold the course files? (0-$($drives.Count))").Trim() } until ($n -match '^\d+$' -and [int]$n -le $drives.Count)
    if ([int]$n -gt 0) { $target = Join-Path $drives[[int]$n - 1] 'Moodle' }
} else {
    Write-Host 'Google Drive for desktop was not found. Install it (https://www.google.com/drive/download/) so Gemini/Claude can read the files,' -ForegroundColor Yellow
    Write-Host 'or the files will be saved locally in this folder.' -ForegroundColor Yellow
}
if (-not $target) {
    $custom = (Read-Host 'Folder to save the files in (Enter = the Moodle folder next to this script)').Trim()
    $target = if ($custom) { $custom } else { Join-Path $root 'Moodle' }
}
$cfg.moodleFolder = $target

$opt = @($cfg.notionCourses)
if ($opt.Count) {
    $names = ($opt | ForEach-Object { $_.name }) -join ', '
    if (-not (Ask-YesNo "Also copy the course website(s) on Notion ($names)? Answer y only if you take that course")) { $cfg.notionCourses = @() }
}
$cfg | ConvertTo-Json -Depth 5 | Set-Content -Path $cfgFile -Encoding UTF8
Write-Host "OK - files will be saved in $target" -ForegroundColor Green

Write-Host ''
Write-Host '=== Step 3/3: hourly sync ===' -ForegroundColor Cyan
$sync = Join-Path $root 'moodle-sync.ps1'
$user = [Security.Principal.WindowsIdentity]::GetCurrent().Name
$action   = New-ScheduledTaskAction -Execute 'powershell.exe' -WorkingDirectory $root `
              -Argument "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$sync`""
$trigger  = New-ScheduledTaskTrigger -Daily -At '07:00'
$trigger.Repetition = (New-ScheduledTaskTrigger -Once -At '07:00' -RepetitionInterval (New-TimeSpan -Hours 1) -RepetitionDuration (New-TimeSpan -Hours 16)).Repetition
$settings = New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries `
              -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 30)
$principal = New-ScheduledTaskPrincipal -UserId $user -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName $taskName -Description 'Download my course files from Moodle every hour' `
    -Trigger $trigger -Action $action -Settings $settings -Principal $principal -Force | Out-Null
Write-Host "OK - task '$taskName' runs every hour from 07:00 to 23:00" -ForegroundColor Green

Write-Host ''
Write-Host 'Running the first sync now (the first time takes a few minutes)...' -ForegroundColor Cyan
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $sync
Write-Host ''
Write-Host 'Done. Next: connect Gemini or Claude - see README.md.' -ForegroundColor Green
