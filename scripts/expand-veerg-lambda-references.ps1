param(
  [Parameter(Mandatory = $true)]
  [string] $SourceWorkbook,

  [string] $OutputWorkbook,

  [switch] $DryRun,

  [switch] $DebugFailedWrites
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Test-IsInOldFolder {
  param(
    [Parameter(Mandatory = $true)]
    [string] $Path
  )

  return $Path -match '(?i)(^|[\\/])Old([\\/]|$)'
}

function Get-DefaultOutputPath {
  param(
    [Parameter(Mandatory = $true)]
    [string] $Path
  )

  $directory = Split-Path $Path -Parent
  $name = [System.IO.Path]::GetFileNameWithoutExtension($Path)
  $extension = [System.IO.Path]::GetExtension($Path)
  return Join-Path $directory ("{0}_expanded{1}" -f $name, $extension)
}

function Split-TopLevelArguments {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string] $Text
  )

  $parts = [System.Collections.Generic.List[string]]::new()
  $buffer = New-Object System.Text.StringBuilder
  $depth = 0
  $inString = $false

  for ($i = 0; $i -lt $Text.Length; $i++) {
    $ch = $Text[$i]

    if ($ch -eq '"') {
      if ($inString -and $i + 1 -lt $Text.Length -and $Text[$i + 1] -eq '"') {
        [void] $buffer.Append('"')
        $i++
        continue
      }

      $inString = -not $inString
      [void] $buffer.Append($ch)
      continue
    }

    if (-not $inString) {
      if ($ch -eq '(') {
        $depth++
      } elseif ($ch -eq ')') {
        $depth--
      } elseif ($ch -eq ',' -and $depth -eq 0) {
        $parts.Add($buffer.ToString().Trim())
        $null = $buffer.Clear()
        continue
      }
    }

    [void] $buffer.Append($ch)
  }

  if ($buffer.Length -gt 0 -or $Text.Trim().Length -eq 0) {
    $parts.Add($buffer.ToString().Trim())
  }

  return $parts.ToArray()
}

function Get-ParenthesizedContent {
  param(
    [Parameter(Mandatory = $true)]
    [string] $Text,

    [Parameter(Mandatory = $true)]
    [int] $OpenParenIndex
  )

  if ($OpenParenIndex -lt 0 -or $OpenParenIndex -ge $Text.Length -or $Text[$OpenParenIndex] -ne '(') {
    return $null
  }

  $depth = 0
  $inString = $false
  $start = $OpenParenIndex + 1

  for ($i = $OpenParenIndex; $i -lt $Text.Length; $i++) {
    $ch = $Text[$i]

    if ($ch -eq '"') {
      if ($inString -and $i + 1 -lt $Text.Length -and $Text[$i + 1] -eq '"') {
        $i++
        continue
      }

      $inString = -not $inString
      continue
    }

    if ($inString) {
      continue
    }

    if ($ch -eq '(') {
      $depth++
    } elseif ($ch -eq ')') {
      $depth--

      if ($depth -eq 0) {
        return [pscustomobject]@{
          InnerText = $Text.Substring($start, $i - $start)
          EndIndex  = $i
        }
      }
    }
  }

  return $null
}

function Parse-LambdaDefinition {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string] $RefersTo
  )

  $raw = $RefersTo.Trim()
  if ($raw.StartsWith('=')) {
    $raw = $raw.Substring(1)
  }

  $lambdaTokenIndex = $raw.IndexOf('LAMBDA(', [System.StringComparison]::OrdinalIgnoreCase)
  if ($lambdaTokenIndex -lt 0) {
    return $null
  }

  $openIndex = $raw.IndexOf('(', $lambdaTokenIndex)
  $group = Get-ParenthesizedContent -Text $raw -OpenParenIndex $openIndex
  if ($null -eq $group) {
    return $null
  }

  $tokens = @(Split-TopLevelArguments -Text $group.InnerText)
  if ($tokens.Length -lt 1) {
    return $null
  }

  $parameters = @()
  if ($tokens.Length -gt 1) {
    $parameters = @($tokens[0..($tokens.Length - 2)])
  }

  $body = $tokens[$tokens.Length - 1]

  return [pscustomobject]@{
    Parameters = $parameters
    Body       = $body
  }
}

