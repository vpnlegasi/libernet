#!/bin/bash

# PING Loop Wrapper
# Modded By Vpn Legasi

if [ "$(id -u)" != "0" ]; then
  echo "This script must be run as root" 1>&2
  exit 1
fi

SERVICE_NAME="PING loop"
SYSTEM_CONFIG="${LIBERNET_DIR}/system/config.json"
INTERVAL="3"
HOST="m.pubgmobile.com"

function http_ping() {
  local hosts=(
    "m.pubgmobile.com"
    "www.google.com"
    "www.bing.com"
    "cdn.cloudflare.com"
  )
  local success=0
  for h in "${hosts[@]}"; do
    if httping -qi "${INTERVAL}" -t "${INTERVAL}" "$h" >/dev/null 2>&1; then
      HOST="$h"
      success=1
      break
    fi
  done

  # fallback Host
  if [[ $success -eq 0 ]]; then
    HOST="m.pubgmobile.com"
  fi
}

function loop() {
  while true; do
    http_ping
    sleep $INTERVAL
  done
}

function run() {
  # write to service log
  "${LIBERNET_DIR}/bin/log.sh" -w "Starting ${SERVICE_NAME} service"
  echo -e "Starting ${SERVICE_NAME} service ..."
  screen -AmdS ping-loop "${LIBERNET_DIR}/bin/ping-loop.sh" -l \
    && echo -e "${SERVICE_NAME} service started!"
}

function stop() {
  # write to service log
  "${LIBERNET_DIR}/bin/log.sh" -w "Stopping ${SERVICE_NAME} service"
  echo -e "Stopping ${SERVICE_NAME} service ..."
  kill $(screen -list | grep ping-loop | awk -F '[.]' {'print $1'}) > /dev/null 2>&1
  echo -e "${SERVICE_NAME} service stopped!"
}

function usage() {
  cat <<EOF
Usage:
  -r  Run ${SERVICE_NAME} service
  -s  Stop ${SERVICE_NAME} service
EOF
}

case "${1}" in
  -r)
    run
    ;;
  -s)
    stop
    ;;
  -l)
    loop
    ;;
  *)
    usage
    ;;
esac
