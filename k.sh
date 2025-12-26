#!/usr/bin/env bash
PATH=/bin:/sbin:/usr/bin:/usr/sbin:/usr/local/bin:/usr/local/sbin:~/bin
export PATH

red='\033[0;31m'
green='\033[0;32m'
yellow='\033[0;33m'
plain='\033[0m'

[[ $EUID -ne 0 ]] && echo -e "[${red}Error${plain}] Please run this script as root!" && exit 1

disable_selinux(){
    if [ -s /etc/selinux/config ] && grep 'SELINUX=enforcing' /etc/selinux/config; then
        sed -i 's/SELINUX=enforcing/SELINUX=disabled/g' /etc/selinux/config
        setenforce 0
    fi
}

check_sys(){
    local checkType=$1
    local value=$2

    local release=''
    local systemPackage=''

    if grep -Eqi "debian|raspbian" /etc/issue; then
        release="debian"
        systemPackage="apt"
    elif grep -Eqi "ubuntu" /etc/issue; then
        release="ubuntu"
        systemPackage="apt"
    elif grep -Eqi "debian|raspbian" /proc/version; then
        release="debian"
        systemPackage="apt"
    elif grep -Eqi "ubuntu" /proc/version; then
        release="ubuntu"
        systemPackage="apt"
    fi

    if [[ "${checkType}" == "sysRelease" ]]; then
        if [ "${value}" == "${release}" ]; then
            return 0
        else
            return 1
        fi
    elif [[ "${checkType}" == "packageManager" ]]; then
        if [ "${value}" == "${systemPackage}" ]; then
            return 0
        else
            return 1
        fi
    fi
}

getversion(){
    grep -oE  "[0-9.]+" /etc/issue
}

get_ip(){
    local IP=$( ip addr | egrep -o '[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}' | egrep -v "^192\.168|^172\.1[6-9]\.|^172\.2[0-9]\.|^172\.3[0-2]\.|^10\.|^127\.|^255\.|^0\." | head -n 1 )
    [ -z ${IP} ] && IP=$( wget -qO- -t1 -T2 ipv4.icanhazip.com )
    [ -z ${IP} ] && IP=$( wget -qO- -t1 -T2 ipinfo.io/ip )
    echo ${IP}
}

check_ip(){
    local checkip=$1   
    local valid_check=$(echo $checkip|awk -F. '$1<=255&&$2<=255&&$3<=255&&$4<=255{print "yes"}')   
    if echo $checkip|grep -E "^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$" >/dev/null; then   
        if [ ${valid_check:-no} == "yes" ]; then   
            return 0   
        else   
            echo -e "[${red}Error${plain}] IP $checkip not available!"   
            return 1   
        fi   
    else   
        echo -e "[${red}Error${plain}] IP format error!"   
        return 1   
    fi
}

download(){
    local filename=${1}
    echo -e "[${green}Info${plain}] ${filename} download configuration now..."
    wget --no-check-certificate -q -t3 -T60 -O ${1} ${2}
    if [ $? -ne 0 ]; then
        echo -e "[${red}Error${plain}] Download ${filename} failed."
        exit 1
    fi
}

error_detect_depends(){
    local command=$1
    local depend=`echo "${command}" | awk '{print $4}'`
    echo -e "[${green}Info${plain}] Starting to install package ${depend}"
    ${command} > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "[${red}Error${plain}] Failed to install ${red}${depend}${plain}"
        exit 1
    fi
}

config_firewall(){
    if command -v systemctl >/dev/null 2>&1 && systemctl list-units --type=service | grep -q firewalld; then
        systemctl status firewalld > /dev/null 2>&1
        if [ $? -eq 0 ]; then
            default_zone=$(firewall-cmd --get-default-zone)
            for port in ${ports}; do
                firewall-cmd --permanent --zone=${default_zone} --add-port=${port}/tcp
                if [ ${port} == "53" ]; then
                    firewall-cmd --permanent --zone=${default_zone} --add-port=${port}/udp
                fi
            done
            firewall-cmd --reload
            echo -e "[Info] Firewall configuration complete using firewalld."
        else
            echo -e "[Warning] firewalld installed but not running, please enable ports ${ports} manually if necessary."
        fi
    else
        for port in ${ports}; do
            iptables -L -n | grep -i ${port} > /dev/null 2>&1
            if [ $? -ne 0 ]; then
                iptables -I INPUT -m state --state NEW -m tcp -p tcp --dport ${port} -j ACCEPT
                if [ ${port} == "53" ]; then
                    iptables -I INPUT -m state --state NEW -m udp -p udp --dport ${port} -j ACCEPT
                fi
            else
                echo -e "[Info] port ${port} already enabled."
            fi
        done

        if command -v netfilter-persistent >/dev/null 2>&1; then
            netfilter-persistent save
        elif command -v iptables-save >/dev/null 2>&1; then
            iptables-save > /etc/iptables/rules.v4
        fi
        echo -e "[Info] Firewall configuration complete using iptables."
    fi
}