function Get-MapWithoutKey {
  param(
    [Parameter(Mandatory = $true)]
    [hashtable] $Map,

    [Parameter(Mandatory = $true)]
    [string] $Key
  )

  $clone = @{}
  foreach ($entry in $Map.GetEnumerator()) {
    if ($entry.Key -ne $Key) {
      $clone[$entry.Key] = $entry.Value
    }
  }

  return $clone
}

function Format-ReplacementExpression {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string] $Value
  )

  $trimmed = $Value.Trim()
  if ($trimmed.Length -eq 0) {
    return '()'
  }

  # Keep simple references/identifiers/scalars unwrapped for cleaner final formulas.
  if (
    $trimmed -match '^[A-Za-z_][A-Za-z0-9_\.]*$' -or
    $trimmed -match '^\$?[A-Za-z]{1,3}\$?[0-9]+$' -or
    $trimmed -match '^[+-]?(?:\d+(?:\.\d+)?|\.\d+)(?:[Ee][+-]?\d+)?$' -or
    $trimmed -match '^"(?:[^"]|"")*"$'
  ) {
    return $trimmed
  }

  return "($trimmed)"
}

function Substitute-Expression {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string] $Expression,

    [Parameter(Mandatory = $true)]
    [hashtable] $Replacements
  )

  $result = New-Object System.Text.StringBuilder
  $i = 0
  $inString = $false

  while ($i -lt $Expression.Length) {
    $ch = $Expression[$i]

    if ($ch -eq '"') {
      [void] $result.Append($ch)
      if ($inString -and $i + 1 -lt $Expression.Length -and $Expression[$i + 1] -eq '"') {
        [void] $result.Append('"')
        $i += 2
        continue
      }

      $inString = -not $inString
      $i++
      continue
    }

    if ($inString) {
      [void] $result.Append($ch)
      $i++
      continue
    }

    if ($ch -match '[A-Za-z_]') {
      $start = $i
      $i++
      while ($i -lt $Expression.Length -and $Expression[$i] -match '[A-Za-z0-9_\.]') {
        $i++
      }

      $token = $Expression.Substring($start, $i - $start)
      $wsStart = $i
      while ($wsStart -lt $Expression.Length -and [char]::IsWhiteSpace($Expression[$wsStart])) {
        $wsStart++
      }

      if ($wsStart -lt $Expression.Length -and $Expression[$wsStart] -eq '(') {
        $group = Get-ParenthesizedContent -Text $Expression -OpenParenIndex $wsStart
        if ($null -ne $group) {
          $args = @(Split-TopLevelArguments -Text $group.InnerText)
          $processedArgs = [System.Collections.Generic.List[string]]::new()

          if ($token -ieq 'LET' -and $args.Length -ge 3) {
            $activeMap = $Replacements
            $argIndex = 0

            while ($argIndex -lt ($args.Length - 1)) {
              if ($argIndex + 1 -ge ($args.Length - 1)) {
                $processedArgs.Add((Substitute-Expression -Expression $args[$argIndex] -Replacements $activeMap))
                $argIndex++
                continue
              }

              $nameArg = $args[$argIndex].Trim()
              $valueArg = $args[$argIndex + 1]

              $processedArgs.Add($nameArg)
              $processedArgs.Add((Substitute-Expression -Expression $valueArg -Replacements $activeMap))

              if ($nameArg -match '^[A-Za-z_][A-Za-z0-9_\.]*$') {
                $activeMap = Get-MapWithoutKey -Map $activeMap -Key $nameArg
              }

              $argIndex += 2
            }

            $finalArg = $args[$args.Length - 1]
            $processedArgs.Add((Substitute-Expression -Expression $finalArg -Replacements $activeMap))
          } else {
            foreach ($arg in $args) {
              $processedArgs.Add((Substitute-Expression -Expression $arg -Replacements $Replacements))
            }
          }

          [void] $result.Append($token)
          [void] $result.Append('(')
          [void] $result.Append([string]::Join(', ', $processedArgs))
          [void] $result.Append(')')
          $i = $group.EndIndex + 1
          continue
        }
      }

      if ($Replacements.ContainsKey($token)) {
        [void] $result.Append((Format-ReplacementExpression -Value ([string] $Replacements[$token])))
      } else {
        [void] $result.Append($token)
      }

      continue
    }

    [void] $result.Append($ch)
    $i++
  }

  return $result.ToString()
}

