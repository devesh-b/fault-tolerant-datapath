#!/usr/bin/env python3
"""Protection scheme for the multi-precision MAC, and the algebra behind it.

Two layers, because detection and correction are different jobs:

  residue mod 3   concurrent DETECTION across the whole multiply-accumulate
  Hamming SEC-DED CORRECTION of the accumulator file

This file proves the residue algebra before any RTL exists, the same way
model/mpmac.py did for the datapath itself. Two things make the algebra less
obvious than "residues are homomorphic":

1. SIGNEDNESS. A W-bit pattern u representing a two's complement value v has
   v = u - s*2^W where s is the sign bit. For even W, 2^W = 1 (mod 3), so
        v = u - s   (mod 3)
   A one-bit correction, not a re-computation.

2. ACCUMULATOR WRAP. acc_next = (acc + p) mod 2^W discards a carry worth
   2^W = 1 (mod 3), so
        acc_next = acc + p - k  (mod 3),  k = the discarded carry
   Ignoring k makes the checker fire on every wrap. The RTL therefore feeds
   the real carry-out into the check rather than pretending it cannot happen.

Residues themselves are cheap: 4 = 1 (mod 3), so the residue of a binary
number is the sum of its 2-bit groups, mod 3 - a small adder tree, no division.
"""

import random
from mpmac_core import M16, M8, M4, LANES, LANE_W, DIGS_PER_LANE, DIG_W, products

MOD = 3


