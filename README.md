# runner-bench

Compares GitHub-hosted `ubuntu-24.04` (4 vCPU on public repos) with `blacksmith-4vcpu-ubuntu-2404` on x86: CPU
(model, sysbench, zstd build), disk (fio 4k random IOPS, sequential MB/s, fsync), and actions/cache save and
restore speed (1 GiB random file, 20,000 files of 16 KiB) from a fresh runner. Run with workflow_dispatch.
