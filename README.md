# fault-tolerant-datapath

Concurrent error detection and correction for a multi-precision multiply-
accumulate datapath, characterised against an unprotected baseline and against
triple-modular redundancy.

**Status: not started.** This repository is a placeholder. The design it will
harden lives in
[multiprecision-datapath](https://github.com/devesh-b/multiprecision-datapath);
the fault-injection primitive it will use lives in
[fault-injection-harness](https://github.com/devesh-b/fault-injection-harness).

## Planned scope

- Residue-mod-3 checking across the multiply-accumulate for concurrent
  detection, and Hamming SEC-DED on the accumulator file for correction.
- Injection campaigns classifying every trial as masked, corrected, detected,
  or silent data corruption — the last being the only real failure.
- Area, timing and power against an unprotected baseline, with TMR as the
  200%-overhead reference point.

One prediction worth recording before any measurement: a single accumulator bit
flip has magnitude ±2^k, and 2^k mod 3 alternates 1, 2 and is never 0 — so
residue-mod-3 should detect *every* such fault. Operand-register and
combinational faults can produce error magnitudes divisible by 3 and should
escape roughly one time in three. If the campaigns disagree with that, the
reasoning is wrong and worth chasing.
