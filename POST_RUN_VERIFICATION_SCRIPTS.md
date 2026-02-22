# Post-Run Verification Scripts (PowerShell)

Last Updated: 2026-02-22

This document collects small PowerShell snippets you can use after
running **TakeoutPhotoSanitizer** to verify results (counts,
distribution, suspected contamination, and OneDrive transfer readiness).

> Notes - All scripts are read-only unless explicitly stated. - Run
> these from **Windows PowerShell 5.1** or **PowerShell 7.x**. - Replace
> paths to match your environment.

------------------------------------------------------------------------

## 0) Set Your Root Path

``` powershell
$Root = "C:\Users\jeong\Projects\TakeoutPhotoSanitizer\Photos_Backup\From_Google_Takeout"
```

------------------------------------------------------------------------

## 1) Count Media Files by Top-Level Folder (Year Buckets)

Counts media files under each first-level folder (e.g., `2014`, `2015`,
`_Uncertain`).

``` powershell
$MediaExt = @(".jpg",".jpeg",".png",".gif",".webp",".heic",".mp4",".mov",".m4v",".avi",".mkv",".dng",".cr2",".nef",".arw")

Get-ChildItem -LiteralPath $Root -Directory | ForEach-Object {
  $dir = $_.FullName
  $count = (Get-ChildItem -LiteralPath $dir -Recurse -File -ErrorAction SilentlyContinue |
            Where-Object { $MediaExt -contains $_.Extension.ToLowerInvariant() }).Count
  [PSCustomObject]@{ Folder = $_.Name; MediaFiles = $count }
} | Sort-Object MediaFiles -Descending | Format-Table -AutoSize
```

------------------------------------------------------------------------

## 2) Count Media Files by Extension (Whole Archive)

``` powershell
$MediaExt = @(".jpg",".jpeg",".png",".gif",".webp",".heic",".mp4",".mov",".m4v",".avi",".mkv",".dng",".cr2",".nef",".arw")

Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
  Where-Object { $MediaExt -contains $_.Extension.ToLowerInvariant() } |
  Group-Object { $_.Extension } |
  Sort-Object Count -Descending |
  Select-Object Name, Count |
  Format-Table -AutoSize
```

------------------------------------------------------------------------

## 3) List the Remaining `_Uncertain` Files (Quick Review)

``` powershell
$Unc = Join-Path $Root "_Uncertain"
Get-ChildItem -LiteralPath $Unc -Recurse -File -ErrorAction SilentlyContinue |
  Select-Object FullName, Length, LastWriteTime |
  Sort-Object Length -Descending |
  Format-Table -AutoSize
```

------------------------------------------------------------------------

## 4) Spot-Check EXIF Date on Random JPEGs

This reads EXIF tags (DateTimeOriginal / Digitized / DateTime) from
random JPEG samples. Useful to confirm EXIF reading works in your
environment.

