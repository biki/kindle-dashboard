# Kindle dashboard

An e-ink dashboard that runs on a jailbroken Kindle Paperwhite, with no server. It shows the date and time, the weather (now, the next 24 hours, the next 6 days) and your calendar.

Inspired by [re-kindle](https://github.com/abdenourgnx/re-kindle). The Kindle does all the work:

```
Kindle Paperwhite (/mnt/us/kindledash)
  loop.sh   Wi-Fi on ─▶ curl  Open-Meteo CSV (no API key)
                      ─▶ curl  ICS calendars (hourly)
            Wi-Fi off
            ical.awk   ─▶ events.txt   (expands repeats, time zones, exceptions)
            render.awk ─▶ draw commands (text widths from fontdata.awk)
            FBInk      ─▶ screen (Nunito TTF, PNG icons, one full refresh)
            suspend to RAM until the next refresh (RTC alarm)
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

After this first install, updates come over Wi-Fi (see below). USB is necessary again only for `secrets.conf` and for the logs.

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
- **Double tap** while it is awake (two taps within about 2 s): stops the dashboard and goes to the home screen. This also works during a refresh. A sleeping Kindle does not feel taps: press the power button first.
- If taps do not work: hold the power button for about 15 s. The Kindle restarts without the dashboard.
- Stop the dashboard before you connect USB.
- The screen has no clock, because it changes only every 15 minutes. The footer shows the time of the last refresh.

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
uv run --project tools --with icalendar --with recurring-ical-events \
    python tools/test/check_ical.py                   # ical.awk against the Python icalendar libraries
sh tools/test/check_update.sh                         # update.sh in busybox, with a local web server as GitHub
```

`tools/preview.py` draws the commands with FBInk's font metrics, so the preview matches the Kindle within a few pixels. It warns when a text would not fit its box, because FBInk would wrap it.

## Files

| Path | Purpose |
|------|---------|
| `kindle/kindledash/loop.sh` | Main loop on the Kindle: Wi-Fi, downloads, drawing, suspend, taps. |
| `kindle/kindledash/render.awk` | Layout. Writes `T`/`I`/`R` draw commands. |
| `kindle/kindledash/ical.awk` | ICS parser: RRULE (daily, weekly, monthly, yearly), EXDATE, RECURRENCE-ID, VTIMEZONE. |
| `kindle/kindledash/common.awk` | Date functions shared by both awk scripts. |
| `kindle/kindledash/fontdata.awk` | Generated: font metrics and glyph widths. |
| `kindle/kindledash/fonts/`, `icons/` | Generated: Nunito static fonts (SIL OFL), weather icons, detail icons, card corners. |
| `kindle/documents/` | Scriptlets: Start, Stop, Probe. |
| `tools/` | Build, preview and test tools (Mac). |

## Known limits

- ICS: BYSETPOS, BYWEEKNO, BYYEARDAY and HOURLY rules are not supported. Times in foreign time zones can be 1 hour off in the days around a daylight saving change.
- The layout is for 758×1024. Other Kindle models need other icon sizes and coordinates.
