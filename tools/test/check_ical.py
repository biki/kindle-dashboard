"""Compares kindle/kindledash/ical.awk (run in busybox) with the Python icalendar libraries.

uv run --project tools --with icalendar --with recurring-ical-events python tools/test/check_ical.py [file.ics]

Needs Docker (busybox image). Prints the differences and exits 1 if there are any.
"""

from __future__ import annotations

import subprocess
import sys
from datetime import date, datetime, timedelta, timezone
from pathlib import Path
from zoneinfo import ZoneInfo

import icalendar
import recurring_ical_events

ROOT = Path(__file__).resolve().parents[2]
TZ = ZoneInfo("Europe/Berlin")
FROM = datetime(2026, 11, 12, tzinfo=TZ)
TO = datetime(2026, 11, 20, tzinfo=TZ)
OFF = 3600  # Berlin in November


def wall(dt: datetime) -> int:
    """Local wall-clock time as if it were UTC (the format ical.awk uses)."""
    return int(dt.astimezone(TZ).replace(tzinfo=timezone.utc).timestamp())


def expected(ics: Path) -> set[tuple]:
    cal = icalendar.Calendar.from_ical(ics.read_bytes())
    out = set()
    for ev in recurring_ical_events.of(cal).between(FROM, TO):
        if str(ev.get("STATUS", "")).upper() == "CANCELLED":
            continue
        s = ev.decoded("DTSTART")
        if isinstance(s, datetime):
            e = ev.decoded("DTEND") if "DTEND" in ev else s + ev.decoded("DURATION", timedelta(0))
            ls, le, order = wall(s), wall(e), 1
        else:
            e = ev.decoded("DTEND") if "DTEND" in ev else s + timedelta(days=1)
            ls = int(datetime(s.year, s.month, s.day, tzinfo=timezone.utc).timestamp())
            le = int(datetime(e.year, e.month, e.day, tzinfo=timezone.utc).timestamp())
            order = 0
        title = " ".join(str(ev.get("SUMMARY", "")).replace("|", "/").split()) or "-"
        out.add((ls // 86400, order, ls, le, title))
    return out


def actual(ics: Path) -> set[tuple]:
    rel = ics.resolve().relative_to(ROOT)
    # Same as the Kindle: concatenate common.awk and ical.awk, then run with busybox awk.
    script = (
        "cat kindle/kindledash/common.awk kindle/kindledash/ical.awk > /tmp/i.awk && "
        f"awk -v from={wall(FROM)} -v to={wall(TO)} -v off={OFF} -v ltz=Europe/Berlin -f /tmp/i.awk {rel}"
    )
    cmd = ["docker", "run", "--rm", "-v", f"{ROOT}:/w:ro", "-w", "/w", "busybox:1.36", "sh", "-c", script]
    res = subprocess.run(cmd, capture_output=True, text=True, check=True)
    out = set()
    for line in res.stdout.splitlines():
        d, o, s, e, t = line.split("|", 4)
        out.add((int(d), int(o), int(s), int(e), t))
    return out


def show(r: tuple) -> str:
    fmt = lambda x: datetime.fromtimestamp(x, timezone.utc).strftime("%a %d.%m %H:%M")  # noqa: E731
    return f"{fmt(r[2])} - {fmt(r[3])}  {'all-day' if r[1] == 0 else 'timed  '}  {r[4]}"


if __name__ == "__main__":
    ics = Path(sys.argv[1]) if len(sys.argv) > 1 else ROOT / "tools" / "test" / "cases.ics"
    exp, act = expected(ics), actual(ics)
    for r in sorted(exp | act, key=lambda r: (r[0], r[1], r[2])):
        mark = "  ok " if r in exp and r in act else ("MISS " if r in exp else "EXTRA")
        print(mark, show(r))
    bad = exp ^ act
    print(f"\n{len(exp & act)} match, {len(exp - act)} missing in ical.awk, {len(act - exp)} extra in ical.awk")
    sys.exit(1 if bad else 0)
