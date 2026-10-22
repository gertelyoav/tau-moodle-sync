# uninstall.ps1 - removes the hourly task and your saved Moodle key. Your downloaded files are kept.
$ErrorActionPreference = 'SilentlyContinue'
Unregister-ScheduledTask -TaskName 'TAU-Moodle-Sync' -Confirm:$false
Remove-Item (Join-Path $PSScriptRoot 'token.dat') -Force
Write-Host 'Removed the hourly sync and the saved Moodle key. Your files were not deleted.'
Write-Host 'To fully revoke the key, open https://moodle.tau.ac.il/user/managetoken.php and click Reset.'
