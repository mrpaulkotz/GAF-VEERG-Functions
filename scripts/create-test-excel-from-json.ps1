param(
  [string] $RepoRoot = $(Split-Path $PSScriptRoot -Parent),
  [string] $ExcelSearchRoot,
  [string] $ConfigPath,
  [string] $TestID,
  [string] $Suffix = '_test',
  [double] $DifferenceTolerance = 0.00001
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($ExcelSearchRoot)) {
  $ExcelSearchRoot = Join-Path $RepoRoot 'Excel'
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
  $ConfigPath = Join-Path $RepoRoot 'Test\Test.json'
}

$resolvedExcelRoot = (Resolve-Path -LiteralPath $ExcelSearchRoot).Path
$resolvedConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path

if ([string]::IsNullOrWhiteSpace($TestID)) {
  throw "TestID is required. Example: npm run create-test-excel -- -TestID 3_1_Enteric_Feedlot"
}

function Find-TestEntryById {
  param(
    [Parameter(Mandatory = $true)]
    [AllowNull()]
    [object] $Node,

    [Parameter(Mandatory = $true)]
    [string] $Id
  )

  if ($null -eq $Node) {
    return $null
  }

  $properties = @($Node.PSObject.Properties)
  if ($properties.Count -eq 0) {
    return $null
  }

  $propNames = @($properties.Name)
  if ($propNames -contains 'TestID' -and [string] $Node.TestID -eq $Id) {
    return $Node
  }

  foreach ($property in $properties) {
    $found = Find-TestEntryById -Node $property.Value -Id $Id
    if ($null -ne $found) {
      return $found
    }
  }

  return $null
}

$configRaw = Get-Content -LiteralPath $resolvedConfigPath -Raw
$configObject = $configRaw | ConvertFrom-Json
$testEntry = Find-TestEntryById -Node $configObject -Id $TestID

if ($null -eq $testEntry) {
  throw "No test entry found in '$resolvedConfigPath' with TestID '$TestID'."
}

$nameContains = [string] $testEntry.TestExcelFile
if ([string]::IsNullOrWhiteSpace($nameContains)) {
  throw "Test entry '$TestID' in '$resolvedConfigPath' is missing TestExcelFile."
}

$testInputFile = [string] $testEntry.TestInputFile
if ([string]::IsNullOrWhiteSpace($testInputFile)) {
  throw "Test entry '$TestID' in '$resolvedConfigPath' is missing TestInputFile."
}

$testResultsFile = [string] $testEntry.TestResultsFile
if ([string]::IsNullOrWhiteSpace($testResultsFile)) {
  throw "Test entry '$TestID' in '$resolvedConfigPath' is missing TestResultsFile."
}

$configDirectory = Split-Path -Parent $resolvedConfigPath
$jsonPath = if ([System.IO.Path]::IsPathRooted($testInputFile)) {
  $testInputFile
} else {
  Join-Path $configDirectory $testInputFile
}

$resultsPath = if ([System.IO.Path]::IsPathRooted($testResultsFile)) {
  $testResultsFile
} else {
  Join-Path $configDirectory $testResultsFile
}

$resolvedJsonPath = (Resolve-Path -LiteralPath $jsonPath).Path
$jsonRaw = Get-Content -LiteralPath $resolvedJsonPath -Raw
$jsonObject = $jsonRaw | ConvertFrom-Json
$jsonProperties = @($jsonObject.PSObject.Properties)

$resolvedResultsPath = (Resolve-Path -LiteralPath $resultsPath).Path
$resultsRaw = Get-Content -LiteralPath $resolvedResultsPath -Raw
$resultsObject = $resultsRaw | ConvertFrom-Json
$resultsProperties = @($resultsObject.PSObject.Properties)

function Convert-ToNullableDouble {
  param(
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [object] $Value
  )

  if ($null -eq $Value) {
    return $null
  }

  if ($Value -is [byte] -or $Value -is [sbyte] -or $Value -is [int16] -or $Value -is [uint16] -or $Value -is [int32] -or $Value -is [uint32] -or $Value -is [int64] -or $Value -is [uint64] -or $Value -is [single] -or $Value -is [double] -or $Value -is [decimal]) {
    return [double] $Value
  }

  $text = [string] $Value
  $parsed = 0.0
  if ([double]::TryParse($text, [System.Globalization.NumberStyles]::Float -bor [System.Globalization.NumberStyles]::AllowThousands, [System.Globalization.CultureInfo]::InvariantCulture, [ref] $parsed)) {
    return $parsed
  }
  if ([double]::TryParse($text, [ref] $parsed)) {
    return $parsed
  }

  return $null
}

