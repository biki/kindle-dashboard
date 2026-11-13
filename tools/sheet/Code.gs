/**
 * Kindle dashboard: the Kindle writes the daily power meter row into this sheet, and reads the
 * newest rows for its chart. Replaces the service-account code of the Pi (biki/pizero).
 *
 * Sheet contract (fixed by the existing document):
 *   A = date dd.mm.yyyy, B = meter total kWh, C = that day's consumption kWh.
 *   Row 1 is the header. Row 2 is always the newest entry: each push inserts at the top.
 *
 * Setup: see tools/sheet/README.md.
 *
 * Calls (POST or GET, form fields):
 *   token=...&action=rows&n=40                  -> "ok", then "dd.mm.yyyy|total|daily" newest first
 *   token=...&action=info                       -> "ok", code version, file, tab in use, all tabs
 *   token=...&action=push&date=dd.mm.yyyy&total=18813.78&daily=12.53
 *                                               -> "ok|row 2", or "dup|dd.mm.yyyy" (row exists)
 *   Errors                                      -> "error|reason"
 * Numbers use a decimal point in both directions. The sheet shows them in its own locale.
 */

const CODE_VERSION = '2026-11-13.2';  // shown by action=info: is the new code deployed?
const SHEET_NAME = 'Tibber API';  // tab name; '' = the first tab
const SPREADSHEET_ID = '';  // '' = the sheet this script is bound to; else the ID from the sheet URL
                            // (for a standalone script, e.g. owned by an account outside a Workspace)

function doPost(e) { return handle_(e); }
function doGet(e) { return handle_(e); }

function handle_(e) {
  const p = (e && e.parameter) || {};
  const token = PropertiesService.getScriptProperties().getProperty('TOKEN');
  if (!token || p.token !== token) return out_('error|bad token');
  const lock = LockService.getScriptLock();
  if (!lock.tryLock(20000)) return out_('error|busy');
  try {
    const sheet = sheet_();
    if (p.action === 'rows') {
      const n = Math.max(1, Math.min(parseInt(p.n, 10) || 14, 400));
      return out_(['ok'].concat(rows_(sheet, n)).join('\n'));
    }
    if (p.action === 'push') return out_(push_(sheet, p));
    if (p.action === 'info') {
      const book = book_();
      return out_(['ok', 'code|' + CODE_VERSION, 'file|' + book.getName(),
        'tab|' + sheet.getName() + '|rows ' + sheet.getLastRow() + '|A2 ' + dateText_(sheet.getRange(2, 1).getValue()),
        'tabs|' + book.getSheets().map(function (t) { return t.getName(); }).join(', ')].join('\n'));
    }
    return out_('error|unknown action');
  } catch (err) {
    return out_('error|' + String(err && err.message || err).replace(/\s+/g, ' '));
  } finally {
    lock.releaseLock();
  }
}

function out_(s) {
  return ContentService.createTextOutput(s + '\n').setMimeType(ContentService.MimeType.TEXT);
}

function book_() {
  return SPREADSHEET_ID ? SpreadsheetApp.openById(SPREADSHEET_ID) : SpreadsheetApp.getActiveSpreadsheet();
}

// A configured tab that does not exist is an error, not a new empty tab: the sheet has history.
function sheet_() {
  const ss = book_();
  if (!SHEET_NAME) return ss.getSheets()[0];
  const sh = ss.getSheetByName(SHEET_NAME);
  if (!sh) throw new Error('tab "' + SHEET_NAME + '" not found');
  return sh;
}

function dateText_(v) {
  if (v instanceof Date) {
    const tz = book_().getSpreadsheetTimeZone();
    return Utilities.formatDate(v, tz, 'dd.MM.yyyy');
  }
  const m = String(v).trim().match(/^(\d{1,2})\.(\d{1,2})\.(\d{4})$/);
  return m ? ('0' + m[1]).slice(-2) + '.' + ('0' + m[2]).slice(-2) + '.' + m[3] : '';
}

// dd.mm.yyyy -> yyyymmdd (sorts by date), '' if empty
function sortKey_(d) { return d ? d.slice(6) + d.slice(3, 5) + d.slice(0, 2) : ''; }

// "18813,78", "18.813,78" or a number -> number (NaN if empty or not a number).
function number_(v) {
  if (typeof v === 'number') return v;
  let s = String(v).replace(/[\s ]/g, '');
  if (!s) return NaN;
  if (s.indexOf(',') >= 0) s = s.replace(/\./g, '').replace(',', '.');
  return Number(s);
}

// Row number of the first data row: 2 when row 1 is a header (its A cell is not a date), else 1.
function firstRow_(sheet) {
  if (sheet.getLastRow() < 1) return 1;
  return dateText_(sheet.getRange(1, 1).getValue()) ? 1 : 2;
}

function rows_(sheet, n) {
  const first = firstRow_(sheet);
  const count = Math.min(n, sheet.getLastRow() - first + 1);
  if (count < 1) return [];
  return sheet.getRange(first, 1, count, 3).getValues()
    .map(function (r) {
      const d = dateText_(r[0]), t = number_(r[1]), c = number_(r[2]);
      if (!d) return '';
      return d + '|' + (isNaN(t) ? '' : t.toFixed(2)) + '|' + (isNaN(c) ? '' : c.toFixed(2));
    })
    .filter(function (s) { return s; });
}

function push_(sheet, p) {
  const date = dateText_(p.date || '');
  const total = Number(p.total), daily = Number(p.daily);
  if (!date || !isFinite(total) || !isFinite(daily)) return 'error|bad values';
  const first = firstRow_(sheet);
  // Newest row first, or no row at all: a tab in the old order (oldest first, such as the backup
  // that pizero's reverse_sheet.py made) would get the new row in the wrong place.
  if (sheet.getLastRow() >= first + 1) {
    const two = sheet.getRange(first, 1, 2, 1).getValues();
    const a = sortKey_(dateText_(two[0][0])), b = sortKey_(dateText_(two[1][0]));
    if (a && b && a < b) return 'error|tab "' + sheet.getName() + '" is oldest first: set SHEET_NAME';
  }
  // A second push for the same day (retry, or the Pi still running) must not add a row.
  if (sheet.getLastRow() >= first && dateText_(sheet.getRange(first, 1).getValue()) === date) {
    return 'dup|' + date;
  }
  sheet.insertRowBefore(first);
  const row = sheet.getRange(first, 1, 1, 3);
  // Format from the previous newest row (now one row down), not from the header.
  if (sheet.getLastRow() > first) {
    sheet.getRange(first + 1, 1, 1, 3).copyTo(row, SpreadsheetApp.CopyPasteType.PASTE_FORMAT, false);
  }
  // Like "USER_ENTERED" on the Pi: the sheet reads the date text as a date in its own locale.
  row.setValues([[date, Math.round(total * 100) / 100, Math.round(daily * 100) / 100]]);
  return 'ok|row ' + first;
}
