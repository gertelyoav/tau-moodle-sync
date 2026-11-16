# save-claude-token.ps1 - optional phone notifications (run save-claude-token.cmd, or answer y in setup.cmd).
# Asks for your Claude notification routine's id and API token. The id goes to config.json
# (claudeRoutineId); the token is saved encrypted with Windows DPAPI in claude-routine-token.dat
# (only your Windows user on this computer can read it). moodle-sync.ps1 uses them to fire the
# routine only when a sync finds something new. How to create the routine: skills/claude/notify-routine.md
. (Join-Path $PSScriptRoot 'common.ps1')
$file    = Join-Path $PSScriptRoot 'claude-routine-token.dat'
$cfgFile = Join-Path $PSScriptRoot 'config.json'
if (-not (Test-Path $cfgFile)) { Write-Host 'Run setup.cmd first.' -ForegroundColor Yellow; exit 1 }
$cfg = Get-Content $cfgFile -Raw -Encoding UTF8 | ConvertFrom-Json

do {
    $id = (Read-Host 'Routine id (starts with trig_; you can also paste the routine''s API address. Enter = cancel)').Trim()
    if (-not $id) { Write-Host 'Nothing changed.'; exit 1 }
    $m = [regex]::Match($id, 'trig_[A-Za-z0-9]+')
    if ($m.Success) { $id = $m.Value }
    $ok = Test-RoutineId $id
    if (-not $ok) { Write-Host 'That is not a routine id. It looks like trig_01Ab... (letters and digits only).' -ForegroundColor Yellow }
} until ($ok)

$sec = Read-Host 'Paste the routine API token (sk-ant-oat01-...) and press Enter' -AsSecureString
if ($sec.Length -lt 20) { Write-Host 'That does not look like a token - nothing saved.' -ForegroundColor Yellow; exit 1 }
$sec | ConvertFrom-SecureString | Set-Content -Path $file
Set-ConfigValue $cfg 'claudeRoutineId' $id
Save-Config $cfg $cfgFile
Write-Host "Saved: routine $id, token encrypted in $file" -ForegroundColor Green
Write-Host 'You will get a notification after the next sync that finds something new.'
