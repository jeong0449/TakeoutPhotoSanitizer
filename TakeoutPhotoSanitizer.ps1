<# 
Version: 1.0.0
Stability milestone: EXIF FromFile fix (1107 → 28 _Uncertain)

Features
- Processes ALL *.zip in ZipDir in batches (default 4)
- Creates per-batch work folder, scans ONLY that folder, then deletes it
- Moves processed ZIPs to _processed (or deletes them with -DeleteZips)
- Year classification priority (v3.3.5): Takeout JSON -> EXIF(JPG/JPEG) -> Windows Media Properties -> Filename -> HashRep (only when no strong evidence) -> Quarantine (_Uncertain); LastWriteTime is NOT used to confirm year
- JSON folder cache (per-run) for performance
- Hash de-dup with buffered writes + retry
- Skips bad files without stopping; logs to _bad_files.txt
- Disk-space guard (MinFreeGB); auto-reduces batch 8->6->4 if needed

Usage:
  Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass
  .\TakeoutPhotoSanitizer.ps1 -ZipDir "C:\...\Takeout_Zip" -DestRoot "D:\...\From_Google_Takeout" -BatchSize 4 -MinFreeGB 25
#>

param(
  [Parameter(Mandatory=$true)][string]$ZipDir,
  [Parameter(Mandatory=$true)][string]$DestRoot,
  [int]$BatchSize = 4,
  [int]$MinFreeGB = 25,
  [switch]$DeleteZips,
  [switch]$KeepWork,
  [switch]$VerboseLog,
  [switch]$NoSidecarRepair,
  [switch]$ReportSidecars,
  [int]$SuspectYear = (Get-Date).Year,
  [string]$SuspectLeaf = "$SuspectYear`_suspects",
  [switch]$UseWpfCom
)

$MediaExt = @(
  ".jpg",".jpeg",".png",".gif",".webp",".heic",
  ".mp4",".mov",".m4v",".avi",".mkv",
  ".dng",".cr2",".nef",".arw"
)

$ErrorActionPreference = "Continue"

$script:SuspectYear = $SuspectYear
$script:SuspectLeaf = $SuspectLeaf

# ---- robust JSON reader (v3.1) ----
function Read-TakeoutJsonSafe {
  param([Parameter(Mandatory=$true)][string]$Path)
  try {
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    # Drop NUL bytes (sometimes present in Takeout JSON)
    $bytes = $bytes | Where-Object { $_ -ne 0 }
    $text  = [System.Text.Encoding]::UTF8.GetString($bytes)
    # Remove control chars except tab/newline/CR
    $text  = [regex]::Replace($text, '[\x00-\x08\x0B\x0C\x0E-\x1F]', '')
    return ($text | ConvertFrom-Json)
  } catch {
    return $null
  }
}

function Read-TakeoutJsonRobust {
  param([Parameter(Mandatory=$true)][string]$Path)
  $j = $null
  try {
    $j = (Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -ErrorAction Stop)
  } catch {
    $j = $null
  }
  if($null -ne $j){ return $j }
  return (Read-TakeoutJsonSafe -Path $Path)
}


# ---- globals / caches ----
$JsonYearCache = @{}  # dir -> hashtable(baseName -> year)
$HashBuffer    = New-Object System.Collections.Generic.List[string]
$script:TouchedDestDirs = [System.Collections.Generic.HashSet[string]]::new()
$script:Stats = @{ Moved=0; Duplicates=0; SidecarUpdated=0; SidecarRepaired=0 }


function Log($msg){
  $ts = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
  Write-Host "[$ts] $msg"
}

function EnsureDir($p){
  if(-not (Test-Path -LiteralPath $p)){
    New-Item -ItemType Directory -Path $p | Out-Null
  }
}


function FreeGB($anyPath){
  $dn=(Get-Item $anyPath).PSDrive.Name
  [Math]::Round((Get-PSDrive -Name $dn).Free/1GB, 2)
}

function AppendTextWithRetry([string]$path, [string]$text, [int]$maxTry=8){
  for($i=1; $i -le $maxTry; $i++){
    try{
      Add-Content -LiteralPath $path -Value $text -ErrorAction Stop
      return $true
    } catch {
      Start-Sleep -Milliseconds (150 * $i)
    }
  }
  return $false
}

function Get7z(){
  $c = Get-Command 7z.exe -ErrorAction SilentlyContinue
  if($c){ return $c.Source }
  return $null
}

function TryGetGoogleJsonYears([string]$mediaPath){
  # Returns @{ TakenYear = <yyyy or $null>; CreationYear = <yyyy or $null> }
  try{
    $dir  = Split-Path -Parent $mediaPath
    $name = Split-Path -Leaf   $mediaPath

    if(-not $JsonYearCache.ContainsKey($dir)){
      $mapTaken = @{}
      $mapCreation = @{}

      Get-ChildItem -LiteralPath $dir -Filter *.json -File -ErrorAction SilentlyContinue | ForEach-Object {
        try{
          $j = Read-TakeoutJsonRobust -Path $_.FullName

          $takenTs = $null
          $creationTs = $null

          if($j.photoTakenTime -and $j.photoTakenTime.timestamp){
            $takenTs = $j.photoTakenTime.timestamp
          }
          if($j.creationTime -and $j.creationTime.timestamp){
            $creationTs = $j.creationTime.timestamp
          }

          # Normalize base key names (same logic as before)
          $base = $_.BaseName -replace '\.supplemental-metadata$',''
          $baseNoExt = [IO.Path]::GetFileNameWithoutExtension($base)

          if($takenTs){
            $dt = [DateTimeOffset]::FromUnixTimeSeconds([int64]$takenTs).LocalDateTime
            $y  = $dt.Year.ToString()
            $mapTaken[$base] = $y
            if($baseNoExt -and -not $mapTaken.ContainsKey($baseNoExt)){ $mapTaken[$baseNoExt] = $y }
          }

          if($creationTs){
            $dtc = [DateTimeOffset]::FromUnixTimeSeconds([int64]$creationTs).LocalDateTime
            $yc  = $dtc.Year.ToString()
            $mapCreation[$base] = $yc
            if($baseNoExt -and -not $mapCreation.ContainsKey($baseNoExt)){ $mapCreation[$baseNoExt] = $yc }
          }
        } catch {}
      }

      $JsonYearCache[$dir] = @{ Taken=$mapTaken; Creation=$mapCreation }
    }

    $cache = $JsonYearCache[$dir]
    $taken = $cache.Taken
    $creation = $cache.Creation

    $keyNoExt = [IO.Path]::GetFileNameWithoutExtension($name)

    $ty = $null
    if($taken.ContainsKey($name)){ $ty = $taken[$name] }
    elseif($taken.ContainsKey($keyNoExt)){ $ty = $taken[$keyNoExt] }

    $cy = $null
    if($creation.ContainsKey($name)){ $cy = $creation[$name] }
    elseif($creation.ContainsKey($keyNoExt)){ $cy = $creation[$keyNoExt] }

    return @{ TakenYear=$ty; CreationYear=$cy }
  } catch {}

  return @{ TakenYear=$null; CreationYear=$null }
}

