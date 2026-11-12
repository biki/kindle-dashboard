# Turns weather.csv (Open-Meteo CSV) and events.txt (from ical.awk, sorted) into draw commands
# for loop.sh. Run after fontdata.awk and common.awk (the Kindle concatenates the three files).
# Written for busybox awk: no gawk functions, no "name (expr)" concatenation.
#
# Vars: now      local wall-clock epoch (local time written as if it were UTC)
#       lang     en | de
#       place    place name for the header
#       batt     battery percent ("" = unknown)
#       wtime    local wall-clock epoch of the last good weather download ("" = never)
#       ncal     number of calendars configured;  calfail  number that failed to download
#
# Output (one command per line, | separated, coordinates in screen pixels):
#   T|font|px|left|right|top|color|flags|text   FBInk TrueType text (flags: c = centred in the box)
#   I|file|x|y                                  image (path relative to the extension folder)
#   R|x|y|w|h|color                             filled rectangle
#
# Layout units are pixels on a 758 x 1024 Paperwhite. Text positions are baselines;
# sizes are em sizes. Fonts: R text, S semibold, B bold/titles, D display.

function min(a, b) { return a < b ? a : b }
function max(a, b) { return a > b ? a : b }
function round(x) { return x < 0 ? -int(-x + 0.5) : int(x + 0.5) }
function ceil(x) { return x == int(x) ? x : (x > 0 ? int(x) + 1 : int(x)) }

# --- Text measurement -------------------------------------------------------------------

# Splits s into the characters that the font has (UTF-8 aware, drops unknown ones such as emoji).
# Sets CH[1..NCH] and the width CW[i] in font units.
function chars(f, s,   i, n, c, k) {
    NCH = 0; n = length(s); i = 1
    while (i <= n) {
        c = substr(s, i, 1)
        if ((f SUBSEP c) in W) { k = 1 }
        else if ((f SUBSEP substr(s, i, 2)) in W) { k = 2 }
        else if ((f SUBSEP substr(s, i, 3)) in W) { k = 3 }
        else { i++; continue }  # unknown byte: skip it
        NCH++; CH[NCH] = substr(s, i, k); CW[NCH] = W[f, CH[NCH]]
        i += k
    }
}

# Returns s cut with "…" so it is at most maxw px wide (maxw 0 = no limit). Sets TW (px).
function fit(f, px, s, maxw,   sc, i, tot, out, ell) {
    sc = px / (FA[f] - FD[f])
    chars(f, s)
    tot = 0
    for (i = 1; i <= NCH; i++) tot += CW[i]
    if (maxw <= 0 || tot * sc <= maxw) {
        out = ""; for (i = 1; i <= NCH; i++) out = out CH[i]
        TW = tot * sc
        return out
    }
    ell = W[f, "…"]
    while (NCH > 0 && (tot + ell) * sc > maxw) { tot -= CW[NCH]; NCH-- }
    while (NCH > 0 && CH[NCH] == " ") { tot -= CW[NCH]; NCH-- }
    out = ""; for (i = 1; i <= NCH; i++) out = out CH[i]
    TW = (tot + ell) * sc
    return out "…"
}

function pxof(f, em) { return round(em * (FA[f] - FD[f]) / FU[f]) }
function width(f, em, s) { fit(f, pxof(f, em), s, 0); return TW }

# Text with its baseline at y. al: l (x = left edge), r (x = right edge), c (x = centre).
function T(f, em, x, y, col, al, s, maxw,   px, top, left, right, half, flag) {
    px = pxof(f, em)
    s = fit(f, px, s, maxw)
    if (s == "") return
    top = y - ceil(px * FA[f] / (FA[f] - FD[f]))  # FBInk puts the baseline at top + ceil(scale * ascent)
    flag = ""; right = 0
    if (al == "r") left = round(x - TW)
    else if (al == "c") { half = min(x, SW - x); left = round(x - half); right = round(SW - x - half); flag = "c" }
    else left = round(x)
    print "T|" f "|" px "|" left "|" right "|" top "|" col "|" flag "|" s
}

# --- Shapes -----------------------------------------------------------------------------

