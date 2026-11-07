# alsa-pcm: playback stalls when the graph quantum is below the negotiated ALSA period

## Environment

- PipeWire 1.6.10, WirePlumber, pipewire-pulse (Arch Linux)
- Kernel 6.18.58-1-lts (x86_64)
- Machine: Thomson NEO14, Intel Bay/Cherry Trail
- Card: `bytcht-es8316` (ES8316 codec)
  - `snd_soc_sst_byt_cht_es8316`
  - `snd_soc_sst_atom_hifi2_platform`
  - `snd_intel_sst_acpi`
- Sink: `alsa_output.platform-bytcht_es8316.HiFi__Speaker__sink`
- Negotiated hw params: `S16_LE`, 2 ch, 48000 Hz,
  `period_size = 1008`, `buffer_size = 34272`

## Summary

Playback is silent (for **every** application, not only one client) as soon as the graph
quantum drops below the ALSA period of the device. The ALSA `hw_ptr` stops advancing
while `appl_ptr` keeps moving, so the DSP never consumes the buffer. `pactl`/PipeWire
still show signal on the sink monitor, which makes it look like a volume/routing problem.

With quantum >= 1024 playback works normally.

## Measurements

`/proc/asound/card1/pcm0p/sub0/status`, sampled 2 s apart during a 440 Hz sine played
with `paplay`, while forcing `clock.force-quantum`:

| forced quantum | ALSA period | hw_ptr delta over 2 s | state  | audible |
|---------------:|------------:|----------------------:|:------:|:-------:|
| 512  | 1008 | ~0 (pointer reset)   | XRUN   | no  |
| 960  | 1008 | +1008 (one period, then stall) | RUNNING | no |
| 1008 | 1008 | 0                    | RUNNING | no |
| 1024 | 1008 | +96768 (≈48000 fps)  | RUNNING | **yes** |

With quantum 512 the status also shows `appl_ptr = 1024`, `delay = 1024`: only two
512-frame commits were made and then the sink stopped submitting.

## Why the period is 1008

- `spa/plugins/alsa/alsa-pcm.h`: `DEFAULT_PERIOD = 1024`, `DEFAULT_RATE = 48000`.
- `alsa_set_hw_params()`: `default_period = flp2(2 * 1024 - 1) = 1024`, then
  `snd_pcm_hw_params_set_period_size_near(hndl, params, &period_size /* 1024 */, &dir)`.
- The SST platform driver constrains the period to a multiple of 48 frames
  (`snd_pcm_hw_constraint_step(..., SNDRV_PCM_HW_PARAM_PERIOD_SIZE, 48)` in
  `sound/soc/intel/atom/sst-mfld-platform-pcm.c`).
- 1024 rounded to the nearest valid value is **1008**.

The period is therefore fixed at 1008 when the device is opened, but the graph quantum is
still allowed to go down to 512 when a client asks for lower latency. The sink then
commits fewer frames than one period per cycle and the hardware pointer never advances.

## Steps to reproduce

```bash
cat /proc/asound/card1/pcm0p/sub0/hw_params   # period_size: 1008
pw-metadata -n settings 0 clock.force-quantum 512
paplay tone.wav                                # silence
cat /proc/asound/card1/pcm0p/sub0/status       # hw_ptr frozen, appl_ptr moving
pw-metadata -n settings 0 clock.force-quantum 1024
paplay tone.wav                                # sound is back
```

Any player reproduces it (`paplay`, `aplay`, Chromium `<audio>` and Web Audio alike).
It is *not* client-specific: the sink itself stops consuming.

## The kernel driver is not at fault

Writing directly to `hw:1` through ALSA mmap (no PipeWire), same period (1008) and
buffer (34272), with the buffer fully pre-filled before `snd_pcm_start()`:

| pre-fill before start | commit size | measured hw rate | xruns |
|----------------------:|------------:|-----------------:|------:|
| 34272 frames (full) | 512  | 48055 fps | 0 |
| 34272 frames (full) | 1008 | 48001 fps | 0 |
| 34272 frames (full) | 1024 | 48000 fps | 0 |
| 512 frames          | 512  | 0 fps (stuck at 2016) | XRUN |

Sweeping the pre-fill with a constant 512-frame commit size gives a sharp threshold:

| pre-fill before `snd_pcm_start` | result |
|---|---|
| 512 / 1008 / 1512 frames | XRUN, `hw_ptr` frozen |
| **2016 frames (2 periods) and above** | ~48000 fps, 0 xruns |