$excelFiles = @(
  Get-ChildItem -Path $resolvedExcelRoot -File -Recurse |
    Where-Object {
      $_.Name -notlike '~$*' -and
      $_.Name -match [regex]::Escape($nameContains) -and
      @('.xlsx', '.xlsm', '.xls') -contains $_.Extension.ToLowerInvariant()
    } |
    Sort-Object LastWriteTime -Descending
)

if ($excelFiles.Count -eq 0) {
  throw "No Excel files found under '$resolvedExcelRoot' with '$nameContains' in the filename."
}

$preferredExcelFiles = @(
  $excelFiles |
    Where-Object {
      $_.BaseName -notmatch '(?i)_expanded(?:_tmp\d*)?$' -and
      $_.BaseName -notmatch '(?i)_test(?:_\d{4}_\d{8})?(?:_\d+)?$'
    }
)

$sourceCandidates = if ($preferredExcelFiles.Count -gt 0) { $preferredExcelFiles } else { $excelFiles }

$sourceFile = $sourceCandidates[0]
$baseName = [System.IO.Path]::GetFileNameWithoutExtension($sourceFile.Name)
$ext = $sourceFile.Extension
$timestamp = Get-Date -Format 'HHmm_yyyyMMdd'
$testExcelDirectory = Join-Path $resolvedExcelRoot 'TestExcel'
if (-not (Test-Path -LiteralPath $testExcelDirectory)) {
  [void] (New-Item -ItemType Directory -Path $testExcelDirectory)
}

$targetPath = Join-Path $testExcelDirectory ($baseName + $Suffix + '_' + $timestamp + $ext)
$counter = 2
while (Test-Path -LiteralPath $targetPath) {
  $targetPath = Join-Path $testExcelDirectory ($baseName + $Suffix + '_' + $timestamp + '_' + $counter + $ext)
  $counter++
}

Copy-Item -LiteralPath $sourceFile.FullName -Destination $targetPath

$excel = $null
$workbook = $null
$updated = 0
$updatedInputTableCells = 0
$missing = New-Object System.Collections.Generic.List[string]
$failed = New-Object System.Collections.Generic.List[string]
$failedDetails = New-Object System.Collections.Generic.List[string]
$tableMissing = New-Object System.Collections.Generic.List[string]
$tableFailed = New-Object System.Collections.Generic.List[string]
$tableFailedDetails = New-Object System.Collections.Generic.List[string]
$resultsMissing = New-Object System.Collections.Generic.List[string]
$resultsNonNumeric = New-Object System.Collections.Generic.List[string]
$resultDiffs = New-Object System.Collections.Generic.List[psobject]
$resultFailCount = 0
$resultPassCount = 0

function Get-WorkbookNameEntry {
  param(
    [Parameter(Mandatory = $true)]
    [object] $Workbook,

    [Parameter(Mandatory = $true)]
    [string[]] $CandidateNames,

    [Parameter(Mandatory = $false)]
    [ref] $MatchedName
  )

  $allNames = New-Object System.Collections.Generic.List[object]
  foreach ($n in $Workbook.Names) {
    [void] $allNames.Add($n)
  }
  foreach ($candidate in @($CandidateNames)) {
    $candidateText = [string] $candidate
    if ([string]::IsNullOrWhiteSpace($candidateText)) {
      continue
    }

    foreach ($entry in $allNames) {
      if ($null -eq $entry) {
        continue
      }

      $nameLocal = [string] $entry.NameLocal
      $shortName = $nameLocal
      $bangIndex = $nameLocal.LastIndexOf('!')
      if ($bangIndex -ge 0 -and $bangIndex -lt ($nameLocal.Length - 1)) {
        $shortName = $nameLocal.Substring($bangIndex + 1)
      }

      if ([string]::Equals($shortName, $candidateText, [System.StringComparison]::OrdinalIgnoreCase)) {
        if ($null -ne $MatchedName) {
          $MatchedName.Value = $shortName
        }
        return $entry
      }
    }
  }

  return $null
}

function Get-WorkbookTableRange {
  param(
    [Parameter(Mandatory = $true)]
    [object] $Workbook,

    [Parameter(Mandatory = $true)]
    [string] $TableName
  )

  if ([string]::IsNullOrWhiteSpace($TableName)) {
    return $null
  }

  foreach ($worksheet in @($Workbook.Worksheets)) {
    if ($null -eq $worksheet) {
      continue
    }

    $listObject = $null
    try {
      $listObject = $worksheet.ListObjects.Item($TableName)
    } catch {
      $listObject = $null
    }

    if ($null -eq $listObject) {
      continue
    }

    $tableRange = $null
    try {
      if ($null -ne $listObject.DataBodyRange) {
        $tableRange = $listObject.DataBodyRange
      } else {
        $tableRange = $listObject.Range
      }
    } catch {
      $tableRange = $null
    }

    if ($null -ne $tableRange) {
      return ,$tableRange
    }
  }

  return $null
}

