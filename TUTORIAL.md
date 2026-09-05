# How this fault-tolerant datapath works, from the beginning

A ground-up explanation of everything in this repository. It assumes you know
what a bit is and roughly what a logic gate does. It does not assume you know
anything about error correction, fault injection or reliability engineering.

If you have not read the tutorial in the
[multiprecision-datapath](https://github.com/devesh-b/multiprecision-datapath)
repository, you do not need to — the arithmetic you need is recapped here — but
that one explains the datapath this one protects.

---

## 1. The problem: hardware gets things wrong

We normally think of digital hardware as exact. Feed in 3 and 5, get 15, every
time. Mostly true, and it is a remarkable engineering achievement that it is.

But a bit is a voltage on a wire or a charge on a tiny capacitor, and physical
things can be disturbed. Sometimes a bit that should be 0 reads as 1. The circuit
is not broken — the next cycle it works perfectly — but for one moment it held
the wrong value, and by then the wrong value may have been added into a total
that gets used for something.

This is a **soft error**, or a **transient fault**. "Soft" because nothing is
permanently damaged, as opposed to a "hard" fault where a transistor has actually
failed.

### 1.1 Why bits flip

Several causes, all physical:

- **Radiation.** Cosmic rays hit the atmosphere and produce showers of energetic
  particles. One striking a chip can deposit enough charge to flip a stored bit.
  This is a **single-event upset**, or **SEU**. It is worse at altitude, which is
  why avionics takes it very seriously, and it happens at sea level too.
- **Alpha particles** from trace radioactive impurities in the packaging.
- **Voltage and temperature.** Running a chip at lower voltage to save power
  leaves less margin between a 0 and a 1. Aggressive undervolting trades
  reliability for energy, deliberately.
- **Ageing.** Transistors drift over years of operation.

The rate is low per bit — but chips have billions of bits and run for years, and
"low probability per bit per hour" multiplied by a large fleet becomes a
certainty somewhere.

### 1.2 Why it matters more than it used to

Two things changed. Transistors got smaller, so each stores less charge and takes
less energy to disturb. And we started putting neural networks in cars.

The FT-CNN paper this work builds on quotes numbers worth knowing. A single bit
flip during CNN image classification can cause a wrong answer as often as 40% of
the time when it lands in the datapath and 70% in memory. Neutron beam testing of
YOLO object detection measured a failure rate from *silent* corruption high
enough to **fail the ISO 26262 automotive safety standard**.

"Silent" is the key word, and it is the whole subject of this repository.

### 1.3 The three ways a fault can end

When a fault occurs, exactly one of three things happens.

1. **It is masked.** The wrong bit does not change the answer. Maybe it landed in
   a value that was about to be overwritten. Nothing to do.
2. **It is detected.** The answer is wrong, but the system *knows*. It can retry,
   flag an error, or fall back to a safe state. A bad outcome, but a manageable
   one.
3. **It is silent.** The answer is wrong and nothing noticed. The system carries
   on confidently with a wrong number.

The third is **silent data corruption**, or **SDC**, and it is qualitatively
worse than the second. A car that knows its perception system failed can pull
over. A car that does not know will keep driving.

Functional-safety standards like **IEC 61508** and **ISO 26262** are built around
exactly this distinction. They do not ask "how often does it fail" — they ask
"how often does it fail *dangerously and undetected*". A single "coverage"
percentage hides the difference, which is why every measurement in this
repository reports four separate outcomes rather than one number.

---

## 2. The simplest fix, and why it is expensive

### 2.1 Triple modular redundancy

If you do not trust one copy, build three and vote. Compute the same thing three
times, compare, and take the majority answer. If one copy is corrupted the other
two outvote it.

That is **triple modular redundancy**, TMR, and `fault-injection-harness`
contains a working example: a register with three copies and a bitwise majority
voter.

```
q = (c0 AND c1) OR (c1 AND c2) OR (c0 AND c2)
```

Bitwise, so each bit position votes independently.

### 2.2 What TMR does and does not fix

Try it. Flip one bit in copy 0: the other two agree, the voter outputs the right
value, the fault is **masked**. Flip one bit in copy 0 and a *different* bit in
copy 1: for each bit position at most one copy is wrong, so the vote is still
correct. Also masked.

Now flip **the same bit position in two copies**. Two copies now agree on the
wrong value, and they outvote the one correct copy. TMR is defeated.

The harness demonstrates this rather than asserting it, which is the right way
round — a protection scheme you have not tried to break is a protection scheme
you do not understand.

### 2.3 The cost

TMR triples your hardware. Slightly more once you count the voter. In this
repository, TMR-ing the datapath measures at **3.29× the area** — roughly 229%
overhead.

For some systems that is simply the price. But it prompts the question this whole
line of research is built on: **can you get most of the protection for much less
than 200%?**

That question is the DeSyRe thesis — build reliable systems from unreliable
components, rather than making every component reliable. Keep a small part
trustworthy and let it manage the rest.

---

## 3. Detecting errors more cheaply

TMR is expensive because it duplicates *everything*. Cheaper schemes carry a
small amount of extra information alongside the data — enough to tell that
something changed, without recomputing.

### 3.1 Parity

The simplest. Add one bit that makes the total number of 1s even.

```
data 1011010  →  four 1s, already even  →  parity 0
data 1011011  →  five 1s, odd           →  parity 1
```

Flip any single bit and the count's evenness changes, so the parity no longer
matches: **error detected**. One bit of overhead.

But flip *two* bits and the evenness is restored — parity is fooled. And parity
tells you only that something is wrong, never what.

### 3.2 Hamming codes: locating the error

Richard Hamming's insight, in 1950, was that with several parity bits, each
covering a cleverly chosen subset, the *pattern* of which ones fail identifies
the faulty bit.

Number the positions of your codeword from 1. Put check bits at the positions
that are powers of two — 1, 2, 4, 8, 16, … — and data everywhere else. Check bit
at position 2^c covers every position whose index has bit c set.

Now suppose exactly one bit flips, at position p. Every check bit covering p
fails; none of the others do. Write down which check bits failed as a binary
number — this is the **syndrome** — and you get p itself. **The syndrome names
the broken bit.** Flip it back and you have corrected the error.

That is worth pausing on. Not "an error occurred somewhere" but "bit 37 is
wrong". A handful of extra bits buys you the location.

For 48 data bits you need 6 check bits, since 2⁶ = 64 ≥ 48 + 6 + 1.

### 3.3 SEC-DED: knowing when you cannot fix it

Plain Hamming has a nasty failure mode. With *two* errors the syndrome is the XOR
of two valid syndromes — which is some other perfectly legitimate-looking
position. The decoder confidently "corrects" a bit that was fine, and now three
bits are wrong.

The fix is one more bit: an **overall parity** over the entire codeword.

- Two errors leave the overall parity unchanged, but produce a non-zero syndrome.
  Non-zero syndrome with matching parity means **two errors — flag, do not
  correct**.
- One error changes the parity and gives a syndrome. Correct it.
- No error: syndrome zero, parity matches.

This is **SEC-DED**: single error correction, double error detection. For a
48-bit accumulator: 48 data + 6 check + 1 overall = **55 bits stored**, about 15%
overhead — against TMR's 200%.

### 3.35 Hamming worked through, on eight bits

The description above is abstract. Here it is with numbers, on a small enough
code to follow by hand.

Take 4 data bits. We need enough check bits `r` that `2^r ≥ k + r + 1`, so
`r = 3` (since `2³ = 8 ≥ 4 + 3 + 1 = 8`). Seven positions total, numbered 1 to 7.
Check bits go at the powers of two — positions 1, 2 and 4 — and data at 3, 5, 6
and 7.

Which positions does each check bit cover? Check bit at position `2^c` covers
every position whose index has bit `c` set:

| check | position | covers |
|---|---|---|
| c₀ | 1 | 3, 5, 7 (indices with bit 0 set) |
| c₁ | 2 | 3, 6, 7 (bit 1 set) |
| c₂ | 4 | 5, 6, 7 (bit 2 set) |

Say the data bits at positions 3, 5, 6, 7 are `1, 0, 1, 1`. Each check bit is the
XOR of what it covers:

```
c₀ = d₃ XOR d₅ XOR d₇ = 1 XOR 0 XOR 1 = 0
c₁ = d₃ XOR d₆ XOR d₇ = 1 XOR 1 XOR 1 = 1
c₂ = d₅ XOR d₆ XOR d₇ = 0 XOR 1 XOR 1 = 0
```

So the codeword, positions 1 through 7, is `0 1 1 0 1 1 1`.

**Now corrupt position 6.** It flips from 1 to 0, giving `0 1 1 0 1 0 1`.

Recompute each check from the received data and compare with what was stored:

- c₀ covers 3, 5, 7 — none of which changed. Matches. Syndrome bit 0 = **0**.
- c₁ covers 3, 6, 7 — position 6 changed. Fails. Syndrome bit 1 = **1**.
- c₂ covers 5, 6, 7 — position 6 changed. Fails. Syndrome bit 2 = **1**.

Syndrome = `110` binary = **6**. The syndrome is the position of the broken bit.
Flip position 6 back and the codeword is repaired.

That is the whole mechanism, and it scales directly: 48 data bits need 6 check
bits by the same inequality, and the syndrome still names the position. The only
addition for SEC-DED is one more parity bit over everything, so that a *pair* of
errors — which produces some other plausible-looking syndrome — can be
distinguished from a single one and refused rather than mis-corrected.

Try the double-error case by hand once. Corrupt positions 5 and 6 together: the
syndrome comes out `011` = 3, and a plain Hamming decoder would confidently
"repair" position 3, leaving three bits wrong instead of two. The overall parity
bit is what stops that, because two flips leave it unchanged while the syndrome
is non-zero — a combination that cannot arise from a single error.

### 3.4 A bug worth knowing about

`model/protect.py` originally got SEC-DED wrong, and the mistake is instructive.

On decode, the overall parity must be computed over the **received codeword** —
the data bits XOR the *stored* check bits XOR the stored parity. The first
version recomputed the check bits from the (corrupted) data and used those
instead.

Why that breaks: recomputing folds the error into both terms. A single flip at a
position whose index has an odd number of set bits changes the recomputed check
bits an odd number of times, so the two changes cancel, the parity looks
unchanged, and the decoder reports a double error.

The symptom was 1721 of 3000 single errors "corrected" instead of 3000. Only
about the positions with even bit-counts worked, which is exactly the pattern you
would predict once you see the cause — and that is how the bug was found. **When
a failure rate is suspiciously close to a half, look for something that cancels.**

After the fix: 3000/3000 single errors corrected, 3000/3000 double errors
flagged, and in RTL 11,000/11,000 and 169,200/169,200.

---

## 4. Checking arithmetic, not just storage

ECC protects **stored** bits. It says nothing about whether the *arithmetic* was
done correctly. If the multiplier produces a wrong product, ECC will faithfully
protect that wrong product.

For arithmetic you need something that checks the operation.

### 4.1 Casting out nines, in binary

You may have been taught to check arithmetic by casting out nines: add up the
digits, and if the digit sums do not match, you made a mistake. That works
because the digit sum of a decimal number has the same remainder mod 9 as the
number itself, and remainders are preserved by addition and multiplication.

Formally, if `r(x)` is `x mod n`, then

```
r(a + b) = r( r(a) + r(b) )
r(a × b) = r( r(a) × r(b) )
```

So carry a small remainder alongside your big computation, do the same operations
on it, and compare at the end. If the big computation went wrong, the remainders
almost certainly disagree.

This is **residue checking**, and it is exactly casting out nines applied to
hardware.

### 4.2 Why 3 is the right modulus for binary

The choice of modulus decides the cost. We use **mod 3**, and the reason is a
neat piece of arithmetic.

`4 ≡ 1 (mod 3)`. So `4² ≡ 1`, `4³ ≡ 1`, and so on — every power of 4 is 1 mod 3.
A binary number's bits in pairs are exactly its base-4 digits. Therefore:

> The residue mod 3 of a binary number is the **sum of its 2-bit groups**, mod 3.

No division. Take the bits two at a time, add them up with a small tree of 2-bit
adders, and reduce mod 3 at each step. `rtl/res3.v` does exactly this, and it
verifies exhaustively for 12-bit inputs and randomly at 24 and 48.

Most other moduli need an actual divider. Mod 3 needs an adder tree. That is why
residue checking in binary hardware is almost always mod 3.

### 4.3 Making it work on a real datapath

The textbook version says residues are homomorphic and stops. A working
implementation has two corrections, and both are load-bearing.

**Signedness.** A `w`-bit pattern `u` representing a two's-complement value `v`
satisfies `v = u − s·2^w`, where `s` is the sign bit. For even `w`,
`2^w ≡ 1 (mod 3)`, so

```
v ≡ u − s   (mod 3)
```

A one-bit correction, not a recomputation. Subtract the sign bit.

**Accumulator wrap.** The accumulator computes `acc + p` modulo `2^w`, discarding
any carry out. That discarded carry is worth `2^w ≡ 1 (mod 3)`, so

```
acc_next ≡ acc + p − c   (mod 3)
```

where `c` is the carry that fell off the top.

Put together, the check the hardware actually computes is:

```
r(acc_next) = r(acc) + r_a·r_b + s_p − c   (mod 3)
```

Every term on the right is a residue-tree output, a sign bit, or a carry wire.

Drop the `s_p` term and the checker fires on every negative product. Drop `c` and
it fires on every accumulator wrap. Both would make the design useless in a way
that looks like a hardware fault, which is why `model/protect.py` validates the
exact hardware formulation across 560,000 fault-free cycles and reports **zero
false alarms** before any Verilog was written.

**A checker that cries wolf is worse than no checker**, because every alarm costs
something and people learn to ignore it.

### 4.5 Comparing residue checking with the alternatives

It is worth placing residue checking against the other options, because each
occupies a different point on the same trade-off.

**Duplication** — run the computation twice and compare — costs 100% and catches
anything that does not happen identically twice. Conceptually simple, and the
cost is the whole point of avoiding it.

**TMR** costs 200% and *corrects* rather than merely detecting, because with
three copies a majority still exists after one fails.

**ECC** costs about 15% but protects only storage. It has nothing to say about
whether an addition was performed correctly.

**Residue checking** costs a few percent and watches the arithmetic itself. What
it cannot do is *correct*: knowing the product is wrong does not tell you what it
should have been. And it has a structural blind spot, which §7 measures.

That is why this design uses two mechanisms rather than one. Residue watches the
arithmetic, ECC repairs the storage, and neither is asked to do the other's job.
The general principle — **match the mechanism to what it is actually good at,
and stack mechanisms whose weaknesses do not overlap** — is worth more than any
particular scheme.

There is one more axis worth naming. All of the above are *concurrent* checks:
they run alongside the computation and cost area. The alternative is *temporal*
redundancy — do it again — which costs time instead of area, and which §9 shows
catches exactly the faults the concurrent checks miss. Area and time are the two
currencies, and almost every reliability decision is a choice about which one to
spend.

### 4.4 Building the residues once

One more piece of arithmetic pays off. Since `2⁴ ≡ 2¹² ≡ 1 (mod 3)`, the residue
of a wide value is just the **sum of the residues of its narrow pieces**. So the
design computes residues once at 4-bit granularity for operands and 12-bit for
accumulator blocks, then adds them up per mode. One set of narrow trees serves
all three precision modes instead of three separate sets.

---

## 5. The protected datapath

Putting the pieces together. The thing being protected is a multi-precision
multiply-accumulate unit: one 16×16 datapath that also runs as two 8-bit or four
4-bit independent lanes, over a 48-bit accumulator partitioned between those
lanes. It is vendored here from the arithmetic repository, unmodified.

`rtl/mpmac_prot.v` wraps it in two layers:

**Residue mod 3 across the whole multiply-accumulate — detection.** Residues are
taken from the *clean* operands, before the point where faults are injected, so a
fault inside the datapath is visible to the checker.

**Hamming SEC-DED on the 48-bit accumulator — correction.** The accumulator is
stored as data plus ECC, and decoded before use every cycle. A transient in
storage is repaired before it can be accumulated into the running total.

Why split the job this way? Because detection and correction have different costs
and different natural homes. Residue checking watches the arithmetic but cannot
repair it — knowing the product is wrong does not tell you what it should have
been. ECC repairs storage but knows nothing about arithmetic. The accumulator is
the one piece of state where a transient is both most likely (it is the widest,
longest-lived register) and cheapest to actually fix.

`mpmac_unprot` is the same datapath with the protection removed and the same
ports, so the comparison is like for like. `mpmac_tmr` is three copies and a
voter, present only to anchor the expensive end of the scale.

### 5.1 Proving the protection did not break the arithmetic

Before measuring how well protection works, check it did not change the answer.
A protection scheme that quietly alters results is worse than none at all.

Both designs run the arithmetic repository's own golden-model testbench
unmodified — 1,467,310 vectors each, zero errors — and the protected version
additionally asserts that **no flag ever fires** during those vectors. No
detections, no corrections, no double-error reports, on 1.47 million fault-free
operations.

The accumulate path was also rebuilt, to expose the per-lane carry the residue
check needs. Rebuilt code is new code, so it is *proved* equivalent to the
original rather than assumed (`formal/equiv_acc.sby`) — and that proof is
combinational and closes in under a second, where trying to prove the same thing
about the whole sequential MAC did not close in ten minutes. Picking what to
prove is most of the skill.

### 5.2 Choosing a fault model, and why the choice matters

Before you can test a protection scheme you have to say precisely what you are
protecting against. That statement is the **fault model**, and it is a design
decision with consequences, not a formality.

The choice here is **transient single-event upset**: one bit flips for exactly
one cycle, and the register reloads correctly afterwards. One fault per trial.

Why not the alternatives?

**Stuck-at faults** — a wire permanently held at 0 or 1 — are the classic model
in manufacturing test, where the question is "did this chip come out of the
factory working". That is a different question from "does this chip stay correct
in the field", which is what reliability asks. Stuck-at also does not match the
physics of a particle strike, which deposits charge once and leaves.

**Timing faults** — a path too slow to settle before the clock edge — are real
and important, especially with voltage scaling. But modelling them meaningfully
needs a target cell library and static timing analysis, which is a much larger
undertaking, and the results would be specific to one process. Out of scope, and
said so.

**Multiple simultaneous faults** are excluded because the scheme is a
single-error scheme. A double-fault campaign would mostly re-derive that fact,
and the TMR harness already demonstrates the single-error boundary concretely.

Where the faults are injected matters just as much as what they are. Four sites
are used, and they are chosen to span the *mechanisms* rather than just the
locations: stored data, stored ECC, an operand after residues are taken, and a
combinational node. Section 7.2 explains why that last distinction — which
mechanism, not which location — turned out to be the one that mattered.

Being explicit about all of this is what lets someone else disagree with you
usefully. A coverage number without a fault model attached means nothing at all,
because the number is entirely determined by what you chose to inject.

---

## 6. How do you test something that only fails by accident?

You cannot wait for a cosmic ray. You have to cause faults deliberately, which is
**fault injection**.

### 6.1 Saboteurs

The technique used here is a **saboteur**: an input to the design whose only job
is to corrupt a value. Every protected value gets an `inject` port that is XORed
into it.

```verilog
q <= nxt ^ inj_acc;
```

Normally `inj_acc` is zero and the XOR does nothing. Set one bit and that bit of
the accumulator flips for that cycle. Fault injection becomes part of the module
interface rather than a simulator trick, which means the design under test needs
no special build.

The harness in `fault-injection-harness` is the same idea at its simplest: a TMR
register with a saboteur port per copy.

### 6.2 Running a campaign

A **campaign** is many trials, each with one injected fault, classified by
outcome. `tb/tb_campaign.v` runs two copies of the datapath in lockstep on
identical stimulus — one clean, one injected — and compares.

Design choices that matter:

**One fault per trial.** The scheme is a single-error scheme, so multi-fault
campaigns would mostly re-derive that fact. FT-CNN makes the same assumption and
justifies it: a layer executes in a very short time, so two independent
transients landing in the same one is vanishingly unlikely.

**Faults arrive in time, not per operation.** A fault is injected at a rate per
*cycle*, not per operation. This matters more than it sounds: a scheme that buys
coverage by taking extra cycles is exposed for longer and pays for it twice.
Measuring per-operation would hide that.

**Random over sites, bits and cycles**, with four injection sites: accumulator
data bits, stored ECC bits, the operand register (after residues are taken), and
a combinational node at the product output.

### 6.3 The four buckets

Every trial lands in exactly one:

| bucket | output | flag | meaning |
|---|---|---|---|
| **masked** | correct | silent | the fault died on its own |
| **corrected** | correct | fired | protection repaired it |
| **detected** | wrong | fired | safe failure — the system can retry |
| **escaped (SDC)** | wrong | silent | **silent data corruption** |

Only the last is a real failure. Reporting a single coverage number would merge
"masked" and "corrected" — which have very different implications for cost — and
merge "detected" with "escaped", which is the distinction functional safety is
built on.

### 6.4 Measuring the right thing

A subtlety that took a wrong turn to notice. The first version counted *trials in
which the final accumulator was wrong*. That saturates: an accumulator
**ratchets**, so one early silent corruption makes every later result wrong too,
and the metric hits 100% and stops discriminating between schemes.

The fix is to count **corruption events** — moments where a correct accumulator
becomes wrong — and resynchronise the reference afterwards so measurement
continues. Only then do the schemes separate.

**If your metric saturates, it is the wrong metric.** Worth checking before
concluding that two designs are equally bad.

---

## 7. Results, and the prediction that was wrong

### 7.1 What the campaign found

16,000 injections per design.

**Protected:**

| site | masked | corrected | detected | escaped | escape % |
|---|---|---|---|---|---|
| accumulator | 0 | **4000** | 0 | **0** | 0.00% |
| stored ECC | 0 | **4000** | 0 | **0** | 0.00% |
| operand register | 115 | 0 | 2651 | 1234 | **30.85%** |
| product output | 0 | 0 | **4000** | **0** | 0.00% |

**Unprotected**, same faults: accumulator 100% escape, operand 97%, product 100%.

Every single-bit accumulator fault is repaired outright, with zero cycles of
latency, because the SEC-DED decode sits in front of the accumulator read.

### 7.2 The prediction, and why it was wrong

Before building it, the design notes predicted mod 3 would catch accumulator
faults essentially always, and that *combinational* faults would escape "roughly
one time in three".

The first half held. The second was wrong: combinational faults at the product
output escaped **0 times in 4000**.

The prediction had split faults by **location** — accumulator, operand,
combinational. The right axis turns out to be **linearity**:

- **Additive faults** reach the accumulated value as `±2^k`. Accumulator bits,
  product-output bits, adder-tree nodes — all of these. And `2^k mod 3` alternates
  1, 2, 1, 2 and is **never 0**. So mod 3 catches every one of them. An adder
  tree cannot turn a single-bit fault into a multiple of 3, however deep it is.
- **Multiplicative faults** land upstream of the multiply, so they reach the sum
  as `2^k × (other operand)`. That is divisible by 3 exactly when the other
  operand is — about a third of the time. **This is the only way a single fault
  escapes mod 3.**

Measured 30.85% against a predicted 34%; excluding the 115 masked trials (where
the other operand happened to be zero, so the flip changed nothing) it is 31.8%.

The model in `model/protect.py` was corrected to match this reasoning rather than
the campaign being explained away. That direction matters: when measurement and
model disagree, at least one is wrong, and deciding which by argument rather than
convenience is the whole job.

**"Where is the fault?" is the wrong question to ask of a residue checker. "Does
the fault reach the sum linearly?" is the right one.**

---

## 8. What protection costs

Coverage without cost is meaningless. Three designs, same flow.

**Yosys, generic cells:**

| design | cells | FF | vs unprotected |
|---|---|---|---|
| `mpmac_unprot` | 4682 | 48 | — |
| `mpmac_prot` | 7066 | 55 | **+50%** |
| `mpmac_tmr` | 15488 | 144 | +229% |

**Vivado, Artix-7, LUT-only, 10 ns clock:**

| design | LUT | FF | WNS reg→reg | power |
|---|---|---|---|---|
| `mpmac_unprot` | 1525 | 48 | +5.397 ns | 0.106 W |
| `mpmac_prot` | **1883** | 55 | **−0.078 ns** | 0.123 W |
| `mpmac_tmr` | 4775 | 144 | +5.348 ns | 0.152 W |

On real fabric the protection costs **+23.5% LUTs against TMR's +213%** — about
nine times cheaper for most of the coverage. That is the low-overhead claim made
concrete on hardware someone else can re-synthesise.

### 8.1 The knee is timing, not area

Area is the axis everyone quotes, and it is not where this scheme hurts.

Look at the slack column. The unprotected design meets a 10 ns clock with 5.4 ns
to spare. The protected design **misses it**, at −0.078 ns. TMR, which costs
three times the area, barely moves timing at all.

The reason is structural. The SEC-DED decode sits **inside the accumulator
feedback loop** — every cycle the stored word must be decoded before it can be
added to. That decode is now on the critical path. TMR's voting is wide but
shallow, and it is not in a loop.

So the honest trade is not "cheap versus expensive". It is **area versus depth**:
TMR buys full coverage with area, residue+SEC-DED buys 92% of it with timing.
Which one is right depends on whether your design is area-limited or
frequency-limited — a property of the system, not of the scheme.

The fix, if frequency matters, is to pipeline the ECC decode out of the loop:
store the accumulator pre-decoded and correct off the critical path. That is a
real design change rather than a tuning knob, and it is not done here.

---

## 9. On-demand reliability

Everything so far hardens the datapath to a fixed level, chosen at design time
for the worst case you expect. The DeSyRe idea is different: keep a **small part
of the system trustworthy** and let it decide how much protection the rest needs
*right now*.

Why would that help? Because fault density is not constant. It depends on
altitude, on radiation environment, on supply voltage, on how old the chip is.
Designing for the worst case means paying for it always.

### 9.1 Three levels

`rtl/mpmac_ondemand.v` implements three protection policies over the same
hardware:

| level | policy | cost |
|---|---|---|
| **L0** | commit every result; the checker reports but nothing acts | 2.000 cycles/op |
| **L1** | retry when the checker fires | 2.015 cycles/op at the worst density |
| **L2** | execute twice and compare, always | 3.000–3.068 cycles/op |

L1 is nearly free, because a retry only happens on a detection and detections are
rare. You pay in proportion to how often something actually goes wrong.

**L2 is the interesting one.** Two independent evaluations of a *transient*
disagree whether or not the error happens to be divisible by 3 — so double
execution catches the operand-side faults that residue mod 3 structurally
cannot. It buys back the ~31% blind spot from §7, at 50% more cycles.

That is worth dwelling on. Residue checking and temporal redundancy fail in
completely different ways. Residue is blind to errors that are multiples of its
modulus; re-execution is blind only to faults that recur identically. Stacking
two mechanisms with *different* blind spots is far more valuable than making one
of them bigger.

### 9.2 The controller

A `fault_monitor` counts detections in a 64-cycle window, escalates on the first
bad window, and relaxes only after four consecutive clean ones.

That asymmetry is necessary, not decorative, and the first version got it wrong.
With symmetric thresholds, at a fault density where roughly half the windows are
clean, the level performs a **random walk**: escalate, relax, escalate, relax,
and it never settles where it needs to be. Measured mean level 0.46 when it
should have been at 2.

The fix — escalate fast, relax slowly — is standard **hysteresis**, the same idea
as a thermostat that does not switch on and off every thirty seconds. Any control
loop reacting to a noisy measurement needs it.

### 9.3 Graceful degradation

50,000 operations per point per scheme. Silent corruptions per 1000 operations:

| fault density | L0 | L1 | L2 | adaptive |
|---|---|---|---|---|
| none | 0 | 0 | 0 | 0 |
| 1/3000 | 0.22 | 0.06 | **0** | 0.06 |
| 1/1000 | 0.62 | 0.08 | **0** | 0.10 |
| 1/300 | 1.70 | 0.24 | **0** | 0.26 |
| 1/100 | 4.68 | 0.54 | **0** | 0.52 |
| 1/30 | 16.96 | 2.70 | **0** | 0.88 |

**L2 records zero silent corruptions at every density tested.** Temporal
redundancy closes the residue blind spot completely.

### 9.4 Two results that went against the design

**Running at L0 is never worth it.** L1 costs essentially nothing while cutting
silent corruption about six-fold. The first controller relaxed all the way to L0
and was therefore *strictly dominated by simply always running L1* — worse
coverage, no cheaper. The floor was raised to L1, and that is a measured
conclusion rather than a tuning choice.

**Adaptivity does not beat a well-chosen fixed level.** At the highest density
the adaptive scheme reaches **67% of the way from L1 to L2 in coverage while
paying 73% of the way in cost** — marginally *worse* than linear interpolation.
If you know your fault density in advance, pick the fixed level that suits it.

So what is adaptivity for? Not efficiency. Its value is that **no fixed level is
good across the whole range** — L2 wastes a third of your cycles at low density,
L1 leaks 2.7 corruptions per 1000 operations at high density — and the adaptive
unit is close to the better one at both ends *without being told which regime it
is in*. That matters exactly where DeSyRe says it does: ageing, radiation,
voltage-scaled operation, where the density is not known at design time and
changes over the device's life.

### 9.5 Is the fault-free island actually small?

The controller is assumed fault-free. That is DeSyRe's premise, and it is only
defensible if the island is small enough that hardening it is cheap. So measure
it:

| module | cells | share |
|---|---|---|
| `fault_monitor` | **142** | **1.9%** |
| `mpmac_ondemand` | 7366 | 100% |

Triplicating the *monitor* would cost about 284 extra cells — **under 4% of the
design** — against 3.29× for triplicating everything.

That is the DeSyRe argument reduced to two numbers on a real design: you can make
the part that *decides* genuinely fault-free for the price of a rounding error,
precisely because it decides rather than computes.

---

## 10. Protecting a whole array

A real accelerator is not one MAC, it is thousands. Protecting each one
separately is the expensive way to do it.

### 10.1 Checksums over an array

`rtl/pe_array.v` puts P processing elements — each computing one output of a
matrix-vector product — behind two extra **checksum rows**:

```
wc0[j] = Σ_p     W[p][j]        →  yc0 should equal  Σ_p y[p]
wc1[j] = Σ_p (p+1) W[p][j]      →  yc1 should equal  Σ_p (p+1)·y[p]
```

Feed the checksum rows through ordinary PEs and you get what the sum of the real
outputs *ought* to be. Compare, and define the **syndromes**:

```
d0 = yc0 − Σ y[p]          d1 = yc1 − Σ (p+1)·y[p]
```

Both zero means every PE agreed. If PE `q` is wrong by an amount `e`, then
`d0 = −e` and `d1 = −(q+1)·e`. So the ratio `d1/d0` gives `q+1` — **which PE**
— and `d0` gives the correction to add.

This is **algorithm-based fault tolerance**, ABFT, invented by Huang and Abraham
in 1984. It is the same trick as residue checking one level up: carry redundant
information through the same computation and compare.

The reason to do it per array rather than per PE is that the cost is two extra
PEs *regardless of P*. It should amortise.

### 10.2 Detection is perfect; location is not

3000 transients, one per trial, into a random PE:

| outcome | result |
|---|---|
| detected | **3000 / 3000 — 100%** |
| silent corruption | **0** |
| located correctly | 2967 — 98.9% |
| location ambiguous | 59 — 2.0% |

Correction should therefore have removed nearly all the damage. It removed about
half: mean error per output fell from 1.053e-02 to 5.500e-03.

Why? **Every one of the 33 mislocations came from accumulator bit 47** — the top
bit.

Here is the mechanism. When `e = ±2^47`, look at `(q+1)·d0 mod 2^48`. Since
`d0 = −e = 2^47` (mod 2^48), multiplying by any *odd* number gives `2^47` again,
and by any even number gives 0. So candidates 0 and 2 produce identical
syndromes and are **indistinguishable**. The tie is broken by a coin flip.

And bit 47 carries the *largest* possible error, so 2% of trials hold about half
the total damage — and mislocating them adds error to a healthy PE while leaving
the sick one uncorrected.

### 10.3 The same shape, one level up

This is the **mod-2⁴⁸ analogue of the mod-3 blind spot**, and it has the same
structural cause: **the modulus shares factors with the error.**

Mod 3 is blind when the error is a multiple of 3. Mod 2⁴⁸ location is blind when
the error is a high power of 2, because multiplication by an even number is not
invertible modulo a power of two.

No amount of tuning fixes it, and a third checksum row does not either — the
information simply is not in the syndromes. What works is **temporal**: detect
with ABFT, then re-execute. The transient is gone on the second pass, residual
error is zero, and the cost is a second pass *only on a detection*.

Notice that this is the same answer as §9.1: when an algebraic check has a
structural blind spot, redundancy in *time* is the escape, because it fails
differently.

### 10.4 Does ABFT amortise?

| P | bare array | with ABFT | per-PE protected | ABFT | per-PE |
|---|---|---|---|---|---|
| 4 | 19024 | 29360 | 28264 | 54% | 48% |
| 8 | 38048 | 52078 | 56528 | **36%** | 48% |
| 16 | 76096 | 97628 | 113056 | **28%** | 48% |

It amortises — 54% down to 28% — but **not as 2/P**, which would be 50% down to
12.5%. The two checksum PEs are constant; the **syndrome tree** is not. Summing
P 48-bit accumulators with weights 1…P costs about 15% of the array at P=16,
more than the checksum PEs themselves.

**The crossover against per-PE protection is at P = 8.** Below that, hardening
each element is cheaper; above it, ABFT wins and keeps winning. For a DNN
accelerator, where arrays are far wider than 8, that is the answer — and it is
why FT-CNN operates at layer granularity rather than per multiplier.

One constraint worth stating: the checksum rows must be representable in the same
16 bits as the data, and `Σ(p+1)W[p][j]` bounds the usable weight precision — 12
bits at P=4, 8 bits at P=16. **ABFT buys cheap redundancy and pays for it in
dynamic range**, which is a real cost for a quantised accelerator.

### 10.5 Why these three repositories fit together

It is worth stepping back to see the shape of the whole thing, because each piece
protects the one before it at a larger scale.

**`fault-injection-harness`** is the primitive: a saboteur port, a TMR register,
and a testbench demonstrating exactly where majority voting works and where it
fails. Five files. Everything else assumes you believe this works.

**`multiprecision-datapath`** builds the arithmetic being protected — a MAC that
runs at three precisions over a shared accumulator, verified against a golden
model and proved equivalent across two architectures. Nothing in it concerns
reliability; it is the thing that must be correct before protecting it means
anything.

**This repository** wraps that datapath in detection and correction, measures
what the protection costs, and then scales up twice: first to an adaptive
controller that decides how much protection to apply, then to an array of
processing elements protected as a unit.

The progression is deliberate — primitive, datapath, protection, adaptation,
array — and each level introduces exactly one new idea. If any of the above felt
like too much at once, the harness is the place to start.

The other thing the three share is method: model the algebra in Python before
writing any hardware, verify against an independent golden model, prove what a
solver can prove, measure with more than one tool, and report the results that
went against the design as prominently as the ones that supported it.

---

## 11. Does inexactness buy robustness?

There is a claim that circulates where approximate computing meets reliability:
that lower precision, or a "tapered" format like posit, is somehow kinder under
soft errors. Fewer bits, fewer things to go wrong.

`model/robustness.py` measures it on three axes. The answer is no on all three,
and the reasons are instructive.

### 11.1 Measuring damage properly

First, the metric. Damage is measured as the absolute perturbation **in units of
full scale**, not relative to the value.

Why not relative error? Because it diverges for small fixed-point values — a
tiny value perturbed by one least-significant bit has an enormous *relative*
error but has barely moved — and it would flatter the floating formats for
reasons that have nothing to do with reliability. What a downstream computation
actually feels is the absolute perturbation.

Choosing the metric carefully before measuring is most of the work.

### 11.2 Format, at a fixed 16 bits

Every bit of every encoding flipped, values drawn uniformly from [−1, 1):

| format | median | p99 | worst | P(damage > full scale) |
|---|---|---|---|---|
| fixed Q1.15 | 5.86e-03 | 1.00 | **1.00** | **0.0%** |
| IEEE binary16 | 3.74e-02 | 5.49e+04 | 6.55e+04 | 10.8% |
| posit(16,1) | 1.56e-02 | 1.90e+02 | **2.68e+08** | 12.5% |

**Fixed point's damage is structurally bounded by full scale.** There is no bit
you can flip that moves the value further than the format's own range, because
every bit has a fixed weight and the weights sum to the range. That is not a
tuning result, it is a property of the representation.

Both floating formats are unbounded. Flip an exponent bit and you *multiply* the
value. Posit is worst of all: flipping a regime bit changes the exponent by a
great deal more, and its worst case lands exactly on `maxpos = useed^(n−2) = 2²⁸`.

**This inverts the accuracy ranking.** On accuracy over a bounded workload the
order was fixed, posit, binary16. On robustness it is fixed, binary16, posit.
Posit buys its accuracy near 1 with a regime field whose corruption is
catastrophic — the same encoding decision, read from the other side.

For safety-critical inference that is the more important column, and it is an
argument for fixed point that has nothing to do with area.

### 11.3 Precision: fewer bits is worse

| mode | bits | median damage |
|---|---|---|
| `M16` | 16 | 5.86e-03 |
| `M8` | 8 | 9.38e-02 |
| `M4` | 4 | 3.75e-01 |

Sixty-four times worse from 16 bits to 4. The intuition — fewer bits, fewer
things to hit — is right about the cross-section and wrong about the
consequence. Each remaining bit carries proportionally more of the value, and
that dominates completely.

### 11.4 Partitioning: exactly no help

The last axis is the most interesting, because the answer is a clean cancellation.

The accumulator file is a fixed 48 bits however it is partitioned: 1×48, 2×24 or
4×12. A flip lands somewhere in those 48 bits and corrupts exactly one lane.
Narrow lanes **contain** the fault to a smaller fraction of the output — but do
proportionally **more** damage inside the lane they hit.

Measured on the RTL, 20,000 injections per mode:

| mode | lanes × width | output corrupted | damage to that lane | damage to the vector |
|---|---|---|---|---|
| `M16` | 1 × 48 | 100% | 0.0395 | **0.0395** |
| `M8` | 2 × 24 | 50% | 0.0838 | **0.0419** |
| `M4` | 4 × 12 | 25% | 0.1691 | **0.0423** |

**The two effects cancel exactly.** Not approximately — the model predicts the
cancellation for the same reason the measurement finds it: lanes × lane-width is
48 either way.

The general conclusion: **the bits are the cross-section.** If you want a
datapath to be less damaged by soft errors, the lever is not the number format
and not the lane width — it is protecting the bits, which is what the rest of
this repository does. Inexactness buys area and throughput, and it should be
argued for on those grounds rather than on robustness it does not deliver.

---

## 12. A fault, traced all the way through

Concrete numbers again. Suppose the accumulator holds 1000, we are in `M16`
signed mode, and we accumulate 3 × 4.

**Fault-free.** The product is 12. The lane adder computes 1000 + 12 = 1012, no
carry out. In parallel:

- residue of the accumulator: 1000 mod 3 = 1
- residue of operand `a` = 3 mod 3 = 0, of `b` = 4 mod 3 = 1
- product residue = 0 × 1 = 0
- product sign bit `s_p` = 0 (positive), carry `c` = 0
- expected = (1 + 0 + 0 − 0) mod 3 = **1**
- actual residue of 1012: 1012 = 337×3 + 1 → **1**

They match. No flag. Good.

**Now inject a fault** — flip bit 4 of the accumulator as it is written. The
stored value becomes 1012 XOR 16 = 1028.

Two things happen independently.

*The residue check.* Next cycle, the checker computes the residue of what it
reads. 1028 mod 3 = 2, but the expected value was 1. **Mismatch — detected.**
Note it had to be detected: the error is exactly 2⁴ = 16, and 16 mod 3 = 1 ≠ 0.
No power of two is divisible by 3, so no single accumulator bit flip can hide.

*The SEC-DED decode.* The stored 55-bit codeword no longer matches its check
bits. The syndrome comes back naming position 4. The decoder flips that bit back,
and the accumulator reads 1012 again. **Corrected**, in the same cycle, before
the value is used.

So this trial lands in the **corrected** bucket: output correct, flag fired. That
is why the accumulator row of the campaign table is 4000 corrected and 0 escaped.

**A fault that does escape.** Now flip bit 2 of operand `a`, *after* its residue
was taken. `a` becomes 3 XOR 4 = 7 instead of 3. The product is 7 × 4 = 28
instead of 12, so the accumulator becomes 1028 — wrong by 16.

The checker computed its expectation from the *clean* `a` = 3, so it expects
residue 1 and sees 1028 mod 3 = 2. Mismatch, detected. Fine.

But change `b` to 3 instead of 4. Now the error is (7 − 3) × 3 = 12, and
12 mod 3 = 0. The residue is **unchanged**, the checker is satisfied, and the
wrong answer sails through. That is the multiplicative blind spot from §7.2,
happening for exactly the predicted reason: the other operand was divisible by 3.

That single example contains the whole coverage story.

---

## 13. Questions you might reasonably ask

**Why mod 3 and not something bigger, like mod 15?**
A larger modulus has a smaller blind spot — mod 15 misses only multiples of 15.
But the cheap-residue trick needs a modulus of the form `2ⁿ − 1`, and the tree
gets wider as n grows. Mod 3 is the cheapest useful choice. More importantly,
enlarging the modulus does not change the *mechanism*: it still fails on errors
that share factors with it. Adding a second mechanism with a different failure
mode (re-execution) buys more than making one mechanism bigger.

**Why not just use TMR everywhere?**
Because it costs 3.29× the area, and most systems cannot afford to triple their
compute. The entire research question is what fraction of TMR's protection you
can get for a small fraction of its cost. The answer here: 92% of the coverage
for 23.5% area — but you pay in timing instead.

**Why is the controller assumed fault-free? Isn't that cheating?**
It would be, if the controller were large. The measurement in §9.5 is the answer:
it is 1.9% of the design, so you can triplicate *it* for under 4% overall. The
assumption is not "faults do not happen there", it is "protecting there is so
cheap you may as well".

**Why does the protected design fail timing when TMR does not?**
Because the ECC decode is inside the accumulator feedback loop, and TMR's voting
is not in a loop at all. Depth in a loop is much more expensive than depth
elsewhere, because you cannot pipeline it away without changing what the circuit
computes.

**Are the fault rates realistic?**
No, deliberately. Real soft-error rates are far lower — you would wait a very
long time to see anything at 1 fault per 30 cycles. The campaign accelerates the
rate to make the comparison measurable in reasonable time, exactly as accelerated
life testing does. What it does *not* do is model the true rate, so nothing here
converts to a FIT figure. That would need device data and is a separate project.

---

## 14. Reading the code

A few things in this repository look unusual if you have only seen software.

**Saboteurs are just XOR.** The entire fault-injection mechanism is
`value ^ inject`. When `inject` is zero this is the identity, and synthesis
removes it entirely if the port is tied off — so a design can carry injection
ports for testing and cost nothing in production. That is why the campaign and
the shipping design are the same RTL.

**The residue tree is a reduction.** `rtl/res3.v` builds a binary tree of small
mod-3 adders. The awkward-looking part:

```verilog
wire [1:0] lvl [0:LG][0:P-1];
```

is a two-dimensional array — `lvl[level][node]` — holding every intermediate. The
generate loop wires level `l` into level `l+1`. Verilator warns that this looks
circular, because its dependency analysis works per-array rather than per-element
and cannot see that data only ever flows one way. The lint exception in that file
is a deliberate, commented decision, not a suppressed warning.

**Hamming positions are computed at elaboration.** `rtl/secded.v` contains
functions that loop over codeword positions to build masks. Those loops run when
the design is *elaborated*, not when it runs — the result is a constant that
becomes fixed wiring. This is how you write parameterised structural code
without hand-listing 48 XOR terms.

One portability note: an earlier version wrote `pos_of(d)[5:0]`, taking a
bit-select of a function result. Verilator accepts that (it is SystemVerilog);
Yosys does not parse it. Declaring the function to return `[5:0]` directly fixed
it. When a design must pass through several tools, the intersection of what they
accept is smaller than any one of them.

**Segmented arithmetic appears twice.** In the datapath, to keep lanes
independent. In the on-demand controller, to break a window counter. The pattern
— compute in blocks, gate the carry between them — is worth recognising.

---

## 15. What to take away

**On faults.** Bits flip for physical reasons, and the important distinction is
not "did it fail" but "did it fail *silently*". Everything in functional safety
follows from that.

**On protection.** Different mechanisms have different blind spots, and that is
their most important property. Residue mod 3 is blind to errors divisible by 3.
ABFT location is blind when the error is a high power of two. TMR is blind to two
faults in the same bit position. Stacking mechanisms with *different* blind spots
buys far more than enlarging one of them — which is why detection plus
re-execution beats a bigger modulus.

**On cost.** Protection is never free, but it is often not expensive where you
expect. Here the area cost was modest (+23.5% against TMR's +213%) and the real
cost was **timing**, because the correction sits in a feedback loop. Look for the
axis nobody is quoting.

**On measurement.** Two metrics failed in this project before producing anything
useful. A saturating SDC-per-trial metric made all schemes look equally bad. A
symmetric controller threshold made adaptivity look useless. Both were fixed by
noticing the measurement was wrong rather than concluding the design was.

**On honesty.** The most valuable results here contradicted the design:
adaptivity does not beat a well-chosen fixed level, running unprotected is never
worth it, ABFT cannot locate the errors that matter most, and inexactness does
not buy robustness. A negative result you can explain is worth more than a
positive result you cannot.

### Why any of this matters outside this repository

Safety-critical machine learning is the concrete case. Cars, aircraft and medical
devices increasingly run neural networks, and the standards those industries work
to were written for systems whose failure modes could be enumerated. A network
that silently misclassifies because a cosmic ray flipped an accumulator bit is
exactly the failure mode ISO 26262 is designed to bound, and the FT-CNN numbers
in §1.2 say current hardware does not bound it well enough.

Data centres are the other case, at the opposite scale. When you operate millions
of machines, an event with a one-in-a-billion hourly probability happens
constantly, and the industry has spent the last few years discovering that silent
corruption at scale is a real and expensive problem rather than a theoretical one.

There is a third reason, less obvious. Reliability is what lets you be
*aggressive* elsewhere. If you can detect and recover from errors cheaply, you
can run at a lower voltage, or a higher clock, or with less timing margin, and
claw back the energy you spent on checking. That is the DeSyRe argument in its
strongest form: reliability is not only insurance, it is a budget you can spend.

### The pattern worth generalising

Three separate times in this repository, a check based on modular arithmetic
turned out to be blind precisely when **the error shared a factor with the
modulus**:

- residue mod 3 misses errors divisible by 3;
- ABFT location mod 2⁴⁸ fails when the error is a high power of 2;
- and in the datapath repository, a rewrite valid over the integers fails when a
  sum wraps mod 2^w.

Same mathematics, three different levels of the stack. Once you have seen it, you
know what question to ask of any checksum: *what does it share a factor with?*

### Glossary

| term | meaning |
|---|---|
| **ABFT** | algorithm-based fault tolerance; checksums over an algorithm's data |
| **accumulator** | register holding a running total |
| **coverage** | fraction of faults not resulting in silent corruption |
| **DED** | double error detection |
| **ECC** | error-correcting code |
| **FIT** | failures in time; failures per 10⁹ device-hours |
| **hard fault** | permanent physical failure |
| **Hamming code** | code whose syndrome names the faulty bit |
| **hysteresis** | reacting quickly one way and slowly the other, to avoid oscillation |
| **IEC 61508 / ISO 26262** | functional-safety standards, general and automotive |
| **lockstep** | two processors running identical work and comparing |
| **masked** | a fault that occurred but did not change the answer |
| **modulus** | the `n` in "mod n" |
| **parity** | one bit making the count of 1s even |
| **residue** | remainder after division |
| **saboteur** | an input whose purpose is to inject a fault |
| **SDC** | silent data corruption — wrong and undetected |
| **SEC-DED** | single error correction, double error detection |
| **SEU** | single-event upset; a bit flipped by a particle strike |
| **soft error** | transient fault; nothing is permanently broken |
| **syndrome** | the pattern of failed checks, used to locate an error |
| **TMR** | triple modular redundancy; three copies and a majority vote |
| **transient** | a fault lasting one moment rather than permanently |

### Running it yourself

Needs Verilator, Yosys with ABC, SymbiYosys and z3 (all in the OSS CAD Suite),
plus Python with numpy and matplotlib for the analysis.

```bash
# the protection algebra, before any hardware
python3 model/protect.py       # residue and SEC-DED, proved
python3 model/robustness.py    # does inexactness buy robustness

# fault-free correctness: protection must not change the answer
verilator --binary --timing -sv rtl/adders.v rtl/mpmac.v rtl/res3.v \\
  rtl/secded.v rtl/mpmac_prot.v tb/dut_wrap.v tb/tb_mpmac.v \\
  --top-module tb_mpmac -o sim -DDUT=dut_prot \\
  -Wno-DECLFILENAME -Wno-TIMESCALEMOD -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND
./obj_dir/sim

# the injection campaign, 16,000 trials
verilator --binary --timing -sv rtl/adders.v rtl/mpmac.v rtl/res3.v \\
  rtl/secded.v rtl/mpmac_prot.v tb/tb_campaign.v \\
  --top-module tb_campaign -o camp -DDUT=mpmac_prot \\
  -Wno-DECLFILENAME -Wno-TIMESCALEMOD -Wno-WIDTHTRUNC -Wno-WIDTHEXPAND
./obj_dir/camp        # swap -DDUT=mpmac_unprot for the baseline

# overhead
./sweep_prot.sh       # protected vs unprotected vs TMR
./sweep_ondemand.sh   # how small is the fault-free island
./sweep_abft.sh       # does ABFT amortise with array size

# proof that the rebuilt accumulate path is equivalent
cd formal && sby -f equiv_acc.sby
```

### Where to look next

| file | what it holds |
|---|---|
| `model/protect.py` | residue and SEC-DED algebra, proved before any RTL |
| `model/robustness.py` | the bit-flip damage study |
| `rtl/res3.v` | mod-3 residue trees |
| `rtl/secded.v` | Hamming SEC-DED encode and decode |
| `rtl/mpmac_prot.v` | the protected datapath, its baseline, and TMR |
| `rtl/mpmac_ondemand.v` | the fault monitor and the three protection levels |
| `rtl/pe_array.v` | the PE array with ABFT checksum rows |
| `tb/tb_campaign.v` | the injection campaign |
| `tb/tb_damage.v` | containment measured on the RTL |
| `DESIGN.md` | every result with its caveats |
| `results/` | campaign output, plots, and the scripts that draw them |

And in the companion repositories: `multiprecision-datapath` builds and verifies
the datapath being protected here, and `fault-injection-harness` is the smallest
possible working example of a saboteur — a good place to start if any of the
above felt like a lot at once.
