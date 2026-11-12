# Expands the VEVENTs of ICS calendars into the occurrences inside a time window.
# Written for busybox awk (Kindle): no gawk functions, no "name (expr)" concatenation.
#
# Input:  one or more .ics files.
# Vars:   from, to  window in local wall-clock epoch seconds (local time written as if it were UTC)
#         off       current local UTC offset in seconds (for UTC "Z" times and foreign time zones)
#         ltz       local IANA time zone name (e.g. Europe/Berlin). Times with this TZID are kept as they are.
# Output: day|order|start|end|title   (day = local day number, order 0 = all-day, 1 = timed)
#
# Limits: RRULE BYSETPOS, BYWEEKNO, BYYEARDAY, HOURLY and finer are not supported (such rules
# give only their first occurrence). A time zone without a VTIMEZONE block counts as local time.

# fmod, fdiv, dfc, cfd, wday and dim come from common.awk.

# z of the n-th weekday wd (0 = MO) in a month; n < 0 counts from the end. -1e9 if none.
function nth(y, m, n, wd,   z, last) {
    if (n > 0) {
        z = dfc(y, m, 1)
        z += fmod(wd - wday(z), 7) + (n - 1) * 7
        return z <= dfc(y, m, dim(y, m)) ? z : -1e9
    }
    last = dfc(y, m, dim(y, m))
    z = last - fmod(wday(last) - wd, 7) + (n + 1) * 7
    return z >= dfc(y, m, 1) ? z : -1e9
}

# "20261112", "20261112T093000" or "20261112T093000Z" -> wall epoch. Sets PDATE and PZ.
function pdt(v,   t) {
    PZ = substr(v, length(v)) == "Z"
    PDATE = length(v) == 8
    t = dfc(substr(v, 1, 4) + 0, substr(v, 5, 2) + 0, substr(v, 7, 2) + 0) * 86400
    if (!PDATE) t += substr(v, 10, 2) * 3600 + substr(v, 12, 2) * 60 + substr(v, 14, 2)
    return t
}

# "+0100" / "-0530" -> seconds
function poff(v,   s) {
    s = (substr(v, 2, 2) * 3600 + substr(v, 4, 2) * 60)
    return substr(v, 1, 1) == "-" ? -s : s
}

# ISO 8601 duration ("PT1H30M", "P1D", "-P1W") -> seconds
function pdur(v,   s, n, c, i, sign) {
    sign = 1
    if (substr(v, 1, 1) == "-") { sign = -1; v = substr(v, 2) }
    s = 0; n = 0
    for (i = 1; i <= length(v); i++) {
        c = substr(v, i, 1)
        if (c ~ /[0-9]/) n = n * 10 + c
        else if (c == "W") { s += n * 604800; n = 0 }
        else if (c == "D") { s += n * 86400; n = 0 }
        else if (c == "H") { s += n * 3600; n = 0 }
        else if (c == "M") { s += n * 60; n = 0 }
        else if (c == "S") { s += n; n = 0 }
    }
    return sign * s
}

