#!/bin/bash

# MOD By VPN Legasi
# Libernet Installer

if [ "$(id -u)" != "0" ]; then
  echo "This script must be run as root" 1>&2
  exit 1
fi

HOME="/root"
ARCH="$(grep 'DISTRIB_ARCH' /etc/openwrt_release | awk -F '=' '{print $2}' | sed "s/'//g")"
LIBERNET_DIR="${HOME}/libernet"
LIBERNET_WWW="/www/libernet"
STATUS_LOG="${LIBERNET_DIR}/log/status.log"
DOWNLOADS_DIR="${HOME}/Downloads"
LIBERNET_TMP="${DOWNLOADS_DIR}/libernet"
REPOSITORY_URL="https://github.com/vpnlegasi/libernet"

function install_packages() {
  while IFS= read -r line; do
    # install package if not installed yet
    if [[ $(opkg list-installed "${line}" | grep -c "${line}") != "1" ]]; then
      opkg install "${line}"
    fi
  done < requirements.txt
}

function install_proprietary_binaries() {
  echo -e "Installing proprietary binaries"
  while IFS= read -r line; do
    if ! which ${line} > /dev/null 2>&1; then
      bin="/usr/bin/${line}"
      echo "Installing ${line} ..."
      curl -sLko "${bin}" "https://github.com/vpnlegasi/resources/Libernet/proprietary/raw/main/${ARCH}/binaries/${line}"
      chmod +x "${bin}"
    fi
  done < binaries.txt
}

function install_proprietary_packages() {
  echo -e "Installing proprietary packages"
  while IFS= read -r line; do
    if ! which ${line} > /dev/null 2>&1; then
      pkg="/tmp/${line}.ipk"
      echo "Installing ${line} ..."
      curl -sLko "${pkg}" "https://github.com/vpnlegasi/resources/Libernet/proprietary/raw/main/${ARCH}/packages/${line}.ipk"
      opkg install "${pkg}"
      rm -rf "${pkg}"
    fi
  done < packages.txt
}

function install_proprietary() {
  install_proprietary_binaries
  install_proprietary_packages
}

function install_prerequisites() {
  # update packages index
  opkg update
}

function install_requirements() {
  echo -e "Installing packages" \
    && install_prerequisites \
    && install_packages \
    && install_proprietary
}

function enable_uhttp_php() {
  if ! grep -q ".php=/usr/bin/php-cgi" /etc/config/uhttpd; then
    echo -e "Enabling uhttp php execution" \
      && uci set uhttpd.main.interpreter='.php=/usr/bin/php-cgi' \
      && uci add_list uhttpd.main.index_page='index.php' \
      && uci commit uhttpd \
      && echo -e "Restarting uhttp service" \
      && /etc/init.d/uhttpd restart
  else
    echo -e "uhttp php already enabled, skipping ..."
  fi
}

function add_libernet_environment() {
  if ! grep -q LIBERNET_DIR /etc/profile; then
    echo -e "Adding Libernet environment" \
      && echo -e "\n# Libernet\nexport LIBERNET_DIR=${LIBERNET_DIR}" | tee -a '/etc/profile'
  fi
}

function install_libernet() {
  # stop Libernet before install
  if [[ -f "${LIBERNET_DIR}/bin/service.sh" && $(cat "${STATUS_LOG}") != "0" ]]; then
    echo -e "Stopping Libernet"
    "${LIBERNET_DIR}/bin/service.sh" -ds > /dev/null 2>&1
  fi
  # removing directories that might contains garbage
  rm -rf "${LIBERNET_WWW}"
  # install Libernet
  echo -e "Installing Libernet" \
    && mkdir -p "${LIBERNET_DIR}" \
    && echo -e "Copying binary" \
    && cp -arvf bin "${LIBERNET_DIR}/" \
    && echo -e "Copying system" \
    && cp -arvf system "${LIBERNET_DIR}/" \
    && echo -e "Copying log" \
    && cp -arvf log "${LIBERNET_DIR}/" \
    && echo -e "Copying web files" \
    && mkdir -p "${LIBERNET_WWW}" \
    && cp -arvf web/* "${LIBERNET_WWW}/" \
    && echo -e "Configuring Libernet" \
    && sed -i "s/LIBERNET_DIR/$(echo ${LIBERNET_DIR} | sed 's/\//\\\//g')/g" "${LIBERNET_WWW}/config.inc.php"
}

function configure_legasi_firewall() {
  if ! uci get network.legasi > /dev/null 2>&1; then
    echo "Configuring Legasi firewall" \
      && uci set network.legasi=interface \
      && uci set network.legasi.proto='none' \
      && uci set network.legasi.ifname='tun1' \
      && uci commit \
      && uci add firewall zone \
      && uci set firewall.@zone[-1].network='legasi' \
      && uci set firewall.@zone[-1].name='legasi' \
      && uci set firewall.@zone[-1].masq='1' \
      && uci set firewall.@zone[-1].mtu_fix='1' \
      && uci set firewall.@zone[-1].input='REJECT' \
      && uci set firewall.@zone[-1].forward='REJECT' \
      && uci set firewall.@zone[-1].output='ACCEPT' \
      && uci commit \
      && uci add firewall forwarding \
      && uci set firewall.@forwarding[-1].src='lan' \
      && uci set firewall.@forwarding[-1].dest='legasi' \
      && uci commit \
      && /etc/init.d/network restart
  fi
}

function configure_legasi_service() {
  echo -e "Configuring Legasi service"
  # disable services startup
  # DoT
  /etc/init.d/stubby disable
  # shadowsocks
  /etc/init.d/shadowsocks-libev disable
  # openvpn
  /etc/init.d/openvpn disable
  # stunnel
  /etc/init.d/stunnel disable
}

function setup_system_logs() {
  echo -e "Setup system logs"
  logs=("status.log" "service.log" "connected.log")
  for log in "${logs[@]}"; do
    if [[ ! -f "${LIBERNET_DIR}/log/${log}" ]]; then
      touch "${LIBERNET_DIR}/log/${log}"
    fi
  done
}

function finish_install() {
  router_ip="$(ifconfig br-lan | grep 'inet addr:' | awk '{print $2}' | awk -F ':' '{print $2}')"
  echo -e "Libernet successfully installed!\nLibernet URL: http://${router_ip}/libernet"
}

function clean_install() {
  chmod +x /root/libernet/bin/*
  rm -rf ~/Downloads
  rm -rf /root/libernet.sh
  sleep 5
  reboot
}

function main_installer() {
  install_requirements \
    && install_libernet \
    && add_libernet_environment \
    && enable_uhttp_php \
    && configure_legasi_firewall \
    && configure_legasi_service \
    && setup_system_logs \
    && finish_install \
    && clean_install
}

function main() {
  # install git if it's unavailable
  if [[ $(opkg list-installed git | grep -c git) != "1" ]]; then
    opkg update \
      && opkg install git
  fi
  if [[ $(opkg list-installed git-http | grep -c git-http) != "1" ]]; then
    opkg update \
      && opkg install git-http
  fi
  # create ~/Downloads directory if not exist
  if [[ ! -d "${DOWNLOADS_DIR}" ]]; then
    mkdir -p "${DOWNLOADS_DIR}"
  fi
  # install Libernet
  if [[ ! -d "${LIBERNET_TMP}" ]]; then
    git clone --depth 1 "${REPOSITORY_URL}" "${LIBERNET_TMP}" \
      && cd "${LIBERNET_TMP}" \
      && bash install.sh
  else
    cd "${LIBERNET_TMP}" \
      && main_installer
  fi
}

main
