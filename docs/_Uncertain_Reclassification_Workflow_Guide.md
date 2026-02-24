# \_Uncertain Reclassification Workflow Guide

**GenoGlobe -- Learning from Life**\
Created: 2026-02-23

------------------------------------------------------------------------

## Overview

This document describes a safe procedure for reclassifying files that
were placed in the `_Uncertain` folder after running
TakeoutPhotoSanitizer --- without modifying the original SHA-256
database or altering file bytes.

### Core Principles

-   Never modify the existing `SHA-256.txt`.
-   Never modify file bytes (image/video content).
-   Reclassification must be recorded in a separate override file.
-   Design with future extensibility (albums, people, locations,
    annotations).

------------------------------------------------------------------------

## Step 0 -- Create Operational Folders

Create `_ops` and subfolders at the same level as `From_Google_Takeout`:

Photos_Backup\
├─ From_Google_Takeout\
│ ├─ 2019\
│ ├─ 2020\
│ └─ SHA-256.txt ← hash database └─ \_ops\
├─ reclass\
└─ notes\

Only operational and management files should be stored inside `_ops`.

------------------------------------------------------------------------

## Step 1 -- Extract `_Uncertain` File List

PowerShell command:

``` powershell
$unc = "From_Google_Takeout\_Uncertain"
$out = "_ops\reclass\uncertain_review.csv"

if (!(Test-Path -LiteralPath $unc)) {
    throw "_Uncertain folder not found: $unc"
}

Get-ChildItem -LiteralPath $unc -File -Recurse |
Select-Object FullName, Name, Length, LastWriteTime |
Export-Csv -LiteralPath $out -NoTypeInformation -Encoding utf8BOM
```

Generated file:

Photos_Backup_ops`\reclass`{=tex}`\uncertain`{=tex}\_review.csv

------------------------------------------------------------------------

## Step 2 -- Manual Review

Open `uncertain_review.csv` in Excel and add:

-   `year_final` (confirmed year, e.g., 2014)
-   `note` (reason for classification decision)

Only fill `year_final` when confident.

Save as:

Photos_Backup_ops`\reclass`{=tex}`\uncertain`{=tex}\_review_done.csv

------------------------------------------------------------------------

## Step 3 -- Generate Year Override File

``` powershell
# Assumes execution from working directory (= Photos_Backup)

$in = "_ops\reclass\uncertain_review_done.csv"
$out = "_ops\reclass\year_override.tsv"

# Verify input file
if (!(Test-Path $in)) {
    throw "Input file not found: $in"
}

# Create output directory if missing
$outDir = Split-Path -Parent $out
if (!(Test-Path $outDir)) { 
    New-Item -ItemType Directory -Path $outDir | Out-Null 
}

Import-Csv $in |
ForEach-Object {

    # Clean year_final (trim whitespace)
    $yy = ("" + $_.year_final).Trim()

    # Process only valid 4-digit year
    if ($yy -notmatch '^\d{4}$') { return }

    # Validate source path
    $src = $_.FullName
    if ([string]::IsNullOrWhiteSpace($src)) { return }
    if (!(Test-Path -LiteralPath $src)) { return }

    # Clean note (prevent TSV corruption: remove tabs/newlines)
    $note = ("" + $_.note)
    $note = $note -replace "`t", " "
    $note = $note -replace "(\r\n|\n|\r)", " "
    $note = $note.Trim()

    # Compute SHA-256
    $h = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash

    # Output TSV row
    "{0}`t{1}`t{2}`t{3}" -f $h, $yy, (Get-Date -Format "yyyy-MM-dd"), $note
} | Set-Content -LiteralPath $out -Encoding UTF8
```

TSV format:

sha256`<TAB>`{=html}year_final`<TAB>`{=html}date`<TAB>`{=html}note

This file acts as a manual reclassification patch record.\
It is regenerated (overwritten) each time.

------------------------------------------------------------------------

## Step 4 -- Move Files to Final Year Folder

``` powershell
# Assumes execution from working directory (= Photos_Backup)

