import os
import glob
import logging

import riscof.utils as utils
import riscof.constants as constants
from riscof.pluginTemplate import pluginTemplate

logger = logging.getLogger()

class kv32(pluginTemplate):
    __model__   = "kv32"
    __version__ = "1.0.0"

    # -- Initialisation -------------------------------------------------------

    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        config     = kwargs.get('config')
        config_dir = os.getcwd()

        if config is None:
            logger.error("Config file is missing for kv32")
            raise SystemExit(1)

        def _abspath(raw):
            return os.path.abspath(raw if os.path.isabs(raw)
                                   else os.path.join(config_dir, raw))

        self.pluginpath    = _abspath(config['pluginpath'])
        self.isa_spec      = _abspath(config['ispec'])
        self.platform_spec = _abspath(config['pspec'])
        self.num_jobs      = str(config.get('jobs', 1))
        self.target_run    = config.get('target_run', '1') != '0'
        self.project_root  = os.path.abspath(
            os.path.join(self.pluginpath, '../../../'))

        # Defaults - overridden by env.config when present
        self.riscv_prefix  = 'riscv32-unknown-elf-'
        self.spike_exe     = 'spike'
        self.verilator_bin = 'verilator'
        env_config = os.path.join(self.project_root, 'env.config')
        if os.path.exists(env_config):
            with open(env_config) as f:
                for line in f:
                    k, _, v = line.strip().partition('=')
                    if   k == 'RISCV_PREFIX': self.riscv_prefix  = v
                    elif k == 'SPIKE':        self.spike_exe     = v
                    elif k == 'VERILATOR':    self.verilator_bin = v

        self.objdump_exe = self.riscv_prefix + 'objdump'

        # -- plugin-specific --------------------------------------------------
        self.dut_exe = os.path.join(self.project_root, 'build', 'kv32soc')
        # ---------------------------------------------------------------------

        logger.debug("kv32 plugin initialized")

    # -- RISCOF protocol ------------------------------------------------------

    def initialise(self, suite, work_dir, archtest_env):
        self.suite        = suite
        self.work_dir     = work_dir
        self.archtest_env = archtest_env
        self.objdump      = self.objdump_exe + ' -D'

    def build(self, isa_yaml, platform_yaml):
        ispec     = utils.load_yaml(isa_yaml)['hart0']
        self.xlen = '64' if 64 in ispec['supported_xlen'] else '32'
        self.isa  = 'rv' + self.xlen
        for s, k in [('i','I'),('m','M'),('a','A'),('f','F'),('d','D'),('c','C')]:
            if k in ispec['ISA']: self.isa += s
        if 'Zicsr'    in ispec['ISA']: self.isa += '_zicsr'
        if 'Zifencei' in ispec['ISA']: self.isa += '_zifencei'

        # ISA string passed to the simulator (plugins may narrow it)
        self.isa_sim = self.isa

        abi = 'lp64' if self.xlen == '64' else 'ilp32'
        self.compile_cmd = (
            self.riscv_prefix + 'gcc'
            ' -march=' + self.isa.lower() + ' -mabi=' + abi +
            ' -static -mcmodel=medany -fvisibility=hidden -nostdlib -nostartfiles -g'
            ' -T ' + self.pluginpath + '/env/link.ld'
            ' -I ' + self.pluginpath + '/env/'
            ' -I ' + self.archtest_env +
            ' {0} -o {1} {2}'
        )

    # -- Simulator commands (plugin-specific) ---------------------------------

    def _make_run_cmd(self, elf, sig_file):
        return (
            '{exe} {elf} --instructions=2000000'
            ' +signature={sig} +signature-granularity=4'
        ).format(exe=self.dut_exe, elf=elf, sig=sig_file)

    def _make_trace_cmd(self, elf, sig_file, trace_file):
        # kv32soc writes trace via --trace --log; stdout+stderr to log
        return (
            '{exe} {elf} --instructions=2000000'
            ' +signature={sig} +signature-granularity=4'
            ' --trace --log={trace}'
            ' > {log} 2>&1'
        ).format(exe=self.dut_exe, elf=elf,
                 sig=sig_file, trace=trace_file,
                 log=sig_file + '.log')

    # -- Helpers (identical in all plugins) -----------------------------------

    def _trace_file(self, test_dir, is_ref_role):
        prefix = 'REF' if is_ref_role else 'DUT'
        return os.path.join(test_dir, '{}-{}.trace'.format(prefix, self.__model__))

    def _dut_trace_file(self, test_dir):
        dut_dir = os.path.join(test_dir, '..', 'dut')
        matches = sorted(glob.glob(os.path.join(dut_dir, 'DUT-*.trace')))
        return matches[0] if matches else os.path.join(dut_dir, 'DUT.trace')

    # -- Test runner (identical in all plugins) -------------------------------

    def runTests(self, testList):
        make = utils.makeUtil(makefilePath=os.path.join(
            self.work_dir, 'Makefile.' + self.name[:-1]))
        make.makeCommand = 'make -j' + self.num_jobs

        arch_test_trace  = os.environ.get('ARCH_TEST_TRACE', '0') == '1'
        trace_compare_py = os.path.join(self.project_root, 'scripts', 'trace_compare.py')
        is_ref_role      = 'Reference' in self.name

        for testname in testList:
            testentry = testList[testname]
            test      = testentry['test_path']
            test_dir  = testentry['work_dir']
            elf       = os.path.join(test_dir, os.path.basename(test) + '.elf')
            sig_file  = os.path.join(test_dir, self.name[:-1] + '.signature')
            compile_macros = ' -D' + ' -D'.join(testentry['macros'])

            cmd = self.compile_cmd.format(test, elf, compile_macros)

            if self.target_run:
                if arch_test_trace:
                    trace_file = self._trace_file(test_dir, is_ref_role)
                    sim_cmd    = self._make_trace_cmd(elf, sig_file, trace_file)
                    if is_ref_role:
                        dut_trace = self._dut_trace_file(test_dir)
                        cmp_log   = os.path.join(test_dir, '..', 'dut', 'trace_compare.log')
                        cmp_cmd   = (
                            '(python3 {py} {ref} {dut} >> {log} 2>&1'
                            ' && echo TRACE_MATCH >> {log})'
                            ' || echo TRACE_DIFFER >> {log}'
                        ).format(py=trace_compare_py,
                                 ref=trace_file, dut=dut_trace, log=cmp_log)
                        execute = '@cd {d}; {c}; {s}; {cmp}'.format(
                            d=test_dir, c=cmd, s=sim_cmd, cmp=cmp_cmd)
                    else:
                        execute = '@cd {d}; {c}; {s}'.format(
                            d=test_dir, c=cmd, s=sim_cmd)
                else:
                    sim_cmd = self._make_run_cmd(elf, sig_file)
                    execute = '@cd {d}; {c}; {s} &> {sig}.log'.format(
                        d=test_dir, c=cmd, s=sim_cmd, sig=sig_file)
            else:
                execute = 'echo "NO RUN"'

            make.add_target(execute)

        exec_timeout = 900 if arch_test_trace else 300
        make.execute_all(self.work_dir, timeout=exec_timeout)
