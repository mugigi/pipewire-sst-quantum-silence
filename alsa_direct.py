#!/usr/bin/env python3
"""Direct ALSA mmap test, bypassing PipeWire.

Plays a 440 Hz tone to hw:1 with a fixed commit size (chunk) and measures the
hardware pointer *during* playback.  Tells us whether a stall at small chunk
sizes is in the kernel driver/firmware or in PipeWire.

Usage: alsa_direct.py <chunk_frames> [seconds] [prefill_frames]
"""
import ctypes as C
import ctypes.util
import math
import struct
import sys
import time

alsa = C.CDLL(ctypes.util.find_library("asound"))

PLAYBACK = 0
ACCESS_MMAP_INTERLEAVED = 0
FMT_S16_LE = 2
RATE = 48000
CHANNELS = 2
FRAME_BYTES = CHANNELS * 2
PERIOD = 1008
BUFFER = 34272
# Adjust if your card is not card 1 / pcm0p
STATUS = "/proc/asound/card1/pcm0p/sub0/status"


class Area(C.Structure):
    _fields_ = [("addr", C.c_void_p), ("first", C.c_uint), ("step", C.c_uint)]


def chk(name, ret):
    if ret < 0:
        alsa.snd_strerror.restype = C.c_char_p
        alsa.snd_strerror.argtypes = [C.c_int]
        raise RuntimeError(f"{name}: {alsa.snd_strerror(ret).decode()}")
    return ret


def status():
    d = {}
    try:
        with open(STATUS) as f:
            for line in f:
                if ":" in line:
                    k, v = line.split(":", 1)
                    d[k.strip()] = v.strip()
    except OSError:
        pass
    return d


def hw_ptr(st):
    try:
        return int(st.get("hw_ptr", "0"))
    except ValueError:
        return 0


def make_tone(seconds=1):
    n = RATE * seconds
    out = bytearray()
    for i in range(n):
        v = int(0.2 * 32767 * math.sin(2 * math.pi * 440 * i / RATE))
        out += struct.pack("<hh", v, v)
    return bytes(out)


