#!/bin/sh
# Attend une machine calme (CPU < 20 % sur trois relevés de suite, 50 min au plus), puis lance le banc complet
# (ou les tests dont le nom contient $1). À lancer depuis le dossier de l'app : sh tests/calm_bench.sh [filtre]
cpu() { powershell -NoProfile -Command "(Get-CimInstance Win32_Processor | Measure-Object -Property LoadPercentage -Average).Average" | tr -d '\r'; }
calm=0; waited=0
while [ $calm -lt 3 ] && [ $waited -lt 3000 ]; do
  c=$(cpu)
  if [ "${c:-100}" -lt 20 ]; then calm=$((calm+1)); else calm=0; fi
  sleep 10; waited=$((waited+10))
done
echo "attente ${waited} s, calme=${calm}, CPU au départ : $(cpu) %"
PYTHONIOENCODING=utf-8 python -I tests/run_tests.py ${1:+--filter "$1"} 2>&1 | grep -a -v "^PASS" | grep -a "FAIL\|obtenu\|error\|\.lua:\|tests,\|LINT\|B0"
echo "CPU à la fin : $(cpu) %"
