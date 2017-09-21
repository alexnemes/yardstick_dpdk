#!/bin/bash
##############################################################################
# Copyright (c) 2017 ZTE corporation and others.
#
# All rights reserved. This program and the accompanying materials
# are made available under the terms of the Apache License, Version 2.0
# which accompanies this distribution, and is available at
# http://www.apache.org/licenses/LICENSE-2.0
##############################################################################

set -e

# Commandline arguments
SRC_IP=$1         # source IP address of sender in VM A
DST_IP=$2         # destination IP address of receiver in VM A
FWD_REV_MAC=$3    # MAC address of forwarding receiver in VM B
FWD_SEND_MAC=$4   # MAC address of forwarding sender in VM B
RATE=$5           # packet rate in percentage
PKT_SIZE=$6       # packet size
ENS4_IP=$7        # IP address to be statically configured after unbind
ENS5_IP=$8        # IP address to be statically configured after unbind
DURATION=$9

DPDK_DIR=/dpdk

load_modules()
{
    if lsmod | grep "uio" &> /dev/null ; then
    echo "uio module is loaded"
    else
    modprobe uio
    fi

    if lsmod | grep "igb_uio" &> /dev/null ; then
    echo "igb_uio module is loaded"
    else
    insmod ${DPDK_DIR}/x86_64-native-linuxapp-gcc/kmod/igb_uio.ko
    fi

    if lsmod | grep "rte_kni" &> /dev/null ; then
    echo "rte_kni module is loaded"
    else
    insmod ${DPDK_DIR}/x86_64-native-linuxapp-gcc/kmod/rte_kni.ko
    fi
}

change_permissions()
{
    chmod 777 /sys/bus/pci/drivers/virtio-pci/*
    chmod 777 /sys/bus/pci/drivers/igb_uio/*
}

add_interface_to_dpdk(){
    # putting the last 2 interfaces down
    enslist=`ifconfig | grep ens | tail -n +2 | awk '{print $1}'`
    ensarr=(`echo ${enslist}`);
    for i in {0..1}; do ifconfig ${ensarr[$i]} down; done
    # adding them to dpdk driver by pci address
    interfaces=$(lspci |grep Eth |tail -n +2 |awk '{print $1}')
    ${DPDK_DIR}/tools/dpdk-devbind.py --bind=igb_uio $interfaces
}

create_pktgen_config_lua()
{
    touch /home/ubuntu/pktgen_latency.lua &> /dev/null
    lua_file="/home/ubuntu/pktgen_latency.lua"
    chmod 777 $lua_file
    #echo $lua_file

    cat << EOF > "/home/ubuntu/pktgen_latency.lua"
package.path = package.path ..";?.lua;test/?.lua;app/?.lua;"

 -- require "Pktgen";
function pktgen_config()

  pktgen.screen("off");

  pktgen.set_ipaddr("0", "dst", "$DST_IP");
  pktgen.set_ipaddr("0", "src", "$SRC_IP/24");
  pktgen.set_mac("0", "$FWD_REV_MAC");
  pktgen.set_ipaddr("1", "dst", "$SRC_IP");
  pktgen.set_ipaddr("1", "src", "$DST_IP/24");
  pktgen.set_mac("1", "$FWD_SEND_MAC");
  pktgen.set(0, "rate", $RATE);
  pktgen.set(0, "size", $PKT_SIZE);
  pktgen.set_proto("all", "udp");
  pktgen.latency("all","enable");
  pktgen.latency("all","on");

  pktgen.start("0");
  end

pktgen_config()
EOF
}


create_expect_file()
{
    touch /home/ubuntu/pktgen.exp &> /dev/null
    expect_file="/home/ubuntu/pktgen.exp"
    chmod 777 $expect_file
    #echo $expect_file

    cat << 'EOF' > "/home/ubuntu/pktgen.exp"
#!/usr/bin/expect

set blacklist  [lindex $argv 0]
spawn ./app/app/x86_64-native-linuxapp-gcc/pktgen -c 0x07 -n 4 -b $blacklist -- -P -m "1.0,2.1" -f /home/ubuntu/pktgen_latency.lua
expect "Pktgen"
send "on\n"
expect "Pktgen"
send "page latency\n"
expect "Pktgen"
send "page latency\n"
expect "Pktgen"
send "page latency\n"
expect "Pktgen"
send "page latency\n"
expect "Pktgen"
send "page latency\n"
expect "Pktgen"
send "page latency\n"
expect "Pktgen"
send "page latency\n"
expect "Pktgen"
send "page latency\n"
expect "Pktgen"
send "page latency\n"
expect "Pktgen"
send "page latency\n"
expect "Pktgen"
sleep 1
send "quit\n"
expect "#"


EOF

}

free_interfaces()
{

    interfaces=$(lspci |grep Eth |tail -n +2 |awk '{print $1}')
    ${DPDK_DIR}/tools/dpdk-devbind.py -u ${interfaces} &> /dev/null
    ${DPDK_DIR}/tools/dpdk-devbind.py -b virtio-pci ${interfaces} &> /dev/null
    sleep 3
    ifconfig ens4 up
    ifconfig ens5 up
    #dhclient ens4 &> /dev/null
    ifconfig ens4 $ENS4_IP netmask 255.255.255.0
    #dhclient ens5 &> /dev/null
    ifconfig ens5 $ENS5_IP netmask 255.255.255.0
}

run_pktgen()
{
    blacklist=$(lspci |grep Eth |awk '{print $1}'|head -1)
    cd /pktgen-dpdk
    touch /home/ubuntu/result_latency.log
    result_log="/home/ubuntu/result_latency.log"
    sudo expect /home/ubuntu/pktgen.exp $blacklist > $result_log 2>&1
    #sudo expect /home/ubuntu/pktgen.exp $blacklist 2>&1 | tee $result_log
}

main()
{
    free_interfaces
    load_modules
    change_permissions
    create_pktgen_config_lua
    create_expect_file
    add_interface_to_dpdk
    run_pktgen
    free_interfaces
}

main

