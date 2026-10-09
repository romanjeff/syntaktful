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

Three ways forward, in the order they're being pursued:

1. **Check whether MAIN OS (the first ColdFire) reads the FPGA's
   already-summed stereo output back**, for metering, master FX, or the
   analog-overdrive control path. If so, that buffer — not anything on the
   synth-engine chip — is the real analog of Digitakt's `0x8000ea70`, and
   the whole chain above ports with no real change, just a relocated hook.
   **Chosen direction, in progress**, now sharpened by a concrete,
   architecturally-forced target: the intended final hook point is the
   *post-mix* signal — the same stream that reaches the main DAC and
   Overbridge/USB. USB audio-out cannot exist without software packaging
   real digital samples into outgoing packets, so whatever buffer feeds
   Syntakt's USB audio feeder necessarily *is* the true master mix,
   regardless of how the FPGA's internal summing or the analog-overdrive
   stage work internally — any upstream analog summing has to be folded
   back into one digital stream before it can reach USB or the DAC. There
   is direct precedent for exactly this shape, on a sibling product in the
   same ColdFire family: Modded-Cycles' own notes on the Model:Cycles
   document a USB feeder loop whose copy source is explicitly labeled
   "mix stéréo" (stereo mix) in their research. Tracing Syntakt's own USB
   audio driver backward to its feeder's copy source is now the leading
   approach, ahead of a more general FPGA-bridge-read search. This keeps
   the project using the same proven approach that works on Digitakt mk1
   rather than reinventing anything, and sidesteps the FPGA/bitstream
   question entirely if it pans out — the instinct behind the choice is
   "don't guess at FPGA internals if there's a software readback path that
   already does the same job."
2. **Compute the detector from a local software pre-sum, apply the result
   as a uniform per-track gain multiplier before the FPGA handoff.** This
   does **not** require reconstructing or modifying the FPGA bitstream, and
   that's a hard constraint for this project regardless of how promising
   any approach looks — the FPGA image is effectively a black box we don't
   want to be in the business of resynthesizing. The reasoning that makes
   this viable without touching it: if the FPGA's per-track gain/pan stage
   is linear (near-certain for a hardware mixer), a *uniform* gain
   multiplier applied to all 8 per-track buffers before an unmodified FPGA
   mixdown is mathematically identical to applying that same multiplier to
   the final stereo sum after mixdown — the scalar commutes through a
   linear mix regardless of each track's own gain/pan weighting. The
   detector would run on a local pre-sum used only to derive the gain
   value (never written anywhere, never fed back to the FPGA); the FPGA
   keeps doing exactly what it already does, just on pre-scaled inputs.
   **Real, documented caveat, not hypothetical:** Modded-Cycles' own public
   research on this same hardware family found that "the internal mix can
   saturate, creating inter-track interaction" — if the FPGA's summing
   isn't perfectly linear near clipping, a pre-scale diverges slightly from
   true post-mix compression right at the loudest moments. Narrow, but
   real — and testable cheaply in Modded-Cycles' Unicorn emulator before
   ever touching hardware. Held as the fallback if (1) comes back negative.
3. **Look for a loopback path** on either chip that reads the FPGA's output
   back for the analog-overdrive stage specifically (known to have at
   least a partly real analog signal path via an SSI2164 VCA chip). Worth
   a look regardless of (1)'s outcome, since it's cheap once the
   bridge-read search technique already exists.

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
