# cpu-core-stability-prober

Find the CPU cores that silently corrupt computation. It runs a small,
self-checking Python workload once per iteration, pinned to one logical CPU at
a time, and counts the runs that crash instead of printing `ok`.

## Why `stress` misses the fault

Classic `stress` computes `sqrt()` in a tight loop and throws the result away.
A degraded core that returns wrong answers instead of aborting therefore looks
perfectly healthy. Running every thread at once also triggers package power
limits, dropping per-core boost and hiding marginal silicon.

This prober does the opposite: one verified run per core, serially, so the core
can reach its maximum clock. A core that corrupts execution crashes the
process (SIGSEGV / SIGABRT / general-protection fault) and is counted as a
failure.

## What is in this repo

| File | Purpose |
|------|---------|
| `check-cpu-cores.sh` | Per-core stability test plus frequency control (`cap` / `restore` / `status`) |
| `README.md` | This file |

Frequency caps set here are **volatile** — they reset on reboot. For a cap that
survives boot, see the companion service repo `../cpu-freq-fix`.

## Usage

```bash
# test every online CPU (20 runs per core)
./check-cpu-cores.sh

# more confidence, only the two 6.0 GHz preferred cores (4 threads)
./check-cpu-cores.sh -n 40 -c "8 9 10 11"

# explicit subcommand form (same as default)
./check-cpu-cores.sh test -n 20
```

| Flag | Meaning | Default |
|------|---------|---------|
| `-n INT` | Runs per CPU. Raise it for confidence on a suspected core. | `20` |
| `-c "A B C"` | Test only these logical CPUs (space-separated). | all online |

Each iteration forks a fresh Python process pinned with `taskset -c <cpu>`.
The script prints one row per CPU (core, max GHz, runs, failures, rate, result)
and exits non-zero if any core failed.

## The probe

Every run executes exactly this code:

```python
from setuptools.dist import Distribution
from setuptools._distutils.command.install import install as di
d = Distribution({'name': 'myprobe', 'version': '0.1'})
cmd = di(d); cmd.finalize_options(); print('ok')
```

| Step | What happens |
|------|--------------|
| `Distribution({...})` | Builds a full package-metadata object in memory: resolves install prefixes, library paths, header directories. Allocates many nested dicts and internal C-level path buffers. |
| `di(d)` | Constructs the `install` command bound to that distribution. |
| `cmd.finalize_options()` | Forces every option to resolve at once inside a deep pointer-chasing refcount loop. This is enough memory churn and pointer indirection to trip marginal silicon that pure-register math never touches. |
| `print('ok')` | Reached only if nothing crashed, so exit code 0 means a clean run. |

A corrupting core dies here with SIGSEGV / GP fault. Pure `sqrt()` loops stay
in vector registers and never exercise this path, which is why `stress` misses
the fault.

## Frequency control

Each logical CPU has `/sys/devices/system/cpu/cpuN/cpufreq/scaling_max_freq`
in kHz. Values: `4500000` = 4.5 GHz, `5500000` = 5.5 GHz, `6000000` = 6.0 GHz.

```bash
# read-only snapshot: max / current / hardware-min clock per CPU
./check-cpu-cores.sh status
./check-cpu-cores.sh status 8 10 11

# set a hard ceiling (needs root)
sudo ./check-cpu-cores.sh cap 4500000 8 9 10 11
sudo ./check-cpu-cores.sh cap 4500000            # every online CPU

# back to the stock hardware maximum (needs root)
sudo ./check-cpu-cores.sh restore 8 9 10 11
sudo ./check-cpu-cores.sh restore                # every online CPU
```

The global turbo switch is `/sys/devices/system/cpu/intel_pstate/no_turbo`
(`1` = lock all cores to base clock, `0` = turbo on). It is blunt: it affects
every core, not just the bad one.

## Finding a safe frequency

Lower the cap in steps and retest until failures disappear.

| Step | Command | What to expect |
|------|---------|----------------|
| 1 | `sudo ./check-cpu-cores.sh restore` | Back to the stock ceiling (6 GHz) |
| 2 | `./check-cpu-cores.sh -n 40 -c "8 9 10 11"` | Failures on the degraded threads |
| 3 | `sudo ./check-cpu-cores.sh cap 5000000 8 9 10 11` then retest | Fewer failures |
| 4 | Keep stepping down (4.8, 4.5 GHz) until a run is clean | Clean = usable workaround |
| 5 | Raise the cap one notch and confirm failures return | Reversibility proves causality |

If a core still fails at the lowest usable frequency, the silicon is degraded
enough to need replacement (RMA).

## Persistent caps

`scaling_max_freq` resets on every cold boot. To re-apply a cap automatically,
install the systemd unit from the companion repo `../cpu-freq-fix`:

```bash
sudo install -m 755 cpu-freq-cap.sh /usr/local/bin/cpu-freq-cap.sh
sudo install -m 644 cpu-freq-cap.service /etc/systemd/system/cpu-freq-cap.service
sudo systemctl daemon-reload
sudo systemctl enable --now cpu-freq-cap.service
```

## Troubleshooting

If **every** core reports 100% failure, the probe itself is not running — that
is a setup problem, not hardware. The script runs the probe once before testing
any core and aborts with the real Python error, and it only counts a run as a
CPU failure when the process dies from a signal (SIGSEGV 139, SIGABRT 134, …).
A normal Python exception is reported separately and exits 2.

Reproduce the error by hand:

```bash
python3 -c 'from setuptools.dist import Distribution; from setuptools._distutils.command.install import install as di; d=Distribution({"name":"x","version":"1"}); c=di(d); c.finalize_options(); print("ok")'
```

| Symptom | Cause | Fix |
|---------|-------|-----|
| `ModuleNotFoundError: No module named 'setuptools'` or `..._distutils` | setuptools missing or incomplete for that Python | `sudo apt install python3-setuptools`, or `python3 -m pip install -U setuptools` |
| `taskset: failed to set pid's affinity: Invalid argument` | CPU is not in the process's allowed set (container, cgroup, VM) | run on the host, or test only allowed CPUs with `-c "0 1 2 3"` |
| `taskset: command not found` | util-linux missing | `sudo apt install util-linux` |
| Wrong interpreter (venv/conda) | `python3` resolves elsewhere | `PYTHON=/usr/bin/python3 ./check-cpu-cores.sh` |
| `_distutils` import error after a setuptools upgrade | setuptools configured to use the stdlib distutils | `SETUPTOOLS_USE_DISTUTILS=local ./check-cpu-cores.sh` |

## Exit codes

| Code | Meaning |
|------|---------|
| `0` | Every tested CPU was clean across all runs |
| `1` | At least one core failed (hardware evidence) |
| `2` | Usage or setup error (missing `taskset`, no `python3`, bad CPU number, import failure, write failure) |
