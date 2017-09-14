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

DPDK_DIR=/dpdk

if (( ${PKT_SIZE} == 64 )); then
        RANGE="64 Bytes"
elif (( ${PKT_SIZE} > 64 )) && (( ${PKT_SIZE} <= 127 )); then
        RANGE="65-127"
elif (( ${PKT_SIZE} > 127 )) && (( ${PKT_SIZE} <= 225 )); then
        RANGE="128-255"
elif (( ${PKT_SIZE} >  255)) && (( ${PKT_SIZE} <= 511 )); then
        RANGE="256-511"
elif (( ${PKT_SIZE} > 511 )) && (( ${PKT_SIZE} <= 1023 )); then
        RANGE="512-1023"
elif (( ${PKT_SIZE} > 1023 )) && (( ${PKT_SIZE} <= 1518 )); then
        RANGE="1024-1518"
fi

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
set result {}
set timeout 15
spawn ./app/app/x86_64-native-linuxapp-gcc/pktgen -c 0x07 -n 4 -b $blacklist -- -P -m "1.0,2.1" -f /home/ubuntu/pktgen_latency.lua
expect "Pktgen"
sleep 1
send "on\n"
expect "Pktgen"
send "page latency\n"
expect "Pktgen"
send "start 0\n"
expect "Pktgen"
sleep 20
send "stop 0\n"
expect "Pktgen"
send "page main\n"
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
    dhclient ens4 &> /dev/null
    dhclient ens5 &> /dev/null
}

run_pktgen()
{
    blacklist=$(lspci |grep Eth |awk '{print $1}'|head -1)
    cd /pktgen-dpdk
    touch /home/ubuntu/result.log
    result_log="/home/ubuntu/result.log"
    sudo expect /home/ubuntu/pktgen.exp $blacklist > $result_log 2>&1
    #sudo expect /home/ubuntu/pktgen.exp $blacklist 2>&1 | tee $result_log
}

output_json()
{
    sent=0
    result_pps=0

    sent=$(cat ~/result.log -vT | grep "Tx Pkts" | tail -1 | awk '{match($0,/\[18;20H +[0-9]+/)} {print substr($0,RSTART,RLENGTH)}' | awk '{if ($2 != 0) print $2}')
    received=$(cat ~/result.log -vT | grep "$RANGE" | tail -1 | awk '{match($0,/\[17;40H +[0-9]+/)} {print substr($0,RSTART,RLENGTH)}' | awk '{if ($2 != 0) print $2}')
    result_pps=$(( received / 20 ))
    packets_lost=$(( sent - received ))
    #latency=$(cat ~/result.log -vT | grep "Latency" | tail -1 | awk '{match($0,/\[8;40H +[0-9]+/)} {print substr($0,RSTART,RLENGTH)}' | awk '{if ($2 != 0) print $2}')
    
    #echo '{ "frame_size"':${PKT_SIZE} ,   '"packets_sent"':${sent} , '"packets_received"':${received} , '"packets_per_second"':${result_pps} , '"latency"':${latency}   '}'
    echo '{ "frame_size"':${PKT_SIZE} ,   '"packets_sent"':${sent} , '"packets_received"':${received} , '"packets_per_second"':${result_pps} , '"packets_lost"':${packets_lost} '}'
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
    output_json
    free_interfaces
}

main

