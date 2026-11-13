# Power meter view (Tibber Pulse). loop.sh appends this file after render.awk and runs it with
# view=tibber. It uses the helpers of render.awk (T, box, rect, title, header, battery, hm).
# Written for busybox awk: no gawk functions, no "name (expr)" concatenation.
#
# Vars: view   tibber (any other value: this file draws nothing)
#       off    UTC offset in seconds (tibber.txt has UTC times)
#       pushat PUSH_AT (hh:mm), for the label "since dd.mm. 23:55"
#       tfile  tibber.txt       utc_epoch|total_kwh|power_w        last good reading
#       bfile  tibber.base      dd.mm.yyyy|total_kwh               counter at the last sheet row
#       dfile  tibber-days.txt  dd.mm.yyyy|total_kwh|daily_kwh     sheet rows, newest first
# A row dated D covers PUSH_AT on the day before D until PUSH_AT on D (23:55 to 23:55).

BEGIN {
    if (view == "tibber") {
        tsetup()
        off += 0
        if ((getline line < tfile) > 0) {
            split(line, a, "|")
            if (a[2] != "") { HAVEM = 1; MTIME = a[1] + off; TOT = a[2] + 0; PWR = a[3] }
        }
        if ((getline line < bfile) > 0) { split(line, a, "|"); BD = a[1]; BT = a[2] }
        while ((getline line < dfile) > 0) {
            if (split(line, a, "|") < 3) continue
            NR2++
            if (NR2 == 1) { NEWD = a[1]; NEWT = a[2] }
            if (!(a[1] in DAY) && a[3] != "") DAY[a[1]] = a[3] + 0
        }
        # No row by the Kindle yet: the newest sheet row is the baseline (as in tibber.sh).
        if (BT == "" && NEWT != "") { BD = NEWD; BT = NEWT }
    }
}

END { if (view == "tibber") meter() }

function tsetup() {
    if (lang == "de") {
        Y["power"] = "Leistung"; Y["at"] = "gemessen"; Y["old"] = "Stand"; Y["off"] = "Zähler nicht erreichbar"
        Y["none"] = "Keine Zählerdaten"; Y["today"] = "Heute"; Y["since"] = "seit"; Y["meter"] = "Zählerstand"
        Y["chart"] = "Letzte 14 Tage"; Y["perday"] = "pro Tag"; Y["sum"] = "Übersicht"
        Y["avg7"] = "Ø 7 Tage"; Y["avg30"] = "Ø 30 Tage"; Y["kday"] = "kWh pro Tag"
        Y["sofar"] = "kWh bis gestern"; Y["days"] = "Tage"; Y["upd"] = "Aktualisiert"
    } else {
        Y["power"] = "Power"; Y["at"] = "measured"; Y["old"] = "Reading from"; Y["off"] = "meter unreachable"
        Y["none"] = "No meter data"; Y["today"] = "Today"; Y["since"] = "since"; Y["meter"] = "Meter"
        Y["chart"] = "Last 14 days"; Y["perday"] = "per day"; Y["sum"] = "Summary"
        Y["avg7"] = "Ø 7 days"; Y["avg30"] = "Ø 30 days"; Y["kday"] = "kWh per day"
        Y["sofar"] = "kWh to yesterday"; Y["days"] = "days"; Y["upd"] = "Updated"
    }
}

# Number with grouping: de 18.813,78 / en 18,813.78. Minus sign U+2212.
function grp(x, dec,   s, i, ip, fp, neg, out, gs, ds) {
    gs = lang == "de" ? "." : ","; ds = lang == "de" ? "," : "."
    s = sprintf("%." dec "f", x)
    neg = substr(s, 1, 1) == "-"
    if (neg) s = substr(s, 2)
    ip = s; fp = ""
    i = index(s, ".")
    if (i > 0) { ip = substr(s, 1, i - 1); fp = substr(s, i + 1) }
    out = ""
    while (length(ip) > 3) { out = gs substr(ip, length(ip) - 2) out; ip = substr(ip, 1, length(ip) - 3) }
    out = ip out
    if (fp != "") out = out ds fp
    if (neg && out ~ /[1-9]/) out = "−" out
    return out
}

function lbl(z) { cfd(z); return sprintf("%02d.%02d.%04d", CD, CM, CY) }

function meter() {
    STALE = !HAVEM || now - MTIME > 7200
    TODAYK = ""
    if (HAVEM && BT != "") { TODAYK = TOT - BT; if (TODAYK < 0) TODAYK = "" }
    # Baseline from yesterday (or tonight): the value is today's. Older: several days (no bar).
    ONEDAY = BD == lbl(today) || BD == lbl(today - 1)
    header()
    card()
    chart()
    summary()
    T("R", 16, ML, 1014, "GRAY5", "l", Y["upd"] " " hm(now), 520)
    battery()
}

