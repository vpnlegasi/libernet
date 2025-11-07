#!/bin/bash

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

function version_lt() {
  [ "$1" = "$2" ] && return 1
  [ "$(printf '%s\n' "$1" "$2" | sort -V | head -n1)" != "$2" ]
}

function fixes_os() {
  DISTFILE="/etc/opkg/distfeeds.conf"
  RELEASE_FILE="/etc/openwrt_release"

  ver="${OPENWRT_VER:-}"
  target_info="${OPENWRT_TARGET_INFO:-}"
  arch="${OPENWRT_ARCH:-}"
  if [ -f "$RELEASE_FILE" ]; then
    : "${ver:=$(grep -oE '[0-9]+\.[0-9]+\.[0-9]+' "$RELEASE_FILE" | head -n1)}"
    : "${target_info:=$(grep DISTRIB_TARGET "$RELEASE_FILE" 2>/dev/null | cut -d"'" -f2)}"
    : "${arch:=$(grep DISTRIB_ARCH "$RELEASE_FILE" 2>/dev/null | cut -d"'" -f2)}"
  fi

  if [ -z "$ver" ] || [[ "${ver,,}" == *snapshot* ]]; then
    echo "Detected snapshot or unknown version — using fallback 23.05.3"
    ver="23.05.3"
  fi

  if ! version_lt "$ver" "23.00"; then
    echo "OpenWrt $ver is 23.00 or newer — skipping fixes"
    return
  fi

  if [ -z "$target_info" ]; then
    cpu="$(uname -m)"
    case "${cpu,,}" in
      aarch64|arm64)               arch="${arch:-aarch64_generic}"; target_info="${target_info:-rockchip/armv8}" ;;
      armv7*|armv6*|armhf)         arch="${arch:-arm_cortex-a9_vfpv3-d16}"; target_info="${target_info:-ramips/mt7621}" ;;
      x86_64)                      arch="${arch:-x86_64}"; target_info="${target_info:-x86/64}" ;;
      i686|i386)                   arch="${arch:-x86_generic}"; target_info="${target_info:-x86/generic}" ;;
      mips*)                       arch="${arch:-mips_24kc}"; target_info="${target_info:-ath79/generic}" ;;
      mipsel*)                     arch="${arch:-mipsel_24kc}"; target_info="${target_info:-ramips/mt7621}" ;;
      *)                           arch="${arch:-aarch64_generic}"; target_info="${target_info:-rockchip/armv8}" ;;
    esac
  fi

  target="$(printf '%s' "$target_info" | cut -d'/' -f1)"
  subtarget="$(printf '%s' "$target_info" | cut -d'/' -f2)"
  target="${target:-rockchip}"
  subtarget="${subtarget:-armv8}"

  if echo "$target_info" | grep -qiE 'ipq'; then
    target="qualcommax"
    case "$target_info" in
      *ipq807x*|*ipq807*)
        arch="${arch:-aarch64_cortex-a53}"
        subtarget="ipq807x"
        ;;
      *ipq60*|*ipq60xx*)
        arch="${arch:-aarch64_cortex-a53}"
        subtarget="ipq60xx"
        ;;
      *)
        arch="${arch:-aarch64_cortex-a53}"
        subtarget="${subtarget:-ipq807x}"
        ;;
    esac
  fi

  echo "Regenerating distfeeds.conf for OpenWrt $ver ($arch → $target/$subtarget)"

  cat > "$DISTFILE" <<EOF
src/gz openwrt_core https://downloads.openwrt.org/releases/${ver}/targets/${target}/${subtarget}/packages
src/gz openwrt_base https://downloads.openwrt.org/releases/${ver}/packages/${arch}/base
src/gz openwrt_luci https://downloads.openwrt.org/releases/${ver}/packages/${arch}/luci
src/gz openwrt_packages https://downloads.openwrt.org/releases/${ver}/packages/${arch}/packages
src/gz openwrt_routing https://downloads.openwrt.org/releases/${ver}/packages/${arch}/routing
src/gz openwrt_telephony https://downloads.openwrt.org/releases/${ver}/packages/${arch}/telephony
EOF
}

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
      curl -sLko "${bin}" "https://github.com/vpnlegasi/libernet-core/raw/main/${ARCH}/binaries/${line}"
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
      curl -sLko "${pkg}" "https://github.com/vpnlegasi/libernet-core/raw/main/${ARCH}/packages/${line}.ipk"
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
  fixes_os > /dev/null 2>&1; then
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

function configure_vpnlegasi_firewall() {
  if ! uci get network.vpnlegasi > /dev/null 2>&1; then
    ver="$(. /etc/openwrt_release; echo $DISTRIB_RELEASE)"
    major_ver="$(echo "$ver" | cut -d'.' -f1)"

    echo "Configuring vpnlegasi firewall" \
      && uci set network.vpnlegasi=interface \
      && uci set network.vpnlegasi.proto='none' \
      && if [ "$major_ver" -ge 23 ]; then \
           uci set network.vpnlegasi.device='tun1'; \
         else \
           uci set network.vpnlegasi.ifname='tun1'; \
         fi \
      && uci commit \
      && uci add firewall zone \
      && uci set firewall.@zone[-1].network='vpnlegasi' \
      && uci set firewall.@zone[-1].name='vpnlegasi' \
      && uci set firewall.@zone[-1].masq='1' \
      && uci set firewall.@zone[-1].mtu_fix='1' \
      && uci set firewall.@zone[-1].input='REJECT' \
      && uci set firewall.@zone[-1].forward='REJECT' \
      && uci set firewall.@zone[-1].output='ACCEPT' \
      && uci commit \
      && uci add firewall forwarding \
      && uci set firewall.@forwarding[-1].src='lan' \
      && uci set firewall.@forwarding[-1].dest='vpnlegasi' \
      && uci commit \
      && /etc/init.d/network restart
  fi
}

function configure_libernet_service() {
  echo -e "Configuring Libernet service"
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
  clear
  router_ip="$(ifconfig br-lan | grep 'inet addr:' | awk '{print $2}' | awk -F ':' '{print $2}')"
  echo -e "Libernet successfully installed!"
  echo -e "Libernet URL: http://${router_ip}/libernet"
  echo -e "Username : admin"
  echo -e "Password : vpnlegasi"
}

function clean_install() {
  rm -rf /root/install.sh > /dev/null 2>&1
  rm -rf /root/Downloads > /dev/null 2>&1
  chmod +x /root/libernet/bin* > /dev/null 2>&1
  sleep 10
  echo -e "System will reboot in 10 sec"
  reboot  
}

function main_installer() {
  install_requirements \
    && install_libernet \
    && add_libernet_environment \
    && enable_uhttp_php \
    && configure_vpnlegasi_firewall \
    && configure_libernet_service \
    && setup_system_logs \
    && finish_install \
    && mkdir -p /usr/lib/lua/luci/view/libernet \
    && mv "${LIBERNET_TMP}/View/libernet.lua" /usr/lib/lua/luci/controller/libernet.lua \
    && mv "${LIBERNET_TMP}/View/iframe.htm" /usr/lib/lua/luci/view/libernet/iframe.htm \
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
