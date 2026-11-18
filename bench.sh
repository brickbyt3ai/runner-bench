#!/usr/bin/env bash
# Runner benchmark steps: sysinfo, cpu, disk, gen, verify. Each writes JSON into results/.
set -euo pipefail
OUT="${RESULTS_DIR:-$PWD/results}"
mkdir -p "$OUT"
TAG="${BENCH_TAG:?BENCH_TAG unset}"

sysinfo() {
  python3 - "$OUT/sysinfo-$TAG.json" <<'PY'
import json, os, re, subprocess, sys
def sh(c):
    p = subprocess.run(c, shell=True, capture_output=True, text=True)
    return p.stdout.strip()
cpu = open("/proc/cpuinfo").read()
mhz = [float(x) for x in re.findall(r"cpu MHz\s*:\s*([\d.]+)", cpu)]
flags = (re.search(r"flags\s*:\s*(.*)", cpu) or [None, ""])[1].split()
def rd(p):
    try:
        return open(p).read().strip()
    except OSError:
        return None
mem = int(re.search(r"MemTotal:\s*(\d+)", open("/proc/meminfo").read()).group(1))
ws = os.environ.get("GITHUB_WORKSPACE", os.getcwd())
out = {
    "tag": os.environ["BENCH_TAG"], "runner_name": os.environ.get("RUNNER_NAME"),
    "image": [os.environ.get("ImageOS"), os.environ.get("ImageVersion")],
    "blacksmith_env_names": sorted(k for k in os.environ if k.startswith("BLACKSMITH")),
    "model": (re.search(r"model name\s*:\s*(.*)", cpu) or [None, None])[1],
    "nproc": os.cpu_count(), "mem_gib": round(mem / 2**20, 1),
    "cpu_mhz_reported": sorted(set(mhz)),
    "avx512f": "avx512f" in flags, "avx2": "avx2" in flags, "vaes": "vaes" in flags,
    "lscpu": sh("lscpu"), "virt": sh("systemd-detect-virt || true"),
    "dmi": {k: rd("/sys/class/dmi/id/" + k) for k in ("sys_vendor", "product_name", "board_vendor", "bios_vendor")},
    "kernel": sh("uname -r"),
    "cpufreq_max_khz": rd("/sys/devices/system/cpu/cpu0/cpufreq/cpuinfo_max_freq"),
    "df_workspace": sh("df -hT " + ws + " | tail -1"), "df_mnt": sh("df -hT /mnt 2>/dev/null | tail -1"),
    "lsblk": sh("lsblk -o NAME,SIZE,TYPE,ROTA,MODEL,MOUNTPOINT"),
}
json.dump(out, open(sys.argv[1], "w"), indent=1)
print(out["model"], out["nproc"], out["mem_gib"], out["df_workspace"])
PY
}

cpu() {
  local n; n=$(nproc)
  local st mt
  st=$(sysbench cpu --cpu-max-prime=20000 --threads=1 --time=15 run | awk '/events per second/ {print $4}')
  ( sleep 7; grep "cpu MHz" /proc/cpuinfo | awk '{print $4}' | sort -n | tr '\n' ' ' > "$OUT/mhz-under-load-$TAG.txt" ) &
  mt=$(sysbench cpu --cpu-max-prime=20000 --threads="$n" --time=15 run | awk '/events per second/ {print $4}')
  wait
  rm -rf /tmp/zstd-src
  git clone -q --depth 1 --branch v1.5.7 https://github.com/facebook/zstd /tmp/zstd-src
  local t0 t1
  t0=$(date +%s.%N); make -s -C /tmp/zstd-src -j"$n" zstd > /dev/null 2>&1; t1=$(date +%s.%N)
  python3 - "$OUT/cpu-$TAG.json" "$st" "$mt" "$n" "$t0" "$t1" "$OUT/mhz-under-load-$TAG.txt" <<'PY'
import json, sys
o, st, mt, n, t0, t1, mhzf = sys.argv[1:8]
r = {"sysbench_1t_events_s": float(st), "sysbench_nt_events_s": float(mt), "threads": int(n),
     "zstd_build_s": round(float(t1) - float(t0), 2), "mhz_under_load": [float(x) for x in open(mhzf).read().split()]}
json.dump(r, open(o, "w"), indent=1)
print(r)
PY
}

disk() {
  local dir="${GITHUB_WORKSPACE:-$PWD}/fio-test"
  mkdir -p "$dir"
  local common="--directory=$dir --ioengine=libaio --direct=1 --time_based --runtime=20 --group_reporting --output-format=json"
  fio $common --name=randread4k --rw=randread --bs=4k --iodepth=64 --numjobs=4 --size=1G > "$OUT/fio-randread4k-$TAG.json"
  fio $common --name=randwrite4k --rw=randwrite --bs=4k --iodepth=64 --numjobs=4 --size=1G > "$OUT/fio-randwrite4k-$TAG.json"
  fio $common --name=randread4k-qd1 --rw=randread --bs=4k --iodepth=1 --numjobs=1 --size=1G > "$OUT/fio-randread4k-qd1-$TAG.json"
  fio $common --name=seqread1m --rw=read --bs=1M --iodepth=16 --numjobs=1 --size=4G > "$OUT/fio-seqread1m-$TAG.json"
  fio $common --name=seqwrite1m --rw=write --bs=1M --iodepth=16 --numjobs=1 --size=4G > "$OUT/fio-seqwrite1m-$TAG.json"
  fio --directory="$dir" --name=fsync4k --rw=write --bs=4k --size=64M --fsync=1 --ioengine=sync --runtime=20 --group_reporting --output-format=json > "$OUT/fio-fsync4k-$TAG.json"
  rm -rf "$dir"
  python3 - "$OUT" "$TAG" <<'PY'
import glob, json, sys
for f in sorted(glob.glob(sys.argv[1] + "/fio-*-" + sys.argv[2] + ".json")):
    j = json.load(open(f))["jobs"][0]
    for d in ("read", "write"):
        if j[d]["io_bytes"]:
            print(j["jobname"], d, "iops", round(j[d]["iops"]), "MB/s", round(j[d]["bw_bytes"] / 1e6, 1),
                  "p99 us", round(j[d]["clat_ns"]["percentile"].get("99.000000", 0) / 1000, 1))
PY
}

gen() {
  rm -rf data && mkdir -p data/small
  local t0 t1
  t0=$(date +%s.%N)
  head -c $((1024 * 1024 * 1024)) /dev/urandom > data/big.bin
  python3 -c "
import os
for i in range(20000):
    d = 'data/small/d%03d' % (i // 200)
    os.makedirs(d, exist_ok=True)
    open('%s/f%05d.bin' % (d, i), 'wb').write(os.urandom(16384))
"
  t1=$(date +%s.%N)
  sha256sum data/big.bin > data/big.sha256
  (cd data && find small -type f -print0 | sort -z | xargs -0 sha256sum) > data/small.sha256
  echo "gen_s=$(python3 -c "print(round($t1-$t0,2))")"
}

verify() {
  sha256sum -c --quiet data/big.sha256
  (cd data && sha256sum -c --quiet small.sha256)
  echo "verified big.bin and $(wc -l < data/small.sha256) small files"
}

"$@"