function Convert-TableRowsToList {
  param(
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [object] $RowsRaw
  )

  $rows = New-Object System.Collections.Generic.List[object]
  if ($null -eq $RowsRaw) {
    return $rows
  }

  if ($RowsRaw.PSObject.Properties.Name -contains 'RowName' -or $RowsRaw.PSObject.Properties.Name -contains 'Value') {
    $rowNameValue = if ($RowsRaw.PSObject.Properties.Name -contains 'RowName') { [string] $RowsRaw.RowName } else { '' }
    $rowCellValue = if ($RowsRaw.PSObject.Properties.Name -contains 'Value') { $RowsRaw.Value } else { $null }
    [void] $rows.Add([pscustomobject]@{ RowName = $rowNameValue; Value = $rowCellValue })
    return $rows
  }

  $isRowsArrayLike = $RowsRaw.GetType().IsArray -or $RowsRaw -is [System.Collections.IList]
  if ($isRowsArrayLike) {
    foreach ($candidateRow in @($RowsRaw)) {
      if ($null -eq $candidateRow) {
        continue
      }

      if ($candidateRow.PSObject.Properties.Name -contains 'RowName' -or $candidateRow.PSObject.Properties.Name -contains 'Value') {
        $rowNameValue = if ($candidateRow.PSObject.Properties.Name -contains 'RowName') { [string] $candidateRow.RowName } else { '' }
        $rowCellValue = if ($candidateRow.PSObject.Properties.Name -contains 'Value') { $candidateRow.Value } else { $null }
        [void] $rows.Add([pscustomobject]@{ RowName = $rowNameValue; Value = $rowCellValue })
        continue
      }

      foreach ($p in @($candidateRow.PSObject.Properties)) {
        [void] $rows.Add([pscustomobject]@{ RowName = [string] $p.Name; Value = $p.Value })
      }
    }

    return $rows
  }

  foreach ($p in @($RowsRaw.PSObject.Properties)) {
    [void] $rows.Add([pscustomobject]@{ RowName = [string] $p.Name; Value = $p.Value })
  }

  return $rows
}

function Convert-TableColumnsToList {
  param(
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [object] $ColsRaw
  )

  $columns = New-Object System.Collections.Generic.List[object]
  if ($null -eq $ColsRaw) {
    return $columns
  }

  if ($ColsRaw.PSObject.Properties.Name -contains 'ColumnName') {
    $colName = [string] $ColsRaw.ColumnName
    if (-not [string]::IsNullOrWhiteSpace($colName)) {
      [void] $columns.Add([pscustomobject]@{
        ColumnName = $colName
        Rows       = Convert-TableRowsToList -RowsRaw (if ($ColsRaw.PSObject.Properties.Name -contains 'Rows') { $ColsRaw.Rows } else { $null })
      })
    }

    return $columns
  }

  $isColsArrayLike = $ColsRaw.GetType().IsArray -or $ColsRaw -is [System.Collections.IList]
  if ($isColsArrayLike) {
    foreach ($candidateCol in @($ColsRaw)) {
      if ($null -eq $candidateCol) {
        continue
      }

      if ($candidateCol.PSObject.Properties.Name -contains 'ColumnName') {
        $colName = [string] $candidateCol.ColumnName
        if ([string]::IsNullOrWhiteSpace($colName)) {
          continue
        }

        [void] $columns.Add([pscustomobject]@{
          ColumnName = $colName
          Rows       = Convert-TableRowsToList -RowsRaw (if ($candidateCol.PSObject.Properties.Name -contains 'Rows') { $candidateCol.Rows } else { $null })
        })
        continue
      }

      foreach ($p in @($candidateCol.PSObject.Properties)) {
        [void] $columns.Add([pscustomobject]@{
          ColumnName = [string] $p.Name
          Rows       = Convert-TableRowsToList -RowsRaw $p.Value
        })
      }
    }

    return $columns
  }

  foreach ($p in @($ColsRaw.PSObject.Properties)) {
    [void] $columns.Add([pscustomobject]@{
      ColumnName = [string] $p.Name
      Rows       = Convert-TableRowsToList -RowsRaw $p.Value
    })
  }

  return $columns
}

