# notion-sync.ps1
# Copies public Notion course sites (notionCourses in config.json) into the Moodle folder:
# every page becomes a Markdown file (formulas kept as LaTeX), attached PDFs are downloaded.
# Adds the pages to index.json and reports new pages in updates.json (for notifications).
# Called at the end of moodle-sync.ps1 (every hour). Can also be run on its own.

param([string]$OutRoot = '')

$ErrorActionPreference = 'Stop'
$ProgressPreference    = 'SilentlyContinue'
$root    = $PSScriptRoot
$logFile = Join-Path $root 'log.txt'
$api     = if ($env:NOTION_API) { $env:NOTION_API } else { 'https://app.notion.com/api/v3' }
$ua      = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0 Safari/537.36'

function Write-Log([string]$msg) {
    $line = '{0:yyyy-MM-dd HH:mm:ss}  [notion]  {1}' -f (Get-Date), $msg
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

function Get-SafeName([string]$s) {
    $s = ($s -replace '[\\/:*?"<>|\r\n\t]', ' ' -replace '[^\p{L}\p{N}\p{P}\p{Zs}+=~$^`]', '' -replace '\s+', ' ').Trim().TrimEnd('.')
    if ($s.Length -gt 90) { $s = $s.Substring(0, 90).Trim() }
    if (-not $s) { $s = '_' }
    return $s
}
function Invoke-Notion([string]$endpoint, $body) {
    $json = $body | ConvertTo-Json -Depth 12 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    for ($i = 0; $i -lt 3; $i++) {
        try {
            return Invoke-RestMethod -Uri "$api/$endpoint" -Method Post -Body $bytes -ContentType 'application/json; charset=utf-8' -UserAgent $ua -TimeoutSec 60
        } catch { if ($i -eq 2) { throw } ; Start-Sleep -Seconds (3 * ($i + 1)) }
    }
}

# ---------- block store ----------
$blocks = @{}
function Add-Records($recordMap) {
    if (-not $recordMap -or -not $recordMap.block) { return }
    foreach ($p in $recordMap.block.PSObject.Properties) {
        $v = $p.Value.value
        if ($v -and $v.PSObject.Properties['value'] -and $v.value -and $v.value.PSObject.Properties['type']) { $v = $v.value }
        if ($v -and $v.PSObject.Properties['type']) { $script:blocks[$p.Name] = $v }
    }
}
function Get-PageBlocks([string]$pageId) {
    $cursor = @{ stack = @() }
    for ($n = 0; $n -lt 50; $n++) {
        $r = Invoke-Notion 'loadPageChunk' @{ pageId = $pageId; limit = 100; cursor = $cursor; chunkNumber = $n; verticalColumns = $false }
        Add-Records $r.recordMap
        if (-not $r.cursor -or -not $r.cursor.stack -or @($r.cursor.stack).Count -eq 0) { break }
        $cursor = $r.cursor
    }
}
function Get-MissingBlocks([string[]]$ids) {
    $ids = @($ids | Where-Object { -not $script:blocks.ContainsKey($_) } | Select-Object -Unique)
    for ($i = 0; $i -lt $ids.Count; $i += 100) {
        $batch = $ids[$i..([Math]::Min($i + 99, $ids.Count - 1))]
        $req = @($batch | ForEach-Object { @{ pointer = @{ table = 'block'; id = $_ }; version = -1 } })
        $r = Invoke-Notion 'syncRecordValues' @{ requests = $req }
        Add-Records $r.recordMap
    }
}
function Complete-Tree([string]$pageId) {
    # make sure every descendant (except child pages) is loaded
    for ($round = 0; $round -lt 6; $round++) {
        $missing = New-Object System.Collections.ArrayList
        $stack = New-Object System.Collections.Stack; $stack.Push($pageId)
        while ($stack.Count) {
            $id = $stack.Pop(); $b = $script:blocks[$id]
            if (-not $b) { [void]$missing.Add($id); continue }
            if ($id -ne $pageId -and $b.type -eq 'page') { continue }
            foreach ($c in @($b.content)) { if ($c) { $stack.Push([string]$c) } }
        }
        if ($missing.Count -eq 0) { return }
        Get-MissingBlocks $missing
    }
}

# ---------- Markdown rendering ----------
function Convert-Rich($title) {
    if (-not $title) { return '' }
    $sb = New-Object Text.StringBuilder
    foreach ($seg in @($title)) {
        $text = [string]$seg[0]; $ann = @(); if (@($seg).Count -gt 1) { $ann = @($seg[1]) }
        $latex = $null; $bold = $false; $ital = $false; $code = $false; $link = $null
        foreach ($a in $ann) {
            switch ([string]$a[0]) { 'e' { $latex = [string]$a[1] } 'b' { $bold = $true } 'i' { $ital = $true } 'c' { $code = $true } 'a' { $link = [string]$a[1] } }
        }
        if ($null -ne $latex) { [void]$sb.Append('$' + $latex.Trim() + '$'); continue }
        if (-not $text) { continue }
        if ($code) { $text = '`' + $text + '`' }
        if ($bold -and $text.Trim()) { $text = '**' + $text.Trim() + '** ' }
        if ($ital -and $text.Trim()) { $text = '*' + $text.Trim() + '* ' }
        if ($link -and $link -notlike '/*') { $text = "[$text]($link)" }
        [void]$sb.Append($text)
    }
    return $sb.ToString()
}
function Render-Block([string]$id, [int]$depth, $out, $pagesFound) {
    $b = $script:blocks[$id]; if (-not $b) { return }
    if ($b.PSObject.Properties['alive'] -and $b.alive -eq $false) { return }
    $ind = '  ' * $depth
    $t = ''; if ($b.properties -and $b.properties.title) { $t = Convert-Rich $b.properties.title }
    $kids = $true
    switch ($b.type) {
        'page'             { [void]$pagesFound.Add($id); [void]$out.Add("$ind- 📄 (עמוד) $t"); $kids = $false }
        'header'           { [void]$out.Add(''); [void]$out.Add("# $t") }
        'sub_header'       { [void]$out.Add(''); [void]$out.Add("## $t") }
        'sub_sub_header'   { [void]$out.Add(''); [void]$out.Add("### $t") }
        'header_4'         { [void]$out.Add(''); [void]$out.Add("#### $t") }
        'bulleted_list'    { [void]$out.Add("$ind- $t") }
        'numbered_list'    { [void]$out.Add("${ind}1. $t") }
        'to_do'            { [void]$out.Add("$ind- [ ] $t") }
        'toggle'           { [void]$out.Add("$ind▸ **$($t.Trim('*',' '))**") }
        'callout'          { [void]$out.Add(''); [void]$out.Add("$ind> $t") }
        'quote'            { [void]$out.Add("$ind> $t") }
        'equation'         { [void]$out.Add(''); [void]$out.Add('$$'); [void]$out.Add(($t -replace '^\$|\$$', '')); [void]$out.Add('$$') }
        'code'             { [void]$out.Add('```'); [void]$out.Add($t); [void]$out.Add('```') }
        'divider'          { [void]$out.Add('---') }
        'image'            { [void]$out.Add("$ind[איור]") }
        'file'             { [void]$out.Add("$ind- 📎 $t") }
        'pdf'              { [void]$out.Add("$ind- 📎 $t") }
        'bookmark'         { $l = ''; if ($b.properties.link) { $l = Convert-Rich $b.properties.link }; [void]$out.Add("$ind- 🔗 $l") }
        'table_row'        {
            $cells = @(); if ($b.properties) { foreach ($cp in $b.properties.PSObject.Properties) { $cells += (Convert-Rich $cp.Value) } }
            [void]$out.Add('| ' + ($cells -join ' | ') + ' |')
        }
        default            { if ($t) { [void]$out.Add("$ind$t") } }
    }
    if ($b.type -in @('text','callout','quote','bulleted_list','numbered_list','toggle','to_do') -and $b.type -eq 'text') { [void]$out.Add('') }
    if ($kids) {
        $d = $depth; if ($b.type -in @('bulleted_list','numbered_list','toggle','to_do','callout','quote')) { $d = $depth + 1 }
        foreach ($c in @($b.content)) { if ($c) { Render-Block ([string]$c) $d $out $pagesFound } }
    }
}

# ---------- main ----------
try {
    $cfg = Get-Content (Join-Path $root 'config.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $sites = @($cfg.notionCourses)
    if (-not $sites -or -not $sites[0]) { exit 0 }
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

    if (-not $OutRoot) {
        $OutRoot = Join-Path $root 'Moodle'
        if ($cfg.moodleFolder) {
            $want = [string]$cfg.moodleFolder
            $pick = @($want, ($want -replace 'My Drive', 'האחסון שלי')) | Where-Object { Test-Path (Split-Path $_ -Parent) } | Select-Object -First 1
            if ($pick) { $OutRoot = $pick }
        }
    }
    New-Item -ItemType Directory -Force -Path $OutRoot | Out-Null
    $index    = Join-Path $OutRoot 'index.json'
    $seenFile = Join-Path $OutRoot 'seen.json'
    $updFile  = Join-Path $OutRoot 'updates.json'

    $entries = New-Object System.Collections.ArrayList
    $old = @{}
    if (Test-Path $index) {
        foreach ($e in (Read-JsonList $index)) {
            if ([string]$e.course -like '*(Notion)*') { $old[[string]$e.path] = $e } else { [void]$entries.Add($e) }
        }
    }
    $seen = @{}
    if (Test-Path $seenFile) { $o = Get-Content $seenFile -Raw -Encoding UTF8 | ConvertFrom-Json; foreach ($pr in $o.PSObject.Properties) { $seen[$pr.Name] = [string]$pr.Value } }
    $updates = New-Object System.Collections.ArrayList
    foreach ($u in (Read-JsonList $updFile)) { [void]$updates.Add($u) }
    $nowIso = (Get-Date).ToString('yyyy-MM-ddTHH:mm:sszzz')
    $newPages = 0; $written = 0

    foreach ($site in $sites) {
        $courseName = [string]$site.name + ' (Notion)'
        $rootId = [string]$site.pageId
        $courseDir = Join-Path $OutRoot (Get-SafeName $courseName)
        $firstForSite = -not ($seen.Keys | Where-Object { $_ -like "notion:$rootId*" })
        $seen["notion:$rootId"] = '1'

        Get-PageBlocks $rootId; Complete-Tree $rootId
        $queue = New-Object System.Collections.Queue
        $rootPages = New-Object System.Collections.ArrayList
        $tmp = New-Object System.Collections.ArrayList
        foreach ($c in @($blocks[$rootId].content)) { if ($c) { Render-Block ([string]$c) 0 $tmp $rootPages } }
        # root page itself (course info)
        $queue.Enqueue(@($rootId, ''))
        foreach ($p in $rootPages) { $queue.Enqueue(@([string]$p, '')) }
        $done = @{}

        while ($queue.Count) {
            $item = $queue.Dequeue(); $pgId = $item[0]; $parentTitle = $item[1]
            if ($done.ContainsKey($pgId)) { continue }; $done[$pgId] = $true
            if (-not $blocks.ContainsKey($pgId) -or $pgId -ne $rootId) { Get-PageBlocks $pgId }
            Complete-Tree $pgId
            $pb = $blocks[$pgId]; if (-not $pb) { continue }
            if ($pb.PSObject.Properties['alive'] -and $pb.alive -eq $false) { continue }
            $title = (Convert-Rich $pb.properties.title) -replace '\*', '' -replace '\s+', ' '
            $title = ($title -replace '^[^\p{L}\p{N}\[(]+', '').Trim(); if (-not $title) { $title = 'Untitled' }
            if ($parentTitle) { $title = "$parentTitle - $title" }
            $section = 'כללי'
            if ($title -match '(?i)recitation|tirgul|תרגול') { $section = 'תרגולים' }
            elseif ($title -match '(?i)lecture|הרצאה') { $section = 'הרצאות' }
            elseif ($title -match '(?i)exam|solution|מבחן|בחינ') { $section = 'בחינות' }
            elseif ($pgId -eq $rootId) { $section = 'מידע כללי' }
            $edited = [int64]([double]$pb.last_edited_time / 1000)

            $lines = New-Object System.Collections.ArrayList
            $subPages = New-Object System.Collections.ArrayList
            [void]$lines.Add("# $title"); [void]$lines.Add('')
            [void]$lines.Add("מקור: https://app.notion.com/p/$($pgId -replace '-','')"); [void]$lines.Add('')
            foreach ($c in @($pb.content)) { if ($c) { Render-Block ([string]$c) 0 $lines $subPages } }

            $secOrder = @{ 'מידע כללי' = '01'; 'הרצאות' = '02'; 'תרגולים' = '03'; 'בחינות' = '04'; 'כללי' = '05' }
            $secDir = Join-Path $courseDir ("$($secOrder[$section]) - $section")
            New-Item -ItemType Directory -Force -Path $secDir | Out-Null
            # "Lecture 3 ..." -> "Lecture 03 ..." so files sort in course order
            $fileName = (Get-SafeName ([regex]::Replace($title, '^(\D*?)(\d+)', { param($mm) $mm.Groups[1].Value + ([int]$mm.Groups[2].Value).ToString('00') }))) + '.md'
            $dest = Join-Path $secDir $fileName
            $rel = $dest.Substring($OutRoot.TrimEnd('\','/').Length + 1)
            $prev = $old[$rel]
            if (-not $prev -or [int64]$prev.timemodified -ne $edited -or -not (Test-Path -LiteralPath $dest)) {
                [IO.File]::WriteAllLines($dest, [string[]]$lines, (New-Object Text.UTF8Encoding $true))
                $written++
            }
            [void]$entries.Add([pscustomobject][ordered]@{ path = $rel; course = $courseName; section = $section; activity = $title; timemodified = $edited; size = (Get-Item -LiteralPath $dest).Length; downloadedAt = $(if ($prev) { $prev.downloadedAt } else { (Get-Date).ToString('yyyy-MM-dd HH:mm') }) })

            if ($pgId -ne $rootId -and -not $seen.ContainsKey("notion:$pgId")) {
                $seen["notion:$pgId"] = '1'
                if (-not $firstForSite) {
                    [void]$updates.Add([pscustomobject][ordered]@{ detectedAt = $nowIso; course = $courseName; type = 'activity'; title = $title; detail = "עמוד חדש באתר הקורס (Notion) - $section" })
                    $newPages++
                }
            }

            # attached files (PDFs) on this page
            $fileBlocks = @($blocks.Values | Where-Object { $_.parent_id -eq $pgId -and $_.type -in @('file','pdf') -and $_.properties -and $_.properties.source })
            foreach ($fb in $fileBlocks) {
                $fname = Get-SafeName ([string]$fb.properties.title[0][0]); if (-not $fname) { $fname = "$($fb.id).pdf" }
                $fdest = Join-Path $secDir $fname
                $frel = $fdest.Substring($OutRoot.TrimEnd('\','/').Length + 1)
                if (-not (Test-Path -LiteralPath $fdest)) {
                    $src = [string]$fb.properties.source[0][0]
                    $s = Invoke-Notion 'getSignedFileUrls' @{ urls = @(@{ url = $src; permissionRecord = @{ table = 'block'; id = $fb.id; spaceId = $fb.space_id } }) }
                    $signed = @($s.signedUrls)[0]
                    if ($signed) { $tmpDl = [IO.Path]::GetTempFileName(); Invoke-WebRequest -Uri $signed -OutFile $tmpDl -UseBasicParsing -UserAgent $ua -TimeoutSec 300; Move-Item -LiteralPath $tmpDl -Destination $fdest -Force; $written++ }
                }
                if (Test-Path -LiteralPath $fdest) {
                    [void]$entries.Add([pscustomobject][ordered]@{ path = $frel; course = $courseName; section = $section; activity = $title; timemodified = [int64]([double]$fb.created_time / 1000); size = (Get-Item -LiteralPath $fdest).Length; downloadedAt = (Get-Date).ToString('yyyy-MM-dd HH:mm') })
                    if (-not $seen.ContainsKey("notion:$($fb.id)")) {
                        $seen["notion:$($fb.id)"] = '1'
                        if (-not $firstForSite) { [void]$updates.Add([pscustomobject][ordered]@{ detectedAt = $nowIso; course = $courseName; type = 'activity'; title = $fname; detail = "קובץ חדש באתר הקורס (Notion) - $title" }); $newPages++ }
                    }
                }
            }
            foreach ($sp in $subPages) { $queue.Enqueue(@([string]$sp, $(if ($pgId -eq $rootId) { '' } else { $title }))) }
        }
        if ($firstForSite) { Write-Log "${courseName}: first sync, $($done.Count) page(s) (no notifications for existing pages)" }
    }

    ConvertTo-Json -InputObject ([object[]]$entries.ToArray()) -Depth 4 | Set-Content -Path $index -Encoding UTF8
    [pscustomobject]$seen | ConvertTo-Json -Depth 3 | Set-Content -Path $seenFile -Encoding UTF8
    $keep = @($updates | Select-Object -Last 200)
    ConvertTo-Json -InputObject ([object[]]$keep) -Depth 4 | Set-Content -Path $updFile -Encoding UTF8
    Write-Log "notion sync ok: $written file(s) written, $newPages new item(s)"
}
catch {
    Write-Log "ERROR: $($_.Exception.Message)"
    exit 1
}
