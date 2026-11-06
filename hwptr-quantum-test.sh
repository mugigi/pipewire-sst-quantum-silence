#!/bin/bash
# hwptr-quantum-test.sh
#
# Reproducer: on some ALSA devices (e.g. Intel SST + ES8316, bytcht-es8316),
# the hardware pointer stops advancing when the PipeWire graph quantum is
# smaller than the ALSA period negotiated by pipewire's alsa-pcm plugin.
# The result is silence for EVERY application, while the sink monitor still
# shows a full-level signal.
#
# Usage:
#   ./hwptr-quantum-test.sh                 # autodetect card, test 512 960 1008 1024
#   ./hwptr-quantum-test.sh 512 768 1024    # custom quantum list
#   CARD=bytcht-es8316 PCM=pcm0p ./hwptr-quantum-test.sh
#
# Requirements: pipewire, pipewire-pulse (pw-metadata, paplay), coreutils.
# Run as the user owning the PipeWire session.

set -u

CARD="${CARD:-bytcht-es8316}"
PCM="${PCM:-pcm0p}"
QUANTA=("$@")
[ ${#QUANTA[@]} -eq 0 ] && QUANTA=(512 960 1008 1024)

# --- locate the card -------------------------------------------------------
card_index=$(awk -v c="$CARD" 'index($0,c)>0 && /^ *[0-9]+ \[/ {gsub(/[^0-9].*/,"",$1); print $1; exit}' /proc/asound/cards)
if [ -z "${card_index:-}" ]; then
    echo "Card '$CARD' not found. Available cards:" >&2
    sed -n 's/^ *\([0-9]\+\) \[\([^]]*\)\].*/  \1 = \2/p' /proc/asound/cards >&2
    exit 1
fi

S="/proc/asound/card${card_index}/${PCM}/sub0"
[ -d "$S" ] || { echo "No $S (is the PCM opened?)" >&2; exit 1; }

period() { awk -F': *' '/^period_size/{print $2}' "$S/hw_params" 2>/dev/null; }
snap() {
    awk -F': *' '
        /^state/   {st=$2}
        /^hw_ptr/  {hw=$2}
        /^appl_ptr/{ap=$2}
        /^delay/   {dl=$2}
        END{printf "%s %s %s %s", st, hw, ap, dl}' "$S/status" 2>/dev/null
}

TONEFILE=$(mktemp /tmp/hwptr-tone.XXXXXX.wav)
trap 'rm -f "$TONEFILE"; pw-metadata -n settings 0 clock.force-quantum 0 >/dev/null 2>&1' EXIT

echo "Building 20 s test tone..."
python3 - "$TONEFILE" <<'PY'
import sys, wave, struct, math
sr = 48000
with wave.open(sys.argv[1], 'wb') as w:
    w.setnchannels(2); w.setsampwidth(2); w.setframerate(sr)
    d = bytearray()
    for i in range(sr * 20):
        v = int(0.2 * 32767 * math.sin(2 * math.pi * 440 * i / sr))
        d += struct.pack('<hh', v, v)
    w.writeframes(bytes(d))
PY

printf '%-9s %-8s %-9s %-14s %-14s %s\n' "quantum" "period" "state" "hw_ptr before" "hw_ptr after" "rate"
for q in "${QUANTA[@]}"; do
    pw-metadata -n settings 0 clock.force-quantum "$q" >/dev/null 2>&1
    sleep 0.5
    paplay "$TONEFILE" >/dev/null 2>&1 &
    pid=$!
    sleep 1.5
    read -r st1 hw1 _ _ < <(snap)
    sleep 2
    read -r st2 hw2 _ _ < <(snap)
    per=$(period)
    kill "$pid" 2>/dev/null; wait "$pid" 2>/dev/null
    d=$(( ${hw2:-0} - ${hw1:-0} ))
    printf '%-9s %-8s %-9s %-14s %-14s %s fps\n' \
        "$q" "${per:-?}" "${st1:-?}" "${hw1:-?}" "${hw2:-?}" "$(( d / 2 ))"
    sleep 0.8
done

pw-metadata -n settings 0 clock.force-quantum 0 >/dev/null 2>&1
echo
echo "Expected while audio is really playing: ~48000 fps (or your configured rate)."
echo "A stalled pointer (0, or one period only) means the DSP is not consuming."
