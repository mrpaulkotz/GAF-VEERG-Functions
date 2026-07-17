param(
  [string] $RepoRoot = $(Split-Path $PSScriptRoot -Parent),
  [string] $ExcelSearchRoot,
  [string] $InputFieldsRoot,
  [string] $ConfigPath,
  [string] $TestID,
  [string] $Suffix = '_test',
  [ValidateSet('Test', 'Emissions')]
  [string] $Context = 'Test',
  [double] $DifferenceTolerance = 0.00001
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Context distinguishes how the CanOverWriteFormula rule is applied:
#   Test      - generating a test workbook: overwrite every targeted cell (including
#               protected formula cells) so all test inputs land in the sheet.
#   Emissions - mirror the emissions-calculation consumer (e.g. conversational-input):
#               only overwrite formula cells whose definition opts in via
#               CanOverWriteFormula, leaving all other formulas intact.
$overwriteAllFormulas = ($Context -eq 'Test')

if (-not (Test-Path -LiteralPath $RepoRoot)) {
  $fallbackRepoRoot = Split-Path $PSScriptRoot -Parent
  if (Test-Path -LiteralPath $fallbackRepoRoot) {
    $RepoRoot = $fallbackRepoRoot
  } else {
    throw "RepoRoot path '$RepoRoot' was not found and fallback '$fallbackRepoRoot' is unavailable."
  }
}

$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

if ([string]::IsNullOrWhiteSpace($ExcelSearchRoot)) {
  $ExcelSearchRoot = Join-Path $RepoRoot 'Excel'
}

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
  $ConfigPath = Join-Path $RepoRoot 'Test\Test.json'
}