install_dependencies(){
echo "Installing dependencies..."
    if [[ ${fastmode} = "1" ]]; then
        apt_depends=(
            curl gettext libev-dev libpcre3-dev libudns-dev
        )
    else
        apt_depends=(
            autotools-dev cdbs curl gettext libev-dev libpcre3-dev libudns-dev autoconf devscripts build-essential
        )
    fi
    apt-get -y update
    for depend in "${apt_depends[@]}"; do
        error_detect_depends "apt-get -y install ${depend}"
    done
    echo -e "[Info] Dependencies installation complete..."
}

compile_dnsmasq(){
    # Install build dependencies for Debian/Ubuntu
    error_detect_depends "apt -y install make"
    error_detect_depends "apt -y install gcc"
    error_detect_depends "apt -y install g++"
    error_detect_depends "apt -y install pkg-config"
    error_detect_depends "apt -y install nettle-dev"
    error_detect_depends "apt -y install gettext"
    error_detect_depends "apt -y install libidn11-dev"
    error_detect_depends "apt -y install libnetfilter-conntrack-dev"
    error_detect_depends "apt -y install libdbus-1-dev"

    [ -d /tmp/dnsmasq-2.91 ] && rm -rf /tmp/dnsmasq-2.91

    cd /tmp/
    download dnsmasq-2.91.tar.gz https://thekelleys.org.uk/dnsmasq/dnsmasq-2.91.tar.gz
    tar -zxf dnsmasq-2.91.tar.gz
    cd dnsmasq-2.91

    # Compile dnsmasq with required flags
    make all-i18n V=s COPTS='-DHAVE_DNSSEC -DHAVE_IDN -DHAVE_CONNTRACK -DHAVE_DBUS'
    if [ $? -ne 0 ]; then
        echo -e "[Error] dnsmasq compilation failed."
        rm -rf /tmp/dnsmasq-2.91 /tmp/dnsmasq-2.91.tar.gz
        exit 1
    fi
}

install_dnsmasq(){
    port53_pid=$(netstat -tulnp 2>/dev/null | grep -P "\d+\.\d+\.\d+\.\d+:53\s+" | awk '{print $7}' | cut -d'/' -f1)
    if [ -n "$port53_pid" ]; then
        echo -e "[Info] Port 53 is in use by PID: $port53_pid. Releasing..."
        kill -9 $port53_pid
        sleep 1
        echo -e "[Info] Port 53 released."
    fi

    echo "Installing Dnsmasq..."
    
    # Install dnsmasq via apt
    error_detect_depends "apt -y install dnsmasq"

    # Compile mode if fastmode=0
    if [[ ${fastmode} = "0" ]]; then
        compile_dnsmasq
        yes | cp -f /tmp/dnsmasq-2.91/src/dnsmasq /usr/sbin/dnsmasq && chmod +x /usr/sbin/dnsmasq
    fi

    # Check installation
    [ ! -f /usr/sbin/dnsmasq ] && echo -e "[Error] Dnsmasq installation failed, please check." && exit 1

    # Download custom Netflix config
    download /etc/dnsmasq.d/custom_netflix.conf https://raw.githubusercontent.com/myxuchangbin/dnsmasq_sniproxy_install/master/dnsmasq.conf
    download /tmp/proxy-domains.txt https://raw.githubusercontent.com/myxuchangbin/dnsmasq_sniproxy_install/master/proxy-domains.txt

    # Add domain rules
    for domain in $(cat /tmp/proxy-domains.txt); do
        printf "address=/${domain}/${publicip}\n" | tee -a /etc/dnsmasq.d/custom_netflix.conf > /dev/null 2>&1
    done

    # Ensure conf-dir line exists
    grep -qE "(conf-dir=/etc/dnsmasq.d)" /etc/dnsmasq.conf || echo -e "\nconf-dir=/etc/dnsmasq.d" >> /etc/dnsmasq.conf

    # Enable and start dnsmasq
    if grep -q "^#IGNORE_RESOLVCONF=yes" /etc/default/dnsmasq; then
        sed -i 's/^#IGNORE_RESOLVCONF=yes/IGNORE_RESOLVCONF=yes/' /etc/default/dnsmasq
    elif ! grep -q "^IGNORE_RESOLVCONF=yes" /etc/default/dnsmasq; then
        echo "IGNORE_RESOLVCONF=yes" >> /etc/default/dnsmasq
    fi

    systemctl enable dnsmasq
    systemctl restart dnsmasq || echo -e "[Error] Failed to start dnsmasq."

    # Cleanup
    cd /tmp
    rm -rf /tmp/dnsmasq-2.91 /tmp/dnsmasq-2.91.tar.gz /tmp/proxy-domains.txt

    echo -e "[Info] Dnsmasq installation complete..."
}