function Convert-InputTableToColumns {
  param(
    [Parameter(Mandatory = $true)]
    [object] $Table
  )

  if ($Table.PSObject.Properties.Name -contains 'Cols' -and $null -ne $Table.Cols) {
    return @(Convert-TableColumnsToList -ColsRaw $Table.Cols)
  }

  if (-not ($Table.PSObject.Properties.Name -contains 'Rows') -or $null -eq $Table.Rows) {
    return @()
  }

  $rowEntries = @()
  $rowsRaw = $Table.Rows

  $isRowsArrayLike = $rowsRaw.GetType().IsArray -or $rowsRaw -is [System.Collections.IList]
  if ($isRowsArrayLike) {
    foreach ($candidateRow in @($rowsRaw)) {
      if ($null -eq $candidateRow) {
        continue
      }

      if ($candidateRow.PSObject.Properties.Name -contains 'RowName') {
        $entryName = [string] $candidateRow.RowName
        $entryData = if ($candidateRow.PSObject.Properties.Name -contains 'Value') { $candidateRow.Value } else { $candidateRow }
        $rowEntries += ,([pscustomobject]@{ RowName = $entryName; Data = $entryData })
      } else {
        foreach ($p in @($candidateRow.PSObject.Properties)) {
          $rowEntries += ,([pscustomobject]@{ RowName = [string] $p.Name; Data = $p.Value })
        }
      }
    }
  } else {
    foreach ($p in @($rowsRaw.PSObject.Properties)) {
      $rowEntries += ,([pscustomobject]@{ RowName = [string] $p.Name; Data = $p.Value })
    }
  }

  $columnRowsMap = @{}
  $columnOrder = @()
  foreach ($entry in $rowEntries) {
    $rowName = [string] $entry.RowName
    $rowData = $entry.Data

    if ($null -eq $rowData) {
      if (-not $columnRowsMap.ContainsKey('Value')) {
        $columnRowsMap['Value'] = @()
        $columnOrder += 'Value'
      }
      $columnRowsMap['Value'] += ,([pscustomobject]@{ RowName = $rowName; Value = $null })
      continue
    }

    $rowDataProps = @()
    if ($null -ne $rowData.PSObject -and $null -ne $rowData.PSObject.Properties) {
      $rowDataProps = @($rowData.PSObject.Properties)
    }
    $hasDataProps = $rowDataProps.Count -gt 0
    if ($hasDataProps -and -not ($rowData -is [string])) {
      foreach ($prop in $rowDataProps) {
        if ([string]::Equals([string] $prop.Name, 'RowName', [System.StringComparison]::OrdinalIgnoreCase)) {
          continue
        }

        $columnName = [string] $prop.Name
        if (-not $columnRowsMap.ContainsKey($columnName)) {
          $columnRowsMap[$columnName] = @()
          $columnOrder += $columnName
        }

        $columnRowsMap[$columnName] += ,([pscustomobject]@{ RowName = $rowName; Value = $prop.Value })
      }
      continue
    }

    if (-not $columnRowsMap.ContainsKey('Value')) {
      $columnRowsMap['Value'] = @()
      $columnOrder += 'Value'
    }
    $columnRowsMap['Value'] += ,([pscustomobject]@{ RowName = $rowName; Value = $rowData })
  }

  $columns = @()
  foreach ($columnName in @($columnOrder)) {
    $columns += ,([pscustomobject]@{
      ColumnName = [string] $columnName
      Rows       = @($columnRowsMap[$columnName])
    })
  }

  return @($columns)
}

