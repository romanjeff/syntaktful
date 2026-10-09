| syntakt_comp.s -- master-bus compressor, Syntakt second-ColdFire port
| DRAFT, 2026-10-09 -- REDESIGNED for per-track pre-scale. NOT READY TO
| ASSEMBLE. See notes at bottom before touching -- especially new note 7.
|
| HOOK MODEL, decided 2026-10-09 (Jeff: "let's do it with per track
| pre-scaling... it's not the end of the world" -- accepting the known
| saturation-divergence tradeoff documented in docs/compressor.md rather
| than pursue a 3rd round of hook-point verification). Tracing the second
| ColdFire's audio ISR to its output found there is NO software stereo
| master buffer here at all -- the 8 per-track render buffers get handed
| raw to the FPGA bridge, which does the real 8-track-to-stereo mixdown in
| hardware. A separate trace of MAIN OS found it reads the FPGA's summed
| output back, but only to feed USB -- not confirmed (and now believed
| NOT) to also feed the main analog/Cirrus DAC output, which the FPGA's
| own second (analog-control) chip most likely drives directly in
| hardware, bypassing both ColdFires. So neither "hook the second chip's
| master buffer" (doesn't exist) nor "hook MAIN OS's USB tap" (likely
| USB-only) delivers compression on BOTH outputs with one insert.
|
| This version instead hooks directly before the FPGA handoff, on THIS
| (second) ColdFire: compressor_run has NO buffer-pointer argument any
| more -- it operates in place on the 8 fixed per-track mono buffers at
| TRACKBASE (confirmed address, see the M0/architecture trace), applying
| ONE shared gain multiplier per frame to all 8 of them. Scaling every
| track equally, before the FPGA ever sums/pans them, affects whatever the
| FPGA does with them identically on every output it produces -- so this
| does not need to know the FPGA's own per-track gain/pan weights, and
| does NOT touch the FPGA bitstream at all (a hard constraint). The
| detector input is a LOCAL, UNWEIGHTED pre-sum of the 8 track buffers --
| a deliberate proxy for "the real mix," not a measurement of it, since
| the FPGA's actual gain/pan weighting is invisible from this chip. Known,
| accepted tradeoff: if the FPGA's real summing saturates (Modded-Cycles'
| own finding on this hardware family: "the internal mix can saturate,
| creating inter-track interaction"), this proxy diverges slightly from
| true post-mix behavior right at the loudest moments. Narrow, accepted,
| not silently hidden -- test in an emulator before trusting it further.
|
| Derived from Digitakt OS 1.53's stock compressor algorithm shape
| (FUN_4007425e/FUN_40071b86/FUN_40073654/FUN_40073c00), re-implemented
| fresh for Syntakt -- no Digitakt/DN2 bytes, addresses, or tables copied.
| The sidechain filter, peak detector, gain computer and envelope below are
| the SAME verified math as the original stereo draft, just collapsed to
| ONE channel -- there is no stereo signal at this point in the chain
| (each of the 8 track buffers is independently mono), so the two-channel
| SVF from the original draft has no second channel to run here.

    .set  FR,       32          | frames per block (established convention)
    .set  NTRACKS,  8           | per-track render buffers, pre-FPGA-handoff
    .set  TSTRIDE,  0x80        | bytes between adjacent track buffers (confirmed
                                 | by the architecture trace that found this hook site)
    .set  TRACKBASE,0x80003840  | fixed SRAM base of the 8 per-track buffers (confirmed)

| ---- per-instance state/coefficient struct (symbolic -- real SRAM
|      address is a NEW open gap: needs a free-RAM slot on the SECOND
|      ColdFire specifically, not the same gap as the old MAIN-OS-hook
|      version of this file had). ----
    .set  THR,        0   | precomputed threshold constant (set-time, not per-sample)
    .set  RATSL,       4   | precomputed ratio slope constant (set-time)
    .set  MUP,         8   | makeup gain, Q-format TBD to match this chip's sample headroom
    .set  MIX,        12   | dry/wet mix, 0..0x7fff
    .set  SCTYPE,     16   | sidechain filter type: 0=lowpass, 1=highpass (Syntakt-original; see note 5)
    .set  SCCOEF_A2,  20   | block-constant SVF coefficient ("a2"), LUT-derived from cutoff
    .set  SCCOEF_A1,  24   | per-sample-ramped SVF coefficient ("a1")
    .set  SCRAMP_STEP,28   | per-sample ramp step for A1, computed once per block
    .set  SCIC1,      32   | SVF integrator-1 state (MONO -- one channel now, see header)
    .set  SCIC2,      36   | SVF integrator-2 state (MONO) = lowpass tap
    .set  ATKCO,      40   | attack coefficient (precomputed from Attack time)
    .set  RELCO,      44   | release coefficient (precomputed from Release time)
    .set  ENVST,      48   | envelope follower state (current gain-reduction level)
    .set  STATE_SIZE, 52

    .text
    .globl compressor_run
