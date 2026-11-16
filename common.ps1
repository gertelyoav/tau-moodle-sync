# common.ps1 - small helpers shared by moodle-sync.ps1, setup.ps1 and tests/run-tests.ps1.
# Pure functions only: no network, no files except Save-Config. Windows PowerShell 5.1 compatible.

function Get-CourseName([string]$full) {
    # "0366201001 - מבוא להסתברות0366201001 - Introduction to Probability Theory" -> "מבוא להסתברות (0366201001)"
    $m = [regex]::Match($full, '^\s*(\d+)\s*-\s*(.+?)\s*\1\s*-\s*.+$')
    if ($m.Success) { return "$($m.Groups[2].Value.Trim()) ($($m.Groups[1].Value))" }
    $m = [regex]::Match($full, '^\s*(\d+)\s*-\s*(.+)$')
    if ($m.Success) { return "$($m.Groups[2].Value.Trim()) ($($m.Groups[1].Value))" }
    return $full.Trim()
}

# The course number at the start of the Moodle name ("0366201001 - ..."), else the short name.
function Get-CourseNumber($course) {
    $m = [regex]::Match([string]$course.fullname, '^\s*(\d+)\s*-')
    if ($m.Success) { return $m.Groups[1].Value }
    return ([string]$course.shortname).Trim()
}

# True when the course's full or short name contains one of the numbers in moodleSkipCourses.
function Test-CourseSkipped($course, $skip) {
    foreach ($s in @($skip)) {
        $s = [string]$s
        if (-not $s) { continue }
        if (([string]$course.fullname).Contains($s) -or ([string]$course.shortname).Contains($s)) { return $true }
    }
    return $false
}

# Huge courses most students don't want synced (5800030001 = the TAU exam archive, thousands of files).
$script:SuggestedSkipCourses = @('5800030001')
function Get-SuggestedSkips($courses) {
    $out = @()
    foreach ($n in $script:SuggestedSkipCourses) {
        if (@($courses | Where-Object { Test-CourseSkipped $_ @($n) }).Count) { $out += $n }
    }
    return ,$out
}

# Turns the setup answer into course numbers: '' = keep $default, '0' = none, '1,3' or '1 3' = those
# courses from the numbered list. Throws on anything else so setup can ask again.
function Resolve-SkipAnswer($courses, [string]$answer, $default) {
    $courses = @($courses)
    $a = ([string]$answer).Trim()
    if (-not $a) { return ,@($default | Where-Object { $_ }) }
    if ($a -eq '0') { return ,@() }
    $out = @()
    foreach ($part in ($a -split '[\s,]+' | Where-Object { $_ })) {
        if ($part -notmatch '^\d+$') { throw "'$part' is not a number from the list" }
        $i = [int]$part
        if ($i -lt 1 -or $i -gt $courses.Count) { throw "$i is not in the list (1-$($courses.Count))" }
        $n = Get-CourseNumber $courses[$i - 1]
        if ($out -notcontains $n) { $out += $n }
    }
    return ,$out
}

# A Claude routine id as shown in the routine's URL: trig_ followed by letters and digits.
function Test-RoutineId([string]$id) { return [bool]($id -match '^trig_[A-Za-z0-9]+$') }

# Sets a setting even when an older config.json does not have it yet.
function Set-ConfigValue($cfg, [string]$name, $value) {
    $cfg | Add-Member -NotePropertyName $name -NotePropertyValue $value -Force
}

# Writes config.json as UTF-8 with BOM (what the scripts expect). Windows PowerShell 5.1 turns a
# one-item list into a plain string in ConvertTo-Json, so moodleSkipCourses is forced to stay a list.
function Save-Config($cfg, [string]$path) {
    $skip = @($cfg.moodleSkipCourses | Where-Object { $_ } | ForEach-Object { [string]$_ })
    $cfg | Add-Member -NotePropertyName moodleSkipCourses -NotePropertyValue '__SKIP_LIST__' -Force
    $json = $cfg | ConvertTo-Json -Depth 5
    $cfg | Add-Member -NotePropertyName moodleSkipCourses -NotePropertyValue $skip -Force
    $list = '[]'
    if ($skip.Count) { $list = '[' + (($skip | ForEach-Object { ConvertTo-Json -InputObject $_ }) -join ', ') + ']' }
    $json = $json.Replace('"__SKIP_LIST__"', $list)
    [IO.File]::WriteAllText($path, $json, (New-Object Text.UTF8Encoding $true))
}
