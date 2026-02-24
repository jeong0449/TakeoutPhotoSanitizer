# PowerShell Version Compatibility

## Introduction

`TakeoutPhotoSanitizer.ps1` is primarily designed to run on modern
Windows environments.\
While PowerShell maintains strong backward compatibility, certain
behaviors---especially related to encoding, file handling, and default
parameter values---can differ between versions.

Understanding these differences is important to ensure consistent and
reproducible results when processing large Google Takeout archives.

This document outlines the compatibility considerations between:

-   Windows PowerShell 5.1\
-   PowerShell 7.x (Core / Cross-platform)

------------------------------------------------------------------------

## Key Differences Between PowerShell 5.1 and 7.x

### 1. Default Text Encoding

One of the most important differences concerns text encoding.

**PowerShell 5.1** - `Out-File`, `Set-Content`, and `Export-Csv` may
default to UTF-16 LE or system ANSI in certain scenarios. - UTF-8 output
does not always include BOM unless explicitly specified.

**PowerShell 7.x** - Defaults to UTF-8 (without BOM). - Supports
`-Encoding utf8BOM` explicitly.

Since `TakeoutPhotoSanitizer` generates CSV/TSV files that may be opened
in Microsoft Excel (especially in Korean Windows environments), it is
strongly recommended to explicitly use:

    -Encoding utf8BOM

to prevent character corruption.

------------------------------------------------------------------------

### 2. File System and Path Handling

PowerShell 7 provides improvements in:

-   Path normalization
-   Cross-platform compatibility
-   Long path handling
-   More consistent behavior with `-LiteralPath`

If processing very large Takeout archives or deeply nested folder
structures, PowerShell 7 is generally more robust.

------------------------------------------------------------------------

### 3. Performance Considerations

PowerShell 7 typically offers:

-   Faster pipeline execution
-   Better memory management
-   Improved parallel processing support

For collections containing tens of thousands of files, PowerShell 7 is
recommended.

------------------------------------------------------------------------

### 4. Recommended Runtime Environment

`TakeoutPhotoSanitizer.ps1` works in:

-   Windows PowerShell 5.1\
-   PowerShell 7.x

However, for best stability, encoding consistency, and performance, the
recommended runtime environment is:

> PowerShell 7.x (64-bit)

You can check your installed version using:

    $PSVersionTable.PSVersion

------------------------------------------------------------------------

## Summary

  Feature             PowerShell 5.1           PowerShell 7.x
  ------------------- ------------------------ --------------------
  Default Encoding    Legacy/UTF-16 variants   UTF-8 (no BOM)
  UTF-8 BOM Support   Limited                  Explicit `utf8BOM`
  Long Path Support   Limited                  Improved
  Performance         Stable                   Faster
  Recommendation      Compatible               Recommended

------------------------------------------------------------------------

This compatibility guidance ensures reproducible and predictable
behavior when running `TakeoutPhotoSanitizer.ps1` across different
Windows environments.