def main():
    chunk = int(sys.argv[1]) if len(sys.argv) > 1 else 512
    seconds = float(sys.argv[2]) if len(sys.argv) > 2 else 6.0
    prefill = int(sys.argv[3]) if len(sys.argv) > 3 else None

    tone = make_tone(1)
    tone_len = len(tone)

    pcm = C.c_void_p()
    chk("open", alsa.snd_pcm_open(C.byref(pcm), b"hw:1", PLAYBACK, 0))

    params = C.c_void_p()
    chk("params_malloc", alsa.snd_pcm_hw_params_malloc(C.byref(params)))
    chk("any", alsa.snd_pcm_hw_params_any(pcm, params))
    chk("access", alsa.snd_pcm_hw_params_set_access(
        pcm, params, ACCESS_MMAP_INTERLEAVED))
    chk("format", alsa.snd_pcm_hw_params_set_format(pcm, params, FMT_S16_LE))
    chk("channels", alsa.snd_pcm_hw_params_set_channels(pcm, params, CHANNELS))
    rate = C.c_uint(RATE)
    chk("rate", alsa.snd_pcm_hw_params_set_rate_near(pcm, params, C.byref(rate), None))
    per = C.c_ulong(PERIOD)
    chk("period", alsa.snd_pcm_hw_params_set_period_size_near(pcm, params, C.byref(per), None))
    buf = C.c_ulong(BUFFER)
    chk("buffer", alsa.snd_pcm_hw_params_set_buffer_size_near(pcm, params, C.byref(buf)))
    chk("hw_params", alsa.snd_pcm_hw_params(pcm, params))

    p = C.c_void_p()
    chk("hm", alsa.snd_pcm_hw_params_malloc(C.byref(p)))
    chk("hc", alsa.snd_pcm_hw_params_current(pcm, p))
    period, bfr = C.c_ulong(), C.c_ulong()
    chk("gp", alsa.snd_pcm_hw_params_get_period_size(p, C.byref(period), None))
    chk("gb", alsa.snd_pcm_hw_params_get_buffer_size(p, C.byref(bfr)))
    alsa.snd_pcm_hw_params_free(p)
    period, bfr = period.value, bfr.value

    sw = C.c_void_p()
    chk("sw_malloc", alsa.snd_pcm_sw_params_malloc(C.byref(sw)))
    chk("sw_current", alsa.snd_pcm_sw_params_current(pcm, sw))
    chk("start_thr", alsa.snd_pcm_sw_params_set_start_threshold(pcm, sw, bfr))
    chk("avail_min", alsa.snd_pcm_sw_params_set_avail_min(pcm, sw, chunk))
    chk("sw_params", alsa.snd_pcm_sw_params(pcm, sw))
    alsa.snd_pcm_sw_params_free(sw)

    chk("prepare", alsa.snd_pcm_prepare(pcm))

    def commit(frames):
        off = C.c_ulong(0)
        areas = C.POINTER(Area)()
        r = alsa.snd_pcm_mmap_begin(pcm, C.byref(areas), C.byref(off), C.byref(frames))
        if r < 0:
            return r, 0
        n = frames.value
        base = C.cast(areas[0].addr, C.c_void_p).value + off.value * FRAME_BYTES
        need = n * FRAME_BYTES
        start = phase[0] % tone_len
        data = tone[start:start + need]
        if len(data) < need:
            data += tone[:need - len(data)]
        C.memmove(base, data, need)
        phase[0] = (phase[0] + need) % tone_len
        c = alsa.snd_pcm_mmap_commit(pcm, off.value, n)
        return c, n

    phase = [0]

    # pre-fill, then start
    target_fill = bfr if not prefill else min(prefill, bfr)
    filled = 0
    while filled < target_fill:
        want = C.c_ulong(min(chunk, target_fill - filled))
        c, n = commit(want)
        if c < 0:
            break
        filled += n
    chk("start", alsa.snd_pcm_start(pcm))

    print(f"chunk={chunk} period={period} buffer={bfr} prefill={target_fill}")

    next_t = time.monotonic()
    t0 = time.monotonic()
    errors = 0
    samples = []
    last_sample = 0.0

    while True:
        now = time.monotonic()
        elapsed = now - t0
        if elapsed >= seconds:
            break
        if elapsed - last_sample >= 1.0:
            samples.append((elapsed, hw_ptr(status())))
            last_sample = elapsed
        want = C.c_ulong(chunk)
        c, n = commit(want)
        if c < 0:
            errors += 1
            chk("prepare", alsa.snd_pcm_prepare(pcm))
            filled = 0
            while filled < bfr:
                w2 = C.c_ulong(min(chunk, bfr - filled))
                c2, n2 = commit(w2)
                if c2 < 0:
                    break
                filled += n2
            alsa.snd_pcm_start(pcm)
            next_t = time.monotonic()
            t0 = time.monotonic()
            samples = []
            last_sample = 0.0
            continue
        next_t += n / RATE
        delay = next_t - time.monotonic()
        if delay > 0:
            time.sleep(delay)

    dur = time.monotonic() - t0
    st = status()
    end_hw = hw_ptr(st)
    if len(samples) >= 2:
        (t1, h1), (t2, h2) = samples[0], samples[-1]
        rate = (h2 - h1) / (t2 - t1) if t2 > t1 else 0
    else:
        rate = end_hw / dur if dur else 0
    print(f"  hw_ptr samples: {samples}")
    print(f"  measured rate: {rate:.0f} fps over {dur:.1f}s, xrun recoveries={errors}")
    print(f"  final: state={st.get('state')} appl={st.get('appl_ptr')} delay={st.get('delay')}")
    print(f"  => {'JOUE' if rate > 40000 else 'BLOQUE'}")
    alsa.snd_pcm_drop(pcm)
    alsa.snd_pcm_close(pcm)


if __name__ == "__main__":
    main()
