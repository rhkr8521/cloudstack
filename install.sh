#!/bin/bash
set -euo pipefail  # 안전한 실행 설정
trap 'echo "An error occurred. Exiting..."; exit 1;' ERR

if [ "$EUID" -ne 0 ]; then
  echo "
  ############################################################################# 
  ##         This script must be run as root or with sudo command            ##   
  ##  before running the script switch to root user using <su> or <sudo su>  ##
  #############################################################################
  "
  sleep 15
  exit 1
fi

# Ubuntu 버전 확인
UBUNTU_VERSION=$(lsb_release -rs)
if [[ ! "$UBUNTU_VERSION" =~ ^(20\.|22\.) ]]; then
  echo "
  ############################################################################# 
  ##         This script requires Ubuntu version 22.04 or 20.xx             ##   
  #############################################################################
  "
  sleep 15
  exit 1
fi

# 초기 정보 출력
echo -e "
 ██████╗ ███████╗██╗    ██╗ █████╗ ███╗   ██╗███████╗   ███╗   ██╗███████╗██╗  ██╗██████╗  █████╗ 
 ██╔══██╗██╔════╝██║    ██║██╔══██╗████╗  ██║██╔════╝   ████╗  ██║██╔════╝██║  ██║██╔══██╗██╔══██╗ 
 ██║  ██║█████╗  ██║ █╗ ██║███████║██╔██╗ ██║███████╗   ██╔██╗ ██║█████╗  ███████║██████╔╝███████║ 
 ██║  ██║██╔══╝  ██║███╗██║██╔══██║██║╚██╗██║╚════██║   ██║╚██╗██║██╔══╝  ██╔══██║██╔══██╗██╔══██║
 ██████╔╝███████╗╚███╔███╔╝██║  ██║██║ ╚████║███████║   ██║ ╚████║███████╗██║  ██║██║  ██║██║  ██║ 
 ╚═════╝ ╚══════╝ ╚══╝╚══╝ ╚═╝  ╚═╝╚═╝  ╚═══╝╚══════╝   ╚═╝  ╚═══╝╚══════╝╚═╝  ╚═╝╚═╝  ╚═╝╚═╝  ╚═╝  
"
echo -e "
###################################################################################
####           This script is written by Dewans Nehra.                        ####
####           You can contact me at https://dewansnehra.xyz                  ####
####           This script is written for Ubuntu 22.04                        ####
####           This script will install Cloudstack 4.18                       ####
###################################################################################
"

echo "Updating system packages..."
apt update && apt upgrade -y

# 네트워크 정보 설정
GATEWAY=$(ip route | awk '/default/ {print $3}')
IP=$(hostname -I | awk '{print $1}')
ADAPTER=$(ip -o -4 addr show | awk '{print $2}' | grep -Ev '^(lo|vir|wl)')

HOSTS_CONTENT="127.0.0.1\tlocalhost\n$IP\tdevil.dewansnehra.xyz\tdevil"
if ! grep -Fxq "$HOSTS_CONTENT" /etc/hosts; then
  echo -e "$HOSTS_CONTENT" | tee -a /etc/hosts
fi

# 브리지 설정
echo "Installing bridge-utils and configuring bridge..."
apt install -y bridge-utils
if brctl show | grep -q 'br0'; then
  echo "Bridge 'br0' already exists."
else
  brctl addbr br0
  echo "Bridge 'br0' created."
fi

if ! brctl show br0 | grep -q "$ADAPTER"; then
  brctl addif br0 $ADAPTER
  echo "Interface $ADAPTER added to br0."
else
  echo "Interface $ADAPTER is already part of br0."
fi

# Netplan 설정
NETPLAN_FILE="/etc/netplan/99-cloudstack.yaml"
NETPLAN_CONTENT="network:
  version: 2
  renderer: networkd
  ethernets:
    $ADAPTER:
      dhcp4: true
  bridges:
    br0:
      interfaces: [$ADAPTER]
      dhcp4: no
      addresses: [$IP/24]
      gateway4: $GATEWAY
      nameservers:
        addresses: [8.8.8.8, 8.8.4.4]"

echo "$NETPLAN_CONTENT" | tee $NETPLAN_FILE
netplan apply || {
  echo "Netplan configuration failed. Restoring original interface settings..."
  ip link set br0 down
  brctl delbr br0
  ip link set $ADAPTER up
  echo "Original network interface restored."
}

hostnamectl set-hostname devil.dewansnehra.xyz

# CloudStack 설치
echo "Installing CloudStack dependencies..."
apt-get install -y openntpd openssh-server sudo vim htop tar intel-microcode mysql-server

# CloudStack 저장소 추가
echo "Configuring CloudStack repository..."
if [[ "$UBUNTU_VERSION" == "20."* ]]; then
  echo deb [arch=amd64] http://download.cloudstack.org/ubuntu focal 4.18 > /etc/apt/sources.list.d/cloudstack.list
elif [[ "$UBUNTU_VERSION" == "22."* ]]; then
  echo deb [arch=amd64] http://download.cloudstack.org/ubuntu jammy 4.18 > /etc/apt/sources.list.d/cloudstack.list
fi

wget -qO - http://download.cloudstack.org/release.asc | gpg --dearmor -o /usr/share/keyrings/cloudstack-archive-keyring.gpg
apt update && apt install -y cloudstack-management cloudstack-usage

# MySQL 설정
echo "Configuring MySQL for CloudStack..."
cat <<EOF | tee -a /etc/mysql/mysql.conf.d/mysqld.cnf
[mysqld]
server_id=1
sql-mode="STRICT_TRANS_TABLES,NO_ENGINE_SUBSTITUTION,ERROR_FOR_DIVISION_BY_ZERO,NO_ZERO_DATE,NO_ZERO_IN_DATE,NO_ENGINE_SUBSTITUTION"
innodb_rollback_on_timeout=1
innodb_lock_wait_timeout=600
max_connections=1000
log-bin=mysql-bin
binlog-format='ROW'
EOF

systemctl restart mysql

mysql -u root -e "
ALTER USER 'root'@'localhost' IDENTIFIED WITH mysql_native_password BY 'dewansnehra';
FLUSH PRIVILEGES;
"

cloudstack-setup-databases root:dewansnehra@localhost --deploy-as=root:dewansnehra
cloudstack-setup-management

# NFS 구성
echo "Setting up NFS..."
apt install -y nfs-kernel-server
mkdir -p /export/{primary,secondary}
echo "/export *(rw,async,no_root_squash,no_subtree_check)" | tee -a /etc/exports
exportfs -r
systemctl restart nfs-server

# 완료 메시지
echo "
###################################################################################
####           Installation done. You can go to http://localhost:8080          ####
####           Username : admin                                                ####
####           Password : password                                             ####
###################################################################################
"
