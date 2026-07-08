<#
.SYNOPSIS
  Create workbook-scoped named ranges for matrix tables in a VEERG source workbook.

.DESCRIPTION
  A matrix table is identified by a "title" cell that uses the named cell style
  "Table name" (e.g. cell D81 = "M1_Table_I_j_k_l"). The layout is:

      row R      : title cell   (style "Table name")   <- the range name
      row R+1    : description   (style "Table description")
      row R+2..  : header row + data rows                <- the range to name

  For each title the script:
    * finds the matrix start = first non-empty row below the description row
      (i.e. two rows below the title),
    * extends RIGHT across the header row's contiguous non-empty columns
      (this naturally excludes a trailing "units" column, whose header is blank),
    * extends DOWN while the anchor (title) column stays non-empty,
    * includes the header row in the named range,
    * adds a workbook-scoped defined name = the title text, RefersTo that range.

  By default runs read-only and reports the proposed names (-DryRun implied unless
  -Commit is supplied).

.PARAMETER WorkbookPath
  Full path to the .xlsx to process. Defaults to the latest pasture-beef manure
  management workbook under Excel/.

.PARAMETER TitleStyle
  The cell style name that marks a table title. Default "Table name".

.PARAMETER Commit
  Actually write the defined names and save the workbook. Without it the script
  runs read-only and only reports what it WOULD do.
