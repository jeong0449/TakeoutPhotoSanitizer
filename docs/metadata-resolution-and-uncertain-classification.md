# Metadata Resolution and \_Uncertain Classification Strategy

This document explains how TakeoutPhotoSanitizer resolves multiple JSON
sidecars, determines media year classification, and handles files that
fall into the `_Uncertain` category --- including the special
`_Uncertain/<year>_suspects` folder.

------------------------------------------------------------------------

## 1. How Metadata Is Recovered When Multiple JSON Files Exist

Google Takeout often produces inconsistent sidecar metadata:

-   A single media file may have multiple JSON files
-   JSON filenames may not exactly match the media filename
-   `.supplemental-metadata.json` and plain `.json` may coexist
-   Duplicate media (same SHA-256) may appear across different albums
    with different metadata

TakeoutPhotoSanitizer uses a practical recovery strategy instead of
attempting full JSON merging.

### 1.1 JSON Discovery Order

For each media file, the script searches for candidate JSON sidecars in
the following priority:

1.  `<media>.supplemental-metadata.json`
2.  `<media>.json`
3.  `<mediaBaseName>.supplemental-metadata.json`
4.  `<mediaBaseName>.json`
5.  Title-based matching fallback

If direct filename matching fails, the script scans JSON files in the
same directory and compares the `title` field to the normalized media
filename.

Normalization includes:

-   Unicode normalization (Form C)
-   Removal of duplicate suffixes like `__1`, `__2`
-   Case-insensitive comparison

If a match is found, the JSON is copied and aligned to the media file.

------------------------------------------------------------------------

### 1.2 Folder-Level JSON Caching

For year classification, the script scans JSON files once per folder and
builds two maps:

-   `photoTakenTime.timestamp` → preferred year source
-   `creationTime.timestamp` → fallback year source

Keys are normalized to handle:

-   `.supplemental-metadata` suffixes
-   Extension vs non-extension base names

If multiple JSON files map to the same key, the last processed entry
overwrites earlier ones. Duplicate handling (below) mitigates metadata
loss.

------------------------------------------------------------------------

### 1.3 Duplicate Media With Different JSON

If the same media appears multiple times:

-   Only one physical copy is retained
-   JSON quality is compared

A metadata score is computed:

-   `photoTakenTime.timestamp` → +100
-   `creationTime.timestamp` → +60
-   Valid GPS (non-zero) → +30
-   Non-empty description → +10
-   Favorite flag → +5
-   People tag present → +5

The highest-scoring JSON is retained next to the representative media
file.

Full JSON merging is intentionally avoided to preserve source integrity.

------------------------------------------------------------------------

## 2. What Media Files Go to `_Uncertain`?

A file is moved to `_Uncertain` when the capture year cannot be
determined reliably.

Year resolution priority:

1.  JSON `photoTakenTime.timestamp`
2.  JSON `creationTime.timestamp`
3.  EXIF DateTimeOriginal (JPEG)
4.  Filename pattern parsing (YYYY-MM-DD)
5.  Unix epoch interpretation

If all methods fail, the file is classified as unresolved.

Typical causes:

-   Missing JSON
-   Corrupted EXIF
-   Invalid timestamps
-   Generated or edited images
-   Metadata stripped by external tools

------------------------------------------------------------------------

## 3. Meaning of `_Uncertain/<year>_suspects`

This folder contains files classified into the current runtime year via
fallback logic, but considered suspicious.

Fallback contamination may result from:

-   File system timestamps (LastWriteTime)
-   Extraction time metadata
-   Misinterpreted epoch values
-   Incorrect JSON precedence

Instead of silently misclassifying into the current year, the script
isolates them in:

`_Uncertain/<currentYear>_suspects/`

This makes potential year pollution visible and reviewable.

------------------------------------------------------------------------

### 3.1 What Happens Next Year?

If the script runs in a new year and similar fallback occurs, the
suspect folder name updates accordingly:

`_Uncertain/2027_suspects/` (example)

This dynamic naming ensures transparency and prevents silent archive
corruption.

------------------------------------------------------------------------

## 4. Design Philosophy

TakeoutPhotoSanitizer follows three principles:

1.  Preserve the best available metadata
2.  Avoid silent misclassification
3.  Make uncertainty explicit

When metadata cannot be trusted, it is surfaced --- not guessed.