# Gray card: power on the left; today and the meter total on the right.
function card(   x, col, sz, s, lab) {
    box(ML - 8, 124, MR - ML + 16, 236, 18, "GRAYE", "e")
    x = ML + 8; col = 456
    T("B", 24, x, 172, "BLACK", "l", Y["power"], 0)
    if (!HAVEM) {
        T("B", 30, x, 262, "BLACK", "l", Y["none"], col - x - 30)
    } else {
        s = PWR == "" ? "–" : grp(PWR, 0)
        sz = 112
        while (sz > 56 && width("D", sz, s) + width("B", 38, " W") > col - x - 30) sz -= 4
        T("D", sz, x, 284, "BLACK", "l", s, 0)
        T("B", 38, x + TW + 10, 284, "BLACK", "l", "W", 0)
        s = (STALE ? Y["old"] : Y["at"]) " " hm(MTIME)
        if (STALE) s = s " · " Y["off"]
        T("R", 21, x, 330, "GRAY5", "l", s, col - x - 24)
    }
    rect(col - 22, 148, 2, 188, "GRAYB")

    lab = Y["today"]
    if (BD != "" && !ONEDAY) lab = Y["since"] " " substr(BD, 1, 6) " " pushat
    T("R", 21, col, 172, "GRAY5", "l", lab, MR - col)
    T("B", 40, col, 226, "BLACK", "l", TODAYK == "" ? "–" : grp(TODAYK, 2) " kWh", MR - col)
    T("R", 21, col, 278, "GRAY5", "l", Y["meter"], MR - col)
    T("B", 30, col, 322, "BLACK", "l", HAVEM ? grp(TOT, 1) " kWh" : "–", MR - col)
}

# Bars for the last 13 sheet rows and today so far (gray), with the average as a line.
function chart(   k, z, d, v, n, sum, mx, cw, cx, top, base, h, avg, ya, col) {
    title(ML, 404, Y["chart"])
    for (k = 0; k < 14; k++) {
        z = today - 13 + k; d = lbl(z)
        V[k] = (d in DAY) ? DAY[d] : ""
        if (k == 13) V[k] = ONEDAY ? TODAYK : ""
    }
    n = 0; sum = 0; mx = 0
    for (k = 0; k < 14; k++) {
        if (V[k] == "") continue
        if (V[k] > mx) mx = V[k]
        if (k < 13) { n++; sum += V[k] }
    }
    if (n) {
        avg = sum / n
        T("R", 21, MR, 404, "GRAY5", "r", "Ø " grp(avg, 1) " kWh " Y["perday"], 0)
    }
    if (mx <= 0) mx = 1
    base = 716; top = 496; cw = (MR - ML) / 14
    if (n) { ya = base - (base - top) * avg / mx; rect(ML, ya, MR - ML, 2, "GRAYB") }
    rect(ML, base, MR - ML, 2, "BLACK")
    for (k = 0; k < 14; k++) {
        z = today - 13 + k; cx = ML + cw * (k + 0.5)
        col = k == 13 ? "GRAY9" : "BLACK"
        if (V[k] != "") {
            h = (base - top) * V[k] / mx
            if (h < 2) h = 2
            rect(cx - 15, base - h, 30, h, col)
            T("R", 15, cx, round(base - h - 8), "GRAY5", "c", grp(V[k], V[k] < 10 ? 1 : 0), 0)
        } else T("R", 18, cx, base - 10, "GRAY9", "c", "–", 0)
        cfd(z)
        T("B", 18, cx, 744, k == 13 ? "GRAY5" : "BLACK", "c", dayname(z, 1), 0)
        T("R", 15, cx, 768, "GRAY5", "c", CD ".", 0)
    }
}

# Averages and month totals from the sheet rows.
function summary(   cw, k, z, d, n7, s7, n30, s30, ym, cy, pm, py, nm, sm, np, sp, dd, a) {
    title(ML, 820, Y["sum"])
    box(ML - 8, 838, MR - ML + 16, 140, 18, "GRAYE", "e")
    n7 = s7 = n30 = s30 = 0
    for (k = 1; k <= 30; k++) {
        d = lbl(today - k)
        if (!(d in DAY)) continue
        if (k <= 7) { n7++; s7 += DAY[d] }
        n30++; s30 += DAY[d]
    }
    cfd(today); ym = CM; cy = CY; py = CY; pm = CM - 1
    if (pm < 1) { pm = 12; py-- }
    nm = sm = np = sp = 0
    for (d in DAY) {
        split(d, a, ".")
        if (a[2] + 0 == ym && a[3] + 0 == cy) { nm++; sm += DAY[d] }
        else if (a[2] + 0 == pm && a[3] + 0 == py) { np++; sp += DAY[d] }
    }
    cw = (MR - ML) / 4
    stat(ML + cw * 0.5, Y["avg7"], n7 ? grp(s7 / n7, 1) : "–", Y["kday"])
    stat(ML + cw * 1.5, Y["avg30"], n30 ? grp(s30 / n30, 1) : "–", Y["kday"])
    stat(ML + cw * 2.5, MON[ym], nm ? grp(sm, 0) : "–", Y["sofar"])
    dd = dim(py, pm)
    stat(ML + cw * 3.5, MON[pm], np ? grp(sp, 0) : "–", np && np < dd ? "kWh (" np "/" dd " " Y["days"] ")" : "kWh")
}

function stat(cx, label, value, note,   w) {
    w = (MR - ML) / 4 - 8
    T("R", 19, cx, 880, "GRAY5", "c", label, w)
    T("B", 34, cx, 928, "BLACK", "c", value, w)
    T("R", 16, cx, 958, "GRAY5", "c", note, w)
}
