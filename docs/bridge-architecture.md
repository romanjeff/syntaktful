# The MAIN OS ↔ second-ColdFire bridge

A reference map of everything confirmed so far about how Syntakt's two
physical ColdFire chips communicate across the FPGA. Kept current as
research lands — see [`PROJECT_NOTES`](../../PROJECT_NOTES.md) (not
public) for the chronological trace that built this; this document is
the organized result, not a substitute for it.

## The one fact that matters most: the same address means two different things

Both chips map their own internal SRAM at the conventional base
`0x80000000`. **These are two separate physical memories on two separate
chips.** An address like `0x80000000` or `0x80008000` is meaningless
without saying which chip's disassembly it came from. Every section below
is explicit about this.

## Chip 2 (the synth engine) — confirmed SRAM map

| Range | Size | Contents | Confidence |
|---|---|---|---|
| `0x80000000`–`0x80003840` | 14,400 B | 8 voices × 1800 B per-voice synthesis state | Confirmed (Modded-Cycles' independent research) |
| `0x80003840`–`0x80003c40` | 1,024 B | 8 per-track render buffers (128 B/track, 32 mono int32 samples), handed raw to the FPGA bridge write at `0xfc0455e0` (confirmed at `0x40000ae2`) | Confirmed |
| `0x80003c40`+ | — | Per-track params struct, 142-byte stride, the direct input to the voice-render call `0x40004324` | Confirmed |
| `0x80007f90`–`0x80008000` | 112 B | **Free** — the compressor's new state struct lives here. Confirmed free two independent static ways (literal-operand scan + fresh Ghidra pass), raw bytes zero/padding on both sides. **Not emulator-confirmed** — no traced-execution check exists for this chip | High for "no static reference"; unverified at runtime |
| `0x80008000`–`0x800081b0` | 432 B | The **mirror window** — see below | 97% mapped |

### The 432-byte mirror window, fully mapped

Every audio block (~0.667 ms), an interrupt handler on chip 2 does
`memcpy(0x80008000, 0x00000000, 432)` — a blind bulk copy from address
`0` on chip 2's own bus (backed by the FPGA bridge, not a real DDR/flash
address) into this window. An exhaustive trace (hex *and* decimal literal
scans, plus register-relative displacement chains) found **four**
independent consumers, accounting for 419 of 432 bytes (97%):

| Offset range | Bytes | Consumer | What it does |
|---|---|---|---|
| `0x000`–`0x0D9` | 218 | IRQ handler `0x40000934`–`0x40000b1e` | Per-track 20-byte block copy, plus direct tune/pan field reads |
| `0x0DA`–`0x0DF` | 6 | *(none found)* | Low confidence this is genuinely free — sits between back-to-back loop reads, the signature of struct padding |
| `0x0E0`–`0x14F` | 112 | Same IRQ handler | An 8-track block, larger than first documented (earlier trace only caught one loop iteration) |
| `0x150`–`0x16F` | 32 | Voice-render fn, `0x40004496` | Indexed longword read, gated by a track-type check |
| `0x170`–`0x17F` | 16 | **Previously untraced** filter/DSP fn `0x400024e0`–`0x40002540` | Feeds an EMAC `msacl` coefficient chain |
| `0x180`–`0x1A8` | 41 | Same IRQ handler | Trig/gate byte/word/longword reads |
| `0x1A9`–`0x1AF` | 7 | *(none found)* | Same low-confidence caveat as the other gap |
| `0x1B0`+ | — | A separate DSP table (confirmed boundary) | Owned by unrelated code, not part of this window |

**Verdict: not usable for new data.** Only 13 non-contiguous, low-confidence
bytes are free — nowhere near the 52 bytes the compressor struct needs.
Don't use this window for anything new.

## Chip 1 (MAIN OS) — confirmed FPGA bridge register families

All in the `0xfc04xxxx` range. Each is a 32-byte descriptor: buffer-base
pointer, one or two size fields, a doorbell-register pointer, flags.

### `0xfc0455xx` — the audio ring (confirmed, well-understood)

Buffer base `0x80001800` (chip 1's own SRAM), 2048-byte wrap, ±0x400
ping-pong, 32-frame blocks — the family's standard audio block size. Read
back by chip 1's own interrupt handler (`0x40101bae`) and fed straight to
the USB audio feeder (`FUN_40003fee`, buffer `0x45511108`/`0x4551110c`).
**Confirmed USB-only**: chip 1 has zero traffic to its own on-chip
audio-serial (SSI0) or I2C0 peripherals, so the main analog (Cirrus
Logic) DAC output is very likely fed by a separate, pure-hardware
FPGA-to-codec path that never touches either ColdFire.

### `0xfc0456xx` — a second, matched DMA pair (confirmed, ruled out as the mirror source)

Configured in the *same* init routine as the audio ring above:
`0xfc045690` = buffer base `0x80001800` (the known ring, restated here),
`0xfc0456c0` = buffer base **`0x80000000`** — chip 1's own SRAM, a
*different*, previously-uncharacterized 1024-byte ping-pong buffer.

This channel moves 1024 bytes/block as **32 distinct per-frame values
per track** (an audio-rate envelope/gain ramp — each value produced by an
EMAC multiply against a running per-track sample counter, then `>>8`).
**Confirmed NOT chip 2's parameter mirror**: the shape doesn't match
(1024 bytes vs. chip 2's 432; "32 frames per track" vs. chip 2's single
discrete struct fields per track; 432 isn't even a clean multiple of this
channel's 32-frame unit). Most likely feeds the FPGA's own mixer or
metering stage. A real, useful finding — just not the one being hunted.

### `0xfc0451xx` — a generic tagged-event mailbox (confirmed, ruled out as the mirror source)

Buffer base `0x800051e0`, part of a **repeating family** of similar
descriptors (siblings at `0x80005160`/`5180`/`51a0`/`51c0`, each 0x20
apart), each configured independently by unrelated code elsewhere in the
image. Carries discrete `(tag=0x8001, 16-bit value)` pairs, sentinel-
terminated (`0x08005555`), variable length — reused by **five** unrelated
interrupt-handler call sites across the firmware (e.g. "machine type
changed → ship its new default parameters"). This is a generic outbound
event primitive, not a periodic bulk state mirror. Wrong shape for what
chip 2's `memcpy(dst, 0, 432)` needs.

### Still unknown: the real source of chip 2's mirror

Two real, independently-confirmed candidates investigated and ruled out
above. **The actual bridge channel that populates address `0` as seen
from chip 2 — the true source of its 432-byte mirror — has not yet been
found.** A systematic sweep of the remaining `0xfc04xxxx` register space
for other descriptor-shaped configurations is ongoing.

## Open questions

- The real source of chip 2's 432-byte mirror (see above).
- Whether `0x80007f90`'s "confirmed free" status would survive a traced
  emulator execution — no emulator exists for chip 2 that models the
  FPGA bridge (Modded-Cycles' emulator was evaluated for this and found
  not to model MMIO/bridge behavior at all — credible for validating
  pure in-SRAM DSP math, not for bridge-content questions).
- The `0x80000000`/`0xfc0456c0` audio-rate channel's actual destination
  (FPGA mixer? metering UI?) — found, not fully traced to its consumer.
