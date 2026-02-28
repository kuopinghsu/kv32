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

class kv32sim(pluginTemplate):
    __model__ = "kv32sim"
    __version__ = "1.0.0"

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        config = kwargs.get('config')

        if config is None:
            logger.error("Config file is missing for kv32sim")
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

        self.num_jobs = str(config['jobs'] if 'jobs' in config else 1)

        # Resolve ISA spec path
        ispec_raw = config['ispec']
        if not os.path.isabs(ispec_raw):
            self.isa_spec = os.path.abspath(os.path.join(config_dir, ispec_raw))
        else:
            self.isa_spec = os.path.abspath(ispec_raw)

        # Resolve platform spec path
        pspec_raw = config['pspec']
        if not os.path.isabs(pspec_raw):
            self.platform_spec = os.path.abspath(os.path.join(config_dir, pspec_raw))
        else:
            self.platform_spec = os.path.abspath(pspec_raw)

        # Get paths from project root
        self.project_root = os.path.abspath(os.path.join(self.pluginpath, '../../../'))

        # Load environment configuration
        env_config_path = os.path.join(self.project_root, 'env.config')
        self.riscv_prefix = None
        self.kv32sim_exe = os.path.join(self.project_root, 'build', 'kv32sim')
        self.spike_exe   = 'spike'

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
        self.dut_exe = self.kv32sim_exe
        self.num_jobs = str(config['jobs'] if 'jobs' in config else 1)

        # Check if target should be run
        if 'target_run' in config and config['target_run']=='0':
            self.target_run = False
        else:
            self.target_run = True

        logger.debug("kv32sim plugin initialized")

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

        # kv32sim ISA string - only supports rv32ima or rv32ima_zicsr
        # Remove _zifencei as kv32sim doesn't accept it in --isa parameter
        self.isa_sim = self.isa.replace('_zifencei', '')

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

        # Trace comparison support: enabled via ARCH_TEST_TRACE=1 env var (set by
        # the Makefile when the user passes TRACE=1 on the command line).
        #
        # This plugin may be used in two roles:
        #   DUT role  (arch-test-sim):  self.name contains "DUT-"       → run
        #                               kv32sim and compare its trace against spike.
        #   REF role  (arch-test-rv32i): self.name contains "Reference-" → just
        #                               generate the signature (+ kv32sim trace
        #                               file for debugging).  Do NOT re-run spike
        #                               here; the DUT plugin already does that for
        #                               the RTL-vs-spike comparison, and a second
        #                               spike call would add ~10 s × N tests of
        #                               silent waiting.
        arch_test_trace  = os.environ.get('ARCH_TEST_TRACE', '0') == '1'
        is_ref_role      = 'Reference' in self.name   # True when acting as REF
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

            if arch_test_trace and not is_ref_role:
                # DUT role with TRACE=1: generate kv32sim signature + RTL-format
                # trace, then compare against spike.
                # DUT trace stays in dut/; spike REF trace goes to ref/ to match
                # the standard RISCOF layout (ref/ is the reference model dir).
                ref_dir          = os.path.join(test_dir, '..', 'ref')
                dut_trace_file   = os.path.join(test_dir, 'DUT-kv32sim.trace')
                spike_trace_file = os.path.join(ref_dir, 'REF-spike.trace')
                trace_cmp_log    = os.path.join(test_dir, 'trace_compare.log')

                sim_cmd = ('{0} --isa={1} --rtl-trace --log={2}'
                           ' +signature={3} +signature-granularity=4 {4}').format(
                               self.kv32sim_exe, self.isa_sim,
                               dut_trace_file, sig_file, elf)

                # REF: spike generates instruction trace via --log-commits
                # (spike writes the commit log to stderr; timeout handles programs
                #  that spin until external kill; exit 124 = timeout = OK)
                # Timeout 5 s matches the DUT plugin — the real test completes
                # in <<1 s; extra time is just the tohost polling loop.
                spike_tracecmd = (
                    "bash -c 'timeout 5 {0} --pc=0x80000000 --isa={1} --log-commits"
                    " +signature=/dev/null +signature-granularity=4 {2}"
                    " > /dev/null 2>{3};"
                    " RC=$$?; if [ $$RC -eq 124 ] || [ $$RC -eq 0 ]; then exit 0; else exit $$RC; fi'"
                ).format(self.spike_exe, self.isa, elf, spike_trace_file)

                # Compare: spike trace (REF) vs kv32sim trace (DUT)
                cmp_cmd = (
                    '(python3 {0} {1} {2} > {3} 2>&1'
                    ' && echo TRACE_MATCH >> {3})'
                    ' || echo TRACE_DIFFER >> {3}').format(
                        trace_compare_py, spike_trace_file, dut_trace_file, trace_cmp_log)

                execute = '@cd {0}; mkdir -p {1}; {2}; {3} &> {4}.log; {5}; {6};'.format(
                    test_dir, ref_dir, cmd, sim_cmd, sig_file, spike_tracecmd, cmp_cmd)

            elif arch_test_trace and is_ref_role:
                # REF role with TRACE=1: generate kv32sim RTL-format trace, then
                # compare it against the RTL trace that the DUT plugin already
                # wrote to ../dut/DUT-kv32.trace.
                # Result goes to ../dut/trace_compare.log so TRACE_SUMMARY finds it.
                sim_trace_file = os.path.join(test_dir, 'REF-kv32sim.trace')
                rtl_trace_file = os.path.join(test_dir, '..', 'dut', 'DUT-kv32.trace')
                trace_cmp_log  = os.path.join(test_dir, '..', 'dut', 'trace_compare.log')

                sim_cmd = ('{0} --isa={1} --rtl-trace --log={2}'
                           ' +signature={3} +signature-granularity=4 {4}').format(
                               self.kv32sim_exe, self.isa_sim,
                               sim_trace_file, sig_file, elf)

                # Compare: kv32sim trace (REF) vs RTL trace (DUT)
                cmp_cmd = (
                    '(python3 {0} {1} {2} > {3} 2>&1'
                    ' && echo TRACE_MATCH >> {3})'
                    ' || echo TRACE_DIFFER >> {3}').format(
                        trace_compare_py, sim_trace_file, rtl_trace_file, trace_cmp_log)

                execute = '@cd {0}; {1}; {2} &> {3}.log; {4};'.format(
                    test_dir, cmd, sim_cmd, sig_file, cmp_cmd)

            else:
                # Normal run: signature only
                sim_cmd = '{0} --isa={1} +signature={2} +signature-granularity=4 {3}'.format(
                    self.kv32sim_exe, self.isa_sim, sig_file, elf)
                execute = '@cd {0}; {1}; {2} &> {3}.log'.format(
                    test_dir, cmd, sim_cmd, sig_file)

            make.add_target(execute)

        # When kv32sim is the DUT (arch-test-sim) with TRACE=1, each test
        # runs kv32sim + spike (up to 5 s) + compare.  Pass an extended timeout.
        # In REF role with TRACE=1 there is no spike, so 300 s is sufficient.
        exec_timeout = 900 if (arch_test_trace and not is_ref_role) else 300
        make.execute_all(self.work_dir, timeout=exec_timeout)
