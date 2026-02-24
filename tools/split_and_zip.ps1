<#
================================================================================
split_and_zip.ps1
================================================================================

Purpose
-------
Split files under a specified input directory into N numbered batch folders
(001, 002, 003, ...), then create a ZIP archive for each batch folder.

This utility is useful when:
- Uploading large collections to cloud services with per-upload limits
- Creating manageable archive segments
- Preparing staged Google Takeout reprocessing batches
- Dividing large photo collections for parallel processing

--------------------------------------------------------------------------------
Execution Assumptions
--------------------------------------------------------------------------------

- The script is executed from the project working directory.
- InputDir can be relative or absolute.
- Only FILES are processed (directories themselves are not split objects).
- Subdirectories are included unless -PreserveTree is omitted.

--------------------------------------------------------------------------------
Basic Usage Examples
--------------------------------------------------------------------------------

Example 1 – Split into 10 equal batches (copy mode)

    .\split_and_zip.ps1 `
        -InputDir "From_Google_Takeout\_Uncertain" `
        -OutDir "_batches" `
        -N 10

Result:
    _batches\
        001\
        002\
        ...
        010\
        001.zip
        002.zip
        ...
        010.zip

Original files remain untouched.


Example 2 – Split into 4 batches and MOVE files

    .\split_and_zip.ps1 `
        -InputDir "From_Google_Takeout\2026_suspects" `
        -OutDir "_batches" `
        -N 4 `
        -Move

Files are moved instead of copied.


Example 3 – Preserve original folder structure inside each batch

    .\split_and_zip.ps1 `
        -InputDir "From_Google_Takeout" `
        -OutDir "_batches" `
        -N 6 `
        -PreserveTree

Each batch folder maintains the original relative directory structure.


Example 4 – Absolute path usage

    .\split_and_zip.ps1 `
        -InputDir "E:\Photos_Backup\From_Google_Takeout" `
        -OutDir "E:\Photos_Backup\_batches" `
        -N 8


--------------------------------------------------------------------------------
Distribution Strategy
--------------------------------------------------------------------------------

Files are distributed using round-robin assignment:

    file1 → 001
    file2 → 002
    ...
    fileN → 00N
    fileN+1 → 001
    ...

This ensures approximately equal file counts per batch.

--------------------------------------------------------------------------------
Collision Handling
--------------------------------------------------------------------------------

If multiple files with the same name are placed into the same batch folder
(flat mode), name collisions are resolved by prefixing the first 8 characters
of the SHA-256 hash:

    original.jpg
    a1b2c3d4_original.jpg

--------------------------------------------------------------------------------
Safety Notes
--------------------------------------------------------------------------------

- ZIP files are recreated if they already exist.
- Use -Move with caution.
- For very large datasets, ensure sufficient disk space.
- ZIP creation uses .NET System.IO.Compression.

--------------------------------------------------------------------------------
Compatibility
--------------------------------------------------------------------------------

Tested on:
- Windows PowerShell 5.1
- PowerShell 7.x (recommended)

--------------------------------------------------------------------------------
License
--------------------------------------------------------------------------------

This script is provided as a utility component of the TakeoutPhotoSanitizer
ecosystem. Use at your own risk.

================================================================================
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]
    [string]$InputDir,

    [Parameter(Mandatory=$true)]
    [string]$OutDir,

    [Parameter(Mandatory=$true)]
    [ValidateRange(1, 999)]
    [int]$N,

    # If set, files are moved instead of copied
    [switch]$Move,

    # Preserve subfolder structure inside each batch folder (default: flat)
    [switch]$PreserveTree
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Ensure-Dir([string]$p) {
    if (!(Test-Path -LiteralPath $p)) {
        New-Item -ItemType Directory -Path $p -Force | Out-Null
    }
}

# Resolve paths relative to current directory
$InputDir = (Resolve-Path -LiteralPath $InputDir).Path
Ensure-Dir $OutDir
$OutDir = (Resolve-Path -LiteralPath $OutDir).Path

# Collect files
$files = Get-ChildItem -LiteralPath $InputDir -File -Recurse
if ($files.Count -eq 0) {
    throw "No files found under: $InputDir"
}

# Prepare batch folders 001..N
$batchDirs = @()
for ($i=1; $i -le $N; $i++) {
    $name = "{0:D3}" -f $i
    $dir  = Join-Path $OutDir $name
    Ensure-Dir $dir
    $batchDirs += $dir
}

Write-Host ("[INFO] Input files: {0}" -f $files.Count)
Write-Host ("[INFO] Batches: {0}" -f $N)
Write-Host ("[INFO] Mode: {0}" -f ($(if ($Move) {"MOVE"} else {"COPY"})))
Write-Host ("[INFO] PreserveTree: {0}" -f $PreserveTree)

# Distribute files round-robin
$idx = 0
foreach ($f in $files) {
    $batchDir = $batchDirs[$idx % $N]

    if ($PreserveTree) {
        # Keep relative path
        $rel = $f.FullName.Substring($InputDir.Length).TrimStart('\','/')
        $destPath = Join-Path $batchDir $rel
        $destDir  = Split-Path -Parent $destPath
        Ensure-Dir $destDir
    } else {
        # Flat copy: name collisions possible -> prefix with short hash if needed
        $destPath = Join-Path $batchDir $f.Name
        if (Test-Path -LiteralPath $destPath) {
            $h8 = (Get-FileHash -LiteralPath $f.FullName -Algorithm SHA256).Hash.Substring(0,8)
            $destPath = Join-Path $batchDir ("{0}_{1}" -f $h8, $f.Name)
        }
    }

    if ($Move) {
        Move-Item -LiteralPath $f.FullName -Destination $destPath
    } else {
        Copy-Item -LiteralPath $f.FullName -Destination $destPath
    }

    $idx++
}

# Zip each batch folder
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

for ($i=1; $i -le $N; $i++) {
    $name = "{0:D3}" -f $i
    $dir  = Join-Path $OutDir $name
    $zip  = Join-Path $OutDir ("{0}.zip" -f $name)

    if (Test-Path -LiteralPath $zip) {
        Remove-Item -LiteralPath $zip -Force
    }

    [System.IO.Compression.ZipFile]::CreateFromDirectory($dir, $zip)
    Write-Host ("[ZIP] {0} -> {1}" -f $dir, $zip)
}

Write-Host "[DONE] Split & zip completed."