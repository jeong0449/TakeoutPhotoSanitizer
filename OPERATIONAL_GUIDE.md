# TakeoutPhotoSanitizer -- Operational Guide

Last Updated: 2026-02-22

------------------------------------------------------------------------

## Overview

This document describes the recommended operational workflow for safely
processing Google Takeout ZIP archives and synchronizing results to
OneDrive.

The goal is to:

-   Ensure stable batch processing
-   Prevent metadata contamination
-   Avoid SHA256 database corruption
-   Optimize disk usage
-   Maintain archival integrity

------------------------------------------------------------------------

## Recommended Workflow

### Step 1 -- Prepare Directories

Before running the script:

-   Create `ZipDir`
-   Create `DestRoot`
-   Place all Google Takeout ZIP files into `ZipDir`

Example:

    ZipDir   = C:\Takeout_Zip
    DestRoot = C:\Photos_Backup\From_Google_Takeout

------------------------------------------------------------------------

### Step 2 -- Local Batch Processing (No OneDrive Sync)

Run the sanitizer locally:

-   Process ZIP files in batches
-   Allow `_work` folders to auto-delete
-   Allow `_hash_db` to grow normally

⚠ During processing, avoid active OneDrive synchronization to reduce
disk I/O and prevent file locking issues.

------------------------------------------------------------------------

### Step 3 -- Verify Results

After a batch:

-   Check year folders
-   Review `_Uncertain`
-   Confirm expected classification behavior

Do NOT copy `_hash_db` yet.

------------------------------------------------------------------------

### Step 4 -- Incremental OneDrive Sync

Once a logical batch is complete:

1.  Copy only year folders to OneDrive
2.  Copy `_Uncertain` if desired
3.  Do NOT copy `_hash_db` during ongoing processing

Example:

    From_Google_Takeout\2014
    From_Google_Takeout\2015
    ...

Year folders merge naturally in OneDrive.

------------------------------------------------------------------------

### Step 5 -- Final SHA256 Database Sync

After all ZIP files have been processed:

1.  Ensure no script is running
2.  Optionally create a snapshot:

```
    Copy-Item _hash_db\sha256_db.tsv _hash_db\sha256_db.final.tsv

3.  Copy the entire `_hash_db` folder to OneDrive once

This prevents:

-   Partial database sync
-   File locking conflicts
-   Index corruption

------------------------------------------------------------------------

## Why This Matters

The SHA256 database is:

-   A deduplication index
-   A historical state record
-   A structural integrity component

It should be treated as a final-state artifact, not a continuously
synchronized working file.

------------------------------------------------------------------------

## Disk Usage Best Practices

To minimize storage usage:

-   Allow `_work` to auto-delete
-   Move processed ZIP files to external storage OR use `-DeleteZips`
-   Keep only normalized year folders locally

This ensures only one authoritative archive copy exists.

------------------------------------------------------------------------

## Summary

✔ Process locally in batches\
✔ Sync year folders incrementally\
✔ Sync `_hash_db` only once at the end\
✔ Avoid simultaneous processing and cloud sync

This workflow provides stable, contamination-resistant, and reproducible
archival normalization.

------------------------------------------------------------------------
