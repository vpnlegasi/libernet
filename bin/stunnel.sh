#!/bin/bash
# Modded By Vpn Legasi

SERVICE_NAME="Stunnel"
STUNNEL_DIR="${LIBERNET_DIR}/bin/config/stunnel"

if [ "$(id -u)" != "0" ]; then
  echo "This script must be run as root" 1>&2
  exit 1
fi

function tlsmod() {
  cp -af "${LIBERNET_DIR}/bin/config/stunnel/templates/stunnel-tls.conf" "${STUNNEL_CONFIG}"
  sed -i "s/^connect = .*/connect = ${STUNNEL_HOST}:${STUNNEL_PORT}/g" "${STUNNEL_CONFIG}"
  sed -i "s/^sni = .*/sni = ${STUNNEL_SNI}/g" "${STUNNEL_CONFIG}"
  sed -i "s|^cert = .*|cert = ${LIBERNET_DIR}/bin/config/stunnel/stunnel.pem|g" "${STUNNEL_CONFIG}"
}

function nontls() {
  cp -af "${LIBERNET_DIR}/bin/config/stunnel/templates/stunnel-non.conf" "${STUNNEL_CONFIG}"
  sed -i "s/^connect = .*/connect = ${STUNNEL_HOST}:${STUNNEL_PORT}/g" "${STUNNEL_CONFIG}"
}

function configure() {
  STUNNEL_MODE="${1}"
  STUNNEL_PROFILE="${2}"
  STUNNEL_HOST="${3}"
  STUNNEL_PORT="${4}"
  STUNNEL_SNI="${5}"
  STUNNEL_TLS="${6}"
  STUNNEL_CONFIG="${STUNNEL_DIR}/${STUNNEL_MODE}/${STUNNEL_PROFILE}.conf"

  [ ! -d "${STUNNEL_DIR}/${STUNNEL_MODE}" ] && mkdir -p "${STUNNEL_DIR}/${STUNNEL_MODE}"

  if [[ "${STUNNEL_TLS}" == "true" ]]; then
    tlsmod
  else
    nontls
  fi
}

function run() {
  "${LIBERNET_DIR}/bin/log.sh" -w "Starting ${SERVICE_NAME} service"
  echo -e "Starting ${SERVICE_NAME} service ..."
  configure "${1}" "${2}" "${3}" "${4}" "${5}" "${6}" \
    && screen -AmdS stunnel bash -c "while true; do stunnel \"${STUNNEL_CONFIG}\" || true; sleep 3; done" \
    && echo -e "${SERVICE_NAME} service started!"
}

function stop() {
  "${LIBERNET_DIR}/bin/log.sh" -w "Stopping ${SERVICE_NAME} service"
  echo -e "Stopping ${SERVICE_NAME} service ..."
  screen -list | grep stunnel | awk -F '[.]' '{print $1}' | xargs -r kill
  killall -q stunnel 2>/dev/null
  echo -e "${SERVICE_NAME} service stopped!"
}

function usage() {
  cat <<EOF
Usage:
  ${0} -r <mode> <profile> <host> <port> <sni> <tls>
  ${0} -s

Example:
  ${0} -r client myprofile example.com 443 www.example.com true
  ${0} -s
EOF
}


case "${1}" in
  -r)
    # command mode profile host port sni tls
    run "${2}" "${3}" "${4}" "${5}" "${6}" "${7}"
  ;;
  -s)
    stop
  ;;
  *)
    usage
  ;;
esac