function rect(x, y, w, h, col) { if (w > 0 && h > 0) print "R|" round(x) "|" round(y) "|" round(w) "|" round(h) "|" col }
function img(name, x, y) { print "I|icons/" name ".png|" round(x) "|" round(y) }
function icon(kind, isday, size, x, y,   dn) { dn = isday ? "d" : "n"; img(kind "-" dn "-" size, x, y) }

# Rounded box: two rectangles and four corner images (icons/corner-R-C-q.png, made by tools/build.py).
# col: FBInk colour name, cc: its code in the corner file names (e = GRAYE, d = GRAYD, 0 = BLACK).
function box(x, y, w, h, r, col, cc) {
    x = round(x); y = round(y); w = round(w); h = round(h)
    rect(x + r, y, w - 2 * r, h, col)
    rect(x, y + r, r, h - 2 * r, col)
    rect(x + w - r, y + r, r, h - 2 * r, col)
    img("corner-" r "-" cc "-tl", x, y);         img("corner-" r "-" cc "-tr", x + w - r, y)
    img("corner-" r "-" cc "-bl", x, y + h - r); img("corner-" r "-" cc "-br", x + w - r, y + h - r)
}

# Pill-shaped label with its text baseline at y. dark = black pill with white text.
function pill(x, y, s, dark,   w) {
    w = width("B", 20, s) + 24
    if (dark) box(x, y - 21, w, 28, 14, "BLACK", "0"); else box(x, y - 21, w, 28, 14, "GRAYD", "d")
    T("B", 20, x + 12, y, dark ? "WHITE" : "BLACK", "l", s, 0)
    return w
}

function title(x, y, s) { T("B", 21, x, y, "BLACK", "l", s, 0) }

# --- Formatting -------------------------------------------------------------------------

function deg(v,   n, s) { n = round(v + 0); s = n < 0 ? "−" : ""; if (n < 0) n = -n; return s n "°" }
function hm(t,   s) { s = fmod(t, 86400); return sprintf("%02d:%02d", int(s / 3600), int(s % 3600 / 60)) }
function iso(s) {  # "2026-11-12T16:00" or "2026-11-12" -> local wall epoch
    return dfc(substr(s, 1, 4) + 0, substr(s, 6, 2) + 0, substr(s, 9, 2) + 0) * 86400 + substr(s, 12, 2) * 3600 + substr(s, 15, 2) * 60
}
function wcode(c,   k) { k = c + 0; return (k in WI) ? k : -1 }
function dayname(z, short,   n) { n = DAYS[wday(z)]; return short ? substr(n, 1, lang == "de" ? 2 : 3) : n }
function num1(x,   s) { s = sprintf("%.1f", x); if (lang == "de") sub(/\./, ",", s); return s }
function isoweek(z,   th) {  # ISO 8601 week number of day z
    th = z - wday(z) + 3
    cfd(th)
    return int((th - dfc(CY, 1, 1)) / 7) + 1
}