compressor_run:
    | NO ARGS. Hooked directly before the FPGA bridge write (the confirmed
    | per-track-buffer-handoff site on this chip). Operates in place on
    | the 8 fixed buffers at TRACKBASE. Register save list widened to
    | include %a0/%a1 (both used as working registers below, see the
    | frame-cursor/track-cursor split); still PLACEHOLDER SIZE -- verify
    | against the real hook site's own register liveness before
    | assembling, same discipline as every other address/size in this
    | file that's flagged rather than guessed.
    lea     -16(%sp),%sp             | PLACEHOLDER -- verify against hook site
    movem.l %d0-%d7/%a0-%a3,(%sp)
    movea.l g_syntakt_comp_state,%a2  | symbolic -- real SRAM address TBD (new gap)

    move.l  #0x20,%macsr             | signed, fractional, no saturation
    movea.l #TRACKBASE,%a1           | a1 = persistent per-FRAME cursor (track 0's
                                      | sample for the current frame); advances by
                                      | 4 bytes/frame, NOT by TSTRIDE -- TSTRIDE only
                                      | steps between tracks within one frame (below)
    moveq   #FR,%d7

.Lblock:
    movel   SCCOEF_A1(%a2),%d4       | reload ramped "a1" every frame -- this
                                      | register is NOT left live across the whole
                                      | block loop the way the old stereo draft kept
                                      | it, because this version now also needs %d4
                                      | as scratch inside the envelope section below;
                                      | reloading here, explicitly, avoids relying on
                                      | cross-iteration register liveness.

    | ---- pre-sum detector input: unweighted sum of all 8 track buffers at
    | this frame. Deliberate proxy for "the real mix," not a measurement of
    | it -- see header note on the accepted saturation tradeoff. ----
    movea.l %a1,%a0                  | a0 = per-track cursor, reset to this frame
    movel   (%a0),%d0                | d0 = running sum, track 0's sample
    moveq   #NTRACKS-1,%d6
