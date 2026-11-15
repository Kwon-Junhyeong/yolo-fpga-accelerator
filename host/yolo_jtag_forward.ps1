param(
    [string]$ImagePath = "",
    [int]$ImageIndex = -1,
    [string]$InputHex = "",
    [string]$Stem = "",
    [string]$OutDir = "C:\skeleton\bin\yolo_hw_jtag_runtime",
    [string]$PathsFile = "",
    [int]$Seq = 1,
    [string]$Manifest = "",
    [string]$TclScript = $(if ($env:YOLO_HW_JTAG_TCL) { $env:YOLO_HW_JTAG_TCL } else { Join-Path $PSScriptRoot "yolo_jtag_batch.tcl" }),
    [string]$Vivado = "vivado",
    [string]$Xsct = "xsct",
    [string]$ProgramBitTcl = (Join-Path $PSScriptRoot "program_yolo_mb_bit.tcl"),
    [string]$DownloadElfTcl = (Join-Path $PSScriptRoot "download_yolo_mb_smoke_elf.tcl"),
    [string]$Bitstream = "",
    [string]$Elf = "",
    [string]$TargetSerial = "",
    [switch]$Program,
    [switch]$ReloadWeights,
    [switch]$SkipWeightStage,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"

function Resolve-OptionalPath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }
    $resolved = Resolve-Path -LiteralPath $Path -ErrorAction SilentlyContinue
    if ($null -ne $resolved) {
        return $resolved.ProviderPath
    }
    return [System.IO.Path]::GetFullPath($Path)
}

function Normalize-ComparePath {
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) {
        return ""
    }
    return (Resolve-OptionalPath $Path).Replace('\', '/').ToLowerInvariant()
}

function Select-ManifestRow {
    param(
        [string]$ManifestPath,
        [string]$Image,
        [int]$Index
    )

    if ([string]::IsNullOrWhiteSpace($ManifestPath) -or !(Test-Path -LiteralPath $ManifestPath)) {
        throw "manifest not found: '$ManifestPath'. Pass -Manifest or -InputHex."
    }

    $rows = Import-Csv -LiteralPath $ManifestPath -Delimiter "`t"
    $imageNorm = Normalize-ComparePath $Image
    $imageBase = if ($Image) { [System.IO.Path]::GetFileName($Image).ToLowerInvariant() } else { "" }

    foreach ($row in $rows) {
        if ($Index -ge 0 -and [int]$row.index -eq $Index) {
            return $row
        }
    }

    if ($imageNorm -ne "") {
        foreach ($row in $rows) {
            if ((Normalize-ComparePath $row.image) -eq $imageNorm) {
                return $row
            }
        }
    }

    if ($imageBase -ne "") {
        foreach ($row in $rows) {
            if ([System.IO.Path]::GetFileName($row.image).ToLowerInvariant() -eq $imageBase) {
                return $row
            }
        }
    }

    return $null
}

New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
$OutDir = Resolve-OptionalPath $OutDir
if ([string]::IsNullOrWhiteSpace($PathsFile)) {
    $PathsFile = Join-Path $OutDir "last_paths.env"
}

if ([string]::IsNullOrWhiteSpace($InputHex)) {
    $row = Select-ManifestRow -ManifestPath $Manifest -Image $ImagePath -Index $ImageIndex
    if ($null -eq $row) {
        throw "image not found in manifest. Pass -InputHex for a pre-generated CONV00_input_32b hex file. image=$ImagePath index=$ImageIndex manifest=$Manifest"
    }
    $InputHex = $row.input
    if ([string]::IsNullOrWhiteSpace($Stem)) {
        $Stem = $row.stem
    }
    if ([string]::IsNullOrWhiteSpace($ImagePath)) {
        $ImagePath = $row.image
    }
    if ($ImageIndex -lt 0) {
        $ImageIndex = [int]$row.index
    }
}
elseif ([string]::IsNullOrWhiteSpace($Stem)) {
    if ($ImagePath) {
        $Stem = [System.IO.Path]::GetFileNameWithoutExtension($ImagePath)
    }
    else {
        $Stem = [System.IO.Path]::GetFileNameWithoutExtension($InputHex)
    }
}

$InputHex = Resolve-OptionalPath $InputHex
if (!(Test-Path -LiteralPath $InputHex)) {
    throw "input hex not found: $InputHex"
}