install_sniproxy(){
    for aport in 80 443 9443; do
        netstat -a -n -p | grep LISTEN | grep -P "\d+\.\d+\.\d+\.\d+:${aport}\s+" > /dev/null && echo -e "[Error] Required port ${aport} already in use\n" && exit 1
    done

    install_dependencies
    echo "Installing SNI Proxy..."

    # Remove old sniproxy if exists
    dpkg -s sniproxy >/dev/null 2>&1 && dpkg -r sniproxy

    bit=$(uname -m)
    cd /tmp

    # Download & extract source if fastmode=0
    if [[ ${fastmode} = "0" ]]; then
        rm -rf sniproxy-0.6.1
        download /tmp/sniproxy-0.6.1.tar.gz https://github.com/dlundquist/sniproxy/archive/refs/tags/0.6.1.tar.gz
        tar -zxf sniproxy-0.6.1.tar.gz
        cd sniproxy-0.6.1
        env NAME="sniproxy" DEBFULLNAME="sniproxy" DEBEMAIL="sniproxy@example.com" EMAIL="sniproxy@example.com" ./autogen.sh
        ./configure --prefix=/usr && make && make install
    fi  

    # Fastmode installation
    if [[ ${fastmode} = "1" ]]; then
        if [[ ${bit} = "x86_64" ]]; then
            download /tmp/sniproxy_0.6.1_amd64.deb https://github.com/myxuchangbin/dnsmasq_sniproxy_install/raw/master/sniproxy/sniproxy_0.6.1_amd64.deb
            error_detect_depends "dpkg -i --no-debsig /tmp/sniproxy_0.6.1_amd64.deb"
            rm -f /tmp/sniproxy_0.6.1_amd64.deb
        else
            echo -e "[Error] The ${bit} architecture is not supported, please use compile mode to install!" && exit 1
        fi
    fi  

    # Setup systemd service
    download /etc/systemd/system/sniproxy.service https://raw.githubusercontent.com/myxuchangbin/dnsmasq_sniproxy_install/master/sniproxy.service
    systemctl daemon-reload
    [ ! -f /etc/systemd/system/sniproxy.service ] && echo -e "[Error] Failed to download Sniproxy startup file, please check." && exit 1

    [ ! -f /usr/sbin/sniproxy ] && echo -e "[Error] Sniproxy installation failed, please check." && exit 1

    # Configure sniproxy
    download /etc/sniproxy.conf https://raw.githubusercontent.com/myxuchangbin/dnsmasq_sniproxy_install/master/sniproxy.conf
    download /tmp/sniproxy-domains.txt https://raw.githubusercontent.com/myxuchangbin/dnsmasq_sniproxy_install/master/proxy-domains.txt
    sed -i -e 's/\./\\\./g' -e 's/^/    \.\*/' -e 's/$/\$ \*/' /tmp/sniproxy-domains.txt || (echo -e "[Error] Failed to configure sniproxy." && exit 1)
    sed -i '/table {/r /tmp/sniproxy-domains.txt' /etc/sniproxy.conf || (echo -e "[Error] Failed to configure sniproxy." && exit 1)

    [ ! -d /var/log/sniproxy ] && mkdir /var/log/sniproxy

    # Start service
    echo "Starting SNI Proxy service..."
    systemctl enable sniproxy > /dev/null 2>&1
    systemctl restart sniproxy || (echo -e "[Error] Failed to start sniproxy." && exit 1)

    # Cleanup
    cd /tmp
    rm -rf /tmp/sniproxy-0.6.1/
    rm -rf /tmp/sniproxy-domains.txt

    echo -e "[Info] Sniproxy installation complete..."
}

