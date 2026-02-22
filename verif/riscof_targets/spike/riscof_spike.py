import os
import re
import shutil
import subprocess
import shlex
import logging
import random
import string
from string import Template
import sys

import riscof.utils as utils
import riscof.constants as constants
from riscof.pluginTemplate import pluginTemplate

logger = logging.getLogger()

class spike(pluginTemplate):
    __model__ = "spike"
    __version__ = "1.0.0"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        config = kwargs.get('config')

        if config is None:
            logger.error("Config file is missing for spike")
            raise SystemExit(1)

        # Get the directory where config.ini is located (riscof_targets directory)
        # RISCOF runs from this directory, so relative paths are resolved from here
        config_dir = os.getcwd()

        # Resolve pluginpath - if relative, make it relative to config directory
        pluginpath_raw = config['pluginpath']
        if not os.path.isabs(pluginpath_raw):
            self.pluginpath = os.path.abspath(os.path.join(config_dir, pluginpath_raw))
        else:
            self.pluginpath = os.path.abspath(pluginpath_raw)

        # Get paths from project root
        self.project_root = os.path.abspath(os.path.join(self.pluginpath, '../../../'))

        # Load environment configuration
        env_config_path = os.path.join(self.project_root, 'env.config')
        self.riscv_prefix = None
        self.spike_exe = 'spike'

        if os.path.exists(env_config_path):
            with open(env_config_path, 'r') as f:
                for line in f:
                    line = line.strip()
                    if line.startswith('RISCV_PREFIX='):
                        self.riscv_prefix = line.split('=', 1)[1]
                    elif line.startswith('SPIKE='):
                        self.spike_exe = line.split('=', 1)[1]

        if not self.riscv_prefix:
            self.riscv_prefix = 'riscv32-unknown-elf-'

        self.objdump_exe = self.riscv_prefix + 'objdump'
        self.dut_exe = self.spike_exe
        self.num_jobs = str(config['jobs'] if 'jobs' in config else 1)
        logger.debug("SPIKE plugin initialized")

    def initialise(self, suite, work_dir, archtest_env):
        self.suite = suite
        self.work_dir = work_dir
        self.archtest_env = archtest_env
        self.objdump = self.objdump_exe + ' -D'

    def build(self, isa_yaml, platform_yaml):
        ispec = utils.load_yaml(isa_yaml)['hart0']
        self.xlen = ('64' if 64 in ispec['supported_xlen'] else '32')
        self.isa = 'rv' + self.xlen
        if "I" in ispec["ISA"]:
            self.isa += 'i'
        if "M" in ispec["ISA"]:
            self.isa += 'm'
        if "A" in ispec["ISA"]:
            self.isa += 'a'
        if "F" in ispec["ISA"]:
            self.isa += 'f'
        if "D" in ispec["ISA"]:
            self.isa += 'd'
        if "C" in ispec["ISA"]:
            self.isa += 'c'
        if "Zicsr" in ispec["ISA"]:
            self.isa += '_zicsr'
        if "Zifencei" in ispec["ISA"]:
            self.isa += '_zifencei'

        # Spike ISA string (same as compile ISA)
        self.isa_spike = self.isa

        # Set ABI based on xlen and build compile_cmd
        # Format will be used later: {0}=test_path, {1}=elf_path, {2}=compile_macros
        abi = 'lp64' if "64" in self.xlen else 'ilp32'
        self.compile_cmd = self.riscv_prefix+'gcc -march='+self.isa.lower()+' -mabi='+abi+' \
         -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles -g\
         -T '+self.pluginpath+'/env/link.ld \
         -I '+self.pluginpath+'/env/\
         -I '+self.archtest_env+' {0} -o {1} {2}'

    def runTests(self, testList):
        make = utils.makeUtil(makefilePath=os.path.join(self.work_dir, "Makefile." + self.name[:-1]))
        make.makeCommand = 'make -j' + self.num_jobs

        # Trace comparison support: enabled via ARCH_TEST_TRACE=1 env var
        arch_test_trace  = os.environ.get('ARCH_TEST_TRACE', '0') == '1'
        trace_compare_py = os.path.join(self.project_root, 'scripts', 'trace_compare.py')

        for testname in testList:
            testentry = testList[testname]
            test = testentry['test_path']
            test_dir = testentry['work_dir']
            elf = os.path.join(test_dir, os.path.basename(test) + '.elf')
            sig_file = os.path.join(test_dir, self.name[:-1] + ".signature")

            # Compile macros
            compile_macros = ' -D' + " -D".join(testentry['macros'])

            # Compile command - using the base compile_cmd with proper formatting
            cmd = self.compile_cmd.format(test, elf, compile_macros)

            if arch_test_trace:
                # REF role with TRACE=1: generate spike trace in ref/, compare vs ../dut/DUT-rv32.trace
                spike_trace_file = os.path.join(test_dir, 'REF-spike.trace')
                rtl_trace_file   = os.path.join(test_dir, '..', 'dut', 'DUT-rv32.trace')
                trace_cmp_log    = os.path.join(test_dir, '..', 'dut', 'trace_compare.log')

                # spike --log-commits writes trace to stderr; redirect to trace file
                spike_trace_cmd = (
                    "bash -c 'timeout 10 {spike} --pc=0x80000000 --log-commits --isa={isa}"
                    " +signature={sig} +signature-granularity=4 {elf}"
                    " > {sig}.log 2>{trace};"
                    " RC=$$?; if [ $$RC -eq 124 ] || [ $$RC -eq 0 ]; then exit 0; else exit $$RC; fi'"
                ).format(
                    spike=self.spike_exe, isa=self.isa_spike,
                    sig=sig_file, elf=elf, trace=spike_trace_file)

                cmp_cmd = (
                    '(python3 {py} {trace} {rtl} >> {log}'
                    ' && echo TRACE_MATCH >> {log})'
                    ' || echo TRACE_DIFFER >> {log}'
                ).format(
                    py=trace_compare_py, trace=spike_trace_file,
                    rtl=rtl_trace_file, log=trace_cmp_log)

                execute = '@cd {dir}; {compile}; {spike}; {cmp}'.format(
                    dir=test_dir, compile=cmd, spike=spike_trace_cmd, cmp=cmp_cmd)
            else:
                # Normal run: signature only
                # Note: spike doesn't exit after RVMODEL_HALT, so we use timeout
                spike_cmd = 'timeout 10 ' + self.spike_exe + ' --pc=0x80000000 --isa={0} +signature={1} +signature-granularity=4 {2}'.format(
                    self.isa_spike, sig_file, elf)

                # Wrap spike command to treat timeout exit code 124 as success (exit 0)
                spike_cmd_wrapped = "bash -c '{0}; RC=$$?; if [ $$RC -eq 124 ] || [ $$RC -eq 0 ]; then exit 0; else exit $$RC; fi'".format(spike_cmd)

                execute = '@cd {0}; {1}; {2} &> {3}.log'.format(test_dir, cmd, spike_cmd_wrapped, sig_file)

            make.add_target(execute)

        exec_timeout = 900 if arch_test_trace else 300
        make.execute_all(self.work_dir, timeout=exec_timeout)

