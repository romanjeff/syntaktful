# Integrating with elekloader and Modwerk

Two existing community projects already do real work in this space, for
other Elektron devices. Rather than building a parallel, incompatible
packaging/distribution mechanism, this project aims to plug into them once
the underlying research is far enough along.

## What each project actually is

**[elekloader](https://github.com/irpina/elekloader)** (GPL-2.0-or-later,
Python 3.9+/TypeScript) is the actual engine: a per-device profile plus a
patching/linking toolchain that builds a flashable image from a user's own
stock OS file plus one or more mods. It never ships or redistributes
firmware — every build happens from the hash-identified stock file the
user supplies. It currently supports Digitakt mk1 (1.53/1.54), Digitone
mk1/Keys (1.43/1.44), Octatrack MKI/MKII (1.40C), and Digitakt II (1.17,
experimental).

**[Modwerk](https://modwerk.app)** (`repeat98/octamod` on GitHub,
GPL-3.0-or-later; formerly "Octamod") is a browser-based hub sitting on top
of elekloader (and, for the Octatrack, `octabam`): a module catalog,
machine pages, a build UI, and a review process. For the devices it
supports today, Modwerk vendors elekloader's engine unchanged and runs it
in the user's own browser — Modwerk's own TypeScript linker/writer/core
exist but are currently frozen while that vendored approach is used.

The practical relationship: **elekloader is where the real technical
integration work belongs; Modwerk is where it becomes visible to users**
once it exists. A device profile and core added to elekloader is most of
what's needed for Modwerk to eventually list the device as supported.

## Syntakt's current status in both projects

Neither currently supports Syntakt. Modwerk already has a placeholder
entry for it (`sdk/machines/syntakt/machine.json`): `status: "open"`, and
every one of its five tracked steps (`format`, `rebuild`, `boot`, `core`,
`mods`) marked `open` — meaning no public research has been credited
there yet. This project's own findings are a natural candidate for the
first real content on that page.

## Why Syntakt is a good structural fit for elekloader's model

elekloader already has a close precedent: **Digitone mk1**. Its firmware
container has the identical shape Syntakt's does — same ELE3 family, same
SysEx transport, section 7 holding "the second CPU's image, which renders
the FM voices." Syntakt's own section 7 (the second ColdFire's synth
engine, see [`architecture.md`](architecture.md)) is structurally the same
kind of thing: a second-CPU firmware image dedicated to voice rendering,
confirmed via [Modded-Cycles'](https://github.com/18nelli18/Modded-Cycles)
independent research.

Crucially, elekloader's own documentation of how Digitone mk1 mods reach
into that second chip's output is **exactly the same shape as the answer
this project is currently chasing for Syntakt's compressor** (see
[`compressor.md`](compressor.md)): mods don't patch the second chip's
code directly. They hook `ev_render_voices` on the **main** CPU, right
after it has read the second chip's rendered output back into SRAM
(`fw_voices`, via eDMA) and before that output reaches the mix/effects
chain. If Syntakt's MAIN OS does something analogous for the FPGA's
already-summed output, the integration story is almost identical to one
elekloader already ships for a real device — not a new pattern invented
from scratch.

## What a Syntakt device profile would need

Per elekloader's own `docs/ADAPTING.md` ("What a new device needs besides
its profile"), concretely:

| Field | What's already known | What's still open |
|---|---|---|
| `releases` | Syntakt OS 1.41's `.syx` hash, and the MAIN OS section's hash/length once depacked | — |
| `sysex_id` | The device byte of Syntakt's OS messages | Not yet read off the framing messages |
| `main_section`, `main_load` | Section 3, `0x40000400` | Confirmed via objdump Gate F cross-check |
| `stage` | Where the bootstrap stages MAIN OS before unpacking in place | Not yet traced — need the bootstrap's own loader call, analogous to Digitakt's `0x800005fe` |
| `flash_at`, `flash_limit` | — | Not yet traced — needs the bootstrap's flash-read range |
| `trailer` | Digitakt mk1 has none; Digitone II is sealed (HMAC, seed `"Multiplier"`) | Unconfirmed for Syntakt — check the bootstrap for a seed string before assuming either way |
| `isa` | ColdFire — elekloader already ships `isa/coldfire.py` | Directly reusable, no new decoder needed |
| `areas` (free RAM for mods) | — | Not yet researched — this is "what the OS never touches," the same category of finding as this project's own BSS/free-SRAM work on the Bento side, just not yet done here |
| `container`, `version_len` | ELE3, same shape as Digitakt/Digitone mk1 | — |
| `toolchain` | m68k binutils/gcc, same as every other ColdFire device elekloader supports | — |

The honest summary: the *transport and packing* side (container format,
ISA, toolchain) is close to free, since Syntakt is clearly the same family
as devices elekloader already handles. The *device-specific* side
(staging address, flash layout, seal/trailer, free-RAM map) is real,
unstarted research — comparable in shape and effort to work this project
has already done once, on Bento's side, for a completely different
platform.

## What a Syntakt *core* would need

Before any mod (including this project's compressor) can be a proper
elekloader "linkable mod" (format 2, combinable with others — see
`ADAPTING.md`, "Path B"), a **core** needs to exist: a small piece of code
that reserves RAM and turns Syntakt's own shared hook sites (tick, draw,
key, encoder turn, settings-menu-build, at minimum) into the generic event
set every device's core exposes (`ev_tick`, `ev_draw`, `ev_key`, `ev_enc`,
`ev_settings`, ...). This is real, unstarted work of its own — comparable
in scope to how Digitakt II's `core-dt2` was built from scratch for a
device with no prior elekloader support at all, which elekloader's own
docs record as a completed, working precedent (booted on real hardware,
4 Oct 2026).

Until a core exists, this project's compressor mod can still ship as a
**whole-build mod** (elekloader's "Path A" — a complete `.syx`, the output
of this project's own direct-patch approach), at the cost of not combining
with any other mod. elekloader's own guidance frames this exact situation
as the normal stopgap, not a dead end: "quick, but it cannot be combined
with anything... Path A is a stopgap for an existing monolithic build."

## Realistic sequencing

1. **Research lands here first**, in this repo — hashes, addresses, and
   notes only, never firmware bytes, matching the convention both
   elekloader and Modwerk already enforce ("Never share firmware").
2. **A documentation-only PR to Modwerk**, updating
   `sdk/machines/syntakt/machine.json` to move `status` from `open` to
   `research` and crediting this project's findings against whichever
   steps have real progress (almost certainly `format`, given the
   container/ISA match above, once written up with enough rigor to cite).
   Low-risk, no code required — `ADD_A_MACHINE.md` documents exactly this
   workflow.
3. **A device-profile PR to elekloader itself**, once the open items in
   the table above are resolved — this is where the real technical
   contribution belongs, since Modwerk vendors elekloader's engine rather
   than reimplementing it.
4. **A core PR**, once a profile exists and enough of Syntakt's own shared
   UI hook sites are mapped — this is the long pole, and probably the
   right point to revisit whether this project's compressor ships as a
   linkable mod or stays a whole build in the meantime.
5. **Modwerk's Syntakt page updated again** to reflect `boot`/`core` done,
   once (3) and (4) land, following the same PR-based review process every
   other change there goes through (owner review, no auto-merge).

Both projects are explicitly open to outside contribution — elekloader's
`ADAPTING.md` is written "for people and for coding agents," and Modwerk's
`SDK.md` states plainly that "every new module, update, document and media
change is a pull request." Neither step above requires permission to
start; they require the underlying research to actually be solid first.