function setup(   a, i, n, codes) {
    if (lang == "de") {
        split("Montag Dienstag Mittwoch Donnerstag Freitag Samstag Sonntag", DAYS0, " ")
        split("Januar Februar März April Mai Juni Juli August September Oktober November Dezember", MON, " ")
        split("N NO O SO S SW W NW", COMP, " ")
        X["max"] = "Max"; X["min"] = "Min"; X["feels"] = "gefühlt"; X["week"] = "KW"
        X["hours"] = "Nächste Stunden"; X["days"] = "Nächste Tage"; X["agenda"] = "Termine"
        X["today"] = "Heute"; X["tomorrow"] = "Morgen"; X["allday"] = "ganztägig"; X["now"] = "jetzt"
        X["noev"] = "Keine anstehenden Termine"; X["nocal"] = "Kalender in kindledash.conf eintragen"
        X["noweather"] = "Keine Wetterdaten"; X["wold"] = "Wetter von"; X["offline"] = "offline"
        X["calfail"] = "Kalender nicht erreichbar"; X["updated"] = "Aktualisiert"
    } else {
        split("Monday Tuesday Wednesday Thursday Friday Saturday Sunday", DAYS0, " ")
        split("January February March April May June July August September October November December", MON, " ")
        split("N NE E SE S SW W NW", COMP, " ")
        X["max"] = "High"; X["min"] = "Low"; X["feels"] = "feels"; X["week"] = "Week"
        X["hours"] = "Next hours"; X["days"] = "Next days"; X["agenda"] = "Agenda"
        X["today"] = "Today"; X["tomorrow"] = "Tomorrow"; X["allday"] = "all day"; X["now"] = "now"
        X["noev"] = "No upcoming events"; X["nocal"] = "Add a calendar in kindledash.conf"
        X["noweather"] = "No weather data"; X["wold"] = "Weather from"; X["offline"] = "offline"
        X["calfail"] = "calendar(s) unreachable"; X["updated"] = "Updated"
    }
    for (i = 1; i <= 7; i++) DAYS[i - 1] = DAYS0[i]
    # WMO weather code | icon | English | German
    n = split("0|clear|Clear sky|Klar;1|partly|Mainly clear|Überwiegend klar;2|partly|Partly cloudy|Teilweise bewölkt;" \
        "3|cloudy|Overcast|Bedeckt;45|fog|Fog|Nebel;48|fog|Rime fog|Reifnebel;51|drizzle|Light drizzle|Leichter Niesel;" \
        "53|drizzle|Drizzle|Nieselregen;55|drizzle|Heavy drizzle|Starker Niesel;56|drizzle|Freezing drizzle|Gefrierender Niesel;" \
        "57|drizzle|Freezing drizzle|Gefrierender Niesel;61|rain|Light rain|Leichter Regen;63|rain|Rain|Regen;" \
        "65|rain|Heavy rain|Starker Regen;66|rain|Freezing rain|Gefrierender Regen;67|rain|Freezing rain|Gefrierender Regen;" \
        "71|snow|Light snow|Leichter Schneefall;73|snow|Snow|Schneefall;75|snow|Heavy snow|Starker Schneefall;" \
        "77|snow|Snow grains|Schneegriesel;80|rain|Light showers|Leichte Schauer;81|rain|Showers|Schauer;" \
        "82|rain|Heavy showers|Starke Schauer;85|snow|Snow showers|Schneeschauer;86|snow|Snow showers|Schneeschauer;" \
        "95|storm|Thunderstorm|Gewitter;96|storm|Thunderstorm, hail|Gewitter mit Hagel;99|storm|Thunderstorm, hail|Gewitter mit Hagel;" \
        "-1|cloudy|Unknown|Unbekannt", codes, ";")
    for (i = 1; i <= n; i++) {
        split(codes[i], a, "|")
        WI[a[1] + 0] = a[2]; WT[a[1] + 0] = lang == "de" ? a[4] : a[3]
    }
}

# --- Input ------------------------------------------------------------------------------

BEGIN {
    SW = 758; SH = 1024; ML = 32; MR = SW - 32
    now += 0
    setup()
}

# weather.csv: meta, current, hourly, daily sections separated by blank lines. Columns are
# found by their header names (the part before " (unit)"). (Not "FNR == NR": the file can be empty.)
FILENAME == ARGV[1] {
    if ($0 == "") { sec++; hdr = 1; next }
    n = split($0, a, ",")
    if (hdr) {
        for (i = 1; i <= n; i++) { h = a[i]; sub(/ .*/, "", h); COL[sec, h] = i }
        hdr = 0; next
    }
    if (sec == 1) { for (k in COL) { split(k, kk, SUBSEP); if (kk[1] == 1) CUR[kk[2]] = a[COL[k]] } ; HAVEW = 1 }
    else if (sec == 2) {
        NH++; HT[NH] = iso(a[COL[2, "time"]]); HTE[NH] = a[COL[2, "temperature_2m"]]
        HC[NH] = a[COL[2, "weather_code"]]; HP[NH] = a[COL[2, "precipitation_probability"]]; HD[NH] = a[COL[2, "is_day"]]
    }
    else if (sec == 3) {
        ND++; DT[ND] = iso(a[COL[3, "time"]]); DC[ND] = a[COL[3, "weather_code"]]
        DMX[ND] = a[COL[3, "temperature_2m_max"]]; DMN[ND] = a[COL[3, "temperature_2m_min"]]
        DPP[ND] = a[COL[3, "precipitation_probability_max"]]; DPS[ND] = a[COL[3, "precipitation_sum"]]
        DSR[ND] = a[COL[3, "sunrise"]]; DSS[ND] = a[COL[3, "sunset"]]
    }
    next
}
# events.txt: day|order|start|end|title, sorted
{ NE++; EVL[NE] = $0 }

