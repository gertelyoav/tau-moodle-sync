# save-claude-token.ps1 - optional phone notifications (run save-claude-token.cmd).
# Saves the API token of your Claude notification routine, encrypted with Windows DPAPI
# (only your Windows user on this computer can read it). moodle-sync.ps1 uses it to fire the
# routine only when a sync finds something new. Also set claudeRoutineId in config.json.
$file = Join-Path $PSScriptRoot 'claude-routine-token.dat'
$sec = Read-Host 'Paste the routine API token (sk-ant-oat01-...) and press Enter' -AsSecureString
if ($sec.Length -lt 20) { Write-Host 'That does not look like a token - nothing saved.' -ForegroundColor Yellow; exit 1 }
$sec | ConvertFrom-SecureString | Set-Content -Path $file
Write-Host "Saved (encrypted) to $file" -ForegroundColor Green
