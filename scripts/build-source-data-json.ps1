<#
.SYNOPSIS
  Converts VEERG SourceData .xlf files into canonical machine-readable JSON artifacts.

.DESCRIPTION
  The .xlf files are the source of truth. They encode tables as named Excel LAMBDA
  definitions. This script parses those LAMBDA grammars and emits one derived JSON
  file per .xlf so downstream consumers do not have to parse the LAMBDA grammar at
  runtime. Both source-data/SourceData_*.xlf files and module-level
  <Module>_SourceData.xlf files are processed.

  Each table is owned by a "<Prefix>_Data" LAMBDA of the form:
    <Prefix>_Data =LAMBDA(MAKEARRAY(<rows>, <cols>, LAMBDA(r,c, INDEX({ <matrix> }, r, c))))
  where <matrix> uses ';' to separate rows and ',' to separate cells. The first matrix
  row is the header. Strings are double-quoted with "" as an escaped quote. Scalar
  "<Prefix>_Data =LAMBDA(0.08)" definitions (no MAKEARRAY) are not tables and are skipped.
  <Prefix> may be "SourceData_*" or a module-specific prefix (e.g. "Fuel_*").

  Metadata for a table lives in sibling LAMBDAs sharing the same <Prefix>:
    <Prefix>_Title, <Prefix>_Variable, <Prefix>_Description, <Prefix>_Unit,
    <Prefix>_Source, <Prefix>_Variation
  Metadata values may be wrapped in one or two parentheses: =LAMBDA("x") or =LAMBDA(("x")).

  Sentinel cell values ("NO", "n/a", "na", "-") are quoted in the source and are
  preserved verbatim as strings. Numeric cells are emitted as JSON numbers; everything
  else stays a string.

.PARAMETER RepoRoot
  Repository root. Defaults to the parent of the scripts/ folder.

.PARAMETER XlfPath
  Optional path to a single .xlf file. When omitted, every source-data/SourceData_*.xlf
  file plus the known module-level <Module>_SourceData.xlf files are processed.

.PARAMETER DryRun
  Parse and validate but do not write any JSON files. Prints what would be written.

.OUTPUTS
  One "<basename>.sourcedata.json" written to the generated-sourcedata/ directory
  at the repository root.
#>
param(
  [string] $RepoRoot = $(Split-Path $PSScriptRoot -Parent),
  [string] $XlfPath,
  [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$schemaVersion = 1

function Convert-CellToken {
  <#
    Converts a single raw matrix cell into its typed value.
    Quoted strings (IsString) are kept verbatim. Bare tokens are parsed as numbers
    when they look numeric, otherwise kept as a trimmed string.
  #>
  param(
    [AllowEmptyString()] [string] $Raw,
    [bool] $IsString
  )

  if ($IsString) {
    return $Raw
  }

  $t = $Raw.Trim()
  if ($t -eq '') {
    return ''
  }
  if ($t -match '^-?\d+$') {
    return [long]$t
  }
  if ($t -match '^-?(?:\d+\.?\d*|\.\d+)(?:[eE][+-]?\d+)?$') {
    return [double]$t
  }
  return $t
}

function ConvertFrom-LambdaMatrix {
  <#
    Quote-aware tokenizer for an Excel array literal body (the text between { and }).
    Rows are separated by ';' and cells by ',', but separators inside double-quoted
    strings are literal. "" is an escaped double-quote inside a string.
    Returns a List of rows, each row a List of typed cell values.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string] $Matrix
  )

  $rows = New-Object System.Collections.Generic.List[object]
  $row = New-Object System.Collections.Generic.List[object]
  $sb = [System.Text.StringBuilder]::new()
  $inQuote = $false
  $cellIsString = $false
  $stringClosed = $false

  $len = $Matrix.Length
  $i = 0

  while ($i -lt $len) {
    $ch = $Matrix[$i]

    if ($inQuote) {
      if ($ch -eq '"') {
        if (($i + 1) -lt $len -and $Matrix[$i + 1] -eq '"') {
          [void]$sb.Append('"')
          $i += 2
          continue
        }
        $inQuote = $false
        $stringClosed = $true
        $i++
        continue
      }
      [void]$sb.Append($ch)
      $i++
      continue
    }

    switch ($ch) {
      '"' {
        # Opening quote of a string cell. Discard any inter-token whitespace
        # accumulated before the quote so only the quoted content is captured.
        $cellIsString = $true
        $sb.Clear() | Out-Null
        $inQuote = $true
        $i++
      }
      ',' {
        $value = Convert-CellToken -Raw $sb.ToString() -IsString $cellIsString
        [void]$row.Add($value)
        $sb.Clear() | Out-Null
        $cellIsString = $false
        $stringClosed = $false
        $i++
      }
      ';' {
        $value = Convert-CellToken -Raw $sb.ToString() -IsString $cellIsString
        [void]$row.Add($value)
        $sb.Clear() | Out-Null
        $cellIsString = $false
        $stringClosed = $false
        $rows.Add($row)
        $row = New-Object System.Collections.Generic.List[object]
        $i++
      }
      default {
        # Ignore trailing whitespace that follows a closed string cell.
        if (-not $stringClosed) {
          [void]$sb.Append($ch)
        }
        $i++
      }
    }
  }

  # Flush the trailing cell / row (the matrix body has no trailing ';').
  $value = Convert-CellToken -Raw $sb.ToString() -IsString $cellIsString
  $trailingHasContent = $cellIsString -or ($sb.ToString().Trim() -ne '')
  if ($trailingHasContent -or $row.Count -gt 0) {
    [void]$row.Add($value)
  }
  if ($row.Count -gt 0) {
    $rows.Add($row)
  }

  return , $rows
}