#>
param(
  [string] $RepoRoot = (Split-Path $PSScriptRoot -Parent),
  [string] $WorkbookPath,
  [string] $TitleStyle = 'Table name',
  [switch] $Commit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Resolve the workbook (version-tolerant: pick the highest _v## match).
# ---------------------------------------------------------------------------
function Resolve-Workbook {
  param([string] $RepoRoot, [string] $WorkbookPath)

  if (-not [string]::IsNullOrWhiteSpace($WorkbookPath)) {
    if (-not (Test-Path -LiteralPath $WorkbookPath)) { throw "Workbook not found: $WorkbookPath" }
    return (Resolve-Path -LiteralPath $WorkbookPath).Path
  }
  $excelDir = Join-Path $RepoRoot 'Excel'
  $candidates = Get-ChildItem -LiteralPath $excelDir -Filter '4_2_ManureManagement_BeefPasture_WIP_v*.xlsx' -File |
    Sort-Object {
      if ($_.BaseName -match '_v(\d+)$') { [int] $Matches[1] } else { 0 }
    } -Descending
  if (-not $candidates -or @($candidates).Count -eq 0) {
    throw "No pasture-beef manure workbook found in $excelDir"
  }
  return $candidates[0].FullName
}

# ---------------------------------------------------------------------------
# Cell helpers.
# ---------------------------------------------------------------------------
function Test-NameToken {
  # Prefilter for a plausible name title: a single non-empty token with no
  # internal whitespace (descriptive text has spaces). The authoritative gate
  # is the cell style; disallowed characters are stripped later by
  # ConvertTo-ExcelName, so we accept tokens that contain them here.
  param([object] $Value)
  if ($null -eq $Value) { return $false }
  $s = ([string] $Value).Trim()
  if ($s.Length -lt 1 -or $s.Length -gt 255) { return $false }
  if ($s -match '\s') { return $false }
  return $true
}

function ConvertTo-ExcelName {
  # Turn a title token into a legal Excel defined name by STRIPPING characters
  # that are not allowed (keep letters, digits, underscore, period, backslash).
  # e.g. 'M1_Table_LC_j_k-4-5' -> 'M1_Table_LC_j_k45'.
  param([string] $Token)
  if ([string]::IsNullOrWhiteSpace($Token)) { return $null }
  $s = ([string] $Token).Trim() -replace '[^A-Za-z0-9_.\\]', ''
  if ($s.Length -eq 0) { return $null }
  if ($s -notmatch '^[A-Za-z_\\]') { $s = '_' + $s }   # first char must be letter/_/\
  if ($s.Length -gt 255) { $s = $s.Substring(0, 255) }
  return $s
}

function Get-CellText {
  param($Worksheet, [int] $Row, [int] $Col)
  $v = $Worksheet.Cells.Item($Row, $Col).Value2
  if ($null -eq $v) { return '' }
  return ([string] $v).Trim()
}

function Get-CrossSheetRefCount {
  # Count cells in the range whose formula references another sheet (contains '!').
  # A high count marks a "consumer" copy; a source table holds literals/local refs.
  param($Range)
  $f = $Range.Formula
  $count = 0
  if ($f -is [System.Array]) {
    foreach ($cell in $f) {
      if ($cell -is [string] -and $cell.StartsWith('=') -and $cell.Contains('!')) { $count++ }
    }
  } elseif ($f -is [string] -and $f.StartsWith('=') -and $f.Contains('!')) {
    $count = 1
  }
  return $count
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
$resolved = Resolve-Workbook -RepoRoot $RepoRoot -WorkbookPath $WorkbookPath
Write-Host ("Workbook : {0}" -f $resolved)
Write-Host ("Style    : {0}" -f $TitleStyle)
Write-Host ("Mode     : {0}" -f ($(if ($Commit) { 'COMMIT' } else { 'DRY-RUN' })))
Write-Host ''

$excel = $null
$wb = $null
try {
  $excel = New-Object -ComObject Excel.Application
  $excel.Visible = $false
  $excel.DisplayAlerts = $false
  $excel.AskToUpdateLinks = $false
  $excel.ScreenUpdating = $false

  $readOnly = -not $Commit
  $wb = $excel.Workbooks.Open($resolved, 0, $readOnly)

  # Snapshot existing workbook-scoped names.
  $existingNames = @{}
  foreach ($n in $wb.Names) {
    try { $existingNames[[string] $n.Name] = [string] $n.RefersTo } catch { }
  }

  $candidates = New-Object System.Collections.Generic.List[object]

  foreach ($ws in $wb.Worksheets) {
    $sheetName = [string] $ws.Name
    $ur = $ws.UsedRange
    $r0 = [int] $ur.Row
    $c0 = [int] $ur.Column
    $nRows = [int] $ur.Rows.Count
    $nCols = [int] $ur.Columns.Count
    if ($nRows -lt 1 -or $nCols -lt 1) { continue }

    # Bulk read for cheap candidate scan.
    $data = $ur.Value2
    $isScalar = ($nRows -eq 1 -and $nCols -eq 1)

    for ($i = 1; $i -le $nRows; $i++) {
      for ($j = 1; $j -le $nCols; $j++) {
        $val = if ($isScalar) { $data } else { $data.GetValue($i, $j) }
        if (-not (Test-NameToken $val)) { continue }

        $row = $r0 + $i - 1
        $col = $c0 + $j - 1

        # Authoritative gate: the cell style.
        $styleName = $null
        try { $styleName = [string] $ws.Cells.Item($row, $col).Style.Name } catch { continue }
        if ($styleName -ne $TitleStyle) { continue }

        $token = ([string] $val).Trim()
        $name = ConvertTo-ExcelName $token
        if ([string]::IsNullOrEmpty($name)) {
          $candidates.Add([pscustomobject]@{
            Sheet = $sheetName; Name = $token; Token = $token; SanitisedFrom = ''
            RefersTo = ''; RangeLabel = ''; ExtRefs = 0
            Status = 'skip'; Reason = 'no legal name characters in title' })
          continue
        }
        $sanitisedFrom = if ($name -ne $token) { $token } else { '' }

        # Matrix start = first non-empty row (in the title column) below the
        # description row (title row + 1).
        $descRow = $row + 1
        $startRow = 0
        for ($r = $descRow + 1; $r -le ($r0 + $nRows + 50); $r++) {
          if ((Get-CellText $ws $r $col) -ne '') { $startRow = $r; break }
        }
        if ($startRow -eq 0) {
          $candidates.Add([pscustomobject]@{
            Sheet = $sheetName; Name = $name; Token = $token; SanitisedFrom = $sanitisedFrom
            RefersTo = ''; RangeLabel = ''; ExtRefs = 0
            Status = 'skip'; Reason = 'no data rows found below title' })
          continue
        }

        # Extend RIGHT across the header row's contiguous non-empty columns.
        $lastCol = $col
        $c = $col
        while ($true) {
          $next = $c + 1
          if ((Get-CellText $ws $startRow $next) -eq '') { break }
          $lastCol = $next; $c = $next
        }

        # Extend DOWN while the anchor (title) column stays non-empty.
        $lastRow = $startRow
        $r = $startRow
        while ($true) {
          $next = $r + 1
          if ((Get-CellText $ws $next $col) -eq '') { break }
          $lastRow = $next; $r = $next
        }

        $rng = $ws.Range($ws.Cells.Item($startRow, $col), $ws.Cells.Item($lastRow, $lastCol))
        $addr = $rng.Address($true, $true, 1, $false)   # $D$83:$N$87
        $quotedSheet = $sheetName -replace "'", "''"
        $refersTo = "='{0}'!{1}" -f $quotedSheet, $addr
        $extRefs = Get-CrossSheetRefCount $rng
        $cellCount = ($lastRow - $startRow + 1) * ($lastCol - $col + 1)

        $candidates.Add([pscustomobject]@{
          Sheet = $sheetName; Name = $name; Token = $token; SanitisedFrom = $sanitisedFrom
          RangeLabel = ("{0}!{1}" -f $sheetName, $addr)
          RefersTo = $refersTo; ExtRefs = $extRefs; CellCount = $cellCount
          Status = $null; Reason = '' })
      }
    }
  }

  # --- Resolve duplicate tokens: the source is the occurrence with the fewest
  #     cross-sheet references (consumers are cell-by-cell copies of the source).
  #     The source keeps the bare token; each consumer is named
  #     <token>_Consumer_<N> (N sequential per source) so every matrix is named
  #     without colliding with the global source name.
  $proposed = New-Object System.Collections.Generic.List[object]
  $groups = $candidates | Where-Object { $_.Status -ne 'skip' } | Group-Object Name
  foreach ($g in $groups) {
    $baseToken = [string] $g.Name
    $members = @($g.Group)
    if ($members.Count -eq 1) {
      $members[0].Status = 'source'
      $proposed.Add($members[0])
      continue
    }
    # Source = the largest range (a consumer is a same-size or smaller copy);
    # tie-break on fewest cross-sheet references (a source holds literals/local
    # refs, a consumer references the source cell-by-cell).
    $sorted = $members | Sort-Object @{ Expression = 'CellCount'; Descending = $true }, @{ Expression = 'ExtRefs'; Descending = $false }
    $source = $sorted[0]
    $source.Status = 'source'
    $proposed.Add($source)
    $n = 0
    foreach ($m in $members) {
      if ([object]::ReferenceEquals($m, $source)) { continue }
      $n++
      $m.Name = "{0}_Consumer_{1}" -f $baseToken, $n
      $m.Status = 'consumer'
      if ($m.ExtRefs -gt 0) {
        $m.Reason = ("consumer #{0} of '{1}' on '{2}' ({3} cross-sheet cells)" -f $n, $baseToken, $source.Sheet, $m.ExtRefs)
      } else {
        $m.Reason = ("consumer #{0} of '{1}' on '{2}' (redundant duplicate)" -f $n, $baseToken, $source.Sheet)
      }
      $proposed.Add($m)
    }
  }
  # Carry through any 'skip' rows for reporting.
  foreach ($c in ($candidates | Where-Object { $_.Status -eq 'skip' })) { $proposed.Add($c) }

  # --- Classify against existing workbook-scoped names -----------------------
  foreach ($p in $proposed) {
    if ($p.Status -ne 'source' -and $p.Status -ne 'consumer') { continue }
    if ($existingNames.ContainsKey($p.Name)) {
      $existingRef = $existingNames[$p.Name]
      if (($existingRef -replace '\s', '') -ieq ($p.RefersTo -replace '\s', '')) {
        $p.Status = 'exists'; $p.Reason = 'already named (same range)'
      } else {
        $p.Status = 'conflict'; $p.Reason = ("name exists -> {0}" -f $existingRef)
      }
    }
  }

  # --- Report ---------------------------------------------------------------
  Write-Host "Detected table titles:"
  Write-Host ''
  foreach ($p in ($proposed | Sort-Object Sheet, Name)) {
    Write-Host ("  [{0,-8}] {1,-28} {2}" -f $p.Status, $p.Name, $p.RangeLabel)
    if ($p.SanitisedFrom) { Write-Host ("             ^ sanitised from '{0}'" -f $p.SanitisedFrom) }
    if ($p.Reason) { Write-Host ("             ^ {0}" -f $p.Reason) }
  }

  # --- Commit ---------------------------------------------------------------
  $added = 0; $failed = 0
  if ($Commit) {
    foreach ($p in $proposed) {
      if ($p.Status -ne 'source' -and $p.Status -ne 'consumer') { continue }
      try {
        [void] $wb.Names.Add($p.Name, $p.RefersTo)
        $added++
      } catch {
        $failed++
        Write-Warning ("Failed to add '{0}': {1}" -f $p.Name, $_.Exception.Message)
      }
    }
    if ($added -gt 0) { $wb.Save() }
  }

  # --- Summary --------------------------------------------------------------
  $byStatus = $proposed | Group-Object Status | Sort-Object Name
  Write-Host ''
  Write-Host '===================== Summary ====================='
  Write-Host ("Titles found      : {0}" -f $proposed.Count)
  foreach ($grp in $byStatus) { Write-Host ("  {0,-10} : {1}" -f $grp.Name, $grp.Count) }
  if ($Commit) {
    Write-Host ("Names added       : {0}" -f $added)
    Write-Host ("Names failed      : {0}" -f $failed)
  } else {
    Write-Host '(dry-run: no names written; re-run with -Commit to apply)'
  }
  Write-Host '==================================================='
}
finally {
  if ($null -ne $wb) { try { $wb.Close($false) } catch { } }
  if ($null -ne $excel) {
    try { $excel.Quit() } catch { }
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel)
  }
}