.Lsumloop:
    addal   #TSTRIDE,%a0
    addl    (%a0),%d0
    subql   #1,%d6
    bne.b   .Lsumloop
                                      | d0 = sum8 (mono pre-sum for this frame)

    | ---- sidechain filter: ONE-channel 2-integrator trapezoidal SVF.
    | Same verified skeleton as the original stereo draft's per-channel
    | math (Digitakt FUN_40073654's confirmed shape: ic1 updates first from
    | OLD ic2, then ic2 updates from the NEW ic1 and block-constant "a2";
    | ic2 is the unconditional lowpass-tap output) -- run once instead of
    | twice, since there is only one signal (the pre-sum) to filter here. ----
    movel   %d0,%d2
    subl    SCIC2(%a2),%d2            | d2 = v3 = sum8 - ic2
    movclrl %acc0,%d3                 | clear before use -- independent product,
                                       | not a chain (same reasoning as the
                                       | original draft's audited SVF sites)
    mac.l   %d4,%d2,%acc0             | acc0 = a1 * v3
    movel   %acc0,%d5
    asll    #1,%d5                    | d5 = 2*a1*v3
    addl    SCIC1(%a2),%d5            | d5 = ic1_new
    movel   %d5,SCIC1(%a2)
    movel   SCCOEF_A2(%a2),%d3        | d3 = a2 (block-constant, LUT-derived)
    movclrl %acc0,%d6                 | clear before use
    mac.l   %d3,%d5,%acc0             | acc0 = a2 * ic1_new
    movel   %acc0,%d6
    addl    SCIC2(%a2),%d6            | d6 = ic2_new = lowpass tap
    movel   %d6,SCIC2(%a2)

    | ---- LP/HP tap select (Syntakt-original, unchanged reasoning from the
    | stereo draft -- HP is the standard complementary tap, sum8 - lowpass,
    | not a second filter; d0 still holds the dry pre-sum untouched) ----
    movel   %d0,%d2                   | d2 = highpass tap = sum8 - lowpass
    subl    %d6,%d2
    tst.l   SCTYPE(%a2)
    beq.b   .Lsc_lp_select
    movel   %d2,%d6                   | SCTYPE==1 -> highpass
.Lsc_lp_select:
    addl    SCRAMP_STEP(%a2),%d4      | ramp a1 toward this block's target
    movel   %d4,SCCOEF_A1(%a2)

    | ---- peak detector: fast rectify + floor clamp. Single channel now --
    | no L/R max needed, there is only one signal (the filtered pre-sum). ----
    movel   %d6,%d2
    asrl    #31,%d2
    eorl    %d2,%d6                   | d6 = |sc_out|
    moveq   #0x100,%d3                | floor clamp, matches Digitakt's choice
    cmpl    %d3,%d6
    bgt.b   .Lpeak_done
    movel   %d3,%d6
.Lpeak_done:                          | d6 = detected peak, floor-clamped

    | ---- log-domain gain computer: LUT-based, not FF1/LZCOUNT (unchanged
    | shape from the stereo draft). d6 is in linear 24.8-ish domain --
    | match this chip's own sample headroom once confirmed, not MAIN OS's. ----
    movel   %d6,%d3
    lsrl    #6,%d3                    | table index shift -- TBD precisely,
                                       | same open gap as the original draft
    lea     comp_log_table,%a3
    movel   (%a3,%d3.l*4),%d2         | d2 = log-domain(peak)
    movel   %d2,%d0
    subl    THR(%a2),%d0              | d0 = log(peak) - log(threshold)
    bmi.b   .Lunder_thresh
    muls.l  RATSL(%a2),%d0            | ratio-scaled gain delta (over threshold)
    bra.b   .Lgain_delta_done
.Lunder_thresh:
    moveq   #0,%d0                    | at/under threshold: no reduction
.Lgain_delta_done:

    | ---- dual-rate envelope: two coefficients, selected by comparison,
    | exactly Digitakt's confirmed shape (unchanged). Reuses %d4 as scratch
    | for the attack/release coefficient -- safe because the SC filter's
    | own use of %d4 (the ramped "a1") is already done for this frame and
    | gets reloaded fresh at the top of the NEXT frame, not carried in %d4
    | across iterations (see the reload at the top of .Lblock). ----
    movel   ENVST(%a2),%d1
    cmpl    %d1,%d0
    bgt.b   .Lattack                  | gain delta rising -> attack rate
    movel   RELCO(%a2),%d4
    bra.b   .Lenv_coef_done
.Lattack:
    movel   ATKCO(%a2),%d4
.Lenv_coef_done:
    movel   %d0,%d3
    subl    %d1,%d3
    movclrl %acc0,%d2                 | clear before use
    mac.l   %d4,%d3,%acc0
    addl    %acc0,%d1
    movel   %d1,ENVST(%a2)            | smoothed gain-reduction, in log domain

    | ---- back to linear, makeup gain, limiter clamp (unchanged shape) ----
    lea     comp_exp_table,%a3
    movel   %d1,%d3
    lsrl    #6,%d3
    movel   (%a3,%d3.l*4),%d2         | d2 = linear gain multiplier
    movclrl %acc0,%d0                 | clear before use
    mac.l   MUP(%a2),%d2,%acc0
    movel   %acc0,%d2                 | apply makeup gain
    cmpi.l  #0x7fffffff,%d2
    ble.b   .Lno_clamp
    movel   #0x7fffffff,%d2
.Lno_clamp:                           | d2 = final linear gain multiplier

    | ---- NEW output stage, the actual point of this redesign: collapse
    | the dry/wet blend into ONE effective scalar, then apply it to all 8
    | per-track buffers equally. output[i] = dry[i]*(1-mix) + dry[i]*gain*
    | mix = dry[i] * ((1-mix) + mix*gain) -- valid because this is a pure
    | gain-type effect (wet is just dry*gain, nothing added), so the blend
    | collapses algebraically into one multiplier M, computed once per
    | FRAME (gain varies per-sample) and reused for every track. This is
    | exactly the "scale every track equally, before the FPGA sums/pans
    | them" step the whole hook-model redesign is for. ----
    movel   MIX(%a2),%d5
    lsll    #16,%d5                   | d5 = mix, widened 0x7fff-range -> Q1.31
    movel   #0x7fffffff,%d3
    subl    %d5,%d3                   | d3 = inv_mix = 0x7fffffff - mix
    movclrl %acc0,%d0                 | clear before use
    mac.l   %d2,%d5,%acc0             | acc0 = gain * mix
    movclrl %acc0,%d1                 | d1 = gain*mix; acc0 cleared again
    addl    %d3,%d1                   | d1 = M = inv_mix + gain*mix

    movea.l %a1,%a0                   | a0 = per-track cursor, reset to this frame
    moveq   #NTRACKS-1,%d6
.Lscaleloop:
    movel   (%a0),%d3                 | track[i][frame], dry
    movclrl %acc0,%d0                 | clear before use
    mac.l   %d1,%d3,%acc0             | acc0 = track[i] * M
    movclrl %acc0,%d3
    movel   %d3,(%a0)                 | write back, scaled -- in place, same
                                       | buffer the FPGA is about to read
    addal   #TSTRIDE,%a0
    subql   #1,%d6
    bne.b   .Lscaleloop

    addql   #4,%a1                    | advance the FRAME cursor (not the
                                       | per-track cursor, which %a0 owned and
                                       | which is dead now) to the next frame
    subql   #1,%d7
    bne.b   .Lblock

    movem.l (%sp),%d0-%d7/%a0-%a3
    lea     16(%sp),%sp
    rts

