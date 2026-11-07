#!/bin/bash
# Isolated PipeWire test for an ALSA SPA plugin build.
#
# Starts a private PipeWire/WirePlumber/pipewire-pulse instance using the
# given libspa-alsa.so, forces several graph quantums, plays a test tone and
# measures how fast the ALSA hardware pointer advances.  The user's normal
# PipeWire services are stopped for the duration and restored on exit.
#
# Usage:
#   ./test-isolated.sh <alsa-plugin-dir> [quantum ...]
#
# Example:
#   ./test-isolated.sh ~/pipewire-1.6.10/build/spa/plugins/alsa 128 512 1008 1024
#
# Environment:
#   CARD=card1        ALSA card name under /proc/asound
#   PCM=pcm0p         PCM device (playback)
#   SINK_MATCH=bytcht substring used to find the sink in pactl output
#   MEASURE=2         seconds of measurement per quantum
#   PWDEBUG=2         PIPEWIRE_DEBUG value for the private instance
#   SPA_SYSTEM_DIR=/usr/lib/spa-0.2   system SPA plugin directory
set -u

PLUGDIR="${1:-}"
[ $# -gt 0 ] && shift
if [ -z "$PLUGDIR" ] || [ ! -d "$PLUGDIR" ]; then
    echo "usage: $0 <alsa-plugin-dir> [quantum ...]" >&2
    exit 2
fi
[ -f "$PLUGDIR/libspa-alsa.so" ] || {
    echo "error: $PLUGDIR/libspa-alsa.so not found" >&2
    exit 2
}

QUANTA=("$@"); [ ${#QUANTA[@]} -eq 0 ] && QUANTA=(512 1024)

CARD="${CARD:-card1}"
PCM="${PCM:-pcm0p}"
SINK_MATCH="${SINK_MATCH:-bytcht}"
MEASURE="${MEASURE:-2}"
SPA_SYSTEM_DIR="${SPA_SYSTEM_DIR:-/usr/lib/spa-0.2}"

WORK="${TMPDIR:-/tmp}/pw-alsa-test.$$"
SPADIR="$WORK/spa"
LOGDIR="$WORK/log"
STATUS="/proc/asound/$CARD/$PCM/sub0/status"
HWPARAMS="/proc/asound/$CARD/$PCM/sub0/hw_params"
TONE="$WORK/tone.wav"

CONF="$HOME/.config/pipewire/pipewire.conf.d/99-min-quantum.conf"
CONFBAK="$CONF.test-bak"

mkdir -p "$SPADIR" "$LOGDIR"

# Build a 30 s, 440 Hz, S16_LE stereo 48 kHz test tone.
python3 - "$TONE" <<'PY'
import math, struct, sys, wave
rate, secs, amp = 48000, 30, 0.2
with wave.open(sys.argv[1], "wb") as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(rate)
    frames = bytearray()
    for i in range(rate * secs):
        v = int(amp * 32767 * math.sin(2 * math.pi * 440 * i / rate))
        frames += struct.pack("<hh", v, v)
    w.writeframes(bytes(frames))
PY

# Mirror the system SPA directory, replacing the alsa plugin.
for d in "$SPA_SYSTEM_DIR"/*; do
    [ -e "$d" ] || continue
    name=$(basename "$d")
    [ "$name" = "alsa" ] && continue
    ln -s "$d" "$SPADIR/$name"
done
ln -s "$(cd "$PLUGDIR" && pwd)" "$SPADIR/alsa"

PIDS=()
restore() {
    for p in "${PIDS[@]}"; do kill "$p" 2>/dev/null; done
    sleep 1
    for p in "${PIDS[@]}"; do kill -9 "$p" 2>/dev/null; done
    [ -f "$CONFBAK" ] && mv "$CONFBAK" "$CONF"
    systemctl --user start pipewire.socket pipewire-pulse.socket >/dev/null 2>&1
    systemctl --user start pipewire.service wireplumber.service pipewire-pulse.service >/dev/null 2>&1
    rm -rf "$WORK"
}
trap restore EXIT

period() { awk -F': *' '/^period_size/{print $2}' "$HWPARAMS" 2>/dev/null; }
hwptr()  { awk -F': *' '/^hw_ptr/{print $2}' "$STATUS" 2>/dev/null; }
pstate() { awk -F': *' '/^state/{print $2}' "$STATUS" 2>/dev/null; }

# Do not let a low-latency workaround mask the bug.
[ -f "$CONF" ] && mv "$CONF" "$CONFBAK"

systemctl --user stop pipewire-pulse.service pipewire-pulse.socket \
                         wireplumber.service pipewire.service pipewire.socket >/dev/null 2>&1
sleep 1

SPA_PLUGIN_DIR="$SPADIR" PIPEWIRE_DEBUG="${PWDEBUG:-2}" pipewire > "$LOGDIR/pipewire.log" 2>&1 &
PIDS+=($!)
sleep 2
wireplumber > "$LOGDIR/wireplumber.log" 2>&1 &
PIDS+=($!)
pipewire-pulse > "$LOGDIR/pulse.log" 2>&1 &
PIDS+=($!)

for _ in $(seq 1 20); do
    pactl list short sinks 2>/dev/null | grep -q "$SINK_MATCH" && break
    sleep 0.5
done
sleep 1

echo "== sink =="
pactl list short sinks 2>/dev/null | grep "$SINK_MATCH" || pactl list short sinks 2>/dev/null | head -3
pw-metadata -n settings 0 clock.min-quantum 32 >/dev/null 2>&1

echo "== measurements (${MEASURE}s each) =="
for q in "${QUANTA[@]}"; do
    pw-metadata -n settings 0 clock.force-quantum "$q" >/dev/null 2>&1
    sleep 0.5
    paplay "$TONE" >/dev/null 2>&1 &
    pid=$!
    sleep 1.5
    h1=$(hwptr); per=$(period)
    sleep "$MEASURE"
    h2=$(hwptr); st=$(pstate)
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    rate=$(( (${h2:-0} - ${h1:-0}) / MEASURE ))
    printf 'quantum=%-5s period=%-5s state=%-8s hw_ptr=%s->%s rate=%s fps\n' \
        "$q" "${per:-?}" "${st:-?}" "${h1:-?}" "${h2:-?}" "$rate"
    sleep 0.8
done

echo "== xruns in private instance =="
grep -c "xrun of" "$LOGDIR/pipewire.log" 2>/dev/null || echo 0
