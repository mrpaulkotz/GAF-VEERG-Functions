<#
.SYNOPSIS
  Produces a 'clean' copy of a built enterprise workbook: blanks the example/
  placeholder content of every input cell and input table field (as catalogued
  by InputFields/Enterprise_<Id>_InputFields.json), while leaving every formula
  untouched - including formulas that happen to live in an input cell/column
  (e.g. CanOverwriteFormula defaults, Result-table calculated columns).

.DESCRIPTION
  For each InputCell / InputTable field named in the enterprise's generated
  (override-merged) InputFields JSON:
    - Cells/table-column cells that carry a live formula are left completely
      alone (HasFormula = true skips clearing, regardless of style).
    - Everything else is only cleared if the cell's own named style starts with
      'Input' (the same authoritative convention build-input-fields-json.ps1
      uses to tell editable content from fixed labels/identities) - so a fixed
      row-identity column (Content normal, etc.) is never touched even though
      its table is in scope.
  Table row COUNT is never changed - only cell VALUES are cleared, so free-add
  tables keep whatever number of example rows they shipped with.

  Fields marked ExcelExcluded in the InputFields JSON (web-app-only, no Excel
  backing) are skipped entirely - there is nothing on the sheet to clean.

  Always writes a SEPARATE output workbook; the source (already-built) enterprise
  workbook is never modified.

.PARAMETER EnterpriseId
  e.g. 'PastureBeef' -> resolves Enterprises\Enterprise_PastureBeef.json and
  InputFields\Enterprise_PastureBeef_InputFields.json. If neither this nor
  -ConfigPath is given, every Enterprises\Enterprise_*.json is cleaned in turn.

.PARAMETER ConfigPath
  Full path to a specific Enterprise_*.json (alternative to -EnterpriseId).

.PARAMETER SourcePath
  Override: path to the built workbook to clean. Defaults to
  Excel\Enterprises\<enterprise.outputWorkbook> from the config.

.PARAMETER OutputPath
  Override: path to write the cleaned copy to. Defaults to the source file name
  with '_Clean' inserted before its '_WIP' version suffix (or before the
  extension if no '_WIP' suffix is present).

.PARAMETER DryRun
  Report what would be cleared without writing anything.
#>
param(
  [Parameter(Position = 0)]
  [string] $EnterpriseId,
  [string] $RepoRoot,
  [string] $ConfigPath,
  [string] $SourcePath,
  [string] $OutputPath,
  [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($RepoRoot)) { $RepoRoot = Split-Path $PSScriptRoot -Parent }

# Shared pre-flight file-accessibility guard (Assert-FilesAccessible).
. (Join-Path $PSScriptRoot 'file-access.ps1')

# ---------------------------------------------------------------------------
# Auto-discovery: with neither -ConfigPath nor -EnterpriseId, clean every
# enterprise config in turn by re-invoking this script once per config.
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($ConfigPath) -and [string]::IsNullOrWhiteSpace($EnterpriseId)) {
  $enterprisesDir = Join-Path $RepoRoot 'Enterprises'
  if (-not (Test-Path -LiteralPath $enterprisesDir)) { throw "Enterprises directory not found: $enterprisesDir" }
  $discovered = @(Get-ChildItem -LiteralPath $enterprisesDir -File -Filter 'Enterprise_*.json' | Sort-Object Name)
  if ($discovered.Count -eq 0) { throw "No Enterprise_*.json configs found in $enterprisesDir" }
  Write-Host ("Auto-discovered {0} enterprise config(s) in {1}." -f $discovered.Count, $enterprisesDir)
  foreach ($cfg in $discovered) {
    Write-Host ''
    Write-Host ("=== Cleaning {0} ===" -f $cfg.Name)
    & $PSCommandPath -RepoRoot $RepoRoot -ConfigPath $cfg.FullName -DryRun:$DryRun
  }
  return
}

function Resolve-EnterpriseConfigPath {
  param([string] $RepoRoot, [string] $ConfigPath, [string] $EnterpriseId)
  if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config not found: $ConfigPath" }
    return (Resolve-Path -LiteralPath $ConfigPath).Path
  }
  if (-not [string]::IsNullOrWhiteSpace($EnterpriseId)) {
    $p = Join-Path $RepoRoot ("Enterprises\Enterprise_{0}.json" -f $EnterpriseId)
    if (-not (Test-Path -LiteralPath $p)) { throw "Config not found for enterprise '$EnterpriseId': $p" }
    return (Resolve-Path -LiteralPath $p).Path
  }
  throw "Provide -ConfigPath or -EnterpriseId."
}

$configPathResolved = Resolve-EnterpriseConfigPath -RepoRoot $RepoRoot -ConfigPath $ConfigPath -EnterpriseId $EnterpriseId
$config = Get-Content -Raw -LiteralPath $configPathResolved | ConvertFrom-Json
$enterpriseIdResolved = [string] $config.enterprise.id

