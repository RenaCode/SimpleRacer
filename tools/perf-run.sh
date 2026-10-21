#!/bin/zsh
# Pomiar wydajności wyścigu w każdej krainie: czas ładowania, czasy klatek, praca CPU w klatce, pamięć procesu.
#   tools/perf-run.sh <simulator-udid> <out-dir> [extra launch args...]
# Wymaga zainstalowanego buildu Debug/Family. Zmienne: WAIT (s jazdy na wyścig), REGIONS, CAR.
# Symulator rysuje na GPU Maca i ma vsync 60 Hz — czas klatki pokazuje przycięcia, a nie zapas GPU iPada;
# porównuj pracę CPU, ładowanie i pamięć, zawsze A/B na tym samym symulatorze.
set -u
SIM=$1 OUT=${2:A}; shift 2
WAIT=${WAIT:-45}
mkdir -p $OUT
typeset -A T; T=(city 1 coast 9 desert 17 forest 25 snow 33)
for r in ${=REGIONS:-city coast desert forest snow}; do
  car=(); [[ -n ${CAR:-} ]] && car=(-car $CAR)
  xcrun simctl terminate $SIM com.renacode.simpleracer 2>/dev/null
  xcrun simctl launch --stdout=$OUT/$r.log --stderr=$OUT/$r.log $SIM com.renacode.simpleracer \
    -mute -autostartRace -track $T[$r] "${car[@]}" "$@" >/dev/null
  sleep $WAIT
  pid=$(xcrun simctl spawn $SIM launchctl list 2>/dev/null | awk '/com.renacode.simpleracer/ {print $1}')
  mem=$( [[ -n $pid && $pid != - ]] && footprint -p $pid 2>/dev/null | awk '/phys_footprint:/ {print $2, $3}' | head -1)
  printf '%-7s %s | %s | %s | pamięć %s\n' $r \
    "$(grep -h 'ładowanie wyścigu' $OUT/$r.log | tail -1 | sed 's/.*ładowanie/ładowanie/')" \
    "$(grep -h 'klatki:' $OUT/$r.log | tail -1 | sed 's/.*klatki/klatki/')" \
    "$(grep -h 'praca CPU' $OUT/$r.log | tail -1 | sed 's/.*praca/praca/')" "${mem:-?}"
done
xcrun simctl terminate $SIM com.renacode.simpleracer 2>/dev/null
