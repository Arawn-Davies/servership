#!/bin/bash
# bmcfleet - unified IPMI dashboard across mixed BMC vendors (iLO2, iDRAC6).
# One protocol (IPMI 2.0 / lanplus) works identically on all of them.
#
# Creds come from a .env file (gitignored - never commit real creds):
#   ILO_IP=...      ILO_USER=...      ILO_PASS=...
#   IDRAC_IP=...    IDRAC_USER=...    IDRAC_PASS=...
#
# Usage: bmcfleet.sh [path/to/.env]   (defaults to ./.env)
#
# Power CONTROL is just as unified:
#   ipmitool -I lanplus -H <ip> -U <u> -P <p> chassis power on|off|cycle|reset|soft

ENVF="${1:-.env}"
[ -f "$ENVF" ] || { echo "no env file: $ENVF (copy .env.example -> .env)"; exit 1; }
set -a; . "$ENVF"; set +a

IPMI() { ipmitool -I lanplus -H "$1" -U "$2" -P "$3" "${@:4}" 2>/dev/null; }

row() { # label ip user pass
  local label="$1" ip="$2" user="$3" pass="$4"
  [ -z "$ip" ] && return
  local pw amb fans draw
  pw=$(IPMI "$ip" "$user" "$pass" chassis power status | awk '{print $NF}')
  amb=$(IPMI "$ip" "$user" "$pass" sdr type temperature | grep -i ambient | head -1 | awk -F'|' '{gsub(/ /,"",$5);print $5}')
  fans=$(IPMI "$ip" "$user" "$pass" sdr type fan | grep -c RPM)
  draw=$(IPMI "$ip" "$user" "$pass" sdr | grep -iE 'watt' | head -1 | awk -F'|' '{gsub(/^ +| +$/,"",$2);print $2}')
  printf "%-12s %-14s %-7s %-10s %-5s %s\n" \
    "$label" "$ip" "${pw:-unreach}" "${amb:-?}" "${fans:-0}" "${draw:-n/a}"
}

printf "%-12s %-14s %-7s %-10s %-5s %s\n" NODE BMC POWER AMBIENT FANS DRAW
printf "%.0s-" {1..62}; echo
row SQUIDBLADE "$ILO_IP"   "$ILO_USER"   "$ILO_PASS"
row SQUIDBOAT  "$IDRAC_IP" "$IDRAC_USER" "$IDRAC_PASS"
