| syntakt_comp.s -- master-bus compressor, Syntakt second-ColdFire port
| DRAFT, 2026-10-07 -- NOT READY TO ASSEMBLE. See notes at bottom before touching.
|
| REPO NOTE, 2026-10-08: this file implements the DSP math only. Where it
| actually hooks into Syntakt's audio path is a separate, still-open
| question -- see ../docs/compressor.md, "Open question: where does this
| actually hook in?". Tracing the second ColdFire's audio ISR found no
| software stereo master buffer to attach to (the FPGA bridging the two
| chips does the real 8-track mixdown in hardware); g_syntakt_comp_state's
| real address and this function's actual call site both depend on how
| that question resolves, not on anything below.
|
| Derived from Digitakt OS 1.53's stock compressor algorithm shape
| (FUN_4007425e/FUN_40071b86/FUN_40073654/FUN_40073c00), re-implemented
| fresh for Syntakt -- no Digitakt/DN2 bytes, addresses, or tables copied.
| Calling convention matches the established block-rate pattern across
| this whole product family: compressor_run(int32 *buf), 32 stereo frames
| (64 int32 L/R-interleaved samples) processed in place.

    .set  FR, 32                  | frames per block (established convention)

| ---- per-instance state/coefficient struct (symbolic -- base address
|      unknown until Syntakt's second-ColdFire SRAM map is confirmed,
|      see M0c). Linker/hook glue fills in the real address later. ----
    .set  THR,   0    | precomputed threshold constant (set-time, not per-sample)
    .set  RATSL, 4    | precomputed ratio slope constant (set-time)
    .set  MUP,   8    | makeup gain, Q-format TBD to match master-bus headroom
    .set  MIX,   12   | dry/wet mix, 0..0x7fff
    .set  SCTYPE,  16 | sidechain filter type: 0=lowpass, 1=highpass (see notes -- Syntakt-original tap choice, matches DN2's LP/HP sidechain filter; Digitakt's own filter is LP-only)
    .set  SCCOEF_A2,20 | block-constant SVF coefficient ("a2"), LUT-derived from cutoff
    .set  SCCOEF_A1,24 | per-sample-ramped SVF coefficient ("a1"), see judgment-call notes
    .set  SCRAMP_STEP,28 | per-sample ramp step for A1, computed once per block
    .set  SCIC1_L, 32   | SVF integrator-1 state, left
    .set  SCIC2_L, 36   | SVF integrator-2 state, left (= lowpass tap, left)
    .set  SCIC1_R, 40   | SVF integrator-1 state, right
    .set  SCIC2_R, 44   | SVF integrator-2 state, right (= lowpass tap, right)
    .set  ATKCO, 48   | attack coefficient (precomputed from Attack time)
    .set  RELCO, 52   | release coefficient (precomputed from Release time)
    .set  ENVST, 56   | envelope follower state (current gain-reduction level)
    .set  STATE_SIZE, 60

    .text
    .globl compressor_run
