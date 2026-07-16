#!/bin/bash

# WireGuard VPN client installer (PBX / IAX2 split-tunnel peers)
# Companion to wireguard-install.sh

RED='\033[0;31m'
ORANGE='\033[0;33m'
GREEN='\033[0;32m'
NC='\033[0m'

WG_DEFAULT_INTERFACE='wg0'
WG_DEFAULT_MTU=1360
WG_MTU_OVERHEAD=60

function installPackages() {
	if ! "$@"; then
		echo -e "${RED}Failed to install packages.${NC}"
		echo "Please check your internet connection and package sources."
		exit 1
	fi
}

function isRoot() {
	if [ "${EUID}" -ne 0 ]; then
		echo "You need to run this script as root"
		exit 1
	fi
}

function isAutoInstall() {
	[[ "${AUTO_INSTALL}" == "y" ]]
}

function checkVirt() {
	if command -v virt-what &>/dev/null; then
		VIRT=$(virt-what)
	else
		VIRT=$(systemd-detect-virt 2>/dev/null || true)
	fi
	if [[ ${VIRT} == "openvz" ]]; then
		echo "OpenVZ is not supported"
		exit 1
	fi
	if [[ ${VIRT} == "lxc" ]]; then
		echo "LXC is not supported (yet)."
		echo "WireGuard can technically run in an LXC container,"
		echo "but the kernel module has to be installed on the host,"
		echo "the container has to be run with some specific parameters"
		echo "and only the tools need to be installed in the container."
		exit 1
	fi
}

function checkOS() {
	source /etc/os-release
	OS="${ID}"
	if [[ ${OS} == "debian" || ${OS} == "raspbian" ]]; then
		if [[ ${VERSION_ID} -lt 10 ]]; then
			echo "Your version of Debian (${VERSION_ID}) is not supported. Please use Debian 10 Buster or later"
			exit 1
		fi
		OS=debian
	elif [[ ${OS} == "ubuntu" ]]; then
		RELEASE_YEAR=$(echo "${VERSION_ID}" | cut -d'.' -f1)
		if [[ ${RELEASE_YEAR} -lt 18 ]]; then
			echo "Your version of Ubuntu (${VERSION_ID}) is not supported. Please use Ubuntu 18.04 or later"
			exit 1
		fi
	elif [[ ${OS} == "fedora" ]]; then
		if [[ ${VERSION_ID} -lt 32 ]]; then
			echo "Your version of Fedora (${VERSION_ID}) is not supported. Please use Fedora 32 or later"
			exit 1
		fi
	elif [[ ${OS} == 'centos' ]] || [[ ${OS} == 'almalinux' ]] || [[ ${OS} == 'rocky' ]]; then
		if [[ ${VERSION_ID} == 7* ]]; then
			OS=centos7
		fi
	elif [[ -e /etc/oracle-release ]]; then
		source /etc/oracle-release
		OS=oracle
	elif [[ -e /etc/arch-release ]]; then
		OS=arch
	elif [[ -e /etc/alpine-release ]]; then
		OS=alpine
	else
		echo "Looks like you aren't running this installer on a supported Linux system"
		echo "Supported: Debian, Ubuntu, Fedora, CentOS 7+, Rocky, AlmaLinux, Oracle, Arch, Alpine"
		exit 1
	fi
}

function detectDefaultNic() {
	ip -4 route ls | grep default | awk '/dev/ {for (i=1; i<=NF; i++) if ($i == "dev") print $(i+1)}' | head -1
}

function detectWireGuardMtu() {
	local nic="${1:-$(detectDefaultNic)}"
	local iface_mtu

	if [[ -n "${nic}" ]] && iface_mtu=$(ip link show dev "${nic}" 2>/dev/null | awk '/mtu/ {print $5; exit}'); then
		if [[ "${iface_mtu}" =~ ^[0-9]+$ ]]; then
			WG_MTU=$((iface_mtu - WG_MTU_OVERHEAD))
		fi
	fi

	if [[ -z "${WG_MTU}" ]] || [[ ! "${WG_MTU}" =~ ^[0-9]+$ ]] || [[ ${WG_MTU} -lt 576 ]]; then
		WG_MTU=${WG_DEFAULT_MTU}
	fi
}