install_check(){
    # Only Debian/Ubuntu
    if check_sys packageManager apt; then
        return 0
    else
        return 1
    fi
}

ready_install(){
    echo "Checking your system..."
    if ! install_check; then
        echo -e "[Error] Your OS is not supported to run this!"
        echo -e "Please switch to Debian 8+/Ubuntu 16+ and try again."
        exit 1
    fi

    # Update & install dependencies
    apt update
    error_detect_depends "apt-get -y install net-tools"
    error_detect_depends "apt-get -y install wget"

    disable_selinux

    echo -e "[Info] System check complete..."
}

install_all(){
    ports="53 80 443 9443"
    publicip=$(get_ip)
    hello
    ready_install
    install_dnsmasq
    install_sniproxy
    echo ""
    echo -e "${yellow}Dnsmasq + SNI Proxy installation completed!${plain}"
    echo ""
    echo -e "${yellow}Change your DNS to $(get_ip) to get My content.${plain}"
    echo ""
}

undnsmasq(){
    echo -e "[Info] Stopping dnsmasq services."
    
    # Disable & stop dnsmasq
    systemctl disable dnsmasq > /dev/null 2>&1
    systemctl stop dnsmasq || echo -e "[Error] Failed to stop dnsmasq."

    echo -e "[Info] Starting to uninstall dnsmasq services."
    
    # Remove dnsmasq packages
    apt-get remove dnsmasq -y > /dev/null 2>&1
    apt-get remove dnsmasq-base -y > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "[Error] Failed to uninstall dnsmasq"
    fi

    # Remove custom config
    rm -rf /etc/dnsmasq.d/custom_netflix.conf
    echo -e "[Info] dnsmasq uninstall complete..."
}

unsniproxy(){
    echo -e "[Info] Stopping sniproxy services."
    
    # Disable & stop sniproxy
    systemctl disable sniproxy > /dev/null 2>&1
    systemctl stop sniproxy || echo -e "[Error] Failed to stop sniproxy."

    echo -e "[Info] Starting to uninstall sniproxy services."
    
    # Remove sniproxy package
    apt-get remove sniproxy -y > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        echo -e "[Error] Failed to uninstall sniproxy"
    fi

    # Remove config
    rm -rf /etc/sniproxy.conf
    echo -e "[Info] Sniproxy uninstall complete..."
}

hello(){
    echo ""
    echo -e "${yellow}Dnsmasq + SNI Proxy self-install script${plain}"
    echo -e "${yellow}Supported OS:  Debian 8+, Ubuntu 16+${plain}"
    echo ""
}

menu(){
    hello
    echo "Please select an option:"
    echo "  1) Install Dnsmasq + SNI Proxy"
    echo "  2) Uninstall Dnsmasq + SNI Proxy"
    echo "  0) Exit"
    echo ""
    read -e -p "Enter number [0-9]: " choice
    case $choice in
        1) fastmode=0; install_all ;;
        2) hello; echo -e "${yellow}Executing uninstall of Dnsmasq and SNI Proxy.${plain}"; confirm; undnsmasq; unsniproxy ;;
        0) exit 0 ;;
        *) echo -e "[Error] Invalid selection."; exit 1 ;;
    esac
}

if [[ $# -eq 1 ]]; then
    key="$1"
    case $key in
        -i|--install) fastmode=0; install_all ;;
        -u|--uninstall) hello; echo -e "${yellow}Executing uninstall of Dnsmasq and SNI Proxy.${plain}"; confirm; undnsmasq; unsniproxy ;;
    esac
else
    menu
fi