try {
  $excel = New-Object -ComObject Excel.Application
  $excel.Visible = $false
  $excel.DisplayAlerts = $false
  $excel.ScreenUpdating = $false
  $excel.EnableEvents = $false

  $workbook = $excel.Workbooks.Open($targetPath)

  $skipJsonKeys = @(
    'TextExcelFile',
    'TestExcelFile',
    'TestID',
    'TestInputFile',
    'TestResultsFile',
    'InputTables'
  )

  foreach ($prop in $jsonProperties) {
    if ($skipJsonKeys -contains [string] $prop.Name) {
      continue
    }

    $nameEntry = $null
    try {
      $nameEntry = $workbook.Names.Item([string] $prop.Name)
    } catch {
      $nameEntry = $null
    }

    if ($null -eq $nameEntry) {
      [void] $missing.Add([string] $prop.Name)
      continue
    }

    try {
      $range = $nameEntry.RefersToRange
      if ($null -eq $range) {
        [void] $failed.Add([string] $prop.Name)
        [void] $failedDetails.Add(([string] $prop.Name + ': name does not refer to a writable range'))
        continue
      }

      $value = $prop.Value
      if ($null -eq $value) {
        $range.Value2 = ''
      } elseif ($value -is [bool]) {
        $range.Value2 = if ($value) { 1 } else { 0 }
      } elseif (
        $value -is [byte] -or
        $value -is [sbyte] -or
        $value -is [int16] -or
        $value -is [uint16] -or
        $value -is [int32] -or
        $value -is [uint32] -or
        $value -is [int64] -or
        $value -is [uint64] -or
        $value -is [single] -or
        $value -is [double] -or
        $value -is [decimal]
      ) {
        $range.Value2 = [string] $value
      } else {
        $range.Value2 = $value
      }

      $updated++
    } catch {
      [void] $failed.Add([string] $prop.Name)
      [void] $failedDetails.Add(([string] $prop.Name + ': ' + $_.Exception.Message))
    }
  }

  $inputTables = New-Object System.Collections.Generic.List[object]
  $inputTablesRaw = $null
  if ($jsonObject.PSObject.Properties.Name -contains 'InputTables') {
    $inputTablesRaw = $jsonObject.InputTables
  }

  if ($null -ne $inputTablesRaw) {
    if ($inputTablesRaw -is [System.Collections.IEnumerable] -and -not ($inputTablesRaw -is [string])) {
      foreach ($candidateTable in $inputTablesRaw) {
        if ($null -eq $candidateTable) {
          continue
        }
        if ($candidateTable.PSObject.Properties.Name -contains 'TableName') {
          [void] $inputTables.Add($candidateTable)
        }
      }
    } elseif ($inputTablesRaw.PSObject.Properties.Name -contains 'TableName') {
      [void] $inputTables.Add($inputTablesRaw)
    }
  }

  foreach ($table in $inputTables) {
    if ($null -eq $table) {
      continue
    }

    $tableName = [string] $table.TableName
    if ([string]::IsNullOrWhiteSpace($tableName)) {
      [void] $tableFailed.Add('InputTables')
      [void] $tableFailedDetails.Add('InputTables: missing TableName')
      continue
    }

    $hasCols = $table.PSObject.Properties.Name -contains 'Cols'
    $hasRows = $table.PSObject.Properties.Name -contains 'Rows'
    if ((-not $hasCols -or $null -eq $table.Cols) -and (-not $hasRows -or $null -eq $table.Rows)) {
      [void] $tableFailed.Add($tableName)
      [void] $tableFailedDetails.Add($tableName + ': missing Cols/Rows data')
      continue
    }

    $tableRangeName = $tableName
    $tableRangeFromExcelTable = $false
    $tableRange = Get-WorkbookTableRange -Workbook $workbook -TableName $tableRangeName
    if ($null -ne $tableRange) {
      $tableRangeFromExcelTable = $true
    }

    if ($null -eq $tableRange) {
      $tableNameEntry = Get-WorkbookNameEntry -Workbook $workbook -CandidateNames ([string[]] @($tableRangeName))
      if ($null -ne $tableNameEntry) {
        try {
          $tableRange = $tableNameEntry.RefersToRange
        } catch {
          $tableRange = $null
        }
      }
    }

    $tableRangeSupportsGridAddressing = $false
    if ($null -ne $tableRange) {
      try {
        $probeCell = $tableRange.Rows.Item(1).Columns.Item(1)
        if ($null -ne $probeCell) {
          $tableRangeSupportsGridAddressing = $true
        }
      } catch {
        $tableRangeSupportsGridAddressing = $false
      }
    }

    if (-not $tableRangeSupportsGridAddressing) {
      $fallbackTableRange = Get-WorkbookTableRange -Workbook $workbook -TableName $tableRangeName
      if ($null -ne $fallbackTableRange) {
        $tableRange = $fallbackTableRange
      }
    }

    if ($null -eq $tableRange) {
      [void] $tableMissing.Add($tableRangeName)
      [void] $tableFailedDetails.Add($tableRangeName + ': not found as a named range or Excel table')
      continue
    }

    $tableRangeRowCount = [int] $tableRange.Rows.Count
    $tableRangeColumnCount = [int] $tableRange.Columns.Count

    $columnOffset = if ($tableRangeFromExcelTable) { 0 } else { 1 }
    if ($table.PSObject.Properties.Name -contains 'ColumnOffset' -and $null -ne $table.ColumnOffset) {
      $parsedColumnOffset = 0
      if ([int]::TryParse([string] $table.ColumnOffset, [ref] $parsedColumnOffset)) {
        $columnOffset = $parsedColumnOffset
      }
    }

    $rowOffset = if ($tableRangeFromExcelTable) { 0 } else { 1 }
    if ($table.PSObject.Properties.Name -contains 'RowOffset' -and $null -ne $table.RowOffset) {
      $parsedRowOffset = 0
      if ([int]::TryParse([string] $table.RowOffset, [ref] $parsedRowOffset)) {
        $rowOffset = $parsedRowOffset
      }
    }

    $matrixType = 'RowsToCols'
    if ($table.PSObject.Properties.Name -contains 'MatrixType' -and -not [string]::IsNullOrWhiteSpace([string] $table.MatrixType)) {
      $matrixType = [string] $table.MatrixType
    }

    $hasColsData = $table.PSObject.Properties.Name -contains 'Cols' -and $null -ne $table.Cols
    $hasRowsData = $table.PSObject.Properties.Name -contains 'Rows' -and $null -ne $table.Rows
    if (-not $hasColsData -and $hasRowsData) {
      $rowsRaw = $table.Rows
      $rowEntries = @()
      $isRowsArrayLike = $rowsRaw.GetType().IsArray -or $rowsRaw -is [System.Collections.IList]
      if ($isRowsArrayLike) {
        foreach ($candidateRow in @($rowsRaw)) {
          if ($null -eq $candidateRow) {
            continue
          }

          if ($candidateRow.PSObject.Properties.Name -contains 'RowName') {
            $entryName = [string] $candidateRow.RowName
            $entryData = if ($candidateRow.PSObject.Properties.Name -contains 'Value') { $candidateRow.Value } else { $candidateRow }
            $rowEntries += ,([pscustomobject]@{ RowName = $entryName; Data = $entryData })
          } else {
            foreach ($p in @($candidateRow.PSObject.Properties)) {
              $rowEntries += ,([pscustomobject]@{ RowName = [string] $p.Name; Data = $p.Value })
            }
          }
        }
      } else {
        foreach ($p in @($rowsRaw.PSObject.Properties)) {
          $rowEntries += ,([pscustomobject]@{ RowName = [string] $p.Name; Data = $p.Value })
        }
      }

      $requestedColsToRows = [string]::Equals($matrixType, 'ColsToRows', [System.StringComparison]::OrdinalIgnoreCase)
      for ($rowIndex = 0; $rowIndex -lt $rowEntries.Count; $rowIndex++) {
        $entry = $rowEntries[$rowIndex]
        if ($null -eq $entry) {
          continue
        }

        $entryData = $entry.Data
        $entryProps = @()
        if ($null -ne $entryData -and $null -ne $entryData.PSObject -and $null -ne $entryData.PSObject.Properties -and -not ($entryData -is [string])) {
          $entryProps = @($entryData.PSObject.Properties)
        }

        if ($entryProps.Count -eq 0) {
          $entryProps = @([pscustomobject]@{ Name = 'Value'; Value = $entryData })
        }

        for ($colIndex = 0; $colIndex -lt $entryProps.Count; $colIndex++) {
          $prop = $entryProps[$colIndex]
          if ($null -eq $prop) {
            continue
          }

          $targetRowPosition = if ($requestedColsToRows) { $colIndex + 1 + $rowOffset } else { $rowIndex + 1 + $rowOffset }
          $targetColumnPosition = if ($requestedColsToRows) { $rowIndex + 1 + $columnOffset } else { $colIndex + 1 + $columnOffset }

          if ($targetColumnPosition -lt 1 -or $targetColumnPosition -gt $tableRangeColumnCount) {
            [void] $tableFailed.Add($tableRangeName)
            [void] $tableFailedDetails.Add(($tableRangeName + ': column position ' + $targetColumnPosition + ' is outside range width ' + $tableRangeColumnCount))
            continue
          }

          if ($targetRowPosition -lt 1 -or $targetRowPosition -gt $tableRangeRowCount) {
            [void] $tableFailed.Add($tableRangeName)
            [void] $tableFailedDetails.Add(($tableRangeName + ': row position ' + $targetRowPosition + ' is outside range height ' + $tableRangeRowCount))
            continue
          }

          try {
            $targetCell = $tableRange.Rows.Item($targetRowPosition).Columns.Item($targetColumnPosition)
            $tableValue = $prop.Value

            if ($null -eq $tableValue) {
              $targetCell.Value2 = ''
            } elseif ($tableValue -is [bool]) {
              $targetCell.Value2 = if ($tableValue) { 1 } else { 0 }
            } elseif (
              $tableValue -is [byte] -or
              $tableValue -is [sbyte] -or
              $tableValue -is [int16] -or
              $tableValue -is [uint16] -or
              $tableValue -is [int32] -or
              $tableValue -is [uint32] -or
              $tableValue -is [int64] -or
              $tableValue -is [uint64] -or
              $tableValue -is [single] -or
              $tableValue -is [double] -or
              $tableValue -is [decimal]
            ) {
              $targetCell.Value2 = [string] $tableValue
            } else {
              $targetCell.Value2 = $tableValue
            }

            $updatedInputTableCells++
          } catch {
            $tableCellLabel = ($tableRangeName + ': row=' + $targetRowPosition + ', col=' + $targetColumnPosition)
            [void] $tableFailed.Add($tableCellLabel)
            [void] $tableFailedDetails.Add($tableCellLabel + ': ' + $_.Exception.Message)
          }
        }
      }

      continue
    }

    $columns = @(Convert-InputTableToColumns -Table $table)
    $preparedColumns = New-Object System.Collections.Generic.List[object]
    $maxRowsPerColumn = 0
    foreach ($col in $columns) {
      if ($null -eq $col) {
        continue
      }

      $rows = @(Convert-TableRowsToList -RowsRaw $col.Rows)
      if ($rows.Count -gt $maxRowsPerColumn) {
        $maxRowsPerColumn = $rows.Count
      }

      [void] $preparedColumns.Add([pscustomobject]@{
        Column = $col
        Rows   = $rows
      })
    }

    $requestedColsToRows = [string]::Equals($matrixType, 'ColsToRows', [System.StringComparison]::OrdinalIgnoreCase)
    $isColsToRows = $false

    $requiredRowsRowsToCols = $rowOffset + $maxRowsPerColumn
    $requiredColsRowsToCols = $columnOffset + $preparedColumns.Count
    $requiredRowsColsToRows = $rowOffset + $preparedColumns.Count
    $requiredColsColsToRows = $columnOffset + $maxRowsPerColumn

    $rowsToColsFits = ($requiredRowsRowsToCols -le $tableRangeRowCount) -and ($requiredColsRowsToCols -le $tableRangeColumnCount)
    $colsToRowsFits = ($requiredRowsColsToRows -le $tableRangeRowCount) -and ($requiredColsColsToRows -le $tableRangeColumnCount)

    if ($requestedColsToRows -and -not $rowsToColsFits -and $colsToRowsFits) {
      $isColsToRows = $true
    } elseif ($requestedColsToRows -and -not $colsToRowsFits -and $rowsToColsFits) {
      [void] $tableFailedDetails.Add(($tableRangeName + ': MatrixType=ColsToRows does not fit named range; using RowsToCols fallback'))
    }

    for ($colIndex = 0; $colIndex -lt $preparedColumns.Count; $colIndex++) {
      $colEntry = $preparedColumns[$colIndex]
      if ($null -eq $colEntry) {
        continue
      }

      $rows = @($colEntry.Rows)

      for ($rowIndex = 0; $rowIndex -lt $rows.Count; $rowIndex++) {
        $row = $rows[$rowIndex]
        if ($null -eq $row) {
          continue
        }

        $targetRowPosition = if ($isColsToRows) { $colIndex + 1 + $rowOffset } else { $rowIndex + 1 + $rowOffset }
        $targetColumnPosition = if ($isColsToRows) { $rowIndex + 1 + $columnOffset } else { $colIndex + 1 + $columnOffset }

        if ($targetColumnPosition -lt 1 -or $targetColumnPosition -gt $tableRangeColumnCount) {
          [void] $tableFailed.Add($tableRangeName)
          [void] $tableFailedDetails.Add(($tableRangeName + ': column position ' + $targetColumnPosition + ' is outside range width ' + $tableRangeColumnCount))
          continue
        }

        if ($targetRowPosition -lt 1 -or $targetRowPosition -gt $tableRangeRowCount) {
          [void] $tableFailed.Add($tableRangeName)
          [void] $tableFailedDetails.Add(($tableRangeName + ': row position ' + $targetRowPosition + ' is outside range height ' + $tableRangeRowCount))
          continue
        }

        $rowName = [string] $row.RowName

        try {
          # Row/column chained addressing is reliable for both named ranges and Excel table ranges.
          $targetCell = $tableRange.Rows.Item($targetRowPosition).Columns.Item($targetColumnPosition)
          $tableValue = if ($row.PSObject.Properties.Name -contains 'Value') { $row.Value } else { $rowName }

          if ($null -eq $tableValue) {
            $targetCell.Value2 = ''
          } elseif ($tableValue -is [bool]) {
            $targetCell.Value2 = if ($tableValue) { 1 } else { 0 }
          } elseif (
            $tableValue -is [byte] -or
            $tableValue -is [sbyte] -or
            $tableValue -is [int16] -or
            $tableValue -is [uint16] -or
            $tableValue -is [int32] -or
            $tableValue -is [uint32] -or
            $tableValue -is [int64] -or
            $tableValue -is [uint64] -or
            $tableValue -is [single] -or
            $tableValue -is [double] -or
            $tableValue -is [decimal]
          ) {
            $targetCell.Value2 = [string] $tableValue
          } else {
            $targetCell.Value2 = $tableValue
          }

          $updatedInputTableCells++
        } catch {
          $tableCellLabel = ($tableRangeName + ': row=' + $targetRowPosition + ', col=' + $targetColumnPosition)
          [void] $tableFailed.Add($tableCellLabel)
          [void] $tableFailedDetails.Add($tableCellLabel + ': ' + $_.Exception.Message)
        }
      }
    }
  }

  foreach ($resultProp in $resultsProperties) {
    $resultName = [string] $resultProp.Name
    $nameEntry = $null
    try {
      $nameEntry = $workbook.Names.Item($resultName)
    } catch {
      $nameEntry = $null
    }

    if ($null -eq $nameEntry) {
      [void] $resultsMissing.Add($resultName)
      continue
    }

    $expected = Convert-ToNullableDouble -Value $resultProp.Value
    if ($null -eq $expected) {
      [void] $resultsNonNumeric.Add($resultName + ': expected value is not numeric')
      continue
    }

    try {
      $range = $nameEntry.RefersToRange
      if ($null -eq $range) {
        [void] $resultsNonNumeric.Add($resultName + ': name does not refer to a writable range')
        continue
      }

      $actual = Convert-ToNullableDouble -Value $range.Value2
      if ($null -eq $actual) {
        [void] $resultsNonNumeric.Add($resultName + ': workbook value is not numeric')
        continue
      }

      $difference = $actual - $expected
      $absDifference = [Math]::Abs($difference)
      $status = if ($absDifference -gt $DifferenceTolerance) { 'FAIL' } else { 'PASS' }
      if ($status -eq 'FAIL') {
        $resultFailCount++
      } else {
        $resultPassCount++
      }

      [void] $resultDiffs.Add([pscustomobject]@{
        Name          = $resultName
        Expected      = $expected
        Actual        = $actual
        Difference    = $difference
        AbsDifference = $absDifference
        Status        = $status
      })
    } catch {
      [void] $resultsNonNumeric.Add($resultName + ': ' + $_.Exception.Message)
    }
  }

  $workbook.Save()
} finally {
  if ($null -ne $workbook) {
    try { $workbook.Close($true) } catch { }
  }
  if ($null -ne $excel) {
    try { $excel.Quit() } catch { }
  }
  if ($null -ne $workbook) {
    try { [void] [System.Runtime.InteropServices.Marshal]::ReleaseComObject($workbook) } catch { }
  }
  if ($null -ne $excel) {
    try { [void] [System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel) } catch { }
  }
  [GC]::Collect()
  [GC]::WaitForPendingFinalizers()
}