function Get-TableMetadata {
  <#
    Parses all <Prefix>_(Title|Variable|Unit|Source|Variation) string LAMBDAs from the
    file content into a hashtable keyed by <Prefix>.
  #>
  param(
    [Parameter(Mandatory = $true)]
    [string] $Content
  )

  $meta = @{}
  # Prefix is generic (SourceData_* under source-data/, or <Module>_* alongside a module).
  # The metadata value may be wrapped in one or two parentheses: =LAMBDA("x") or =LAMBDA(("x")).
  $pattern = '(?ms)^[ \t]*(?<prefix>[A-Za-z][A-Za-z0-9_]*?)_(?<kind>Title|Variable|Description|Unit|Source|Variation)[ \t\r\n]*=\s*LAMBDA\(\s*\(?\s*"(?<val>(?:[^"]|"")*)"\s*\)?\s*\)'
  foreach ($m in [regex]::Matches($Content, $pattern)) {
    $prefix = $m.Groups['prefix'].Value
    $kind = $m.Groups['kind'].Value
    $val = $m.Groups['val'].Value.Replace('""', '"')
    if (-not $meta.ContainsKey($prefix)) {
      $meta[$prefix] = @{}
    }
    $meta[$prefix][$kind] = $val
  }

  return $meta
}

function ConvertTo-SourceDataModel {
  <#
    Parses a single .xlf file's content into the JSON model object.
  #>
  param(
    [Parameter(Mandatory = $true)] [string] $Content,
    [Parameter(Mandatory = $true)] [string] $SourceFileName
  )

  $metadata = Get-TableMetadata -Content $Content

  $tables = New-Object System.Collections.Generic.List[object]
  $dataPattern = '(?sm)^[ \t]*(?<prefix>[A-Za-z][A-Za-z0-9_]*?)_Data[ \t\r\n]*=\s*LAMBDA\(\s*MAKEARRAY\(\s*(?<rows>\d+)\s*,\s*(?<cols>\d+)\s*,\s*LAMBDA\(\s*r\s*,\s*c\s*,\s*INDEX\(\s*\{(?<matrix>[^{}]*)\}'

  foreach ($m in [regex]::Matches($Content, $dataPattern)) {
    $prefix = $m.Groups['prefix'].Value
    $declaredRows = [int]$m.Groups['rows'].Value
    $declaredCols = [int]$m.Groups['cols'].Value
    $matrix = $m.Groups['matrix'].Value

    $parsed = ConvertFrom-LambdaMatrix -Matrix $matrix
    if ($parsed.Count -lt 1) {
      Write-Warning "Table '$prefix' in '$SourceFileName' produced no rows; skipping."
      $script:ValidationWarningCount++
      continue
    }

    $header = @($parsed[0] | ForEach-Object { [string]$_ })
    $dataRows = New-Object System.Collections.Generic.List[object]
    for ($r = 1; $r -lt $parsed.Count; $r++) {
      $dataRows.Add(@($parsed[$r]))
    }

    # Round-trip integrity: the parsed matrix (header + data rows) should match the
    # dimensions declared in MAKEARRAY(<rows>, <cols>). A mismatch indicates the source
    # .xlf is internally inconsistent (e.g. a stale row/column count). Surface it as a
    # warning and emit the table with its actual parsed data rather than aborting the
    # whole build.
    if ($parsed.Count -ne $declaredRows) {
      Write-Warning "Table '$prefix' in '$SourceFileName': parsed $($parsed.Count) matrix rows but MAKEARRAY declares $declaredRows."
      $script:ValidationWarningCount++
    }
    if ($header.Count -ne $declaredCols) {
      Write-Warning "Table '$prefix' in '$SourceFileName': header has $($header.Count) columns but MAKEARRAY declares $declaredCols."
      $script:ValidationWarningCount++
    }
    for ($r = 0; $r -lt $parsed.Count; $r++) {
      if ($parsed[$r].Count -ne $header.Count) {
        Write-Warning "Table '$prefix' in '$SourceFileName': matrix row $($r + 1) has $($parsed[$r].Count) cells but header has $($header.Count)."
        $script:ValidationWarningCount++
      }
    }

    $meta = if ($metadata.ContainsKey($prefix)) { $metadata[$prefix] } else { @{} }
    $getMeta = {
      param($key)
      if ($meta.ContainsKey($key)) { $meta[$key] } else { '' }
    }

    $tables.Add([ordered]@{
        name        = $prefix
        title       = (& $getMeta 'Title')
        variable    = (& $getMeta 'Variable')
        description = (& $getMeta 'Description')
        unit        = (& $getMeta 'Unit')
        source      = (& $getMeta 'Source')
        variation   = (& $getMeta 'Variation')
        header      = $header
        rows        = $dataRows
      })
  }

  $model = [ordered]@{
    generatedFrom = $SourceFileName
    generatedAt   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    schemaVersion = $schemaVersion
    tables        = $tables
  }

  return $model
}

