# References and prior art

## Official

- Elektron's own [Syntakt](https://www.elektron.se/en/syntakt-explorer) and
  [Digitone II](https://www.elektron.se/en/digitone-ii-explorer) product
  pages, user manuals and OS release notes.
- NXP's ColdFire documentation — specifically the *ColdFire Family
  Programmer's Reference Manual* and the MCF5441x family reference manual
  (the actual silicon marking confirmed on this chip family elsewhere in
  this project's research, `MCF54415CMJ250`), and NXP App Note AN3514 for
  the Serial Boot Facility / RAMBAR boot conventions.

## Hardware teardown

- Elektronauts "Syntakt PCB" thread — community members' physical teardown
  and photographs, the source for confirming two physical ColdFire chips,
  the bridging/analog-control FPGAs, and the SSI2164 VCA chip. Firmware
  analysis alone could not distinguish this from a soft-core-in-FPGA
  hypothesis; this teardown settled it.

## Tooling

- [m-dwyer/digikit](https://github.com/m-dwyer/digikit) — source of the
  `68000:BE:32:ColdfireEMAC` Ghidra language extension this project
  depends on for anything touching ISRs or EMAC-based DSP code (stock
  Ghidra's ColdFire language silently mis-decodes these opcodes).

## Community reverse-engineering projects for other Elektron devices

- [18nelli18/Modded-Cycles](https://github.com/18nelli18/Modded-Cycles) —
  independently resolved Syntakt's second-ColdFire load address, entry
  point, and full per-voice synthesis engine map, as a side effect of
  porting that same engine into the Elektron Model:Cycles. Directly
  resolved this project's own M0c milestone. Also ships a working
  Unicorn-based emulator for that firmware, verified sample-accurate
  against real hardware.
- [gdeo607/digi1_mods](https://github.com/gdeo607/digi1_mods) — the
  `digieq` mod, source of Digitakt mk1's confirmed master-bus hook
  (`0x400721e6`) and the row-insertion technique for adding a new menu
  entry ahead of "Internal Mixer" — the same technique this project's
  Syntakt menu-insertion point reuses.
- [DigiAlchemydsp/DigiFilter](https://github.com/DigiAlchemydsp/DigiFilter) —
  another Digitakt mk1 community mod, consulted during the search for
  Digitakt's compressor DSP chain.

## Mod packaging and distribution frameworks

- [irpina/elekloader](https://github.com/irpina/elekloader) — the actual
  device-profile/build engine behind Modwerk's Digitakt and Digitone
  support. See [`framework-integration.md`](framework-integration.md) for
  how this project aims to integrate with it.
- [repeat98/octamod](https://github.com/repeat98/octamod) (Modwerk,
  modwerk.app) — the community hub/catalog built on top of elekloader (and
  octabam, for the Octatrack). Already has an empty placeholder entry for
  Syntakt with no research credited yet.

## This project's own prior milestones

Full chronological working notes (addresses, decisions, dead ends) live in
this project's private working folder, not in this public repo — only
hashes, structure, addresses and conclusions are published here, per the
"never share firmware" convention every project above also follows.