# --- Drawing ----------------------------------------------------------------------------

END {
    today = fdiv(now, 86400)
    cfd(today)

    # Header: weekday and date on the left, place and week number on the right. No clock:
    # the screen changes only every 15 minutes.
    T("D", 54, ML, 70, "BLACK", "l", dayname(today, 0), 0)
    if (lang == "de") d = CD ". " MON[CM] " " CY; else d = CD " " MON[CM] " " CY
    T("R", 25, ML, 106, "GRAY5", "l", d, 0)
    T("B", 26, MR, 58, "BLACK", "r", place, 0)
    T("R", 22, MR, 96, "GRAY5", "r", X["week"] " " isoweek(today), 0)

    if (!HAVEW) T("B", 30, SW / 2, 400, "BLACK", "c", X["noweather"], 0)
    else { current(); hourly(); daily() }
    agenda()
    footer()
}

function current(   c, tx, col, sz, ti, s, i, y, prob) {
    box(ML - 8, 124, MR - ML + 16, 236, 18, "GRAYE", "e")
    c = wcode(CUR["weather_code"])
    icon(WI[c], CUR["is_day"] == 1, 170, ML, 140)

    ti = 0
    for (i = 1; i <= ND; i++) if (fdiv(DT[i], 86400) == today) ti = i

    tx = ML + 186; col = 532
    sz = 112
    while (sz > 60 && width("D", sz, deg(CUR["temperature_2m"])) > col - tx - 12) sz -= 4
    T("D", sz, tx, 250, "BLACK", "l", deg(CUR["temperature_2m"]), 0)
    T("B", 29, tx + 3, 294, "BLACK", "l", WT[c], col - tx - 8)
    s = X["feels"] " " deg(CUR["apparent_temperature"])
    if (ti) s = X["max"] " " deg(DMX[ti]) " · " X["min"] " " deg(DMN[ti]) " · " s
    T("R", 21, tx + 3, 330, "GRAY5", "l", s, col - tx - 8)

    # Details with small icons: precipitation, humidity, wind, sunrise, sunset
    n = 0
    if (ti) {
        prob = DPP[ti] != "" ? DPP[ti] "%" : "–"
        if (DPS[ti] + 0 > 0) prob = prob " · " num1(DPS[ti]) " mm"
        n++; DI[n] = "umbrella"; DV[n] = prob
    }
    n++; DI[n] = "humidity"; DV[n] = CUR["relative_humidity_2m"] "%"
    n++; DI[n] = "wind"; DV[n] = round(CUR["wind_speed_10m"]) " km/h " COMP[fmod(round(CUR["wind_direction_10m"] / 45), 8) + 1]
    if (ti) {
        n++; DI[n] = "sunrise"; DV[n] = hm(iso(DSR[ti]))
        n++; DI[n] = "sunset"; DV[n] = hm(iso(DSS[ti]))
    }
    for (i = 1; i <= n; i++) {
        y = 170 + (i - 1) * 42
        img("mini-" DI[i] "-30", col, y - 24)
        T("S", 22, col + 40, y, "BLACK", "l", DV[i], MR - col - 40)
    }
}

function hourly(   h0, i, k, j, cw, cx, c) {
    title(ML, 404, X["hours"])
    h0 = 0
    for (i = 1; i <= NH; i++) if (HT[i] >= now - fmod(now, 3600)) { h0 = i; break }
    if (!h0) return
    cw = (MR - ML) / 8
    for (k = 0; k < 8; k++) {
        j = h0 + 1 + k * 3
        if (j > NH) break
        cx = ML + cw * (k + 0.5)
        c = wcode(HC[j])
        T("R", 19, cx, 438, "GRAY5", "c", hm(HT[j]), 0)
        icon(WI[c], HD[j] == 1, 56, cx - 28, 448)
        T("B", 27, cx, 532, "BLACK", "c", deg(HTE[j]), 0)
        if (HP[j] + 0 >= 10) precip(cx, 558, HP[j])
    }
}

