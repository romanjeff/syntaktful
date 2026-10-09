# syntaktful

Community firmware research and (eventually) mods for the [Elektron
Syntakt](https://www.elektron.se/en/syntakt-explorer) — a hybrid
analog/digital drum machine and synthesizer groovebox.

**Not affiliated with, endorsed by, or supported by Elektron.** Syntakt,
Digitakt, Digitone and Elektron are trademarks of Elektron Music Machines.
This project contains no Elektron firmware and never will — bring your own
official `.syx` file from Elektron. Everything here is independent
reverse-engineering research plus (eventually) patches that apply to a
copy of the official firmware you supply yourself.

## Status

This repo currently holds **research and a design draft only** — no
patches have shipped yet. See [`ROADMAP.md`](ROADMAP.md) for what's
planned and where it stands.

## Why this exists

Syntakt has real hardware-modding precedent to build on: Digitakt mk1 and
Digitone mk1 both have active community mod scenes and, more usefully, an
actual distribution framework ([elekloader](https://github.com/irpina/elekloader)
and the [Modwerk](https://modwerk.app) hub built on it). Syntakt itself has
no public firmware-modding research yet — this project aims to be that,
and to plug into those existing frameworks rather than invent a parallel,
incompatible one. See [`docs/framework-integration.md`](docs/framework-integration.md).

## On safety

This project follows the same rules every serious Elektron and 1010music
modding community already converges on: **never touch the bootstrap or
updater sections**, **never change the firmware file's size** (overwrite
bytes in place only), and **never redistribute the manufacturer's
firmware** in any form. Modifying your device's firmware is entirely at
your own risk and may affect your warranty.

## Hardware, in brief

Syntakt runs on **two physical ColdFire processors**, bridged by an FPGA —
not one CPU plus a mystery DSP, and not a Digitone-II-style ColdFire+SHARC
split either:

- **First ColdFire (MAIN OS)** — UI, menus, sequencer, parameter storage.
- **Second ColdFire** — runs the actual per-voice synthesis engine, same
  codebase (confirmed byte-identical, just relocated) as the one powering
  the Elektron Model:Cycles.
- A **Xilinx Spartan XC3S200A FPGA** bridges them and does the actual
  8-track-to-stereo mixdown in hardware — not in software on either chip.
- A **second, identical FPGA** handles analog component control, and an
  **SSI2164 VCA chip** confirms a genuinely analog signal path exists in
  parts of the audio chain.

Full detail, with how this was determined, in
[`docs/architecture.md`](docs/architecture.md).

## Documentation

- [`docs/architecture.md`](docs/architecture.md) — hardware, the two-chip
  split, the firmware container format, toolchain discipline
- [`docs/bridge-architecture.md`](docs/bridge-architecture.md) — the
  FPGA bridge connecting the two ColdFires: confirmed register families,
  each chip's SRAM map, and what's been ruled out while hunting for the
  compressor's actual cross-chip parameter path
- [`docs/compressor.md`](docs/compressor.md) — the master compressor port:
  Digitakt mk1's DSP chain as the design reference, Syntakt's draft
  implementation, and the current open question about where it hooks in
- [`docs/framework-integration.md`](docs/framework-integration.md) — how
  this project aims to integrate with elekloader and Modwerk
- [`docs/references.md`](docs/references.md) — official docs and
  community projects this work draws on

## Related projects

- [18nelli18/Modded-Cycles](https://github.com/18nelli18/Modded-Cycles) —
  independently resolved Syntakt's second-ColdFire load address and full
  synth-engine map, as a side effect of a different port. This project's
  single most valuable external find so far.
- [gdeo607/digi1_mods](https://github.com/gdeo607/digi1_mods) — Digitakt
  mk1's `digieq` mod; source of the master-bus hook and menu-insertion
  technique this project's design reference and menu plan both reuse.
- [irpina/elekloader](https://github.com/irpina/elekloader) /
  [repeat98/octamod](https://github.com/repeat98/octamod) (Modwerk) — the
  distribution frameworks this project aims to integrate with.

None of this repository's code is derived from those projects' own source
— Syntakt is different hardware and (so far) a different firmware
framework generation. The *techniques* (Ghidra-based static analysis
cross-checked against objdump, emulated verification before hardware,
append-only patching) transfer; specific addresses do not.

## This project's broader context

This is one of two parallel firmware-modding efforts
([the other is Bento](https://github.com/romanjeff/bento_enhanced)) run
with an eye toward a longer-term goal: understanding, in concrete detail,
how experienced groovebox manufacturers actually design and architect
their instruments — not just to patch them, but to eventually inform an
original design of our own.

## License

MIT — see [`LICENSE`](LICENSE). Covers the code and documentation in this
repository only.
