# Kindle dashboard

An e-ink dashboard that runs on a jailbroken Kindle Paperwhite, with no server. It shows the date and time, the weather (now, the next 24 hours, the next 6 days) and your calendar.

A second view shows the power meter (Tibber Pulse Bridge): power, today's consumption, the meter total, the last 14 days and month totals. Each night at 23:55, the Kindle writes the day's consumption into a Google Sheet. This replaces the old Raspberry Pi Zero ([biki/pizero](https://github.com/biki/pizero)). A single tap switches between the two views.

Inspired by [re-kindle](https://github.com/abdenourgnx/re-kindle). The Kindle does all the work:

```
Kindle Paperwhite (/mnt/us/kindledash)
  loop.sh   Wi-Fi on ─▶ curl  Open-Meteo CSV (no API key)
                      ─▶ curl  ICS calendars (hourly)
                      ─▶ curl  Tibber bridge on the home network (meter.awk decodes SML)
            Wi-Fi off
            ical.awk   ─▶ events.txt   (expands repeats, time zones, exceptions)
            render.awk ─▶ draw commands (text widths from fontdata.awk)
            FBInk      ─▶ screen (Nunito TTF, PNG icons, one full refresh)
            suspend to RAM until the next refresh (RTC alarm)

  tibber.sh push   at 23:55: meter counter - counter of the last row ─▶ Apps Script ─▶ Google Sheet
```

Tested target: Kindle Paperwhite (758×1024), firmware 5.12.2.2, WinterBreak2 jailbreak, FBInk 1.25.0 in `/mnt/us/libkh/bin`. KUAL is not needed: the dashboard starts from scriptlets (`.sh` files in `documents`).

## Install

1. Edit `kindle/kindledash/kindledash.conf`: place, latitude, longitude, language, schedule.
2. Connect the Kindle over USB and copy the files:
   ```sh
   cp -RX kindle/kindledash /Volumes/Kindle/
   cp -X kindle/documents/kindledash-*.sh /Volumes/Kindle/documents/
   find /Volumes/Kindle/kindledash /Volumes/Kindle/documents -name '._*' -delete
   ```
3. Create `/Volumes/Kindle/kindledash/secrets.conf` with your calendars (ICS URLs, separated by spaces):
   ```sh
   CALENDARS="https://calendar.google.com/calendar/ical/.../basic.ics"
   ```
   Google Calendar: Settings > your calendar > "Secret address in iCal format". This file stays on the Kindle only. It is not in the repo, and updates never change it.
4. Eject the Kindle. In the library, open **Dashboard: Start**.

After this first install, updates come over Wi-Fi (see below).

### Power meter and Google Sheet (optional)

1. Set up the Apps Script web app in the sheet: see [`tools/sheet/README.md`](tools/sheet/README.md).
2. Add to `secrets.conf` on the Kindle:
   ```sh
   TIBBER_HOST="..."   # address of the bridge (router: list of network devices)
   TIBBER_PASS="..."   # password on the sticker on the back of the bridge
   SHEET_URL="https://script.google.com/macros/s/.../exec"
   SHEET_TOKEN="..."
   ```
   These are the values from `/etc/pizero/config.ini` on the Pi. Without `SHEET_URL`, the Kindle keeps the daily values only for its own chart.
3. Run **Dashboard: Probe** and read `probe.txt`. The `meter bridge` section must show `decoded` with your meter total, and the `sheet` section must show `ok` and rows.
4. When the Kindle wrote its first row: stop the Pi's timer (`sudo systemctl disable --now pizero-daily.timer`). Until then, both can run: the script writes only one row per day.

The first night uses the newest sheet row as the baseline, so no day is lost. USB is necessary again only for `secrets.conf` and for the logs.

## Updates over Wi-Fi

The Kindle pulls new versions from this GitHub repo (`UPDATE_URL` in `kindledash.conf`):

1. Change the files on the Mac and test them (`tools/dev-render.sh`).
2. Run `sh tools/release.sh "What changed"`. It writes `kindle/kindledash/MANIFEST` (an MD5 checksum per file), commits and pushes.
3. The Kindle checks the manifest every `UPDATE_EVERY` minutes (60) during a refresh, and after each power-button press. To install at once: press the power button.

`update.sh` downloads only the changed files and checks them before it uses them: MD5 checksum, shell syntax, and one test render. If a check fails, the Kindle keeps the old version and logs the reason in `loop.log`. Settings in `kindledash.conf` also come with updates. `secrets.conf` never does.

## Use

- The Kindle wakes at every full hour (`INTERVAL=60`). It does not wake between 23:00 and 06:00 (`NIGHT_START`, `NIGHT_END`).
- **Power button**: wakes the Kindle, turns the front light on (`FL_LEVEL`) and refreshes at once. After the refresh, it stays awake for 30 s. Then the light goes off and the Kindle sleeps.
- **Front light**: off while the Kindle sleeps. Deep sleep with the light off gives the longest battery life. "Dashboard: Stop" restores your old light level.
- **Single tap** while it is awake: switches between the dashboard and the power meter view (only with `TIBBER_HOST` set). The switch comes about 3 s after the tap, because a second tap would mean "stop". The Kindle keeps the view until the next tap, also after an update. Each tap keeps the Kindle awake for `IDLE` more seconds.
- **Double tap** while it is awake (two taps within about 2 s): stops the dashboard and goes to the home screen. This also works during a refresh. A sleeping Kindle does not feel taps: press the power button first.
- If taps do not work: hold the power button for about 15 s. The Kindle restarts without the dashboard.
- **USB cable**: the dashboard stops when you connect a cable, and it does not start while a cable is connected. The Kindle cannot tell a computer from a wall charger, so a charger also stops it. To keep the dashboard running on a charger, set `USB_STOP=0` (then stop the dashboard yourself before you connect a computer).
- The screen has no clock, because it changes only every hour. The footer shows the time of the last refresh.
- The power value is the reading at the last refresh, not live. The time of the reading is below it. Press the power button for a new reading.
- **Daily row**: the Kindle wakes at `PUSH_AT` (23:55), also in the night pause. It reads the meter twice, writes the row, and sleeps again. It does not draw and does not turn on the light. If the bridge or the sheet fails, it tries again every 10 minutes for 1 hour. After that, the next night writes one row for two days (as the Pi did).
- The Kindle writes rows only while the dashboard runs. A night with the dashboard stopped becomes part of the next row.

## Battery

Each refresh turns on Wi-Fi for about 10–20 s. Between refreshes, the Kindle sleeps with Wi-Fi and the front light off. `loop.log` records the battery level at each refresh. Settings that give a longer battery life: a larger `INTERVAL`, a longer night pause, `FL_LEVEL=0`.

## Troubleshooting

- `kindledash/loop.log` has about one line per refresh and step.
- **Dashboard: Probe** writes `kindledash/probe.txt`: tools, screen data, input devices, and tests of the weather and calendar downloads.
- Taps do nothing: find the touchscreen in `probe.txt` (section `input`) and set `TOUCH=/dev/input/eventN` in `kindledash.conf`.

## Development (Mac)

Requires [uv](https://docs.astral.sh/uv/) and Docker (for busybox, the Kindle's shell and awk).

```sh
uv run --project tools python tools/build.py         # fonts, fontdata.awk, icons (KD_FONTS=fredoka: Fredoka for large text)
sh tools/dev-render.sh /tmp/dash.png                  # run the real loop.sh once in busybox, draw a preview
sh tools/dev-render.sh /tmp/dash.png my.ics de        # with your calendar file, in German
sh tools/dev-render.sh /tmp/meter.png "" de tibber   # the power meter view (fake bridge and sheet rows)
uv run --project tools --with icalendar --with recurring-ical-events \
    python tools/test/check_ical.py                   # ical.awk against the Python icalendar libraries
uv run --project tools --with smllib python tools/test/check_meter.py [raw.bin]
                                                      # meter.awk against smllib (also on your own capture)
sh tools/test/check_tibber.sh                         # tibber.sh: read, daily row, errors (fake bridge and sheet)
sh tools/test/check_update.sh                         # update.sh in busybox, with a local web server as GitHub
```

Set `BUSYBOX=busybox:1.28.3` to run the busybox tests in the Kindle's version (the default is 1.36).

The bridge firmware changed the data path: older firmware (pizero) used `/data.json?node_id=1`, current firmware uses `/node_data.json?node_id=1` (the default in `TIBBER_PATH`). Both send raw SML. The password is the code on the bridge sticker (login realm `admin:QR-CODE`).

To check the decoder on your own meter, capture one payload on the home network and give it to `check_meter.py`. Do not commit it: an SML frame contains the meter ID.

```sh
curl -u admin:PASSWORD -o /tmp/raw.bin "http://BRIDGE-ADDRESS/node_data.json?node_id=1"
```

`tools/preview.py` draws the commands with FBInk's font metrics, so the preview matches the Kindle within a few pixels. It warns when a text would not fit its box, because FBInk would wrap it.

## Files

| Path | Purpose |
|------|---------|
| `kindle/kindledash/loop.sh` | Main loop on the Kindle: Wi-Fi, downloads, drawing, suspend, taps. |
| `kindle/kindledash/render.awk` | Layout. Writes `T`/`I`/`R` draw commands. |
| `kindle/kindledash/ical.awk` | ICS parser: RRULE (daily, weekly, monthly, yearly), EXDATE, RECURRENCE-ID, VTIMEZONE. |
| `kindle/kindledash/common.awk` | Date functions shared by both awk scripts. |
| `kindle/kindledash/tibber.sh` | Power meter: reading, daily sheet row, sheet rows for the chart. |
| `kindle/kindledash/meter.awk` | Decodes the bridge data (SML, or plaintext OBIS) into the meter total and the power. |
| `kindle/kindledash/tibber.awk` | Layout of the power meter view (appended after `render.awk`). |
| `tools/sheet/` | Apps Script for the Google Sheet, and its setup. |
| `kindle/kindledash/fontdata.awk` | Generated: font metrics and glyph widths. |
| `kindle/kindledash/fonts/`, `icons/` | Generated: Nunito static fonts (SIL OFL), weather icons, detail icons, card corners. |
| `kindle/documents/` | Scriptlets: Start, Stop, Probe. |
| `tools/` | Build, preview and test tools (Mac). |

## Known limits

- ICS: BYSETPOS, BYWEEKNO, BYYEARDAY and HOURLY rules are not supported. Times in foreign time zones can be 1 hour off in the days around a daylight saving change.
- The layout is for 758×1024. Other Kindle models need other icon sizes and coordinates.