function Expand-VeergCallsInFormula {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string] $Formula,

    [Parameter(Mandatory = $true)]
    [hashtable] $LambdaMap
  )

  $output = $Formula
  $maxPasses = 8

  for ($pass = 0; $pass -lt $maxPasses; $pass++) {
    $changed = $false
    $builder = New-Object System.Text.StringBuilder
    $i = 0

    while ($i -lt $output.Length) {
      $ch = $output[$i]

      if ($ch -match '[A-Za-z_]') {
        $start = $i
        $i++
        while ($i -lt $output.Length -and $output[$i] -match '[A-Za-z0-9_\.]') {
          $i++
        }

        $nameToken = $output.Substring($start, $i - $start)

        if ($nameToken -match 'VEERG' -and $i -lt $output.Length -and $output[$i] -eq '(' -and $LambdaMap.ContainsKey($nameToken)) {
          $group = Get-ParenthesizedContent -Text $output -OpenParenIndex $i
          if ($null -ne $group) {
            $definition = $LambdaMap[$nameToken]
            $callArgs = @(Split-TopLevelArguments -Text $group.InnerText)
            # Normalize FUNC() to zero arguments (Split-TopLevelArguments returns one empty token for empty input).
            if ($callArgs.Length -eq 1 -and [string]::IsNullOrWhiteSpace([string] $callArgs[0])) {
              $callArgs = @()
            }
            $definitionParameters = @($definition.Parameters)

            if ($callArgs.Length -eq $definitionParameters.Length) {
              $replacementMap = @{}
              for ($argIndex = 0; $argIndex -lt $definitionParameters.Length; $argIndex++) {
                $replacementMap[$definitionParameters[$argIndex]] = $callArgs[$argIndex]
              }

              $expandedBody = Substitute-Expression -Expression $definition.Body -Replacements $replacementMap
              [void] $builder.Append('(')
              [void] $builder.Append($expandedBody)
              [void] $builder.Append(')')
              $i = $group.EndIndex + 1
              $changed = $true
              continue
            }
          }
        }

        [void] $builder.Append($nameToken)
        continue
      }

      [void] $builder.Append($ch)
      $i++
    }

    $nextOutput = $builder.ToString()
    if (-not $changed -or $nextOutput -eq $output) {
      break
    }

    $output = $nextOutput
  }

  return $output
}

function Get-WholeFormulaStringLiteralValue {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string] $Formula
  )

  # Match whole-formula string literals like ="text" or =("text").
  $match = [regex]::Match(
    $Formula,
    '^\s*=\s*(?:\(\s*)?"((?:[^"]|"")*)"\s*(?:\)\s*)?$'
  )

  if (-not $match.Success) {
    return $null
  }

  return $match.Groups[1].Value.Replace('""', '"')
}

function Get-WholeFormulaZeroArgFunctionName {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string] $Formula
  )

  $expr = $Formula.Trim()
  if (-not $expr.StartsWith('=')) {
    return $null
  }

  $expr = $expr.Substring(1)
  $expr = Remove-OuterWrappingParentheses -Text $expr

  $match = [regex]::Match($expr, '^\s*([A-Za-z_][A-Za-z0-9_\.]*)\s*\(\s*\)\s*$')
  if (-not $match.Success) {
    return $null
  }

  return $match.Groups[1].Value
}