function TryExifDate([string]$path){
  $ext=[IO.Path]::GetExtension($path).ToLower()
  if($ext -ne ".jpg" -and $ext -ne ".jpeg"){ return $null }

  try{
    Add-Type -AssemblyName System.Drawing -ErrorAction SilentlyContinue | Out-Null

    $propIds = @(0x9003,0x9004,0x0132) # DateTimeOriginal, DateTimeDigitized, DateTime
    $img = $null

    try{
      # Prefer FromFile (often more reliable than FromStream on some JPEGs)
      $img = [System.Drawing.Image]::FromFile($path)

      foreach($propId in $propIds){
        if($img.PropertyIdList -contains $propId){
          $p = $img.GetPropertyItem($propId)
          $s = ([Text.Encoding]::ASCII.GetString($p.Value)).Trim([char]0)
          if($s){
            try { return [DateTime]::ParseExact($s,'yyyy:MM:dd HH:mm:ss',[Globalization.CultureInfo]::InvariantCulture) } catch {}
            try { return [DateTime]::ParseExact($s,'yyyy:MM:dd HH:mm',[Globalization.CultureInfo]::InvariantCulture) } catch {}
          }
        }
      }
    } finally {
      if($img){ $img.Dispose() }
    }

    return $null
  } catch {
    return $null
  }
}

function TryExifDateWpf([string]$path){
  $ext=[IO.Path]::GetExtension($path).ToLower()
  if($ext -ne ".jpg" -and $ext -ne ".jpeg"){ return $null }

  try{
    # WPF metadata reader (more reliable than System.Drawing on PS7)
    Add-Type -AssemblyName PresentationCore -ErrorAction SilentlyContinue | Out-Null
    $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try{
      $frame = [System.Windows.Media.Imaging.BitmapFrame]::Create(
        $fs,
        [System.Windows.Media.Imaging.BitmapCreateOptions]::DelayCreation,
        [System.Windows.Media.Imaging.BitmapCacheOption]::None
      )
      $meta = $frame.Metadata
      if($null -eq $meta){ return $null }

      $s = $null
      try { $s = $meta.GetQuery("/app1/ifd/exif:{uint=36867}") } catch {}
      if(-not $s){
        try { $s = $meta.GetQuery("/app1/ifd/{uint=306}") } catch {}
      }
      if(-not $s){ return $null }

      $s = [string]$s
      # EXIF datetime format: "YYYY:MM:DD HH:MM:SS"
      # Parse by normalizing the first two ':' into '-'
      $s2 = $s.Replace(":", "-", 2)
      return [DateTime]::Parse($s2)
    } finally {
      $fs.Dispose()
    }
  } catch {
    return $null
  }
}

function TryDateFromFilename([string]$name){
  if([string]::IsNullOrWhiteSpace($name)){ return $null }

  # Common numeric patterns:
  #  - 2025_04_04 19_29(_05)
  #  - 2025-04-04 19-29-05
  #  - 20250404_192905
  if($name -match '(?<!\d)(19\d{2}|20\d{2})[._-]?(0[1-9]|1[0-2])[._-]?(0[1-9]|[12]\d|3[01])(?:[ T._-]?([01]\d|2[0-3])[.:_-]?([0-5]\d)(?:[.:_-]?([0-5]\d))?)?'){
    try{
      $y=[int]$Matches[1]; $mo=[int]$Matches[2]; $d=[int]$Matches[3]
      $hh=0; $mm=0; $ss=0
      if($Matches[4]){ $hh=[int]$Matches[4] }
      if($Matches[5]){ $mm=[int]$Matches[5] }
      if($Matches[6]){ $ss=[int]$Matches[6] }
      return [DateTime]::new($y,$mo,$d,$hh,$mm,$ss)
    } catch {}
  }

  # Korean pattern (encoding-safe via \uXXXX):
  #  - "2025년 3월 31일 오전 12_06_52"
  #  - "2025년3월31일 오후 1시 02분 05초" (loose)
  #
  # \uB144=년, \uC6D4=월, \uC77C=일, \uC624\uC804=오전, \uC624\uD6C4=오후, \uC2DC=시, \uBD84=분, \uCD08=초
  if($name -match '(?<!\d)(19\d{2}|20\d{2})\s*\uB144\s*(\d{1,2})\s*\uC6D4\s*(\d{1,2})\s*\uC77C(?:\s*(\uC624\uC804|\uC624\uD6C4)\s*(\d{1,2})(?:\s*[:\uC2DC_ \-]\s*(\d{1,2}))?(?:\s*[:\uBD84_ \-]\s*(\d{1,2}))?(?:\s*[:\uCD08_ \-]\s*(\d{1,2}))?)?(?!\d)'){
    try{
      $y=[int]$Matches[1]; $mo=[int]$Matches[2]; $d=[int]$Matches[3]
      $ampm=$Matches[4]
      $hh=0; $mm=0; $ss=0
      if($Matches[5]){ $hh=[int]$Matches[5] }
      if($Matches[6]){ $mm=[int]$Matches[6] }
      if($Matches[7]){ $ss=[int]$Matches[7] }

      $am = [string]::Concat([char]0xC624,[char]0xC804) # 오전
      $pm = [string]::Concat([char]0xC624,[char]0xD6C4) # 오후
      if($ampm -eq $pm -and $hh -lt 12){ $hh += 12 }
      if($ampm -eq $am -and $hh -eq 12){ $hh = 0 }

      return [DateTime]::new($y,$mo,$d,$hh,$mm,$ss)
    } catch {}
  }

  # Epoch milliseconds (13 digits)
  if($name -match '(?<!\d)(\d{13})(?!\d)'){
    try{
      $ms=[int64]$Matches[1]
      return ([DateTimeOffset]::FromUnixTimeMilliseconds($ms).LocalDateTime)
    } catch {}
  }

  # Epoch seconds (10 digits) - accept only plausible modern range (avoid numeric IDs like 1000006409 -> year 2001)
  if($name -match '(?<!\d)(\d{10})(?!\d)'){
    try{
      $sec=[int64]$Matches[1]
      $dt = ([DateTimeOffset]::FromUnixTimeSeconds($sec).LocalDateTime)
      $minY = 2010
      $maxY = (Get-Date).Year + 1
      if($dt.Year -ge $minY -and $dt.Year -le $maxY){
        return $dt
      }
    } catch {}
  }

  return $null
}