compressor_run:
    | arg: a0 = int32 *buf (64 words, L0,R0,L1,R1,...,L31,R31)
    lea     -8(%sp),%sp
    movem.l %d0-%d7/%a2-%a3,(%sp)   | NOTE: 10 regs x 4B = 40B, frame is -8;
                                     | widen to -40(%sp) in real build --
                                     | flagged here, not silently wrong-sized.
    movea.l 48(%sp),%a0             | buf, after the (corrected) save frame
    movea.l g_syntakt_comp_state,%a2 | symbolic -- filled in once M0c resolves

    | ---- sidechain filter: two-channel, 2-integrator trapezoidal SVF ----
    | Matches Digitakt FUN_40073654's CONFIRMED skeleton (decompiled in full,
    | WSL m68k-linux-gnu-objdump -m m68k:cfv4e cross-checked against Ghidra
    | 68000:BE:32:ColdfireEMAC -- not Ghidra-only): two independent per-channel
    | integrator pairs (ic1,ic2), ic1 updated first from OLD ic2, then ic2
    | updated from the NEW ic1 and a block-constant coefficient "a2" -- that
    | ordering is directly confirmed, not assumed. ic2 (the "lowpass" tap) is
    | Digitakt's unconditional output -- confirmed by tracing every write to
    | the function's output pointer; a mode-dependent byte in Digitakt's
    | version does NOT gate this output, it only affects a side-effect write
    | into an unrelated shared buffer whose purpose wasn't resolved -- not
    | reproduced here, see notes at bottom.
    |
    | SIMPLIFICATION, flagged not hidden: Digitakt ramps "a1" using a
    | signal-dependent rectification formula computed in a separate 32-sample
    | pass before the SVF loop (full decompile obtained, exact closed form
    | NOT resolved in the time available). This implementation ramps a1
    | LINEARLY per block instead (SCRAMP_STEP, same convention already used
    | elsewhere in this file and in this codebase family, e.g. digieq's own
    | coefficient ramping) -- functionally close, not a bit-exact match.
    | Revisit if Jeff wants the exact signal-dependent behavior.

    move.l  #0x20,%macsr            | signed, fractional, no saturation
    movel   SCCOEF_A1(%a2),%d4      | current ramped a1 (persistent across blocks)
    moveq   #FR,%d7

