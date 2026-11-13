"""Synthetic Tibber Pulse Bridge payloads (SML and plaintext) and preview data for the meter view.

    uv run --project tools python tools/test/tibber_fixtures.py preview DIR

writes DIR/node_data.json (an SML frame), DIR/tibber-days.txt and DIR/tibber.base, with dates relative
to today, for tools/dev-render.sh. check_meter.py imports build_sml() and build_text().

The frames are made here, not copied from a real meter: a real frame carries the meter's ID.
"""

from __future__ import annotations

import datetime as dt
import math
import struct
import sys
from pathlib import Path

# CRC-16/X-25, as SML uses it (smllib.crc.x25).
def crc_x25(data: bytes) -> int:
    crc = 0xFFFF
    for byte in data:
        crc ^= byte
        for _ in range(8):
            crc = (crc >> 1) ^ 0x8408 if crc & 1 else crc >> 1
    crc ^= 0xFFFF
    return ((crc & 0xFF) << 8) | (crc >> 8)  # SML sends it byte-swapped


def _tl(typ: int, length: int) -> bytes:
    """Type-length field. length: element count for a list, else data bytes."""
    if typ == 7:
        if length < 16:
            return bytes([0x70 | length])
        return bytes([0xF0 | (length >> 4), length & 0x0F])
    if length + 1 < 16:
        return bytes([(typ << 4) | (length + 1)])
    total = length + 2
    return bytes([0x80 | (typ << 4) | (total >> 4), total & 0x0F])


def octets(b: bytes) -> bytes:
    return _tl(0, len(b)) + b


def uint(v: int, size: int) -> bytes:
    return _tl(6, size) + v.to_bytes(size, "big")


def sint(v: int, size: int) -> bytes:
    return _tl(5, size) + v.to_bytes(size, "big", signed=True)


def lst(*items: bytes) -> bytes:
    return _tl(7, len(items)) + b"".join(items)


NONE = b"\x01"
END = b"\x00"


def message(txid: int, tag: int, body: bytes) -> bytes:
    # The CRC covers the message up to the CRC field.
    raw =_tl(7, 6) + octets(bytes([txid])) + uint(0, 1) + uint(0, 1) + lst(uint(tag, 4), body)
    return raw + uint(crc_x25(raw), 2) + END


def entry(obis: bytes, unit: int | None, scaler: int | None, value: bytes, status: bytes = NONE) -> bytes:
    return lst(
        octets(obis), status, NONE,
        uint(unit, 1) if unit is not None else NONE,
        sint(scaler, 1) if scaler is not None else NONE,
        value, NONE,
    )


SERVER_ID = bytes.fromhex("0a01000000000000000000")  # fake meter ID
OBIS_TOTAL = bytes.fromhex("0100010800ff")
OBIS_T1 = bytes.fromhex("0100010801ff")
OBIS_EXPORT = bytes.fromhex("0100020800ff")
OBIS_POWER = bytes.fromhex("0100100700ff")
OBIS_TOTAL_96 = bytes.fromhex("010001080060")  # 1.8.0*96: not the counter, must be ignored


def build_sml(total_wh: float, power_w: float | None = None, *, total_scaler: int = -1,
              total_size: int = 8, power_size: int = 4, extra: int = 0, prefix: bytes = b"") -> bytes:
    """One SML file: open, get-list (total, tariff 1, export, power, optional fillers), close."""
    total_raw = round(total_wh / 10 ** total_scaler)
    entries = [
        entry(bytes.fromhex("8181c78203ff"), None, None, octets(b"FAK")),
        entry(OBIS_TOTAL, 30, total_scaler, uint(total_raw, total_size),
              status=uint(0x1C0104, 4)),
        entry(OBIS_TOTAL_96, 30, 0, uint(123, 2)),
        entry(OBIS_T1, 30, total_scaler, uint(total_raw, total_size)),
        entry(OBIS_EXPORT, 30, -1, uint(4567, 4)),
    ]
    if power_w is not None:
        entries.append(entry(OBIS_POWER, 27, 0, sint(round(power_w), power_size)))
    for k in range(extra):  # long lists: more than 15 entries need a two-byte type-length field
        entries.append(entry(bytes([1, 0, 32 + k % 40, 7, 0, 255]), 35, -1, uint(2300 + k, 2)))
    body_open = lst(NONE, NONE, octets(b"\x00\x01"), octets(SERVER_ID), NONE, NONE)
    body_list = lst(NONE, octets(SERVER_ID), NONE, lst(uint(1, 1), uint(123456, 4)), lst(*entries), NONE, NONE)
    body_close = lst(NONE)
    data = (message(1, 0x0101, body_open) + message(2, 0x0701, body_list)
            + message(3, 0x0201, body_close))
    pad = (4 - len(data) % 4) % 4
    frame = b"\x1b\x1b\x1b\x1b\x01\x01\x01\x01" + data + b"\x00" * pad + b"\x1b\x1b\x1b\x1b\x1a" + bytes([pad])
    return prefix + frame + struct.pack(">H", crc_x25(frame))


def build_text(total_kwh: float, power_w: float | None) -> bytes:
    lines = ["/FAK5FAKE", "", "1-0:0.0.0*255(00000000)",
             "1-0:1.8.0*255({:011.4f}*kWh)".format(total_kwh),
             "1-0:21.8.0*255(000123.4000*kWh)"]
    if power_w is not None:
        lines.append("1-0:16.7.0*255({:07.0f}*W)".format(power_w))
    lines.append("!")
    return ("\r\n".join(lines) + "\r\n").encode()


def preview(out: Path) -> None:
    """node_data.json, tibber-days.txt (70 days, newest first) and tibber.base for dev-render.sh."""
    out.mkdir(parents=True, exist_ok=True)
    today = dt.date.today()
    total = 18000.0
    rows = []
    for k in range(70, 0, -1):  # oldest first, so the totals go up
        d = today - dt.timedelta(days=k)
        daily = round(9.5 + 3.2 * math.sin(k * 0.9) + (2.5 if d.weekday() >= 5 else 0), 2)
        total = round(total + daily, 2)
        rows.append((d, total, daily))
    rows = rows[:-2]  # the last two nights are missing in the sheet: the chart shows the gap
    (out / "tibber-days.txt").write_text(
        "".join("{}|{:.2f}|{:.2f}\n".format(d.strftime("%d.%m.%Y"), t, v) for d, t, v in reversed(rows)))
    yesterday = today - dt.timedelta(days=1)
    base = total + 21.4
    (out / "tibber.base").write_text("{}|{:.4f}\n".format(yesterday.strftime("%d.%m.%Y"), base))
    (out / "node_data.json").write_bytes(build_sml((base + 7.43) * 1000, 1284))


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "preview":
        preview(Path(sys.argv[2]))
    else:
        sys.exit("usage: tibber_fixtures.py preview DIR")
