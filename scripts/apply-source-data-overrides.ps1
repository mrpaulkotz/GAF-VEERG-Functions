<#
.SYNOPSIS
  Apply source-data overrides to a DUPLICATED VEERG workbook.

.DESCRIPTION
  Reads an overrides JSON file (overrides/<Module>.overrides.json) whose shape
  mirrors the generated source-data JSON, and for every overridden source-data
  table:
    1. Serialises header + rows into an Excel array LAMBDA constant.
    2. Upserts a "<name>_Data_Override" function into a dedicated AFE
       (Excel Labs) module (default: SourceData_Overrides) inside the workbook's
       AFE blob, then republishes so the workbook-scoped defined name
       "SourceData_Overrides.<name>_Data_Override" exists.
    3. Repoints every consuming cell formula from the base dotted call
       "<Module>.<name>_Data(" to "SourceData_Overrides.<name>_Data_Override(".

  The base "_Data" functions are left pristine. This is intended to run against a
  COPY of a workbook (no reset/restore is performed).

.NOTES
  Only MATRIX source-data tables (header + rows) are supported, matching the
  generated source-data JSON contract.
#>
param(
  [Parameter(Mandatory = $true)][string] $WorkbookPath,
  [Parameter(Mandatory = $true)][string] $OverridesPath,
  [string] $OverridesModuleName = 'SourceData_Overrides',
  $ExcelApp = $null,
  [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem

. "$PSScriptRoot\afe-named-functions.ps1"

# Excel caps a defined name's RefersTo at ~8192 chars; a longer override
# constant cannot be published and would leave the repoint dangling.
$script:MaxRefersToLen = 8192

function Format-ExcelArrayValue {
  # Render a single JSON value as an Excel array-literal cell.
  param([AllowNull()] $Value)

  if ($null -eq $Value) { return '""' }
  if ($Value -is [bool]) { return $(if ($Value) { 'TRUE' } else { 'FALSE' }) }

  $inv = [System.Globalization.CultureInfo]::InvariantCulture
  if ($Value -is [double] -or $Value -is [single] -or $Value -is [decimal]) {
    return ([double]$Value).ToString('R', $inv)
  }
  if ($Value -is [long] -or $Value -is [int] -or $Value -is [int16] -or $Value -is [byte]) {
    return ([long]$Value).ToString($inv)
  }

  # String (or anything else) -> quoted, with embedded quotes doubled.
  $s = [string]$Value
  return '"' + ($s -replace '"', '""') + '"'
}

function ConvertTo-LambdaMatrixConstant {
  # Build =LAMBDA(MAKEARRAY(<rows>, <cols>, LAMBDA(r,c, INDEX({...}, r, c))))
  # from a header row and data rows. The array literal is header row followed by
  # the data rows.
  param(
    [Parameter(Mandatory = $true)] [object[]] $Header,
    [Parameter(Mandatory = $true)] [object[]] $Rows
  )

  $cols = $Header.Count
  if ($cols -lt 1) { throw "Override header must have at least one column." }

  $matrixRows = New-Object System.Collections.Generic.List[string]
  $matrixRows.Add((($Header | ForEach-Object { Format-ExcelArrayValue $_ }) -join ', '))

  foreach ($row in $Rows) {
    $cells = @($row)
    if ($cells.Count -ne $cols) {
      throw ("Override row has {0} cells but header has {1} columns: {2}" -f $cells.Count, $cols, (($cells | ForEach-Object { [string]$_ }) -join ', '))
    }
    $matrixRows.Add((($cells | ForEach-Object { Format-ExcelArrayValue $_ }) -join ', '))
  }

  $totalRows = 1 + @($Rows).Count
  $matrix = $matrixRows -join '; '
  return ('=LAMBDA(MAKEARRAY({0}, {1}, LAMBDA(r,c, INDEX({{{2}}}, r, c))))' -f $totalRows, $cols, $matrix)
}

function Get-AfeProjectLocal {
  # Read the AFE JSON blob from a workbook (no COM). Returns
  # { EntryName; Xml; Project } or $null.
  param([string] $Path)

  $zip = [System.IO.Compression.ZipFile]::Open($Path, 'Read')
  try {
    foreach ($entry in $zip.Entries) {
      if ($entry.FullName -notlike 'customXml/item*.xml') { continue }
      $reader = [System.IO.StreamReader]::new($entry.Open())
      try { $xml = $reader.ReadToEnd() } finally { $reader.Dispose() }
      if ($xml -match '<AFEJSONBlob') {
        $b64 = [regex]::Match($xml, '(?s)<AFEJSONBlob[^>]*>(.*)</AFEJSONBlob>').Groups[1].Value
        if ([string]::IsNullOrWhiteSpace($b64)) { continue }
        $json = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($b64))
        return [pscustomobject]@{
          EntryName = $entry.FullName
          Xml       = $xml
          Project   = ($json | ConvertFrom-Json)
        }
      }
    }
  } finally { $zip.Dispose() }
  return $null
}

function Set-AfeOverrideModule {
  # Upsert the override module (path /projects/<ModuleName>) in the workbook's
  # AFE blob, replacing its whole text with $ModuleText.
  param(
    [string] $Path,
    [string] $ModuleName,
    [string] $ModuleText
  )

  $afe = Get-AfeProjectLocal -Path $Path
  if ($null -eq $afe) { throw "Workbook has no Excel Labs (AFE) project: $Path" }

  $modPath = '/projects/' + $ModuleName
  $fileList = New-Object System.Collections.Generic.List[object]
  $found = $false
  foreach ($f in @($afe.Project.files)) {
    if ($f.path -eq $modPath) {
      $f.text = $ModuleText
      $found = $true
    }
    $fileList.Add($f)
  }
  if (-not $found) {
    $fileList.Add([pscustomobject]@{ path = $modPath; text = $ModuleText })
  }

  $afe.Project | Add-Member -NotePropertyName files -NotePropertyValue ($fileList.ToArray()) -Force
  $newJson = $afe.Project | ConvertTo-Json -Depth 100 -Compress
  $newB64 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($newJson))
  $newXml = [regex]::Replace($afe.Xml, '(?s)(<AFEJSONBlob[^>]*>).*?(</AFEJSONBlob>)', ('$1' + $newB64 + '$2'))

  $zip = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Update)
  try {
    $old = $zip.GetEntry($afe.EntryName)
    if ($null -ne $old) { $old.Delete() }
    $newEntry = $zip.CreateEntry($afe.EntryName)
    $writer = [System.IO.StreamWriter]::new($newEntry.Open(), [System.Text.UTF8Encoding]::new($false))
    try { $writer.Write($newXml) } finally { $writer.Dispose() }
  } finally { $zip.Dispose() }
}

