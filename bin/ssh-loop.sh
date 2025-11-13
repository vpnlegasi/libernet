#!/bin/bash

# Libernet Service Wrapper
# Modded By Vpn Legasi

if [ "$(id -u)" != "0" ]; then
  echo "This script must be run as root" 1>&2
  exit 1
fi

function connect() {
  sshpass -p "${2}" ssh \
    -4CND "${5}" \
    -p "${4}" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "${1}@${3}"
}

function connect_with_proxy() {
  sshpass -p "${2}" ssh \
    -4CND "${5}" \
    -p "${4}" \
    -o ProxyCommand="/usr/bin/corkscrew ${6} ${7} %h %p" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "${1}@${3}"
}

# fungsi semak IP dan bandingkan
function check_ip() {
  CURRENT_IP=$(ip -4 addr show | grep -v "127.0.0.1" | grep inet | awk '{print $2}' | cut -d/ -f1 | head -n1)
  if [[ -z "$CURRENT_IP" ]]; then
    # tiada IP detected, reconnect
    "${LIBERNET_DIR}/bin/log.sh" -w "SSH tunnel lost IP, restarting..."
    return 1
  fi

  if [[ "$CURRENT_IP" != "$LAST_IP" ]]; then
    LAST_IP="$CURRENT_IP"
    "${LIBERNET_DIR}/bin/log.sh" -w "SSH tunnel IP changed, restarting..."
    return 1
  fi

  return 0
}

LAST_IP=""

case "${1}" in
  -d)
    while true; do
      if ! check_ip; then
        sleep 3
        continue
      fi
      # command username password host port dynamic_port
      connect "${2}" "${3}" "${4}" "${5}" "${6}"
      sleep 3
    done
    ;;
  -e)
    while true; do
      if ! check_ip; then
        sleep 3
        continue
      fi
      # command username password host port dynamic_port proxy_ip proxy_port
      connect_with_proxy "${2}" "${3}" "${4}" "${5}" "${6}" "${7}" "${8}"
      sleep 3
    done
    ;;
esac