if ([string]::IsNullOrWhiteSpace($InputFieldsRoot)) {
  $InputFieldsRoot = Join-Path $RepoRoot 'InputFields'
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

$testExcelDirectoryName = $null
if (@($testEntry.PSObject.Properties.Name) -contains 'TestExcelDirectory') {
  $testExcelDirectoryName = [string] $testEntry.TestExcelDirectory
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

$excelSearchRoot = $resolvedExcelRoot
if (-not [string]::IsNullOrWhiteSpace($testExcelDirectoryName)) {
  $candidateSearchRoot = Join-Path $resolvedExcelRoot $testExcelDirectoryName
  if (-not (Test-Path -LiteralPath $candidateSearchRoot -PathType Container)) {
    throw "TestExcelDirectory '$testExcelDirectoryName' for TestID '$TestID' was not found under '$resolvedExcelRoot'."
  }
  $excelSearchRoot = (Resolve-Path -LiteralPath $candidateSearchRoot).Path
}

$excelFiles = @(
  Get-ChildItem -Path $excelSearchRoot -File -Recurse |
    Where-Object {
      $_.Name -notlike '~$*' -and
      $_.Name -match [regex]::Escape($nameContains) -and
      @('.xlsx', '.xlsm', '.xls') -contains $_.Extension.ToLowerInvariant()
    } |
    Sort-Object LastWriteTime -Descending
)

if ($excelFiles.Count -eq 0) {
  throw "No Excel files found under '$excelSearchRoot' with '$nameContains' in the filename."
}

$preferredExcelFiles = @(
  $excelFiles |
    Where-Object {
      $_.FullName -notmatch '(?i)[\\/]TestExcel[\\/]' -and
      $_.BaseName -notmatch '(?i)_expanded(?:_tmp\d*)?$' -and
      $_.BaseName -notmatch '(?i)_test(?:_\d{4}_\d{8})?(?:_\d+)?$'
    }
)

$nonTestExcelFiles = @(
  $excelFiles |
    Where-Object { $_.FullName -notmatch '(?i)[\\/]TestExcel[\\/]' }
)

$sourceCandidates = if ($preferredExcelFiles.Count -gt 0) {
  $preferredExcelFiles
} elseif ($nonTestExcelFiles.Count -gt 0) {
  $nonTestExcelFiles
} else {
  $excelFiles
}

$sourceFile = $sourceCandidates[0]
$baseName = [System.IO.Path]::GetFileNameWithoutExtension($sourceFile.Name)
$sourceIsInTestExcel = $sourceFile.FullName -match '(?i)[\\/]TestExcel[\\/]'
if ($sourceIsInTestExcel -or [string]::IsNullOrWhiteSpace($baseName)) {
  $baseName = [string] $nameContains
}

$baseName = [regex]::Replace($baseName, '[^A-Za-z0-9._-]+', '_')
if ([string]::IsNullOrWhiteSpace($baseName)) {
  $baseName = 'GeneratedWorkbook'
}

if ($baseName.Length -gt 64) {
  $baseName = $baseName.Substring(0, 64).TrimEnd('_')
}

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
$formulaWriteSkips = 0
$formulaWriteSkipDetails = New-Object System.Collections.Generic.List[string]
$formulaOverwriteCellNames = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
$formulaOverwriteTableFields = @{}
$formulaOverwriteTableNames = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)

function Add-FormulaOverwriteTableField {
  param(
    [Parameter(Mandatory = $false)]
    [string] $TableName,

    [Parameter(Mandatory = $false)]
    [string] $FieldName
  )

  if ([string]::IsNullOrWhiteSpace($TableName) -or [string]::IsNullOrWhiteSpace($FieldName)) {
    return
  }

  $normalizedTableName = $TableName.ToLowerInvariant()
  if (-not $formulaOverwriteTableFields.ContainsKey($normalizedTableName)) {
    $formulaOverwriteTableFields[$normalizedTableName] = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
  }

  [void] $formulaOverwriteTableFields[$normalizedTableName].Add($FieldName)
}

function Add-FormulaOverwriteTableName {
  param(
    [Parameter(Mandatory = $false)]
    [string] $TableName
  )

  if ([string]::IsNullOrWhiteSpace($TableName)) {
    return
  }

  [void] $formulaOverwriteTableNames.Add($TableName)
}

function Test-IsTruthyFlag {
  param(
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [object] $Value
  )

  if ($Value -is [bool]) {
    return [bool] $Value
  }

  if ($null -eq $Value) {
    return $false
  }

  $text = [string] $Value
  if ([string]::IsNullOrWhiteSpace($text)) {
    return $false
  }

  $normalized = $text.Trim().ToLowerInvariant()
  return @('true', '1', 'yes', 'y') -contains $normalized
}

function Get-InputFieldFileCandidates {
  param(
    [Parameter(Mandatory = $false)]
    [string] $TestInputFile,

    [Parameter(Mandatory = $false)]
    [string] $TestExcelFile
  )

  $candidates = New-Object System.Collections.Generic.List[string]
  [void] $candidates.Add('Common_InputFields.json')

  $inputBaseName = [System.IO.Path]::GetFileNameWithoutExtension([string] $TestInputFile)
  if (-not [string]::IsNullOrWhiteSpace($inputBaseName) -and $inputBaseName.StartsWith('TestInput_', [System.StringComparison]::OrdinalIgnoreCase)) {
    [void] $candidates.Add(($inputBaseName.Substring('TestInput_'.Length) + '_InputFields.json'))
  }

  $excelBaseName = [string] $TestExcelFile
  if (-not [string]::IsNullOrWhiteSpace($excelBaseName)) {
    $excelBaseName = [regex]::Replace($excelBaseName, '_WIP_v\d+$', '', [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $excelBaseName = [regex]::Replace($excelBaseName, '^\d+(?:_\d+)?_', '')
    if (-not [string]::IsNullOrWhiteSpace($excelBaseName)) {
      [void] $candidates.Add(($excelBaseName + '_InputFields.json'))
    }
  }

  $unique = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::OrdinalIgnoreCase)
  $result = New-Object System.Collections.Generic.List[string]
  foreach ($item in $candidates) {
    if ([string]::IsNullOrWhiteSpace($item)) { continue }
    if ($unique.Add($item)) {
      [void] $result.Add($item)
    }
  }

  return @($result)
}

function Add-OverwritePolicyFromInputFieldDefinition {
  param(
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [object] $Definition
  )

  if ($null -eq $Definition) {
    return
  }

  $getOptionalPropertyValue = {
    param(
      [Parameter(Mandatory = $false)]
      [AllowNull()]
      [object] $Source,

      [Parameter(Mandatory = $true)]
      [string] $PropertyName
    )

    if ($null -eq $Source -or [string]::IsNullOrWhiteSpace($PropertyName)) {
      return $null
    }

    if ($null -eq $Source.PSObject -or $null -eq $Source.PSObject.Properties) {
      return $null
    }

    $property = $Source.PSObject.Properties[$PropertyName]
    if ($null -eq $property) {
      return $null
    }

    return $property.Value
  }

  $getFormulaOverwriteFlag = {
    param(
      [Parameter(Mandatory = $false)]
      [AllowNull()]
      [object] $Source
    )

    $value = & $getOptionalPropertyValue -Source $Source -PropertyName 'CanOverWriteFormula'
    if ($null -eq $value) {
      $value = & $getOptionalPropertyValue -Source $Source -PropertyName 'CanOverwriteFormula'
    }

    return $value
  }

  foreach ($inputCell in @($Definition.InputCells)) {
    if ($null -eq $inputCell) { continue }
    $cellOverwriteFlag = & $getFormulaOverwriteFlag -Source $inputCell
    if (Test-IsTruthyFlag -Value $cellOverwriteFlag) {
      $cellName = [string] $inputCell.CellName
      if (-not [string]::IsNullOrWhiteSpace($cellName)) {
        [void] $formulaOverwriteCellNames.Add($cellName)
      }
    }
  }

  foreach ($inputTable in @($Definition.InputTables)) {
    if ($null -eq $inputTable) { continue }
    $tableName = [string] $inputTable.TableName
    if ([string]::IsNullOrWhiteSpace($tableName)) { continue }

    foreach ($tableBranchName in @('Rows', 'Cols')) {
      if (-not ($inputTable.PSObject.Properties.Name -contains $tableBranchName)) {
        continue
      }

      $tableBranch = $inputTable.$tableBranchName
      if ($null -eq $tableBranch -or $null -eq $tableBranch.PSObject -or $null -eq $tableBranch.PSObject.Properties) {
        continue
      }

      foreach ($branchDefinition in @($tableBranch.PSObject.Properties)) {
        if ($null -eq $branchDefinition -or $null -eq $branchDefinition.Value) { continue }
        $branchValue = $branchDefinition.Value
        if ($null -eq $branchValue.PSObject -or $null -eq $branchValue.PSObject.Properties) { continue }

        foreach ($field in @($branchValue.PSObject.Properties)) {
          if ($null -eq $field -or $null -eq $field.Value) { continue }
          $fieldOverwriteFlag = & $getFormulaOverwriteFlag -Source $field.Value
          if (Test-IsTruthyFlag -Value $fieldOverwriteFlag) {
            Add-FormulaOverwriteTableField -TableName $tableName -FieldName ([string] $field.Name)
            Add-FormulaOverwriteTableName -TableName $tableName
          }
        }
      }
    }
  }
}

$inputFieldsRoot = $InputFieldsRoot
if (Test-Path -LiteralPath $inputFieldsRoot) {
  $inputFieldFileCandidates = @(Get-InputFieldFileCandidates -TestInputFile $testInputFile -TestExcelFile $nameContains)
  foreach ($candidate in $inputFieldFileCandidates) {
    $candidatePath = Join-Path $inputFieldsRoot $candidate
    if (-not (Test-Path -LiteralPath $candidatePath)) {
      continue
    }

    try {
      $candidateDefinitionRaw = Get-Content -LiteralPath $candidatePath -Raw
      $candidateDefinition = $candidateDefinitionRaw | ConvertFrom-Json
      Add-OverwritePolicyFromInputFieldDefinition -Definition $candidateDefinition
    } catch {
      # Ignore malformed/missing InputFields files and continue with other sources.
    }
  }
}

$overwritePolicy = $null
if ($jsonObject.PSObject.Properties.Name -contains '__FormulaOverwritePolicy') {
  $overwritePolicy = $jsonObject.__FormulaOverwritePolicy
}

if ($null -ne $overwritePolicy) {
  if ($overwritePolicy.PSObject.Properties.Name -contains 'Cells' -and $null -ne $overwritePolicy.Cells) {
    $cellsRaw = $overwritePolicy.Cells
    if ($cellsRaw -is [System.Collections.IEnumerable] -and -not ($cellsRaw -is [string])) {
      foreach ($cellName in @($cellsRaw)) {
        if ($null -eq $cellName) { continue }
        $cellNameText = [string] $cellName
        if (-not [string]::IsNullOrWhiteSpace($cellNameText)) {
          [void] $formulaOverwriteCellNames.Add($cellNameText)
        }
      }
    } elseif ($null -ne $cellsRaw) {
      $cellNameText = [string] $cellsRaw
      if (-not [string]::IsNullOrWhiteSpace($cellNameText)) {
        [void] $formulaOverwriteCellNames.Add($cellNameText)
      }
    }
  }

  if ($overwritePolicy.PSObject.Properties.Name -contains 'Tables' -and $null -ne $overwritePolicy.Tables) {
    foreach ($tableProp in @($overwritePolicy.Tables.PSObject.Properties)) {
      if ($null -eq $tableProp) { continue }

      $tableName = [string] $tableProp.Name
      if ([string]::IsNullOrWhiteSpace($tableName)) { continue }
      Add-FormulaOverwriteTableName -TableName $tableName

      $fieldsRaw = $tableProp.Value
      if ($fieldsRaw -is [System.Collections.IEnumerable] -and -not ($fieldsRaw -is [string])) {
        foreach ($fieldName in @($fieldsRaw)) {
          if ($null -eq $fieldName) { continue }
          $fieldText = [string] $fieldName
          if (-not [string]::IsNullOrWhiteSpace($fieldText)) {
            Add-FormulaOverwriteTableField -TableName $tableName -FieldName $fieldText
          }
        }
      } elseif ($null -ne $fieldsRaw) {
        $fieldText = [string] $fieldsRaw
        if (-not [string]::IsNullOrWhiteSpace($fieldText)) {
          Add-FormulaOverwriteTableField -TableName $tableName -FieldName $fieldText
        }
      }
    }
  }
}

$debugFormulaPolicy = Test-IsTruthyFlag -Value $env:VEERG_DEBUG_FORMULA_POLICY
if ($debugFormulaPolicy) {
  if ($formulaOverwriteCellNames.Count -gt 0) {
    Write-Host 'Formula overwrite named-cell policy:'
    foreach ($cellName in @($formulaOverwriteCellNames | Sort-Object)) {
      Write-Host ('  - ' + $cellName)
    }
  }

  if ($formulaOverwriteTableFields.Count -gt 0) {
    Write-Host 'Formula overwrite table-field policy:'
    foreach ($tableKey in @($formulaOverwriteTableFields.Keys | Sort-Object)) {
      $fieldSet = $formulaOverwriteTableFields[$tableKey]
      $fieldsText = if ($null -eq $fieldSet) { '' } else { (@($fieldSet | Sort-Object) -join ', ') }
      Write-Host ('  - ' + $tableKey + ': ' + $fieldsText)
    }
  } else {
    Write-Host 'Formula overwrite table-field policy: none'
  }

  if ($formulaOverwriteTableNames.Count -gt 0) {
    Write-Host 'Formula overwrite table-name policy:'
    foreach ($tableName in @($formulaOverwriteTableNames | Sort-Object)) {
      Write-Host ('  - ' + $tableName)
    }
  } else {
    Write-Host 'Formula overwrite table-name policy: none'
  }
}

function Test-AllowFormulaOverwriteNamedCell {
  param(
    [Parameter(Mandatory = $false)]
    [string] $CellName
  )

  if ([string]::IsNullOrWhiteSpace($CellName)) {
    return $false
  }

  return $formulaOverwriteCellNames.Contains($CellName)
}

function Test-AllowFormulaOverwriteTableField {
  param(
    [Parameter(Mandatory = $false)]
    [string] $TableName,

    [Parameter(Mandatory = $false)]
    [string] $FieldName
  )

  if ([string]::IsNullOrWhiteSpace($TableName)) {
    return $false
  }

  if ($formulaOverwriteTableNames.Contains($TableName)) {
    return $true
  }

  if ([string]::IsNullOrWhiteSpace($FieldName)) {
    return $false
  }

  $normalizedTableName = $TableName.ToLowerInvariant()
  if (-not $formulaOverwriteTableFields.ContainsKey($normalizedTableName)) {
    return $false
  }

  $fieldSet = $formulaOverwriteTableFields[$normalizedTableName]
  if ($null -eq $fieldSet) {
    return $false
  }

  return $fieldSet.Contains($FieldName)
}

function Test-AllowFormulaOverwriteTableFieldAny {
  param(
    [Parameter(Mandatory = $false)]
    [string] $TableName,

    [Parameter(Mandatory = $false)]
    [string[]] $FieldNames
  )

  if ([string]::IsNullOrWhiteSpace($TableName) -or $null -eq $FieldNames -or $FieldNames.Count -eq 0) {
    return $false
  }

  if ($formulaOverwriteTableNames.Contains($TableName)) {
    return $true
  }

  foreach ($fieldName in $FieldNames) {
    if (Test-AllowFormulaOverwriteTableField -TableName $TableName -FieldName $fieldName) {
      return $true
    }
  }

  return $false
}

function Test-CellContainsFormula {
  param(
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [object] $Cell
  )

  if ($null -eq $Cell) {
    return $false
  }

  try {
    $hasFormula = $Cell.HasFormula
    if ($hasFormula -is [bool] -and $hasFormula) {
      return $true
    }
  } catch {
    # Ignore COM errors and fallback to formula text checks.
  }

  foreach ($formulaProperty in @('Formula', 'FormulaLocal', 'FormulaR1C1')) {
    try {
      $formulaText = [string] $Cell.$formulaProperty
      if (-not [string]::IsNullOrWhiteSpace($formulaText) -and $formulaText.TrimStart().StartsWith('=')) {
        return $true
      }
    } catch {
      # Ignore property access failures.
    }
  }

  return $false
}

function Set-CellValueIfWritable {
  param(
    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [object] $Cell,

    [Parameter(Mandatory = $false)]
    [AllowNull()]
    [object] $Value,

    [Parameter(Mandatory = $false)]
    [bool] $AllowFormulaOverwrite = $false
  )

  if ($null -eq $Cell) {
    return $false
  }

  if ((Test-CellContainsFormula -Cell $Cell) -and -not $AllowFormulaOverwrite) {
    return $false
  }

  if ($null -eq $Value) {
    $Cell.Value2 = ''
  } elseif ($Value -is [bool]) {
    $Cell.Value2 = if ($Value) { 1 } else { 0 }
  } elseif (
    $Value -is [byte] -or
    $Value -is [sbyte] -or
    $Value -is [int16] -or
    $Value -is [uint16] -or
    $Value -is [int32] -or
    $Value -is [uint32] -or
    $Value -is [int64] -or
    $Value -is [uint64] -or
    $Value -is [single] -or
    $Value -is [double] -or
    $Value -is [decimal]
  ) {
    $Cell.Value2 = [string] $Value
  } else {
    $Cell.Value2 = $Value
  }

  return $true
}

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
      $rowsRawValue = if ($ColsRaw.PSObject.Properties.Name -contains 'Rows') { $ColsRaw.Rows } else { $null }
      [void] $columns.Add([pscustomobject]@{
        ColumnName = $colName
        Rows       = Convert-TableRowsToList -RowsRaw $rowsRawValue
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

        $rowsRawValue = if ($candidateCol.PSObject.Properties.Name -contains 'Rows') { $candidateCol.Rows } else { $null }
        [void] $columns.Add([pscustomobject]@{
          ColumnName = $colName
          Rows       = Convert-TableRowsToList -RowsRaw $rowsRawValue
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
    'InputTables',
    '__FormulaOverwritePolicy'
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
      $allowFormulaOverwrite = $overwriteAllFormulas -or (Test-AllowFormulaOverwriteNamedCell -CellName ([string] $prop.Name))
      if (Set-CellValueIfWritable -Cell $range -Value $value -AllowFormulaOverwrite $allowFormulaOverwrite) {
        $updated++
      } else {
        $formulaWriteSkips++
        [void] $formulaWriteSkipDetails.Add(([string] $prop.Name + ': skipped write because target cell contains formula'))
      }
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

            $allowFormulaOverwrite = $overwriteAllFormulas -or (Test-AllowFormulaOverwriteTableField -TableName $tableRangeName -FieldName ([string] $prop.Name))
            if (Set-CellValueIfWritable -Cell $targetCell -Value $tableValue -AllowFormulaOverwrite $allowFormulaOverwrite) {
              $updatedInputTableCells++
            } else {
              $formulaWriteSkips++
              [void] $formulaWriteSkipDetails.Add(($tableRangeName + ': row=' + $targetRowPosition + ', col=' + $targetColumnPosition + ', field=' + [string] $prop.Name + ', allowOverwrite=' + [string] $allowFormulaOverwrite + ': skipped write because target cell contains formula'))
            }
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

          $columnName = [string] $colEntry.Column.ColumnName
          $allowFormulaOverwrite = $overwriteAllFormulas -or (Test-AllowFormulaOverwriteTableFieldAny -TableName $tableRangeName -FieldNames @($rowName, $columnName))
          if (Set-CellValueIfWritable -Cell $targetCell -Value $tableValue -AllowFormulaOverwrite $allowFormulaOverwrite) {
            $updatedInputTableCells++
          } else {
            $formulaWriteSkips++
            [void] $formulaWriteSkipDetails.Add(($tableRangeName + ': row=' + $targetRowPosition + ', col=' + $targetColumnPosition + ', field=' + $rowName + '/' + $columnName + ', allowOverwrite=' + [string] $allowFormulaOverwrite + ': skipped write because target cell contains formula'))
          }
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
Write-Host ("Context: {0}{1}" -f $Context, $(if ($overwriteAllFormulas) { ' (overwriting all cells, including protected formulas)' } else { ' (respecting CanOverWriteFormula protection)' }))
Write-Host ("Test config: {0}" -f $resolvedConfigPath)
Write-Host ("JSON file: {0}" -f $resolvedJsonPath)
Write-Host ("Results file: {0}" -f $resolvedResultsPath)
Write-Host ("Named cells updated: {0}" -f $updated)
Write-Host ("Input table cells updated: {0}" -f $updatedInputTableCells)
Write-Host ("Formula-backed cells skipped: {0}" -f $formulaWriteSkips)

if ($formulaWriteSkips -gt 0) {
  Write-Warning 'Skipped writes to formula-backed cells:'
  foreach ($detail in @($formulaWriteSkipDetails | Sort-Object -Unique)) {
    Write-Warning ('  - ' + $detail)
  }
}

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