def res_pattern(u, w):
    """Residue mod 3 of a w-bit pattern, the way hardware does it:
    sum the 2-bit groups (4^k = 1 mod 3)."""
    assert w % 2 == 0
    return sum((u >> (2 * i)) & 3 for i in range(w // 2)) % MOD


def res_value(u, w, signed):
    """Residue mod 3 of the VALUE a w-bit pattern represents."""
    s = (u >> (w - 1)) & 1 if signed else 0
    return (res_pattern(u, w) - s) % MOD          # 2^w = 1 (mod 3), w even


def lane_operand(x, mode, L):
    w = DIG_W * DIGS_PER_LANE[mode]
    return (x >> (w * L)) & ((1 << w) - 1), w


def expected_residue(a, b, acc, mode, sgn, L, carry):
    """What the accumulator lane's residue must be after this cycle."""
    w = LANE_W[mode]
    av, ow = lane_operand(a, mode, L)
    bv, _ = lane_operand(b, mode, L)
    ra = res_value(av, ow, sgn)
    rb = res_value(bv, ow, sgn)
    racc = res_pattern((acc >> (w * L)) & ((1 << w) - 1), w)
    # acc_next = acc + a*b - carry*2^w, and 2^w = 1 (mod 3)
    return (racc + ra * rb - carry) % MOD


def step_lane(acc_lane, prod, w):
    """Lane accumulate, returning the wrapped result and the discarded carry."""
    s = acc_lane + prod
    return s & ((1 << w) - 1), (s >> w) & 1 if s >= 0 else -((-s) >> w != 0)


# ----------------------------------------------------------------- SEC-DED

def hamming_encode(data, k=48):
    """SEC-DED over k data bits: Hamming check bits plus one overall parity.
    Returns (check_bits, overall_parity)."""
    r = 1
    while (1 << r) < k + r + 1:
        r += 1
    # position i (1-based) is a check position iff it is a power of two
    bits = {}
    di = 0
    for pos in range(1, k + r + 1):
        if pos & (pos - 1):
            bits[pos] = (data >> di) & 1
            di += 1
    chk = 0
    for c in range(r):
        p = 1 << c
        v = 0
        for pos, bit in bits.items():
            if pos & p:
                v ^= bit
        chk |= v << c
    overall = 0
    for bit in bits.values():
        overall ^= bit
    for c in range(r):
        overall ^= (chk >> c) & 1
    return chk, overall, r


def hamming_decode(data, chk, overall, k=48):
    """Returns (corrected_data, corrected_flag, double_error_flag)."""
    exp_chk, _, r = hamming_encode(data, k)
    syn = chk ^ exp_chk
    # Overall parity is taken over the RECEIVED codeword - data XOR stored
    # check bits XOR stored parity - never over check bits recomputed from
    # corrupted data. Recomputing folds the error into both terms, so a single
    # flip at a position with an odd bit-count cancels itself and reads as DED.
    par = overall
    d = data
    while d:
        par ^= d & 1
        d >>= 1
    c = chk
    while c:
        par ^= c & 1
        c >>= 1
    if syn == 0:
        return data, (par != 0), False          # clean, or the parity bit itself
    if par == 0:
        return data, False, True                # syndrome but parity agrees -> DED
    # single error at 1-based position `syn`
    if syn & (syn - 1):                         # a data position
        di = 0
        for pos in range(1, k + r + 1):
            if pos & (pos - 1):
                if pos == syn:
                    return data ^ (1 << di), True, False
                di += 1
    return data, True, False                    # error landed in a check bit


# ------------------------------------------------------------- self-checks

def check_residue_algebra():
    """Residue check must never fire when the datapath is correct."""
    random.seed(20260904)
    false_alarms = 0
    trials = 0
    for mode in (M16, M8, M4):
        w = LANE_W[mode]
        for sgn in (0, 1):
            for _ in range(20000):
                a, b = random.getrandbits(16), random.getrandbits(16)
                acc = random.getrandbits(48)
                prods = products(a, b, mode, sgn)
                for L in range(LANES[mode]):
                    lane = (acc >> (w * L)) & ((1 << w) - 1)
                    s = lane + prods[L]
                    nxt = s & ((1 << w) - 1)
                    carry = (s - nxt) >> w        # exact, signed-aware
                    exp = (expected_residue(a, b, acc, mode, sgn, L, carry)) % MOD
                    got = res_pattern(nxt, w)
                    trials += 1
                    if exp != got:
                        false_alarms += 1
    return trials, false_alarms


def check_detection():
    """Single bit flips in the accumulator must ALWAYS be caught by mod 3.

    A flip of bit k changes the value by +/-2^k, and 2^k mod 3 alternates 1, 2
    and is never 0 -- so no single accumulator bit flip can be invisible.
    """
    missed = 0
    total = 0
    for w in (12, 24, 48):
        for k in range(w):
            for base in (0, 0x5A5A5A5A5A5A & ((1 << w) - 1), (1 << w) - 1):
                good = base
                bad = base ^ (1 << k)
                total += 1
                if res_pattern(good, w) == res_pattern(bad, w):
                    missed += 1
    return total, missed


def check_secded():
    random.seed(7)
    single_fixed = double_flagged = 0
    single_total = double_total = 0
    for _ in range(3000):
        d = random.getrandbits(48)
        chk, ov, r = hamming_encode(d)
        # single error in a data bit
        i = random.randrange(48)
        got, corrected, ded = hamming_decode(d ^ (1 << i), chk, ov)
        single_total += 1
        if got == d and corrected and not ded:
            single_fixed += 1
        # double error in data bits
        i, j = random.sample(range(48), 2)
        got, corrected, ded = hamming_decode(d ^ (1 << i) ^ (1 << j), chk, ov)
        double_total += 1
        if ded:
            double_flagged += 1
    return single_total, single_fixed, double_total, double_flagged


def predict_escapes(trials=60000):
    """Predicted mod-3 escape rate per injection site.

    CORRECTED after the first campaign. The original prediction split faults by
    location (accumulator / operand / combinational) and guessed ~1/3 escape for
    anything combinational. That is wrong, and the campaign showed it: a
    combinational fault at the product output escaped 0 times in 4000.

    The right split is by how the fault reaches the accumulated value:

      ADDITIVE       the error lands as +/-2^k on a value that is then simply
                     added -- accumulator bits, product-output bits, adder-tree
                     nodes. 2^k mod 3 alternates 1, 2 and is NEVER 0, so mod 3
                     catches every one of them. 0% escape, not ~33%.

      MULTIPLICATIVE the error lands upstream of the multiply, so it reaches the
                     sum as 2^k * (other operand). That is divisible by 3 exactly
                     when the other operand is, which is about a third of the
                     time. This is the only way a single fault escapes mod 3.

    Location was the wrong axis; linearity is the right one. An adder tree
    cannot turn a single-bit fault into a multiple of 3, however deep it is.
    """
    random.seed(99)
    out = {}

    # ADDITIVE: error is +/-2^k on the accumulated value
    esc = n = 0
    for _ in range(trials):
        w = random.choice([12, 24, 48])
        acc = random.getrandbits(w)
        k = random.randrange(w)
        n += 1
        if res_pattern(acc, w) == res_pattern(acc ^ (1 << k), w):
            esc += 1
    out["additive (acc / product / tree)"] = (n, esc)

    # MULTIPLICATIVE: error is 2^k * other operand
    esc = n = 0
    for _ in range(trials):
        a, b = random.getrandbits(8), random.getrandbits(8)
        k = random.randrange(8)
        delta = ((a ^ (1 << k)) - a) * b
        n += 1
        if delta % MOD == 0:
            esc += 1
    out["multiplicative (operand side)"] = (n, esc)
    return out


if __name__ == "__main__":
    t, fa = check_residue_algebra()
    print(f"residue algebra  : {t} fault-free lane-cycles, {fa} false alarms")
    tot, missed = check_detection()
    print(f"single-bit detect: {tot} accumulator bit flips, {missed} missed")
    st, sf, dt, df = check_secded()
    print(f"SEC-DED single   : {sf}/{st} corrected")
    print(f"SEC-DED double   : {df}/{dt} flagged as uncorrectable")
    _, r = hamming_encode(0)[0], hamming_encode(0)[2]
    print(f"SEC-DED width    : 48 data + {r} check + 1 overall = {48+r+1} bits")
    print()
    print("predicted mod-3 escape rates (the campaign must reproduce these):")
    for site, (n, esc) in predict_escapes().items():
        print(f"  {site:22s} {esc:6d}/{n} = {100.0*esc/n:5.2f}%")
    raise SystemExit(1 if (fa or missed or sf != st or df != dt) else 0)
