# CPU Core Stability Prober

Diagnose and manage CPU degradation on Intel Raptor Lake (13th/14th gen) systems where high-boost cores silently corrupt computation at stock frequencies.

## The problem

Stock tools like `stress` or `stress-ng` don't verify results — they throw away output, so a failing core that returns wrong answers instead of crashing reports nothing. This probe **verifies every run** by importing a known-good Python/setuptools path and checking exit code 0. A corrupted core will SIGSEGV/SIGABRT instead of succeeding.

## What is in this directory

| File | Purpose |
|------|---------|
| `check-cpu-cores.sh` | Full per-core stability test with frequency control (cap/restore/show status) |
| `probe-cpus.py` | Python alternative: live progress bars, ASCII failure chart |
| `cpu-freq-cap.sh` | Boot-time cap script (called by systemd unit) |

## Quick start

**Test every online CPU at current frequency:**
```bash
./check-cpu-cores.sh
```

**Just the two 6.0 GHz cores that tend to fail first:**
```bash
./check-cpu-cores.sh -c "8/9/10/11"
```

**More confidence per core:**
```bash
./check-cpu-cores.sh -n 40 -c "8/9/10/11"
```

Each line of output shows: **cpu | physical-core # | runs | failures | rate | result (OK or FAIL)**. The test runs serially so each core can boost to its maximum clock — parallel testing would lower package turbo and hide the fault.

## Frequency control

Every CPU has a file `/sys/devices/system/cpu/cpuN/cpufreq/scaling_max_freq` that sets per-core ceiling. Values are in kHz: `4500000 = 4.5 GHz`, `6000000 = 6.0 GHz`.

**Read current limits:**
```bash
./check-cpu-cores.sh status
./check-cpu-cores.sh status '8/9/10/11'           # just those cores
```

Output shows max, current running clock, and min for each logical CPU. If `max GHz < cpuinfo_max_freq`, the cap is active (`[C]` marker).

**Change frequency caps (requires sudo once):**
```bash
sudo ./check-cpu-cores.sh cap 4800000 '8/9/10/11'    # set to 4.8 GHz
sudo ./check-cpu-cores.sh restore                     # back to stock for all online CPUs
```

Manual alternative (sysfs directly):
```bash
echo 4500000 | sudo tee /sys/devices/system/cpu/cpu10/cpufreq/scaling_max_freq
cat /sys/devices/system/cpu/cpu10/cpufreq/scaling_max_freq    # verify it took
```

`no_turbo=1` under `/sys/devices/system/cpu/intel_pstate/` clamps all cores to their base clock instead of per-core fine-control. It is a blunt toggle: `1 = turbo off`, `0 = turbo on`.

## The testing pipeline

To find the exact frequency threshold where a core stops failing, lower the cap step-by-step and retest at each level. A complete sweep might look like this:

| Step | Action | What to expect if degraded |
|------|--------|-----|
| 1 | `sudo ... restore` | Caps gone, cores back to stock 6.0 GHz |
| 2 | `./check-cpu-cores.sh -c "8/10" -n 30` | Failures appear on the bad cores |
| 3 | `sudo ... cap 5000000 '8/9/10/11'` | Cores 8–11 limited to 5.0 GHz |
| 4 | `./check-cpu-cores.sh -c "8/10" -n 20` | If still failing: lower more |
| 5 | `sudo ... cap 4700000 '8/9/10/11'` | Try again; keep stepping down until clean |

When failures drop to zero at a given cap, that is your safe operating frequency. Go back one notch higher to confirm it starts failing again — reversibility proves causality.

## Making caps persistent (survive reboot)

Frequency limits are **volatile** — they reset on every power-cycle or cold boot. To keep them after shutdown you need systemd:

```ini
# /etc/systemd/system/cpu-freq-cap.service
[Unit]
Description=Cap max frequency on degraded cores at 4.5 GHz
After=multi-user.target power-profiles-daemon.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/cpu-freq-cap.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
```

The script `/usr/local/bin/cpu-freq-cap.sh` writes `4500000` into each CPU's `scaling_max_freq`. Activate with:
```bash
sudo systemctl daemon-reload
sudo systemctl enable --now cpu-freq-cap.service
```

Remove when ready to test without caps (e.g. during a diagnostic session):
```bash
sudo systemctl disable --now cpu-freq-cap.service
```

## Why `stress` says nothing is wrong

The classic `stress` binary has **no result verification** — it computes `sqrt()` in a tight loop and throws away the output. A degraded core that returns subtly wrong floating-point results will not crash, so the report reads "all good" even though arithmetic was silently corrupted. The same applies when running all 32 cores at once: package power limits drop boost frequency from per-core 6.0 GHz down to ~5.4 GHz, which may mask the defect.

A self-checking test like this one catches the fault reliably because the probe is lightweight (a single import + config call) and verified — if the core corrupts execution in that path it gets `SIGSEGV`.

## Exit codes

| Code | Meaning |
|------|---------|
| 0 | All tested CPUs clean across all runs |
| 1 | At least one core failed (hardware evidence) |
| 2 | Usage/setup error (missing taskset, python unavailable, bad CPU #) |
