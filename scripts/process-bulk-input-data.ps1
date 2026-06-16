param(
  [string] $RepoRoot = $(Split-Path $PSScriptRoot -Parent),
  [Parameter(Mandatory = $true)]
  [string] $ManifestPath,
  [Parameter(Mandatory = $true)]
  [string] $InputRoot,
  [string] $OutputRoot,
  [string] $RunStamp,
  [Parameter(Mandatory = $true)]
  [string] $ResultJsonPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if ([string]::IsNullOrWhiteSpace($OutputRoot)) {
  $OutputRoot = Join-Path $RepoRoot 'Excel\Batch processing'
}

if ([string]::IsNullOrWhiteSpace($RunStamp)) {
  $RunStamp = Get-Date -Format 'HHmm_yyyyMMdd'
}

$resolvedRepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path
$resolvedManifestPath = (Resolve-Path -LiteralPath $ManifestPath).Path
$resolvedInputRoot = (Resolve-Path -LiteralPath $InputRoot).Path

if (-not (Test-Path -LiteralPath $OutputRoot)) {
  [void] (New-Item -ItemType Directory -Path $OutputRoot -Force)
}

$resolvedOutputRoot = (Resolve-Path -LiteralPath $OutputRoot).Path
function Get-UniqueRunStamp {
  param(
    [Parameter(Mandatory = $true)]
    [string] $RootPath,

    [Parameter(Mandatory = $true)]
    [string] $BaseStamp
  )

  $stamp = $BaseStamp
  $suffix = 2
  while (Test-Path -LiteralPath (Join-Path $RootPath $stamp)) {
    $stamp = ('{0}_{1}' -f $BaseStamp, $suffix)
    $suffix++
  }

  return $stamp
}

$RunStamp = Get-UniqueRunStamp -RootPath $resolvedOutputRoot -BaseStamp $RunStamp
$runOutputDirectory = Join-Path $resolvedOutputRoot $RunStamp
if (-not (Test-Path -LiteralPath $runOutputDirectory)) {
  [void] (New-Item -ItemType Directory -Path $runOutputDirectory -Force)
}

function Get-ManifestEntries {
  param(
    [Parameter(Mandatory = $true)]
    [AllowNull()]
    [object] $Node,

    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [System.Collections.Generic.List[object]] $Entries
  )

  if ($null -eq $Node) {
    return
  }

  $properties = @($Node.PSObject.Properties)
  if ($properties.Count -eq 0) {
    return
  }

  $names = @($properties.Name)
  if ($names -contains 'TestID' -and $names -contains 'TestExcelFile' -and $names -contains 'TestInputFile') {
    [void] $Entries.Add([pscustomobject]@{
      TestID = [string] $Node.TestID
      TestExcelFile = [string] $Node.TestExcelFile
      TestInputFile = [string] $Node.TestInputFile
      TestResultsFile = if ($names -contains 'TestResultsFile') { [string] $Node.TestResultsFile } else { '' }
    })
  }

  foreach ($property in $properties) {
    Get-ManifestEntries -Node $property.Value -Entries $Entries
  }
}

function Get-WorkbookNameEntry {
  param(
    [Parameter(Mandatory = $true)]
    [object] $Workbook,

    [Parameter(Mandatory = $true)]
    [string[]] $CandidateNames
  )

  $allNames = New-Object System.Collections.Generic.List[object]
  foreach ($n in $Workbook.Names) {
    [void] $allNames.Add($n)
  }

  foreach ($candidate in @($CandidateNames)) {
    if ([string]::IsNullOrWhiteSpace([string] $candidate)) {
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

      if ([string]::Equals($shortName, [string] $candidate, [System.StringComparison]::OrdinalIgnoreCase)) {
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

function Get-RelativePathSafe {
  param(
    [Parameter(Mandatory = $true)]
    [string] $BasePath,

    [Parameter(Mandatory = $true)]
    [string] $TargetPath
  )

  $baseFull = [System.IO.Path]::GetFullPath($BasePath)
  $targetFull = [System.IO.Path]::GetFullPath($TargetPath)

  if (-not $baseFull.EndsWith([System.IO.Path]::DirectorySeparatorChar)) {
    $baseFull += [System.IO.Path]::DirectorySeparatorChar
  }

  $baseUri = New-Object System.Uri($baseFull)
  $targetUri = New-Object System.Uri($targetFull)
  $relativeUri = $baseUri.MakeRelativeUri($targetUri)
  return [System.Uri]::UnescapeDataString($relativeUri.ToString()).Replace('/', '\\')
}

function Write-NamedInputs {
  param(
    [Parameter(Mandatory = $true)]
    [object] $Workbook,

    [Parameter(Mandatory = $true)]
    [object] $JsonObject,

    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [System.Collections.Generic.List[string]] $Warnings
  )

  $updated = 0
  $skipJsonKeys = @('TextExcelFile', 'TestExcelFile', 'TestID', 'TestInputFile', 'TestResultsFile', 'InputTables')

  foreach ($prop in @($JsonObject.PSObject.Properties)) {
    if ($skipJsonKeys -contains [string] $prop.Name) {
      continue
    }

    $nameEntry = $null
    try {
      $nameEntry = $Workbook.Names.Item([string] $prop.Name)
    } catch {
      $nameEntry = $null
    }

    if ($null -eq $nameEntry) {
      [void] $Warnings.Add('Missing named cell: ' + [string] $prop.Name)
      continue
    }

    try {
      $range = $nameEntry.RefersToRange
      if ($null -eq $range) {
        [void] $Warnings.Add('Named cell has no writable range: ' + [string] $prop.Name)
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
      [void] $Warnings.Add(([string] $prop.Name + ': ' + $_.Exception.Message))
    }
  }

  return $updated
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

function Write-InputTables {
  param(
    [Parameter(Mandatory = $true)]
    [object] $Workbook,

    [Parameter(Mandatory = $true)]
    [object] $JsonObject,

    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [System.Collections.Generic.List[string]] $Warnings
  )

  $updated = 0

  if (-not ($JsonObject.PSObject.Properties.Name -contains 'InputTables')) {
    return $updated
  }

  $inputTables = New-Object System.Collections.Generic.List[object]
  $inputTablesRaw = $JsonObject.InputTables

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
    $tableName = [string] $table.TableName
    if ([string]::IsNullOrWhiteSpace($tableName)) {
      [void] $Warnings.Add('Input table has no TableName')
      continue
    }

    $hasCols = $table.PSObject.Properties.Name -contains 'Cols'
    $hasRows = $table.PSObject.Properties.Name -contains 'Rows'
    if ((-not $hasCols -or $null -eq $table.Cols) -and (-not $hasRows -or $null -eq $table.Rows)) {
      [void] $Warnings.Add('Input table ' + $tableName + ' has no Cols/Rows data')
      continue
    }

    $tableRangeName = $tableName
    $tableRangeFromExcelTable = $false
    $tableRange = Get-WorkbookTableRange -Workbook $Workbook -TableName $tableRangeName
    if ($null -ne $tableRange) {
      $tableRangeFromExcelTable = $true
    }

    if ($null -eq $tableRange) {
      $tableNameEntry = Get-WorkbookNameEntry -Workbook $Workbook -CandidateNames ([string[]] @($tableRangeName))
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
      $fallbackTableRange = Get-WorkbookTableRange -Workbook $Workbook -TableName $tableRangeName
      if ($null -ne $fallbackTableRange) {
        $tableRange = $fallbackTableRange
      }
    }

    if ($null -eq $tableRange) {
      [void] $Warnings.Add('Missing named range or Excel table: ' + $tableRangeName)
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
            [void] $Warnings.Add(($tableRangeName + ': column position ' + $targetColumnPosition + ' outside width ' + $tableRangeColumnCount))
            continue
          }

          if ($targetRowPosition -lt 1 -or $targetRowPosition -gt $tableRangeRowCount) {
            [void] $Warnings.Add(($tableRangeName + ': row position ' + $targetRowPosition + ' outside height ' + $tableRangeRowCount))
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

            $updated++
          } catch {
            [void] $Warnings.Add(($tableRangeName + ': row=' + $targetRowPosition + ', col=' + $targetColumnPosition + ': ' + $_.Exception.Message))
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
      [void] $Warnings.Add(($tableRangeName + ': MatrixType=ColsToRows does not fit named range; using RowsToCols fallback'))
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
          [void] $Warnings.Add(($tableRangeName + ': column position ' + $targetColumnPosition + ' outside width ' + $tableRangeColumnCount))
          continue
        }

        if ($targetRowPosition -lt 1 -or $targetRowPosition -gt $tableRangeRowCount) {
          [void] $Warnings.Add(($tableRangeName + ': row position ' + $targetRowPosition + ' outside height ' + $tableRangeRowCount))
          continue
        }

        try {
          $targetCell = $tableRange.Rows.Item($targetRowPosition).Columns.Item($targetColumnPosition)
          $tableValue = if ($row.PSObject.Properties.Name -contains 'Value') { $row.Value } else { [string] $row.RowName }

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

          $updated++
        } catch {
          [void] $Warnings.Add(($tableRangeName + ': row=' + $targetRowPosition + ', col=' + $targetColumnPosition + ': ' + $_.Exception.Message))
        }
      }
    }
  }

  return $updated
}

function Get-ResultNames {
  param(
    [Parameter(Mandatory = $true)]
    [string] $RepoRoot,

    [Parameter(Mandatory = $false)]
    [string] $ResultsFilePath,

    [Parameter(Mandatory = $true)]
    [AllowEmptyCollection()]
    [System.Collections.Generic.List[string]] $Warnings
  )

  if ([string]::IsNullOrWhiteSpace($ResultsFilePath)) {
    return @()
  }

  $candidatePaths = New-Object System.Collections.Generic.List[string]
  if ([System.IO.Path]::IsPathRooted($ResultsFilePath)) {
    [void] $candidatePaths.Add($ResultsFilePath)
  } else {
    [void] $candidatePaths.Add((Join-Path (Join-Path $RepoRoot 'Test') $ResultsFilePath))
    [void] $candidatePaths.Add((Join-Path $RepoRoot $ResultsFilePath))
  }

  foreach ($candidate in $candidatePaths) {
    if (-not (Test-Path -LiteralPath $candidate)) {
      continue
    }

    try {
      $raw = Get-Content -LiteralPath $candidate -Raw
      $obj = $raw | ConvertFrom-Json
      return @($obj.PSObject.Properties.Name)
    } catch {
      [void] $Warnings.Add('Unable to parse results file ' + $candidate + ': ' + $_.Exception.Message)
      return @()
    }
  }

  [void] $Warnings.Add('Results file not found: ' + $ResultsFilePath)
  return @()
}

$manifestRaw = Get-Content -LiteralPath $resolvedManifestPath -Raw
$manifestObject = $manifestRaw | ConvertFrom-Json
$entries = New-Object System.Collections.Generic.List[object]
Get-ManifestEntries -Node $manifestObject -Entries $entries

if ($entries.Count -eq 0) {
  throw 'No manifest entries found with TestID/TestExcelFile/TestInputFile fields.'
}

$inputFiles = @(
  Get-ChildItem -Path $resolvedInputRoot -File -Recurse | Where-Object { $_.Extension.ToLowerInvariant() -eq '.json' }
)

$inputByBaseName = @{}
foreach ($f in $inputFiles) {
  $base = $f.Name.ToLowerInvariant()
  if (-not $inputByBaseName.ContainsKey($base)) {
    $inputByBaseName[$base] = $f.FullName
  }
}

$excelRoot = Join-Path $resolvedRepoRoot 'Excel'
$warnings = New-Object System.Collections.Generic.List[string]
$items = New-Object System.Collections.Generic.List[object]

$excel = $null
try {
  $excel = New-Object -ComObject Excel.Application
  $excel.Visible = $false
  $excel.DisplayAlerts = $false
  $excel.ScreenUpdating = $false
  $excel.EnableEvents = $false

  foreach ($entry in $entries) {
    $testId = [string] $entry.TestID
    $excelNeedle = [string] $entry.TestExcelFile
    $inputRef = [string] $entry.TestInputFile
    $resultsRef = [string] $entry.TestResultsFile

    if ([string]::IsNullOrWhiteSpace($testId) -or [string]::IsNullOrWhiteSpace($excelNeedle) -or [string]::IsNullOrWhiteSpace($inputRef)) {
      throw 'Manifest entry is missing required fields.'
    }

    $inputBase = [System.IO.Path]::GetFileName($inputRef).ToLowerInvariant()
    if (-not $inputByBaseName.ContainsKey($inputBase)) {
      throw ('Missing input JSON for manifest reference: ' + $inputRef)
    }

    $inputPath = [string] $inputByBaseName[$inputBase]

    $excelFiles = @(
      Get-ChildItem -Path $excelRoot -File -Recurse |
        Where-Object {
          $_.Name -notlike '~$*' -and
          $_.FullName -notmatch '(?i)(^|[\\/])Batch processing([\\/]|$)' -and
          $_.Name -match [regex]::Escape($excelNeedle) -and
          @('.xlsx', '.xlsm', '.xls') -contains $_.Extension.ToLowerInvariant()
        } |
        Sort-Object LastWriteTime -Descending
    )

    if ($excelFiles.Count -eq 0) {
      throw ('No Excel file found for TestExcelFile value: ' + $excelNeedle)
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

    $targetName = ('{0}_{1}_{2}{3}' -f [System.IO.Path]::GetFileNameWithoutExtension($sourceFile.Name), $RunStamp, $testId, $sourceFile.Extension)
    $targetPath = Join-Path $runOutputDirectory $targetName
    $counter = 2
    while (Test-Path -LiteralPath $targetPath) {
      $targetName = ('{0}_{1}_{2}_{3}{4}' -f [System.IO.Path]::GetFileNameWithoutExtension($sourceFile.Name), $RunStamp, $testId, $counter, $sourceFile.Extension)
      $targetPath = Join-Path $runOutputDirectory $targetName
      $counter++
    }

    Copy-Item -LiteralPath $sourceFile.FullName -Destination $targetPath

    $workbook = $null
    try {
      $workbook = $excel.Workbooks.Open($targetPath)
      $jsonRaw = Get-Content -LiteralPath $inputPath -Raw
      $jsonObject = $jsonRaw | ConvertFrom-Json

      $entryWarnings = New-Object System.Collections.Generic.List[string]
      [void] (Write-NamedInputs -Workbook $workbook -JsonObject $jsonObject -Warnings $entryWarnings)
      [void] (Write-InputTables -Workbook $workbook -JsonObject $jsonObject -Warnings $entryWarnings)

      $workbook.RefreshAll()
      $excel.CalculateFullRebuild()

      $resultNames = Get-ResultNames -RepoRoot $resolvedRepoRoot -ResultsFilePath $resultsRef -Warnings $entryWarnings
      $resultMap = [ordered] @{}

      foreach ($resultName in @($resultNames | Select-Object -Unique)) {
        $nameEntry = $null
        try {
          $nameEntry = $workbook.Names.Item($resultName)
        } catch {
          $nameEntry = $null
        }

        if ($null -eq $nameEntry) {
          $resultMap[$resultName] = $null
          [void] $entryWarnings.Add('Result range not found: ' + $resultName)
          continue
        }

        try {
          $range = $nameEntry.RefersToRange
          if ($null -eq $range) {
            $resultMap[$resultName] = $null
            [void] $entryWarnings.Add('Result range is not readable: ' + $resultName)
            continue
          }
          $resultMap[$resultName] = $range.Value2
        } catch {
          $resultMap[$resultName] = $null
          [void] $entryWarnings.Add('Result read failed for ' + $resultName + ': ' + $_.Exception.Message)
        }
      }

      $workbook.Save()

      foreach ($w in $entryWarnings) {
        [void] $warnings.Add(($testId + ': ' + $w))
      }

      $createdRelative = Get-RelativePathSafe -BasePath $resolvedRepoRoot -TargetPath $targetPath
      [void] $items.Add([pscustomobject]@{
        TestID = $testId
        SourceWorkbook = $sourceFile.FullName
        InputFileUsed = $inputPath
        CreatedWorkbookPath = $targetPath
        CreatedWorkbookRelativePath = $createdRelative
        CreatedWorkbookFileName = [System.IO.Path]::GetFileName($targetPath)
        Results = [pscustomobject] $resultMap
      })
    } finally {
      if ($null -ne $workbook) {
        try { $workbook.Close($true) } catch { }
        try { [void] [System.Runtime.InteropServices.Marshal]::ReleaseComObject($workbook) } catch { }
      }
      [GC]::Collect()
      [GC]::WaitForPendingFinalizers()
    }
  }
} finally {
  if ($null -ne $excel) {
    try { $excel.Quit() } catch { }
    try { [void] [System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel) } catch { }
  }
  [GC]::Collect()
  [GC]::WaitForPendingFinalizers()
}

$resultPayload = [pscustomobject]@{
  RunStamp = $RunStamp
  OutputDirectory = $runOutputDirectory
  OutputDirectoryRelativePath = Get-RelativePathSafe -BasePath $resolvedRepoRoot -TargetPath $runOutputDirectory
  Items = $items
  ValidationWarnings = @($warnings)
}

$resultDirectory = Split-Path -Parent $ResultJsonPath
if (-not [string]::IsNullOrWhiteSpace($resultDirectory) -and -not (Test-Path -LiteralPath $resultDirectory)) {
  [void] (New-Item -ItemType Directory -Path $resultDirectory -Force)
}

$resultPayload | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $ResultJsonPath -Encoding UTF8
Write-Host ('Bulk processing complete. Output directory: ' + $runOutputDirectory)
