# tests/run-tests.ps1 - checks that need no Moodle account, no network and no Google Drive.
# Run on Windows:  powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1
# Exit code 0 = all passed. Runs on Windows PowerShell 5.1 (the target) and PowerShell 7.
# The same script runs on every push and pull request in GitHub Actions (.github/workflows/tests.yml).

$ErrorActionPreference = 'Stop'
$repo = Split-Path $PSScriptRoot -Parent
$script:failed = 0
$script:passed = 0

function Test-Case([string]$name, [scriptblock]$body) {
    try { & $body; $script:passed++; Write-Host "  PASS  $name" -ForegroundColor Green }
    catch { $script:failed++; Write-Host "  FAIL  $name`n        $($_.Exception.Message)" -ForegroundColor Red }
}
function Assert-True($cond, [string]$msg) { if (-not $cond) { throw $msg } }
function Assert-Equal($expected, $actual, [string]$msg) {
    $e = ($expected | ForEach-Object { [string]$_ }) -join ','
    $a = ($actual   | ForEach-Object { [string]$_ }) -join ','
    if ($e -ne $a) { throw "$msg - expected [$e], got [$a]" }
}
function Assert-Throws([scriptblock]$body, [string]$msg) {
    $threw = $false
    try { & $body } catch { $threw = $true }
    if (-not $threw) { throw $msg }
}
function Read-Text([string]$rel) { Get-Content -LiteralPath (Join-Path $repo $rel) -Raw -Encoding UTF8 }

$common = Join-Path $repo 'common.ps1'
if (Test-Path $common) { . $common }

# Files tracked by git (falls back to all files when git is not available, e.g. in a ZIP download)
$tracked = @()
try { $tracked = @(git -C $repo ls-files 2>$null) } catch {}
if (-not $tracked.Count) {
    $tracked = @(Get-ChildItem -Path $repo -Recurse -File | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' } |
        ForEach-Object { $_.FullName.Substring($repo.Length + 1) -replace '\\', '/' })
}

Write-Host ''
Write-Host '=== Repository checks ===' -ForegroundColor Cyan

Test-Case 'every PowerShell script parses without errors' {
    $bad = @()
    foreach ($f in Get-ChildItem -Path $repo -Recurse -Filter *.ps1 | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }) {
        $errs = $null
        [void][System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$errs)
        if ($errs) { $bad += "$($f.Name): $($errs[0].Message) (line $($errs[0].Extent.StartLineNumber))" }
    }
    Assert-True (-not $bad.Count) ($bad -join '; ')
}

Test-Case '.gitignore keeps personal files out of git' {
    $gi = (Read-Text '.gitignore') -split "`r?`n" | ForEach-Object { $_.Trim() }
    foreach ($p in 'config.json', 'token.dat', 'claude-routine-token.dat', 'log.txt', 'Moodle/') {
        Assert-True ($gi -contains $p) ".gitignore is missing $p"
    }
    foreach ($p in 'config.json', 'token.dat', 'claude-routine-token.dat', 'log.txt') {
        Assert-True (-not ($tracked -contains $p)) "$p is tracked by git"
    }
}

Test-Case 'no tracked file contains a real key or routine id' {
    $patterns = @(
        @{ re = '(?<![0-9a-fA-F])[0-9a-f]{32}(?![0-9a-fA-F])'; what = 'a Moodle key (32 hex characters)' },
        @{ re = 'sk-ant-[a-z0-9]+-[A-Za-z0-9_\-]{20,}';      what = 'a Claude token' },
        @{ re = 'trig_[A-Za-z0-9]{8,}';                      what = 'a routine id' }
    )
    $hits = @()
    foreach ($rel in $tracked) {
        if ($rel -like 'tests/*') { continue }
        $path = Join-Path $repo $rel
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $text = Get-Content -LiteralPath $path -Raw -Encoding UTF8
        if (-not $text) { continue }
        foreach ($p in $patterns) { if ($text -match $p.re) { $hits += "$rel looks like it contains $($p.what)" } }
    }
    Assert-True (-not $hits.Count) ($hits -join '; ')
}

Test-Case 'config.example.json is valid and has every setting' {
    $cfg = Read-Text 'config.example.json' | ConvertFrom-Json
    foreach ($k in 'moodleUrl', 'moodleFolder', 'moodleMaxFileMB', 'moodleSkipCourses', 'claudeRoutineId', 'notionCourses') {
        Assert-True ($cfg.PSObject.Properties.Name -contains $k) "missing $k"
    }
    Assert-True ([string]$cfg.claudeRoutineId -eq '') 'claudeRoutineId must be empty in the example'
}

Test-Case 'every relative link in README.md points to a file in the repo' {
    $readme = Read-Text 'README.md'
    $missing = @()
    foreach ($m in [regex]::Matches($readme, '\]\(([^)#\s]+)\)')) {
        $target = $m.Groups[1].Value
        if ($target -match '^(https?:|mailto:)') { continue }
        if (-not (Test-Path -LiteralPath (Join-Path $repo $target))) { $missing += $target }
    }
    Assert-True (-not $missing.Count) ("missing: " + ($missing -join ', '))
}

