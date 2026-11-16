# רוטינת התראות לטלפון (אופציונלי)

הרוטינה הזאת שולחת התראה לאפליקציה של קלוד בטלפון, **רק** כשהסנכרון מוצא משהו חדש: פריט חדש בקורס, קובץ שעודכן או ציון חדש.
הסנכרון במחשב שלך מפעיל אותה דרך ה-API של קלוד, ולכן אין לה תזמון משלה. צריך מנוי לקלוד שכולל רוטינות.

## יצירת הרוטינה

1. באתר של קלוד יוצרים רוטינה חדשה (`claude.ai/code/routines → New routine`).
2. בטריגר בוחרים API בלבד, בלי תזמון (`Trigger: API`), ומפעילים התראות push.
3. בשדה ההוראות מדביקים את הטקסט שבסעיף הבא, כמו שהוא.
4. לוחצים על יצירת מפתח (`Generate token`) ומעתיקים אותו. הוא מוצג פעם אחת בלבד.
5. מריצים את `setup.cmd` (שלב 4) או את `save-claude-token.cmd`, ומדביקים את מזהה הרוטינה (מתחיל ב-`trig_`, אפשר להדביק את כל כתובת ה-API שלה) ואת המפתח. המפתח נשמר מוצפן במחשב שלך.

## ההוראות לרוטינה

```
You are triggered by my Moodle sync script only when it finds something new in my Tel Aviv University courses.
The new items are a JSON list inside <routine-fire-payload>. Each item has: detectedAt, course, type (activity = new item on the course page, file = updated file, grade = new grade), title, detail.

1. Read the list in <routine-fire-payload>. If it is missing or empty, do nothing and end.
2. Send exactly one push notification with the PushNotification tool, in Hebrew:
   - Title: a short summary, e.g. "2 עדכונים חדשים במודל".
   - Body: one line per item, "<course without the number in parentheses>: <title> (<detail>)". Grades first. If there are more than 6 items, show 6 and add "ועוד N".
3. Do not open, read or change any files, repositories or other tools. Do not reply with anything else.
```

## בדיקה

אחרי השמירה, ההתראה הראשונה תגיע בסנכרון הבא שמוצא משהו חדש. ב-`log.txt` תופיע השורה `phone notification sent`.
