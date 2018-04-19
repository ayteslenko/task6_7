#!/bin/bash
dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

source "$dir/vm1.config"
modprobe 8021q
#Down

ifdown $INTERNAL_IF
ifdown $EXTERNAL_IF

#Configure VLAN and Internal interface

echo "
# Available interfaces
source /etc/network/interfaces.d/*
# Loopback
auto lo
iface lo inet loopback
# Internal. Host-only
auto $INTERNAL_IF
iface $INTERNAL_IF inet static
	address $(echo $INT_IP | cut -d / -f 1)
	netmask $(echo $INT_IP | cut -d / -f 2)
# VLAN
auto $INTERNAL_IF.$VLAN
iface $INTERNAL_IF.$VLAN inet static
	address $(echo $VLAN_IP | cut -d / -f 1)
	netmask $(echo $VLAN_IP | cut -d / -f 2)
	vlan-raw-device $INTERNAL_IF" >/etc/network/interfaces

#Checking DHCP or static and configure External

if [ "$EXT_IP" == DHCP ]
then
	echo "
# External
auto $EXTERNAL_IF
iface $EXTERNAL_IF inet dhcp" >>/etc/network/interfaces
else
	echo "
# External 
auto $EXTERNAL_IF
iface $EXTERNAL_IF inet static
	address $(echo $EXT_IP | cut -d / -f 1)
	netmask $(echo $EXT_IP | cut -d / -f 2)
	gateway $EXT_GW
	dns-nameserver 8.8.8.8" >>/etc/network/interfaces
fi

#Up

ifup $INTERNAL_IF
ifup $INTERNAL_IF.$VLAN
ifup $EXTERNAL_IF
IP=`ifconfig $EXTERNAL_IF | grep "inet addr:" | cut -d: -f2 | awk '{print $1}'`

#Iptables for access to internet from VM2

sed -i 's/#net.ipv4.ip_forward=1/net.ipv4.ip_forward=1/' /etc/sysctl.conf
sysctl --system
iptables -t nat -A POSTROUTING -o $EXTERNAL_IF -j MASQUERADE

#Creating root cert

openssl genrsa -out /etc/ssl/private/root-ca.key 2048
openssl req -x509 -new\
	-key /etc/ssl/private/root-ca.key\
	-days 365\
	-out /etc/ssl/certs/root-ca.crt\
	-subj '/C=UA/ST=Kharkiv/L=Kharkiv/O=NURE/OU=Mirantis/CN=rootCA'

#Creating web cert signing request and sign

openssl genrsa -out /etc/ssl/private/web.key 2048
openssl req -new\
	-key /etc/ssl/private/web.key\
	-nodes\
	-out /etc/ssl/certs/web.csr\
	-subj "/C=UA/ST=Kharkiv/L=Karkiv/O=NURE/OU=Mirantis/CN=$(hostname -f)"

if [ "$EXT_IP" == DHCP ]
then
	openssl x509 -req -extfile <(printf "subjectAltName=IP:$IP,DNS:$(hostname -f)") -days 365 -in /etc/ssl/certs/web.csr -CA /etc/ssl/certs/root-ca.crt -CAkey /etc/ssl/private/root-ca.key -CAcreateserial -out /etc/ssl/certs/web.crt
else
	openssl x509 -req -extfile <(printf "subjectAltName=IP:$EXT_IP,DNS:$(hostname -f)") -days 365 -in /etc/ssl/certs/web.csr -CA /etc/ssl/certs/root-ca.crt -CAkey /etc/ssl/private/root-ca.key -CAcreateserial -out /etc/ssl/certs/web.crt
fi

#Creating cert chain and moving to certs dir

cat /etc/ssl/certs/web.crt /etc/ssl/certs/root-ca.crt > web-bundle.crt
mv ./web-bundle.crt /etc/ssl/certs
echo "
127.0.0.1 loopback
$IP $(hostname)" > /etc/hosts

#Install nginx and configure virtual hosts

apt-get -y install nginx
rm /etc/nginx/sites-enabled/*
cp /etc/nginx/sites-available/default /etc/nginx/sites-available/$(hostname)
echo "
server {
	listen $IP:$NGINX_PORT ssl;
	server_name $(hostname)
	ssl on;
	ssl_certificate /etc/ssl/certs/web-bundle.crt;
	ssl_certificate_key /etc/ssl/private/web.key;
	location / {
		proxy_pass http://$APACHE_VLAN_IP;
	}
}" > /etc/nginx/sites-available/$(hostname)
ln -s /etc/nginx/sites-available/$(hostname) /etc/nginx/sites-enabled/$(hostname)
service nginx restart