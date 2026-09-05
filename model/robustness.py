#!/usr/bin/env python3
"""Does inexactness buy robustness? (d2-5, d2-6)

Two questions that get confused with each other:

  FORMAT   At a fixed 16 bits, how much numerical damage does one bit flip do,
           in fixed point vs IEEE binary16 vs posit(16,1)? Accuracy and
           robustness are different axes and the ranking is not the same.

  PRECISION Does using FEWER bits make a datapath more robust? Two effects pull
           opposite ways: a narrow value has fewer bits to hit, but each bit is
           worth proportionally more of the value.

Damage is measured in units of FULL SCALE, not relative to the value. Relative
error is the wrong metric here: it diverges for small values in fixed point and
would flatter floating formats for reasons that have nothing to do with
reliability. What a downstream computation feels is the absolute perturbation.
"""
import numpy as np
from formats import posit_decode, posit_table, quantise_fixed, quantise_to

RNG = np.random.default_rng(20260905)


# --------------------------------------------------------------- encoders

def fixed_bits(x, n=16):
    """Q1.(n-1) two's complement pattern."""
    f = n - 1
    q = np.clip(np.round(x * (1 << f)), -(1 << f), (1 << f) - 1).astype(np.int64)
    return (q & ((1 << n) - 1)).astype(np.uint32)


def fixed_value(bits, n=16):
    f = n - 1
    v = bits.astype(np.int64)
    v = np.where(v >= (1 << (n - 1)), v - (1 << n), v)
    return v / (1 << f)


def f16_bits(x):
    return np.asarray(x, dtype=np.float16).view(np.uint16).astype(np.uint32)


def f16_value(bits):
    return bits.astype(np.uint16).view(np.float16).astype(np.float64)


class Posit:
    def __init__(self, n=16, es=1):
        self.n, self.es = n, es
        pairs = []
        for b in range(1 << n):
            v = posit_decode(b, n, es)
            if v is not None:
                pairs.append((v, b))
        pairs.sort()
        self.vals = np.array([p[0] for p in pairs])
        self.bits = np.array([p[1] for p in pairs], dtype=np.uint32)
        self.lut = np.array([posit_decode(b, n, es) if posit_decode(b, n, es) is not None
                             else np.nan for b in range(1 << n)])

    def encode(self, x):
        idx = np.searchsorted(self.vals, x)
        idx = np.clip(idx, 1, len(self.vals) - 1)
        lo, hi = self.vals[idx - 1], self.vals[idx]
        pick = np.where(np.abs(x - lo) <= np.abs(hi - x), idx - 1, idx)
        return self.bits[pick]

    def decode(self, bits):
        return self.lut[bits]


# ------------------------------------------------------- flip experiment

def flip_damage(encode, decode, x, nbits):
    """Absolute perturbation, in units of full scale, for a flip in every bit.

    Returns an array shaped (len(x), nbits). NaN entries are flips that produced
    a non-finite or undefined code (binary16 Inf/NaN, posit NaR) -- counted
    separately, because 'the number stopped being a number' is a distinct and
    worse failure than 'the number moved'.
    """
    b = encode(x)
    out = np.full((len(x), nbits), np.nan)
    for k in range(nbits):
        v2 = decode(b ^ np.uint32(1 << k))
        d = np.abs(v2 - x)
        d[~np.isfinite(v2)] = np.nan
        out[:, k] = d
    return out


def summarise(name, dmg, scale=1.0):
    flat = dmg.reshape(-1)
    nan = np.isnan(flat).mean()
    fin = flat[~np.isnan(flat)] / scale
    return dict(name=name,
                median=float(np.median(fin)),
                p99=float(np.percentile(fin, 99)),
                worst=float(fin.max()),
                gt_fullscale=float((fin > 1.0).mean()),
                nonfinite=float(nan))


def study_formats(n=4000):
    x = RNG.uniform(-1.0, 1.0, size=n)
    pos = Posit(16, 1)
    rows = [
        summarise("fixed Q1.15",   flip_damage(fixed_bits, fixed_value, quantise_fixed(x, 16), 16)),
        summarise("IEEE binary16", flip_damage(f16_bits,   f16_value,   x, 16)),
        summarise("posit(16,1)",   flip_damage(pos.encode, pos.decode,  x, 16)),
    ]
    return rows


