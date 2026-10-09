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

**The hook-point question is now decided** — the full back-and-forth
(MAIN OS's USB-only tap, a VCA angle investigated and ruled out, landing
on per-track pre-scale) is in [`docs/compressor.md`](docs/compressor.md).
Short version: the FPGA does the real mixdown in hardware with no software
master buffer to hook on either chip, so the compressor computes its
detector from a local pre-sum of the 8 per-track buffers and applies the
resulting gain as one scalar to all 8, upstream of the FPGA handoff —
never touching the FPGA bitstream. Known, accepted tradeoff: this diverges
slightly from true post-mix "glue" character if the FPGA's internal
summing saturates, which Modded-Cycles' own research confirms it can.
`research/syntakt_comp_draft.s` has been rewritten for this hook model.

- **Parameter storage decided**: a freestanding struct, with a confirmed
  home at `0x80007f90`–`0x80008000` on the second ColdFire (112 bytes,
  fits the 52-byte struct with margin) — the gap between its two
  boot-time SRAM copy chunks, confirmed free of static references by two
  independent methods. Not emulator-confirmed yet — see
  [`docs/compressor.md`](docs/compressor.md) for the honest caveat.

## In progress

M3's draft is now fully addressed except for the LUT table contents
(`comp_log_table`/`comp_exp_table`, which depend on this chip's real
sample headroom) and the exact register-save frame size at the hook
site — both flagged in the draft itself, not guessed. M4 (the actual
mixer-menu page content) was blocked on parameter storage; that's clear
now, so M4 is next up.

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