function Invoke-OverrideCellRepoint {
  # Rewrite every worksheet cell formula that calls a base "<Module>.<fn>_Data("
  # so it calls "<OverridesModule>.<fn>_Data_Override(" instead. $FnNames are the
  # base data-function names (e.g. SourceData_Dairy_LiveweightCowsAndHeifers_Data).
  param(
    $Workbook,
    [string[]] $FnNames,
    [string] $OverridesModule
  )

  # Precompile a regex per base function name.
  $rewrites = @()
  foreach ($fn in $FnNames) {
    $pattern = '(?i)[A-Za-z_]\w*\.' + [regex]::Escape($fn) + '\s*\('
    $replacement = ('{0}.{1}_Override(' -f $OverridesModule, $fn)
    $rewrites += [pscustomobject]@{ Fn = $fn; Rx = [regex]::new($pattern); Replacement = $replacement }
  }

  $repointed = 0
  $handledArrays = New-Object 'System.Collections.Generic.HashSet[string]'

  foreach ($ws in $Workbook.Worksheets) {
    $ur = $ws.UsedRange
    if ($null -eq $ur) { continue }
    $f = $ur.Formula
    if ($null -eq $f) { continue }
    $rows = $ur.Rows.Count
    $cols = $ur.Columns.Count
    $r0 = $ur.Row; $c0 = $ur.Column
    $single = ($rows -eq 1 -and $cols -eq 1)

    for ($r = 1; $r -le $rows; $r++) {
      for ($c = 1; $c -le $cols; $c++) {
        $val = if ($single) { $f } else { $f[$r, $c] }
        if ($null -eq $val) { continue }
        $s = [string]$val
        if ($s.Length -lt 2 -or $s[0] -ne '=') { continue }
        if ($s -notmatch '_Data\s*\(') { continue }

        $new = $s
        foreach ($rw in $rewrites) { $new = $rw.Rx.Replace($new, $rw.Replacement) }
        if ($new -eq $s) { continue }

        $cell = $ws.Cells.Item($r0 + $r - 1, $c0 + $c - 1)
        if ($cell.HasArray) {
          $ca = $cell.CurrentArray
          $key = ("{0}!{1}" -f $ws.Name, $ca.Address($false, $false))
          if ($handledArrays.Add($key)) {
            $ca.FormulaArray = $new
            $repointed++
          }
        } else {
          $cell.Formula = $new
          $repointed++
        }
      }
    }
  }

  return $repointed
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$WorkbookPath = (Resolve-Path -LiteralPath $WorkbookPath).ProviderPath
$OverridesPath = (Resolve-Path -LiteralPath $OverridesPath).ProviderPath

Write-Host ("Applying source-data overrides") -ForegroundColor Cyan
Write-Host ("  Workbook : {0}" -f $WorkbookPath)
Write-Host ("  Overrides: {0}" -f $OverridesPath)
Write-Host ("  Module   : {0}" -f $OverridesModuleName)

$doc = Get-Content -LiteralPath $OverridesPath -Raw | ConvertFrom-Json
if ($null -eq $doc.PSObject.Properties['Overrides']) {
  throw "Overrides file has no 'Overrides' object: $OverridesPath"
}

# Published base names in the target workbook, used to skip overrides whose base
# source-data table is not present here (so an overrides dir can be applied
# wholesale without touching unrelated workbooks).
$existingNames = Get-WorkbookDefinedNameMap -WorkbookPath $WorkbookPath
$baseDataSuffixes = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
foreach ($k in $existingNames.Keys) {
  $bare = $k
  $dot = $k.LastIndexOf('.')
  if ($dot -ge 0) { $bare = $k.Substring($dot + 1) }
  [void] $baseDataSuffixes.Add($bare)
}

# Build the override module text + collect the base data-function names to repoint.
$funcBlocks = New-Object System.Collections.Generic.List[string]
$fnNames = New-Object System.Collections.Generic.List[string]
$skipped = New-Object System.Collections.Generic.List[string]

foreach ($prop in $doc.Overrides.PSObject.Properties) {
  $name = $prop.Name
  $entry = $prop.Value
  if ($null -eq $entry.PSObject.Properties['header'] -or $null -eq $entry.PSObject.Properties['rows']) {
    throw "Override '$name' must have 'header' and 'rows'."
  }

  $fn = $name + '_Data'
  if (-not $baseDataSuffixes.Contains($fn)) {
    $skipped.Add(("{0} (base function {1} not defined in this workbook)" -f $name, $fn))
    continue
  }

  $header = @($entry.header)
  $rows = @($entry.rows)
  $lambda = ConvertTo-LambdaMatrixConstant -Header $header -Rows $rows

  if ($lambda.Length -gt $script:MaxRefersToLen) {
    $skipped.Add(("{0} (constant {1} > {2} chars)" -f $name, $lambda.Length, $script:MaxRefersToLen))
    continue
  }

  $overrideFn = $fn + '_Override'
  $funcBlocks.Add(("{0}`n  {1};" -f $overrideFn, $lambda))
  $fnNames.Add($fn)
  Write-Host ("  + override: {0}  ({1} rows x {2} cols)" -f $overrideFn, (1 + $rows.Count), $header.Count)
}

foreach ($s in $skipped) { Write-Warning ("Skipped override {0}" -f $s) }

if ($fnNames.Count -eq 0) {
  Write-Warning "No applicable overrides found; nothing to do."
  return
}

$moduleText = "// --- $OverridesModuleName ---`n" +
              "// Source-data overrides generated by apply-source-data-overrides.ps1.`n" +
              "// Each function shadows a base SourceData ..._Data table for this workbook only.`n`n" +
              (($funcBlocks) -join "`n`n") + "`n"

if ($DryRun) {
  Write-Host "`n[DryRun] Override module text:" -ForegroundColor Yellow
  Write-Host $moduleText
  Write-Host ("[DryRun] Would repoint calls for: {0}" -f ($fnNames -join ', '))
  return
}

# 1) Upsert the override module into the AFE blob (file must be closed).
Write-Host "`nWriting override module into AFE blob..."
Set-AfeOverrideModule -Path $WorkbookPath -ModuleName $OverridesModuleName -ModuleText $moduleText

# 2) Republish so the SourceData_Overrides.* defined names exist.
Write-Host "Republishing named functions..."
$rep = Invoke-AfeNamedFunctionRepublish -WorkbookPath $WorkbookPath -ExcelApp $ExcelApp
Write-Host ("  Checked={0}  Republished={1}  Failed={2}  Skipped={3}" -f `
  $rep.Checked, $rep.Republished.Count, $rep.Failed.Count, $rep.Skipped.Count)
foreach ($fail in $rep.Failed) { Write-Warning ("Republish failed: {0}" -f $fail) }

# Confirm each override name was actually published before repointing.
$nameMap = Get-WorkbookDefinedNameMap -WorkbookPath $WorkbookPath
$missing = @()
foreach ($fn in $fnNames) {
  $pub = '{0}.{1}_Override' -f $OverridesModuleName, $fn
  if (-not $nameMap.ContainsKey($pub)) { $missing += $pub }
}
if ($missing.Count -gt 0) {
  throw ("Override names were not published (cannot repoint): {0}" -f ($missing -join ', '))
}

# 3) Repoint consuming cells (own COM session or the caller's Excel app).
Write-Host "Repointing consuming cell formulas..."
$ownExcel = $false
$excel = $ExcelApp
$wb = $null
try {
  if ($null -eq $excel) {
    $excel = New-Object -ComObject Excel.Application
    $excel.Visible = $false
    $ownExcel = $true
  }
  $excel.DisplayAlerts = $false
  $wb = $excel.Workbooks.Open($WorkbookPath)
  $prevCalc = $null
  try { $prevCalc = $excel.Calculation; $excel.Calculation = -4135 } catch { }  # xlCalculationManual

  $count = Invoke-OverrideCellRepoint -Workbook $wb -FnNames $fnNames -OverridesModule $OverridesModuleName

  try { if ($null -ne $prevCalc) { $excel.Calculation = $prevCalc } } catch { }
  $wb.Save()
  $wb.Close($false)
  $wb = $null
  Write-Host ("  Repointed {0} cell/array formula(s)." -f $count) -ForegroundColor Green
} finally {
  if ($null -ne $wb) {
    try { $wb.Close($false) } catch { }
    try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($wb) | Out-Null } catch { }
  }
  if ($ownExcel -and $null -ne $excel) {
    try { $excel.Quit() } catch { }
    try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel) | Out-Null } catch { }
    [GC]::Collect(); [GC]::WaitForPendingFinalizers()
  }
}

Write-Host "`nSource-data overrides applied." -ForegroundColor Cyan