function Remove-OuterWrappingParentheses {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string] $Text
  )

  $result = $Text.Trim()
  while ($result.Length -ge 2 -and $result[0] -eq '(') {
    $group = Get-ParenthesizedContent -Text $result -OpenParenIndex 0
    if ($null -eq $group -or $group.EndIndex -ne ($result.Length - 1)) {
      break
    }

    $result = $group.InnerText.Trim()
  }

  return $result
}

function Split-TopLevelByDelimiter {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string] $Text,

    [Parameter(Mandatory = $true)]
    [char] $Delimiter
  )

  $parts = [System.Collections.Generic.List[string]]::new()
  $buffer = New-Object System.Text.StringBuilder
  $parenDepth = 0
  $braceDepth = 0
  $inString = $false

  for ($i = 0; $i -lt $Text.Length; $i++) {
    $ch = $Text[$i]

    if ($ch -eq '"') {
      if ($inString -and $i + 1 -lt $Text.Length -and $Text[$i + 1] -eq '"') {
        [void] $buffer.Append('"')
        $i++
        continue
      }

      $inString = -not $inString
      [void] $buffer.Append($ch)
      continue
    }

    if (-not $inString) {
      if ($ch -eq '(') {
        $parenDepth++
      } elseif ($ch -eq ')') {
        $parenDepth--
      } elseif ($ch -eq '{') {
        $braceDepth++
      } elseif ($ch -eq '}') {
        $braceDepth--
      } elseif ($ch -eq $Delimiter -and $parenDepth -eq 0 -and $braceDepth -eq 0) {
        $parts.Add($buffer.ToString().Trim())
        $null = $buffer.Clear()
        continue
      }
    }

    [void] $buffer.Append($ch)
  }

  $parts.Add($buffer.ToString().Trim())
  return $parts.ToArray()
}

function Convert-ExcelLiteralToValue {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string] $Token
  )

  $value = $Token.Trim()
  if ($value -match '^"((?:[^"]|"")*)"$') {
    return $matches[1].Replace('""', '"')
  }

  return $value
}

function Convert-ExcelComValueToText {
  param(
    [Parameter(Mandatory = $false)]
    $Value
  )

  if ($null -eq $Value) {
    return ''
  }

  if ($Value -isnot [System.Array]) {
    return [string] $Value
  }

  $array = $Value
  if ($array.Rank -eq 1) {
    $parts = [System.Collections.Generic.List[string]]::new()
    foreach ($item in @($array)) {
      if ($null -eq $item) {
        $parts.Add('')
      } else {
        $parts.Add([string] $item)
      }
    }

    return [string]::Join(', ', $parts)
  }

  if ($array.Rank -eq 2) {
    $rowStart = $array.GetLowerBound(0)
    $rowEnd = $array.GetUpperBound(0)
    $colStart = $array.GetLowerBound(1)
    $colEnd = $array.GetUpperBound(1)

    $rowStrings = [System.Collections.Generic.List[string]]::new()
    for ($r = $rowStart; $r -le $rowEnd; $r++) {
      $colStrings = [System.Collections.Generic.List[string]]::new()
      for ($c = $colStart; $c -le $colEnd; $c++) {
        $item = $array.GetValue($r, $c)
        if ($null -eq $item) {
          $colStrings.Add('')
        } else {
          $colStrings.Add([string] $item)
        }
      }

      $rowStrings.Add(([string]::Join(', ', $colStrings)))
    }

    return [string]::Join('; ', $rowStrings)
  }

  $flattened = [System.Collections.Generic.List[string]]::new()
  foreach ($item in @($array)) {
    if ($null -eq $item) {
      $flattened.Add('')
    } else {
      $flattened.Add([string] $item)
    }
  }

  return [string]::Join(', ', $flattened)
}