Test-Case 'README explains how to update and links the latest release' {
    $readme = Read-Text 'README.md'
    Assert-True ($readme -match '## עדכון') 'no update section (## עדכון ...)'
    Assert-True ($readme -match 'releases/latest') 'no link to releases/latest'
}

Test-Case 'a ready-made notification routine prompt is included' {
    $p = Join-Path $repo 'skills/claude/notify-routine.md'
    Assert-True (Test-Path $p) 'skills/claude/notify-routine.md is missing'
    $t = Read-Text 'skills/claude/notify-routine.md'
    Assert-True ($t -match 'routine-fire-payload') 'prompt does not mention <routine-fire-payload>'
    Assert-True ($t -match 'PushNotification') 'prompt does not mention PushNotification'
}

Test-Case 'bug report form asks for the log and warns about keys' {
    $p = Join-Path $repo '.github/ISSUE_TEMPLATE/bug_report.yml'
    Assert-True (Test-Path $p) '.github/ISSUE_TEMPLATE/bug_report.yml is missing'
    $t = Read-Text '.github/ISSUE_TEMPLATE/bug_report.yml'
    Assert-True ($t -match 'log\.txt') 'form does not ask for log.txt'
    Assert-True ($t -match 'token\.dat') 'form does not warn about token.dat'
}

Test-Case 'LICENSE names the copyright holder' {
    $line = ((Read-Text 'LICENSE') -split "`r?`n" | Where-Object { $_ -match '^Copyright' } | Select-Object -First 1)
    Assert-True ($line -match '^Copyright \(c\) \d{4}\s+\S') "copyright line has no name: '$line'"
}

Test-Case 'the sync and the setup share common.ps1' {
    Assert-True (Test-Path $common) 'common.ps1 is missing'
    foreach ($f in 'moodle-sync.ps1', 'setup.ps1') {
        Assert-True ((Read-Text $f) -match "Join-Path \`$PSScriptRoot 'common\.ps1'") "$f does not load common.ps1"
    }
    Assert-True (-not ((Read-Text 'moodle-sync.ps1') -match 'function Get-CourseName')) 'moodle-sync.ps1 still has its own Get-CourseName'
}

Write-Host ''
Write-Host '=== Logic checks (common.ps1) ===' -ForegroundColor Cyan

$prob    = [pscustomobject]@{ id = 11; fullname = '0366201001 - מבוא להסתברות0366201001 - Introduction to Probability Theory'; shortname = '0366201001' }
$ds      = [pscustomobject]@{ id = 12; fullname = '0368234401 - מבני נתונים'; shortname = '0368234401' }
$archive = [pscustomobject]@{ id = 13; fullname = '5800030001 - מאגר בחינות'; shortname = '5800030001' }
$plain   = [pscustomobject]@{ id = 14; fullname = 'Student lounge'; shortname = 'lounge' }

Test-Case 'Get-CourseName turns Moodle names into "name (number)"' {
    Assert-Equal 'מבוא להסתברות (0366201001)' (Get-CourseName $prob.fullname) 'two-language name'
    Assert-Equal 'מבני נתונים (0368234401)' (Get-CourseName $ds.fullname) 'one-language name'
    Assert-Equal 'Student lounge' (Get-CourseName $plain.fullname) 'name without a number'
}

Test-Case 'Get-CourseNumber finds the course number' {
    Assert-Equal '0366201001' (Get-CourseNumber $prob) 'from fullname'
    Assert-Equal 'lounge' (Get-CourseNumber $plain) 'falls back to shortname'
}

Test-Case 'Test-CourseSkipped skips only the listed courses' {
    Assert-True (Test-CourseSkipped $archive @('5800030001')) 'archive should be skipped'
    Assert-True (-not (Test-CourseSkipped $prob @('5800030001'))) 'probability should not be skipped'
    Assert-True (-not (Test-CourseSkipped $prob @())) 'empty list skips nothing'
    Assert-True (-not (Test-CourseSkipped $prob @('', $null))) 'blank entries skip nothing'
}

Test-Case 'Get-SuggestedSkips suggests the exam archive only when enrolled in it' {
    Assert-Equal '5800030001' (Get-SuggestedSkips @($prob, $archive, $ds)) 'enrolled in the archive'
    Assert-Equal '' (Get-SuggestedSkips @($prob, $ds)) 'not enrolled in the archive'
}

Test-Case 'Resolve-SkipAnswer understands the answers setup accepts' {
    $list = @($prob, $ds, $archive)
    Assert-Equal '5800030001' (Resolve-SkipAnswer $list '' @('5800030001')) 'Enter keeps the suggestion'
    Assert-Equal '' (Resolve-SkipAnswer $list '0' @('5800030001')) '0 skips nothing'
    Assert-Equal '0366201001,5800030001' (Resolve-SkipAnswer $list ' 1, 3 ' @()) 'numbers from the list'
    Assert-Equal '0368234401' (Resolve-SkipAnswer $list '2 2' @()) 'duplicates removed, spaces allowed'
    Assert-Throws { Resolve-SkipAnswer $list '4' @() } 'a number outside the list must be rejected'
    Assert-Throws { Resolve-SkipAnswer $list 'abc' @() } 'text must be rejected'
}