Write-Host ("Source workbook: {0}" -f $sourceFile.FullName)
Write-Host ("Created workbook: {0}" -f $targetPath)
Write-Host ("TestID: {0}" -f $TestID)
Write-Host ("Test config: {0}" -f $resolvedConfigPath)
Write-Host ("JSON file: {0}" -f $resolvedJsonPath)
Write-Host ("Results file: {0}" -f $resolvedResultsPath)
Write-Host ("Named cells updated: {0}" -f $updated)
Write-Host ("Input table cells updated: {0}" -f $updatedInputTableCells)

if ($missing.Count -gt 0) {
  Write-Warning ("JSON keys not found as workbook names ({0}): {1}" -f $missing.Count, (($missing | Sort-Object) -join ', '))
}

if ($failed.Count -gt 0) {
  Write-Warning ("Workbook names found but failed to write ({0}): {1}" -f $failed.Count, (($failed | Sort-Object) -join ', '))
  Write-Warning ('Failure details:')
  foreach ($detail in @($failedDetails | Sort-Object)) {
    Write-Warning ('  - ' + $detail)
  }
}

if ($tableMissing.Count -gt 0) {
  Write-Warning ("Input table name lookups not found ({0}): {1}" -f $tableMissing.Count, (($tableMissing | Sort-Object -Unique) -join ', '))
}

