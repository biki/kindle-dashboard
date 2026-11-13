# Google Sheet: Apps Script web app

The Kindle writes one row per day into the existing sheet (the sheet that the Pi filled before). It cannot sign a Google service-account token, so a small script in the sheet does the write. The Kindle calls the script URL with a secret token.

## Install (once)

1. Open the sheet. Select **Extensions > Apps Script**.
2. Replace the code in `Code.gs` with [`Code.gs`](Code.gs) from this folder. If the rows are not on the first tab, set `SHEET_NAME`.
3. Select **Project Settings** (gear icon) > **Script Properties** > **Add script property**. Name: `TOKEN`. Value: a long random string of letters and digits. For example, run `openssl rand -hex 24` on the Mac.
4. Select **Deploy > New deployment**. Type: **Web app**. Execute as: **Me**. Who has access: **Anyone**. Select **Deploy** and allow the access.
5. Copy the web app URL (it ends with `/exec`).
6. Add to `secrets.conf` on the Kindle:
   ```sh
   SHEET_URL="https://script.google.com/macros/s/.../exec"
   SHEET_TOKEN="the TOKEN value"
   ```

"Anyone" means: anyone with the URL can call the script. The script does nothing without the correct token.

## Google Workspace accounts

A Workspace (company) admin can block web apps for callers outside the domain. Then every call without a Google login gets HTTP 403 "Zugriff verweigert" (access denied), also with "Who has access: Anyone". The Kindle has no Google login.

Fix: share the sheet with a private Gmail account (editor). In that account, make a standalone script at script.google.com with `Code.gs`, set `SPREADSHEET_ID` to the ID from the sheet URL (`docs.google.com/spreadsheets/d/<ID>/edit`), and do steps 3 to 6 above.

## Test from the Mac

```sh
curl -sL -d "token=TOKEN&action=rows&n=3" "https://script.google.com/macros/s/.../exec"
```

The answer is `ok`, then the newest 3 rows as `dd.mm.yyyy|total|daily`.

`action=info` shows the code version, the file, the tab in use (rows, date in A2) and all tabs. If the code version is old: save the code (Cmd+S) before you deploy a new version.

## Change the script later

Edit the code, then select **Deploy > Manage deployments**, edit the deployment, and select **Version: New version**. The URL stays the same. A new deployment gets a new URL.

## Contract

- Column A: date `dd.mm.yyyy`. Column B: meter total in kWh. Column C: consumption of that day in kWh.
- Row 1 is the header. Each push inserts the new row at row 2 (newest first). The format comes from the old row 2.
- If row 2 already has the date (a retry, or the Pi still runs), the script writes nothing and answers `dup`.
- A tab name in `SHEET_NAME` that does not exist is an error. The script does not make a new tab.