function YearFromFilename([string]$name){
  $dt = TryDateFromFilename $name
  if($dt){ return $dt.Year.ToString() }
  return $null
}



function TryMediaPropertyDate([string]$path){
  # Windows-only: use Shell property system (often works for PNG/MP4 where EXIF isn't available via WPF/System.Drawing)
  try{
    $shell = New-Object -ComObject Shell.Application
    $dir   = Split-Path -Parent $path
    $leaf  = Split-Path -Leaf   $path
    $ns    = $shell.NameSpace($dir)
    if($null -eq $ns){ return $null }
    $item  = $ns.ParseName($leaf)
    if($null -eq $item){ return $null }

    # Try multiple indices that commonly map to "Media created"/"Date taken" depending on file type & Windows build.
    # 12, 208, 4 are common on many systems, but not guaranteed.
    $candidates = @()
    foreach($idx in @(12,208,4,3,189)){
      try{
        $v = $ns.GetDetailsOf($item, $idx)
        if(-not [string]::IsNullOrWhiteSpace($v)){ $candidates += $v }
      } catch {}
    }

    foreach($v in $candidates){
      try{
        $dt = [DateTime]::Parse($v)
        if($dt.Year -ge 1990 -and $dt.Year -le ([DateTime]::Now.Year + 1)){
          return $dt
        }
      } catch {}
    }
  } catch {}
  return $null
}


function YearDecisionNoHash($fi){
  $fsYear = $fi.LastWriteTime.Year.ToString()

  # 1) Takeout JSON
  $jy = TryGetGoogleJsonYears $fi.FullName
  if($jy.TakenYear){
    return @{ Status="Confirmed"; Year=$jy.TakenYear; Source="JSON_taken"; FsYear=$fsYear }
  }
  # NOTE: creationTime is often "library/upload/processing time" and can be misleading (e.g., 2026 contamination).
  # We treat it as low-trust and do NOT confirm year from it unless no stronger evidence exists.
  $weakJsonYear = $null
  if($jy.CreationYear){
    $weakJsonYear = $jy.CreationYear
  }

  # 2) Embedded EXIF for JPG/JPEG
  $dt = $null
  if($UseWpfCom){ $dt = TryExifDateWpf $fi.FullName }
  if($dt){ return @{ Status="Confirmed"; Year=$dt.Year.ToString(); Source="EXIF_WPF"; FsYear=$fsYear } }

  $dt2 = TryExifDate $fi.FullName
  if($dt2){ return @{ Status="Confirmed"; Year=$dt2.Year.ToString(); Source="EXIF_SD"; FsYear=$fsYear } }

  # 3) Windows media properties (PNG/MP4/etc) - OPTIONAL (COM). Treat suspect year as Uncertain.
  $dt3 = $null
  if($UseWpfCom){ $dt3 = TryMediaPropertyDate $fi.FullName }
  if($dt3){
    $y3 = $dt3.Year.ToString()
    if([int]$y3 -eq $script:SuspectYear){
      return @{ Status="Uncertain"; Year=$y3; Source="ShellPropSuspect"; FsYear=$fsYear }
    }
    return @{ Status="Confirmed"; Year=$y3; Source="ShellProp"; FsYear=$fsYear }
  }

  # 4) Filename-derived date
  $yf = YearFromFilename $fi.Name
  if($yf){ return @{ Status="Confirmed"; Year=$yf; Source="Filename"; FsYear=$fsYear } }

  # 5) If we only have JSON creationTime, quarantine it under JSONC_<year> (do not confirm).
  if($weakJsonYear){
    return @{ Status="Uncertain"; Year=$weakJsonYear; Source="JSON_creation"; FsYear=$fsYear }
  }

  # Still nothing: quarantine by FS year
  return @{ Status="Uncertain"; Year=$fsYear; Source="LastWriteTime"; FsYear=$fsYear }
}