function Get-ExcelCellResolvedValueText {
  param(
    [Parameter(Mandatory = $true)]
    $Cell
  )

  $value = $null
  $spillRange = $null
  try {
    $hasSpill = $false
    try {
      $hasSpill = [bool] $Cell.HasSpill
    } catch {
      $hasSpill = $false
    }

    if ($hasSpill) {
      try {
        $spillRange = $Cell.SpillingToRange
      } catch {
        $spillRange = $null
      }

      if ($null -ne $spillRange) {
        $value = $spillRange.Value2
      }
    }

    if ($null -eq $value) {
      $value = $Cell.Value2
    }
  } finally {
    if ($null -ne $spillRange -and [System.Runtime.InteropServices.Marshal]::IsComObject($spillRange)) {
      [void] [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($spillRange)
    }
  }

  return Convert-ExcelComValueToText -Value $value
}

function Parse-ExcelArrayConstant {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string] $Text
  )

  $raw = $Text.Trim()
  if ($raw.Length -lt 2 -or $raw[0] -ne '{' -or $raw[$raw.Length - 1] -ne '}') {
    return $null
  }

  $inner = $raw.Substring(1, $raw.Length - 2)
  $rows = @(Split-TopLevelByDelimiter -Text $inner -Delimiter ';')
  if ($rows.Length -eq 0) {
    return $null
  }

  $table = [System.Collections.Generic.List[object[]]]::new()
  foreach ($rowText in $rows) {
    $cells = @(Split-TopLevelByDelimiter -Text $rowText -Delimiter ',')
    $rowValues = [System.Collections.Generic.List[object]]::new()
    foreach ($cellText in $cells) {
      $rowValues.Add((Convert-ExcelLiteralToValue -Token $cellText))
    }

    $table.Add($rowValues.ToArray())
  }

  return $table.ToArray()
}