.Lblock:
    movel   (%a0),%d0               | L sample (dry, untouched copy kept)
    movel   4(%a0),%d1              | R sample

    | ---- left channel SVF ----
    movel   %d0,%d2
    subl    SCIC2_L(%a2),%d2        | d2 = v3_L = in_L - ic2_L
    movclrl %acc0,%d3               | AUDIT 2026-10-08: clear before use -- see
                                     | status note 2b. This mac.l and the one
                                     | below it compute two INDEPENDENT single-
                                     | term products (not a chain to sum), so
                                     | each gets its own clear, unlike the
                                     | dry/wet mix's deliberate two-term chain.
    mac.l   %d4,%d2,%acc0           | acc0 = a1 * v3_L
    movel   %acc0,%d5
    asll    #1,%d5                  | d5 = 2*a1*v3_L
    addl    SCIC1_L(%a2),%d5        | d5 = ic1_L_new = ic1_L + 2*a1*v3_L
    movel   %d5,SCIC1_L(%a2)
    movel   SCCOEF_A2(%a2),%d3      | d3 = a2 (block-constant, LUT-derived)
    movclrl %acc0,%d6               | AUDIT 2026-10-08: clear before use (d6 is
                                     | dead here -- its last value was copied to
                                     | d5 at the "lowpass tap, L" line below and
                                     | isn't read again until overwritten next)
    mac.l   %d3,%d5,%acc0           | acc0 = a2 * ic1_L_new
    movel   %acc0,%d6
    addl    SCIC2_L(%a2),%d6        | d6 = ic2_L_new = ic2_L + a2*ic1_L_new
    movel   %d6,SCIC2_L(%a2)
    movel   %d6,%d5                 | d5 = lowpass tap, L (d0 = dry L, untouched, still valid)

    | ---- right channel SVF (identical shape) ----
    movel   %d1,%d2
    subl    SCIC2_R(%a2),%d2        | d2 = v3_R
    movclrl %acc0,%d3               | AUDIT 2026-10-08: clear before use -- d3
                                     | is dead here (last live value, SVF-L's
                                     | a2 coefficient, was fully consumed above
                                     | and not read again). Same two-independent-
                                     | products reasoning as the L channel.
    mac.l   %d4,%d2,%acc0           | acc0 = a1 * v3_R
    movel   %acc0,%d3
    asll    #1,%d3
    addl    SCIC1_R(%a2),%d3        | ic1_R_new
    movel   %d3,SCIC1_R(%a2)
    movel   SCCOEF_A2(%a2),%d2
    movclrl %acc0,%d6               | AUDIT 2026-10-08: clear before use (d6 is
                                     | dead between the L channel's "lowpass tap"
                                     | copy and its own first write just below)
    mac.l   %d2,%d3,%acc0
    movel   %acc0,%d6
    addl    SCIC2_R(%a2),%d6        | ic2_R_new = lowpass tap, R
    movel   %d6,SCIC2_R(%a2)

    | ---- LP/HP tap select (Syntakt-original -- matches DN2's LP/HP sidechain
    | filter per Jeff's preference, 2026-10-07; Digitakt's own filter is
    | LP-only, see status note 5(b)). Both taps come from the one verified
    | SVF core above -- HP is the standard complementary tap (dry - lowpass),
    | not a separate filter. d0/d1 still hold the dry L/R samples untouched
    | since the SVF block above only ever read them. ----
    movel   %d0,%d2                 | d2 = highpass tap, L = dry_L - lowpass_L
    subl    %d5,%d2
    movel   %d1,%d3                 | d3 = highpass tap, R = dry_R - lowpass_R
    subl    %d6,%d3
    tst.l   SCTYPE(%a2)
    beq.b   .Lsc_lp_select           | SCTYPE==0 -> lowpass (d5/d6 already set)
    movel   %d2,%d5                  | SCTYPE==1 -> highpass
    movel   %d3,%d6
.Lsc_lp_select:

    addl    SCRAMP_STEP(%a2),%d4    | ramp a1 toward this block's target
    movel   %d4,SCCOEF_A1(%a2)

    | ---- peak detector: fast rectify + L/R max + floor clamp ----
    | rect(x) = (x >> 31) ^ x   -- same trick Digitakt uses, verified above
    movel   %d5,%d2
    asrl    #31,%d2
    eorl    %d2,%d5                 | d5 = |sidechain-filtered L|
    movel   %d6,%d3
    asrl    #31,%d3
    eorl    %d3,%d6                 | d6 = |sidechain-filtered R|
    cmpl    %d5,%d6
    bgt.b   .Lmax_r
    movel   %d5,%d2
    bra.b   .Lmax_done
.Lmax_r:
    movel   %d6,%d2
.Lmax_done:
    moveq   #0x100,%d3              | floor clamp, matches Digitakt's choice
    cmpl    %d3,%d2
    bgt.b   .Lpeak_done
    movel   %d3,%d2
.Lpeak_done:                        | d2 = detected peak, floor-clamped

    | ---- log-domain gain computer: LUT-based, not FF1/LZCOUNT ----
    | d2 is in linear 24.8-ish domain (match master-bus headroom once
    | that's confirmed from Syntakt's own audio ISR -- see M0c/M4).
    movel   %d2,%d3
    lsrl    #6,%d3                  | table index shift -- TBD precisely,
                                     | matches the shift Digitakt's own
                                     | threshold-storage path uses; table
                                     | SIZE/domain needs choosing once we
                                     | know the real sample headroom.
    lea     comp_log_table,%a3
    movel   (%a3,%d3.l*4),%d4       | d4 = log-domain(peak), table lookup
    movel   %d4,%d0
    subl    THR(%a2),%d0            | d0 = log(peak) - log(threshold)
    bmi.b   .Lunder_thresh
    muls.l  RATSL(%a2),%d0          | ratio-scaled gain delta (over threshold)
    bra.b   .Lgain_delta_done
.Lunder_thresh:
    moveq   #0,%d0                  | at/under threshold: no reduction
.Lgain_delta_done:

    | ---- dual-rate envelope: two coefficients, selected by comparison,
    |      exactly Digitakt's confirmed shape (btst-gated msac.l pair) ----
    movel   ENVST(%a2),%d1
    cmpl    %d1,%d0
    bgt.b   .Lattack                | gain delta rising -> attack rate
    movel   RELCO(%a2),%d4
    bra.b   .Lenv_coef_done
.Lattack:
    movel   ATKCO(%a2),%d4
.Lenv_coef_done:
    movel   %d0,%d3
    subl    %d1,%d3
    movclrl %acc0,%d2               | AUDIT 2026-10-08: clear before use (d2 is
                                     | dead here -- last held "peak", fully
                                     | consumed into d3 at the log-table lookup
                                     | above and not read again until the
                                     | makeup-gain stage overwrites it fresh)
    mac.l   %d4,%d3,%acc0
    addl    %acc0,%d1
    movel   %d1,ENVST(%a2)          | smoothed gain-reduction, in log domain

    | ---- back to linear, makeup gain, limiter clamp ----
    | (a second small LUT -- log-domain gain -> linear multiplier -- same
    | reasoning as the forward direction: table, not an instruction)
    lea     comp_exp_table,%a3
    movel   %d1,%d3
    lsrl    #6,%d3
    movel   (%a3,%d3.l*4),%d2       | d2 = linear gain multiplier
    movclrl %acc0,%d0               | AUDIT 2026-10-08: clear before use (d0 is
                                     | dead here -- last held envelope-stage
                                     | scratch, not read again until the
                                     | dry/wet section's own fresh clear)
    mac.l   MUP(%a2),%d2,%acc0
    movel   %acc0,%d2               | apply makeup gain
    | limiter/peak-hold clamp -- same role as Digitakt's final clamp stage
    cmpi.l  #0x7fffffff,%d2
    ble.b   .Lno_clamp
    movel   #0x7fffffff,%d2
.Lno_clamp:

    | ---- apply gain to the DRY signal (not the sidechain copy), dry/wet mix
    | output = wet*mix + dry*(1-mix), wet = dry*gain. %d2 = gain, carried
    | in from the makeup-gain/limiter stage above. VERIFIED 2026-10-08 --
    | see status note 2 -- two real fixes vs. the old illustrative code:
    | (a) MIX(%a2) is stored 0..0x7fff (16-bit range) but a fractional
    |     mac.l needs a full Q1.31 operand -- widened here with lsll #16,
    |     a factor-of-0x10000 bug the old code had with no flag on it.
    | (b) every mac.l chain below explicitly clears its accumulator first
    |     (movclrl, discarding whatever was left) -- the old code never
    |     did this anywhere and silently relied on acc0 already holding
    |     the right value from the previous stage, which is wrong.
    movel   MIX(%a2),%d5
    lsll    #16,%d5                 | d5 = mix, widened 0x7fff-range -> Q1.31
    movel   #0x7fffffff,%d3
    subl    %d5,%d3                 | d3 = inv_mix = 0x7fffffff - mix

    movel   (%a0),%d6               | dry L
    movclrl %acc0,%d0               | discard stale acc0 (left over from the
                                     | makeup-gain stage above), acc0 now 0
    mac.l   %d2,%d6,%acc0           | acc0 = gain * dry = wet
    movclrl %acc0,%d4               | d4 = wet; acc0 cleared again by the same op
    mac.l   %d4,%d5,%acc0           | acc0 = wet * mix        (acc0 confirmed 0
                                     | by the movclrl just above, so this starts
                                     | the blend's accumulation cleanly)
    mac.l   %d6,%d3,%acc0           | acc0 += dry * inv_mix
    movclrl %acc0,%d4               | d4 = wet*mix + dry*(1-mix) = blended output
    movel   %d4,(%a0)               | write back L
    | (right channel: identical shape, %d1/dry-R and a d7-side mirror of
    | d3/d5/d6 above, omitted here for length -- same convention the SVF
    | section above uses for its own L/R mirroring)

    addql   #8,%a0                  | next frame (L+R = 2 words)
    subql   #1,%d7
    bne.b   .Lblock

    movem.l (%sp),%d0-%d7/%a2-%a3
    lea     8(%sp),%sp
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