function HealRepresentativeIfNeeded([string]$hash,[string]$destRoot,[hashtable]$hashRep,[string]$badLog,[string]$preferredYear=$null){
  if(-not $hashRep.ContainsKey($hash)){ return $null }
  $repRel = $hashRep[$hash]
  if([string]::IsNullOrWhiteSpace($repRel)){ return $null }

  # Only consider reps stored under a year folder (e.g., '2026\...')
  if($repRel -notmatch '^(19\d{2}|20\d{2})\\'){ return $null }
  $repYear = [int]$Matches[1]

  # v3.3.5: heal representatives not only for "future" years, but also when we have
  # a strong preferred year (from JSON/EXIF/ShellProp/Filename) that contradicts the rep folder.
  $nowY = (Get-Date).Year
  $suspicious = ($repYear -ge ($nowY + 1))
  $prefer = $null
  if($preferredYear -and $preferredYear -match '^\d{4}$'){ $prefer = [int]$preferredYear }
  if(-not $suspicious -and $null -eq $prefer){ return $null }

  $repAbs = Join-Path $destRoot $repRel
  if(-not (Test-Path -LiteralPath $repAbs)){ return $null }

  try{
    $repFi = Get-Item -LiteralPath $repAbs -ErrorAction Stop
    $repDec = YearDecisionNoHash $repFi
    if($repDec.Status -ne "Confirmed"){ return $null }

    $trueYear = [int]$repDec.Year
    # If we were called with a preferred year, only heal when the representative's own
    # strong evidence agrees with that preferred year.
    if($null -ne $prefer){
      if($trueYear -ne $prefer){ return $null }
    }
    if($trueYear -eq $repYear){ return $null }

    # Move representative to the corrected year folder and update mapping
    $targetDir = Join-Path $destRoot $repDec.Year
    EnsureDir $targetDir

    $base = [IO.Path]::GetFileName($repAbs)
    $dst  = Join-Path $targetDir $base

    if(Test-Path -LiteralPath $dst){
      $name = [IO.Path]::GetFileNameWithoutExtension($base)
      $ext  = [IO.Path]::GetExtension($base)
      $k=1
      do{
        $dst = Join-Path $targetDir ("{0}__{1}{2}" -f $name,$k,$ext)
        $k++
      } while(Test-Path -LiteralPath $dst)
    }

    $ok = MoveWithRetry $repAbs $dst
    if(-not $ok){
      if($VerboseLog){ Log ("WARN: HealRepresentative move failed; skipping heal: {0}" -f $repAbs) }
      AppendTextWithRetry $badLog ("REP_HEAL_MOVE_FAIL`t{0}`t{1}" -f $repAbs,$dst) | Out-Null
      return $null
    }

    # Move sidecars along
    MoveSidecars $repAbs $dst $badLog

    $newRel = $dst.Substring($destRoot.Length).TrimStart('\','/')
    $hashRep[$hash] = $newRel

    # Append updated mapping so last-wins on next load
    $HashBuffer.Add(("{0}`t{1}" -f $hash,$newRel)) | Out-Null

    if($VerboseLog){
      Log ("Healed representative year: {0} -> {1} ({2})" -f $repYear,$trueYear,$repDec.Source)
    }
    return $trueYear.ToString()
  } catch {
    AppendTextWithRetry $badLog ("REP_HEAL_EXCEPTION`t{0}`t{1}" -f $hash, $_.Exception.Message) | Out-Null
    return $null
  }
}

function YearDecisionForFile($fi,[string]$hash,[hashtable]$hashRep,[string]$destRoot,[string]$badLog){
  $fsYear = $fi.LastWriteTime.Year.ToString()

  # v3.3.5 IMPORTANT CHANGE:
  # Determine the year from strong evidence FIRST (JSON/EXIF/ShellProp/Filename).
  # HashRep is used only as a fallback when strong evidence is missing.
  $strong = YearDecisionNoHash $fi
  if($strong.Status -eq "Confirmed"){
    # If we already had a representative under a different year, try to heal it when
    # the representative's own strong evidence agrees with this strong year.
    $healedYear = HealRepresentativeIfNeeded $hash $destRoot $hashRep $badLog $strong.Year
    if($healedYear){
      return @{ Status="Confirmed"; Year=$strong.Year; Source=($strong.Source + "+HealedRep"); FsYear=$fsYear }
    }
    return $strong
  }

  # No strong evidence: inherit year from representative if available
  if($hashRep -and $hashRep.ContainsKey($hash)){
    $repRel = $hashRep[$hash]
    if(-not [string]::IsNullOrWhiteSpace($repRel)){
      if($repRel -match '^(19\d{2}|20\d{2})\\'){
        if([int]$Matches[1] -eq $script:SuspectYear){
          return @{ Status="Uncertain"; Year=$Matches[1]; Source="HashRepSuspect"; FsYear=$fsYear }
        }
        return @{ Status="Confirmed"; Year=$Matches[1]; Source="HashRep"; FsYear=$fsYear }
      }
      if($repRel -match '^_Uncertain\\FS_(\d{4})\\'){
        return @{ Status="Uncertain"; Year=$Matches[1]; Source="HashRepUncertain"; FsYear=$fsYear }
      }
    }
  }

  # Still nothing: quarantine (do NOT confirm year from filesystem timestamps)
  return $strong
}


function MoveWithRetry([string]$src,[string]$dst,[int]$maxTry=6){
  for($i=1; $i -le $maxTry; $i++){
    try{
      Move-Item -LiteralPath $src -Destination $dst -ErrorAction Stop
      return $true
    } catch {
      Start-Sleep -Milliseconds (200 * $i)
    }
  }
  return $false
}

function CopyWithRetry([string]$src,[string]$dst,[int]$maxTry=6){
  for($i=1; $i -le $maxTry; $i++){
    try{
      Copy-Item -LiteralPath $src -Destination $dst -ErrorAction Stop
      return $true
    } catch {
      Start-Sleep -Milliseconds (200 * $i)
    }
  }
  return $false
}


function MoveSidecars([string]$srcMedia,[string]$dstMedia,[string]$badLog){
  try{
    $srcDir  = Split-Path -Parent $srcMedia
    $dstDir  = Split-Path -Parent $dstMedia

    $srcLeaf = Split-Path -Leaf $srcMedia
    $dstLeaf = Split-Path -Leaf $dstMedia

    $srcNoExt = [IO.Path]::GetFileNameWithoutExtension($srcLeaf)
    $dstNoExt = [IO.Path]::GetFileNameWithoutExtension($dstLeaf)

    function Combine([string]$a,[string]$b){ return [IO.Path]::Combine($a,$b) }

    $candidates = @(
      ($srcLeaf + ".json"),
      ($srcLeaf + ".supplemental-metadata.json"),
      ($srcNoExt + ".json"),
      ($srcNoExt + ".supplemental-metadata.json")
    ) | Select-Object -Unique

    foreach($c in $candidates){
      $srcJson = Combine $srcDir $c
      if(-not (Test-Path -LiteralPath $srcJson)){ continue }

      # Rewrite destination sidecar name to follow the final destination media name
      $dstName = $c
      $dstName = $dstName -replace [regex]::Escape($srcLeaf),  $dstLeaf
      $dstName = $dstName -replace [regex]::Escape($srcNoExt), $dstNoExt
      $dstJson = Combine $dstDir $dstName

      # Avoid collisions on destination JSON
      if(Test-Path -LiteralPath $dstJson){
        $n = [IO.Path]::GetFileNameWithoutExtension($dstName)
        $e = [IO.Path]::GetExtension($dstName)  # usually .json
        $k = 1
        do{
          $dstJson = Combine $dstDir ("{0}__{1}{2}" -f $n,$k,$e)
          $k++
        } while(Test-Path -LiteralPath $dstJson)
      }

      $ok = MoveWithRetry $srcJson $dstJson
      if(-not $ok){
        $ok2 = CopyWithRetry $srcJson $dstJson
        if(-not $ok2){
          AppendTextWithRetry $badLog ("SIDECAR_MOVE_COPY_FAIL`t{0}`t{1}" -f $srcJson,$dstJson) | Out-Null
          continue
        }
        Remove-Item -LiteralPath $srcJson -Force -ErrorAction SilentlyContinue
      }
    }
  } catch {
    AppendTextWithRetry $badLog ("SIDECAR_EXCEPTION`t{0}`t{1}" -f $srcMedia, $_.Exception.Message) | Out-Null
  }
}



function GetSidecarPath([string]$mediaPath){
  $dir = Split-Path -Parent $mediaPath
  $leaf = Split-Path -Leaf $mediaPath
  $base = [IO.Path]::GetFileNameWithoutExtension($leaf)

  $cands = @(
    (Join-Path $dir ($leaf + ".supplemental-metadata.json")),
    (Join-Path $dir ($leaf + ".json")),
    (Join-Path $dir ($base + ".supplemental-metadata.json")),
    (Join-Path $dir ($base + ".json"))
  ) | Select-Object -Unique

  foreach($p in $cands){
    if(Test-Path -LiteralPath $p){ return $p }
  }
    $byTitle = GetSidecarPathByTitle $mediaPath
  if($byTitle){ return $byTitle }
  return $null
}


# --- Sidecar repair helpers (title-based) ---
# Cache: per-directory JSON title -> json path
$script:DirJsonTitleCache = @{}

function NormalizeTitleKey([string]$s){
  if([string]::IsNullOrWhiteSpace($s)){ return $null }
  $n = $s.Normalize([Text.NormalizationForm]::FormC)
  # Strip common duplicate suffix like __1 before extension
  $n = $n -replace '__\d+(?=\.)',''
  return $n.ToLowerInvariant()
}

function BuildDirJsonTitleMap([string]$dir){
  if($script:DirJsonTitleCache.ContainsKey($dir)){ return $script:DirJsonTitleCache[$dir] }
  $map = @{}
  # Prefer supplemental metadata JSONs; fall back to any json if needed
  $jsons = @(Get-ChildItem -LiteralPath $dir -File -Filter *.supplemental-metadata.json -ErrorAction SilentlyContinue)
  if($jsons.Count -eq 0){
    $jsons = @(Get-ChildItem -LiteralPath $dir -File -Filter *.json -ErrorAction SilentlyContinue)
  }
  foreach($jf in $jsons){
    try{
      $j = Read-TakeoutJsonRobust -Path $jf.FullName
    } catch { continue }
    if($null -eq $j){ continue }
    if($j.PSObject.Properties.Name -contains "title"){
      $t = $j.title
      $k = NormalizeTitleKey ($t.ToString())
      if($null -ne $k -and -not $map.ContainsKey($k)){
        $map[$k] = $jf.FullName
      }
    }
  }
  $script:DirJsonTitleCache[$dir] = $map
  return $map
}

function GetSidecarPathByTitle([string]$mediaPath){
  $dir  = Split-Path -Parent $mediaPath
  $leaf = Split-Path -Leaf $mediaPath
  $want = NormalizeTitleKey $leaf
  if($null -eq $want){ return $null }
  $map = BuildDirJsonTitleMap $dir
  if($map.ContainsKey($want)){ return $map[$want] }
  return $null
}

function HasSidecar([string]$mediaPath){
  $dir = Split-Path -Parent $mediaPath
  $leaf = Split-Path -Leaf $mediaPath
  $base = [IO.Path]::GetFileNameWithoutExtension($leaf)
  $p1 = Join-Path $dir ($leaf + ".supplemental-metadata.json")
  $p2 = Join-Path $dir ($leaf + ".json")
  $p3 = Join-Path $dir ($base + ".supplemental-metadata.json")
  $p4 = Join-Path $dir ($base + ".json")
  return ((Test-Path -LiteralPath $p1) -or (Test-Path -LiteralPath $p2) -or (Test-Path -LiteralPath $p3) -or (Test-Path -LiteralPath $p4))
}

function RepairMissingSidecarsInDir([string]$dir,[string]$badLog){
  $fixed = 0
  # For each media without an adjacent sidecar, find a json in the same directory whose internal title matches,
  # then copy it as <mediaName>.supplemental-metadata.json (preferred) or <mediaName>.json.
  $mediaExt = @(".jpg",".jpeg",".png",".gif",".webp",".heic",".tif",".tiff",".mp4",".mov",".m4v",".avi",".3gp",".mkv")
  $media = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue | Where-Object { $mediaExt -contains $_.Extension.ToLowerInvariant() })
  if($media.Count -eq 0){ return 0 }
  $map = BuildDirJsonTitleMap $dir
  foreach($m in $media){
    $mp = $m.FullName
    if(HasSidecar $mp){ continue }
    $k = NormalizeTitleKey $m.Name
    if($null -eq $k){ continue }
    if(-not $map.ContainsKey($k)){ continue }
    $srcJson = $map[$k]

    $dstJson = Join-Path $dir ($m.Name + ".supplemental-metadata.json")
    if(-not (Test-Path -LiteralPath $dstJson)){
      # If the source is not supplemental, keep extension as .json
      if($srcJson.ToLowerInvariant().EndsWith(".supplemental-metadata.json")){
        $ok = CopyWithRetry $srcJson $dstJson
      if($ok){ $fixed++ }
      } else {
        $dstJson2 = Join-Path $dir ($m.Name + ".json")
        $ok = CopyWithRetry $srcJson $dstJson2
        if($ok){ $fixed++ }
      }
      if(-not $ok){
        AppendTextWithRetry $badLog ("SIDECAR_REPAIR_COPY_FAIL`t{0}`t{1}" -f $srcJson,$dstJson) | Out-Null
      }
    }
  }
  if($fixed -gt 0){ $script:Stats.SidecarRepaired = [int]$script:Stats.SidecarRepaired + $fixed }
  return $fixed
}

