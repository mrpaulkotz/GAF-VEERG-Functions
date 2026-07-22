<#
.SYNOPSIS
  Name "constant" cells that call a SourceData_*_Data function and return a
  single value, then route all references to those cells through the new name.

.DESCRIPTION
  Many workbooks contain scalar "constant" cells whose formula is a single call
  to a VEERG source-data function, e.g.

      =Common_SourceData.Common_SourceData_DensityOfMethane_Data()

  Other cells (often on other sheets) reference these constants by raw cell
  address (e.g. ='Constants - Pasture Beef'!$G$5). This script:

    1. Finds cells whose formula is a SINGLE call to a function whose (bare)
       name matches -FunctionPattern (default: contains a "SourceData_" segment
       and ends with "_Data") AND whose result is a single (scalar) value.
    2. Adds a workbook-scoped defined name = the BARE function name (module
       prefix stripped), RefersTo that cell.
    3. Rewrites every reference to that cell (pure or embedded, same-sheet or
       cross-sheet) to use the new name, via Excel's native "Apply Names".

  Runs on ALL top-level Excel/*.xlsx workbooks by default (this is a one-shot
  maintenance script). Pass -WorkbookPath to target a single workbook.

  DRY-RUN by default: the naming + Apply-Names is performed IN MEMORY and the
  formula changes are diffed and reported, but the file is NOT written. Pass
  -Commit to save (a one-time *.prename.bak.xlsx backup is created first).

.PARAMETER WorkbookPath
  Full path to a single .xlsx to process. If omitted, every top-level
  Excel/*.xlsx (excluding lock files and *_expanded* outputs) is processed.

.PARAMETER FunctionPattern
  Regex (case-insensitive) tested against the BARE function name. Default
  '(^|_)SourceData_.*_Data$'.

.PARAMETER Commit
  Actually write the names / rewrites and save. Without it, reports only.
#>
param(
  [string] $RepoRoot = (Split-Path $PSScriptRoot -Parent),
  [string] $WorkbookPath,
  [string] $FunctionPattern = '(^|_)SourceData_.*_Data$',
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
    Where-Object { $_.Name -notlike '~$*' -and $_.BaseName -notmatch '(?i)_expanded' } |
    Sort-Object FullName |
    ForEach-Object { $_.FullName }
}

# ---------------------------------------------------------------------------
# Formula parsing helpers.
# ---------------------------------------------------------------------------
function Get-OuterCallName {
  # Returns the outer call name IFF the formula is a single outer function call
  # spanning the whole formula (=Name(...)), else $null. Quote/paren aware.
  param([string] $Formula)
  if ([string]::IsNullOrWhiteSpace($Formula)) { return $null }
  $f = $Formula.Trim()
  if (-not $f.StartsWith('=')) { return $null }
  $body = $f.Substring(1).Trim()
  $m = [regex]::Match($body, '^([A-Za-z_\\][A-Za-z0-9_.\\]*)\s*\(')
  if (-not $m.Success) { return $null }
  $name = $m.Groups[1].Value
  $open = $m.Index + $m.Length - 1   # index of the '('
  $depth = 0; $inStr = $false; $lastClose = -1
  for ($i = $open; $i -lt $body.Length; $i++) {
    $ch = $body[$i]
    if ($inStr) { if ($ch -eq '"') { $inStr = $false }; continue }
    if ($ch -eq '"') { $inStr = $true; continue }
    if ($ch -eq '(') { $depth++ }
    elseif ($ch -eq ')') { $depth--; if ($depth -eq 0) { $lastClose = $i; break } }
  }
  if ($lastClose -lt 0) { return $null }
  if ($body.Substring($lastClose + 1).Trim().Length -ne 0) { return $null }
  return $name
}

function Get-BareFunctionName {
  param([string] $CallName)
  if ([string]::IsNullOrWhiteSpace($CallName)) { return $null }
  $idx = $CallName.LastIndexOf('.')
  if ($idx -ge 0) { return $CallName.Substring($idx + 1) }
  return $CallName
}

function Test-ScalarResult {
  param($Cell)
  try { $v2 = $Cell.Value2 } catch { return $false }
  if ($v2 -is [System.Array]) { return $false }
  try { $t = [string] $Cell.Text; if ($t -like '#*') { return $false } } catch { }
  try { if ([bool] $Cell.HasArray) { if ([int] $Cell.CurrentArray.Count -gt 1) { return $false } } } catch { }
  try { if ([bool] $Cell.HasSpill) { $sp = $Cell.SpillingToRange; if ($null -ne $sp -and [int] $sp.Count -gt 1) { return $false } } } catch { }
  return $true
}

# ---------------------------------------------------------------------------
# Formula snapshot (for before/after diffing).
#   Returns @{ Base=@{Row;Col;Rows;Cols}; Data=<object[,] or scalar> } per sheet.
# ---------------------------------------------------------------------------
function Get-FormulaSnapshot {
  param($Ws)
  $ur = $Ws.UsedRange
  $rows = [int] $ur.Rows.Count
  $cols = [int] $ur.Columns.Count
  return [pscustomobject]@{
    Row  = [int] $ur.Row
    Col  = [int] $ur.Column
    Rows = $rows
    Cols = $cols
    Data = $ur.Formula
  }
}

function Get-SnapshotFormula {
  param($Snapshot, [int] $R, [int] $C)   # R,C are 1-based within snapshot
  if ($Snapshot.Rows -eq 1 -and $Snapshot.Cols -eq 1) { return [string] $Snapshot.Data }
  return [string] $Snapshot.Data.GetValue($R, $C)
}

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

# ---------------------------------------------------------------------------
# Process a single workbook.
# ---------------------------------------------------------------------------
function Invoke-Workbook {
  param($Excel, [string] $Path, [switch] $Commit)

  Write-Host ''
  Write-Host ('=' * 78)
  Write-Host ("Workbook : {0}" -f (Split-Path $Path -Leaf))

  $wb = $Excel.Workbooks.Open($Path, 0, $false)   # read-write; we control saving
  $renamedCells = 0
  $rewriteCount = 0
  $skippedConflicts = 0
  $duplicateCells = 0

  try {
    # Existing workbook-scoped names (case-insensitive) -> RefersTo.
    $existing = @{}
    foreach ($n in $wb.Names) {
      try { $existing[[string] $n.Name] = [string] $n.RefersTo } catch { }
    }

    # ---- Pass 1: find candidate constant cells. --------------------------
    $candidates = New-Object System.Collections.Generic.List[object]
    $seenBare = @{}   # bareName -> "sheet!addr" of the first cell that claimed it

    foreach ($ws in $wb.Worksheets) {
      $ur = $null
      try { $ur = $ws.UsedRange } catch { continue }
      if ($null -eq $ur) { continue }
      $snap = Get-FormulaSnapshot -Ws $ws
      if ($snap.Rows -lt 1 -or $snap.Cols -lt 1) { continue }

      for ($r = 1; $r -le $snap.Rows; $r++) {
        for ($c = 1; $c -le $snap.Cols; $c++) {
          $formula = Get-SnapshotFormula -Snapshot $snap -R $r -C $c
          if ([string]::IsNullOrWhiteSpace($formula)) { continue }
          if ($formula.IndexOf('_Data', [StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }

          $callName = Get-OuterCallName -Formula $formula
          if ($null -eq $callName) { continue }
          $bare = Get-BareFunctionName -CallName $callName
          if ($bare -notmatch $FunctionPattern) { continue }

          $absRow = $snap.Row + $r - 1
          $absCol = $snap.Col + $c - 1
          $cell = $ws.Cells.Item($absRow, $absCol)
          if (-not (Test-ScalarResult -Cell $cell)) { continue }

          $addr = (ConvertTo-ColLetters $absCol) + [string] $absRow
          $key = "{0}!{1}" -f $ws.Name, $addr

          if ($seenBare.ContainsKey($bare)) {
            Write-Host ("  [dup]   {0} -> '{1}' already claimed by {2} (cell not named)" -f $key, $bare, $seenBare[$bare]) -ForegroundColor DarkYellow
            $duplicateCells++
            continue
          }
          $seenBare[$bare] = $key

          $candidates.Add([pscustomobject]@{
            Bare     = $bare
            CallName = $callName
            Sheet    = [string] $ws.Name
            AbsRow   = $absRow
            AbsCol   = $absCol
            Addr     = $addr
            Cell     = $cell
          })
        }
      }
    }

    if ($candidates.Count -eq 0) {
      Write-Host '  No SourceData_*_Data constant cells found.' -ForegroundColor DarkGray
      return [pscustomobject]@{ Renamed = 0; Rewrites = 0; Conflicts = 0; Duplicates = $duplicateCells }
    }

    # ---- Pass 2: add workbook-scoped names. ------------------------------
    $applyNames = New-Object System.Collections.Generic.List[object]
    foreach ($cand in $candidates) {
      $refersTo = "='" + ($cand.Sheet -replace "'", "''") + "'!" + $cand.Cell.Address($true, $true)

      if ($existing.ContainsKey($cand.Bare)) {
        $cur = $existing[$cand.Bare]
        if ($cur -and ($cur -replace '\s', '') -ieq ($refersTo -replace '\s', '')) {
          Write-Host ("  [have]  {0}!{1} already named '{2}'" -f $cand.Sheet, $cand.Addr, $cand.Bare) -ForegroundColor DarkGray
          $applyNames.Add($cand.Bare)
        } else {
          Write-Host ("  [SKIP]  '{0}' already exists (RefersTo {1}); {2}!{3} left as-is" -f $cand.Bare, $cur, $cand.Sheet, $cand.Addr) -ForegroundColor Yellow
          $skippedConflicts++
        }
        continue
      }

      try {
        [void] $wb.Names.Add($cand.Bare, $refersTo)
        $existing[$cand.Bare] = $refersTo
        $applyNames.Add($cand.Bare)
        $renamedCells++
        Write-Host ("  [name]  {0}!{1}  ->  {2}" -f $cand.Sheet, $cand.Addr, $cand.Bare) -ForegroundColor Green
      } catch {
        Write-Host ("  [ERR]   could not add name '{0}' for {1}!{2}: {3}" -f $cand.Bare, $cand.Sheet, $cand.Addr, $_.Exception.Message) -ForegroundColor Red
        $skippedConflicts++
      }
    }

    if ($applyNames.Count -eq 0) {
      Write-Host '  No names to apply.' -ForegroundColor DarkGray
      return [pscustomobject]@{ Renamed = $renamedCells; Rewrites = 0; Conflicts = $skippedConflicts; Duplicates = $duplicateCells }
    }

    # ---- Pass 3: rewrite references to the named cells. ------------------
    # Excel's native "Apply Names" only rewrites SAME-SHEET references, so we
    # rewrite manually to also catch cross-sheet and embedded references.
    # Range endpoints (address adjacent to ':') are conservatively skipped.
    $namedSet = @{}
    foreach ($nm in $applyNames) { $namedSet[$nm] = $true }
    $rules = New-Object System.Collections.Generic.List[object]
    foreach ($cand in $candidates) {
      if (-not $namedSet.ContainsKey($cand.Bare)) { continue }
      $col = ConvertTo-ColLetters $cand.AbsCol
      $row = [string] $cand.AbsRow
      $reCol = [regex]::Escape($col)
      $q = "'" + ($cand.Sheet -replace "'", "''") + "'"
      $sheetAlt = [regex]::Escape($q) + '|' + [regex]::Escape($cand.Sheet)
      $rules.Add([pscustomobject]@{
        Name  = $cand.Bare
        Sheet = $cand.Sheet
        Row   = $cand.AbsRow
        Col   = $cand.AbsCol
        # Sheet-qualified reference (any sheet may host the formula).
        Qual  = [regex]::new('(?<![A-Za-z0-9_''])(?:' + $sheetAlt + ')!\$?' + $reCol + '\$?' + $row + '(?![0-9A-Za-z_:])')
        # Bare same-sheet reference (only when formula lives on Sheet).
        Bare  = [regex]::new('(?<![A-Za-z0-9_$''!:])\$?' + $reCol + '\$?' + $row + '(?![0-9A-Za-z_(:])')
      })
    }

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
            # Skip the source constant cell itself.
            if ($rule.Sheet -eq $sheetName -and $rule.Row -eq $absRow -and $rule.Col -eq $absCol) { continue }
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

    Write-Host ("  Summary: {0} named, {1} references rewritten, {2} conflicts, {3} duplicates" -f `
        $renamedCells, $rewriteCount, $skippedConflicts, $duplicateCells)

    # ---- Save (commit only). ---------------------------------------------
    if ($Commit -and ($renamedCells -gt 0 -or $rewriteCount -gt 0)) {
      $bak = [IO.Path]::Combine((Split-Path $Path -Parent),
        ([IO.Path]::GetFileNameWithoutExtension($Path) + '.prename.bak.xlsx'))
      if (-not (Test-Path -LiteralPath $bak)) {
        Copy-Item -LiteralPath $Path -Destination $bak -Force
        Write-Host ("  Backup : {0}" -f (Split-Path $bak -Leaf)) -ForegroundColor DarkGray
      }
      $wb.Save()
      Write-Host '  Saved.' -ForegroundColor Green
    }

    return [pscustomobject]@{ Renamed = $renamedCells; Rewrites = $rewriteCount; Conflicts = $skippedConflicts; Duplicates = $duplicateCells }
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
Write-Host ("Pattern   : {0}" -f $FunctionPattern)

$excel = $null
$totRenamed = 0; $totRewrites = 0; $totConflicts = 0; $totDuplicates = 0
try {
  $excel = New-Object -ComObject Excel.Application
  $excel.Visible = $false
  $excel.DisplayAlerts = $false
  $excel.AskToUpdateLinks = $false
  $excel.ScreenUpdating = $false

  foreach ($path in $workbooks) {
    try {
      $res = Invoke-Workbook -Excel $excel -Path $path -Commit:$Commit
      $totRenamed += $res.Renamed
      $totRewrites += $res.Rewrites
      $totConflicts += $res.Conflicts
      $totDuplicates += $res.Duplicates
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
Write-Host ("TOTAL: {0} cells named, {1} references rewritten, {2} conflicts, {3} duplicates across {4} workbook(s)." -f `
    $totRenamed, $totRewrites, $totConflicts, $totDuplicates, $workbooks.Count)
if (-not $Commit) { Write-Host 'DRY-RUN: nothing was written. Re-run with -Commit to apply.' -ForegroundColor Yellow }
