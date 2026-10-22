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
if ($needKey) {
    Write-Host 'Opening the Moodle "Security keys" page in your browser (log in if asked).'
    Write-Host 'Copy the existing key in the row "Moodle mobile web service". Do NOT click Reset.'
    Write-Host 'If there is no key there, log in to the Moodle app on your phone once, then reload the page.'
    Write-Host '(If you do click Reset, the old key stops working: you will need to log in again in the Moodle app on your phone/tablet.)' -ForegroundColor Yellow
    Start-Process "$base/user/managetoken.php"
    while ($true) {
        $sec = Read-Host 'Paste the key here and press Enter (it will not be shown)' -AsSecureString
        $plain = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec)).Trim()
        try {
            $r = Invoke-RestMethod -Uri "$base/webservice/rest/server.php" -Method Post -TimeoutSec 60 `
                   -Body @{ wstoken = $plain; wsfunction = 'core_webservice_get_site_info'; moodlewsrestformat = 'json' }
            if ($r.PSObject.Properties['exception']) { throw $r.message }
            Write-Host "OK - connected to Moodle as $($r.fullname)" -ForegroundColor Green
            $sec | ConvertFrom-SecureString | Set-Content -Path $tokenFile
            break
        } catch { Write-Host "That key did not work ($($_.Exception.Message)). Try again." -ForegroundColor Yellow }
    }
    $plain = $null
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
    $n = [int](Read-Host "Which one should hold the course files? (1-$($drives.Count))")
    $target = Join-Path $drives[$n - 1] 'Moodle'
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
