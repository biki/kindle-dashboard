"""Checks kindle/kindledash/meter.awk (in busybox, Docker) against smllib on SML payloads.

    uv run --project tools --with smllib python tools/test/check_meter.py [payload ...]

Without arguments: synthetic frames from tibber_fixtures.py and plaintext payloads.
With arguments: also your own captures, raw (.bin) or as hex text (.hex). Capture one with
    curl -u admin:PASSWORD -o raw.bin "http://BRIDGE-IP/node_data.json?node_id=1"
Do not commit captures: an SML frame carries the meter's ID.

smllib is the reference for SML (as on the old Pi). Only the exact registers 1.8.0*255 and
16.7.0*255 count (pizero also matched 1.8.0*96 and similar, which some meters send).
"""

from __future__ import annotations

import os
import re
import subprocess
import sys
import tempfile
from binascii import a2b_hex
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from tibber_fixtures import build_sml, build_text  # noqa: E402

ROOT = Path(__file__).resolve().parents[2]
TOTAL, POWER = "0100010800ff", "0100100700ff"


def expected_sml(payload: bytes):
    """(total_kwh, power_w) from smllib, or None when there is no 1.8.0."""
    from smllib import SmlStreamReader
    reader = SmlStreamReader()
    reader.add(payload)
    total = power = None
    while True:
        try:
            frame = reader.get_frame()
        except Exception:  # CRC error and similar: the awk decoder has no CRC check
            return "skip"
        if frame is None:
            break
        try:
            entries = frame.get_obis()
        except Exception:  # smllib's shortcut fails on some real frames: parse all messages
            entries = [e for m in frame.parse_frame() for e in (getattr(m.message_body, "val_list", None) or ())]
        for e in entries:
            v = e.get_value() if hasattr(e, "get_value") else e.value
            if not isinstance(v, (int, float)):
                continue
            if str(e.obis) == TOTAL:
                total = v / 1000
            elif str(e.obis) == POWER:
                power = v
    return None if total is None else (total, power)


def expected_text(payload: bytes):
    """pizero's plaintext parser."""
    rx = re.compile(r"(?:\d+-\d+:)?(\d+\.\d+\.\d+)(?:\*\d+)?\((-?[\d.]+)\s*\*?\s*([A-Za-z]*)\)")
    total = power = None
    for obis, value, unit in rx.findall(payload.decode("ascii", "replace")):
        if obis == "1.8.0":
            total = float(value) if unit.lower() == "kwh" else float(value) / 1000
        elif obis == "16.7.0":
            power = float(value) * 1000 if unit.lower() == "kw" else float(value)
    return None if total is None else (total, power)


def cases():
    yield "sml basic", build_sml(18813780, 1284), "sml"
    yield "sml no power", build_sml(18813780, None), "sml"
    yield "sml export (negative power)", build_sml(48213900.5, -734, power_size=2), "sml"
    yield "sml 3-byte power", build_sml(5000, 70000, power_size=3), "sml"
    yield "sml scaler 0, 4-byte total", build_sml(123456, 99, total_scaler=0, total_size=4), "sml"
    yield "sml scaler -2", build_sml(9876543.21, 12, total_scaler=-2), "sml"
    yield "sml long list (two-byte TL)", build_sml(777777, 321, extra=30), "sml"
    yield "sml garbage before the frame", build_sml(18813780, 15, prefix=b"\x00\x1bxy"), "sml"
    yield "text kWh and W", build_text(18813.7812, 1284), "text"
    yield "text no power", build_text(12.5, None), "text"


def main(extra: list[str]) -> int:
    items = list(cases())
    for name in extra:
        p = Path(name)
        data = p.read_bytes()
        if p.suffix == ".hex":
            data = a2b_hex(re.sub(rb"[^0-9a-fA-F]", b"", data))
        items.append((p.name, data, "auto"))

    with tempfile.TemporaryDirectory() as tmp:
        w = Path(tmp)
        (w / "meter.awk").write_bytes((ROOT / "kindle/kindledash/meter.awk").read_bytes())
        for i, (_, data, _) in enumerate(items):
            (w / f"{i}.bin").write_bytes(data)
        # The same pipeline as tibber.sh: SML first, then plaintext.
        script = (
            'for f in /w/*.bin; do r=$(od -An -v -t x1 "$f" | awk -v mode=sml -f /w/meter.awk); '
            '[ -n "$r" ] || r=$(tr -d "\\000" < "$f" | awk -v mode=text -f /w/meter.awk); '
            'echo "$(basename "$f" .bin) $r"; done'
        )
        out = subprocess.run(["docker", "run", "--rm", "-v", f"{w}:/w", os.environ.get("BUSYBOX", "busybox:1.36"), "sh", "-c", script],
                             capture_output=True, text=True, check=True).stdout
    got = {}
    for line in out.splitlines():
        k, _, r = line.partition(" ")
        got[int(k)] = r

    fails = 0
    for i, (name, data, kind) in enumerate(items):
        want = expected_sml(data) if kind in ("sml", "auto") else expected_text(data)
        if kind == "auto" and want is None:
            want = expected_text(data)
        if want == "skip":
            print(f"skip {name}: smllib rejects the frame (CRC)")
            continue
        r = got.get(i, "")
        if want is None:
            ok = r == ""
            detail = f"want no output, got {r!r}"
        else:
            t, _, p = r.partition("|")
            ok = r != "" and abs(float(t) - want[0]) < 0.00051 and (
                (want[1] is None and p == "") or (want[1] is not None and p != "" and abs(float(p) - want[1]) <= 0.5))
            detail = f"want {want[0]:.4f}|{'' if want[1] is None else round(want[1])}, got {r!r}"
        print(f"{'ok  ' if ok else 'FAIL'} {name}: {detail}")
        fails += not ok
    return 1 if fails else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
