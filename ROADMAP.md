# Roadmap

Status as of this writing. Research and a design draft only — no patches
have shipped yet.

## Goal

A master compressor on Syntakt, in the style of Digitone II's, exposed as
a mixer-menu page the way Digitakt mk1's own Compressor row works — a
fixed master-out insert, no pre/post placement menu. Sidechain filter is
LP/HP switchable, matching Digitone II's real behavior (not LP-only, which
is what Digitakt mk1's own filter turned out to be once decompiled).

## Done

- **Hardware architecture resolved.** Two physical ColdFire chips, bridged
  by an FPGA that does the real audio mixdown; a second FPGA for analog
  control; confirmed via community hardware teardown after firmware-only
  analysis couldn't fully settle it. See [`docs/architecture.md`](docs/architecture.md).
- **Second ColdFire's load address and entry point confirmed** — via an
  unexpected but decisive external find: independent public research
  ([Modded-Cycles](https://github.com/18nelli18/Modded-Cycles)) had
  already solved this for an unrelated port, and fully mapped the voice
  engine along with it.
- **Digitakt mk1's full compressor DSP chain mapped** as the design
  reference (sidechain filter → peak detector → log-domain gain compute →
  dual-rate envelope → makeup/mix), with the honest correction that its
  sidechain filter is LP-only, not LP/HP as originally assumed — the
  LP/HP addition is genuinely new work, not a port.
- **A compressor DSP draft written** against that reference, with an
  EMAC-accumulator-clear audit across every `mac.l`/`msac.l` site (a
  systemic bug class found and fixed once discovered at one site).
- **The menu-insertion point for a new "Compressor" row confirmed and
  Gate-F-cleared** — reuses the identical technique Digitakt's `digieq`
  community mod already validated on real hardware.
- **Framework-integration research** — see
  [`docs/framework-integration.md`](docs/framework-integration.md).
  elekloader is the real engine behind Modwerk's existing Digitakt/Digitone
  support; Syntakt is structurally a close match to a device elekloader
  already supports (Digitone mk1's second-CPU/section-7 shape); Modwerk
  has an empty placeholder for Syntakt with no research credited yet.

## In progress

**The real open question: where does the compressor actually hook in?**
Tracing the second ColdFire's audio ISR all the way to its output
disproved the working assumption that it builds a software stereo master
buffer the way Digitakt mk1's single chip does — the 8 tracks stay
unsummed in their own per-track buffers right up until a raw pointer to
them gets handed to the FPGA, which does the real mixdown in hardware.
Three paths, being pursued in this order (see
[`docs/compressor.md`](docs/compressor.md) for full reasoning):

1. Check whether MAIN OS reads the FPGA's already-summed output back for
   metering, master FX, or the analog-overdrive control path — **found**.
   A real interrupt handler reads a fixed bridge window and feeds it
   straight to the USB audio feeder — the real analog of Digitakt's
   software master buffer. **Last open gap:** confirming the main analog
   DAC output shares this same buffer rather than bypassing it via a
   separate hardware-only path — checking now.
2. If not: compute the detector from a local software pre-sum and apply a
   uniform per-track gain multiplier before the FPGA handoff — provably
   equivalent to post-mix compression under a linearity assumption, with
   one known caveat (the internal mix can saturate, per Modded-Cycles'
   own research on this hardware family) that would need validating in an
   emulator before trusting it. **Does not require touching the FPGA
   bitstream** — that's a hard constraint for this project regardless of
   how any approach otherwise pencils out.
3. Look for a loopback path specific to the analog-overdrive stage, which
   is known to have at least a partly real analog signal path.

Parameter storage (a freestanding struct vs. tracing Syntakt's native
group → parameter lookup) is held open until the hook-point question
above is resolved, since the answer may change what "native" storage even
means on whichever chip ends up owning this.

## Not yet started

- **Emulator validation.** [Modded-Cycles' Unicorn-based emulator](https://github.com/18nelli18/Modded-Cycles)
  (`tools/emu/stengine.py`, verified sample-accurate against real
  hardware) is a credible head start for this, not yet evaluated or
  adapted to this project's own code.
- **Hardware flash test**, recovery rehearsed first, once emulator
  validation passes.
- **A real elekloader device profile and core for Syntakt** — see
  [`docs/framework-integration.md`](docs/framework-integration.md) for
  the concrete checklist; this is unstarted, real research in its own
  right, not a formality.
