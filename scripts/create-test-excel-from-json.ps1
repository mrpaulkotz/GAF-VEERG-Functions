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

  $inputTables = @($jsonObject.InputTables)
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

    $columns = @($table.Cols)
    foreach ($col in $columns) {
      if ($null -eq $col) {
        continue
      }

      $columnName = [string] $col.ColumnName
      if ([string]::IsNullOrWhiteSpace($columnName)) {
        $tableCellLabel = ('X_Table_{0}: missing ColumnName' -f $tableName)
        [void] $tableFailed.Add($tableCellLabel)
        [void] $tableFailedDetails.Add($tableCellLabel)
        continue
      }

      $columnCandidateNames = [string[]] @(
        ('X_Table_' + $tableName + 'Col_' + $columnName),
        ('X_Table_' + $tableName + '_Col_' + $columnName),
        ('X_Coord_' + $tableName + '_Col_' + $columnName)
      )
      $columnCellName = ''
      $columnNameEntry = Get-WorkbookNameEntry -Workbook $workbook -CandidateNames $columnCandidateNames -MatchedName ([ref] $columnCellName)

      if ($null -eq $columnNameEntry) {
        [void] $tableMissing.Add([string] $columnCandidateNames[0])
        continue
      }

      $columnHeaderRange = $null
      try {
        $columnHeaderRange = $columnNameEntry.RefersToRange
      } catch {
        $columnHeaderRange = $null
      }

      if ($null -eq $columnHeaderRange) {
        [void] $tableFailed.Add($columnCellName)
        [void] $tableFailedDetails.Add($columnCellName + ': column name does not refer to a range')
        continue
      }

      $rows = @($col.Rows)
      foreach ($row in $rows) {
        if ($null -eq $row) {
          continue
        }

        $rowName = [string] $row.RowName
        if ([string]::IsNullOrWhiteSpace($rowName)) {
          $tableCellLabel = ('X_Table_{0}Col_{1}: missing RowName' -f $tableName, $columnName)
          [void] $tableFailed.Add($tableCellLabel)
          [void] $tableFailedDetails.Add($tableCellLabel)
          continue
        }

        $rowCandidateNames = [string[]] @(
          ('X_Table_' + $tableName + 'Row_' + $rowName),
          ('X_Table_' + $tableName + '_Row_' + $rowName),
          ('X_Coord_' + $tableName + '_Row_' + $rowName)
        )
        $rowCellName = ''
        $rowNameEntry = Get-WorkbookNameEntry -Workbook $workbook -CandidateNames $rowCandidateNames -MatchedName ([ref] $rowCellName)

        $rowHeaderRange = $null
        if ($null -ne $rowNameEntry) {
          try {
            $rowHeaderRange = $rowNameEntry.RefersToRange
          } catch {
            $rowHeaderRange = $null
          }
        }

        if ($null -eq $rowHeaderRange) {
          $springName = ''
          $springCandidateNames = [string[]] @(
            ('X_Table_' + $tableName + 'Row_Spring'),
            ('X_Table_' + $tableName + '_Row_Spring'),
            ('X_Coord_' + $tableName + '_Row_Spring')
          )
          $springEntry = Get-WorkbookNameEntry -Workbook $workbook -CandidateNames $springCandidateNames -MatchedName ([ref] $springName)

          if ($null -ne $springEntry) {
            $springRange = $null
            try {
              $springRange = $springEntry.RefersToRange
            } catch {
              $springRange = $null
            }

            if ($null -ne $springRange) {
              $scanWorksheet = $springRange.Worksheet
              $scanColumn = [int] $springRange.Column
              $scanStartRow = [int] $springRange.Row
              $scanEndRow = $scanStartRow + 200
              for ($scanRow = $scanStartRow; $scanRow -le $scanEndRow; $scanRow++) {
                $scanValue = $scanWorksheet.Cells.Item($scanRow, $scanColumn).Value2
                if ($null -eq $scanValue) {
                  continue
                }

                if ([string]::Equals(([string] $scanValue).Trim(), $rowName, [System.StringComparison]::OrdinalIgnoreCase)) {
                  $rowHeaderRange = $scanWorksheet.Cells.Item($scanRow, $scanColumn)
                  $rowCellName = $springName + '->' + $rowName
                  break
                }
              }
            }
          }
        }

        if ($null -eq $rowHeaderRange) {
          [void] $tableMissing.Add([string] $rowCandidateNames[0])
          continue
        }

        if ($columnHeaderRange.Worksheet.Name -ne $rowHeaderRange.Worksheet.Name) {
          $tableCellLabel = ('{0} + {1}' -f $columnCellName, $rowCellName)
          [void] $tableFailed.Add($tableCellLabel)
          [void] $tableFailedDetails.Add($tableCellLabel + ': row and column headers are on different worksheets')
          continue
        }

        try {
          $targetCell = $rowHeaderRange.Worksheet.Cells.Item($rowHeaderRange.Row, $columnHeaderRange.Column)
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
          $tableCellLabel = ('{0} + {1}' -f $columnCellName, $rowCellName)
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