function Get-ChooseColsMakeArrayStringValues {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string] $Formula
  )

  $expr = $Formula.Trim()
  if ($expr.StartsWith('=')) {
    $expr = $expr.Substring(1)
  }
  $expr = Remove-OuterWrappingParentheses -Text $expr

  $chooseToken = 'CHOOSECOLS'
  if (-not $expr.StartsWith($chooseToken, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $null
  }

  $chooseOpen = $expr.IndexOf('(', $chooseToken.Length)
  $chooseGroup = Get-ParenthesizedContent -Text $expr -OpenParenIndex $chooseOpen
  if ($null -eq $chooseGroup -or $chooseGroup.EndIndex -ne ($expr.Length - 1)) {
    return $null
  }

  $chooseArgs = @(Split-TopLevelByDelimiter -Text $chooseGroup.InnerText -Delimiter ',')
  if ($chooseArgs.Length -lt 2) {
    return $null
  }

  $makeExpr = Remove-OuterWrappingParentheses -Text $chooseArgs[0]
  $makeToken = 'MAKEARRAY'
  if (-not $makeExpr.StartsWith($makeToken, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $null
  }

  $makeOpen = $makeExpr.IndexOf('(', $makeToken.Length)
  $makeGroup = Get-ParenthesizedContent -Text $makeExpr -OpenParenIndex $makeOpen
  if ($null -eq $makeGroup -or $makeGroup.EndIndex -ne ($makeExpr.Length - 1)) {
    return $null
  }

  $makeArgs = @(Split-TopLevelByDelimiter -Text $makeGroup.InnerText -Delimiter ',')
  if ($makeArgs.Length -lt 3) {
    return $null
  }

  $rowCount = 0
  if (-not [int]::TryParse($makeArgs[0].Trim(), [ref] $rowCount) -or $rowCount -le 0) {
    return $null
  }

  $lambdaExpr = Remove-OuterWrappingParentheses -Text $makeArgs[2]
  $lambdaToken = 'LAMBDA'
  if (-not $lambdaExpr.StartsWith($lambdaToken, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $null
  }

  $lambdaOpen = $lambdaExpr.IndexOf('(', $lambdaToken.Length)
  $lambdaGroup = Get-ParenthesizedContent -Text $lambdaExpr -OpenParenIndex $lambdaOpen
  if ($null -eq $lambdaGroup -or $lambdaGroup.EndIndex -ne ($lambdaExpr.Length - 1)) {
    return $null
  }

  $lambdaArgs = @(Split-TopLevelByDelimiter -Text $lambdaGroup.InnerText -Delimiter ',')
  if ($lambdaArgs.Length -lt 3) {
    return $null
  }

  $indexExpr = Remove-OuterWrappingParentheses -Text $lambdaArgs[$lambdaArgs.Length - 1]
  $indexToken = 'INDEX'
  if (-not $indexExpr.StartsWith($indexToken, [System.StringComparison]::OrdinalIgnoreCase)) {
    return $null
  }

  $indexOpen = $indexExpr.IndexOf('(', $indexToken.Length)
  $indexGroup = Get-ParenthesizedContent -Text $indexExpr -OpenParenIndex $indexOpen
  if ($null -eq $indexGroup -or $indexGroup.EndIndex -ne ($indexExpr.Length - 1)) {
    return $null
  }

  $indexArgs = @(Split-TopLevelByDelimiter -Text $indexGroup.InnerText -Delimiter ',')
  if ($indexArgs.Length -lt 1) {
    return $null
  }

  $table = Parse-ExcelArrayConstant -Text (Remove-OuterWrappingParentheses -Text $indexArgs[0])
  if ($null -eq $table -or $table.Length -eq 0) {
    return $null
  }

  $selectedColumns = [System.Collections.Generic.List[int]]::new()
  for ($argIndex = 1; $argIndex -lt $chooseArgs.Length; $argIndex++) {
    $colIndex = 0
    if (-not [int]::TryParse($chooseArgs[$argIndex].Trim(), [ref] $colIndex) -or $colIndex -le 0) {
      return $null
    }

    $selectedColumns.Add($colIndex)
  }

  if ($selectedColumns.Count -eq 0) {
    return $null
  }

  $outputRows = [Math]::Min($rowCount, $table.Length)
  if ($outputRows -le 0) {
    return $null
  }

  $values = New-Object 'object[,]' $outputRows, $selectedColumns.Count
  for ($r = 0; $r -lt $outputRows; $r++) {
    $row = @($table[$r])
    for ($c = 0; $c -lt $selectedColumns.Count; $c++) {
      $sourceIndex = $selectedColumns[$c] - 1
      if ($sourceIndex -ge 0 -and $sourceIndex -lt $row.Length) {
        $values[$r, $c] = $row[$sourceIndex]
      } else {
        $values[$r, $c] = ''
      }
    }
  }

  return [pscustomobject]@{
    RowCount    = $outputRows
    ColumnCount = $selectedColumns.Count
    Values      = $values
  }
}

function Expand-VeergLambdaReferences {
  param(
    [Parameter(Mandatory = $true)]
    [string] $WorkbookPath,

    [Parameter(Mandatory = $true)]
    [string] $DuplicatedWorkbookPath,

    [switch] $DryRun
  )

  if (-not (Test-Path $WorkbookPath)) {
    throw "Source workbook not found: $WorkbookPath"
  }

  Copy-Item -Path $WorkbookPath -Destination $DuplicatedWorkbookPath -Force
  Write-Host ("Duplicated workbook: {0}" -f $DuplicatedWorkbookPath)

  $excel = $null
  $workbook = $null
  $updatedCells = 0
  $clearedCells = 0
  $writeErrors = [System.Collections.Generic.List[object]]::new()

  try {
    $excel = New-Object -ComObject Excel.Application
    $excel.Visible = $false
    $excel.DisplayAlerts = $false
    $excel.ScreenUpdating = $false
    $excel.EnableEvents = $false
    $excel.AskToUpdateLinks = $false

    $workbook = $excel.Workbooks.Open($DuplicatedWorkbookPath)

    $lambdaMap = @{}
    $sourceDataStringLambdas = @{}
    foreach ($name in @($workbook.Names)) {
      $nameKey = [string] $name.Name
      $definition = Parse-LambdaDefinition -RefersTo ([string] $name.RefersTo)
      if ($null -eq $definition) {
        continue
      }

      if ($nameKey -match 'VEERG') {
        $lambdaMap[$nameKey] = $definition
      }

      # SourceData string-display helpers can have different module prefixes (e.g. Common_SourceData, SourceData_Dairy, Fertiliser_SourceData).
      if ($nameKey -match 'SourceData' -and @($definition.Parameters).Count -eq 0) {
        $body = $definition.Body.Trim()
        if ($body -match '^"(?:[^"]|"")*"$') {
          $sourceDataStringLambdas[$nameKey] = (Convert-ExcelLiteralToValue -Token $body)
        }
      }
    }

    if ($lambdaMap.Count -eq 0) {
      Write-Host 'No VEERG LAMBDA named functions were found in the workbook. Continuing with cleanup-only pass.'
    }

    foreach ($sheet in @($workbook.Worksheets)) {
      $constantTextCells = $null
      try {
        # xlCellTypeConstants=2, xlTextValues=2
        $constantTextCells = $sheet.UsedRange.SpecialCells(2, 2)
      } catch {
        $constantTextCells = $null
      }

      if ($null -ne $constantTextCells) {
        foreach ($cell in @($constantTextCells.Cells)) {
          $valueText = [string] $cell.Value2
          if ($valueText.Trim() -ne 'Function name') {
            continue
          }

          if (-not $DryRun) {
            [void] $cell.ClearContents()
          }
          $clearedCells++
        }
      }

      $formulaCells = $null
      try {
        $formulaCells = $sheet.UsedRange.SpecialCells(-4123)
      } catch {
        $formulaCells = $null
      }

      if ($null -eq $formulaCells) {
        continue
      }

      foreach ($cell in @($formulaCells.Cells)) {
        $formulaObject = $cell.Formula
        if ($formulaObject -is [System.Array]) {
          continue
        }

        $formula = [string] $formulaObject
        if ([string]::IsNullOrWhiteSpace($formula)) {
          continue
        }

        if ($formula -match '(?i)\bUtility_displayFunctionName\b') {
          if (-not $DryRun) {
            [void] $cell.ClearContents()
          }
          $clearedCells++
          continue
        }

        if ($formula -match '(?i)\b(?:Common_InputFunctions\.)?Utility_DisplayArrayInTable\b') {
          if (-not $DryRun) {
            $cell.Value2 = Get-ExcelCellResolvedValueText -Cell $cell
          }
          $updatedCells++
          continue
        }

        $wholeFunctionName = Get-WholeFormulaZeroArgFunctionName -Formula $formula
        if ($null -ne $wholeFunctionName -and $sourceDataStringLambdas.ContainsKey($wholeFunctionName)) {
          if (-not $DryRun) {
            $cell.Value2 = [string] $sourceDataStringLambdas[$wholeFunctionName]
          }
          $updatedCells++
          continue
        }

        if ($null -ne $wholeFunctionName -and $wholeFunctionName -match 'SourceData') {
          if (-not $DryRun) {
            $cell.Value2 = Get-ExcelCellResolvedValueText -Cell $cell
          }
          $updatedCells++
          continue
        }

        if ($formula -notmatch 'VEERG') {
          continue
        }

        $expanded = Expand-VeergCallsInFormula -Formula $formula -LambdaMap $lambdaMap
        if ($expanded -ne $formula) {
          if (-not $DryRun) {
            $address = [string] $cell.Address($false, $false)
            $sheetName = [string] $sheet.Name
            $writeSucceeded = $false

            $literalValue = Get-WholeFormulaStringLiteralValue -Formula $expanded
            if ($null -ne $literalValue) {
              $cell.Value2 = $literalValue
              $writeSucceeded = $true
            }

            if (-not $writeSucceeded) {
              $arrayValues = Get-ChooseColsMakeArrayStringValues -Formula $expanded
              if ($null -ne $arrayValues) {
                for ($rowOffset = 0; $rowOffset -lt $arrayValues.RowCount; $rowOffset++) {
                  for ($colOffset = 0; $colOffset -lt $arrayValues.ColumnCount; $colOffset++) {
                    $cell.Offset($rowOffset, $colOffset).Value2 = $arrayValues.Values[$rowOffset, $colOffset]
                  }
                }
                $writeSucceeded = $true
              }
            }

            # Prefer Formula2 for modern functions (LAMBDA/LET/dynamic arrays), then fall back to Formula.
            if (-not $writeSucceeded) {
              try {
                $cell.Formula2 = $expanded
                $writeSucceeded = $true
              } catch {
                try {
                  $cell.Formula = $expanded
                  $writeSucceeded = $true
                } catch {
                  $writeErrors.Add([pscustomobject]@{
                    Sheet    = $sheetName
                    Address  = $address
                    Message  = $_.Exception.Message
                    Original = $formula
                    Expanded = $expanded
                  })
                }
              }
            }

            if (-not $writeSucceeded) {
              continue
            }
          }
          $updatedCells++
        }
      }
    }

    if (-not $DryRun) {
      [void] $workbook.Save()
    }

    return ,([pscustomobject]@{
      UpdatedCells = $updatedCells
      ClearedCells = $clearedCells
      LambdaCount  = $lambdaMap.Count
      WriteErrors  = @($writeErrors)
    })
  } finally {
    if ($null -ne $workbook) {
      [void] $workbook.Close($false)
      [void] [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($workbook)
    }

    if ($null -ne $excel) {
      [void] $excel.Quit()
      [void] [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($excel)
    }

    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
  }
}

$resolvedSource = (Resolve-Path $SourceWorkbook).Path
if ([string]::IsNullOrWhiteSpace($OutputWorkbook)) {
  $OutputWorkbook = Get-DefaultOutputPath -Path $resolvedSource
}

$resolvedOutput = [System.IO.Path]::GetFullPath($OutputWorkbook)

if (Test-IsInOldFolder -Path $resolvedSource) {
  throw "Source workbook must not be inside an Old folder: $resolvedSource"
}

if (Test-IsInOldFolder -Path $resolvedOutput) {
  throw "Output workbook must not be inside an Old folder: $resolvedOutput"
}

$result = Expand-VeergLambdaReferences -WorkbookPath $resolvedSource -DuplicatedWorkbookPath $resolvedOutput -DryRun:$DryRun

if ($DryRun) {
  Write-Host ("Dry run complete: would update {0} formula cells and clear {1} helper cells using {2} VEERG lambdas in {3}" -f $result.UpdatedCells, $result.ClearedCells, $result.LambdaCount, $resolvedOutput)
} else {
  Write-Host ("Updated {0} formula cells and cleared {1} helper cells using {2} VEERG lambdas in {3}" -f $result.UpdatedCells, $result.ClearedCells, $result.LambdaCount, $resolvedOutput)
  if ($null -ne $result.WriteErrors -and $result.WriteErrors.Count -gt 0) {
    Write-Warning ("Skipped {0} formula writes due to Excel validation errors:" -f $result.WriteErrors.Count)
    foreach ($err in @($result.WriteErrors)) {
      Write-Warning (" - {0}!{1} :: {2}" -f $err.Sheet, $err.Address, $err.Message)
      if ($DebugFailedWrites) {
        Write-Host ("   Original: {0}" -f $err.Original)
        Write-Host ("   Expanded: {0}" -f $err.Expanded)
      }
    }
  }
}