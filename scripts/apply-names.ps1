<#
.SYNOPSIS
  Apply defined names to formulas: rewrite every cell/range reference that
  matches an existing defined name so the formula uses the NAME instead of the
  raw address. This is the equivalent of Excel's native "Apply Names" feature,
  but it also rewrites CROSS-SHEET references (which Excel's built-in does not).

.DESCRIPTION
  For each workbook this script:

    1. Enumerates every WORKBOOK-SCOPED defined name whose RefersTo is a plain
       cell or contiguous range on a single sheet, e.g.
           MyConst        -> ='Constants'!$G$5
           M1_Table_I_j   -> ='Data'!$D$83:$H$140
       Names that refer to formulas, constants, unions (commas), whole
       columns/rows, external workbooks or built-ins (Print_Area, etc.) are
       skipped.

    2. Rewrites every reference to that cell/range (pure or embedded,
       same-sheet or cross-sheet, qualified or bare) to use the name instead.
       Single-cell range endpoints (address adjacent to ':') are conservatively
       left alone so multi-cell ranges are not partially rewritten.

  Runs on ALL top-level Excel/*.xlsx workbooks by default (this is a one-shot
  maintenance task). Pass -WorkbookPath to target a single workbook.

  DRY-RUN by default: the rewrites are computed IN MEMORY and reported as
  old -> new, but the file is NOT written. Pass -Commit to save (a one-time
  *.preapply.bak.xlsx backup is created first).

.PARAMETER WorkbookPath
  Full path to a single .xlsx to process. If omitted, every top-level
  Excel/*.xlsx (excluding lock files and *_expanded* outputs) is processed.

.PARAMETER NamePattern
  Optional regex (case-insensitive) tested against the defined name. Only names
  matching this are applied. Default '.' (all names).

.PARAMETER Commit
  Actually write the rewrites and save. Without it, reports only.
#>
param(
  [string] $RepoRoot = (Split-Path $PSScriptRoot -Parent),
  [string] $WorkbookPath,
  [string] $NamePattern = '.',
  [switch] $Commit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Workbook discovery.
# ---------------------------------------------------------------------------
function Get-TargetWorkbooks {
  param([string] $RepoRoot, [string] $WorkbookPath)
  if (-not [string]::IsNullOrWhiteSpace($WorkbookPath)) {
    if (-not (Test-Path -LiteralPath $WorkbookPath)) { throw "Workbook not found: $WorkbookPath" }
    return @((Resolve-Path -LiteralPath $WorkbookPath).Path)
  }
  $excelDir = Join-Path $RepoRoot 'Excel'
  if (-not (Test-Path -LiteralPath $excelDir)) { throw "Excel folder not found: $excelDir" }
  Get-ChildItem -LiteralPath $excelDir -Filter '*.xlsx' -File |
    Where-Object { $_.Name -notlike '~$*' -and $_.BaseName -notmatch '(?i)_expanded' -and $_.BaseName -notmatch '(?i)\.(prename|preapply)\.bak$' } |
    Sort-Object FullName |
    ForEach-Object { $_.FullName }
}

# ---------------------------------------------------------------------------
# Address / snapshot helpers.
# ---------------------------------------------------------------------------
function ConvertTo-ColLetters {
  param([int] $Col)
  $s = ''
  while ($Col -gt 0) {
    $rem = ($Col - 1) % 26
    $s = [char](65 + $rem) + $s
    $Col = [int](($Col - $rem - 1) / 26)
  }
  return $s
}

function ConvertFrom-ColLetters {
  param([string] $Letters)
  $n = 0
  foreach ($ch in $Letters.ToUpperInvariant().ToCharArray()) {
    $n = $n * 26 + ([int][char]$ch - 64)
  }
  return $n
}

function Get-FormulaSnapshot {
  param($Ws)
  $ur = $Ws.UsedRange
  return [pscustomobject]@{
    Row  = [int] $ur.Row
    Col  = [int] $ur.Column
    Rows = [int] $ur.Rows.Count
    Cols = [int] $ur.Columns.Count
    Data = $ur.Formula
  }
}

function Get-SnapshotFormula {
  param($Snapshot, [int] $R, [int] $C)   # R,C are 1-based within snapshot
  if ($Snapshot.Rows -eq 1 -and $Snapshot.Cols -eq 1) { return [string] $Snapshot.Data }
  return [string] $Snapshot.Data.GetValue($R, $C)
}

# ---------------------------------------------------------------------------
# Parse a defined name's RefersTo into a simple cell/range target, or $null if
# it is not a plain single-sheet cell/range reference we can safely rewrite.
#   Returns @{ Sheet; Col1; Row1; Col2; Row2; IsRange }
# ---------------------------------------------------------------------------
function Get-NameTarget {
  param([string] $RefersTo)
  if ([string]::IsNullOrWhiteSpace($RefersTo)) { return $null }
  $s = $RefersTo.Trim()
  if ($s.StartsWith('=')) { $s = $s.Substring(1).Trim() }

  # Reject external workbooks, unions/intersections, and 3D references.
  if ($s.IndexOf('[') -ge 0 -or $s.IndexOf(']') -ge 0) { return $null }
  if ($s.IndexOf(',') -ge 0) { return $null }

  $addr = '\$?([A-Za-z]{1,3})\$?([0-9]+)'
  $rx = "^(?:'((?:[^']|'')+)'|([A-Za-z0-9_.]+))!$addr(?::$addr)?$"
  $m = [regex]::Match($s, $rx)
  if (-not $m.Success) { return $null }

  $sheet = if ($m.Groups[1].Success) { $m.Groups[1].Value -replace "''", "'" } else { $m.Groups[2].Value }
  $col1 = ($m.Groups[3].Value).ToUpperInvariant()
  $row1 = [int] $m.Groups[4].Value
  $isRange = $m.Groups[5].Success
  $col2 = if ($isRange) { ($m.Groups[5].Value).ToUpperInvariant() } else { $col1 }
  $row2 = if ($isRange) { [int] $m.Groups[6].Value } else { $row1 }

  return [pscustomobject]@{
    Sheet   = $sheet
    Col1    = $col1
    Row1    = $row1
    Col2    = $col2
    Row2    = $row2
    IsRange = ($isRange -and -not ($col1 -eq $col2 -and $row1 -eq $row2))
  }
}

# ---------------------------------------------------------------------------
# Build the rewrite rule (compiled regexes) for one named target.
# ---------------------------------------------------------------------------
function New-ApplyRule {
  param([string] $Name, $Target)

  $q = "'" + ($Target.Sheet -replace "'", "''") + "'"
  $sheetAlt = [regex]::Escape($q) + '|' + [regex]::Escape($Target.Sheet)

  if ($Target.IsRange) {
    $a1 = '\$?' + [regex]::Escape($Target.Col1) + '\$?' + $Target.Row1
    $a2 = '\$?' + [regex]::Escape($Target.Col2) + '\$?' + $Target.Row2
    $qual = '(?<![A-Za-z0-9_''])(?:' + $sheetAlt + ')!' + $a1 + ':' + $a2 + '(?![0-9A-Za-z_])'
    $bare = '(?<![A-Za-z0-9_$''!:])' + $a1 + ':' + $a2 + '(?![0-9A-Za-z_])'
  } else {
    $a = '\$?' + [regex]::Escape($Target.Col1) + '\$?' + $Target.Row1
    $qual = '(?<![A-Za-z0-9_''])(?:' + $sheetAlt + ')!' + $a + '(?![0-9A-Za-z_:])'
    $bare = '(?<![A-Za-z0-9_$''!:])' + $a + '(?![0-9A-Za-z_(:])'
  }

  return [pscustomobject]@{
    Name  = $Name
    Sheet = $Target.Sheet
    Row   = $Target.Row1
    Col   = (ConvertFrom-ColLetters $Target.Col1)
    Range = $Target.IsRange
    Qual  = [regex]::new($qual)
    Bare  = [regex]::new($bare)
  }
}

# ---------------------------------------------------------------------------
# Process a single workbook.
# ---------------------------------------------------------------------------
function Invoke-Workbook {
  param($Excel, [string] $Path, [switch] $Commit)

  Write-Host ''
  Write-Host ('=' * 78)
  Write-Host ("Workbook : {0}" -f (Split-Path $Path -Leaf))

  $wb = $Excel.Workbooks.Open($Path, 0, $false)   # read-write; we control saving
  $rewriteCount = 0
  $ruleCount = 0
  $skipped = 0

  try {
    # ---- Build rewrite rules from existing workbook-scoped names. --------
    $rules = New-Object System.Collections.Generic.List[object]
    foreach ($n in $wb.Names) {
      $name = $null; $refersTo = $null
      try { $name = [string] $n.Name; $refersTo = [string] $n.RefersTo } catch { continue }
      if ([string]::IsNullOrWhiteSpace($name)) { continue }

      # Workbook-scoped only (sheet-local names appear as 'Sheet'!Name).
      if ($name.IndexOf('!') -ge 0) { continue }
      # Skip Excel built-ins (Print_Area, Print_Titles, _FilterDatabase, ...).
      if ($name -match '(?i)(^|\.)_xlnm' -or $name -match '(?i)^Print_(Area|Titles)$' -or $name -match '(?i)_FilterDatabase') { continue }
      if ($name -notmatch $NamePattern) { continue }

      $target = Get-NameTarget -RefersTo $refersTo
      if ($null -eq $target) {
        Write-Host ("  [skip]  '{0}' -> {1} (not a plain cell/range)" -f $name, $refersTo) -ForegroundColor DarkGray
        $skipped++
        continue
      }

      $rules.Add((New-ApplyRule -Name $name -Target $target))
      $ruleCount++
    }

    if ($rules.Count -eq 0) {
      Write-Host '  No applicable defined names found.' -ForegroundColor DarkGray
      return [pscustomobject]@{ Rules = 0; Rewrites = 0; Skipped = $skipped }
    }

    # ---- Rewrite references to the named cells/ranges. -------------------
    foreach ($ws in $wb.Worksheets) {
      $sheetName = [string] $ws.Name
      $snap = $null
      try { $snap = Get-FormulaSnapshot -Ws $ws } catch { continue }
      if ($snap.Rows -lt 1 -or $snap.Cols -lt 1) { continue }

      for ($r = 1; $r -le $snap.Rows; $r++) {
        for ($c = 1; $c -le $snap.Cols; $c++) {
          $f = Get-SnapshotFormula -Snapshot $snap -R $r -C $c
          if ([string]::IsNullOrWhiteSpace($f) -or $f[0] -ne '=') { continue }

          $absRow = $snap.Row + $r - 1
          $absCol = $snap.Col + $c - 1
          $new = $f
          foreach ($rule in $rules) {
            # Never rewrite the defining cell's own formula to reference itself.
            if (-not $rule.Range -and $rule.Sheet -eq $sheetName -and $rule.Row -eq $absRow -and $rule.Col -eq $absCol) { continue }
            $eval = [System.Text.RegularExpressions.MatchEvaluator] { param($m) $rule.Name }
            $new = $rule.Qual.Replace($new, $eval)
            if ($rule.Sheet -eq $sheetName) { $new = $rule.Bare.Replace($new, $eval) }
          }

          if ($new -ne $f) {
            $addr = (ConvertTo-ColLetters $absCol) + [string] $absRow
            $rewriteCount++
            Write-Host ("  [ref]   {0}!{1}  {2}  ->  {3}" -f $sheetName, $addr, $f, $new) -ForegroundColor Cyan
            if ($Commit) { $ws.Cells.Item($absRow, $absCol).Formula = $new }
          }
        }
      }
    }

    Write-Host ("  Summary: {0} names applied, {1} references rewritten, {2} names skipped" -f `
        $ruleCount, $rewriteCount, $skipped)

    # ---- Save (commit only). ---------------------------------------------
    if ($Commit -and $rewriteCount -gt 0) {
      $bak = [IO.Path]::Combine((Split-Path $Path -Parent),
        ([IO.Path]::GetFileNameWithoutExtension($Path) + '.preapply.bak.xlsx'))
      if (-not (Test-Path -LiteralPath $bak)) {
        Copy-Item -LiteralPath $Path -Destination $bak -Force
        Write-Host ("  Backup : {0}" -f (Split-Path $bak -Leaf)) -ForegroundColor DarkGray
      }
      $wb.Save()
      Write-Host '  Saved.' -ForegroundColor Green
    }

    return [pscustomobject]@{ Rules = $ruleCount; Rewrites = $rewriteCount; Skipped = $skipped }
  }
  finally {
    try { $wb.Close($false) } catch { }
    if ($null -ne $wb) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($wb) }
  }
}

# ---------------------------------------------------------------------------
# Main.
# ---------------------------------------------------------------------------
$workbooks = @(Get-TargetWorkbooks -RepoRoot $RepoRoot -WorkbookPath $WorkbookPath)
Write-Host ("Mode      : {0}" -f ($(if ($Commit) { 'COMMIT' } else { 'DRY-RUN (no files written)' })))
Write-Host ("Workbooks : {0}" -f $workbooks.Count)
Write-Host ("NamePattern: {0}" -f $NamePattern)

$excel = $null
$totRules = 0; $totRewrites = 0; $totSkipped = 0
try {
  $excel = New-Object -ComObject Excel.Application
  $excel.Visible = $false
  $excel.DisplayAlerts = $false
  $excel.AskToUpdateLinks = $false
  $excel.ScreenUpdating = $false

  foreach ($path in $workbooks) {
    try {
      $res = Invoke-Workbook -Excel $excel -Path $path -Commit:$Commit
      $totRules += $res.Rules
      $totRewrites += $res.Rewrites
      $totSkipped += $res.Skipped
    } catch {
      Write-Host ("  [FATAL] {0}: {1}" -f (Split-Path $path -Leaf), $_.Exception.Message) -ForegroundColor Red
      # Recreate Excel in case the COM server crashed.
      try { $excel.Quit() } catch { }
      try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel) } catch { }
      $excel = New-Object -ComObject Excel.Application
      $excel.Visible = $false
      $excel.DisplayAlerts = $false
      $excel.AskToUpdateLinks = $false
      $excel.ScreenUpdating = $false
    }
  }
}
finally {
  if ($null -ne $excel) {
    try { $excel.Quit() } catch { }
    try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel) } catch { }
  }
  [System.GC]::Collect()
  [System.GC]::WaitForPendingFinalizers()
}

Write-Host ''
Write-Host ('=' * 78)
Write-Host ("TOTAL: {0} names applied, {1} references rewritten, {2} names skipped across {3} workbook(s)." -f `
    $totRules, $totRewrites, $totSkipped, $workbooks.Count)
if (-not $Commit) { Write-Host 'DRY-RUN: nothing was written. Re-run with -Commit to apply.' -ForegroundColor Yellow }
