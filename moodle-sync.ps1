# moodle-sync.ps1
# Downloads your course files from Moodle into a "Moodle" folder (normally inside Google Drive),
# ordered like the Moodle course pages. Only new or changed files are downloaded.
# Uses your personal Moodle key, stored encrypted in token.dat by setup.cmd (only your Windows
# user on this computer can decrypt it). The key is sent only to the Moodle site (moodleUrl).
# Runs every hour via Task Scheduler (created by setup.cmd), or manually: sync-now.cmd

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'   # the progress bar makes downloads very slow in Windows PowerShell
$root    = $PSScriptRoot
$logFile = Join-Path $root 'log.txt'
$outRoot = Join-Path $root 'Moodle'   # replaced below by moodleFolder from config.json, if set

function Write-Log([string]$msg) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  [moodle]  {1}' -f (Get-Date), $msg
    Add-Content -Path $logFile -Value $line -Encoding UTF8
    Write-Host $line
}

# Reads a JSON list robustly (Windows PowerShell 5.1 does not unroll arrays from ConvertFrom-Json,
# and older runs may have written lists nested as {"value":[...],"Count":n}) - always returns a flat array.
function Read-JsonList([string]$path) {
    $out = New-Object System.Collections.ArrayList
    if (-not (Test-Path -LiteralPath $path)) { return ,$out.ToArray() }
    $raw = Get-Content -LiteralPath $path -Raw -Encoding UTF8 | ConvertFrom-Json
    $stack = New-Object System.Collections.Stack
    $stack.Push($raw)
    while ($stack.Count) {
        $x = $stack.Pop()
        if ($null -eq $x) { continue }
        if ($x -is [System.Array]) { for ($i = $x.Count - 1; $i -ge 0; $i--) { $stack.Push($x[$i]) }; continue }
        $names = @($x.PSObject.Properties | ForEach-Object { $_.Name })
        if ($names.Count -eq 2 -and $names -contains 'value' -and $names -contains 'Count') { $stack.Push($x.value); continue }
        [void]$out.Add($x)
    }
    return ,$out.ToArray()
}

function Get-CourseName([string]$full) {
    # "0366201001 - מבוא להסתברות0366201001 - Introduction to Probability Theory" -> "מבוא להסתברות (0366201001)"
    $m = [regex]::Match($full, '^\s*(\d+)\s*-\s*(.+?)\s*\1\s*-\s*.+$')
    if ($m.Success) { return "$($m.Groups[2].Value.Trim()) ($($m.Groups[1].Value))" }
    $m = [regex]::Match($full, '^\s*(\d+)\s*-\s*(.+)$')
    if ($m.Success) { return "$($m.Groups[2].Value.Trim()) ($($m.Groups[1].Value))" }
    return $full.Trim()
}

function Get-SafeName([string]$s) {
    $s = ($s -replace '[\\/:*?"<>|]', '_').Trim().TrimEnd('.')
    if ($s.Length -gt 80) { $s = $s.Substring(0, 80).Trim() }
    if (-not $s) { $s = '_' }
    return $s
}