function GetJsonScore([string]$jsonPath){
  if([string]::IsNullOrWhiteSpace($jsonPath)){ return -1 }
  try{
    $j = Read-TakeoutJsonRobust -Path $jsonPath
  } catch {
    return -1
  }

  $score = 0

  if($j.PSObject.Properties.Name -contains "photoTakenTime"){
    $pt = $j.photoTakenTime
    if($null -ne $pt -and $pt.PSObject.Properties.Name -contains "timestamp"){
      $t = $pt.timestamp
      if($null -ne $t -and $t.ToString().Trim().Length -gt 0){ $score += 100 }
    }
  }
  if($score -lt 100 -and ($j.PSObject.Properties.Name -contains "creationTime")){
    $ct = $j.creationTime
    if($null -ne $ct -and $ct.PSObject.Properties.Name -contains "timestamp"){
      $t = $ct.timestamp
      if($null -ne $t -and $t.ToString().Trim().Length -gt 0){ $score += 60 }
    }
  }

  foreach($nodeName in @("geoDataExif","geoData")){
    if($j.PSObject.Properties.Name -contains $nodeName){
      $g = $j.$nodeName
      if($null -ne $g){
        $lat = $null; $lng = $null
        if($g.PSObject.Properties.Name -contains "latitude"){  $lat = [double]$g.latitude }
        if($g.PSObject.Properties.Name -contains "longitude"){ $lng = [double]$g.longitude }
        if($null -ne $lat -and $null -ne $lng -and -not (($lat -eq 0) -and ($lng -eq 0))){
          $score += 30
          break
        }
      }
    }
  }

  if($j.PSObject.Properties.Name -contains "description"){
    if(-not [string]::IsNullOrWhiteSpace($j.description)){ $score += 10 }
  }
  if($j.PSObject.Properties.Name -contains "favorite"){
    try{ if([bool]$j.favorite){ $score += 5 } } catch {}
  }
  if($j.PSObject.Properties.Name -contains "people"){
    try{
      $p = $j.people
      if($null -ne $p){
        if($p -is [System.Array]){
          if($p.Count -gt 0){ $score += 5 }
        } else {
          $score += 5
        }
      }
    } catch {}
  }

  return $score
}

