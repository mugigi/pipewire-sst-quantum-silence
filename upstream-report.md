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

## Possible directions

1. In `alsa-pcm.c`, when the ALSA node is the graph driver, clamp
   `pos->clock.target_duration` to at least `state->period_frames`, or renegotiate
   `period_size` when the quantum goes below it.
2. Check whether the driver's `SNDRV_PCM_INFO_BLOCK_TRANSFER` expectation is honoured
   by the mmap commit path used by the ALSA plugin.
3. Kernel side (separate issue): `sst_media_prepare()` assigns
   `substream->runtime->hw.info = SNDRV_PCM_INFO_BLOCK_TRANSFER;` instead of OR-ing it,
   which clears all other `hw.info` bits.

## Attachments to add

- `pw-metadata -n settings` output
- `/proc/asound/card1/pcm0p/sub0/status` dumps for quantum 512 and 1024
- `pw-top -b -n 2` during both cases