# Small drop and "40%", centred at cx with the baseline at y.
function precip(cx, y, p,   s, w) {
    s = p "%"; w = width("R", 17, s) + 18
    img("mini-drop-16", cx - w / 2, y - 14)
    T("R", 17, cx - w / 2 + 18, y, "GRAY5", "l", s, 0)
}

function daily(   i, k, j, cw, cx, c, hi, lo, wh, wl, x0, lo_all, hi_all, bw, bx, a, b) {
    title(ML, 600, X["days"])
    j = 0
    for (i = 1; i <= ND; i++) if (fdiv(DT[i], 86400) == today) j = i
    # Common scale for the range bars: the lowest and highest temperature of the shown days.
    lo_all = 999; hi_all = -999
    for (k = 1; k <= 6 && j + k <= ND; k++) { lo_all = min(lo_all, DMN[j + k] + 0); hi_all = max(hi_all, DMX[j + k] + 0) }
    if (hi_all - lo_all < 1) hi_all = lo_all + 1
    cw = (MR - ML) / 6; bw = 76
    for (k = 0; k < 6; k++) {
        i = j + 1 + k
        if (i > ND) break
        cx = ML + cw * (k + 0.5)
        c = wcode(DC[i])
        T("B", 23, cx, 634, "BLACK", "c", dayname(fdiv(DT[i], 86400), 1), 0)
        icon(WI[c], 1, 56, cx - 28, 644)
        hi = deg(DMX[i]); lo = deg(DMN[i])
        wh = width("B", 24, hi); wl = width("R", 24, lo)
        x0 = cx - (wh + 10 + wl) / 2
        T("B", 24, x0, 726, "BLACK", "l", hi, 0)
        T("R", 24, x0 + wh + 10, 726, "GRAY5", "l", lo, 0)
        # Range bar: grey track, black part from the day's low to its high
        bx = cx - bw / 2
        rect(bx, 738, bw, 6, "GRAYD")
        a = bx + bw * (DMN[i] - lo_all) / (hi_all - lo_all)
        b = bx + bw * (DMX[i] - lo_all) / (hi_all - lo_all)
        rect(a, 737, max(b - a, 6), 8, "BLACK")
        if (DPP[i] + 0 >= 10) precip(cx, 770, DPP[i])
    }
}

function agenda(   y, i, a, day, last, tag, when) {
    title(ML, 810, X["agenda"])
    if (!ncal) { T("R", 22, ML, 848, "GRAY5", "l", X["nocal"], 0); return }
    y = 848; last = ""
    for (i = 1; i <= NE; i++) {
        split(EVL[i], a, "|")
        if (a[4] + 0 <= now) continue
        if (y > 988) break
        day = max(a[1] + 0, today)
        if (day != last) {
            if (day == today) tag = X["today"]
            else if (day == today + 1) tag = X["tomorrow"]
            else { cfd(day); tag = dayname(day, 1) " " CD "." }
            pill(ML, y, tag, day == today)
            last = day
        }
        if (a[2] == 0) when = X["allday"]
        else if (a[3] + 0 <= now) when = X["now"]
        else when = hm(a[3])
        T("R", 21, ML + 128, y, "GRAY5", "l", when, 100)
        T("S", 23, ML + 236, y, "BLACK", "l", a[5], MR - ML - 236)
        y += 35
    }
    if (y == 848) T("R", 22, ML, 848, "GRAY5", "l", X["noev"], 0)
}

function footer(   s, bx) {
    s = X["updated"] " " hm(now)
    if (wtime == "" || now - wtime > 3600) s = HAVEW ? X["wold"] " " hm(wtime) " (" X["offline"] ")" : X["noweather"]
    if (calfail + 0 > 0) s = s " · " calfail " " X["calfail"]
    T("R", 16, ML, 1014, "GRAY5", "l", s, 520)
    if (batt != "") {
        T("R", 16, MR, 1014, "GRAY5", "r", batt "%", 0)
        bx = MR - TW - 34
        rect(bx, 1002, 24, 13, "GRAY5"); rect(bx + 2, 1004, 20, 9, "WHITE")
        rect(bx + 24, 1006, 2, 5, "GRAY5")
        if (batt + 0 > 0) rect(bx + 3, 1005, 18 * min(batt, 100) / 100, 7, "GRAY5")
    }
}