function GetRepSidecarPath([string]$repMediaPath,[bool]$preferSupplemental){
  $dir = Split-Path -Parent $repMediaPath
  $leaf = Split-Path -Leaf $repMediaPath
  if($preferSupplemental){
    return (Join-Path $dir ($leaf + ".supplemental-metadata.json"))
  } else {
    return (Join-Path $dir ($leaf + ".json"))
  }
}

function EnsureBestSidecarForRepresentative([string]$repMediaPath,[string]$candidateJsonPath,[int]$candidateScore,[int]$currentBestScore,[string]$badLog){
  if([string]::IsNullOrWhiteSpace($repMediaPath) -or -not (Test-Path -LiteralPath $repMediaPath)){ return $currentBestScore }
  if([string]::IsNullOrWhiteSpace($candidateJsonPath) -or -not (Test-Path -LiteralPath $candidateJsonPath)){ return $currentBestScore }
  if($candidateScore -lt 0){ return $currentBestScore }

  $repSupp = GetRepSidecarPath $repMediaPath $true
  $repJson = GetRepSidecarPath $repMediaPath $false
  $repHas  = (Test-Path -LiteralPath $repSupp) -or (Test-Path -LiteralPath $repJson)

  if((-not $repHas) -or ($candidateScore -gt $currentBestScore)){
    $preferSupp = ($candidateJsonPath.ToLower().EndsWith(".supplemental-metadata.json"))
    $dst = GetRepSidecarPath $repMediaPath $preferSupp

    try{
      EnsureDir (Split-Path -Parent $dst)
      CopyWithRetry $candidateJsonPath $dst | Out-Null
      $script:Stats.SidecarUpdated = [int]$script:Stats.SidecarUpdated + 1
      if($VerboseLog){
        Log ("Sidecar updated for representative: {0}" -f $repMediaPath)
      }
      return $candidateScore
    } catch {
      AppendTextWithRetry $badLog ("SIDECAR_COPY_FAIL`t{0}`t{1}" -f $candidateJsonPath, $_.Exception.Message) | Out-Null
      return $currentBestScore
    }
  }

  return $currentBestScore
}

