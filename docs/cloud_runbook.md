# Cloud runbook — exact command sequence (P3→P4), all from the terminal

One linear script from an empty instance to an ILA capture. No GUI anywhere.
Target: **AWS F2 (VU47P)** (AWS migrated from F1). ⚠️ platform/AMI/AGFI names change —
check `platforminfo -l`, awsdocs-fpga-f2 and aws-fpga (branch f2).

## 0. Instance + environment (build instance from the FPGA Developer AMI, Vitis 2025.2)
On this AMI Vivado/Vitis/v++ are **already on PATH** (`/opt/Xilinx/2025.2/…`, settings64.sh is
sourced by the profile) — nothing needs to be sourced for SYNTHESIS (P3).
XRT and aws-fpga are **not** preinstalled — they are only needed for P4 (packaging/host/hardware):
```bash
# --- this is enough for P3 (synth): ---
git clone https://github.com/AlexOnTheStorm/systolic-gemm-kernelgen.git
cd systolic-gemm-kernelgen
which vivado    # sanity: /opt/Xilinx/2025.2/Vivado/bin/vivado

# --- EXTRA, only once you reach P4 (xo/v++/host): ---
git clone https://github.com/aws/aws-fpga.git ~/aws-fpga
source ~/aws-fpga/vitis_setup.sh    # installs/picks up XRT + F2 platforms + env
# (if settings64 is not in the profile: source /opt/Xilinx/2025.2/Vitis/settings64.sh)
```

## 1. P3 — synthesis estimate (f_max, resources) — any region
```bash
vivado -mode batch -source flow/synth.tcl -tclargs xcvu47p-fsvh2892-3-e 3.0 8 8
# stdout prints WNS and f_max right away. Details:
grep -A4 "Design Timing Summary" results/synth/timing_summary.rpt
grep -E "CLB LUTs|CLB Registers|DSPs|Block RAM Tile" results/synth/utilization.rpt
```
Goal: **WNS ≥ 0** and **DSP ≈ ARRAY_M·ARRAY_N** (validates the P2 model). The VU47P has 9024
DSPs, so 8×8=64 is a drop in the ocean; 64×64 can be synthesized too.

## 2. P4 — build the kernel and the xclbin
```bash
vivado -mode batch -source flow/package_kernel.tcl          # → results/xo/gemm_kernel.xo
export PLATFORM=xilinx_aws-vu47p-f2_202420_2                # F2 platform (verify: platforminfo -l)

./flow/build_hw.sh sw_emu    # (seconds) host↔kernel logic check
./flow/build_hw.sh hw_emu    # (minutes) RTL-accurate emulation — catches most bugs before the bitstream
./flow/build_hw.sh hw        # (hours)   real bitstream with ILA → results/hw/*.xclbin
```
Emulation (`sw_emu`/`hw_emu`) does NOT need an f2 — run it on the cheap build instance.
Run `hw` only once emulation is clean (the kernel logic is already sim-checked by `make kernel`).

## 3. From .xclbin to an AWS image (.awsxclbin/AFI). Vitis/XRT flow, in an F2 region!
F2 does not load a raw `.xclbin` but an `.awsxclbin` (an AWS wrapper with the AFI). AFI creation
is asynchronous on the AWS side (~30–60 min). ⚠️ The bucket and `create-fpga-image` must be in an
**F2 region** (Frankfurt=eu-central-1 or London=eu-west-2), NOT eu-north-1. The build box can be
anywhere — it only uploads to S3 and calls the API.

Needed: AWS CLI with credentials (IAM permissions `ec2:CreateFpgaImage`,
`ec2:DescribeFpgaImages`, S3 access) and an S3 bucket in an F2 region.
```bash
source ~/aws-fpga/vitis_setup.sh              # provides create_vitis_afi.sh
aws configure set region eu-central-1         # Frankfurt (F2)
aws s3 mb s3://<bucket-afi> --region eu-central-1   # once

# locate the script (the path depends on the aws-fpga version):
AFISH=$(find ~/aws-fpga -name create_vitis_afi.sh | head -1); echo $AFISH

# generate the AFI + .awsxclbin from hw.xclbin:
$AFISH -xclbin=results/hw/gemm_kernel.hw.xclbin \
       -o=results/hw/gemm_kernel \
       -s3_bucket=<bucket-afi> -s3_dcp_key=dcp -s3_logs_key=logs
# → results/hw/gemm_kernel.awsxclbin  +  *_afi_id.txt (afi-.../agfi-...)

# wait until the AFI becomes 'available':
afi=$(grep -o 'afi-[0-9a-f]*' *_afi_id.txt | head -1)
aws ec2 describe-fpga-images --fpga-image-ids $afi \
    --query 'FpgaImages[0].State.Code' --region eu-central-1   # wait for "available"
```

## 4. Run + golden check (on f2.6xlarge, Frankfurt)
XRT programs the FPGA itself on `load_xclbin(.awsxclbin)` — a separate `fpga-load-local-image`
is NOT needed in the Vitis flow. XRT/pyxrt come preinstalled on f2.
```bash
# copy to the f2: .awsxclbin + host/ + ref/ (easiest is to clone the repo again)
python3 host/run_hw.py results/hw/gemm_kernel.awsxclbin --M 8 --N 8 --K 8
# PASS — hardware GEMM 8x8x8 matches golden   ← ON-SILICON MEASUREMENT
```

## 5. ILA debug on F2 — headless (see flow/ila_debug.tcl)
The bitstream is built with a System ILA (`--debug.chipscope`, `hw` only). On F2 the ILA is reached
through the XRT debug bridge (XVC). ⚠️ The exact XVC/port mechanics on F2 depend on the
XRT/awsdocs-fpga version — check the current AWS docs before running.
```bash
# t.1 (f2): open the XVC bridge to the programmed FPGA (XRT/AWS utility)
#   on F2 the XRT debug bridge does this; port/command — see awsdocs-fpga (F2 debug).
# t.2: arm the ILA and capture the waveform to a file (headless batch Tcl):
XVC_URL=localhost:10201 vivado -mode batch -source flow/ila_debug.tcl
# t.3: kick the kernel → trigger on ap_start:
python3 host/run_hw.py results/hw/gemm_kernel.awsxclbin --M 8 --N 8 --K 8
```
Waveform → `results/ila/capture.vcd`. To view:
```bash
surfer results/ila/capture.vcd        # headless viewer; or scp to a laptop
grep -c "" results/ila/capture.csv    # quick sanity check of the sample count
```

## Which instance for which step
| Step | Instance | Region | Cost |
|---|---|---|---|
| 0–2 (synth, xo, emulation, `hw` bitstream) | m7a.2xlarge (no FPGA) | any | cheap |
| 3–5 (load, run, ILA) | f2.6xlarge (1×VU47P) | F2 region (EU: Frankfurt/London) | start / run / **terminate** |

Rule: everything that can run on the build instance and in emulation does; f2 is for the final step only.