$excelDir = Join-Path $RepoRoot 'Excel'
if ([string]::IsNullOrWhiteSpace($SourcePath)) {
  $SourcePath = Join-Path (Join-Path $excelDir 'Enterprises') ([string] $config.enterprise.outputWorkbook)
}
if (-not (Test-Path -LiteralPath $SourcePath)) {
  throw "Enterprise workbook not found (build it first with build-enterprise): $SourcePath"
}
$SourcePath = (Resolve-Path -LiteralPath $SourcePath).Path

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  $srcDir = Split-Path -Parent $SourcePath
  $srcName = Split-Path -Leaf $SourcePath
  if ($srcName -match '(?i)_WIP_v\d+\.xlsx$') {
    $cleanName = [regex]::Replace($srcName, '(?i)(_WIP_v\d+\.xlsx)$', '_Clean$1')
  } else {
    $cleanName = [System.IO.Path]::GetFileNameWithoutExtension($srcName) + '_Clean' + [System.IO.Path]::GetExtension($srcName)
  }
  $OutputPath = Join-Path $srcDir $cleanName
}

$inputFieldsPath = Join-Path $RepoRoot ("InputFields\Enterprise_{0}_InputFields.json" -f $enterpriseIdResolved)
if (-not (Test-Path -LiteralPath $inputFieldsPath)) {
  throw "InputFields JSON not found (run build:input-fields / build-enterprise first): $inputFieldsPath"
}
$fields = Get-Content -Raw -LiteralPath $inputFieldsPath | ConvertFrom-Json

Write-Host ("Enterprise  : {0}" -f $config.enterprise.name)
Write-Host ("Source      : {0}" -f $SourcePath)
Write-Host ("Output      : {0}" -f $OutputPath)
Write-Host ("InputFields : {0}" -f $inputFieldsPath)
Write-Host ("Mode        : {0}" -f $(if ($DryRun) { 'DRY RUN' } else { 'CLEAN' }))
Write-Host ''

if (-not $DryRun) {
  Assert-FilesAccessible -RequiredReadPaths @($SourcePath) -WritePaths @($OutputPath)
  Copy-Item -LiteralPath $SourcePath -Destination $OutputPath -Force
}
$workBasis = if ($DryRun) { $SourcePath } else { $OutputPath }

function New-ExcelApp {
  $x = New-Object -ComObject Excel.Application
  $x.Visible = $false
  $x.DisplayAlerts = $false
  $x.ScreenUpdating = $false
  $x.AskToUpdateLinks = $false
  return $x
}

function Find-ListObject {
  param($Workbook, [string] $Name)
  foreach ($ws in $Workbook.Worksheets) {
    foreach ($lo in $ws.ListObjects) {
      if ([string] $lo.Name -eq $Name) { return $lo }
    }
  }
  return $null
}

# Clear one cell unless it carries a live formula (formulas are always left
# intact, even inside an input cell/column - e.g. CanOverwriteFormula defaults
# and calculated Result-table columns). Cell style is NOT used as a signal here:
# spot-checking the built workbooks showed genuinely editable fields (e.g.
# Table_Input_LivestockSales's SaleDate/HeadSold) sharing the same 'Content
# normal' style as true fixed labels, so style cannot reliably tell them apart.
# The caller is responsible for never passing an identity/label-column cell in
# the first place (see the column-1 skip logic below).
# Returns 'Cleared' or 'KeptFormula'.
function Clear-IfPlaceholder {
  param($Cell, [bool] $DryRun)
  $hasFormula = $true
  try { $hasFormula = [bool] $Cell.HasFormula } catch { $hasFormula = $true }
  if ($hasFormula) { return 'KeptFormula' }

  if (-not $DryRun) { try { $Cell.ClearContents() | Out-Null } catch { } }
  return 'Cleared'
}

$excel = $null
$cleared = 0; $keptFormula = 0; $skippedIdentity = 0
$missingCells = New-Object System.Collections.Generic.List[string]
$missingTables = New-Object System.Collections.Generic.List[string]

