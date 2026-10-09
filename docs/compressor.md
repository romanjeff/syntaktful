# Master compressor port — status

## Goal

Port Digitone II's style of master compressor into Syntakt, as a mixer-menu
page (like Digitakt mk1's own Compressor row), not an FX-block feature:
master-out insert only, fixed position, no pre/post placement menu. Syntakt
already routes tracks into its FX block separately, and a placement choice
on top of that was judged to add UI complexity without real benefit.

Sidechain filter is LP/HP switchable (matching Digitone II's real behavior)
rather than LP-only (which is what Digitakt mk1's own filter turned out to
be, once decompiled — see below).

## Why Digitakt mk1, not Digitone II, is the design reference

Digitone II's compressor runs on its **SHARC** DSP chip, not its ColdFire —
confirmed by measuring that no ColdFire code anywhere in its MAIN OS reads
back the compressor's mirror slots beyond the same generic one-way
frame-builder write used for every other FX category, and corroborated by a
hardware-probed SPI "gain reduction" readback that tracks compressor
on/off state live. A completely different ISA, needing a completely
different toolchain — not useful as an implementation template for Syntakt,
even though its control-plane *menu* (Threshold / Sidechain Src / Sidechain
Filter) is the right vocabulary to match on the UI side.

**Digitakt mk1 has no SHARC and no FPGA at all** — its compressor must be,
and is, ordinary ColdFire software. Its MAIN OS contains the identical
parameter vocabulary (`Compressor`, `Sidechain Src`, `Sidechain Filter`,
`Threshold`) with zero `SHARC` references anywhere. This makes it the
correct architectural relative to reason from for Syntakt's *digital*
compressor math, independent of where in Syntakt's own split architecture
that math ends up needing to live.

## Digitakt mk1's compressor, fully mapped (design reference)

Found via a community mod lead: [`digi1_mods`](https://github.com/gdeo607/digi1_mods)'s
`digieq` mod documents Digitakt's stock master-pages menu order
(Compressor → EQ → Internal Mixer) and a verified master-bus hook at
`0x400721e6` — the instruction that spreads the final master mix
(`0x8000ea70`, 32 frames × {L,R} 32-bit samples) to the outputs. Tracing
backward from that hook (the function immediately preceding it,
`FUN_40071c20`, 1732 bytes) gave the full compressor signal chain:

| Stage | Function | What it does |
|---|---|---|
| Sidechain filter | `FUN_40073654` | Table-driven two-state-pair biquad/SVF. A mode byte was hypothesized to switch its output tap between HP and LP shapes — **decompiled fully, and this turned out to be wrong**: the mode byte gates an unrelated shared buffer, not an HP/LP tap at all. Digitakt's own filter is LP-only. |
| Threshold/Ratio storage | `FUN_40073c00` | Squares and clamps the threshold field (an energy term); small-enum ratio lookup. |
| **Gain computer** | `FUN_4007425e` | Peak detect (fast-abs `(x>>31)^x`, L/R max, floor-clamp) → log2 → compare against threshold → ratio-scaled gain delta → limiter/peak-hold clamp. Textbook log-domain feedforward gain computation. |
| **Dual-rate envelope** | `FUN_40071b86` | Two coefficients (attack/release) applied via a `btst`-interleaved pair of EMAC `msac.l` chains on the same accumulator. |
| Makeup gain / dry-wet mix | `FUN_400718ea`, `FUN_40071934` | Simple one-pole/scale stages. |

This is a standard, fully implementable topology: sidechain filter → peak
detector → log-domain threshold compare → ratio-scaled gain delta →
dual-rate (attack/release) smoothing → gain applied to signal. Nothing
exotic about the math itself.

## The LP/HP sidechain filter is a genuine Syntakt-original addition

Since Digitakt's own filter doesn't gate LP/HP at all (above), the
LP/HP-switchable sidechain filter in Syntakt's draft is **new work, not a
port of anything Digitakt or Digitone II actually does** — implemented as
a standard trapezoidal state-variable filter (two integrator states,
ramped resonance/cutoff coefficients), with the lowpass tap and a
complementary highpass tap (`dry_input − lowpass`) computed from the same
filter state. This is explicitly documented as original, not misattributed
to either reference device.

## Current draft

[`research/syntakt_comp_draft.s`](../research/syntakt_comp_draft.s) —
`compressor_run(int32 *buf)`, 32-frame block convention, written against
Syntakt's own addresses once they're confirmed. Implements the chain above
plus the LP/HP addition. EMAC-audited: every `mac.l`/`msac.l` site has an
explicit accumulator clear (ColdFire's fractional EMAC mode does not
auto-clear between chains — a systemic bug class found and fixed across
every site in this file, not just the one it was first noticed at).

**This file ships no Elektron firmware bytes** — it's entirely original
code that calls firmware routines by address, consistent with the
"ship no firmware bytes" convention every community modding framework in
this space follows (see [`framework-integration.md`](framework-integration.md)).

**Known incomplete:** the register-save frame size at the top of the
function is deliberately left wrong (`-8(%sp)` instead of the correct
`-40(%sp)`) as an explicit flag for the next pass — this must be
re-derived against the real hook site's actual register needs once that
site is confirmed (see below), not silently "fixed" with a guess.

## Open question: where does this actually hook in?

This is the one real unresolved design question, and it's more
fundamental than it first appeared.

The working assumption — carried over from Digitakt's architecture —was
that Syntakt's second ColdFire (the synth engine chip) builds a summed
stereo master buffer in software, the same way Digitakt's single ColdFire
does at `0x8000ea70`. **Tracing the second chip's actual audio ISR all the
way to its output disproved this.** Each of the 8 tracks stays in its own
128-byte render slot through the entire chain; immediately after the last
per-track stage runs, the *raw pointer to the per-track buffer* (not a sum)
gets written directly into an FPGA bridge register. The 8-track mixdown —
gains, pans, the actual stereo sum — happens inside the Spartan FPGA, in
hardware. There is no software master buffer on that chip to hook.

**Decided, 2026-10-09: per-track pre-scale, applied on the second ColdFire
before the FPGA handoff.** Here's how the investigation actually went:

1. **Checked whether MAIN OS (the first ColdFire) reads the FPGA's
   already-summed stereo output back.** **Found:** a real interrupt handler
   (`0x40101bae`, full register + EMAC context save/restore, ends `rte`)
   reads a fixed FPGA bridge window (`0x80001800`, ping-ponged ±0x400,
   2048-byte wrap) — 32 stereo frames, the family's standard block size —
   rescales each sample and writes the de-interleaved result to
   `0x45511108`/`0x4551110c` (L/R), then calls Syntakt's USB audio feeder
   directly on that buffer. Found by tracing the USB feeder backward from
   its copy source, with direct precedent from the sibling Model:Cycles
   (whose own USB feeder source is labeled "mix stéréo" in independent
   public research). **But a follow-up check found this is very likely
   USB-only:** MAIN OS has zero traffic to its own on-chip audio-serial
   (SSI0) or I2C0 peripherals — a real negative, cross-validated against
   neighboring peripherals (SPI, USB, eDMA) that *are* heavily used in the
   same image. The most consistent explanation is that the FPGA forks the
   summed mix two ways in hardware: one copy straight to the Cirrus codec
   (never touching either ColdFire), one copy into this bridge window
   purely so MAIN OS can relay it over USB. A compressor inserted only
   here would affect Overbridge/USB and silently leave the main outputs
   untouched — not acceptable for a master compressor.
2. **Considered a software-controllable analog VCA as a true post-fork
   insert point — investigated and ruled out.** Syntakt's hardware teardown
   confirmed an SSI2164 (dual-channel VCA) chip exists on the board. The
   hypothesis was that if MAIN OS could drive it directly, that would be
   genuine analog-domain gain control reaching the real outputs after any
   digital fork, with none of the pre-scale's detector/saturation
   approximations. **This turned out to rest on an unjustified inference:**
   the teardown only established that the chip exists and that real analog
   hardware is present on the board — it never placed it on the master bus
   or the overdrive stage. Syntakt actually has 8 digital voices **and 4
   dedicated analog voices** (the same architectural family as Analog
   Rytm), and a dual-channel VCA is far more likely doing standard
   per-voice amplitude/envelope shaping on those 4 analog voices
   specifically. This isn't just a confidence problem — it's structurally
   disqualifying even in the best case: a per-analog-voice VCA could only
   ever reach 4 of Syntakt's 12 voices. The 8 digital voices sum entirely
   inside the FPGA and never pass through any analog VCA circuitry. A
   master compressor has to affect everything, so this angle can't deliver
   that regardless of how controllable the chip turns out to be. A
   follow-up check against the real SSI2164 datasheet closed it further:
   it's a **quad** VCA (not dual) with **no digital control protocol at
   all** — each of its 4 channels is set by a pure analog control voltage
   on a dedicated pin, so there was never going to be an "SSI2164 command"
   to find in MAIN OS's code in the first place, independent of the
   scope problem above.
3. **Landed on per-track pre-scale** — computing the detector from a local,
   unweighted pre-sum of the 8 per-track buffers (on the second ColdFire,
   right before the FPGA handoff), and applying the resulting gain as a
   uniform multiplier to all 8 buffers before the FPGA ever sees them.
   This does **not** touch the FPGA bitstream — a hard constraint for this
   project regardless of how any other approach pencils out. The reasoning
   that makes it valid: if the FPGA's per-track gain/pan stage is linear
   (near-certain for a hardware mixer), a uniform multiplier commutes
   through a linear mix identically whether applied before or after
   summing — the scalar reaches the output the same either way, on both
   of whatever the FPGA forks it to. **Accepted, not resolved, tradeoff:**
   this is only exactly equivalent to true post-mix compression under that
   linearity assumption, and Modded-Cycles' own research on this hardware
   family found the internal mix *can* saturate — exactly the regime where
   "glue"-style compression does its most audible, characterful work. A
   pre-scale turns tracks down before they hit that saturation, which is a
   genuinely different result than letting the real mix saturate and
   turning the result down afterward, not just a rounding error. Jeff's
   call, explicitly weighing this tradeoff: proceed anyway rather than
   pursue a third round of hook-point verification. Worth validating in an
   emulator (see [`ROADMAP.md`](../ROADMAP.md), M5) before trusting it on
   real hardware. The draft in
   [`research/syntakt_comp_draft.s`](../research/syntakt_comp_draft.s) has
   been rewritten for this hook model: no buffer argument, a single-channel
   (not stereo) sidechain filter since there's no stereo signal this early
   in the chain, and an output stage that applies one collapsed dry/wet+
   gain scalar to all 8 track buffers per frame.

Already known and *not* the answer: the menu-insertion mechanism for a new
"Compressor" row (hooking right before Syntakt's existing "Internal Mixer"
row-build at `0x40194cae`, using the identical technique Digitakt's
`digieq` mod already validated on hardware) is solved and unaffected by
this question — it's purely the DSP hook point that's open, not the UI.

## Parameter storage

Not yet decided: a freestanding state struct (simpler, but loses
integration with Syntakt's existing p-lock system) versus continuing to
trace the native group → parameter lookup mechanism (more consistent with
how every other Syntakt parameter works, uncertain remaining effort). Held
open pending the DSP-hook question above, since the answer may change what
"native" storage even looks like on whichever chip ends up owning this.
