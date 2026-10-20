#!/bin/zsh
# Stały kadr każdej krainy (kamera wyścigu i z boku) do porównań wyglądu przed/po.
#   tools/scenery-shots.sh <simulator-udid> <out-dir> [extra launch args...]
# Wymaga zainstalowanego buildu Debug/Family. Zmienne: SHOT (miejsce na trasie, m), WAIT (s), REGIONS.
# Zrzuty pionowe (iOS 26+) obracamy do poziomu. Log czasu klatki: <out>/<kraina>-<kadr>.log.
set -u
# simctl launch --stdout z względną ścieżką nie uruchamia aplikacji („No such process”) — zawsze bezwzględna.
SIM=$1 OUT=${2:A}; shift 2
SHOT=${SHOT:-150} WAIT=${WAIT:-26}
mkdir -p $OUT
typeset -A T; T=(city 1 coast 9 desert 17 forest 25 snow 33)
for r in ${=REGIONS:-city coast desert forest snow}; do
  for cam in race side; do
    extra=(); [[ $cam == side ]] && extra=(-sideCam)
    xcrun simctl terminate $SIM com.renacode.simpleracer 2>/dev/null
    xcrun simctl launch --stdout=$OUT/$r-$cam.log --stderr=$OUT/$r-$cam.log $SIM com.renacode.simpleracer \
      -mute -autostartRace -track $T[$r] -shotAt $SHOT "${extra[@]}" "$@" >/dev/null
    sleep $WAIT
    xcrun simctl io $SIM screenshot --type=png $OUT/$r-$cam.png >/dev/null 2>&1
    # iOS 26+ zapisuje zrzut iPada pionowo, ale po restarcie symulatora bywa już poziomy — obracamy tylko pionowe.
    w=$(sips -g pixelWidth $OUT/$r-$cam.png | awk '/pixelWidth/ {print $2}')
    h=$(sips -g pixelHeight $OUT/$r-$cam.png | awk '/pixelHeight/ {print $2}')
    (( h > w )) && sips -r 270 $OUT/$r-$cam.png >/dev/null
    echo "$r-$cam: $(grep -h 'klatki:' $OUT/$r-$cam.log | tail -1 | sed 's/.*klatki/klatki/')"
  done
done
xcrun simctl terminate $SIM com.renacode.simpleracer 2>/dev/null