try {
  $excel = New-ExcelApp
  $wb = $excel.Workbooks.Open($workBasis, 0, [bool] $DryRun)

  foreach ($cell in @($fields.InputCells)) {
    $exProp = $cell.PSObject.Properties['ExcelExcluded']
    if ($null -ne $exProp -and $exProp.Value -eq $true) { continue }
    $cellName = [string] $cell.CellName
    if ([string]::IsNullOrWhiteSpace($cellName)) { continue }

    $nameObj = $null
    try { $nameObj = $wb.Names.Item($cellName) } catch { $nameObj = $null }
    if ($null -eq $nameObj) { $missingCells.Add($cellName); continue }
    $range = $null
    try { $range = $nameObj.RefersToRange } catch { $range = $null }
    if ($null -eq $range) { $missingCells.Add($cellName); continue }

    foreach ($c in $range.Cells) {
      switch (Clear-IfPlaceholder -Cell $c -DryRun ([bool] $DryRun)) {
        'Cleared' { $cleared++ }
        'KeptFormula' { $keptFormula++ }
      }
    }
  }

  foreach ($tbl in @($fields.InputTables)) {
    $exProp = $tbl.PSObject.Properties['ExcelExcluded']
    if ($null -ne $exProp -and $exProp.Value -eq $true) { continue }
    $tableName = [string] $tbl.TableName
    if ([string]::IsNullOrWhiteSpace($tableName)) { continue }

    # Column 1 of the table's range is an identity/label column - never data
    # to clear - in two cases: a ListObject the generator flagged FixedRows
    # (e.g. DataQuality's row identity, RECSurrendered's Source), or a
    # ColsToRows named-range table, where the axes are transposed so column 1
    # holds the field/period label instead of one of the real data columns
    # (e.g. X_Table_PastureBeef_Head_Method1's per-period row labels).
    $skipFirstColumn = $false
    $frProp = $tbl.PSObject.Properties['FixedRows']
    if ($null -ne $frProp -and $frProp.Value -eq $true) { $skipFirstColumn = $true }
    $mtProp = $tbl.PSObject.Properties['MatrixType']
    if ($null -ne $mtProp -and [string] $mtProp.Value -eq 'ColsToRows') { $skipFirstColumn = $true }

    $lo = Find-ListObject -Workbook $wb -Name $tableName
    if ($null -ne $lo) {
      $cols = @($lo.ListColumns)
      for ($i = 0; $i -lt $cols.Count; $i++) {
        if ($skipFirstColumn -and $i -eq 0) { $skippedIdentity++; continue }
        $colBody = $null
        try { $colBody = $cols[$i].DataBodyRange } catch { $colBody = $null }
        if ($null -eq $colBody) { continue }   # header-only column: nothing to clean
        foreach ($c in $colBody.Cells) {
          switch (Clear-IfPlaceholder -Cell $c -DryRun ([bool] $DryRun)) {
            'Cleared' { $cleared++ }
            'KeptFormula' { $keptFormula++ }
          }
        }
      }
      continue
    }

    # Not a ListObject: some X_Table_* input tables are plain defined-name
    # ranges instead (build-input-fields-json.ps1's Get-NamedRangeTables).
    # Row 1 of the named range is always the header; data starts at row 2.
    $nameObj = $null
    try { $nameObj = $wb.Names.Item($tableName) } catch { $nameObj = $null }
    $range = $null
    if ($null -ne $nameObj) { try { $range = $nameObj.RefersToRange } catch { $range = $null } }
    if ($null -eq $range) { $missingTables.Add($tableName); continue }
    $rowCount = 0; $colCount = 0
    try { $rowCount = [int] $range.Rows.Count; $colCount = [int] $range.Columns.Count } catch { }
    if ($rowCount -lt 2 -or $colCount -lt 1) { continue }
    $firstDataCol = if ($skipFirstColumn) { 2 } else { 1 }
    if ($skipFirstColumn) { $skippedIdentity += ($rowCount - 1) }
    if ($firstDataCol -gt $colCount) { continue }
    $dataRange = $null
    try { $dataRange = $range.Worksheet.Range($range.Cells.Item(2, $firstDataCol), $range.Cells.Item($rowCount, $colCount)) } catch { $dataRange = $null }
    if ($null -eq $dataRange) { continue }
    foreach ($c in $dataRange.Cells) {
      switch (Clear-IfPlaceholder -Cell $c -DryRun ([bool] $DryRun)) {
        'Cleared' { $cleared++ }
        'KeptFormula' { $keptFormula++ }
      }
    }
  }

  if (-not $DryRun) {
    $wb.Save()
  }
  $wb.Close($false)
} finally {
  if ($null -ne $excel) { $excel.Quit() }
  [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel)
  [System.GC]::Collect()
  [System.GC]::WaitForPendingFinalizers()
}

Write-Host ("Cells/columns cleared      : {0}" -f $cleared) -ForegroundColor Green
Write-Host ("Kept (had a formula)       : {0}" -f $keptFormula) -ForegroundColor DarkGray
Write-Host ("Skipped (identity column)  : {0}" -f $skippedIdentity) -ForegroundColor DarkGray
if ($missingCells.Count -gt 0) {
  Write-Warning ("{0} InputCell(s) named in the InputFields JSON were not found in the workbook:`n{1}" -f $missingCells.Count, ($missingCells -join "`n"))
}
if ($missingTables.Count -gt 0) {
  Write-Warning ("{0} InputTable(s) named in the InputFields JSON were not found in the workbook:`n{1}" -f $missingTables.Count, ($missingTables -join "`n"))
}
if ($DryRun) {
  Write-Host ''
  Write-Host 'DRY RUN: no file was written.'
} else {
  Write-Host ''
  Write-Host ("Wrote clean workbook: {0}" -f $OutputPath) -ForegroundColor Green
}
