# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

tau-moodle-sync: Windows-only PowerShell scripts that download a Tel Aviv University student's Moodle course files (and optionally public Notion course sites) into a folder, normally inside Google Drive, so Gemini/Claude can answer questions from the material via a Drive connector + the skills in `skills/`. No build, no dependencies — plain Windows PowerShell 5.1 scripts launched by `.cmd` wrappers. README.md is the end-user install guide (Hebrew, with a short English overview).

## Commands

- Run a sync now: `powershell -NoProfile -ExecutionPolicy Bypass -File moodle-sync.ps1` (or `sync-now.cmd`). Output goes to the console and `log.txt`.
- Tests: `powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1` (no Moodle account or network needed; exit code = number of failures). They also run in Windows PowerShell 5.1 on GitHub Actions (`.github/workflows/tests.yml`) on every push and PR, which is the way to test from a non-Windows machine.
- Setup / uninstall: `setup.cmd` (interactive: gets the Moodle key via the browser, picks the Drive folder, lets the user choose courses to skip, optional phone-notification step via `save-claude-token.ps1`, registers the hourly task `TAU-Moodle-Sync`, runs the first sync) / `uninstall.cmd`.

## Architecture

- **`moodle-sync.ps1`** (entry point, run hourly 07:00–23:00 by Task Scheduler): calls the Moodle mobile web-service REST API (`/webservice/rest/server.php`) with the user's mobile-app token. Downloads `resource`/`folder` files and assignment attachments into `<course>/<NN - section>/<NN - file>`; numbering follows the order on the Moodle course page, so a reorder renames paths — files whose `fileKey` (`moduleId|filepath|filename`) moved are deleted from the old path and empty folders pruned. A file is (re)downloaded only when `timemodified` changed or it's missing on disk (a file already on disk with the right size counts as downloaded, so a crashed run doesn't re-download everything). Downloads go to a temp file then `Move-Item`; a failed download is logged and retried next run, never aborting the run. Then it runs `notion-sync.ps1` for enrolled courses in `notionCourses`, and finally (optional) fires the Claude notification routine.
- **`common.ps1`**: pure helpers dot-sourced by `moodle-sync.ps1`, `setup.ps1`, `save-claude-token.ps1` and the tests (`Get-CourseName`, `Get-CourseNumber`, `Test-CourseSkipped`, `Get-SuggestedSkips`, `Resolve-SkipAnswer`, `Test-RoutineId`, `Set-ConfigValue`, `Save-Config`). Put new testable logic here, not in the scripts' top level. Always write `config.json` with `Save-Config` (it keeps the UTF-8 BOM and keeps a one-item `moodleSkipCourses` as a list, which plain `ConvertTo-Json` in 5.1 does not).
- **`notion-sync.ps1`**: scrapes public Notion pages through Notion's internal `api/v3` (`loadPageChunk`, `syncRecordValues`, `getSignedFileUrls`), renders blocks to Markdown with LaTeX, downloads attached PDFs into `<course> (Notion)/…`.
- **State files in the output folder** (shared contract between the scripts, the AI skills and `google-tasks/Code.gs` — keep their shapes stable):
  - `index.json` — every file: `path` (relative), `course`, `section`, `activity`, `fileKey`, `timemodified`, `size`, `downloadedAt`. Entries whose `course` contains `(Notion)` are owned by notion-sync; moodle-sync preserves them untouched.
  - `seen.json` — key/value map (`course:<id>`, `mod:<id>`, `grade:<id>`) used to detect changes. No file → "first run": everything is recorded silently. A course with no `course:` key and no seen modules is likewise recorded silently (no flood of updates when joining a course).
  - `updates.json` — rolling last-200 list of `{detectedAt, course, type: activity|file|grade, title, detail}` (detail strings are Hebrew).
  - `deadlines.json` — assignments/quizzes with due dates; read by `google-tasks/Code.gs` (Apps Script) to create Google Tasks.
  - `sync-status.json` — last run result (`ok`, `lastSync`, courses, file count, or `error`).
  - All of these are written at the **end** of a run; an exception that escapes mid-run loses that run's state.
- **Notifications (optional)**: if `claudeRoutineId` is set and `claude-routine-token.dat` exists, the entries added to `updates.json` during this run are POSTed to `https://api.anthropic.com/v1/claude_code/routines/<id>/fire` (body `{"text": <json>}`). The routine (API trigger only, no schedule) formats them and pushes to the phone — event-driven on purpose, because a scheduled routine with push enabled notifies on every run.
- **Config** (`config.json`, from `config.example.json`): `moodleUrl`, `moodleFolder` (Drive path; falls back to `./Moodle` if unreachable, also tries the Hebrew "האחסון שלי" for "My Drive"), `moodleMaxFileMB` (skip larger files, e.g. videos), `moodleSkipCourses` (course numbers to ignore), `claudeRoutineId`, `notionCourses` (`moodleCourse` matches enrollment).
- **Secrets**: the Moodle token and the routine token are DPAPI-encrypted (`token.dat`, `claude-routine-token.dat`; only the same Windows user can decrypt). `setup.ps1` obtains the *existing* Moodle token via `admin/tool/mobile/launch.php` and a temporary `moodlemobile://` URL handler — it must never reset the user's key. Exception messages are scrubbed of the token (`-replace [regex]::Escape($token), '[key]'`) before logging; do the same for any new log line that can contain a URL.

## Gotchas

- Target is Windows PowerShell 5.1, not PowerShell 7: no `??`, `?.`, ternary, `&&`. `ConvertFrom-Json` doesn't unroll arrays and older runs wrote lists as `{"value":[...],"Count":n}` — always read lists with `Read-JsonList` (duplicated in both scripts).
- Script files that contain Hebrew must be saved as UTF-8 **with BOM**, or Windows PowerShell 5.1 reads them as ANSI.
- Read/write JSON with `-Encoding UTF8` (files have a BOM; consumers expect that). Course/section names are Hebrew; `Get-SafeName` sanitizes and truncates path parts to 80 chars.
- `$ProgressPreference = 'SilentlyContinue'` is required — the progress bar makes `Invoke-WebRequest` extremely slow.
- `.gitignore` excludes `config.json`, both token files, `log.txt` and `Moodle/` — course material and personal data must never be committed.
