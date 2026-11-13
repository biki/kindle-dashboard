# Decodes the payload of a Tibber Pulse Bridge (http://<bridge>/node_data.json?node_id=1) into the
# meter total and the power. Written for busybox awk: no gawk functions, no "name (expr)".
#
# The bridge does not send JSON. It sends the raw meter data: SML frames from German meters,
# or plaintext OBIS lines from some other meters.
#
#   mode=sml   input = the payload as hex bytes (od -An -v -t x1)
#   mode=text  input = the payload as text, lines such as 1-0:1.8.0*255(012345.6789*kWh)
#
# Output: total_kwh|power_w   (power_w empty when the meter does not send 16.7.0)
#         no output           (1.8.0 not found)
#
#   1.8.0   energy imported, the meter counter (SML: Wh with a scaler; written here as kWh)
#   16.7.0  power now, all phases (W; negative = export)
#
# SML: finds the list entries 77 07 01 00 01 08 00 ff and 77 07 01 00 10 07 00 ff, then reads
# status, valTime, unit, scaler and value with the SML type-length fields. There is no CRC check
# here: tibber.sh reads the meter twice before it writes a daily row.

BEGIN { for (i = 0; i < 256; i++) HX[sprintf("%02x", i)] = i }

mode == "sml" { for (i = 1; i <= NF; i++) B[++N] = HX[tolower($i)] + 0 }
mode == "text" { plain($0) }

# Type-length field at p. Sets TY (0 octets, 4 bool, 5 int, 6 uint, 7 list), LN (length with the
# type-length bytes; for a list, the number of elements) and HL (number of type-length bytes).
function tl(p,   b) {
    b = B[p]; TY = int(b / 16) % 8; LN = b % 16; HL = 1
    while (b >= 128 && p + HL <= N) { b = B[p + HL]; LN = LN * 16 + b % 16; HL++ }
}

# Element at p. Sets ET (type), EN (data bytes) and EV (the number, for int and uint).
# Returns the position after the element (more than N = past the end).
function elem(p, depth,   t, l, h, i, n, v) {
    if (p > N || depth > 8) return N + 1
    tl(p); t = TY; l = LN; h = HL
    if (t == 7) {
        p += h
        for (i = 0; i < l && p <= N; i++) p = elem(p, depth + 1)
        ET = 7; EN = 0; EV = 0
        return p
    }
    if (l < h) l = h  # 00 (end of message) or a broken length: move on by the field itself
    n = l - h; v = 0
    for (i = 0; i < n; i++) v = v * 256 + B[p + h + i]
    if (t == 5 && n > 0 && B[p + h] >= 128) v -= 256 ^ n
    ET = t; EN = n; EV = v
    return p + l
}

# List entry whose objName starts at q (the 07 byte). Sets VAL (value x 10^scaler). 1 = valid.
function entry(q,   p, sc) {
    p = elem(q, 0)   # objName
    p = elem(p, 0)   # status
    p = elem(p, 0)   # valTime
    p = elem(p, 0)   # unit
    p = elem(p, 0); sc = (ET == 5 && EN > 0) ? EV : 0
    p = elem(p, 0)
    if ((ET != 5 && ET != 6) || EN == 0 || p > N + 1) return 0
    VAL = EV * 10 ^ sc
    return 1
}

# Plaintext OBIS: "1-0:1.8.0*255(012345.6789*kWh)". 1.8.0 in kWh or Wh, 16.7.0 in W or kW.
function plain(s,   m, obis, v, u) {
    while (match(s, /[0-9]+\.[0-9]+\.[0-9]+(\*[0-9]+)?\(-?[0-9.]+ *\*? *[A-Za-z]*\)/)) {
        m = substr(s, RSTART, RLENGTH); s = substr(s, RSTART + RLENGTH)
        obis = m; sub(/[*(].*/, "", obis)
        v = m; sub(/^[^(]*\(/, "", v)
        u = v; gsub(/[^A-Za-z]/, "", u); u = tolower(u)
        sub(/[ *A-Za-z)].*/, "", v)
        if (obis == "1.8.0") { TOT = u == "kwh" ? v + 0 : v / 1000; HT = 1 }
        else if (obis == "16.7.0") { PW = u == "kw" ? v * 1000 : v + 0; HP = 1 }
    }
}

END {
    if (mode == "sml") {
        for (i = 2; i + 6 <= N; i++) {
            if (B[i - 1] != 119 || B[i] != 7 || B[i + 1] != 1 || B[i + 2] != 0 || B[i + 6] != 255) continue
            if (B[i + 3] == 1 && B[i + 4] == 8 && B[i + 5] == 0) { if (entry(i)) { TOT = VAL / 1000; HT = 1 } }
            else if (B[i + 3] == 16 && B[i + 4] == 7 && B[i + 5] == 0) { if (entry(i)) { PW = VAL; HP = 1 } }
        }
    }
    if (HT) print sprintf("%.4f", TOT) "|" (HP ? sprintf("%.0f", PW) : "")
}