$in = "_ops\reclass\uncertain_review_done.csv"
$rootMedia = "From_Google_Takeout"
$log = "_ops\reclass\move_log.tsv"

# Verify input file
if (!(Test-Path -LiteralPath $in)) {
    throw "Input file not found: $in"
}

# Verify media root
if (!(Test-Path -LiteralPath $rootMedia)) {
    throw "Media root folder not found: $rootMedia"
}

# Create log folder if missing
$logDir = Split-Path -Parent $log
if (!(Test-Path -LiteralPath $logDir)) { 
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null 
}

# Counters for summary output
$cnt_total = 0
$cnt_skip = 0
$cnt_moved = 0
$cnt_failed = 0

Import-Csv -LiteralPath $in |
ForEach-Object {

    $cnt_total++

    # Clean year_final
    $yy = ("" + $_.year_final).Trim()
    if ($yy -notmatch '^\d{4}$') { $cnt_skip++; return }

    # Validate source file
    $src = $_.FullName
    if ([string]::IsNullOrWhiteSpace($src)) { $cnt_skip++; return }
    if (!(Test-Path -LiteralPath $src)) { $cnt_skip++; return }

    # Safety check: only move files inside _Uncertain
    if ($src -notmatch '[\\/]+From_Google_Takeout[\\/]+_Uncertain[\\/]+') { 
        $cnt_skip++; return 
    }

    # Ensure destination year folder exists
    $dstDir = Join-Path $rootMedia $yy
    if (!(Test-Path -LiteralPath $dstDir)) { 
        New-Item -ItemType Directory -Path $dstDir -Force | Out-Null 
    }

    # Determine destination filename
    $name = $_.Name
    if ([string]::IsNullOrWhiteSpace($name)) { 
        $name = [System.IO.Path]::GetFileName($src) 
    }

    $dst = Join-Path $dstDir $name

    # Handle filename collision using SHA-256 prefix
    if (Test-Path -LiteralPath $dst) {
        $h8 = (Get-FileHash -LiteralPath $src -Algorithm SHA256).Hash.Substring(0,8)
        $dst = Join-Path $dstDir ("{0}_{1}" -f $h8, $name)
    }

    $status = "moved"

    try {
        Move-Item -LiteralPath $src -Destination $dst -ErrorAction Stop
        $cnt_moved++
    }
    catch {
        $status = "move_failed: " + ($_.Exception.Message -replace "(\r\n|\n|\r)", " " -replace "`t"," ")
        $cnt_failed++
    }

    # Clean log fields (remove tabs/newlines)
    $srcLog = ($src -replace "`t"," " -replace "(\r\n|\n|\r)"," ")
    $dstLog = ($dst -replace "`t"," " -replace "(\r\n|\n|\r)"," ")

    # Log format: time, year_final, src, dst, status
    "{0}`t{1}`t{2}`t{3}`t{4}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $yy, $srcLog, $dstLog, $status |
    Add-Content -LiteralPath $log -Encoding UTF8
}

Write-Host ("[MOVE] total={0} moved={1} failed={2} skipped={3} log={4}" -f $cnt_total, $cnt_moved, $cnt_failed, $cnt_skip, $log)
```

This process does not alter file bytes, so SHA-256 remains unchanged.

------------------------------------------------------------------------

## Optional: Future Annotation File

Photos_Backup_ops`\notes`{=tex}`\annotations`{=tex}.tsv

Format:

sha256`<TAB>`{=html}key`<TAB>`{=html}value`<TAB>`{=html}date

Example:

AAA... place Jeju Seongsan 2026-02-23\
AAA... people Mom;Dad 2026-02-23

This structure supports future expansion: albums, people, locations,
keywords.

------------------------------------------------------------------------

## Operational Loop

1.  Review `_Uncertain`
2.  Enter `year_final`
3.  Generate `year_override.tsv`
4.  Move files
5.  Confirm `_Uncertain` reduction
6.  Repeat

------------------------------------------------------------------------

## Design Philosophy

-   Files are immutable objects.
-   SHA-256 is the permanent identifier.
-   Reclassification is metadata.
-   Albums and annotations are relationship layers.

------------------------------------------------------------------------

End of document.
