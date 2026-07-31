# ===========================================================================
# Shared pre-flight file-accessibility guard. Dot-sourced by the workbook
# builders (build-scope3-excel.ps1, build-enterprise-excel.ps1) to fail fast
# with a clear, aggregated message when a required workbook is missing or is
# still open/locked (typically in Excel) BEFORE the build copies, opens or
# overwrites anything - instead of dying half-way with a raw IOException.
# ===========================================================================

function Test-PathLocked {
  # Returns $true when the file exists but cannot be opened with the requested
  # access because another process (e.g. Excel) holds a handle on it. A missing
  # file is NOT "locked" (returns $false); callers decide if absence is fatal.
  param(
    [Parameter(Mandatory = $true)] [string] $Path,
    [ValidateSet('Read', 'ReadWrite')] [string] $Access = 'ReadWrite'
  )
  if ([string]::IsNullOrWhiteSpace($Path) -or -not (Test-Path -LiteralPath $Path)) { return $false }
  $acc = [System.IO.FileAccess]::$Access
  try {
    # FileShare.None demands exclusive access, so the open fails if ANY other
    # handle is open on the file - exactly the "open in Excel" case we detect.
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, $acc, [System.IO.FileShare]::None)
    $fs.Dispose()
    return $false
  } catch {
    return $true
  }
}

function Assert-FilesAccessible {
  # Pre-flight guard. $RequiredReadPaths must exist and be closed (the build
  # opens them, read-only). $WritePaths may be absent (they get created); if one
  # already exists it must be closed so the build can overwrite it. Throws a
  # single aggregated error naming every problem file, or returns silently.
  param(
    [string[]] $RequiredReadPaths = @(),
    [string[]] $WritePaths = @()
  )

  $missing = New-Object System.Collections.Generic.List[string]
  $locked  = New-Object System.Collections.Generic.List[string]

  foreach ($p in @($RequiredReadPaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
    if (-not (Test-Path -LiteralPath $p)) { $missing.Add($p); continue }
    if (Test-PathLocked -Path $p -Access 'Read') { $locked.Add($p) }
  }

  foreach ($p in @($WritePaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | Select-Object -Unique)) {
    # Absent write targets are fine (they will be created). Only flag ones that
    # exist and are held open, which would block the copy/overwrite/save.
    if ((Test-Path -LiteralPath $p) -and (Test-PathLocked -Path $p -Access 'ReadWrite')) { $locked.Add($p) }
  }

  if ($missing.Count -eq 0 -and $locked.Count -eq 0) { return }

  $sb = New-Object System.Text.StringBuilder
  [void] $sb.AppendLine('Pre-flight file check failed - the build cannot start.')
  if ($locked.Count -gt 0) {
    [void] $sb.AppendLine('')
    [void] $sb.AppendLine('Open or locked (close them in Excel and re-run the build):')
    foreach ($f in ($locked | Select-Object -Unique)) { [void] $sb.AppendLine(('  - {0}' -f $f)) }
  }
  if ($missing.Count -gt 0) {
    [void] $sb.AppendLine('')
    [void] $sb.AppendLine('Missing required file(s):')
    foreach ($f in $missing) { [void] $sb.AppendLine(('  - {0}' -f $f)) }
  }
  throw ($sb.ToString().TrimEnd())
}
