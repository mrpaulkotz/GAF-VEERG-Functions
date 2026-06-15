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

    if (-not ($table.PSObject.Properties.Name -contains 'Cols')) {
      [void] $Warnings.Add('Input table ' + $tableName + ' has no Cols')
      continue
    }

    $tableRangeName = 'X_Table_' + $tableName
    $tableNameEntry = Get-WorkbookNameEntry -Workbook $Workbook -CandidateNames ([string[]] @($tableRangeName))
    if ($null -eq $tableNameEntry) {
      [void] $Warnings.Add('Missing named table range: ' + $tableRangeName)
      continue
    }

    $tableRange = $null
    try {
      $tableRange = $tableNameEntry.RefersToRange
    } catch {
      $tableRange = $null
    }

    if ($null -eq $tableRange) {
      [void] $Warnings.Add('Table range is not writable: ' + $tableRangeName)
      continue
    }

    $tableRangeRowCount = [int] $tableRange.Rows.Count
    $tableRangeColumnCount = [int] $tableRange.Columns.Count

    $columnOffset = 1
    if ($table.PSObject.Properties.Name -contains 'ColumnOffset' -and $null -ne $table.ColumnOffset) {
      $parsedColumnOffset = 0
      if ([int]::TryParse([string] $table.ColumnOffset, [ref] $parsedColumnOffset)) {
        $columnOffset = $parsedColumnOffset
      }
    }

    $rowOffset = 1
    if ($table.PSObject.Properties.Name -contains 'RowOffset' -and $null -ne $table.RowOffset) {
      $parsedRowOffset = 0
      if ([int]::TryParse([string] $table.RowOffset, [ref] $parsedRowOffset)) {
        $rowOffset = $parsedRowOffset
      }
    }

    $columns = @($table.Cols)
    for ($colIndex = 0; $colIndex -lt $columns.Count; $colIndex++) {
      $col = $columns[$colIndex]
      if ($null -eq $col) {
        continue
      }

      $columnPosition = $colIndex + 1 + $columnOffset
      if ($columnPosition -lt 1 -or $columnPosition -gt $tableRangeColumnCount) {
        [void] $Warnings.Add(($tableRangeName + ': column position ' + $columnPosition + ' outside width ' + $tableRangeColumnCount))
        continue
      }

      $rows = @($col.Rows)
      for ($rowIndex = 0; $rowIndex -lt $rows.Count; $rowIndex++) {
        $row = $rows[$rowIndex]
        if ($null -eq $row) {
          continue
        }

        $rowPosition = $rowIndex + 1 + $rowOffset
        if ($rowPosition -lt 1 -or $rowPosition -gt $tableRangeRowCount) {
          [void] $Warnings.Add(($tableRangeName + ': row position ' + $rowPosition + ' outside height ' + $tableRangeRowCount))
          continue
        }

        try {
          $targetCell = $tableRange.Cells.Item($rowPosition, $columnPosition)
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
          [void] $Warnings.Add(($tableRangeName + ': row=' + $rowPosition + ', col=' + $columnPosition + ': ' + $_.Exception.Message))
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
