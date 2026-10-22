---
name: moodle-course-material
description: Answer questions about my Tel Aviv University courses (tutorials, lectures, exercises, homework, past exams, anything from Moodle) from my course files synced to the Google Drive folder "Moodle".
---

# My Moodle course material

Use this whenever I ask about my university courses, tutorials (תרגולים), lecture notes, exercises, past exams or anything that "was on Moodle".

## Where the material is
- My Google Drive (Google Drive connector), folder **Moodle** in My Drive. A script on my computer (tau-moodle-sync) updates it from Moodle every hour. Find the folder with search_files: title = 'Moodle' and mimeType = 'application/vnd.google-apps.folder'.
- One subfolder per course, named "<Hebrew course name> (<course number>)".
- Inside each course: section folders numbered in the order of the Moodle course page (e.g. "02 - תרגולים"), and files numbered in course-page order (e.g. "01 - Tirgul 01.pdf"). Moodle "folder" activities are subfolders.
- Course websites on Notion (if enabled) are in "<course name> (Notion)", with folders מידע כללי / הרצאות / תרגולים / בחינות and Markdown (.md) files with LaTeX math.
- `index.json` in the Moodle folder lists every file: `path` (relative to the Moodle folder), `course`, `section`, `activity`, `timemodified` (unix seconds). Read it first (download_file_content; UTF-8 with BOM) to find the right file instead of searching blindly.
- `updates.json` lists recent changes (new activities, updated files, grades) with `detectedAt`.

## How to answer
1. Find the relevant file(s) via index.json, then get the file with search_files (title = '<file name>' — the last part of the path, including its number prefix) and read it. For PDFs with math or Hebrew, prefer download_file_content + reading the PDF pages as images when extracted text is garbled (Hebrew text often extracts reversed). When the same material exists as .pptx and .pdf, read the PDF.
2. Answer from the material in the course's own notation and terms, and say which file (and page, if possible) it comes from. If the material doesn't cover it, say so before adding general knowledge, and mark that part as outside the course material.
3. Write math in LaTeX ($...$ / $$...$$) so it renders — never in code blocks.
4. When I'm working on an exercise: give a hint before the full solution, and if I share my own solution, check it before presenting the full one.
5. Answer in Hebrew unless I write in English.
6. Read-only: never modify, move or delete anything in the Drive folder.