function prepareIptablesFirewall() {
	if command -v firewall-cmd &>/dev/null && systemctl is-active --quiet firewalld 2>/dev/null; then
		echo -e "${ORANGE}Stopping firewalld — client uses iptables-compatible routing only.${NC}"
		systemctl stop firewalld
		systemctl disable firewalld
	fi
}

function wireguardModuleInstalled() {
	find "/lib/modules/$(uname -r)" -name 'wireguard.ko*' 2>/dev/null | grep -q .
}

function installCentOS7WireGuardFromSource() {
	local kver build_dir

	kver="$(uname -r)"
	build_dir="/usr/local/src/wireguard-build"

	echo -e "${GREEN}Building WireGuard from source for kernel ${kver}...${NC}"

	installPackages yum install -y gcc make git iptables
	yum install -y libmnl-devel 2>/dev/null || yum install -y libmnl libmnl-devel 2>/dev/null || true

	if ! yum install -y "kernel-devel-${kver}"; then
		echo -e "${RED}kernel-devel-${kver} is required to compile WireGuard.${NC}"
		echo "Install matching kernel headers, then re-run this installer:"
		echo "  yum install -y kernel-devel-${kver}"
		echo "If unavailable:"
		echo "  yum update -y kernel"
		echo "  reboot"
		return 1
	fi

	mkdir -p "${build_dir}"
	cd "${build_dir}" || return 1

	if [[ ! -d wireguard-linux-compat/.git ]]; then
		rm -rf wireguard-linux-compat
		installPackages git clone --depth 1 https://git.zx2c4.com/wireguard-linux-compat "${build_dir}/wireguard-linux-compat"
	fi

	echo -e "${GREEN}Compiling wireguard-linux-compat kernel module...${NC}"
	make -C wireguard-linux-compat/src clean >/dev/null 2>&1 || true
	if ! make -C wireguard-linux-compat/src; then
		echo -e "${RED}Failed to build wireguard-linux-compat kernel module.${NC}"
		return 1
	fi
	if ! make -C wireguard-linux-compat/src install; then
		echo -e "${RED}Failed to install wireguard-linux-compat kernel module.${NC}"
		return 1
	fi

	if [[ ! -d wireguard-tools/.git ]]; then
		rm -rf wireguard-tools
		installPackages git clone --depth 1 https://git.zx2c4.com/wireguard-tools "${build_dir}/wireguard-tools"
	fi

	echo -e "${GREEN}Compiling wireguard-tools userspace...${NC}"
	make -C wireguard-tools/src clean >/dev/null 2>&1 || true
	if ! make -C wireguard-tools/src; then
		echo -e "${RED}Failed to build wireguard-tools.${NC}"
		return 1
	fi
	if ! make -C wireguard-tools/src install; then
		echo -e "${RED}Failed to install wireguard-tools.${NC}"
		return 1
	fi

	depmod -a
	echo -e "${GREEN}WireGuard built and installed from source.${NC}"
}

function loadWireGuardModule() {
	if lsmod | grep -q '^wireguard'; then
		return 0
	fi

	if [[ ${OS} == 'centos7' ]] && ! wireguardModuleInstalled; then
		installCentOS7WireGuardFromSource || return 1
	fi

	depmod -a 2>/dev/null || true

	if modprobe wireguard 2>/dev/null; then
		echo -e "${GREEN}Loaded wireguard kernel module.${NC}"
		return 0
	fi

	return 1
}

function hostSupportsIpv6() {
	[[ $(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null) != "1" ]] && ip -6 addr show scope global 2>/dev/null | grep -q 'inet6'
}