function PlaceUnique([string]$src,[string]$destRoot,[hashtable]$hashSet,[hashtable]$hashRep,[hashtable]$hashScore,[string]$hashDb,[string]$badLog){

  # hash with robust skip
  $h = $null
  try{
    $h = (Get-FileHash -Algorithm SHA256 -Path $src -ErrorAction Stop).Hash
  } catch {
    Log ("WARN: Get-FileHash failed. Skipping: {0}" -f $src)
    AppendTextWithRetry $badLog ("HASH_FAIL`t{0}`t{1}" -f $src, $_.Exception.Message) | Out-Null
    return
  }

  if([string]::IsNullOrWhiteSpace($h)){
    Log ("WARN: Null/empty hash. Skipping: {0}" -f $src)
    AppendTextWithRetry $badLog ("HASH_NULL`t{0}" -f $src) | Out-Null
    return
  }

  $srcSidecar = GetSidecarPath $src
  $srcSidecarScore = if($srcSidecar){ GetJsonScore $srcSidecar } else { -1 }

  if($hashSet.ContainsKey($h)){
    $script:Stats.Duplicates = [int]$script:Stats.Duplicates + 1
    # Duplicate media: keep the representative, but ensure it has the best available single sidecar JSON.
    if($srcSidecar -and $srcSidecarScore -ge 0){
      $repRel = $null
      if($hashRep.ContainsKey($h)){ $repRel = $hashRep[$h] }
      if(-not [string]::IsNullOrWhiteSpace($repRel)){
        $repPath = Join-Path $destRoot $repRel
        $best = -1
        if($hashScore.ContainsKey($h)){ $best = [int]$hashScore[$h] }
        $newBest = EnsureBestSidecarForRepresentative $repPath $srcSidecar $srcSidecarScore $best $badLog
        if($newBest -gt $best){ $hashScore[$h] = $newBest }
      }
    }
    if($VerboseLog){ Log ("Duplicate skipped: {0}" -f $src) }
    return
  }

  $fi = Get-Item -LiteralPath $src
  $dec = YearDecisionForFile $fi $h $hashRep $destRoot $badLog

  if($dec.Status -eq "Confirmed"){
    $yearDir = Join-Path $destRoot $dec.Year
  } else {
    # Quarantine. Group by evidence source when available (e.g., JSON_creation_YYYY), otherwise fall back to FS_YYYY.
    $qLeaf = $null
    if(($dec.Year -and [int]$dec.Year -eq $script:SuspectYear) -or ([int]$dec.FsYear -eq $script:SuspectYear)){
      $qLeaf = $script:SuspectLeaf
    }
    elseif($dec.Source -eq "JSON_creation" -and $dec.Year){ $qLeaf = ("JSONC_{0}" -f $dec.Year) }
    elseif($dec.Source -eq "HashRepUncertain" -and $dec.Year){ $qLeaf = ("HASH_{0}" -f $dec.Year) }
    elseif($dec.Source -eq "ShellPropSuspect" -and $dec.Year){ $qLeaf = $script:SuspectLeaf }
    elseif($dec.Source -eq "HashRepSuspect"){ $qLeaf = $script:SuspectLeaf }
    else { $qLeaf = ("FS_{0}" -f $dec.FsYear) }
    $yearDir = Join-Path $destRoot (Join-Path "_Uncertain" $qLeaf)
  }
  EnsureDir $yearDir

  $null = $script:TouchedDestDirs.Add($yearDir)
  $base = [IO.Path]::GetFileName($src)
  $dst  = Join-Path $yearDir $base

  # collision-safe name
  if(Test-Path $dst){
    $name = [IO.Path]::GetFileNameWithoutExtension($base)
    $ext  = [IO.Path]::GetExtension($base)
    $k=1
    do{
      $dst = Join-Path $yearDir ("{0}__{1}{2}" -f $name,$k,$ext)
      $k++
    } while(Test-Path $dst)
  }

  $ok = MoveWithRetry $src $dst
  if(-not $ok){
    if($VerboseLog){ Log ("Move failed; trying copy+delete: {0}" -f $src) }
    $ok2 = CopyWithRetry $src $dst
    if(-not $ok2){
      Log ("WARN: Move/Copy failed. Skipping: {0}" -f $src)
      AppendTextWithRetry $badLog ("MOVE_COPY_FAIL`t{0}" -f $src) | Out-Null
      return
    }
    Remove-Item -LiteralPath $src -Force -ErrorAction SilentlyContinue
  }
  # Move sidecar JSON next to the final media file
  MoveSidecars $src $dst $badLog

  $script:Stats.Moved = [int]$script:Stats.Moved + 1

  $hashSet[$h]=1

  # Record representative path and best sidecar score for this hash
  $rel = $dst.Substring($destRoot.Length).TrimStart('\','/')
  $hashRep[$h] = $rel
  $hashScore[$h] = $srcSidecarScore

  # Persist as TSV (hash<TAB>rel_path). Legacy readers still work on hash-only.
  $HashBuffer.Add(("{0}`t{1}" -f $h,$rel)) | Out-Null
}

function FlushHashBuffer([string]$hashDb){
  if($HashBuffer.Count -le 0){ return }
  $text = ($HashBuffer -join "`n")
  if(AppendTextWithRetry $hashDb $text){
    $HashBuffer.Clear()
  } else {
    Log "WARN: Failed to flush hash buffer after retries."
  }
}

function AdjustBatchIfLowSpace([string]$anyPath,[int]$minGB,[int]$curBatch){
  $free = FreeGB $anyPath
  if($free -ge $minGB){ return $curBatch }

  $try=@()
  if($curBatch -gt 6){ $try += 6 }
  if($curBatch -gt 4){ $try += 4 }

  foreach($b in $try){
    Log ("Low disk space: {0}GB < {1}GB. Trying BatchSize={2}." -f $free,$minGB,$b)
    $free2 = FreeGB $anyPath
    if($free2 -ge $minGB){ return $b }
  }
  throw ("Not enough free space: {0}GB (need >= {1}GB). Stop." -f $free,$minGB)
}

# ---------- init ----------
$ZipDir   = (Resolve-Path $ZipDir).Path
EnsureDir $DestRoot
EnsureDir (Join-Path $DestRoot "_Uncertain")

$ProcessedDir = Join-Path $ZipDir "_processed"
EnsureDir $ProcessedDir

$WorkRoot = Join-Path $ZipDir "_work"
EnsureDir $WorkRoot

$HashDb  = Join-Path $DestRoot "_hashes_sha256.txt"
$BadLog  = Join-Path $DestRoot "_bad_files.txt"
if(-not (Test-Path $HashDb)){ New-Item -ItemType File -Path $HashDb | Out-Null }
if(-not (Test-Path $BadLog)){ New-Item -ItemType File -Path $BadLog | Out-Null }

# load existing hashes (supports legacy 'hash' and newer 'hash<TAB>rel_path')
Log "Loading hash DB..."
$HashSet=@{}
$HashRep=@{}      # hash -> representative relative path (e.g., '2019\IMG_0001.JPG')
$HashScore=@{}    # hash -> best sidecar score observed
Get-Content -LiteralPath $HashDb -ErrorAction SilentlyContinue | ForEach-Object {
  $line = $_.Trim()
  if($line.Length -le 0){ return }
  $parts = $line -split "`t", 2
  $h = $parts[0].Trim()
  if($h.Length -le 0){ return }
  $HashSet[$h]=1
  if($parts.Count -ge 2){
    $rp = $parts[1].Trim()
    if($rp.Length -gt 0){ $HashRep[$h]=$rp }
  }
}
Log ("Loaded hashes: {0}" -f $HashSet.Count)

$SevenZip = Get7z
if($SevenZip){ Log ("Using 7-Zip: {0}" -f $SevenZip) }
else { Log "7-Zip not found. Using Expand-Archive (slow)." }
# --------- inputs: ZIPs + optional loose media in ZipDir ----------
$zipInputs = @(Get-ChildItem -LiteralPath $ZipDir -File -Filter *.zip | Sort-Object Name)

# Loose media (e.g., an unzipped MP4 dropped in ZipDir). JSON sidecars are handled automatically.
$looseInputs = @(Get-ChildItem -LiteralPath $ZipDir -File -ErrorAction SilentlyContinue | Where-Object {
  ($MediaExt -contains $_.Extension.ToLowerInvariant()) -and ($_.Extension.ToLowerInvariant() -ne ".zip")
})

$inputs = New-Object System.Collections.Generic.List[object]
foreach($z in $zipInputs){ $inputs.Add([pscustomobject]@{ Type="zip";   File=$z }) | Out-Null }
foreach($f in $looseInputs){ $inputs.Add([pscustomobject]@{ Type="loose"; File=$f }) | Out-Null }

# Sort all inputs by filename for stable processing order
$inputs = @($inputs | Sort-Object { $_.File.Name })

if($inputs.Count -eq 0){ throw "No ZIP files or loose media files found in ZipDir." }

$ProcessedLooseDir = Join-Path $ZipDir "_processed_loose"
EnsureDir $ProcessedLooseDir

Log ("Inputs found: ZIP={0}, loose_media={1}, total={2}" -f $zipInputs.Count,$looseInputs.Count,$inputs.Count)

# ---------- batch loop ----------
$idx = 0
$curBatch = $BatchSize

while($idx -lt $inputs.Count){

  $curBatch = AdjustBatchIfLowSpace $ZipDir $MinFreeGB $curBatch
  $batch = @($inputs | Select-Object -Skip $idx -First $curBatch)
  if($batch.Count -le 0){
    Log "No inputs selected for this batch. Stopping."
    break
  }
  $batchId = ("{0:0000}_{1}" -f ($idx+1),(Get-Date -Format "yyyyMMdd_HHmmss"))
  $work = Join-Path $WorkRoot $batchId
  EnsureDir $work

  Log ("Batch start: {0} (inputs={1}, MinFreeGB={2})" -f $batchId,$batch.Count,$MinFreeGB)
  $script:TouchedDestDirs.Clear()
  $script:Stats.Moved=0; $script:Stats.Duplicates=0; $script:Stats.SidecarUpdated=0; $script:Stats.SidecarRepaired=0

  $looseRoot = Join-Path $work "_loose"
  EnsureDir $looseRoot

  foreach($it in $batch){
    if($it.Type -eq "zip"){
      $zip = $it.File
      $sub = Join-Path $work ([IO.Path]::GetFileNameWithoutExtension($zip.Name))
      EnsureDir $sub
      Log ("Extract: {0}" -f $zip.Name)

      if($SevenZip){
        & $SevenZip x "`"$($zip.FullName)`"" "-o`"$sub`"" -y | Out-Null
      } else {
        Expand-Archive -LiteralPath $zip.FullName -DestinationPath $sub -Force
      }
    } else {
      $f = $it.File
      # Put each loose media in its own folder under _loose to keep scanning bounded
      $sub = Join-Path $looseRoot ([IO.Path]::GetFileNameWithoutExtension($f.Name))
      EnsureDir $sub
      Log ("Stage loose media: {0}" -f $f.Name)

      Copy-Item -LiteralPath $f.FullName -Destination (Join-Path $sub $f.Name) -Force

      # Copy common sidecar names if present (Takeout style)
      $side1 = Join-Path $ZipDir ($f.Name + ".json")
      if(Test-Path $side1){
        Copy-Item -LiteralPath $side1 -Destination (Join-Path $sub ([IO.Path]::GetFileName($side1))) -Force
      }
      $side2 = Join-Path $ZipDir ($f.Name + ".supplemental-metadata.json")
      if(Test-Path $side2){
        Copy-Item -LiteralPath $side2 -Destination (Join-Path $sub ([IO.Path]::GetFileName($side2))) -Force
      }
    }
  }

  # scan media only under this batch work folder
  Log "Scanning media files..."
  $files = Get-ChildItem -LiteralPath $work -Recurse -File | Where-Object { $MediaExt -contains $_.Extension.ToLower() }
  Log ("Media files found: {0}" -f $files.Count)

  foreach($f in $files){
    PlaceUnique $f.FullName $DestRoot $HashSet $HashRep $HashScore $HashDb $BadLog
  }

  FlushHashBuffer $HashDb

  Log ("Batch done. Total hashes now: {0}" -f $HashSet.Count)
  Log ("Stats: moved={0}, duplicates={1}, sidecar_updated={2}, sidecar_repaired={3}" -f $script:Stats.Moved,$script:Stats.Duplicates,$script:Stats.SidecarUpdated,$script:Stats.SidecarRepaired)
  if($ReportSidecars){
    $missing=0; $total=0
    foreach($d in $script:TouchedDestDirs){
      $media = @(Get-ChildItem -LiteralPath $d -File -ErrorAction SilentlyContinue | Where-Object { $MediaExt -contains $_.Extension.ToLowerInvariant() })
      foreach($m in $media){
        $total++
        if(-not (HasSidecar $m.FullName)){ $missing++ }
      }
    }
    Log ("Sidecar status (touched dirs): media={0}, missing_sidecar={1}" -f $total,$missing)
  }

  # move/delete processed inputs
  foreach($it in $batch){
    if($it.Type -eq "zip"){
      $zip = $it.File
      if($DeleteZips){
        Log ("Delete ZIP: {0}" -f $zip.Name)
        Remove-Item -LiteralPath $zip.FullName -Force -ErrorAction SilentlyContinue
      } else {
        Log ("Move ZIP to _processed: {0}" -f $zip.Name)
        Move-Item -LiteralPath $zip.FullName -Destination (Join-Path $ProcessedDir $zip.Name) -Force
      }
    } else {
      $f = $it.File
      Log ("Move loose media to _processed_loose: {0}" -f $f.Name)
      Move-Item -LiteralPath $f.FullName -Destination (Join-Path $ProcessedLooseDir $f.Name) -Force

      $side1 = Join-Path $ZipDir ($f.Name + ".json")
      if(Test-Path $side1){
        Move-Item -LiteralPath $side1 -Destination (Join-Path $ProcessedLooseDir ([IO.Path]::GetFileName($side1))) -Force
      }
      $side2 = Join-Path $ZipDir ($f.Name + ".supplemental-metadata.json")
      if(Test-Path $side2){
        Move-Item -LiteralPath $side2 -Destination (Join-Path $ProcessedLooseDir ([IO.Path]::GetFileName($side2))) -Force
      }
    }
  }

  if(-not $KeepWork){

  # Sidecar repair pass for touched destination directories (fixes name mismatches)
  if(-not $NoSidecarRepair){
    $repairedTotal = 0
    try{
      foreach($d in $script:TouchedDestDirs){
        $repairedTotal += (RepairMissingSidecarsInDir $d $badLog)
      }
    } catch {
      AppendTextWithRetry $badLog ("SIDECAR_REPAIR_EXCEPTION`t{0}" -f $_.Exception.Message) | Out-Null
    }
    if($VerboseLog -or $repairedTotal -gt 0){ Log ("Sidecar repaired this batch: {0}" -f $repairedTotal) }
  }
    Log ("Remove temp dir: {0}" -f $work)
    Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
  } else {
    Log ("Keep temp dir: {0}" -f $work)
  }
  $idx += $batch.Count
  Log ("Free space now: {0} GB" -f (FreeGB $ZipDir))
  Log "----------------------------------------"
}
Log "All done."
Log ("Output root (LOCAL): {0}" -f $DestRoot)
Log ("Hash DB: {0}" -f $HashDb)
Log ("Bad file log: {0}" -f $BadLog)
if(-not $DeleteZips){ Log ("Processed ZIPs: {0}" -f $ProcessedDir) }
