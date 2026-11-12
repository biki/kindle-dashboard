# Date helpers shared by ical.awk and render.awk (the Kindle concatenates the files).
# Day numbers count from 1970-01-01. Written for busybox awk.

function fmod(a, b) { return (a % b + b) % b }
function fdiv(a, b) { return (a - fmod(a, b)) / b }

# Days since 1970-01-01 for a civil date (proleptic Gregorian), and back (sets CY CM CD).
function dfc(y, m, d,   era, yoe, doy, mm) {
    if (m <= 2) y--
    era = fdiv(y, 400)
    yoe = y - era * 400
    mm = m > 2 ? m - 3 : m + 9
    doy = int((153 * mm + 2) / 5) + d - 1
    return era * 146097 + yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy - 719468
}
function cfd(z,   era, doe, yoe, doy, mp) {
    z += 719468
    era = fdiv(z, 146097)
    doe = z - era * 146097
    yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
    doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
    mp = int((5 * doy + 2) / 153)
    CD = doy - int((153 * mp + 2) / 5) + 1
    CM = mp < 10 ? mp + 3 : mp - 9
    CY = yoe + era * 400
    if (CM <= 2) CY++
}
function wday(z) { return fmod(z + 3, 7) }  # 0 = Monday
function dim(y, m) { return m == 12 ? 31 : dfc(y, m + 1, 1) - dfc(y, m, 1) }
