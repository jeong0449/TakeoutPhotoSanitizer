<#
================================================================================
split_and_zip.ps1
================================================================================

Purpose
-------
Split files into multiple ZIP archives either:

1) By fixed batch count (-N)
2) By maximum ZIP size after compression (-MaxZipGB)

This script is designed for:
- Creating Google Takeout-style 2GB ZIP archives
- Cloud upload size limits
- Large archive segmentation
- Parallel batch processing

--------------------------------------------------------------------------------
Basic Examples
--------------------------------------------------------------------------------

Example 1 – Split into 10 equal batches

    .\split_and_zip.ps1 `
        -InputDir "From_Google_Takeout\_Uncertain" `
        -OutDir "_batches" `
        -N 10

Example 2 – Create 2GB ZIP archives (Takeout-style)

    .\split_and_zip.ps1 `
        -InputDir "From_Google_Takeout" `
        -OutDir "_batches" `
        -MaxZipGB 2

Example 3 – 1.5GB ZIP limit

    .\split_and_zip.ps1 `
        -InputDir "From_Google_Takeout" `
        -OutDir "_batches" `
        -MaxZipGB 1.5

Example 4 – Move instead of copy

    .\split_and_zip.ps1 `
        -InputDir "From_Google_Takeout" `
        -OutDir "_batches" `
        -MaxZipGB 2 `
        -Move

--------------------------------------------------------------------------------
Safety
--------------------------------------------------------------------------------

- Disk free space is checked before processing.
- ZIP files are recreated if they already exist.
- -Move should be used with caution.
- Compression size is checked AFTER each file addition.

Recommended runtime:
- PowerShell 7.x (64-bit)

================================================================================
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$InputDir,

    [Parameter(Mandatory=$true)]
    [string]$OutDir,

    [int]$N,

    [double]$MaxZipGB,

    [switch]$Move
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Dir($p) {
    if (!(Test-Path -LiteralPath $p)) {
        New-Item -ItemType Directory -Path $p -Force | Out-Null
    }
}

# Resolve paths
$InputDir = (Resolve-Path $InputDir).Path
Ensure-Dir $OutDir
$OutDir = (Resolve-Path $OutDir).Path

# Collect files
$files = Get-ChildItem -LiteralPath $InputDir -File -Recurse
if ($files.Count -eq 0) {
    throw "No files found."
}

# Estimate required space
$totalBytes = ($files | Measure-Object -Property Length -Sum).Sum
$drive = Get-PSDrive -Name ([System.IO.Path]::GetPathRoot($OutDir).Substring(0,1))
$free = $drive.Free

Write-Host "[INFO] Total input size (bytes): $totalBytes"
Write-Host "[INFO] Free disk space (bytes): $free"

if ($free -lt ($totalBytes * 1.1)) {
    Write-Warning "Disk space may be insufficient (needs approx 10% overhead)."
}

# Mode 1: Fixed N batches
if ($PSBoundParameters.ContainsKey("N")) {

    $batchDirs = @()
    for ($i=1; $i -le $N; $i++) {
        $name = "{0:D3}" -f $i
        $dir  = Join-Path $OutDir $name
        Ensure-Dir $dir
        $batchDirs += $dir
    }

    $idx = 0
    foreach ($f in $files) {
        $targetDir = $batchDirs[$idx % $N]
        $dest = Join-Path $targetDir $f.Name

        if ($Move) {
            Move-Item -LiteralPath $f.FullName -Destination $dest
        } else {
            Copy-Item -LiteralPath $f.FullName -Destination $dest
        }

        $idx++
    }

    foreach ($dir in $batchDirs) {
        $zip = "$dir.zip"
        if (Test-Path $zip) { Remove-Item $zip -Force }
        Compress-Archive -Path "$dir\*" -DestinationPath $zip
        Write-Host "[ZIP] Created $zip"
    }
}

# Mode 2: Max ZIP size after compression
elseif ($PSBoundParameters.ContainsKey("MaxZipGB")) {

    $maxBytes = [int64]($MaxZipGB * 1GB)
    $zipIndex = 1
    $zipName = Join-Path $OutDir ("{0:D3}.zip" -f $zipIndex)

    if (Test-Path $zipName) { Remove-Item $zipName -Force }

    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipStream = [System.IO.Compression.ZipFile]::Open($zipName, 'Create')

    foreach ($f in $files) {

        $entryName = $f.Name
        [System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile(
            $zipStream, $f.FullName, $entryName
        )

        $zipStream.Dispose()

        $currentSize = (Get-Item $zipName).Length

        if ($currentSize -ge $maxBytes) {
            Write-Host "[ROLL] $zipName reached size limit."
            $zipIndex++
            $zipName = Join-Path $OutDir ("{0:D3}.zip" -f $zipIndex)
            if (Test-Path $zipName) { Remove-Item $zipName -Force }
            $zipStream = [System.IO.Compression.ZipFile]::Open($zipName, 'Create')
        }
        else {
            $zipStream = [System.IO.Compression.ZipFile]::Open($zipName, 'Update')
        }

        if ($Move) {
            Remove-Item -LiteralPath $f.FullName
        }
    }

    $zipStream.Dispose()
    Write-Host "[DONE] Size-based ZIP creation completed."
}
else {
    throw "Specify either -N or -MaxZipGB."
}
