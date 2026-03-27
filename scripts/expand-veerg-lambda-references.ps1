param(
  [Parameter(Mandatory = $true)]
  [string] $SourceWorkbook,

  [string] $OutputWorkbook,

  [switch] $DryRun,

  [switch] $DebugFailedWrites
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

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
    foreach ($name in @($workbook.Names)) {
      $nameKey = [string] $name.Name
      if ($nameKey -notmatch 'VEERG') {
        continue
      }

      $definition = Parse-LambdaDefinition -RefersTo ([string] $name.RefersTo)
      if ($null -eq $definition) {
        continue
      }

      $lambdaMap[$nameKey] = $definition
    }

    if ($lambdaMap.Count -eq 0) {
      Write-Host 'No VEERG LAMBDA named functions were found in the workbook.'
      return [pscustomobject]@{ UpdatedCells = 0; LambdaCount = 0 }
    }

    foreach ($sheet in @($workbook.Worksheets)) {
      $formulaCells = $null
      try {
        $formulaCells = $sheet.UsedRange.SpecialCells(-4123)
      } catch {
        $formulaCells = $null
      }

      if ($null -eq $formulaCells) {
        continue
      }

      foreach ($cell in @($formulaCells)) {
        $formula = [string] $cell.Formula
        if ([string]::IsNullOrWhiteSpace($formula) -or $formula -notmatch 'VEERG') {
          continue
        }

        $expanded = Expand-VeergCallsInFormula -Formula $formula -LambdaMap $lambdaMap
        if ($expanded -ne $formula) {
          if (-not $DryRun) {
            $address = [string] $cell.Address($false, $false)
            $sheetName = [string] $sheet.Name
            $writeSucceeded = $false

            # Prefer Formula2 for modern functions (LAMBDA/LET/dynamic arrays), then fall back to Formula.
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

    return [pscustomobject]@{
      UpdatedCells = $updatedCells
      LambdaCount  = $lambdaMap.Count
      WriteErrors  = @($writeErrors)
    }
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
$result = Expand-VeergLambdaReferences -WorkbookPath $resolvedSource -DuplicatedWorkbookPath $resolvedOutput -DryRun:$DryRun

if ($DryRun) {
  Write-Host ("Dry run complete: would update {0} formula cells using {1} VEERG lambdas in {2}" -f $result.UpdatedCells, $result.LambdaCount, $resolvedOutput)
} else {
  Write-Host ("Updated {0} formula cells using {1} VEERG lambdas in {2}" -f $result.UpdatedCells, $result.LambdaCount, $resolvedOutput)
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