if ($tableFailed.Count -gt 0) {
  Write-Warning ("Input table writes failed ({0}): {1}" -f $tableFailed.Count, (($tableFailed | Sort-Object -Unique) -join ', '))
  Write-Warning ('Input table failure details:')
  foreach ($detail in @($tableFailedDetails | Sort-Object -Unique)) {
    Write-Warning ('  - ' + $detail)
  }
}

if ($resultsMissing.Count -gt 0) {
  Write-Warning ("Result keys not found as workbook names ({0}): {1}" -f $resultsMissing.Count, (($resultsMissing | Sort-Object) -join ', '))
}

if ($resultsNonNumeric.Count -gt 0) {
  Write-Warning ('Result comparison issues:')
  foreach ($detail in @($resultsNonNumeric | Sort-Object)) {
    Write-Warning ('  - ' + $detail)
  }
}

if ($resultDiffs.Count -gt 0) {
  Write-Host ("Result differences (tolerance={0}):" -f $DifferenceTolerance)
  foreach ($d in @($resultDiffs | Sort-Object Name)) {
    Write-Host ("  [{0}] {1}: expected={2}, actual={3}, difference={4}, absDifference={5}" -f $d.Status, $d.Name, $d.Expected, $d.Actual, $d.Difference, $d.AbsDifference)
  }
  Write-Host ("Result summary: pass={0}, fail={1}" -f $resultPassCount, $resultFailCount)
}

if ($resultFailCount -gt 0) {
  throw ("Test failed: {0} result(s) exceeded tolerance {1}." -f $resultFailCount, $DifferenceTolerance)
}
