##############################################################################
# Copyright (c) 2016 ZTE corporation and others.
#
# All rights reserved. This program and the accompanying materials
# are made available under the terms of the Apache License, Version 2.0
# which accompanies this distribution, and is available at
# http://www.apache.org/licenses/LICENSE-2.0
##############################################################################
from __future__ import absolute_import
import pkg_resources
import logging
import json
import time

import yardstick.ssh as ssh
from yardstick.benchmark.scenarios import base

LOG = logging.getLogger(__name__)


class PktgenDPDKLatency(base.Scenario):
    """Execute pktgen-dpdk on one vm and execute testpmd on the other vm

  Parameters
    packetsize - packet size in bytes without the CRC
        type:    int
        unit:    bytes
        default: 64
    """
    __scenario_type__ = "PktgenDPDKLatency"

    PKTGEN_DPDK_SCRIPT = 'pktgen_dpdk_latency_benchmark.bash'
    TESTPMD_SCRIPT = 'testpmd_fwd.bash'

    def __init__(self, scenario_cfg, context_cfg):
        self.scenario_cfg = scenario_cfg
        self.context_cfg = context_cfg
        self.setup_done = False

    def setup(self):
        """scenario setup"""
        self.pktgen_dpdk_script = pkg_resources.resource_filename(
            'yardstick.benchmark.scenarios.networking',
            PktgenDPDKLatency.PKTGEN_DPDK_SCRIPT)
        self.testpmd_script = pkg_resources.resource_filename(
            'yardstick.benchmark.scenarios.networking',
            PktgenDPDKLatency.TESTPMD_SCRIPT)
        host = self.context_cfg['host']
        target = self.context_cfg['target']
        LOG.info("user:%s, target:%s", target['user'], target['ip'])
        self.server = ssh.SSH.from_node(target, defaults={"user": "ubuntu"})
        self.server.wait(timeout=600)

        # copy script to host
        self.server._put_file_shell(self.testpmd_script, '~/testpmd_fwd.sh')

        LOG.info("user:%s, host:%s", host['user'], host['ip'])
        self.client = ssh.SSH.from_node(host, defaults={"user": "ubuntu"})
        self.client.wait(timeout=600)

        # copy script to host
        self.client._put_file_shell(
            self.pktgen_dpdk_script, '~/pktgen_dpdk.sh')
        print("test scripts copied")
        time.sleep(10)
        
        
        ############################

        import subprocess
        import os

        print("################# PORT SECURITY ###############")
        d = dict(os.environ)
        d['OS_AUTH_URL'] = "http://192.168.0.2:5000/"
        p = subprocess.Popen('openstack port list', shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=d)
        for line in p.stdout.readlines():
            if "demeter" in line or "poseidon" in line:
                elements = line.split("|")
                port_id = elements[1].strip()
                print("Removing port security from port {}".format(port_id))
                cmd = "neutron port-update " + port_id + " --no-security-groups"
                q = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=d)
                time.sleep(2)
                cmd = "neutron port-update " + port_id + " --port_security_enabled=False"
                q = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=d)
                time.sleep(2)
                print(q.stdout.readlines())
                if q.stderr:
                    print(q.stderr.readlines())
                #~ cmd = "neutron port-show " + port_id + " show" + " | grep port_security_enabled"
                #~ time.sleep(5)
                #~ q = subprocess.Popen(cmd, shell=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=d)
                #~ for line in q.stdout.readlines():
                    #~ print(line)

        print("################ PORT SECURITY OVER ##########")

        #############################

        
        self.setup_done = True
        self.testpmd_args = []
        self.pktgen_args = []

    @staticmethod
    def get_port_mac(sshclient, port):
        cmd = "ifconfig |grep HWaddr |grep %s |awk '{print $5}' " % port
        LOG.debug("Executing command: %s", cmd)
        status, stdout, stderr = sshclient.execute(cmd)

        if status:
            raise RuntimeError(stderr)
        else:
            return stdout.rstrip()

    @staticmethod
    def get_port_ip(sshclient, port):
        cmd = "ifconfig %s |grep 'inet addr' |awk '{print $2}' \
            |cut -d ':' -f2 " % port
        LOG.debug("Executing command: %s", cmd)
        status, stdout, stderr = sshclient.execute(cmd)

        if status:
            raise RuntimeError(stderr)
        else:
            return stdout.rstrip()
            
    
    def run_iteration(self, testpmd_args, pktgen_args, packetsize, rate):
        iteration_result = {}
        print("pktgen args: {}".format(pktgen_args))
        print("testPMD args: {}".format(testpmd_args))

        cmd_pmd = "screen sudo -E bash ~/testpmd_fwd.sh %s %s %s " % \
                    (testpmd_args[0], testpmd_args[1], testpmd_args[2])
        
        print("testpmd command: {}".format(cmd_pmd))
        
        
        cmd_pktgen = "sudo -E bash ~/pktgen_dpdk.sh %s %s %s %s %s %s" % \
            (pktgen_args[0], pktgen_args[1], pktgen_args[2],
             pktgen_args[3], rate, packetsize)
             
        print("pktgen command: {}".format(cmd_pktgen))
        
        time.sleep(5)
        
        LOG.debug("Executing command to start PMD: %s", cmd_pmd)
        self.server.send_command(cmd_pmd)
        #self.server.send_command(cmd)
               
        print("PMD launched")
        time.sleep(5)
        print("Launching PKTGEN")
        
        LOG.debug("Executing command to start PKTGEN: %s", cmd_pktgen)
        status, stdout, stderr = self.client.execute(cmd_pktgen)

        print("PKTGEN STatus : {}".format(status))
        print("PKTGEN STDOUT : {}".format(stdout.strip()))
        print("PKTGEN STDERR : {}".format(stderr))

        if status:
            # error cause in json dict on stdout
            raise RuntimeError(stdout)
        result_output = "{" + stdout.strip().split("{")[1]
        iteration_result.update(json.loads(result_output))
        
        print("Stopping PMD Screen")
        time.sleep(10)

        print("killing pmd")
        cmd_pid="ps -eaf | grep SCREEN | grep -v grep | awk '{print $2}'"
        cmdpid_status, cmdpid_stdout, cmdpid_stderr = self.server.execute(cmd_pid)
        print(cmdpid_stdout.strip())

        if cmdpid_stdout !=  "":
            cmd_kill="screen -S " + cmdpid_stdout.strip() + " -X stuff 'command'$(echo -ne \'\\015\')"
            print("screen stop cmd : {}".format(cmd_kill))
            print("killing screen PID - " + cmdpid_stdout.strip())
            cmdkill_status, cmdkill_stdout, cmdkill_stderr = self.server.execute(cmd_kill)
            time.sleep(2)
            cmdkill_status, cmdkill_stdout, cmdkill_stderr = self.server.execute(cmd_kill)
            
        print("iteration result : {}".format(iteration_result))
        
        packets_per_second = iteration_result["packets_per_second"]
        bits_per_second = packets_per_second * 8 * (packetsize + 20)
        megabits_per_second = packets_per_second * 8 * (packetsize + 20) // 10**6
        iteration_result.update({"megabits_per_second": megabits_per_second})
        print("iteration result : {}".format(iteration_result))
        
        #for a 10Gbps line
        linerate_percentage = ( float(bits_per_second) / 10**10 ) * 100
        linerate_percentage = float("{0:.2f}".format(linerate_percentage))
        iteration_result.update({"linerate_percentage": linerate_percentage})
        print("result : {}".format(iteration_result))
        
        loss_percentage = (iteration_result['packets_lost'] / float(iteration_result['packets_sent'])) * 100
        #take only four decimals, to show packets lost per million
        iteration_result.update({"loss_percentage": float("{0:.4f}".format(loss_percentage))})
        print("result : {}".format(iteration_result))
                
        # wait for finishing test
        time.sleep(1)
        
        cmd_latency = r"""\
cat ~/result.log -vT \
|awk '{match($0,/\[8;40H +[0-9]+/)} \
{print substr($0,RSTART,RLENGTH)}' \
|grep -v ^$ |awk '{if ($2 != 0) print $2}'\
"""
        client_status, client_stdout, client_stderr = self.client.execute(cmd_latency)

        if client_status:
            raise RuntimeError(client_stderr)

        print("client_stdout : {}".format(client_stdout.split('\n')))

        avg_latency = 0
        if client_stdout:
            latency_list = client_stdout.split('\n')[0:-1]
            print("Latency list length : {}".format(len(latency_list)))
            LOG.info("Samples of latency: %s", latency_list)
            latency_sum = 0
            for i in latency_list:
                latency_sum += int(i)
            avg_latency = latency_sum / len(latency_list)

        iteration_result.update({"avg_latency": avg_latency})

        return iteration_result
        

    def binary_search(self, testpmd_args, pktgen_args, packetsize, rate, loss_tolerance):
        min_rate = 0
        max_rate=rate
                
        framesize_result = self.run_iteration(testpmd_args, pktgen_args, packetsize, max_rate)
        
        while max_rate - min_rate > 1:
            iter_rate = (min_rate + max_rate) / 2.0
            if framesize_result['loss_percentage'] > loss_tolerance:
                
                max_rate=(max_rate - min_rate) / 2.0
                framesize_result = self.run_iteration(testpmd_args, pktgen_args, packetsize, iter_rate)
                
            elif framesize_result['loss_percentage'] <= loss_tolerance:
                min_rate=(max_rate - min_rate) / 2.0
                framesize_result = self.run_iteration(testpmd_args, pktgen_args, packetsize, iter_rate)
                
        return framesize_result
        

    def run(self, result):
        """execute the benchmark"""

        if not self.setup_done:
            self.setup()

        if not self.testpmd_args:
            client_src_ip = self.get_port_ip(self.client, 'ens4').strip()
            client_dst_ip = self.get_port_ip(self.client, 'ens5').strip()
            self.testpmd_args = [self.get_port_mac(self.client, 'ens5').strip(),
                                    client_src_ip, client_dst_ip]
                    

        if not self.pktgen_args:
            server_rev_mac = self.get_port_mac(self.server, 'ens4').strip()
            server_send_mac = self.get_port_mac(self.server, 'ens5').strip()
            client_src_ip = self.get_port_ip(self.client, 'ens4').strip()
            client_dst_ip = self.get_port_ip(self.client, 'ens5').strip()

            self.pktgen_args = [client_src_ip, client_dst_ip,
                                server_rev_mac, server_send_mac]

        print("class pktgen args: {}".format(self.pktgen_args))
        print("class testPMD args: {}".format(self.testpmd_args))

        options = self.scenario_cfg['options']
        packetsize = options.get("packetsize", 64)
        rate = options.get("rate", 100)
        loss_tolerance=0.1 #less than one packet in a thousand

        result.update(self.binary_search(self.testpmd_args, self.pktgen_args, packetsize, rate, loss_tolerance))
        print("Frame Size {} result : {}".format(packetsize, result))
        
        avg_latency = result['avg_latency']

        if avg_latency and "sla" in self.scenario_cfg:
            sla_max_latency = int(self.scenario_cfg["sla"]["max_latency"])
            LOG.info("avg_latency : %d ", avg_latency)
            LOG.info("sla_max_latency: %d", sla_max_latency)
            debug_info = "avg_latency %d > sla_max_latency %d" \
                % (avg_latency, sla_max_latency)
            assert avg_latency <= sla_max_latency, debug_info