try {
    $cfg   = Get-Content (Join-Path $root 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $token = ''
    $tokenFile = Join-Path $root 'token.dat'
    if (Test-Path $tokenFile) {
        $sec = (Get-Content $tokenFile -Raw).Trim() | ConvertTo-SecureString
        $token = [Runtime.InteropServices.Marshal]::PtrToStringBSTR([Runtime.InteropServices.Marshal]::SecureStringToBSTR($sec))
    } elseif ($cfg.PSObject.Properties['moodleToken']) { $token = [string]$cfg.moodleToken }
    $base  = if ($cfg.moodleUrl) { ([string]$cfg.moodleUrl).TrimEnd('/') } else { 'https://moodle.tau.ac.il' }
    if (-not $token) { Write-Log 'no Moodle key yet - run setup.cmd'; exit 0 }
    if ($cfg.moodleFolder) {
        $want = [string]$cfg.moodleFolder
        $cands = @($want, ($want -replace 'My Drive', 'האחסון שלי'))
        $pick = $cands | Where-Object { Test-Path (Split-Path $_ -Parent) } | Select-Object -First 1
        if ($pick) { $outRoot = $pick }
        else { Write-Log "moodleFolder '$want' not reachable (is Google Drive running?) - using the local Moodle folder" }
    }
    $index  = Join-Path $outRoot 'index.json'
    $maxMB  = if ($cfg.moodleMaxFileMB) { [double]$cfg.moodleMaxFileMB } else { 100 }

    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    function Invoke-Moodle([string]$fn, [hashtable]$params = @{}) {
        $body = @{ wstoken = $token; wsfunction = $fn; moodlewsrestformat = 'json' } + $params
        $r = Invoke-RestMethod -Uri "$base/webservice/rest/server.php" -Method Post -Body $body -TimeoutSec 60
        if ($r -and $r.PSObject.Properties['exception']) { throw "Moodle ${fn}: $($r.message) ($($r.errorcode))" }
        return $r
    }

    $site = Invoke-Moodle 'core_webservice_get_site_info'
    $courses = Invoke-Moodle 'core_enrol_get_users_courses' @{ userid = $site.userid }

    $known = @{}
    if (Test-Path $index) {
        foreach ($e in (Read-JsonList $index)) { $known[[string]$e.path] = $e }
    }
    $entries = New-Object System.Collections.ArrayList
    # entries written by notion-sync.ps1 are kept as they are (it updates them itself)
    $notionEntries = @($known.Values | Where-Object { [string]$_.course -like '*(Notion)*' })
    $new = 0

    # ---- change tracking for notifications (new activities / files / grades) ----
    $seenFile = Join-Path $outRoot 'seen.json'
    $updFile  = Join-Path $outRoot 'updates.json'
    $firstRun = -not (Test-Path $seenFile)
    $seen = @{}
    if (-not $firstRun) {
        $o = Get-Content $seenFile -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($pr in $o.PSObject.Properties) { $seen[$pr.Name] = [string]$pr.Value }
    }
    $updates = New-Object System.Collections.ArrayList
    foreach ($u in (Read-JsonList $updFile)) { [void]$updates.Add($u) }
    $nowIso = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    $events = 0
    function Add-Update($course, $type, $title, $detail) {
        [void]$script:updates.Add([pscustomobject][ordered]@{ detectedAt = $script:nowIso; course = $course; type = $type; title = $title; detail = $detail })
        $script:events++
    }
    function Test-Seen([string]$key, [string]$value) {
        # returns $true if this key/value is new or changed (and records it)
        $isNew = -not $script:seen.ContainsKey($key) -or $script:seen[$key] -ne $value
        $script:seen[$key] = $value
        return ($isNew -and -not $script:firstRun)
    }
    $typeNames = @{ quiz = 'בוחן'; assign = 'מטלה'; resource = 'קובץ'; folder = 'תיקיית קבצים'; url = 'קישור'; forum = 'פורום'; page = 'דף'; lti = 'כלי חיצוני' }

    $courseDirs = New-Object System.Collections.ArrayList
    foreach ($c in $courses) {
        $cname = Get-CourseName ([string]$c.fullname)
        $courseDir = Join-Path $outRoot (Get-SafeName $cname)
        [void]$courseDirs.Add($courseDir)
        try { $sections = Invoke-Moodle 'core_course_get_contents' @{ courseid = $c.id } }
        catch { Write-Log "could not read course '$($c.fullname)': $($_.Exception.Message)"; continue }

        foreach ($s in $sections) {
            # folders and files are numbered in the order they appear on the Moodle course page
            $secDir = Join-Path $courseDir ('{0:D2} - {1}' -f [int]$s.section, (Get-SafeName $s.name))
            $modNo = 0
            foreach ($m in $s.modules) {
                if ($m.modname -ne 'label') { $modNo++ }
                if ($m.PSObject.Properties['uservisible'] -and -not $m.uservisible) { continue }
                if ($m.modname -ne 'label' -and (Test-Seen "mod:$($m.id)" '1')) {
                    $tn = if ($typeNames.ContainsKey($m.modname)) { $typeNames[$m.modname] } else { [string]$m.modname }
                    Add-Update $cname 'activity' ([string]$m.name) "$tn חדש/ה ב-$($s.name)"
                }
                if ($m.modname -notin @('resource', 'folder')) { continue }
                foreach ($f in @($m.contents)) {
                    if (-not $f -or $f.type -ne 'file') { continue }
                    $prefix = '{0:D2} - ' -f $modNo
                    $sub = if ($m.modname -eq 'folder') { Join-Path $secDir ($prefix + (Get-SafeName $m.name)) } else { $secDir }
                    if ($f.filepath -and $f.filepath -ne '/') { $sub = Join-Path $sub (Get-SafeName ($f.filepath.Trim('/'))) }
                    $dest = if ($m.modname -eq 'folder') { Join-Path $sub (Get-SafeName $f.filename) } else { Join-Path $sub ($prefix + (Get-SafeName $f.filename)) }
                    $rel  = $dest.Substring($outRoot.TrimEnd('\','/').Length + 1)
                    if ([double]$f.filesize / 1MB -gt $maxMB) { continue }   # skip big files (videos)
                    $fileKey = "$($m.id)|$($f.filepath)|$($f.filename)"
                    $prev = $known[$rel]
                    $entry = [ordered]@{
                        path = $rel; course = $cname; section = $s.name; activity = $m.name; fileKey = $fileKey
                        timemodified = [int64]$f.timemodified; size = [int64]$f.filesize
                        downloadedAt = $(if ($prev) { $prev.downloadedAt } else { $null })
                    }
                    $upToDate = $prev -and ([int64]$prev.timemodified -eq [int64]$f.timemodified) -and (Test-Path -LiteralPath $dest)
                    if (-not $upToDate) {
                        New-Item -ItemType Directory -Force -Path $sub | Out-Null
                        $url = [string]$f.fileurl
                        $url += $(if ($url.Contains('?')) { '&' } else { '?' }) + 'token=' + $token
                        $tmpDl = [IO.Path]::GetTempFileName(); Invoke-WebRequest -Uri $url -OutFile $tmpDl -UseBasicParsing -TimeoutSec 300; Move-Item -LiteralPath $tmpDl -Destination $dest -Force
                        $entry.downloadedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm')
                        $new++
                        Write-Log "downloaded: $rel"
                    }
                    if ($prev -and -not $upToDate -and -not $firstRun) { Add-Update $cname 'file' ([string]$f.filename) "קובץ עודכן ב-$($m.name)" }
                    [void]$entries.Add([pscustomobject]$entry)
                }
            }
        }

        # grades
        try {
            $g = Invoke-Moodle 'gradereport_user_get_grade_items' @{ courseid = $c.id; userid = $site.userid }
            foreach ($gi in @($g.usergrades[0].gradeitems)) {
                if (-not $gi -or $gi.itemtype -eq 'course' -or $null -eq $gi.graderaw) { continue }
                $val = "$($gi.gradeformatted)|$($gi.gradedategraded)"
                if (Test-Seen "grade:$($gi.id)" $val) { Add-Update $cname 'grade' ([string]$gi.itemname) "ציון: $($gi.gradeformatted)" }
            }
        } catch { Write-Log "could not read grades for '$($c.fullname)': $($_.Exception.Message -replace $(if ($token) { [regex]::Escape($token) } else { '(?!)' }), '[key]')" }
    }

    # files that moved to a new path (e.g. renumbered because the lecturer reordered the course page):
    # remove the old copy so nothing is duplicated, then remove folders left empty
    $nowKeys = @{}; $nowPaths = @{}
    foreach ($e in $entries) { $nowKeys[[string]$e.fileKey] = $true; $nowPaths[[string]$e.path] = $true }
    foreach ($e in $known.Values) {
        if ([string]$e.course -like '*(Notion)*' -or -not $e.PSObject.Properties['fileKey']) { continue }
        if ($nowKeys.ContainsKey([string]$e.fileKey) -and -not $nowPaths.ContainsKey([string]$e.path)) {
            $old = Join-Path $outRoot ([string]$e.path)
            if (Test-Path -LiteralPath $old) { Remove-Item -LiteralPath $old -Force; Write-Log "moved: $($e.path)" }
        }
    }
    foreach ($cd in $courseDirs) {
        if (-not (Test-Path -LiteralPath $cd)) { continue }
        Get-ChildItem -LiteralPath $cd -Directory -Recurse | Sort-Object { $_.FullName.Length } -Descending | ForEach-Object {
            if (-not (Get-ChildItem -LiteralPath $_.FullName -Force)) { Remove-Item -LiteralPath $_.FullName -Force }
        }
    }

    # keep the last 200 updates
    $keep = @($updates | Select-Object -Last 200)
    ConvertTo-Json -InputObject ([object[]]$keep) -Depth 4 | Set-Content -Path $updFile -Encoding UTF8
    [pscustomobject]$seen | ConvertTo-Json -Depth 3 | Set-Content -Path $seenFile -Encoding UTF8
    if ($firstRun) { Write-Log 'change tracking initialised (no notifications for existing items)' }
    elseif ($events) { Write-Log "$events new update(s) for notifications" }

    New-Item -ItemType Directory -Force -Path $outRoot | Out-Null
    $moodleFiles = $entries.Count
    foreach ($e in $notionEntries) { [void]$entries.Add($e) }
    ConvertTo-Json -InputObject ([object[]]$entries.ToArray()) -Depth 4 | Set-Content -Path $index -Encoding UTF8
    [ordered]@{ lastSync = (Get-Date).ToString('yyyy-MM-dd HH:mm'); ok = $true; courses = @($courses | ForEach-Object { Get-CourseName ([string]$_.fullname) }); files = $moodleFiles } |
        ConvertTo-Json | Set-Content -Path (Join-Path $outRoot 'sync-status.json') -Encoding UTF8
    Write-Log ("sync ok: {0} course(s), {1} file(s), {2} new" -f @($courses).Count, $moodleFiles, $new)

    # course sites on Notion (notionCourses in config.json)
    $notion = Join-Path $root 'notion-sync.ps1'
    if ($cfg.notionCourses -and (Test-Path $notion)) { & $notion -OutRoot $outRoot }
}
catch {
    $msg = $_.Exception.Message -replace $(if ($token) { [regex]::Escape([string]$token) } else { '(?!)' }), '[key]'
    Write-Log "ERROR: $msg"
    try {
        New-Item -ItemType Directory -Force -Path $outRoot | Out-Null
        [ordered]@{ lastSync = (Get-Date).ToString('yyyy-MM-dd HH:mm'); ok = $false; error = $msg } |
            ConvertTo-Json | Set-Content -Path (Join-Path $outRoot 'sync-status.json') -Encoding UTF8
    } catch {}
    exit 1
}
