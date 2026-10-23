/**
 * Moodle deadlines -> Google Tasks
 * Reads deadlines.json (written every hour by the Moodle sync on your computer into the Drive folder "Moodle")
 * and adds every new assignment / quiz with a due date as a task in Google Tasks, with its due date.
 * If a due date changes on Moodle, the task's date is updated. Runs every hour.
 *
 * Setup: paste into a new Apps Script project, add the "Google Tasks API" service, run setup() once.
 */

const MOODLE_FOLDER = 'Moodle';      // Drive folder the sync writes to
const TASK_LIST     = '@default';     // '@default' = "My Tasks"; or a list name, e.g. 'הגשות'
const TIME_ZONE     = 'Asia/Jerusalem';

function setup() {
  ScriptApp.getProjectTriggers().forEach(t => ScriptApp.deleteTrigger(t));
  ScriptApp.newTrigger('syncDeadlines').timeBased().everyHours(1).create();
  syncDeadlines();
}

function syncDeadlines() {
  const data = readDeadlines_();
  if (!data) return;
  const listId = getListId_();
  const props = PropertiesService.getUserProperties();
  const map = JSON.parse(props.getProperty('map') || '{}');
  const now = Date.now();
  let added = 0, updated = 0;

  data.forEach(d => {
    if (!d || !d.due) return;
    const due = new Date(d.due * 1000);
    if (due.getTime() < now) return;                       // already past
    const course = String(d.course || '').replace(/\s*\(\d+\)\s*$/, '');
    const kind = d.type === 'quiz' ? 'בוחן' : 'הגשה';
    const title = course + ' – ' + d.name;
    const notes = kind + ' עד ' + Utilities.formatDate(due, TIME_ZONE, 'dd/MM/yyyy HH:mm') + '\n' + (d.url || '');
    const dueDay = Utilities.formatDate(due, TIME_ZONE, 'yyyy-MM-dd') + 'T00:00:00.000Z';

    const known = map[d.id];
    if (known) {
      if (known.due !== d.due) {
        try {
          const t = Tasks.Tasks.get(listId, known.task);
          t.due = dueDay; t.notes = notes;
          Tasks.Tasks.update(t, listId, t.id);
          known.due = d.due; updated++;
        } catch (e) { /* task was deleted by the user - leave it */ }
      }
      return;
    }
    const t = Tasks.Tasks.insert({ title: title, notes: notes, due: dueDay }, listId);
    map[d.id] = { task: t.id, due: d.due };
    added++;
  });

  props.setProperty('map', JSON.stringify(map));
  console.log('added ' + added + ', updated ' + updated);
}

function readDeadlines_() {
  const folders = DriveApp.getFoldersByName(MOODLE_FOLDER);
  while (folders.hasNext()) {
    const files = folders.next().getFilesByName('deadlines.json');
    if (files.hasNext()) {
      const text = files.next().getBlob().getDataAsString('UTF-8').replace(/^﻿/, '');
      const json = JSON.parse(text);
      return Array.isArray(json) ? json : [json];
    }
  }
  console.log('deadlines.json not found yet in the "' + MOODLE_FOLDER + '" folder');
  return null;
}

function getListId_() {
  if (TASK_LIST === '@default') return '@default';
  const lists = (Tasks.Tasklists.list().items || []);
  const found = lists.find(l => l.title === TASK_LIST);
  return found ? found.id : Tasks.Tasklists.insert({ title: TASK_LIST }).id;
}
