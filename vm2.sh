#!/bin/bash
dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

source "$dir/vm2.config"
modprobe 8021q

#Down
ifdown $INTERNAL_IF

#Configure VLAN and Internal interface

echo "
# Interfaces available
source /etc/network/interfaces.d/*
# Loopback
auto lo
iface lo inet loopback
# Internal. Host-only
auto $INTERNAL_IF
iface $INTERNAL_IF inet static
address $(echo $INT_IP | cut -d / -f 1)
netmask $(echo $INT_IP | cut -d / -f 2)
gateway $GW_IP
dns-nameservers 8.8.8.8
# VLAN
auto $INTERNAL_IF.$VLAN
iface $INTERNAL_IF.$VLAN inet static
address $(echo $APACHE_VLAN_IP | cut -d / -f 1)
netmask $(echo $APACHE_VLAN_IP | cut -d / -f 2)
vlan-raw-device $INTERNAL_IF" >/etc/network/interfaces

#Up

ifup $INTERNAL_IF
ifup $INTERNAL_IF.$VLAN
IP=`ifconfig $INTERNAL_IF | grep 'inet addr' | cut -d: -f2 | awk '{print $1}'`
echo "
127.0.0.1 loopback
$IP $(hostname)" > /etc/hosts

#Install and configure Apache2

apt-get -y install apache2
rm /etc/apache2/sites-enabled/*
echo "
<VirtualHost *:80>
    ServerAdmin webmaster@localhost
    ServerName $(hostname)
    DocumentRoot /var/www/html
    ErrorLog ${APACHE_LOG_DIR}/error.log
    CustomLog ${APACHE_LOG_DIR}/access.log combined
</VirtualHost>" > /etc/apache2/sites-available/$(hostname).conf
ln -s /etc/apache2/sites-available/$(hostname).conf /etc/apache2/sites-enabled/$(hostname).conf
sed -i "s/Listen 80/Listen $(echo $APACHE_VLAN_IP | cut -d / -f 1):80/" /etc/apache2/ports.conf
a2ensite $(hostname).conf
service apache2 restart