function ConvertTo-CleanJson {
  <#
    Windows PowerShell 5.1 ConvertTo-Json escapes <, >, & and ' as \uXXXX. The source
    headers contain '<' and '>' (e.g. "Bull < 1"); restore them for readable output.
  #>
  param(
    [Parameter(Mandatory = $true)] $InputObject
  )

  $json = $InputObject | ConvertTo-Json -Depth 50
  $json = $json -replace '\\u003c', '<'
  $json = $json -replace '\\u003e', '>'
  $json = $json -replace '\\u0026', '&'
  $json = $json -replace '\\u0027', "'"
  return $json
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$sourceDataDir = Join-Path $RepoRoot 'source-data'

$xlfFiles = @()
if (-not [string]::IsNullOrWhiteSpace($XlfPath)) {
  $xlfFiles = @((Resolve-Path -LiteralPath $XlfPath).Path)
}
else {
  if (-not (Test-Path -LiteralPath $sourceDataDir)) {
    throw "Source-data directory not found: $sourceDataDir"
  }
  $xlfFiles = @(Get-ChildItem -LiteralPath $sourceDataDir -File -Filter 'SourceData_*.xlf' |
    Sort-Object FullName |
    ForEach-Object { $_.FullName })

  # Additional module source-data files named "<Module>_SourceData.xlf" that live
  # alongside their module rather than under source-data/.
  $additionalRelPaths = @(
    'AgriculturalResidueManagement\AgResidue_SourceData.xlf'
    'Common\Common_SourceData.xlf'
    'Common\CommonCropping_SourceData.xlf'
    'Common\CommonLivestock_SourceData.xlf'
    'Electricity\Electricity_SourceData.xlf'
    'Fertiliser\Fertiliser_SourceData.xlf'
    'Fuel\Fuel_SourceData.xlf'
    'Refrigerants\Refrigerants_SourceData.xlf'
    'RiceCultivation\RiceCultivation_SourceData.xlf'
    'Scope3\Scope3_SourceData.xlf'
    'WasteSolid\WasteSolid_SourceData.xlf'
    'Wastewater\Wastewater_SourceData.xlf'
  )
  foreach ($rel in $additionalRelPaths) {
    $full = Join-Path $RepoRoot $rel
    if (Test-Path -LiteralPath $full) {
      $xlfFiles += (Resolve-Path -LiteralPath $full).Path
    }
    else {
      Write-Warning "SourceData file not found (skipped): $rel"
    }
  }
}

if ($xlfFiles.Count -eq 0) {
  Write-Host 'No SourceData_*.xlf files found. Nothing to do.'
  return
}

$mode = if ($DryRun) { '[DryRun] ' } else { '' }
Write-Host ("{0}Building source-data JSON for {1} file(s)..." -f $mode, $xlfFiles.Count)

$outputDir = Join-Path $RepoRoot 'generated-sourcedata'
if (-not $DryRun -and -not (Test-Path -LiteralPath $outputDir)) {
  New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$script:ValidationWarningCount = 0

foreach ($file in $xlfFiles) {
  $fileName = Split-Path $file -Leaf
  $content = Get-Content -LiteralPath $file -Raw

  $model = ConvertTo-SourceDataModel -Content $content -SourceFileName $fileName
  $json = ConvertTo-CleanJson -InputObject $model

  $outPath = Join-Path $outputDir ([System.IO.Path]::GetFileNameWithoutExtension($file) + '.sourcedata.json')
  $outName = Split-Path $outPath -Leaf
  $tableCount = $model.tables.Count

  if ($DryRun) {
    Write-Host ("  {0} -> {1} ({2} table(s)) [not written]" -f $fileName, $outName, $tableCount)
  }
  else {
    [System.IO.File]::WriteAllText($outPath, $json, (New-Object System.Text.UTF8Encoding($false)))
    Write-Host ("  {0} -> {1} ({2} table(s))" -f $fileName, $outName, $tableCount)
  }
}

if ($script:ValidationWarningCount -gt 0) {
  Write-Host ("{0}Done with {1} validation warning(s) (see above)." -f $mode, $script:ValidationWarningCount)
}
else {
  Write-Host ("{0}Done." -f $mode)
}
