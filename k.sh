#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "[${red}Error${plain}] Please run this script as root!" && exit 1

# ----------------------------
# SYSTEM CHECK
# ----------------------------
disable_selinux(){
    if [ -s /etc/selinux/config ] && grep -q 'SELINUX=enforcing' /etc/selinux/config; then
        sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
        setenforce 0 2>/dev/null
    fi
}

check_sys(){
    local checkType=$1
    local value=$2
    local release=''
    local systemPackage=''

    if grep -Eqi "debian|raspbian" /etc/issue || grep -Eqi "debian|raspbian" /proc/version; then
        release="debian"
        systemPackage="apt"
    elif grep -Eqi "ubuntu" /etc/issue || grep -Eqi "ubuntu" /proc/version; then
        release="ubuntu"
        systemPackage="apt"
    fi

    [[ "${checkType}" == "sysRelease" && "${value}" == "${release}" ]] && return 0
    [[ "${checkType}" == "packageManager" && "${value}" == "${systemPackage}" ]] && return 0
    return 1
}

install_check(){
    check_sys packageManager apt
}

ready_install(){
    echo -e "[${green}Info${plain}] Checking system..."
    if ! install_check; then
        echo -e "[${red}Error${plain}] Only Debian / Ubuntu supported"
        exit 1
    fi

    apt update
    apt -y install net-tools wget curl
    disable_selinux
}

# ----------------------------
# UTIL
# ----------------------------
get_ip(){
    ip addr | awk '/inet /{print $2}' | cut -d/ -f1 \
    | grep -Ev "^(127|10|192\.168|172\.(1[6-9]|2[0-9]|3[0-2]))" | head -n1 \
    || curl -s ipv4.icanhazip.com
}

check_ip(){
    echo "$1" | grep -Eq '^([0-9]{1,3}\.){3}[0-9]{1,3}$'
}

download(){
    echo -e "[${green}Info${plain}] Downloading $1"
    wget -q -O "$1" "$2" || { echo -e "[${red}Error${plain}] Download failed"; exit 1; }
}

# ----------------------------
# DNSMASQ
# ----------------------------
compile_dnsmasq(){
    apt -y install make gcc g++ pkg-config nettle-dev gettext libidn11-dev libnetfilter-conntrack-dev libdbus-1-dev
    cd /tmp || exit
    download dnsmasq.tar.gz https://thekelleys.org.uk/dnsmasq/dnsmasq-2.91.tar.gz
    tar zxf dnsmasq.tar.gz
    cd dnsmasq-2.91 || exit
    make all-i18n COPTS='-DHAVE_DNSSEC -DHAVE_IDN -DHAVE_CONNTRACK -DHAVE_DBUS'
    cp src/dnsmasq /usr/sbin/dnsmasq
    chmod +x /usr/sbin/dnsmasq
}

install_dnsmasq(){
    echo -e "[${green}Info${plain}] Installing dnsmasq"
    fuser -k 53/tcp 53/udp 2>/dev/null
    apt -y install dnsmasq

    [[ "$fastmode" == "0" ]] && compile_dnsmasq

    download /etc/dnsmasq.d/custom_netflix.conf \
        https://raw.githubusercontent.com/myxuchangbin/dnsmasq_sniproxy_install/master/dnsmasq.conf
    download /tmp/proxy-domains.txt \
        https://raw.githubusercontent.com/myxuchangbin/dnsmasq_sniproxy_install/master/proxy-domains.txt

    for d in $(cat /tmp/proxy-domains.txt); do
        echo "address=/$d/$publicip" >> /etc/dnsmasq.d/custom_netflix.conf
    done

    grep -q conf-dir=/etc/dnsmasq.d /etc/dnsmasq.conf || echo "conf-dir=/etc/dnsmasq.d" >> /etc/dnsmasq.conf
    sed -i 's/^#IGNORE_RESOLVCONF=yes/IGNORE_RESOLVCONF=yes/' /etc/default/dnsmasq

    systemctl enable dnsmasq
    systemctl restart dnsmasq
}

undnsmasq(){
    systemctl stop dnsmasq
    systemctl disable dnsmasq
    apt -y remove dnsmasq dnsmasq-base
    rm -f /etc/dnsmasq.d/custom_netflix.conf
}

# ----------------------------
# SNIPROXY
# ----------------------------
install_sniproxy(){
    echo -e "[${green}Info${plain}] Installing sniproxy"
    apt -y install libev-dev libpcre3-dev libudns-dev autotools-dev build-essential

    if [[ "$fastmode" == "1" ]]; then
        download /tmp/sniproxy.deb \
          https://github.com/myxuchangbin/dnsmasq_sniproxy_install/raw/master/sniproxy/sniproxy_0.6.1_amd64.deb
        dpkg -i /tmp/sniproxy.deb
    else
        cd /tmp || exit
        download sniproxy.tar.gz https://github.com/dlundquist/sniproxy/archive/refs/tags/0.6.1.tar.gz
        tar zxf sniproxy.tar.gz
        cd sniproxy-0.6.1 || exit
        ./autogen.sh && ./configure --prefix=/usr && make && make install
    fi

    download /etc/systemd/system/sniproxy.service \
      https://raw.githubusercontent.com/myxuchangbin/dnsmasq_sniproxy_install/master/sniproxy.service
    download /etc/sniproxy.conf \
      https://raw.githubusercontent.com/myxuchangbin/dnsmasq_sniproxy_install/master/sniproxy.conf

    systemctl daemon-reload
    systemctl enable sniproxy
    systemctl restart sniproxy
}

unsniproxy(){
    systemctl stop sniproxy
    systemctl disable sniproxy
    apt -y remove sniproxy
    rm -f /etc/sniproxy.conf
}

# ----------------------------
# MAIN
# ----------------------------
install_all(){
    publicip=$(get_ip)
    ready_install
    install_dnsmasq
    install_sniproxy
    echo -e "${yellow}DONE: DNSMASQ + SNIPROXY INSTALLED${plain}"
}

menu(){
    echo "1) Install (compile)"
    echo "2) Install (fast)"
    echo "3) Uninstall all"
    echo "0) Exit"
    read -p "Select: " x
    case $x in
        1) fastmode=0; install_all ;;
        2) fastmode=1; install_all ;;
        3) undnsmasq; unsniproxy ;;
        0) exit ;;
    esac
}

menu
