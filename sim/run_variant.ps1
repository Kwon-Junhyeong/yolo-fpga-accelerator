# Full-frame simulation of one build-switch set, checked against the NumPy model.
# -Prepared: a sim folder where make_static_roms.py and golden.py prepare have run (params, reference, generated, rom).
# usage: run_variant.ps1 -Repo <repository> -Prepared <sim folder> -Out <work folder> -VivadoBin <...\Vivado\bin>
#        -Switches "YOLO_HEAD32_PARTITION_DDR,YOLO_TRUE_LATENCY_COUNTER,..." -Stem 0078_CAPP_testset_long_10115
param([string]$Repo, [string]$Prepared, [string]$Out, [string]$VivadoBin, [string]$Switches, [string]$Stem)
$ErrorActionPreference = "Continue"
if (Test-Path -LiteralPath $Out) { Remove-Item -LiteralPath $Out -Recurse -Force -Confirm:$false }
New-Item -ItemType Directory "$Out\sim\results" | Out-Null
Copy-Item -Recurse -LiteralPath "$Repo\rtl" -Destination "$Out\rtl"
Copy-Item -Recurse -LiteralPath "$Repo\contest" -Destination "$Out\contest"
foreach ($d in "params", "reference", "generated", "rom") { Copy-Item -Recurse -LiteralPath "$Prepared\$d" -Destination "$Out\sim\$d" }
Get-ChildItem -LiteralPath "$Repo\sim" -File | Where-Object { $_.Extension -in ".py", ".v", ".f" } | Copy-Item -Destination "$Out\sim\"

$lines = @('`ifndef YOLO_BUILD_CONFIG_H', '`define YOLO_BUILD_CONFIG_H')
foreach ($s in $Switches.Split(",")) { if ($s) { $lines += "``define $s" } }
$lines += '`endif'
$lines | Set-Content -Encoding ASCII "$Out\rtl\yolo_build_config_h.v"

Set-Location "$Out\sim"
& cmd /c "`"$VivadoBin\xvlog.bat`" -i ../rtl -i ../contest -f files.f > xvlog.out 2>&1"
& cmd /c "`"$VivadoBin\xelab.bat`" tb_frame -s tb_frame > xelab.out 2>&1"
& cmd /c "`"$VivadoBin\xsim.bat`" tb_frame -R -testplusarg RUN_L20 > xsim.out 2>&1"
Select-String -Path xsim.out -Pattern "PERF|CSR_LATCH|ERROR|TIMEOUT" | ForEach-Object { $_.Line }
python golden.py compare-hw --layers L0,L2,L4,L6,L8,L8RAW,L10,L11,L12,L13,L17
python check_heads.py params $Stem reference