Test-Case 'Test-RoutineId accepts only routine ids' {
    Assert-True (Test-RoutineId 'trig_01AbCdEf') 'a real-looking id'
    foreach ($bad in '', 'abc', 'trig_', 'trig_ab cd', 'https://claude.ai/code/routines/trig_01AbCdEf') {
        Assert-True (-not (Test-RoutineId $bad)) "'$bad' should be rejected"
    }
}

Test-Case 'Save-Config keeps lists, Hebrew and the UTF-8 BOM' {
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('cfg-test-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $cfg = Read-Text 'config.example.json' | ConvertFrom-Json
        $cfg.moodleSkipCourses = @('5800030001')
        $cfg.claudeRoutineId = 'trig_01AbCdEf'
        $cfg.moodleFolder = 'G:\האחסון שלי\Moodle'
        Save-Config $cfg $tmp
        $bytes = [IO.File]::ReadAllBytes($tmp)
        Assert-True ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) 'no UTF-8 BOM'
        $raw = [IO.File]::ReadAllText($tmp, [Text.Encoding]::UTF8)
        Assert-True ($raw -match '"moodleSkipCourses":\s*\[') 'one-item moodleSkipCourses was not written as a list'
        $back = $raw | ConvertFrom-Json
        Assert-Equal '5800030001' $back.moodleSkipCourses 'skip list'
        Assert-Equal 'trig_01AbCdEf' $back.claudeRoutineId 'routine id'
        Assert-Equal 'G:\האחסון שלי\Moodle' $back.moodleFolder 'Hebrew folder name'
        Assert-Equal 'מבוא לאופטימיזציה למדעי המחשב' $back.notionCourses[0].name 'Notion course name'
        $cfg.moodleSkipCourses = @()
        Save-Config $cfg $tmp
        Assert-True ((Get-Content $tmp -Raw -Encoding UTF8) -match '"moodleSkipCourses":\s*\[\s*\]') 'empty list was not written as []'
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

Test-Case 'Get-FreshUpdates picks only what this run found' {
    $list = @(
        [pscustomobject]@{ detectedAt = '2026-11-16T14:00:05+02:00'; title = 'old' },
        [pscustomobject]@{ detectedAt = '2026-11-16T15:00:02+02:00'; title = 'new' },
        [pscustomobject]@{ detectedAt = 'not a date'; title = 'broken' }
    )
    Assert-Equal 'new' ((Get-FreshUpdates $list '2026-11-16T15:00:02+02:00') | ForEach-Object { $_.title }) 'fresh items'
    Assert-Equal '' ((Get-FreshUpdates @() '2026-11-16T15:00:02+02:00') | ForEach-Object { $_.title }) 'empty list'
}

Test-Case 'a new update read back from updates.json triggers a notification' {
    # Uses the real Read-JsonList from moodle-sync.ps1, the way the sync reads updates.json before firing the routine.
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $repo 'moodle-sync.ps1'), [ref]$null, [ref]$null)
    $fn = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $a.Name -eq 'Read-JsonList' }, $true) | Select-Object -First 1
    Assert-True $fn 'Read-JsonList not found in moodle-sync.ps1'
    . ([scriptblock]::Create($fn.Extent.Text))
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('upd-test-' + [guid]::NewGuid().ToString('N') + '.json')
    try {
        $items = @(
            [pscustomobject][ordered]@{ detectedAt = '2026-11-16T14:00:05+02:00'; course = 'א'; type = 'file'; title = 'old'; detail = '' },
            [pscustomobject][ordered]@{ detectedAt = '2026-11-16T15:00:02+02:00'; course = 'ב'; type = 'activity'; title = 'intro_prob_ex4'; detail = '' }
        )
        ConvertTo-Json -InputObject ([object[]]$items) -Depth 4 | Set-Content -Path $tmp -Encoding UTF8
        $fresh = Get-FreshUpdates (Read-JsonList $tmp) '2026-11-16T15:00:02+02:00'
        Assert-Equal 'intro_prob_ex4' ($fresh | ForEach-Object { $_.title }) 'fresh items read from the file'
    } finally { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
}

Test-Case 'no script pipes Read-JsonList straight into another command' {
    # Read-JsonList returns ,$array: piped directly, the whole list arrives as ONE object.
    $bad = @()
    foreach ($f in 'moodle-sync.ps1', 'notion-sync.ps1', 'setup.ps1') {
        $n = 0
        foreach ($line in ((Read-Text $f) -split "`r?`n")) {
            $n++
            if ($line -match 'Read-JsonList\s+\$\w+\s*\|') { $bad += "${f}:$n" }
        }
    }
    Assert-True (-not $bad.Count) ('wrap it in parentheses or pass it as an argument: ' + ($bad -join ', '))
}

Write-Host ''
$color = 'Green'; if ($script:failed) { $color = 'Red' }
Write-Host ("{0} passed, {1} failed" -f $script:passed, $script:failed) -ForegroundColor $color
exit $script:failed