# Splits a content line into PN (name), PP (";PARAM=V;...;", upper case) and PV (value).
function prop(line,   i, c, q, head) {
    if (index(line, "\"") == 0) i = index(line, ":")
    else {
        q = 0
        for (i = 1; i <= length(line); i++) {
            c = substr(line, i, 1)
            if (c == "\"") q = !q
            else if (c == ":" && !q) break
        }
    }
    head = substr(line, 1, i - 1)
    PV = substr(line, i + 1)
    i = index(head, ";")
    if (i) { PN = toupper(substr(head, 1, i - 1)); PP = ";" toupper(substr(head, i + 1)) ";" }
    else { PN = toupper(head); PP = "" }
}
function param(name,   i, s) {
    i = index(PP, ";" name "=")
    if (!i) return ""
    s = substr(PP, i + length(name) + 2)
    i = index(s, ";")
    if (i) s = substr(s, 1, i - 1)
    gsub(/"/, "", s)
    return s
}

# --- Time zones -------------------------------------------------------------------------

# Wall time in a DST rule: yearly, month m, BYDAY like "-1SU" at time of day tod.
function ruletime(y, m, bd, tod,   n, wd) {
    wd = WD[substr(bd, length(bd) - 1)]
    n = substr(bd, 1, length(bd) - 2)
    n = (n == "" || n == "+") ? 1 : n + 0
    return nth(y, m, n, wd) * 86400 + tod
}
# UTC offset in seconds of zone tz at wall time t, or "L" (= treat as local time).
function tzoff(tz, t,   y, a, b) {
    if (tz == "" || tz == LTZ || !(tz in TZS)) return "L"
    if (!(tz in TZD) || TZDM[tz] == "" || TZSM[tz] == "") return TZS[tz]
    cfd(fdiv(t, 86400)); y = CY
    a = ruletime(y, TZDM[tz], TZDB[tz], TZDT[tz])
    b = ruletime(y, TZSM[tz], TZSB[tz], TZST[tz])
    if (a < b) return (t >= a && t < b) ? TZD[tz] : TZS[tz]
    return (t >= a || t < b) ? TZD[tz] : TZS[tz]
}
function tolocal(t, tz, z,   o) {
    if (z) return t + OFF
    o = tzoff(tz, t)
    return o == "L" ? t : t - o + OFF
}
function endtz(kind,   m, bd, n, a, i, t) {
    if (tzid == "" || sub_start < TZBEST[tzid, kind]) return  # keep the newest rule only
    TZBEST[tzid, kind] = sub_start
    m = ""; bd = ""
    n = split(toupper(sub_rule), a, ";")
    for (i = 1; i <= n; i++) {
        if (a[i] ~ /^BYMONTH=/) m = substr(a[i], 9) + 0
        else if (a[i] ~ /^BYDAY=/) bd = substr(a[i], 7)
    }
    t = pdt(sub_start); t = fmod(t, 86400)
    if (kind == "STANDARD") { TZS[tzid] = poff(sub_off); TZSM[tzid] = m; TZSB[tzid] = bd; TZST[tzid] = t }
    else { TZD[tzid] = poff(sub_off); TZDM[tzid] = m; TZDB[tzid] = bd; TZDT[tzid] = t }
}

# --- Parsing ----------------------------------------------------------------------------

function handle(line,   blk, top, a, n, i, tz) {
    prop(line)
    if (PN == "BEGIN") {
        blk = toupper(PV); STK[++depth] = blk
        if (blk == "VEVENT") { e_uid = e_sum = e_s = e_stz = e_e = e_etz = e_dur = e_rr = e_ex = e_rid = e_rtz = e_st = "" }
        else if (blk == "VTIMEZONE") tzid = ""
        else if (blk == "STANDARD" || blk == "DAYLIGHT") { sub_off = sub_rule = sub_start = "" }
        return
    }
    if (PN == "END") {
        blk = toupper(PV)
        if (blk == "VEVENT") {
            N++
            U[N] = e_uid; SUM[N] = e_sum; S[N] = e_s; STZ[N] = e_stz; E[N] = e_e; ETZ[N] = e_etz
            DUR[N] = e_dur; RR[N] = e_rr; EX[N] = e_ex; RID[N] = e_rid; RTZ[N] = e_rtz; ST[N] = e_st
        } else if (blk == "STANDARD" || blk == "DAYLIGHT") endtz(blk)
        depth--
        return
    }
    top = STK[depth]
    if (top == "VEVENT") {
        if (PN == "UID") e_uid = PV
        else if (PN == "SUMMARY") e_sum = PV
        else if (PN == "DTSTART") { e_s = PV; e_stz = param("TZID") }
        else if (PN == "DTEND") { e_e = PV; e_etz = param("TZID") }
        else if (PN == "DURATION") e_dur = PV
        else if (PN == "RRULE") e_rr = toupper(PV)
        else if (PN == "EXDATE") {
            tz = param("TZID"); n = split(PV, a, ",")
            for (i = 1; i <= n; i++) e_ex = e_ex " " a[i] "@" tz
        }
        else if (PN == "RECURRENCE-ID") { e_rid = PV; e_rtz = param("TZID") }
        else if (PN == "STATUS") e_st = toupper(PV)
    }
    else if (top == "VTIMEZONE" && PN == "TZID") tzid = toupper(PV)
    else if (top == "STANDARD" || top == "DAYLIGHT") {
        if (PN == "TZOFFSETTO") sub_off = PV
        else if (PN == "RRULE") sub_rule = PV
        else if (PN == "DTSTART") sub_start = PV
    }
}

# --- Expansion --------------------------------------------------------------------------

function title(s) {
    gsub(/\\[nN]/, " ", s); gsub(/\\,/, ",", s); gsub(/\\;/, ";", s); gsub(/\\\\/, "\\", s)
    gsub(/\|/, "/", s); gsub(/[ \t]+/, " ", s); sub(/^ /, "", s); sub(/ $/, "", s)
    return s == "" ? "-" : s
}

# One occurrence starting at wall time t (in the event's zone). Checks EXDATE and overrides.
function occ(i, t,   ls, le, ord) {
    if (ISDATE) { ls = t; le = t + LEN }
    else { ls = tolocal(t, STZ[i], ISZ); le = tolocal(t + LEN, STZ[i], ISZ) }
    if ((i SUBSEP ls) in XD) return
    if ((U[i] "|" ls) in OVR) return
    if (le <= from || ls >= to) return
    if (le == ls && !ISDATE) le = ls + 1  # zero-length event: still show it
    ord = ISDATE ? 0 : 1
    print fdiv(ls, 86400) "|" ord "|" ls "|" le "|" TITLE
}

# Calls occ() for every candidate day z (ascending). Returns 0 when expansion must stop.
function cand(i, z,   t) {
    if (z < D0) return 1
    CNT++
    if (CNT_MAX && CNT > CNT_MAX) return 0
    t = z * 86400 + TOD
    if (UNTIL != "" && t > UNTIL) return 0
    if (z > WTO) return 0
    if (z >= WFROM) occ(i, t)
    return 1
}

# Collects candidate days of month (y, m) into C[1..NC], sorted.
function monthdays(y, m, bd, bmd,   a, n, j, k, x, wd, s, z, last) {
    NC = 0; last = dim(y, m)
    if (bmd != "") {
        n = split(bmd, a, ",")
        for (j = 1; j <= n; j++) { x = a[j] + 0; if (x < 0) x = last + 1 + x; if (x >= 1 && x <= last) C[++NC] = dfc(y, m, x) }
    } else if (bd != "") {
        n = split(bd, a, ",")
        for (j = 1; j <= n; j++) {
            wd = WD[substr(a[j], length(a[j]) - 1)]
            s = substr(a[j], 1, length(a[j]) - 2)
            if (s == "" || s == "+") {  # every such weekday of the month
                for (z = nth(y, m, 1, wd); z <= dfc(y, m, last); z += 7) C[++NC] = z
            } else { z = nth(y, m, s + 0, wd); if (z > -1e9) C[++NC] = z }
        }
    } else if (CDAY <= last) C[++NC] = dfc(y, m, CDAY)
    for (j = 2; j <= NC; j++) { x = C[j]; for (k = j - 1; k >= 1 && C[k] > x; k--) C[k + 1] = C[k]; C[k + 1] = x }
}

function expand(i,   a, n, j, f, iv, bd, bmd, bm, wds, w, z, k, y, m, mi, guard, ws, months, mm) {
    f = ""; iv = 1; bd = ""; bmd = ""; bm = ""; CNT_MAX = 0; UNTIL = ""
    n = split(RR[i], a, ";")
    for (j = 1; j <= n; j++) {
        if (a[j] ~ /^FREQ=/) f = substr(a[j], 6)
        else if (a[j] ~ /^INTERVAL=/) iv = substr(a[j], 10) + 0
        else if (a[j] ~ /^COUNT=/) CNT_MAX = substr(a[j], 7) + 0
        else if (a[j] ~ /^UNTIL=/) {
            UNTIL = pdt(substr(a[j], 7))
            if (PDATE) UNTIL += 86399
            else if (PZ) UNTIL += tzoff(STZ[i], UNTIL) == "L" ? OFF : tzoff(STZ[i], UNTIL)  # UTC -> event wall time
        }
        else if (a[j] ~ /^BYDAY=/) bd = substr(a[j], 7)
        else if (a[j] ~ /^BYMONTHDAY=/) bmd = substr(a[j], 12)
        else if (a[j] ~ /^BYMONTH=/) bm = substr(a[j], 9)
    }
    if (iv < 1) iv = 1
    CNT = 0; cfd(D0); CDAY = CD; y = CY; m = CM

    if (f == "DAILY") {
        z = D0
        if (!CNT_MAX && WFROM > D0) z = D0 + int((WFROM - D0) / iv) * iv
        for (guard = 0; guard < 4000; guard++) {
            if (bd == "" || index(bd, WDS[wday(z)])) { if (!cand(i, z)) return }
            else if (z > WTO) return
            z += iv
        }
    } else if (f == "WEEKLY") {
        if (bd == "") bd = WDS[wday(D0)]
        ws = D0 - wday(D0)
        k = 0
        if (!CNT_MAX && WFROM > ws) k = int((WFROM - ws) / (7 * iv)) * iv
        for (guard = 0; guard < 2000; guard++) {
            for (w = 0; w < 7; w++)
                if (index(bd, WDS[w])) { if (!cand(i, ws + k * 7 + w)) return }
            k += iv
        }
    } else if (f == "MONTHLY") {
        mi = y * 12 + m - 1
        for (guard = 0; guard < 1200; guard++) {
            monthdays(int(mi / 12), mi % 12 + 1, bd, bmd)
            for (j = 1; j <= NC; j++) if (!cand(i, C[j])) return
            if (dfc(int(mi / 12), mi % 12 + 1, 1) > WTO) return
            mi += iv
        }
    } else if (f == "YEARLY") {
        months = bm != "" ? bm : m
        n = split(months, mm, ",")
        for (guard = 0; guard < 200; guard++) {
            for (j = 1; j <= n; j++) {
                monthdays(y, mm[j] + 0, bd, bmd)
                for (k = 1; k <= NC; k++) if (!cand(i, C[k])) return
            }
            if (dfc(y, 1, 1) > WTO) return
            y += iv
        }
    } else cand(i, D0)
}

BEGIN {
    split("MO TU WE TH FR SA SU", a, " ")
    for (i = 1; i <= 7; i++) { WD[a[i]] = i - 1; WDS[i - 1] = a[i] }
    OFF = off + 0; LTZ = toupper(ltz); from += 0; to += 0
}

{
    sub(/\r$/, "")
    c = substr($0, 1, 1)
    if (c == " " || c == "\t") { cur = cur substr($0, 2); next }
    if (have) handle(cur)
    cur = $0; have = 1
}

END {
    if (have) handle(cur)
    # Overrides (RECURRENCE-ID) and EXDATEs, as local wall times.
    for (i = 1; i <= N; i++) {
        if (RID[i] != "") {
            t = pdt(RID[i])
            if (!PDATE) t = tolocal(t, RTZ[i] != "" ? RTZ[i] : STZ[i], PZ)
            OVR[U[i] "|" t] = 1
        }
        if (EX[i] != "") {
            n = split(substr(EX[i], 2), xa, " ")
            for (j = 1; j <= n; j++) {
                k = index(xa[j], "@"); t = pdt(substr(xa[j], 1, k - 1))
                XD[i, PDATE ? t : tolocal(t, substr(xa[j], k + 1), PZ)] = 1
            }
        }
    }
    for (i = 1; i <= N; i++) {
        if (S[i] == "" || ST[i] == "CANCELLED") continue
        t = pdt(S[i]); ISDATE = PDATE; ISZ = PZ
        if (E[i] != "") LEN = pdt(E[i]) - t
        else if (DUR[i] != "") LEN = pdur(DUR[i])
        else LEN = ISDATE ? 86400 : 0
        if (LEN < 0) LEN = 0
        TITLE = title(SUM[i])
        if (RID[i] != "" || RR[i] == "") {
            # Single event, or a moved occurrence: emit as is (no EXDATE/override check against itself).
            saveU = U[i]; U[i] = "\001"; occ(i, t); U[i] = saveU
            continue
        }
        D0 = fdiv(t, 86400); TOD = t - D0 * 86400
        WFROM = fdiv(from - LEN, 86400) - 1; WTO = fdiv(to, 86400) + 1
        expand(i)
    }
}
