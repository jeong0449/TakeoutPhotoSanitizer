# Milestone Report: 1107 → 28

## EXIF Recovery and Metadata Normalization Stabilization

Last Updated: 2026-02-22

------------------------------------------------------------------------

## Overview

This document records the technical journey that reduced `_Uncertain`
classified files from **1107 files to 28 files** during the development
of TakeoutPhotoSanitizer.

The reduction was not the result of heuristic loosening, but of
correcting structural metadata interpretation issues.

This milestone represents the transition from unstable classification
behavior to a reliability-driven metadata normalization engine.

------------------------------------------------------------------------

## Initial Problem State

During early batch runs of Google Takeout ZIP archives:

-   `_Uncertain` folder contained **1107 media files**
-   Many JPEG files had valid EXIF metadata
-   However, EXIF extraction failed (`EXIF_READ_FAIL`)
-   Files were incorrectly downgraded to fallback logic
-   Year contamination (especially 2026) occurred
-   Hash representative propagation (HashRep) amplified
    misclassification

This indicated systemic metadata read failure, not missing metadata.

------------------------------------------------------------------------

## Root Causes Identified

### 1. EXIF Extraction Failure

Original implementation used:

    System.Drawing.Image::FromStream()

Observed problems:

-   Inconsistent EXIF access
-   Silent metadata read failures
-   File locking side effects
-   Some JPEGs returning no PropertyItems

Result: Valid EXIF files were treated as having no metadata.

------------------------------------------------------------------------

### 2. Incorrect Date Parsing Logic

Earlier parsing used unsafe string manipulation of EXIF timestamps.

Example format:

    yyyy:MM:dd HH:mm:ss

Improper string replacement caused parsing instability.

------------------------------------------------------------------------

### 3. HashRep Propagation

When an incorrectly classified file entered `_Uncertain`, its SHA256
hash became the representative path.

Subsequent identical files inherited the incorrect classification.

------------------------------------------------------------------------

### 4. Epoch 10-digit Misinterpretation

Certain numeric filenames (10 digits) were interpreted as Unix seconds,
resulting in incorrect year assignment (e.g., 2001).

------------------------------------------------------------------------

### 5. Encoding Instability in Korean Regex

Direct Korean literals in regex patterns were corrupted due to UTF-8 /
ANSI mismatch in PowerShell 5.1 environments.

------------------------------------------------------------------------

## Structural Fixes Applied

### Fix 1 --- EXIF Read Stabilization

Replaced:

    FromStream()

With:

    System.Drawing.Image::FromFile()

EXIF tag priority:

-   0x9003 --- DateTimeOriginal
-   0x9004 --- DateTimeDigitized
-   0x0132 --- DateTime

Parsing method upgraded to:

    DateTime.ParseExact(..., InvariantCulture)

This restored reliable EXIF detection.

------------------------------------------------------------------------

### Fix 2 --- Trust Hierarchy Model Formalization

Classification order stabilized as:

1.  JSON photoTakenTime
2.  EXIF DateTimeOriginal
3.  Filename-derived datetime
4.  Weak signals (creationTime, Win metadata)
5.  HashRep (conditional)
6.  Fallback → `_Uncertain`

This prevented weak signals from confirming suspect year contamination.

------------------------------------------------------------------------

### Fix 3 --- SuspectYear Protection Model

Introduced dynamic protection of current year:

    SuspectYear = (Get-Date).Year

Weak evidence matching SuspectYear is downgraded to `_Uncertain`.

------------------------------------------------------------------------

### Fix 4 --- Epoch Range Guard

Accepted Unix seconds only if:

    2010 ≤ Year ≤ CurrentYear + 1

Prevents accidental 2001 misclassification.

------------------------------------------------------------------------

### Fix 5 --- Unicode-Safe Korean Regex

Replaced literal Korean characters with:

    \uXXXX patterns

Eliminated encoding corruption in PowerShell 5.1.

------------------------------------------------------------------------

## Quantitative Impact

Before fixes:

    _Uncertain = 1107 files

After EXIF stabilization and hierarchy correction:

    _Uncertain = 28 files

Reduction:

    97.47% decrease in uncertain classifications

The remaining 28 files represent genuine low-confidence cases: - No
EXIF - No JSON - No filename datetime - Weak or absent metadata

------------------------------------------------------------------------

## Architectural Significance

This milestone marks:

-   Transition from heuristic classification
-   To deterministic metadata trust modeling
-   Establishment of reproducible normalization behavior
-   Elimination of structural contamination propagation

The system evolved from a batch sorting script into a reliability-driven
archival normalization engine.

------------------------------------------------------------------------

## Conclusion

The "1107 → 28" milestone is not merely a numeric improvement. It
represents stabilization of metadata interpretation logic, EXIF
extraction correctness, and contamination-resistant year classification.

This document records the technical turning point in the development of
TakeoutPhotoSanitizer.

------------------------------------------------------------------------