$singleManifest = Join-Path $OutDir "single_manifest.tsv"
$manifestImage = if ($ImagePath) { Resolve-OptionalPath $ImagePath } else { "" }
@(
    "index`timage`tinput`tstem"
    ("{0}`t{1}`t{2}`t{3}" -f ([Math]::Max($ImageIndex, 0)), $manifestImage.Replace('\', '/'), $InputHex.Replace('\', '/'), $Stem)
) | Set-Content -LiteralPath $singleManifest -Encoding ASCII

$env:YOLO_BATCH_OUT_DIR = $OutDir.Replace('\', '/')
$env:YOLO_BATCH_MANIFEST = $singleManifest.Replace('\', '/')
$env:YOLO_BATCH_MAX_IMAGES = "1"
$env:YOLO_BATCH_START_SEQ = "$Seq"
$env:YOLO_BATCH_RELOAD_FIRST = if ($ReloadWeights) { "1" } else { "0" }
$env:YOLO_BATCH_SKIP_WEIGHT_STAGE = if ($SkipWeightStage) { "1" } else { "0" }
if ($TargetSerial) {
    $env:YOLO_BATCH_TARGET_SERIAL = $TargetSerial
}

Write-Host "YOLO_JTAG_PROTOCOL_BEGIN"
Write-Host "YOLO_JTAG_IMAGE=$ImagePath"
Write-Host "YOLO_JTAG_INPUT=$InputHex"
Write-Host "YOLO_JTAG_STEM=$Stem"
Write-Host "YOLO_JTAG_OUT_DIR=$OutDir"
Write-Host "YOLO_JTAG_SEQ=$Seq"
Write-Host "YOLO_JTAG_STAGE_WEIGHTS=$(if ($SkipWeightStage) { 0 } else { 1 })"
Write-Host "YOLO_JTAG_RELOAD_WEIGHTS=$(if ($ReloadWeights) { 1 } else { 0 })"
Write-Host "YOLO_JTAG_PROGRAM=$(if ($Program) { 1 } else { 0 })"

if ($Program -and !$DryRun) {
    $programTcl = Resolve-OptionalPath $ProgramBitTcl
    $downloadTcl = Resolve-OptionalPath $DownloadElfTcl
    if (!(Test-Path -LiteralPath $programTcl)) {
        throw "program bit TCL not found: $programTcl"
    }
    if (!(Test-Path -LiteralPath $downloadTcl)) {
        throw "download ELF TCL not found: $downloadTcl"
    }

    if (![string]::IsNullOrWhiteSpace($Bitstream)) {
        $env:YOLO_MB_BIT = Resolve-OptionalPath $Bitstream
        Write-Host "YOLO_JTAG_BITSTREAM=$env:YOLO_MB_BIT"
    }
    if (![string]::IsNullOrWhiteSpace($Elf)) {
        $env:YOLO_MB_ELF = Resolve-OptionalPath $Elf
        Write-Host "YOLO_JTAG_ELF=$env:YOLO_MB_ELF"
    }

    Write-Host "YOLO_JTAG_PROGRAM_BEGIN"
    & $Xsct $programTcl
    if ($LASTEXITCODE -ne 0) {
        throw "XSCT bitstream program failed with exit code $LASTEXITCODE"
    }
    & $Xsct $downloadTcl
    if ($LASTEXITCODE -ne 0) {
        throw "XSCT ELF download failed with exit code $LASTEXITCODE"
    }
    Write-Host "YOLO_JTAG_PROGRAM_END"
}

if (!$DryRun) {
    if ([string]::IsNullOrWhiteSpace($TclScript) -or !(Test-Path -LiteralPath $TclScript)) {
        throw "Vivado JTAG batch script not found: '$TclScript'. Pass -TclScript or set YOLO_HW_JTAG_TCL."
    }
    & $Vivado -mode batch -source $TclScript
    if ($LASTEXITCODE -ne 0) {
        throw "Vivado JTAG batch failed with exit code $LASTEXITCODE"
    }
}
else {
    Write-Host "YOLO_JTAG_DRY_RUN=1"
}

$l14 = Join-Path $OutDir ("{0}_L14.txt" -f $Stem)
$l20 = Join-Path $OutDir ("{0}_L20.txt" -f $Stem)
$cyclesFile = Join-Path $OutDir "cycles.tsv"
$fpsReport = Join-Path $OutDir "fps_report.txt"

$cycles = ""
$fps100 = ""
if (Test-Path -LiteralPath $cyclesFile) {
    $cycleRows = Import-Csv -LiteralPath $cyclesFile -Delimiter "`t"
    if ($cycleRows.Count -gt 0) {
        $cycles = $cycleRows[0].cycles
        $fps100 = $cycleRows[0].fps_100mhz
    }
}

if (!$DryRun) {
    if (!(Test-Path -LiteralPath $l14)) {
        throw "L14 output missing after JTAG run: $l14"
    }
    if (!(Test-Path -LiteralPath $l20)) {
        throw "L20 output missing after JTAG run: $l20"
    }
}

@(
    "YOLO_HW_STATUS=OK"
    "YOLO_HW_BACKEND=jtag"
    "YOLO_HW_STEM=$Stem"
    "YOLO_HW_L14=$($l14.Replace('\', '/'))"
    "YOLO_HW_L20=$($l20.Replace('\', '/'))"
    "YOLO_HW_CYCLES=$cycles"
    "YOLO_HW_FPS_100MHZ=$fps100"
    "YOLO_HW_CYCLES_FILE=$($cyclesFile.Replace('\', '/'))"
    "YOLO_HW_FPS_REPORT=$($fpsReport.Replace('\', '/'))"
    "YOLO_HW_OUT_DIR=$($OutDir.Replace('\', '/'))"
) | Set-Content -LiteralPath $PathsFile -Encoding ASCII

Write-Host "YOLO_JTAG_L14=$l14"
Write-Host "YOLO_JTAG_L20=$l20"
if ($cycles) {
    Write-Host "YOLO_JTAG_CYCLES=$cycles"
    Write-Host "YOLO_JTAG_FPS_100MHZ=$fps100"
}
Write-Host "YOLO_JTAG_PATHS=$PathsFile"
Write-Host "YOLO_JTAG_PROTOCOL_END"
