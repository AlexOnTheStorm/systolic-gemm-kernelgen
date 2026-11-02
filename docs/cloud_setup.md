# Cloud environment for Vivado/Vitis + F2 (P3–P4)

macOS cannot run Vivado/Vitis. Everything hardware-related (synthesis, ILA, bitstream, runs) happens
in the cloud. The direct route is the **AWS FPGA Developer AMI** (F2 branch): it ships Vivado/Vitis +
XRT with a license for the F2 device. Current version: Ubuntu, Xilinx **2025.2**, user `ubuntu`,
repo/docs in `/home/ubuntu/src`.

⚠️ AWS migrated from **F1 (VU9P)** to **F2 (VU47P)**. AMI/platform/version names change quickly —
check awsdocs-fpga-f2.readthedocs-hosted.com and `github.com/aws/aws-fpga` (branch f2), plus
`platforminfo -l` on the instance.

## F2 regions (important!)
US East (N. Virginia), US West (Oregon), Canada Central, **eu-central-1 (Frankfurt)**,
**eu-west-2 (London)**, AP Sydney/Tokyo/Seoul. **There is NO F2 in eu-north-1 (Stockholm).**
- Synthesis/emulation (P3, hw_emu) can run in any region.
- A real F2 run + AFI need an F2 region (EU: Frankfurt/London). The AFI is created in the same
  region as the f2 instance.

## Instance roles (synthesis separate from hardware)
| Task | Instance | Why |
|---|---|---|
| P3 synthesis, building `.xo`/`.xclbin`, emulation | **m7a.2xlarge** (no FPGA) | cheap, fast Zen4 for P&R |
| On-silicon run + ILA | **f2.6xlarge** (1×VU47P) | the FPGA itself; F2 region |

The build (hours) runs on a cheap build instance; you switch to f2 only for the run and the ILA.
Bitstream → **AFI** (`aws ec2 create-fpga-image`), then load it on the f2.

## Quick start
```bash
# 1) build instance from the FPGA Developer AMI (Vitis 2025.2 preinstalled). Environment:
source /home/ubuntu/src/aws-fpga/vitis_setup.sh     # XRT + F2 platforms + env
#   (on a fresh AMI aws-fpga is already cloned into ~/src; otherwise git clone -b f2 ...)

# 2) synthesis estimate (P3), from the gemm_kernelgen project root:
vivado -mode batch -source flow/synth.tcl -tclargs xcvu47p-fsvh2892-3-e 3.0 8 8
#   → results/synth/*.rpt   (analysis: docs/report_analysis.md)

# 3) build the kernel (P4):
vivado -mode batch -source flow/package_kernel.tcl                    # → results/xo/*.xo
PLATFORM=xilinx_aws-vu47p-f2_202420_2 ./flow/build_hw.sh hw_emu       # RTL emulation
PLATFORM=xilinx_aws-vu47p-f2_202420_2 ./flow/build_hw.sh hw           # bitstream → AFI

# 4) on the f2 instance (F2 region) — run + check:
source /opt/xilinx/xrt/setup.sh
python3 host/run_hw.py results/hw/gemm_kernel.hw.xclbin --M 8 --N 8 --K 8
```

## Cheaper without f2
- **hw_emu** (RTL emulation) does NOT need an f2 — run it on the build instance; it catches most
  integration bugs before an expensive bitstream. ALWAYS start with hw_emu.
- The kernel logic is already simulation-checked locally (`make kernel`) — emulation should pass cleanly.

## Cost hygiene
- f2 on demand: start it, run, **terminate**. hw synthesis runs on the build instance.
- Keep the `.xo`/`.dcp`/`.xclbin`/AFI manifest in S3 to avoid rebuilding.
- The VU47P is huge (9024 DSP) — our array fits many times over; 64×64+ is possible.