function adaptConfigForHost() {
	local config_file=$1

	if ! hostSupportsIpv6 && grep -E 'Address = .*,|:.*:' "${config_file}" >/dev/null; then
		echo -e "${ORANGE}IPv6 is unavailable on this host — using IPv4-only client config.${NC}"
		sed -i -E 's/^Address = ([0-9.]+)\/[0-9]+,.*/Address = \1\/32/' "${config_file}"
	fi

	if grep -q '^DNS' "${config_file}" && ! command -v resolvconf &>/dev/null; then
		echo -e "${ORANGE}resolvconf not found — removing DNS from config (not required for PBX split tunnel).${NC}"
		sed -i '/^DNS/d' "${config_file}"
	fi
}

function validateConfigSyntax() {
	if ! wg-quick strip "${WG_INTERFACE}" >/dev/null 2>&1; then
		echo -e "${RED}WireGuard config syntax check failed for /etc/wireguard/${WG_INTERFACE}.conf${NC}"
		echo -e "${ORANGE}Config contents:${NC}"
		sed 's/PrivateKey = .*/PrivateKey = <hidden>/; s/PresharedKey = .*/PresharedKey = <hidden>/' "/etc/wireguard/${WG_INTERFACE}.conf"
		exit 1
	fi
}

function installWireGuardPackages() {
	echo -e "${GREEN}Installing WireGuard packages for ${OS}...${NC}"

	if [[ ${OS} == 'ubuntu' ]] || [[ ${OS} == 'debian' && ${VERSION_ID} -gt 10 ]]; then
		apt-get update
		installPackages apt-get install -y wireguard iptables
	elif [[ ${OS} == 'debian' ]]; then
		if ! grep -rqs "^deb .* buster-backports" /etc/apt/; then
			echo "deb http://deb.debian.org/debian buster-backports main" >/etc/apt/sources.list.d/backports.list
			apt-get update
		fi
		apt-get update
		installPackages apt-get install -y iptables
		installPackages apt-get install -y -t buster-backports wireguard
	elif [[ ${OS} == 'fedora' ]]; then
		if [[ ${VERSION_ID} -lt 32 ]]; then
			installPackages dnf install -y dnf-plugins-core
			dnf copr enable -y jdoss/wireguard
			installPackages dnf install -y wireguard-dkms
		fi
		installPackages dnf install -y wireguard-tools iptables
	elif [[ ${OS} == 'centos7' ]]; then
		installCentOS7WireGuardFromSource
		if ! loadWireGuardModule; then
			echo -e "${RED}WireGuard kernel module could not be loaded for $(uname -r).${NC}"
			exit 1
		fi
	elif [[ ${OS} == 'centos' ]] || [[ ${OS} == 'almalinux' ]] || [[ ${OS} == 'rocky' ]]; then
		if [[ ${VERSION_ID} == 8* ]]; then
			installPackages yum install -y epel-release elrepo-release
			installPackages yum install -y kmod-wireguard
		else
			installPackages yum install -y epel-release || true
		fi
		installPackages yum install -y wireguard-tools iptables
	elif [[ ${OS} == 'oracle' ]]; then
		if [[ ${VERSION_ID} == 8* ]] || [[ ${VERSION_ID} == 7* ]]; then
			installPackages yum install -y oraclelinux-developer-release-el8 || installPackages yum install -y epel-release elrepo-release
			installPackages yum install -y kmod-wireguard || true
		fi
		installPackages yum install -y wireguard-tools iptables || installPackages dnf install -y wireguard-tools iptables
	elif [[ ${OS} == 'arch' ]]; then
		installPackages pacman -S --needed --noconfirm wireguard-tools iptables
	elif [[ ${OS} == 'alpine' ]]; then
		apk update
		installPackages apk add wireguard-tools iptables
	fi

	if ! command -v wg &>/dev/null; then
		echo -e "${RED}WireGuard installation failed. The 'wg' command was not found.${NC}"
		exit 1
	fi

	echo -e "${GREEN}WireGuard tools version: $(wg --version 2>/dev/null || wg -v)${NC}"
}

function validateClientConfig() {
	local config_file=$1

	if [[ ! -f "${config_file}" ]]; then
		echo -e "${RED}Client config not found: ${config_file}${NC}"
		exit 1
	fi

	if ! grep -q '^\[Interface\]' "${config_file}" || ! grep -q '^\[Peer\]' "${config_file}"; then
		echo -e "${RED}Invalid WireGuard config: ${config_file} must contain [Interface] and [Peer] sections.${NC}"
		exit 1
	fi
}