``` powershell
Add-Type -AssemblyName System.Drawing | Out-Null

function Get-ExifDate {
  param([string]$Path)
  $propIds = @(0x9003, 0x9004, 0x0132)
  $img = $null
  try {
    $img = [System.Drawing.Image]::FromFile($Path)
    foreach($id in $propIds){
      if($img.PropertyIdList -contains $id){
        $p = $img.GetPropertyItem($id)
        $s = ([Text.Encoding]::ASCII.GetString($p.Value)).Trim([char]0)
        if($s){
          try { return [DateTime]::ParseExact($s,'yyyy:MM:dd HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture) } catch {}
          try { return [DateTime]::ParseExact($s,'yyyy:MM:dd HH:mm',[Globalization.CultureInfo]::InvariantCulture) } catch {}
        }
      }
    }
  } catch {
    return $null
  } finally {
    if($img) { $img.Dispose() }
  }
  return $null
}

$Sample = Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
  Where-Object { $_.Extension -match '^(?i)\.jpe?g$' } |
  Get-Random -Count 20

$Sample | ForEach-Object {
  $dt = Get-ExifDate $_.FullName
  $dtText = if($dt) { $dt.ToString("yyyy-MM-dd HH:mm:ss") } else { "NO_EXIF" }
  "{0}`t{1}" -f $dtText, $_.FullName
}
```

------------------------------------------------------------------------

## 5) Find Files That Look Like Wrong-Year Contamination

Example: list files currently placed under `2026` but showing a
different EXIF year.

``` powershell
$YearDir = Join-Path $Root "2026"
if(Test-Path -LiteralPath $YearDir){
  Add-Type -AssemblyName System.Drawing | Out-Null

  function Get-ExifYear {
    param([string]$Path)
    $dt = Get-ExifDate $Path
    if($dt) { return $dt.Year }
    return $null
  }

  Get-ChildItem -LiteralPath $YearDir -Recurse -File -ErrorAction SilentlyContinue |
    Where-Object { $_.Extension -match '^(?i)\.jpe?g$' } |
    ForEach-Object {
      $y = Get-ExifYear $_.FullName
      if($y -and $y -ne 2026){
        [PSCustomObject]@{ ExifYear = $y; Path = $_.FullName }
      }
    } | Sort-Object ExifYear | Format-Table -AutoSize
} else {
  "No 2026 folder found under $Root"
}
```

------------------------------------------------------------------------

## 6) Detect "Album Duplicate" Patterns (Same Base Name, Different Paths)

This does NOT compute hashes (fast check). It looks for repeated leaf
names across the archive.

``` powershell
$MediaExt = @(".jpg",".jpeg",".png",".gif",".webp",".heic",".mp4",".mov",".m4v",".avi",".mkv",".dng",".cr2",".nef",".arw")

Get-ChildItem -LiteralPath $Root -Recurse -File -ErrorAction SilentlyContinue |
  Where-Object { $MediaExt -contains $_.Extension.ToLowerInvariant() } |
  Group-Object Name |
  Where-Object { $_.Count -ge 3 } |
  Sort-Object Count -Descending |
  Select-Object -First 50 |
  ForEach-Object {
    "=== {0} (count={1})" -f $_.Name, $_.Count
    $_.Group | Select-Object -First 5 FullName | ForEach-Object { "  " + $_.FullName }
    ""
  }
```

------------------------------------------------------------------------

## 7) Check Available Disk Space (Before Copying to OneDrive)

``` powershell
Get-PSDrive -Name C | Select-Object Name, Free, Used, @{n="FreeGB";e={ [math]::Round($_.Free/1GB,1) }}
```

------------------------------------------------------------------------

## 8) OneDrive "Upload-Then-Free-Space" Reminder Checklist

-   Copy year folders incrementally to OneDrive
-   Wait for sync to complete
-   Then mark folders as online-only ("Free up space") if File On-Demand
    is enabled
-   Copy `_hash_db` only once at the end

------------------------------------------------------------------------

## 9) Optional: Snapshot `_hash_db` at the End (Write Operation)

⚠ This copies the hash DB (safe, but it does write a file). Run only
when the sanitizer is not running.

``` powershell
$HashDir = Join-Path $Root "_hash_db"
$Db = Join-Path $HashDir "sha256_db.tsv"
$Snap = Join-Path $HashDir ("sha256_db.snapshot.2026-02-22.tsv")

if(Test-Path -LiteralPath $Db){
  Copy-Item -LiteralPath $Db -Destination $Snap
  "Snapshot written: $Snap"
} else {
  "No sha256_db.tsv found at: $Db"
}
```

------------------------------------------------------------------------

## Appendix: Recommended Working Directory

If you keep the repo and data under a single project folder:

``` powershell
C:\Users\jeong\Projects\TakeoutPhotoSanitizer\
  TakeoutPhotoSanitizer.ps1
  Takeout_Zip\
  Photos_Backup\From_Google_Takeout\
```

------------------------------------------------------------------------