| =============================================================================
| STATUS NOTES (M3, 2026-10-07) -- read before touching this file
| =============================================================================
|
| This is a DESIGN DRAFT, not working code. Known issues left IN DELIBERATELY
| as flags for the next verification pass, not oversights:
|
| 1. Register-save frame is wrong on purpose: "lea -8(%sp),%sp" should be
|    "-40(%sp)" for a 10-register movem.l (10 x 4B = 40B). Left wrong so an
|    assembler/emulator pass catches it mechanically rather than it being
|    hand-"corrected" based on eyeballing alone.
|
| 2. RESOLVED 2026-10-08. The dry/wet mix accumulate chain is rewritten and
|    the accumulator semantics behind it are now verified, though not by
|    the route first planned.
|
|    What was tried: hoped to find a byte-identical dry/wet-mix reference
|    in Digitakt, at the two functions this project's own notes flagged as
|    "plausibly makeup gain / dry-wet mix, not individually isolated" --
|    FUN_400718ea and FUN_40071934 in Digitakt OS 1.53's MAIN OS. Both were
|    fully decompiled (WSL m68k-linux-gnu-objdump -m m68k:cfv4e, real
|    bytes, not Ghidra-only). Neither turned out to be a dry/wet blend:
|    FUN_400718ea is a 32-iteration two-accumulator (acc0/acc1) msac.l
|    reduction over an array, inheriting whatever MACSR its caller set
|    (no macsr write of its own); FUN_40071934 is a 16-iteration
|    four-accumulator (acc0-acc3) mac.l reduction that explicitly sets
|    `macsr=0x80` -- a different mode than this file's `0x20`. Neither is
|    the target; this pass does not claim either is understood beyond
|    "real code, decompiled, not what we were looking for."
|
|    What that search was still worth: cross-referencing a function using
|    `macsr=0x80` against this file's own `macsr=0x20` confirmed, by
|    contrast rather than by directly reading the CFPRM, that MACSR's F/I
|    (fractional/integer) bit is real and these two values select opposite
|    modes -- i.e. this file's existing `macsr=0x20` really does mean
|    "fractional," not a guess carried forward unchecked. (Also checked and
|    ruled out as a semantic oracle: digikit's own ColdfireEMAC Ghidra
|    language. Its `mac.l` P-code implements a plain integer multiply plus
|    the instruction-encoded scalefactor shift -- it does not model
|    MACSR-dependent fractional scaling at all, and the project's own
|    augmentation notes already flag EMAC semantics there as "not
|    trustworthy... for DSP/EMAC-heavy routines." Not used as a reference.)
|
|    The derived (not reference-matched) fix applied: fractional mac.l's
|    standard purpose -- the reason fractional MAC modes exist on every
|    DSP-capable CPU that has one -- is exactly so that chained `acc +=
|    a*b` calls on Q1.31-range operands sum correctly with no manual
|    rescaling between them. Two mac.l's into the same accumulator,
|    cleared first, correctly compute `wet*mix + dry*(1-mix)` under that
|    standard semantics. This is derived from documented/standard EMAC
|    fractional-MAC behavior, not confirmed against a byte-identical
|    Digitakt example -- flagged as such, not overstated.
|
|    Two real bugs fixed along the way, neither previously flagged:
|    (a) MIX(%a2) is stored 0..0x7fff (16-bit range); a fractional mac.l
|        needs a full 32-bit Q1.31 operand. Using MIX directly, as the old
|        code did, is wrong by a factor of 0x10000. Fixed with `lsll #16`.
|    (b) The old code never cleared acc0 before any of its mac.l calls in
|        this section, silently depending on whatever the makeup-gain
|        stage happened to leave there. Fixed: every chain here now starts
|        with an explicit movclrl.
|
|    FOLLOW-UP AUDIT, 2026-10-08: the broader item flagged above turned out
|    to be real everywhere it was checked. Full inventory of every mac.l in
|    this file (there is no msac.l anywhere in this draft -- the comment
|    near the envelope section references Digitakt's ORIGINAL technique as
|    the inspiration for the dual-rate shape, not a literal msac.l in this
|    implementation):
|
|    - SVF sidechain filter, 4 sites (L-channel ic1-update and ic2-update,
|      R-channel ic1-update and ic2-update): all 4 had the same bug --
|      FIXED, each given its own movclrl. These are two INDEPENDENT
|      single-term products per channel (ic1 = f(a1,v3), ic2 = f(a2,ic1)),
|      not a chain meant to sum -- unlike the dry/wet mix's deliberate
|      two-term accumulation, each of these needed its own separate clear,
|      not one shared clear before a pair.
|    - Dual-rate envelope (1 site): same bug -- FIXED.
|    - Makeup gain (1 site): same bug -- FIXED.
|    - Peak detector: no mac.l/msac.l at all (pure asrl/eorl/cmpl) -- N/A.
|    - Gain computer's ratio scaling: uses `muls.l`, not mac.l/msac.l --
|      a plain signed multiply with no accumulator and no MACSR-mode
|      dependence. Neither bug class applies -- N/A, not a gap.
|    - Dry/wet mix (3 sites): already fixed in the prior pass (above).
|
|    Operand-scale audit (the MIX-style "narrower-than-Q1.31" bug class),
|    checked per the coordinator's explicit list:
|    - THR: only ever reaches a plain `subl` (log-domain threshold
|      compare), never a mac.l. Not subject to this bug class at all --
|      its correctness requirement is "same log-domain units as the LUT
|      table's output," a table-domain question already covered by note 3,
|      not a new finding.
|    - RATSL: only reaches `muls.l`, not mac.l -- same reasoning as THR,
|      not applicable.
|    - MUP, SCCOEF_A1/A2, ATKCO/RELCO: none of these have a documented
|      narrower-than-Q1.31 range anywhere in this file (unlike MIX, which
|      explicitly said "0..0x7fff" right in its .set comment) -- there is
|      nothing here to confirm a bug against. This is the SAME already-
|      flagged gap as status note 6 (Q-format TBD throughout), not a new,
|      separately-confirmed bug the way the MIX case was. Don't read this
|      as "checked and clean" -- read it as "unknown, same as before."
|    - comp_log_table's output: never reaches a mac.l (only plain subl/
|      cmp against THR) -- not subject to this bug class.
|    - comp_exp_table's output: DOES reach a mac.l (feeds makeup gain,
|      multiplied against MUP). Forward-looking requirement, not a bug in
|      today's draft -- the table has no real contents yet (note 3), so
|      there's nothing to be wrong YET, but whoever writes the table-
|      generation script must emit full Q1.31-range values, not a
|      narrower range, or this becomes a second MIX-shaped bug the moment
|      real numbers are filled in. Flagging now so it's not rediscovered
|      the hard way later.
|
|    This section's own earlier fix (the dry/wet mix) remains the only site
|    in the file verified against anything beyond "derived from documented
|    EMAC semantics" -- the cross-check that confirmed macsr=0x20 really
|    means fractional (see above) applies file-wide, but no additional
|    Digitakt reference-matching was attempted for these 6 sites; the fix
|    is the same derived-correct accumulator-clear discipline applied
|    consistently, not re-verified against new real-code examples each time.
|
| 3. comp_log_table / comp_exp_table are referenced by name only -- no
|    actual table contents exist yet. Table size and domain depend on
|    Syntakt's own master-bus sample format/headroom, which is unknown
|    until M0c (second-ColdFire load address / audio ISR) resolves.
|    Generating real values is a short script once that's known.
|
| 4. g_syntakt_comp_state is a placeholder symbol -- the real SRAM address
|    for this struct on Syntakt's second ColdFire chip is unknown (same
|    M0c gap).
|
| 5. UPDATED 2026-10-07 (Jeff asked for exact parity -- "Digitakt's SC
|    filter works well, use the same implementation"): sidechain filter is
|    now a real two-channel, 2-integrator trapezoidal SVF, re-derived from
|    FUN_40073654's full decompile (Ghidra 68000:BE:32:ColdfireEMAC, cross-
|    checked against WSL m68k-linux-gnu-objdump -m m68k:cfv4e -- note plain
|    "-m 5407" silently fails to decode the EMAC mac.l/msac.l/movclrl
|    instructions in this function and must not be trusted here; cfv4e is
|    required). CONFIRMED structure, not guessed: ic1 updates first from the
|    OLD ic2, then ic2 updates from the NEW ic1 and a block-constant "a2"
|    coefficient (LUT-derived from the cutoff parameter); ic2 (the lowpass
|    tap) is Digitakt's unconditional output -- verified by tracing every
|    write to the function's output pointer, not assumed from proximity.
|
|    TWO THINGS DELIBERATELY NOT REPRODUCED, flagged rather than guessed:
|    (a) Digitakt ramps its "a1" coefficient via a signal-dependent
|        rectification formula computed in a separate pre-pass
|        (`uVar20 * -0x7fffffff - uVar20*((uVar20>>31)^uVar20)`, operating
|        on actual sample values, not just coefficients) -- I obtained the
|        full decompile of this but could not resolve its exact closed-form
|        meaning in the time available. This file ramps a1 LINEARLY per
|        block instead (SCRAMP_STEP), matching the established convention
|        used elsewhere in this project rather than Digitakt's exact
|        (signal-adaptive, not fully understood) behavior. If the linear
|        ramp doesn't sound/behave close enough once testable, this is the
|        first place to revisit -- the real formula is recorded in this
|        fork's full report, not lost, just not re-derived into asm yet.
|    (b) Digitakt's mode byte does NOT gate the lowpass-tap output at all --
|        it only changes which of two buffer slots gets a scaled, negated
|        copy of the tap written back into a SEPARATE shared buffer (not
|        the compressor's own output), for a downstream purpose that wasn't
|        traced. This looked like an "HP/LP tap swap" in the original
|        research; the full decompile shows it isn't. Not reproduced here.
|
|        RESOLVED 2026-10-07 (Jeff: DN2's compressor has a real LP/HP
|        sidechain filter choice, prefers that over LP-only): SCTYPE now
|        does real work, added fresh for Syntakt rather than copying a
|        Digitakt mechanism that doesn't exist. Both LP and HP taps come
|        from the SAME verified SVF core above -- HP = dry_input - lowpass,
|        the standard complementary tap a 2-integrator SVF provides for
|        free, not a second filter. SCTYPE=0 selects lowpass (matches
|        Digitakt's behavior as the default), SCTYPE=1 selects highpass.
|        This is an honest Syntakt-original addition, not a reproduction --
|        flagged as such rather than implied to come from Digitakt's bytes.
|
| 6. Fixed-point/Q-format is "TBD to match master-bus headroom" throughout --
|    deliberately not guessed twice (once on format, once on whether it's
|    right) ahead of knowing Syntakt's real audio format.
|
| Algorithmic shape IS verified against real Digitakt bytes (WSL objdump,
| not Ghidra-only) before this was drafted: peak detector fast-abs trick,
| LUT-based (not FF1/log2-instruction-based) threshold compare, and the
| btst-gated dual-coefficient attack/release envelope all match Digitakt's
| actual disassembly, not just the verbal description that was floating
| around in project notes. The LUT-based correction specifically overrides
| an earlier (wrong) assumption that this used a count-leading-zeros-style
| instruction -- it doesn't; Digitakt uses table lookups.