def study_precision(n=4000):
    """Fewer bits: fewer targets, but each worth more.

    Compared at equal FULL SCALE, so the question is purely 'how much of the
    signal does one flip destroy', not 'how big are the numbers'.
    """
    x = RNG.uniform(-1.0, 1.0, size=n)
    rows = []
    for bits, lanes, mode in ((16, 1, "M16"), (8, 2, "M8"), (4, 4, "M4")):
        q = quantise_fixed(x, bits)
        dmg = flip_damage(lambda v, b=bits: fixed_bits(v, b),
                          lambda v, b=bits: fixed_value(v, b), q, bits)
        r = summarise(mode, dmg)
        r["bits"], r["lanes"] = bits, lanes
        rows.append(r)
    return rows


def study_partition(acc_bits=48, n=20000):
    """The containment question, on the datapath that exists.

    The accumulator file is a FIXED 48 bits, partitioned into N lanes of w bits
    (1x48, 2x24, 4x12). A single flip lands somewhere in those 48 bits and
    corrupts exactly one lane. Narrow lanes contain the fault to a smaller
    FRACTION of the output vector -- but each lane bit is worth proportionally
    more of its lane. Whether that is a net win is an empirical question, and
    the answer is not what the "low precision is more robust" folklore expects.

    Damage is measured against the whole output vector: the perturbation of the
    corrupted lane, in units of that lane's full scale, averaged over the N
    lanes the vector contains.
    """
    rows = []
    for w, lanes, mode in ((48, 1, "M16"), (24, 2, "M8"), (12, 4, "M4")):
        bit = RNG.integers(0, acc_bits, size=n)      # uniform over the whole file
        j = bit % w                                  # position within its lane
        # fixed point with the lane's MSB as sign: a flip at j perturbs the lane
        # value by 2^j, and the lane's full scale is 2^(w-1)
        lane_damage = (2.0 ** j) / (2.0 ** (w - 1))
        vector_damage = lane_damage / lanes          # only 1 lane of `lanes` is hit
        rows.append(dict(mode=mode, w=w, lanes=lanes,
                         lane_mean=float(lane_damage.mean()),
                         vec_mean=float(vector_damage.mean()),
                         frac_corrupted=1.0 / lanes))
    return rows


if __name__ == "__main__":
    print("Damage from ONE bit flip, in units of full scale (1.0).")
    print("Values drawn uniformly from [-1,1); every bit position flipped.\n")

    print("d2-5 -- format, at a fixed 16 bits:")
    print(f"  {'format':15s} {'median':>10s} {'p99':>12s} {'worst':>14s} "
          f"{'>full scale':>12s} {'non-finite':>11s}")
    for r in study_formats():
        print(f"  {r['name']:15s} {r['median']:10.3e} {r['p99']:12.3e} "
              f"{r['worst']:14.3e} {100*r['gt_fullscale']:11.1f}% {100*r['nonfinite']:10.1f}%")

    print("\nd2-6a -- precision, per value (fixed point):")
    print(f"  {'mode':5s} {'bits':>5s} {'lanes':>6s} {'median':>11s} {'p99':>11s} "
          f"{'worst':>10s} {'>full scale':>12s}")
    for r in study_precision():
        print(f"  {r['name']:5s} {r['bits']:5d} {r['lanes']:6d} {r['median']:11.3e} "
              f"{r['p99']:11.3e} {r['worst']:10.3e} {100*r['gt_fullscale']:11.1f}%")

    print("\nd2-6b -- containment: one flip in a FIXED 48-bit accumulator file")
    print(f"  {'mode':5s} {'lane w':>7s} {'lanes':>6s} {'output corrupted':>17s} "
          f"{'damage to lane':>15s} {'damage to vector':>17s}")
    for r in study_partition():
        print(f"  {r['mode']:5s} {r['w']:7d} {r['lanes']:6d} {100*r['frac_corrupted']:16.0f}% "
              f"{r['lane_mean']:15.4f} {r['vec_mean']:17.4f}")
    print("\n  Narrow lanes confine the fault to a smaller fraction of the output and")
    print("  do proportionally more damage inside it. The two effects cancel exactly,")
    print("  because lanes x lane-width is 48 either way. Partitioning does not buy")
    print("  robustness -- the bits are the cross-section, and 48 bits is 48 bits.")