function ensureClientMtu() {
	local config_file=$1

	if grep -q '^MTU' "${config_file}"; then
		return
	fi

	if [[ -z "${WG_MTU}" ]]; then
		detectWireGuardMtu
	fi

	sed -i "/^\[Interface\]/a MTU = ${WG_MTU}" "${config_file}"
}

function ensurePersistentKeepalive() {
	local config_file=$1
	local keepalive="${WG_PERSISTENT_KEEPALIVE:-25}"

	if grep -q '^PersistentKeepalive' "${config_file}"; then
		return
	fi

	sed -i "/^\[Peer\]/a PersistentKeepalive = ${keepalive}" "${config_file}"
}

function resolveClientConfig() {
	local temp_config

	if isAutoInstall; then
		WG_INTERFACE="${WG_INTERFACE:-${WG_DEFAULT_INTERFACE}}"

		if [[ -n "${WG_CONF_URL}" ]]; then
			temp_config="$(mktemp)"
			if ! curl -fsSL "${WG_CONF_URL}" -o "${temp_config}"; then
				echo -e "${RED}Failed to download client config from WG_CONF_URL.${NC}"
				exit 1
			fi
			CLIENT_CONFIG="${temp_config}"
		elif [[ -n "${WG_CONF_FILE}" ]]; then
			CLIENT_CONFIG="${WG_CONF_FILE}"
		else
			echo -e "${RED}AUTO_INSTALL requires WG_CONF_FILE or WG_CONF_URL.${NC}"
			exit 1
		fi

		validateClientConfig "${CLIENT_CONFIG}"
		return
	fi

	echo ""
	echo "WireGuard client configuration"
	echo ""
	echo "Provide the .conf file generated by the WireGuard server installer"
	echo "(for example: /root/wg0-client-pbx_peer_1.conf)."
	echo ""

	until [[ -f "${CLIENT_CONFIG}" ]]; do
		read -rp "Path to client config file: " -e -i "${WG_CONF_FILE:-}" CLIENT_CONFIG
		if [[ ! -f "${CLIENT_CONFIG}" ]]; then
			echo -e "${ORANGE}File not found. Please enter a valid path.${NC}"
		fi
	done

	until [[ ${WG_INTERFACE} =~ ^[a-zA-Z0-9_]+$ && ${#WG_INTERFACE} -lt 16 ]]; do
		read -rp "WireGuard interface name: " -e -i "${WG_DEFAULT_INTERFACE}" WG_INTERFACE
	done

	validateClientConfig "${CLIENT_CONFIG}"
}

function deployClientConfig() {
	mkdir -p /etc/wireguard
	chmod 700 /etc/wireguard

	cp "${CLIENT_CONFIG}" "/etc/wireguard/${WG_INTERFACE}.conf"
	chmod 600 "/etc/wireguard/${WG_INTERFACE}.conf"

	ensureClientMtu "/etc/wireguard/${WG_INTERFACE}.conf"
	ensurePersistentKeepalive "/etc/wireguard/${WG_INTERFACE}.conf"
	adaptConfigForHost "/etc/wireguard/${WG_INTERFACE}.conf"
	validateConfigSyntax

	echo -e "${GREEN}Client config installed: /etc/wireguard/${WG_INTERFACE}.conf${NC}"
}

function showStartFailureDiagnostics() {
	echo ""
	echo -e "${RED}WireGuard failed to start. Diagnostics:${NC}"
	echo ""

	if ! loadWireGuardModule; then
		echo -e "${ORANGE}Kernel module 'wireguard' is not loaded.${NC}"
		echo "  Running kernel: $(uname -r)"
		if ! wireguardModuleInstalled; then
			echo -e "${RED}  No wireguard.ko found for this kernel under /lib/modules/$(uname -r)/${NC}"
		fi
		if [[ ${OS} == 'centos7' ]]; then
			echo "  Source build requires: yum install -y kernel-devel-$(uname -r) gcc make git"
			echo "  Re-run this installer to compile wireguard-linux-compat + wireguard-tools"
			echo "  If kernel-devel is missing: yum update -y kernel && reboot"
		else
			echo "  Try: modprobe wireguard"
		fi
		echo ""
	fi

	if [[ ${OS} != 'alpine' ]]; then
		journalctl -u "wg-quick@${WG_INTERFACE}" -n 30 --no-pager 2>/dev/null || true
		echo ""
	fi

	echo -e "${ORANGE}Manual start output:${NC}"
	wg-quick down "${WG_INTERFACE}" 2>/dev/null || true
	wg-quick up "${WG_INTERFACE}" 2>&1 || true
	echo ""
}

function startWireGuardClient() {
	if ! loadWireGuardModule; then
		echo -e "${RED}Cannot load wireguard kernel module before starting the interface.${NC}"
		showStartFailureDiagnostics
		return 1
	fi

	if [[ ${OS} == 'alpine' ]]; then
		ln -sf /etc/init.d/wg-quick "/etc/init.d/wg-quick.${WG_INTERFACE}" 2>/dev/null || true
		rc-update add "wg-quick.${WG_INTERFACE}" 2>/dev/null || true
		if ! rc-service "wg-quick.${WG_INTERFACE}" start; then
			showStartFailureDiagnostics
			return 1
		fi
	else
		systemctl enable "wg-quick@${WG_INTERFACE}"
		if ! systemctl start "wg-quick@${WG_INTERFACE}"; then
			showStartFailureDiagnostics
			return 1
		fi
	fi

	return 0
}

function checkWireGuardRunning() {
	if [[ ${OS} == 'alpine' ]]; then
		rc-service --quiet "wg-quick.${WG_INTERFACE}" status
	else
		systemctl is-active --quiet "wg-quick@${WG_INTERFACE}"
	fi
}

function showServiceCommands() {
	echo ""
	echo -e "${GREEN}WireGuard client service commands:${NC}"
	echo ""

	if [[ ${OS} == 'alpine' ]]; then
		echo "  rc-service wg-quick.${WG_INTERFACE} start"
		echo "  rc-service wg-quick.${WG_INTERFACE} stop"
		echo "  rc-service wg-quick.${WG_INTERFACE} restart"
		echo "  rc-service wg-quick.${WG_INTERFACE} status"
		echo "  rc-update add wg-quick.${WG_INTERFACE}"
	else
		echo "  systemctl start wg-quick@${WG_INTERFACE}"
		echo "  systemctl enable wg-quick@${WG_INTERFACE}"
		echo "  systemctl restart wg-quick@${WG_INTERFACE}"
		echo "  systemctl status wg-quick@${WG_INTERFACE}"
	fi

	echo ""
	echo -e "${GREEN}Diagnostics:${NC}"
	echo "  wg show ${WG_INTERFACE}"
	echo "  ip route | grep ${WG_INTERFACE}"
	echo ""
}

function initialCheck() {
	isRoot
	checkOS
	checkVirt
}

function main() {
	initialCheck

	echo "WireGuard VPN client installer"
	echo "For PBX / IAX2 split-tunnel peers (10.8.0.0/24)"
	echo ""

	WG_INTERFACE="${WG_INTERFACE:-${WG_DEFAULT_INTERFACE}}"
	resolveClientConfig
	prepareIptablesFirewall
	installWireGuardPackages
	deployClientConfig
	START_RESULT=0
	startWireGuardClient || START_RESULT=1

	if [[ ${START_RESULT} -eq 0 ]] && checkWireGuardRunning; then
		echo -e "\n${GREEN}WireGuard client is running on ${WG_INTERFACE}.${NC}"
		wg show "${WG_INTERFACE}" 2>/dev/null || true
	else
		echo -e "\n${RED}WARNING: WireGuard client does not appear to be running.${NC}"
		if [[ ${START_RESULT} -eq 0 ]]; then
			showStartFailureDiagnostics
		fi
	fi

	showServiceCommands
}

main