So the SST driver/firmware handles 512-frame commits fine. The failure is a **startup
underrun**: the firmware needs at least **two periods (2016 frames)** queued before it
starts. Below that it underruns and never recovers. `alsa_write_frames()` primes
`threshold` frames and then writes one graph buffer of `threshold` frames, so with
quantum <= 1008 the stream never has more than 2016 frames queued at start (and usually
less). With quantum >= 1024, `2 * quantum > 2016`, which is why it works.

Reproducer: `alsa_direct.py` (direct ALSA, bypasses PipeWire).

## Proposed fix

The device reports `SNDRV_PCM_INFO_BLOCK_TRANSFER`
(`snd_pcm_hw_params_is_block_transfer() == 1`), i.e. it consumes data only in whole
periods. That is exactly the class of hardware affected by this startup behaviour.

The attached patch (`0001-alsa-pcm-keep-two-periods-queued-for-block-transfer.patch`):

1. stores `is_block_transfer` when the hw params are negotiated;
2. in `recalc_headroom()`, for playback on a block-transfer device whose graph quantum
   is not larger than the ALSA period, enforces `headroom = 2 * period - quantum`, i.e.
   keeps **two periods** queued;
3. calls `recalc_headroom()` when the quantum changes so the margin follows the graph.

```c
/* Block-transfer devices only consume data (and update their pointer)
 * in whole periods. When the graph quantum is not larger than the period,
 * keep at least two periods queued so that the stream does not underrun
 * at startup. Some firmware (e.g. Intel SST with ES8316) never recovers
 * from such a startup underrun and stays silent. */
if (state->stream == SND_PCM_STREAM_PLAYBACK &&
    state->is_block_transfer &&
    state->period_frames >= state->threshold)
	state->headroom = SPA_MAX(state->headroom,
			2 * state->period_frames - state->threshold);
```

The condition is generic: it names no card, only the ALSA `BLOCK_TRANSFER` capability.
The extra latency (~2 periods, 42 ms at 48 kHz) applies only to block-transfer playback
devices and only while the quantum is <= the period. Larger quantums and other devices
are unchanged.

## Test results with the patch

PipeWire 1.6.10 built from source with the patch, isolated instance, `paplay` 440 Hz,
`hw_ptr` sampled from `/proc/asound/card1/pcm0p/sub0/status`:

| forced quantum | period | state | measured hw rate | xruns (10 s) |
|---------------:|-------:|:-----:|-----------------:|-------------:|
| 128  | 1008 | RUNNING | 48182 fps | 0 |
| 512  | 1008 | RUNNING | 48182 fps | 0 |
| 1008 | 1008 | RUNNING | 48081 fps | 0 |
| 1024 | 1008 | RUNNING | 48384 fps | 0 |
| 2048 | 1008 | RUNNING | 48384 fps | 0 |

Before the patch, quantum 128/512/768/1008 all reported 0 fps and `XRUN`.

Reproduce with `test-isolated.sh build/spa/plugins/alsa 128 512 1008 1024` (starts a
private PipeWire instance with the patched plugin and measures `hw_ptr`).

## Expected behaviour

Playback should keep running whatever the graph quantum is (possibly with higher
latency), or the sink should not accept a target quantum below its negotiated period.

## Workaround

```ini
# ~/.config/pipewire/pipewire.conf.d/99-min-quantum.conf
context.properties = {
    default.clock.quantum     = 1024
    default.clock.min-quantum = 1024
}
```

This fixes it, at the cost of a ~21 ms minimum latency instead of ~10 ms.

## Discussion

1. The attached patch implements the fix in `recalc_headroom()`, reusing the existing
   headroom mechanism and the ALSA `BLOCK_TRANSFER` capability. It avoids special-casing
   any card.
2. An alternative would be to refuse a graph quantum below `state->period_frames` for
   block-transfer devices, but that would change scheduling for the whole graph and
   could affect unrelated nodes.
3. Kernel (separate, unrelated): `sst_media_prepare()` assigns
   `substream->runtime->hw.info = SNDRV_PCM_INFO_BLOCK_TRANSFER;` instead of OR-ing it,
   which clears all other `hw.info` bits. Worth a separate report, but it is not the
   cause of this issue (the capability is already reported correctly at hw_params time).

## Attachments to add

- `pw-metadata -n settings` output
- `/proc/asound/card1/pcm0p/sub0/status` dumps for quantum 512 and 1024
- `pw-top -b -n 2` during both cases
