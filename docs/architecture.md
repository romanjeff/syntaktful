# Syntakt hardware and firmware architecture

## Two physical ColdFire CPUs, not one CPU plus a mystery DSP

Firmware-only static analysis (disassembling MAIN OS's DSP-boot-handshake
code, tracing an external bus window) got partway to an answer but couldn't
distinguish "a second physical chip" from "a soft CPU core living inside an
FPGA." Hardware teardown evidence settled it: community members who
physically opened and photographed a unit (Elektronauts "Syntakt PCB"
thread) documented:

- **Two Freescale ColdFire processors** (same family as Digitone's), each
  with its own 128MB SDRAM (Nanya NT5TU128M8HE).
- A **Xilinx Spartan XC3S200A FPGA** bridging them.
- A **second, identical XC3S200A FPGA** dedicated to analog component
  control (DAC-style interfacing, similar to the Analog series).
- A Cirrus Logic ADC/DAC and an **SSI2164 analog VCA chip** — confirming a
  genuinely analog signal path exists in parts of Syntakt's audio chain,
  not just digital emulation of one.

The Spartan XC3S200A is small and old (~200K gates) — nowhere near large
enough to plausibly host a soft CPU core or a full audio engine. That rules
out the "soft core in FPGA" hypothesis firmware analysis alone couldn't
eliminate.

## What each chip does

- **MAIN OS (first ColdFire)** — UI, menus, sequencer, parameter storage,
  and the DSP-boot-handshake with the second chip. Structurally the same
  role Digitakt mk1's single ColdFire plays, since Digitakt has no second
  chip at all.
- **The synth engine (second ColdFire, firmware container section 7)** —
  runs the actual per-voice synthesis for Syntakt's digital machines
  (analog machines are presumably closer to true analog signal paths via
  the second FPGA). Same ColdFire ISA as MAIN OS — not a foreign
  architecture requiring a separate toolchain, unlike Digitone II's SHARC
  split.

### Why this matters for porting a compressor

This is architecturally better news than Digitone II's ColdFire+SHARC
split: Digitone II's DSP chip is an Analog Devices SHARC, a completely
different ISA needing its own toolchain. Syntakt's second chip is the
**same ColdFire ISA** as MAIN OS, so the same Ghidra setup and the same
mental model already in use for MAIN OS applies directly to it too.

It is *not*, however, as simple as "find the master buffer and hook it,"
the way Digitakt mk1's single-chip architecture is. See
[`compressor.md`](compressor.md) for why: the second chip's 8 per-track
render buffers get handed to the bridging FPGA raw, unsummed — the actual
stereo mixdown happens in FPGA hardware, not in any ColdFire software.

## Firmware container format

Both Syntakt and Digitone II use the same **ELE3 container**: a SysEx
transport wrapping a preamble, a section table, and aPLib-compressed
sections — one shared convention across the whole Elektron ColdFire
product line, not a per-device format. Syntakt OS 1.41's section table:

| Section | Contents | Notes |
|---|---|---|
| 3 | MAIN OS | ColdFire V4e, big-endian, loads at `0x40000400` |
| 7 | Second ColdFire's firmware | 383,760 bytes decompressed, dense with real ColdFire opcodes (RTS/JSR.L/LINK/UNLK/RTE) |
| 1 | FPGA bitstream(s) | 149,516 B compressed; opens with a genuine Xilinx bitstream preamble (dummy-word run, then `AA 99` sync) — likely covers one or both Spartan XC3S200A FPGAs |
| 8 | Shared companion-chip firmware | 159,948 bytes decompressed, **byte-for-byte identical (same SHA-256) to Digitone II's own section 8** — almost certainly a shared ARM Cortex-M companion firmware, common across the ColdFire product line, not device-specific |

MAIN OS's load address and section-table shape are identical to Digitone
II's — consistent with "one Elektron platform, one convention" across the
ColdFire lineup.

## The second ColdFire's load address and entry point

Resolved not by this project's own tracing, but by discovering independent
public research that had already solved it for a different reason:
[`18nelli18/Modded-Cycles`](https://github.com/18nelli18/Modded-Cycles) is a
community project porting real Syntakt synth-engine code into the Elektron
Model:Cycles (a sibling product sharing the same MCF54415CMJ250 ColdFire).
Their own statistical method — testing candidate base addresses by how many
absolute jump targets land cleanly, the same technique this project's own
agents were independently using — arrived at:

- **Load address:** `0x40000400`
- **Entry point:** `0x40001070`
- **Voice loop:** `0x40004324`
- **Per-voice state:** 8 voices × 1800 bytes, SRAM base `0x80000000`
- **Dispatch tables:** `0x40014920` / `0x400148f0`

They confirmed Syntakt's second chip runs the *same* synthesis codebase as
Model:Cycles — byte-identical, just relocated — and mapped confirmed
addresses for several individual machines' render code (e.g. SD VINTAGE's
update/render at `0x40008074`/`0x4000847a`).

Modded-Cycles also ships a working **Unicorn-based emulator** for this
exact firmware (`tools/emu/stengine.py`), verified sample-accurate against
real Syntakt hardware — a credible head start for this project's own
emulator-validation milestone, not yet evaluated or adapted.

## Toolchain discipline

- **Ghidra language:** `68000:BE:32:ColdfireEMAC` (installed from
  [m-dwyer/digikit](https://github.com/m-dwyer/digikit)), never stock
  `68000:BE:32:Coldfire`. Stock Ghidra silently mis-decodes `movclr.l` and
  other EMAC opcodes (MAC/MSAC/ACC0-3) with no error raised — common in
  interrupt handler prologues and anything DSP-shaped.
- **"Gate F"**: no reverse-engineering conclusion is trusted until checked
  against `m68k-linux-gnu-objdump -m m68k:cfv4e` (via WSL) on the real
  bytes. Stock Capstone (and radare2, which uses it) was independently
  measured to silently *invent* plausible-looking wrong instructions for
  ColdFire-specific opcodes (`byterev`, `bitrev`, `ff1`, EMAC ops) rather
  than failing loudly — worse than an outright decode failure, because it
  looks correct until cross-checked.

## Rules this project never breaks

- Never touch the bootstrap/updater sections.
- Never change the firmware file's size — overwrite bytes in place only.
- Never redistribute Elektron's firmware, in whole or in part. Everything
  here is our own research and our own code, built against a stock OS file
  each user supplies themselves.
