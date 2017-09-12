#!/bin/bash
##############################################################################
# Copyright (c) 2017 ZTE corporation and others.
#
# All rights reserved. This program and the accompanying materials
# are made available under the terms of the Apache License, Version 2.0
# which accompanies this distribution, and is available at
# http://www.apache.org/licenses/LICENSE-2.0
##############################################################################
#!/bin/sh

set -e

# Commandline arguments
DST_MAC=$1         # MAC address of the peer port
PING_DST1=$2      # first destinatin for ping, from PMD VM to PKTGEN VM
PING_DST2=$3      # second destinatin for ping, from PMD VM to PKTGEN VM

DPDK_DIR=/dpdk

ping_vm()
{
    ping -c 2 ${PING_DST1}
    ping -c 2 ${PING_DST2}
}

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

run_testpmd()
{
    blacklist=$(lspci |grep Eth |awk '{print $1}'|head -1)
    cd ${DPDK_DIR}
    sudo ./destdir/bin/testpmd -c 0x07 -n 4 -b $blacklist -- --auto-start --eth-peer=1,$DST_MAC --forward-mode=mac
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

main()
{
    free_interfaces
    load_modules
    change_permissions
    ping_vm
    add_interface_to_dpdk
    run_testpmd
    free_interfaces
}

main
