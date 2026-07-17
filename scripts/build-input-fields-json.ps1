<#
.SYNOPSIS
  Generates JSON descriptions of the user-input fields found in the VEERG module
  workbooks under Excel/.

.DESCRIPTION
  For every Excel/*.xlsx workbook (skipping Old/, ~$ lock files and *_expanded copies)
  this script uses Excel COM automation to discover:

    * InputCells  - workbook-scoped defined names matching ^X_Cell_, resolving each
                    cell's data-validation list into a CellType + Options structure
                    (including cascading INDIRECT($Parent) dropdowns).
    * InputTables - ListObjects matching ^X_Table_ or ^Table_Input, describing the
                    per-field CellType / Unit / overwrite metadata and the table's
                    MatrixType (RowsToCols vs ColsToRows).

  A per-field override file (InputFields/_overrides/<Module>.json) is merged over the
  generated result so manual settings (Label, Group, Default, Hidden, etc.) survive
  regeneration. The result is written to
  InputFields/<Module>_InputFields.json as UTF-8 WITHOUT a BOM.

  Formula input cells use the _Method naming convention:
    *_Method2  -> the cell has a formula but the user may overwrite it
                  (CanOverWriteFormula = true).
    *_Method1  -> the cell has a protected formula (no flag).

.PARAMETER RepoRoot
  Repository root. Defaults to the parent of the scripts/ folder.

.PARAMETER WorkbookPath
  Optional path to a single workbook. When omitted, every eligible Excel/*.xlsx is
  processed.

.PARAMETER DryRun
  Discover and validate but write no JSON files.

.OUTPUTS
  One InputFields/<Module>_InputFields.json per workbook (UTF-8, no BOM).
#>
param(
  [string] $RepoRoot = $(Split-Path $PSScriptRoot -Parent),
  [string] $WorkbookPath,
  [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$schemaVersion = 1

# Excel constants
$xlValidateList = 3

$script:ValidationWarningCount = 0

# ---------------------------------------------------------------------------
# Helpers (no COM)
# ---------------------------------------------------------------------------

function Get-ModuleName {
  param([Parameter(Mandatory = $true)] [string] $WorkbookFile)

  $base = [System.IO.Path]::GetFileNameWithoutExtension($WorkbookFile)
  # Drop trailing version suffix: _WIP_v07, _v02, etc.
  $base = $base -replace '(?i)_(?:WIP_)?v\d+$', ''
  # Drop the leading section-number prefix(es): 5_, 4_1_, 14_, 3_2_ ...
  $base = $base -replace '^(?:\d+_)+', ''
  return $base
}

function Get-ShortDefinedName {
  param([Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $NameLocal)

  $shortName = $NameLocal
  $bangIndex = $NameLocal.LastIndexOf('!')
  if ($bangIndex -ge 0 -and $bangIndex -lt ($NameLocal.Length - 1)) {
    $shortName = $NameLocal.Substring($bangIndex + 1)
  }
  return $shortName.Trim("'")
}

function Get-FieldKeyFromHeader {
  param([Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Header)

  # Strip any parenthetical (unit) annotation, then PascalCase the remaining words.
  $noParen = [regex]::Replace($Header, '\([^)]*\)', '')
  # Preserve comparison / range semantics that would otherwise be erased when the
  # symbols are dropped, so e.g. "Bulls < 1 year" and "Bulls > 1 year" stay distinct
  # machine keys ("BullsUnder1Year" / "BullsOver1Year") instead of colliding.
  $noParen = [regex]::Replace($noParen, '<', ' Under ')
  $noParen = [regex]::Replace($noParen, '>', ' Over ')
  $noParen = [regex]::Replace($noParen, '(?<=\d)\s*-\s*(?=\d)', ' To ')
  $parts = @([regex]::Split($noParen.Trim(), '[^A-Za-z0-9]+') | Where-Object { $_ -ne '' })
  if ($parts.Count -eq 0) {
    return ($Header -replace '[^A-Za-z0-9]+', '')
  }
  $key = ($parts | ForEach-Object {
      if ($_.Length -le 1) { $_.ToUpperInvariant() }
      else { $_.Substring(0, 1).ToUpperInvariant() + $_.Substring(1) }
    }) -join ''
  return $key
}

function Get-UnitFromHeader {
  param([Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Header)

  $m = [regex]::Match($Header, '\(([^)]*)\)')
  if ($m.Success) {
    $unit = $m.Groups[1].Value.Trim()
    # "(select)" / "(dropdown)" annotations mark a control type, not a unit.
    if ($unit -ne '' -and $unit -notmatch '(?i)^(select|dropdown|drop-down|list)$') {
      return $unit
    }
  }
  return $null
}

function Test-IsPeriodLabel {
  param([Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Label)

  $t = $Label.Trim()
  if ($t -eq '') { return $false }
  if ($t -match '(?i)^month\s*0?[1-9]$' -or $t -match '(?i)^month1[0-2]$') { return $true }
  if ($t -match '(?i)^(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*$') { return $true }
  if ($t -match '(?i)^(jan|feb|mar|apr|may|jun|jul|aug|sep|oct|nov|dec)[a-z]*\s*\d{2,4}$') { return $true }
  if ($t -match '(?i)^(summer|autumn|winter|spring)$') { return $true }
  return $false
}

function Add-ValidationWarning {
  param([Parameter(Mandatory = $true)] [string] $Message)
  Write-Warning $Message
  $script:ValidationWarningCount++
}

function Format-JsonIndentation {
  # PS 5.1 ConvertTo-Json pads values to align with each key's length, producing ragged
  # indentation. Re-emit the same JSON with exactly one $IndentUnit per nesting level.
  # Operates purely on structure: characters inside string literals are copied verbatim,
  # so every value stays byte-for-byte identical.
  param(
    [Parameter(Mandatory = $true)] [string] $Json,
    [string] $IndentUnit = "`t"
  )

  $sb = New-Object System.Text.StringBuilder
  $level = 0
  $inString = $false
  $escaped = $false
  $len = $Json.Length

  for ($i = 0; $i -lt $len; $i++) {
    $c = [string]$Json[$i]

    if ($inString) {
      [void]$sb.Append($c)
      if ($escaped) { $escaped = $false }
      elseif ($c -eq '\') { $escaped = $true }
      elseif ($c -eq '"') { $inString = $false }
      continue
    }

    switch ($c) {
      '"' {
        $inString = $true
        [void]$sb.Append($c)
      }
      { $_ -eq '{' -or $_ -eq '[' } {
        # Collapse an empty container ("{ }" / "[ ]") onto a single line.
        $j = $i + 1
        while ($j -lt $len -and [char]::IsWhiteSpace($Json[$j])) { $j++ }
        $close = if ($c -eq '{') { '}' } else { ']' }
        if ($j -lt $len -and ([string]$Json[$j]) -eq $close) {
          [void]$sb.Append($c + $close)
          $i = $j
        }
        else {
          $level++
          [void]$sb.Append($c)
          [void]$sb.Append("`r`n")
          [void]$sb.Append($IndentUnit * $level)
        }
      }
      { $_ -eq '}' -or $_ -eq ']' } {
        $level--
        [void]$sb.Append("`r`n")
        [void]$sb.Append($IndentUnit * $level)
        [void]$sb.Append($c)
      }
      ',' {
        [void]$sb.Append(',')
        [void]$sb.Append("`r`n")
        [void]$sb.Append($IndentUnit * $level)
      }
      ':' {
        [void]$sb.Append(': ')
      }
      default {
        # Drop the ragged inter-token whitespace; copy everything else (numbers, literals).
        if (-not [char]::IsWhiteSpace($Json[$i])) { [void]$sb.Append($c) }
      }
    }
  }

  return $sb.ToString()
}

function ConvertTo-CleanJson {
  # PS 5.1 ConvertTo-Json escapes < > & ' as \uXXXX; restore them for readable output.
  param([Parameter(Mandatory = $true)] $InputObject)

  $json = $InputObject | ConvertTo-Json -Depth 50
  $json = $json -replace '\\u003c', '<'
  $json = $json -replace '\\u003e', '>'
  $json = $json -replace '\\u0026', '&'
  $json = $json -replace '\\u0027', "'"
  $json = Format-JsonIndentation -Json $json
  return $json
}

function Write-JsonNoBom {
  param(
    [Parameter(Mandatory = $true)] [string] $Path,
    [Parameter(Mandatory = $true)] [string] $Json
  )
  # Write UTF-8 WITHOUT a BOM so downstream JSON.parse does not choke.
  $encoding = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($Path, $Json, $encoding)
}

function Test-FieldExists {
  # True when $Name matches an InputCell CellName or an InputTable TableName in $Base.
  param(
    [Parameter(Mandatory = $true)] $Base,
    [Parameter(Mandatory = $true)] [string] $Name
  )
  foreach ($c in @($Base['InputCells'])) {
    if ($c -is [System.Collections.IDictionary] -and [string]$c['CellName'] -eq $Name) { return $true }
  }
  foreach ($t in @($Base['InputTables'])) {
    if ($t -is [System.Collections.IDictionary] -and [string]$t['TableName'] -eq $Name) { return $true }
  }
  return $false
}

function ConvertTo-FieldGroupModel {
  # Recursively normalizes an override 'FieldGroups' array into the output model.
  # A group is { "Name": <string>, "Items": [ ... ] } where each Item is either a
  # field-name string (an InputCell CellName or InputTable TableName) or a nested
  # subgroup object with the same { Name, Items } shape. Field-name strings are
  # validated against $Base and a warning is emitted for anything unknown.
  param(
    [Parameter(Mandatory = $true)] [AllowNull()] $Groups,
    [Parameter(Mandatory = $true)] $Base
  )

  $result = New-Object System.Collections.Generic.List[object]
  foreach ($g in @($Groups)) {
    if ($null -eq $g) { continue }
    if (-not ($g -is [System.Management.Automation.PSCustomObject])) {
      Add-ValidationWarning "FieldGroups entry is not an object and was skipped."
      continue
    }

    $groupName = ''
    if ($g.PSObject.Properties['Name']) { $groupName = [string]$g.PSObject.Properties['Name'].Value }
    $groupObj = [ordered]@{ Name = $groupName }

    $items = New-Object System.Collections.Generic.List[object]
    $rawItems = @()
    if ($g.PSObject.Properties['Items']) { $rawItems = @($g.PSObject.Properties['Items'].Value) }
    foreach ($it in $rawItems) {
      if ($it -is [System.Management.Automation.PSCustomObject]) {
        # Nested subgroup.
        $sub = @(ConvertTo-FieldGroupModel -Groups @($it) -Base $Base)
        if ($sub.Count -gt 0) { [void]$items.Add($sub[0]) }
      }
      elseif ($it -is [string]) {
        if (-not (Test-FieldExists -Base $Base -Name $it)) {
          Add-ValidationWarning "FieldGroup '$groupName' references unknown field '$it'"
        }
        [void]$items.Add($it)
      }
      else {
        Add-ValidationWarning "FieldGroup '$groupName' has an unsupported item that was skipped."
      }
    }

    $groupObj['Items'] = $items.ToArray()
    [void]$result.Add($groupObj)
  }

  return , $result.ToArray()
}

function Merge-Override {
  # Deep, per-field merge of a hand-maintained override file over the generated
  # model. The override file is keyed by field identity so it survives regeneration
  # and only touches the fields it names:
  #
  #   {
  #     "_comment": "ignored - any top-level key starting with '_' is documentation",
  #     "InputCells":  { "<CellName>":  { <props to add/replace on that cell> } },
  #     "InputTables": { "<TableName>": { <props>, "Columns": { "<Col>": { <props> } } } },
  #     "FieldGroups": [ { "Name": "<title>", "Items": [ "<CellOrTableName>", { "Name": ..., "Items": [ ... ] } ] } ]
  #   }
  #
  # Each override object's properties are shallow-applied onto the matching field
  # (added if absent, replaced if present), so consumers can set Label, Group,
  # Default, Hidden, Order, etc. without redefining the generated structure.
  # FieldGroups is emitted as an ordered, optionally nested grouping of cell/table
  # names for the consuming app to render. Any other top-level key (not '_'-prefixed)
  # falls back to a whole-value replace.
  param(
    [Parameter(Mandatory = $true)] $Base,
    [Parameter(Mandatory = $true)] $Override
  )

  $applyProps = {
    param($Target, $Source)   # $Target = ordered dict field; $Source = PSCustomObject of overrides
    foreach ($p in $Source.PSObject.Properties) {
      $Target[$p.Name] = $p.Value
    }
  }

  foreach ($prop in $Override.PSObject.Properties) {
    $name = $prop.Name

    if ($name.StartsWith('_')) { continue }   # documentation-only keys

    if ($name -eq 'FieldGroups') {
      $Base['FieldGroups'] = @(ConvertTo-FieldGroupModel -Groups $prop.Value -Base $Base)
      continue
    }

    if ($name -eq 'InputCells' -and $prop.Value -is [System.Management.Automation.PSCustomObject]) {
      foreach ($cellOv in $prop.Value.PSObject.Properties) {
        $target = @($Base['InputCells']) | Where-Object { $_['CellName'] -eq $cellOv.Name } | Select-Object -First 1
        if ($null -eq $target) {
          Add-ValidationWarning "Override references unknown InputCell '$($cellOv.Name)'"
          continue
        }
        & $applyProps $target $cellOv.Value
      }
      continue
    }

    if ($name -eq 'InputTables' -and $prop.Value -is [System.Management.Automation.PSCustomObject]) {
      foreach ($tblOv in $prop.Value.PSObject.Properties) {
        $tbl = @($Base['InputTables']) | Where-Object { $_['TableName'] -eq $tblOv.Name } | Select-Object -First 1
        if ($null -eq $tbl) {
          Add-ValidationWarning "Override references unknown InputTable '$($tblOv.Name)'"
          continue
        }
        foreach ($tp in $tblOv.Value.PSObject.Properties) {
          if ($tp.Name -eq 'Columns' -and $tp.Value -is [System.Management.Automation.PSCustomObject]) {
            # Column field defs live under Rows.Row.<key> (RowsToCols) or Cols.Column.<key> (ColsToRows).
            $containers = @()
            foreach ($grp in @(@{ C = 'Rows'; G = 'Row' }, @{ C = 'Cols'; G = 'Column' })) {
              if ($tbl.Contains($grp.C) -and $tbl[$grp.C] -is [System.Collections.IDictionary] -and $tbl[$grp.C].Contains($grp.G)) {
                $containers += , $tbl[$grp.C][$grp.G]
              }
            }
            foreach ($colOv in $tp.Value.PSObject.Properties) {
              $colTarget = $null
              foreach ($cont in $containers) {
                if ($cont -is [System.Collections.IDictionary] -and $cont.Contains($colOv.Name)) { $colTarget = $cont[$colOv.Name]; break }
              }
              if ($null -eq $colTarget) {
                Add-ValidationWarning "Override references unknown column '$($colOv.Name)' in table '$($tblOv.Name)'"
                continue
              }
              & $applyProps $colTarget $colOv.Value
            }
          }
          else {
            $tbl[$tp.Name] = $tp.Value
          }
        }
      }
      continue
    }

    # Fallback: whole-value replace of a top-level key (backward compatible).
    $Base[$name] = $prop.Value
  }

  return $Base
}

# ---------------------------------------------------------------------------
# Helpers (COM value handling)
# ---------------------------------------------------------------------------

function ConvertTo-FlatValues {
  # Flattens an Excel Evaluate()/Value2 result (scalar, 1D, 2D array, or COM Range)
  # into a de-duplicated ordered list of non-empty string values. Errors are skipped.
  param([AllowNull()] $Result)

  $values = New-Object System.Collections.Generic.List[string]
  $seen = New-Object 'System.Collections.Generic.HashSet[string]'

  $addValue = {
    param($v)
    if ($null -eq $v) { return }
    # Excel cell errors surface through Value2 as CVErr integers in this band
    # (#NULL! .. #N/A); skip them so error codes never leak into option lists.
    if (($v -is [int] -or $v -is [long] -or $v -is [double]) -and $v -le -2146826245 -and $v -ge -2146826288) { return }
    $s = [string]$v
    if ([string]::IsNullOrWhiteSpace($s)) { return }
    if ($s -match '^#(REF|VALUE|NAME|N/A|DIV/0|NULL|NUM)') { return }
    if ($s -eq 'System.__ComObject') { return }
    if ($seen.Add($s)) { [void]$values.Add($s) }
  }

  if ($null -eq $Result) { return $values }

  # An evaluated range comes back as a COM object; read its underlying values.
  if ([System.Runtime.InteropServices.Marshal]::IsComObject($Result)) {
    $v2 = $null
    try { $v2 = $Result.Value2 } catch { $v2 = $null }
    $Result = $v2
  }

  if ($null -eq $Result) { return $values }

  if ($Result -is [System.Array]) {
    foreach ($item in $Result) { & $addValue $item }
  }
  else {
    & $addValue $Result
  }
  return $values
}

function Get-RangeValues {
  # Reads a COM Range's values as a flat string list.
  param([AllowNull()] $Range)
  if ($null -eq $Range) { return (New-Object System.Collections.Generic.List[string]) }
  $v2 = $null
  try { $v2 = $Range.Value2 } catch { $v2 = $null }
  return (ConvertTo-FlatValues -Result $v2)
}

function Invoke-WorksheetEvaluate {
  # Safe wrapper around Worksheet.Evaluate.
  param(
    [Parameter(Mandatory = $true)] $Worksheet,
    [Parameter(Mandatory = $true)] [string] $Expression
  )
  try {
    return $Worksheet.Evaluate($Expression)
  }
  catch {
    return $null
  }
}

function Get-ListObjectColumnValues {
  # Reads a structured table column ("TableName[Column Name]") directly from the
  # matching ListObject. This is far more reliable than Worksheet.Evaluate for tables
  # that live on a different sheet. Returns an empty list when the table/column is
  # not found.
  param(
    [Parameter(Mandatory = $true)] $Workbook,
    [Parameter(Mandatory = $true)] [string] $TableName,
    [Parameter(Mandatory = $true)] [string] $ColumnName
  )

  foreach ($ws in @($Workbook.Worksheets)) {
    if ($null -eq $ws) { continue }
    $lo = $null
    try { $lo = $ws.ListObjects.Item($TableName) } catch { $lo = $null }
    if ($null -eq $lo) { continue }

    # Special structured-reference items, e.g. Table[#Headers] lists the column names.
    if ($ColumnName -match '(?i)^#?Headers$') {
      $hdr = $null
      try { $hdr = $lo.HeaderRowRange } catch { $hdr = $null }
      return (Get-RangeValues -Range $hdr)
    }

    $col = $null
    try { $col = $lo.ListColumns.Item($ColumnName) } catch { $col = $null }
    if ($null -eq $col) { return (New-Object System.Collections.Generic.List[string]) }

    $body = $null
    try { $body = $col.DataBodyRange } catch { $body = $null }
    return (Get-RangeValues -Range $body)
  }
  return (New-Object System.Collections.Generic.List[string])
}

function Resolve-StructuredOrEvaluated {
  # Resolves an expression to a flat value list. Structured references ("Name[Col]")
  # are read from the ListObject; anything else is evaluated on the worksheet.
  param(
    [Parameter(Mandatory = $true)] $Worksheet,
    [Parameter(Mandatory = $true)] $Workbook,
    [Parameter(Mandatory = $true)] [string] $Expression
  )

  $sref = [regex]::Match($Expression, '^\s*([^\[\]]+?)\s*\[\s*([^\[\]]+?)\s*\]\s*$')
  if ($sref.Success) {
    $vals = @(Get-ListObjectColumnValues -Workbook $Workbook -TableName $sref.Groups[1].Value.Trim() -ColumnName $sref.Groups[2].Value.Trim())
    if ($vals.Count -gt 0) { return $vals }
  }
  return (ConvertTo-FlatValues -Result (Invoke-WorksheetEvaluate -Worksheet $Worksheet -Expression $Expression))
}

function Get-CellTypeByFormat {
  param([Parameter(Mandatory = $true)] $Cell)

  $fmt = ''
  try { $fmt = [string]$Cell.NumberFormat } catch { $fmt = '' }
  if ($fmt -match '%') { return 'percent' }
  if ($fmt -eq '@' -or $fmt -match '(?i)text') { return 'text' }

  # Fall back to the current value's type when the format is ambiguous (e.g. General):
  # a string value indicates a text field.
  try {
    $val = $Cell.Value2
    if ($val -is [string] -and -not [string]::IsNullOrWhiteSpace($val)) { return 'text' }
  }
  catch { }

  return 'number'
}

# ---------------------------------------------------------------------------
# Validation-list resolution
# ---------------------------------------------------------------------------

function Get-InnerCallArg {
  # Extracts the argument text inside FuncName( ... ) using a quote-aware balanced-paren
  # scan, so wrappers such as TRIMRANGE(INDIRECT(...)) yield just the INDIRECT argument.
  # Returns $null when the function call is not present.
  param(
    [Parameter(Mandatory = $true)] [string] $Expr,
    [Parameter(Mandatory = $true)] [string] $FuncName
  )

  $m = [regex]::Match($Expr, ('(?i)\b{0}\(' -f [regex]::Escape($FuncName)))
  if (-not $m.Success) { return $null }
  $start = $m.Index + $m.Length
  $depth = 1
  $inQuote = $false
  for ($i = $start; $i -lt $Expr.Length; $i++) {
    $ch = $Expr[$i]
    if ($ch -eq '"') { $inQuote = -not $inQuote; continue }
    if ($inQuote) { continue }
    if ($ch -eq '(') { $depth++ }
    elseif ($ch -eq ')') {
      $depth--
      if ($depth -eq 0) { return $Expr.Substring($start, $i - $start) }
    }
  }
  return $null
}

function Split-TopLevelAmpersand {
  # Splits a formula fragment on '&' concatenation operators that sit at the top level
  # (outside quotes and unnested parentheses). Quoted string literals are preserved intact.
  param([Parameter(Mandatory = $true)] [string] $Text)

  $parts = New-Object System.Collections.Generic.List[string]
  $depth = 0
  $inQuote = $false
  $sb = New-Object System.Text.StringBuilder
  for ($i = 0; $i -lt $Text.Length; $i++) {
    $ch = $Text[$i]
    if ($ch -eq '"') { $inQuote = -not $inQuote; [void]$sb.Append($ch); continue }
    if (-not $inQuote) {
      if ($ch -eq '(') { $depth++ }
      elseif ($ch -eq ')') { $depth-- }
      elseif ($ch -eq '&' -and $depth -eq 0) { [void]$parts.Add($sb.ToString()); [void]$sb.Clear(); continue }
    }
    [void]$sb.Append($ch)
  }
  [void]$parts.Add($sb.ToString())
  return $parts
}

function Resolve-ValidationList {
  <#
    Inspects a cell's data validation and returns a hashtable:
      @{ CellType = 'select'|'number'|'text'|...; Options = [ordered]; DependentOn = <name> }
    Returns $null when the cell has no usable list validation.
  #>
  param(
    [Parameter(Mandatory = $true)] $Cell,
    [Parameter(Mandatory = $true)] $Worksheet,
    [Parameter(Mandatory = $true)] $Workbook,
    [Parameter(Mandatory = $true)] [hashtable] $NameIndex,
    [Parameter(Mandatory = $true)] [string] $ContextName
  )

  $validation = $null
  try { $validation = $Cell.Validation } catch { return $null }
  if ($null -eq $validation) { return $null }

  $vtype = $null
  try { $vtype = [int]$validation.Type } catch { return $null }
  if ($vtype -ne $xlValidateList) { return $null }

  $formula1 = ''
  try { $formula1 = [string]$validation.Formula1 } catch { $formula1 = '' }
  if ([string]::IsNullOrWhiteSpace($formula1)) { return $null }

  $expr = $formula1
  if ($expr.StartsWith('=')) { $expr = $expr.Substring(1) }
  $expr = $expr.Trim()

  $result = [ordered]@{ CellType = 'select'; Options = [ordered]@{} }

  $isIndirect = $expr -match '(?i)INDIRECT\('
  $hasConcat = $expr.Contains('&')

  # --- Cascading INDIRECT($Parent) / INDIRECT(SUBSTITUTE($Parent," ","")) ---
  # The reference immediately inside INDIRECT() (optionally space-stripped via
  # SUBSTITUTE) drives the dependent list. The parent may be a named cell
  # (e.g. X_Cell_Site_State, no $) or a $-prefixed address. The terminator lookahead
  # (?=[),]) requires the captured token to be a bare reference, so string-wrapper
  # functions like UNIQUE(/TRIMRANGE( (followed by '(') never false-match.
  $cascadeMatch = [regex]::Match($expr, '(?i)^INDIRECT\(\s*(?:SUBSTITUTE\(\s*)?(\$?[A-Za-z_][\w.$]*)\s*(?=[),])')
  if ($cascadeMatch.Success) {
    $stripSpaces = $expr -match '(?i)SUBSTITUTE\('
    $parentRef = ($cascadeMatch.Groups[1].Value -replace '\$', '')
    $result['DependentOn'] = $parentRef

    $parentValues = @(Get-ParentAllowedValues -ParentRef $parentRef -Worksheet $Worksheet -Workbook $Workbook -NameIndex $NameIndex)
    foreach ($pv in $parentValues) {
      $stripped = if ($stripSpaces) { ($pv -replace '\s', '') } else { $pv }
      $childResult = Invoke-WorksheetEvaluate -Worksheet $Worksheet -Expression ("INDIRECT(""{0}"")" -f $stripped)
      $childValues = @(ConvertTo-FlatValues -Result $childResult)
      if ($childValues.Count -eq 0) {
        $result.Options[$stripped] = 'n/a'
      }
      else {
        $nested = [ordered]@{}
        foreach ($cv in $childValues) { $nested[$cv] = $cv }
        $result.Options[$stripped] = $nested
      }
    }
    return $result
  }

  # --- Static INDIRECT to a quoted constant (optionally wrapped in UNIQUE()/TRIMRANGE()) ---
  # e.g. =INDIRECT("Table[Col]") or =INDIRECT(UNIQUE("Table[Col]")). No concatenation.
  if ($isIndirect -and -not $hasConcat) {
    $constMatch = [regex]::Match($expr, '"([^"]+)"')
    if ($constMatch.Success) {
      $vals = @(Resolve-StructuredOrEvaluated -Worksheet $Worksheet -Workbook $Workbook -Expression $constMatch.Groups[1].Value)
      foreach ($v in $vals) { $result.Options[$v] = $v }
      if ($result.Options.Count -eq 0) {
        Add-ValidationWarning "Select cell '$ContextName' has unresolvable INDIRECT list: $formula1"
      }
      return $result
    }
  }

  # --- Concatenated cascade (e.g. INDIRECT("Table_" & SUBSTITUTE($Parent," ","") & "[Col]")) ---
  # When a SUBSTITUTE() normalises a parent reference, the parent's allowed values are
  # known, so each branch can be expanded statically: build <prefix><stripped value><suffix>
  # and resolve it. Produces nested Options keyed by the space-stripped parent value, with
  # "n/a" for branches that resolve to nothing. Falls back to a warning when there is no
  # SUBSTITUTE-normalised parent to enumerate (target chosen purely at runtime).
  if ($isIndirect -and $hasConcat) {
    $subMatch = [regex]::Match($expr, '(?i)SUBSTITUTE\(\s*([^,]+?)\s*,\s*"[^"]*"\s*,\s*"[^"]*"\s*\)')
    if ($subMatch.Success) {
      $parentRaw = $subMatch.Groups[1].Value.Trim()

      # Split the INDIRECT(...) argument into the static literals before/after the driver.
      $indArg = ''
      $im = [regex]::Match($expr, '(?is)^INDIRECT\((.*)\)\s*$')
      if ($im.Success) { $indArg = $im.Groups[1].Value }
      $subSpan = $subMatch.Value
      $idx = $indArg.IndexOf($subSpan)
      $prefixExpr = if ($idx -ge 0) { $indArg.Substring(0, $idx) } else { '' }
      $suffixExpr = if ($idx -ge 0) { $indArg.Substring($idx + $subSpan.Length) } else { '' }
      $prefix = -join ([regex]::Matches($prefixExpr, '"([^"]*)"') | ForEach-Object { $_.Groups[1].Value })
      $suffix = -join ([regex]::Matches($suffixExpr, '"([^"]*)"') | ForEach-Object { $_.Groups[1].Value })

      $pinfo = Resolve-ParentInfo -Ref $parentRaw -Worksheet $Worksheet -NameIndex $NameIndex
      $result['DependentOn'] = $pinfo.Name

      # Enumerate the parent's allowed values by resolving the parent cell's own validation
      # list (handles static, INDIRECT-structured and named-range parent lists alike).
      $parentValues = @()
      if ($null -ne $pinfo.Range) {
        $parentWorksheet = $Worksheet
        try { $parentWorksheet = $pinfo.Range.Worksheet } catch { $parentWorksheet = $Worksheet }
        $parentList = Resolve-ValidationList -Cell $pinfo.Range -Worksheet $parentWorksheet -Workbook $Workbook -NameIndex $NameIndex -ContextName $pinfo.Name
        if ($null -ne $parentList -and $parentList.Contains('Options')) {
          $parentValues = @($parentList.Options.Keys)
        }
      }
      foreach ($pv in $parentValues) {
        $stripped = ($pv -replace '\s', '')
        $built = "$prefix$stripped$suffix"
        $childValues = @(Resolve-StructuredOrEvaluated -Worksheet $Worksheet -Workbook $Workbook -Expression $built)
        # A branch that resolves to nothing - or only to a literal "n/a" placeholder cell -
        # collapses to the bare string "n/a".
        $realValues = @($childValues | Where-Object { $_ -notmatch '(?i)^\s*n/?a\s*$' })
        if ($realValues.Count -eq 0) {
          $result.Options[$stripped] = 'n/a'
        }
        else {
          $nested = [ordered]@{}
          foreach ($cv in $realValues) { $nested[$cv] = $cv }
          $result.Options[$stripped] = $nested
        }
      }
      if ($parentValues.Count -eq 0) {
        Add-ValidationWarning "Select cell '$ContextName' cascading list has no resolvable parent values: $formula1"
      }
      return $result
    }

    # --- Concatenated cascade driven by a bare reference (no SUBSTITUTE) ---
    # e.g. =TRIMRANGE(INDIRECT("Table_FuelTypesPerUse[" & D17 & "]")). The reference between
    # the literal fragments (typically a sibling table-column cell) selects the child column.
    # Enumerate the driver's allowed values and expand each branch by building
    # <prefix><parent value><suffix> and resolving it. Options are keyed by the raw parent
    # value (used verbatim, since there is no SUBSTITUTE normalisation), with "n/a" for
    # branches that resolve to nothing.
    $indArg = Get-InnerCallArg -Expr $expr -FuncName 'INDIRECT'
    if (-not [string]::IsNullOrWhiteSpace($indArg)) {
      $literalBefore = New-Object System.Collections.Generic.List[string]
      $literalAfter = New-Object System.Collections.Generic.List[string]
      $driverRef = $null
      $driverCount = 0
      foreach ($seg in @(Split-TopLevelAmpersand -Text $indArg)) {
        $lit = [regex]::Match($seg.Trim(), '(?s)^"(.*)"$')
        if ($lit.Success) {
          $litVal = $lit.Groups[1].Value -replace '""', '"'
          if ($null -eq $driverRef) { [void]$literalBefore.Add($litVal) } else { [void]$literalAfter.Add($litVal) }
        }
        else {
          $driverRef = $seg.Trim()
          $driverCount++
        }
      }

      if ($driverCount -eq 1 -and -not [string]::IsNullOrWhiteSpace($driverRef)) {
        $prefix = -join $literalBefore
        $suffix = -join $literalAfter
        $driverBare = ($driverRef -replace '\$', '')

        $pinfo = Resolve-ParentInfo -Ref $driverBare -Worksheet $Worksheet -NameIndex $NameIndex

        # Prefer the sibling table-column field key so DependentOn is portable across rows
        # (e.g. "FuelUse" rather than the raw cell address "D17").
        $depName = $pinfo.Name
        try {
          if ($null -ne $pinfo.Range -and $null -ne $Cell) {
            $app = $Worksheet.Application
            $driverCol = [int]$pinfo.Range.Column
            foreach ($lo in @($Worksheet.ListObjects)) {
              $inter = $null
              try { $inter = $app.Intersect($lo.Range, $Cell) } catch { $inter = $null }
              if ($null -eq $inter) { continue }
              foreach ($lc in @($lo.ListColumns)) {
                $lcRange = $null
                try { $lcRange = $lc.Range } catch { $lcRange = $null }
                if ($null -ne $lcRange -and [int]$lcRange.Column -eq $driverCol) {
                  $depName = Get-FieldKeyFromHeader -Header ([string]$lc.Name)
                  break
                }
              }
              break
            }
          }
        }
        catch { }
        $result['DependentOn'] = $depName

        $parentValues = @()
        if ($null -ne $pinfo.Range) {
          $parentWorksheet = $Worksheet
          try { $parentWorksheet = $pinfo.Range.Worksheet } catch { $parentWorksheet = $Worksheet }
          $parentList = Resolve-ValidationList -Cell $pinfo.Range -Worksheet $parentWorksheet -Workbook $Workbook -NameIndex $NameIndex -ContextName $depName
          if ($null -ne $parentList -and $parentList.Contains('Options')) {
            $parentValues = @($parentList.Options.Keys)
          }
        }

        foreach ($pv in $parentValues) {
          $built = "$prefix$pv$suffix"
          $childValues = @(Resolve-StructuredOrEvaluated -Worksheet $Worksheet -Workbook $Workbook -Expression $built)
          $realValues = @($childValues | Where-Object { $_ -notmatch '(?i)^\s*n/?a\s*$' })
          if ($realValues.Count -eq 0) {
            $result.Options[$pv] = 'n/a'
          }
          else {
            $nested = [ordered]@{}
            foreach ($cv in $realValues) { $nested[$cv] = $cv }
            $result.Options[$pv] = $nested
          }
        }

        if ($parentValues.Count -gt 0) { return $result }
        Add-ValidationWarning "Select cell '$ContextName' cascading list has no resolvable parent values: $formula1"
        return $result
      }
    }

    Add-ValidationWarning "Select cell '$ContextName' has runtime-dependent cascading list (not resolved): $formula1"
    return $result
  }

  # --- Static literal list: "A, B, C" or a single literal "A" ---
  if (-not $formula1.StartsWith('=') -and $expr -notmatch '[!:]') {
    foreach ($v in ($expr -split ',')) {
      $t = $v.Trim()
      if ($t -ne '') { $result.Options[$t] = $t }
    }
    return $result
  }

  # --- Range / named / structured reference ---
  $rangeValues = @(Resolve-StructuredOrEvaluated -Worksheet $Worksheet -Workbook $Workbook -Expression $expr)
  if ($rangeValues.Count -eq 0 -and $NameIndex.ContainsKey($expr)) {
    $rangeValues = @(Get-RangeValues -Range $NameIndex[$expr].Range)
  }
  foreach ($v in $rangeValues) { $result.Options[$v] = $v }

  if ($result.Options.Count -eq 0) {
    Add-ValidationWarning "Select cell '$ContextName' has unresolvable validation: $formula1"
  }
  return $result
}

function Get-ParentAllowedValues {
  # Returns the allowed values of a parent (cascaded-from) cell as a flat string list.
  param(
    [Parameter(Mandatory = $true)] [string] $ParentRef,
    [Parameter(Mandatory = $true)] $Worksheet,
    [Parameter(Mandatory = $true)] $Workbook,
    [Parameter(Mandatory = $true)] [hashtable] $NameIndex
  )

  $parentCell = $null
  if ($NameIndex.ContainsKey($ParentRef)) {
    try { $parentCell = $NameIndex[$ParentRef].Range } catch { $parentCell = $null }
  }
  if ($null -eq $parentCell) {
    $parentCell = Invoke-WorksheetEvaluate -Worksheet $Worksheet -Expression $ParentRef
  }
  return (Get-AllowedValuesFromCell -Cell $parentCell -Worksheet $Worksheet)
}

function Get-AllowedValuesFromCell {
  # Reads the data-validation allowed values from a specific cell (a COM Range) as a flat
  # string list. Handles static literal lists and reference/formula-based lists.
  param(
    [AllowNull()] $Cell,
    [Parameter(Mandatory = $true)] $Worksheet
  )

  if ($null -eq $Cell) { return (New-Object System.Collections.Generic.List[string]) }

  $validation = $null
  try { $validation = $Cell.Validation } catch { $validation = $null }
  if ($null -ne $validation) {
    $f1 = ''
    try { $f1 = [string]$validation.Formula1 } catch { $f1 = '' }
    if (-not [string]::IsNullOrWhiteSpace($f1)) {
      $pexpr = $f1
      if ($pexpr.StartsWith('=')) { $pexpr = $pexpr.Substring(1) }
      $pexpr = $pexpr.Trim()
      if (-not $f1.StartsWith('=') -and $pexpr -match ',' -and $pexpr -notmatch '[!:]') {
        $list = New-Object System.Collections.Generic.List[string]
        foreach ($v in ($pexpr -split ',')) { $t = $v.Trim(); if ($t -ne '') { [void]$list.Add($t) } }
        return $list
      }
      $evaluated = Invoke-WorksheetEvaluate -Worksheet $Worksheet -Expression $pexpr
      $vals = @(ConvertTo-FlatValues -Result $evaluated)
      if ($vals.Count -gt 0) { return $vals }
    }
  }
  return (New-Object System.Collections.Generic.List[string])
}

function Resolve-ParentInfo {
  # Resolves a cascade parent reference (a defined name or a cell address like $E$7) to its
  # ultimate source cell, following simple passthrough formulas (='Sheet'!$X$Y or =Name)
  # so mirror cells are tunnelled through. Returns @{ Name = <defined name or raw ref>;
  # Range = <source COM Range or $null> }.
  param(
    [Parameter(Mandatory = $true)] [string] $Ref,
    [Parameter(Mandatory = $true)] $Worksheet,
    [Parameter(Mandatory = $true)] [hashtable] $NameIndex
  )

  $range = $null
  if ($NameIndex.ContainsKey($Ref)) {
    try { $range = $NameIndex[$Ref].Range } catch { $range = $null }
  }
  if ($null -eq $range) {
    $range = Invoke-WorksheetEvaluate -Worksheet $Worksheet -Expression $Ref
  }

  $matchedName = $null
  $visited = New-Object 'System.Collections.Generic.HashSet[string]'

  for ($hops = 0; $hops -lt 8 -and $null -ne $range; $hops++) {
    $addr = $null; $sheetName = $null
    try { $addr = [string]$range.Address($true, $true) } catch { $addr = $null }
    try { $sheetName = [string]$range.Worksheet.Name } catch { $sheetName = $null }
    if ($null -ne $addr) {
      if (-not $visited.Add("$sheetName!$addr")) { break }
      foreach ($k in @($NameIndex.Keys)) {
        $rng = $NameIndex[$k].Range
        if ($null -eq $rng) { continue }
        try {
          if (([string]$rng.Address($true, $true)) -eq $addr -and
              ([string]$rng.Worksheet.Name) -eq $sheetName) { $matchedName = $k; break }
        }
        catch { }
      }
    }

    # Stop once we reach a cell that holds its own list validation (the true source).
    $isList = $false
    try { $isList = ([int]$range.Validation.Type) -eq $xlValidateList } catch { $isList = $false }
    if ($isList) { break }

    # Otherwise follow a single-cell passthrough formula: a cell address
    # (=Sheet!$X$Y or =$X$Y) or a bare defined name (=X_Cell_Site_State).
    $formula = ''
    try { if ([bool]$range.HasFormula) { $formula = [string]$range.Formula } } catch { $formula = '' }
    if ([string]::IsNullOrWhiteSpace($formula) -or -not $formula.StartsWith('=')) { break }
    $body = $formula.Substring(1).Trim()

    $isAddr = [regex]::IsMatch($body, "^(?:(?:'[^']+'|[A-Za-z0-9_. ]+)!)?\`$?[A-Za-z]{1,3}\`$?[0-9]+$")
    $isName = ($body -match '^[A-Za-z_][\w.]*$') -and $NameIndex.ContainsKey($body)
    if (-not ($isAddr -or $isName)) { break }

    $next = $null
    if ($isName) {
      try { $next = $NameIndex[$body].Range } catch { $next = $null }
    }
    if ($null -eq $next) {
      $next = Invoke-WorksheetEvaluate -Worksheet $range.Worksheet -Expression $body
    }
    if ($null -eq $next) { break }
    $range = $next
  }

  $name = if ($matchedName) { $matchedName } else { ($Ref -replace '\$', '') }
  return @{ Name = $name; Range = $range }
}

# ---------------------------------------------------------------------------
# Input cells
# ---------------------------------------------------------------------------

function Get-InputCells {
  param(
    [Parameter(Mandatory = $true)] $Workbook,
    [Parameter(Mandatory = $true)] [hashtable] $NameIndex
  )

  $cells = New-Object System.Collections.Generic.List[object]
  $seenNames = New-Object 'System.Collections.Generic.HashSet[string]'
  $ordinal = 0

  foreach ($entry in @($Workbook.Names)) {
    if ($null -eq $entry) { continue }

    $shortName = ''
    try { $shortName = Get-ShortDefinedName -NameLocal ([string]$entry.NameLocal) } catch { continue }
    if ($shortName -notmatch '^X_Cell_') { continue }

    if (-not $seenNames.Add($shortName)) {
      Add-ValidationWarning "Duplicate input cell name: $shortName"
      continue
    }

    $range = $null
    try { $range = $entry.RefersToRange } catch { $range = $null }
    if ($null -eq $range) { continue }

    $worksheet = $null
    try { $worksheet = $range.Worksheet } catch { $worksheet = $null }

    # Position within the workbook, so cells are emitted in the order they appear in
    # Excel (sheet tab order, then top-to-bottom, then left-to-right) rather than the
    # alphabetical order of the defined-names collection.
    $sheetIndex = [int]::MaxValue; $cellRow = [int]::MaxValue; $cellCol = [int]::MaxValue
    try { if ($null -ne $worksheet) { $sheetIndex = [int]$worksheet.Index } } catch { }
    try { $cellRow = [int]$range.Row } catch { }
    try { $cellCol = [int]$range.Column } catch { }

    $hasFormula = $false
    try { $hasFormula = [bool]$range.HasFormula } catch { $hasFormula = $false }

    $canOverwrite = $shortName -match '(?i)_Method2'

    $cellObj = [ordered]@{ CellName = $shortName }

    # Label comes from the worksheet cell immediately to the left of the named cell.
    $label = ''
    try {
      $col = [int]$range.Column
      if ($col -gt 1 -and $null -ne $worksheet) {
        $leftValue = $worksheet.Cells.Item([int]$range.Row, $col - 1).Value2
        if ($null -ne $leftValue) { $label = ([string]$leftValue).Trim() }
      }
    }
    catch { $label = '' }
    $cellObj['Label'] = $label

    # Resolve a validation list first (applies whether or not there is a formula).
    $listInfo = $null
    if ($null -ne $worksheet) {
      $listInfo = Resolve-ValidationList -Cell $range -Worksheet $worksheet -Workbook $Workbook -NameIndex $NameIndex -ContextName $shortName
    }

    if ($null -ne $listInfo) {
      $cellObj['CellType'] = 'select'
      if ($listInfo.Contains('DependentOn')) { $cellObj['DependentOn'] = $listInfo['DependentOn'] }
      $cellObj['Options'] = $listInfo.Options
    }
    elseif ($hasFormula -and -not $canOverwrite) {
      $cellObj['CellType'] = 'formula'
    }
    else {
      $cellObj['CellType'] = Get-CellTypeByFormat -Cell $range
    }

    if ($canOverwrite) { $cellObj['CanOverWriteFormula'] = $true }

    [void]$cells.Add([pscustomobject]@{
        SheetIndex = $sheetIndex
        Row        = $cellRow
        Col        = $cellCol
        Ordinal    = $ordinal
        Cell       = $cellObj
      })
    $ordinal++
  }

  return @($cells | Sort-Object SheetIndex, Row, Col, Ordinal | ForEach-Object { $_.Cell })
}

# ---------------------------------------------------------------------------
# Input tables
# ---------------------------------------------------------------------------

function Get-FieldDefFromCell {
  # Builds a field definition (CellType / Options / Unit / CanOverWriteFormula) from a
  # single representative body cell plus its header/label text. Shared by ListObject
  # columns and named-range matrix tables. $BodyCell may be $null.
  param(
    [Parameter(Mandatory = $true)] [AllowNull()] $BodyCell,
    [Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Header,
    [Parameter(Mandatory = $true)] $Worksheet,
    [Parameter(Mandatory = $true)] $Workbook,
    [Parameter(Mandatory = $true)] [hashtable] $NameIndex,
    [Parameter(Mandatory = $true)] [string] $ContextName,
    [bool] $ForceOverwrite = $false
  )

  $def = [ordered]@{}

  $hasFormula = $false
  if ($null -ne $BodyCell) {
    try { $hasFormula = [bool]$BodyCell.HasFormula } catch { $hasFormula = $false }
  }

  # _Method2 marks an overwritable formula: from the header text or the table name.
  $canOverwrite = $ForceOverwrite -or ($Header -match '(?i)_Method2')

  $listInfo = $null
  if ($null -ne $BodyCell) {
    $listInfo = Resolve-ValidationList -Cell $BodyCell -Worksheet $Worksheet -Workbook $Workbook -NameIndex $NameIndex -ContextName $ContextName
  }

  if ($null -ne $listInfo) {
    $def['CellType'] = 'select'
    if ($listInfo.Contains('DependentOn')) { $def['DependentOn'] = $listInfo['DependentOn'] }
    $def['Options'] = $listInfo.Options
  }
  elseif ($hasFormula -and -not $canOverwrite) {
    $def['CellType'] = 'formula'
  }
  elseif ($null -ne $BodyCell) {
    $def['CellType'] = Get-CellTypeByFormat -Cell $BodyCell
  }
  else {
    $def['CellType'] = 'number'
  }

  $unit = Get-UnitFromHeader -Header $Header
  if ($null -ne $unit) { $def['Unit'] = $unit }

  if ($canOverwrite) { $def['CanOverWriteFormula'] = $true }

  return $def
}

function Get-TableFieldDef {
  param(
    [Parameter(Mandatory = $true)] $Column,
    [Parameter(Mandatory = $true)] $Worksheet,
    [Parameter(Mandatory = $true)] $Workbook,
    [Parameter(Mandatory = $true)] [hashtable] $NameIndex,
    [Parameter(Mandatory = $true)] [string] $Header,
    [Parameter(Mandatory = $true)] [string] $ContextName
  )

  $bodyCell = $null
  try {
    $body = $Column.DataBodyRange
    if ($null -ne $body) { $bodyCell = $body.Cells.Item(1, 1) }
  }
  catch { $bodyCell = $null }

  return (Get-FieldDefFromCell -BodyCell $bodyCell -Header $Header -Worksheet $Worksheet -Workbook $Workbook -NameIndex $NameIndex -ContextName $ContextName)
}

function Get-InputTables {
  param(
    [Parameter(Mandatory = $true)] $Workbook,
    [Parameter(Mandatory = $true)] [hashtable] $NameIndex
  )

  $tables = New-Object System.Collections.Generic.List[object]
  $seenTables = New-Object 'System.Collections.Generic.HashSet[string]'

  foreach ($worksheet in @($Workbook.Worksheets)) {
    if ($null -eq $worksheet) { continue }

    $listObjects = $null
    try { $listObjects = $worksheet.ListObjects } catch { $listObjects = $null }
    if ($null -eq $listObjects) { continue }

    foreach ($lo in @($listObjects)) {
      if ($null -eq $lo) { continue }

      $tableName = ''
      try { $tableName = [string]$lo.Name } catch { continue }
      if ($tableName -notmatch '^(X_Table_|Table_Input)') { continue }

      if (-not $seenTables.Add($tableName)) {
        Add-ValidationWarning "Duplicate input table name: $tableName"
        continue
      }

      $columns = @()
      try { $columns = @($lo.ListColumns) } catch { $columns = @() }

      $headers = New-Object System.Collections.Generic.List[string]
      foreach ($col in $columns) {
        $h = ''
        try { $h = [string]$col.Name } catch { $h = '' }
        [void]$headers.Add($h)
      }

      $periodCount = 0
      foreach ($h in $headers) { if (Test-IsPeriodLabel -Label $h) { $periodCount++ } }
      $matrixType = if ($periodCount -ge 2) { 'ColsToRows' } else { 'RowsToCols' }

      $tableObj = [ordered]@{
        TableName  = $tableName
        MatrixType = $matrixType
      }

      $columnNames = [ordered]@{}
      $fieldDefs = [ordered]@{}
      foreach ($col in $columns) {
        $header = ''
        try { $header = [string]$col.Name } catch { $header = '' }
        if ([string]::IsNullOrWhiteSpace($header)) { continue }
        if (Test-IsPeriodLabel -Label $header) { continue }
        $fieldKey = Get-FieldKeyFromHeader -Header $header
        if ([string]::IsNullOrWhiteSpace($fieldKey)) { continue }
        if (-not $columnNames.Contains($fieldKey)) { $columnNames[$fieldKey] = $header }
        $fieldDefs[$fieldKey] = Get-TableFieldDef -Column $col -Worksheet $worksheet -Workbook $Workbook -NameIndex $NameIndex -Header $header -ContextName ("{0}.{1}" -f $tableName, $header)
      }

      $tableObj['NumberOfCols'] = $columnNames.Count
      $tableObj['ColumnNames'] = $columnNames

      if ($matrixType -eq 'ColsToRows') {
        $tableObj['Cols'] = [ordered]@{ 'Column' = $fieldDefs }
      }
      else {
        if ($fieldDefs.Count -eq 0) {
          Add-ValidationWarning "Input table '$tableName' produced no field definitions."
        }
        $tableObj['Rows'] = [ordered]@{ 'Row' = $fieldDefs }
      }

      $tSheet = [int]::MaxValue; $tRow = [int]::MaxValue; $tCol = [int]::MaxValue
      try { if ($null -ne $worksheet) { $tSheet = [int]$worksheet.Index } } catch { }
      try { $tRow = [int]$lo.Range.Row } catch { }
      try { $tCol = [int]$lo.Range.Column } catch { }
      [void]$tables.Add([pscustomobject]@{ SheetIndex = $tSheet; Row = $tRow; Col = $tCol; Table = $tableObj })
    }
  }

  # Also discover X_Table_* defined names (named ranges) that are not Excel ListObjects.
  foreach ($nrt in @(Get-NamedRangeTables -Workbook $Workbook -NameIndex $NameIndex -SeenTables $seenTables)) {
    [void]$tables.Add($nrt)
  }

  # Emit tables in the order they appear in Excel (sheet tab order, then top-to-bottom,
  # then left-to-right) rather than worksheet-then-alphabetical discovery order.
  $sorted = New-Object System.Collections.Generic.List[object]
  $ordinal = 0
  foreach ($w in $tables) { $w | Add-Member -NotePropertyName Ordinal -NotePropertyValue $ordinal -Force; $ordinal++ }
  foreach ($w in @($tables | Sort-Object SheetIndex, Row, Col, Ordinal)) { [void]$sorted.Add($w.Table) }
  return $sorted
}

function Get-NamedRangeTables {
  # Discovers input tables defined as named ranges (defined names matching ^X_Table_)
  # rather than Excel ListObjects. The referenced range's first row holds the header
  # cells. When the first column carries text labels for the data rows, the table is a
  # transposed matrix (ColsToRows: columns are entries, rows are fields); otherwise the
  # header row holds the field columns (RowsToCols).
  param(
    [Parameter(Mandatory = $true)] $Workbook,
    [Parameter(Mandatory = $true)] [hashtable] $NameIndex,
    [Parameter(Mandatory = $true)] $SeenTables
  )

  $tables = New-Object System.Collections.Generic.List[object]

  foreach ($entry in @($Workbook.Names)) {
    if ($null -eq $entry) { continue }

    $shortName = ''
    try { $shortName = Get-ShortDefinedName -NameLocal ([string]$entry.NameLocal) } catch { continue }
    if ($shortName -notmatch '^X_Table_') { continue }
    if ($SeenTables.Contains($shortName)) {
      Add-ValidationWarning "Duplicate input table name: $shortName"
      continue
    }

    $range = $null
    try { $range = $entry.RefersToRange } catch { $range = $null }
    if ($null -eq $range) { continue }

    $worksheet = $null
    try { $worksheet = $range.Worksheet } catch { $worksheet = $null }
    if ($null -eq $worksheet) { continue }

    $rowCount = 0; $colCount = 0
    try { $rowCount = [int]$range.Rows.Count; $colCount = [int]$range.Columns.Count } catch { continue }
    if ($rowCount -lt 2 -or $colCount -lt 1) {
      Add-ValidationWarning "Input table '$shortName' range is too small to describe ($rowCount x $colCount)."
      continue
    }

    [void]$SeenTables.Add($shortName)

    # Header row (row 1) values.
    $headerRow = @()
    for ($jx = 1; $jx -le $colCount; $jx++) {
      $hv = ''
      try { $hv = [string]$range.Cells.Item(1, $jx).Value2 } catch { $hv = '' }
      $headerRow += $hv
    }

    # A left "label column" is present when column-1 data rows (2..N) are mostly text.
    $labelColumn = $false
    if ($colCount -ge 2) {
      $textCount = 0; $checked = 0
      for ($i = 2; $i -le $rowCount; $i++) {
        $v = $null
        try { $v = $range.Cells.Item($i, 1).Value2 } catch { $v = $null }
        if ($null -eq $v) { continue }
        $checked++
        if ($v -is [string] -and -not [string]::IsNullOrWhiteSpace($v)) { $textCount++ }
      }
      if ($checked -gt 0 -and $textCount -ge [math]::Ceiling($checked / 2.0)) { $labelColumn = $true }
    }

    # An explicit matrix-type suffix on the defined name overrides the heuristic:
    #   *_RowsToCols -> header row holds the field columns (labelColumn = false)
    #   *_ColsToRows -> column 1 holds the row labels     (labelColumn = true)
    # The suffix is retained in the emitted TableName.
    if ($shortName -match '(?i)_RowsToCols$') { $labelColumn = $false }
    elseif ($shortName -match '(?i)_ColsToRows$') { $labelColumn = $true }

    # _Method2 on the table name marks the whole table as an overwritable formula default.
    $forceOverwrite = $shortName -match '(?i)_Method2'

    # Row 1 holds column headers and (when a label column is present) column 1 holds row
    # labels. Cells are populated by position, so a missing/blank header or label never
    # drops a field: a positional key (Row<n> / Col<n>) is used as a stable fallback and
    # the explicit Row/Col indices (1-based within the range) drive positional population.
    $usedKeys = New-Object 'System.Collections.Generic.HashSet[string]'
    $addField = {
      param($Defs, $BaseKey, $FallbackKey, $RowIdx, $ColIdx, $LabelText, $LabelProp, $Def)
      $key = if ([string]::IsNullOrWhiteSpace($BaseKey)) { $FallbackKey } else { $BaseKey }
      $candidate = $key; $n = 2
      while ($usedKeys.Contains($candidate)) { $candidate = "$key$n"; $n++ }
      [void]$usedKeys.Add($candidate)

      $posDef = [ordered]@{ Row = $RowIdx; Col = $ColIdx }
      if (-not [string]::IsNullOrWhiteSpace($LabelText)) { $posDef[$LabelProp] = $LabelText }
      foreach ($k in $Def.Keys) { $posDef[$k] = $Def[$k] }
      $Defs[$candidate] = $posDef
    }

    $fieldDefs = [ordered]@{}
    $tableObj = [ordered]@{
      TableName    = $shortName
      MatrixType   = if ($labelColumn) { 'ColsToRows' } else { 'RowsToCols' }
      NumberOfRows = $rowCount
    }

    if ($labelColumn) {
      # ColsToRows: entries = header columns 2..C; fields = rows 2..R (row labels in col 1).
      for ($i = 2; $i -le $rowCount; $i++) {
        $label = ''
        try { $label = [string]$range.Cells.Item($i, 1).Value2 } catch { $label = '' }
        $bodyCell = $null
        try { $bodyCell = $range.Cells.Item($i, 2) } catch { $bodyCell = $null }
        $ctx = if ([string]::IsNullOrWhiteSpace($label)) { "{0}.R{1}" -f $shortName, $i } else { "{0}.{1}" -f $shortName, $label }
        $cellDef = Get-FieldDefFromCell -BodyCell $bodyCell -Header $label -Worksheet $worksheet -Workbook $Workbook -NameIndex $NameIndex -ContextName $ctx -ForceOverwrite $forceOverwrite
        & $addField $fieldDefs (Get-FieldKeyFromHeader -Header $label) ("Row$i") $i 2 $label 'Label' $cellDef
      }

      # The class axis is the header row, columns 2..C. Column 1 holds the row-label
      # header ("Method 1 default values...") and is excluded from ColumnNames/NumberOfCols.
      $columnNames = [ordered]@{}
      for ($jx = 2; $jx -le $colCount; $jx++) {
        $hdr = [string]$headerRow[$jx - 1]
        $ckey = Get-FieldKeyFromHeader -Header $hdr
        if ([string]::IsNullOrWhiteSpace($ckey)) { $ckey = "Col$jx" }
        $candidate = $ckey; $n = 2
        while ($columnNames.Contains($candidate)) { $candidate = "$ckey$n"; $n++ }
        $columnNames[$candidate] = $hdr
      }
      $tableObj['NumberOfCols'] = $columnNames.Count
      $tableObj['ColumnNames'] = $columnNames
      $tableObj['Cols'] = [ordered]@{ 'Column' = $fieldDefs }
    }
    else {
      # RowsToCols: fields = header columns 1..C; data rows are entries.
      for ($jx = 1; $jx -le $colCount; $jx++) {
        $header = [string]$headerRow[$jx - 1]
        if (Test-IsPeriodLabel -Label $header) { continue }
        $bodyCell = $null
        try { $bodyCell = $range.Cells.Item(2, $jx) } catch { $bodyCell = $null }
        $ctx = if ([string]::IsNullOrWhiteSpace($header)) { "{0}.C{1}" -f $shortName, $jx } else { "{0}.{1}" -f $shortName, $header }
        $cellDef = Get-FieldDefFromCell -BodyCell $bodyCell -Header $header -Worksheet $worksheet -Workbook $Workbook -NameIndex $NameIndex -ContextName $ctx -ForceOverwrite $forceOverwrite
        & $addField $fieldDefs (Get-FieldKeyFromHeader -Header $header) ("Col$jx") 2 $jx $header 'Header' $cellDef
      }

      # The field/column axis is the set of fields just built; key it by machine key
      # mapping to the raw header so it matches the keys under Rows.Row.*.
      $columnNames = [ordered]@{}
      foreach ($k in $fieldDefs.Keys) {
        $lbl = ''
        if ($fieldDefs[$k].Contains('Header')) { $lbl = [string]$fieldDefs[$k]['Header'] }
        $columnNames[$k] = $lbl
      }
      $tableObj['NumberOfCols'] = $colCount
      $tableObj['ColumnNames'] = $columnNames
      $tableObj['Rows'] = [ordered]@{ 'Row' = $fieldDefs }
    }

    if ($fieldDefs.Count -eq 0) {
      Add-ValidationWarning "Input table '$shortName' produced no field definitions."
    }

    $tSheet = [int]::MaxValue; $tRow = [int]::MaxValue; $tCol = [int]::MaxValue
    try { if ($null -ne $worksheet) { $tSheet = [int]$worksheet.Index } } catch { }
    try { $tRow = [int]$range.Row } catch { }
    try { $tCol = [int]$range.Column } catch { }
    [void]$tables.Add([pscustomobject]@{ SheetIndex = $tSheet; Row = $tRow; Col = $tCol; Table = $tableObj })
  }

  return $tables
}

# ---------------------------------------------------------------------------
# Per-workbook processing
# ---------------------------------------------------------------------------

function Build-NameIndex {
  param([Parameter(Mandatory = $true)] $Workbook)

  $index = @{}
  foreach ($entry in @($Workbook.Names)) {
    if ($null -eq $entry) { continue }
    try {
      $shortName = Get-ShortDefinedName -NameLocal ([string]$entry.NameLocal)
      if (-not $index.ContainsKey($shortName)) {
        $range = $null
        try { $range = $entry.RefersToRange } catch { $range = $null }
        $index[$shortName] = [pscustomobject]@{ Entry = $entry; Range = $range }
      }
    }
    catch { continue }
  }
  return $index
}

function Set-DateFieldTypes {
  # Any input field whose key contains 'date' (case-insensitive) is a date input.
  # Excel stores dates as numbers, so the format-based detection reports them as
  # 'number' (or 'text'); coerce those scalar types to 'date'. Dropdowns ('select')
  # and computed ('formula') fields are left untouched.
  param([Parameter(Mandatory = $true)] $Model)

  $coerce = {
    param($Key, $Def)
    if ($Key -notmatch '(?i)date') { return }
    if ($null -eq $Def -or -not ($Def -is [System.Collections.IDictionary])) { return }
    if (-not $Def.Contains('CellType')) { return }
    if ($Def['CellType'] -eq 'number' -or $Def['CellType'] -eq 'text') { $Def['CellType'] = 'date' }
  }

  foreach ($cell in @($Model.InputCells)) {
    if ($cell -is [System.Collections.IDictionary] -and $cell.Contains('CellName')) {
      & $coerce $cell['CellName'] $cell
    }
  }

  foreach ($table in @($Model.InputTables)) {
    if (-not ($table -is [System.Collections.IDictionary])) { continue }
    foreach ($container in @('Rows', 'Cols')) {
      if (-not $table.Contains($container)) { continue }
      $inner = $table[$container]
      if (-not ($inner -is [System.Collections.IDictionary])) { continue }
      foreach ($groupKey in @($inner.Keys)) {          # 'Row' or 'Column'
        $fields = $inner[$groupKey]
        if (-not ($fields -is [System.Collections.IDictionary])) { continue }
        foreach ($fieldKey in @($fields.Keys)) {
          & $coerce $fieldKey $fields[$fieldKey]
        }
      }
    }
  }
}

function ConvertTo-InputFieldsModel {
  param(
    [Parameter(Mandatory = $true)] $Workbook,
    [Parameter(Mandatory = $true)] [string] $SourceFileName
  )

  $nameIndex = Build-NameIndex -Workbook $Workbook

  # Wrap in @() so the result is ALWAYS a real array: a function returning an empty
  # List unrolls to $null (which ConvertTo-Json renders as {}), and a single-element
  # result unrolls to a scalar (rendered as a bare object). @() re-collects the
  # unrolled pipeline into an [object[]] for 0, 1 or N items alike.
  $inputCells = @(Get-InputCells -Workbook $Workbook -NameIndex $nameIndex)
  $inputTables = @(Get-InputTables -Workbook $Workbook -NameIndex $nameIndex)

  $model = [ordered]@{
    schemaVersion = $schemaVersion
    generatedFrom = $SourceFileName
    generatedAt   = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")
    InputCells    = $inputCells
    InputTables   = $inputTables
  }
  Set-DateFieldTypes -Model $model
  return $model
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$excelDir = Join-Path $RepoRoot 'Excel'
$enterprisesDir = Join-Path $excelDir 'Enterprises'
$outputDir = Join-Path $RepoRoot 'InputFields'
$overridesDir = Join-Path $outputDir '_overrides'

$workbooks = @()
if (-not [string]::IsNullOrWhiteSpace($WorkbookPath)) {
  $workbooks = @((Resolve-Path -LiteralPath $WorkbookPath).Path)
}
else {
  if (-not (Test-Path -LiteralPath $excelDir)) {
    throw "Excel directory not found: $excelDir"
  }
  $isEligibleWorkbook = {
    param($File)
    $File.Name -notlike '~$*' -and
    $File.BaseName -notmatch '(?i)_expanded(?:_tmp\d*)?$' -and
    $File.BaseName -notmatch '(?i)_template(?:_|$)' -and
    $File.BaseName -notmatch '(?i)\.bak$'
  }
  $candidates = @(Get-ChildItem -LiteralPath $excelDir -File -Filter '*.xlsx')
  if (Test-Path -LiteralPath $enterprisesDir) {
    $candidates += @(Get-ChildItem -LiteralPath $enterprisesDir -File -Filter '*.xlsx')
  }
  $workbooks = @($candidates |
    Where-Object { & $isEligibleWorkbook $_ } |
    Sort-Object FullName |
    ForEach-Object { $_.FullName })
}

if ($workbooks.Count -eq 0) {
  Write-Host 'No eligible workbooks found. Nothing to do.'
  return
}

if (-not $DryRun -and -not (Test-Path -LiteralPath $outputDir)) {
  New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
}

$mode = if ($DryRun) { '[DryRun] ' } else { '' }
Write-Host ("{0}Building input-fields JSON for {1} workbook(s)..." -f $mode, $workbooks.Count)

function New-ExcelApplication {
  $app = New-Object -ComObject Excel.Application
  $app.Visible = $false
  $app.DisplayAlerts = $false
  $app.ScreenUpdating = $false
  $app.EnableEvents = $false
  $app.AskToUpdateLinks = $false
  return $app
}

function Remove-ExcelApplication {
  param($App)
  if ($null -eq $App) { return }
  try { $App.Quit() } catch { }
  try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($App) } catch { }
  [System.GC]::Collect()
  [System.GC]::WaitForPendingFinalizers()
}

$excel = $null
try {
  $excel = New-ExcelApplication

  foreach ($wbPath in $workbooks) {
    $wbName = Split-Path $wbPath -Leaf
    $module = Get-ModuleName -WorkbookFile $wbPath
    $outName = "$module`_InputFields.json"

    # Open with recovery: the Excel COM server can crash/disconnect after processing
    # several workbooks, after which $excel is null and every open fails. Recreate the
    # application and retry once before giving up on this workbook.
    $workbook = $null
    for ($attempt = 1; $attempt -le 2 -and $null -eq $workbook; $attempt++) {
      try {
        if ($null -eq $excel) { $excel = New-ExcelApplication }
        $workbook = $excel.Workbooks.Open($wbPath, 0, $true) # UpdateLinks=0, ReadOnly
      }
      catch {
        if ($attempt -ge 2) {
          Add-ValidationWarning "Could not open '$wbName': $($_.Exception.Message)"
        }
        else {
          Remove-ExcelApplication -App $excel
          $excel = $null
        }
      }
    }
    if ($null -eq $workbook) { continue }

    try {
      $model = ConvertTo-InputFieldsModel -Workbook $workbook -SourceFileName $wbName

      # Per-field-merge override file if present.
      $overridePath = Join-Path $overridesDir "$module.json"
      if (Test-Path -LiteralPath $overridePath) {
        try {
          $override = Get-Content -LiteralPath $overridePath -Raw | ConvertFrom-Json
          $model = Merge-Override -Base $model -Override $override
          Write-Host ("    merged override: _overrides/{0}.json" -f $module)
        }
        catch {
          Add-ValidationWarning "Failed to merge override for '$module': $($_.Exception.Message)"
        }
      }

      $json = ConvertTo-CleanJson -InputObject $model
      $cellCount = @($model.InputCells).Count
      $tableCount = @($model.InputTables).Count

      if ($DryRun) {
        Write-Host ("  {0} -> {1} ({2} cell(s), {3} table(s)) [not written]" -f $wbName, $outName, $cellCount, $tableCount)
      }
      else {
        $outPath = Join-Path $outputDir $outName
        Write-JsonNoBom -Path $outPath -Json $json
        Write-Host ("  {0} -> {1} ({2} cell(s), {3} table(s))" -f $wbName, $outName, $cellCount, $tableCount)
      }
    }
    catch {
      Add-ValidationWarning "Failed processing '$wbName': $($_.Exception.Message)"
    }
    finally {
      if ($null -ne $workbook) {
        try { $workbook.Close($false) } catch { }
        try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($workbook) } catch { }
        $workbook = $null
      }
      # Recycle the Excel COM server between workbooks. Processing many large books in
      # a single instance degrades it: a later, very large workbook (e.g. the aggregated
      # Enterprise book with ~14k defined names) can then open with an incompletely
      # loaded Names collection and silently produce 0 cells/tables. A fresh instance
      # per workbook avoids this. The open-retry block above recreates $excel as needed.
      Remove-ExcelApplication -App $excel
      $excel = $null
    }
  }
}
finally {
  Remove-ExcelApplication -App $excel
  $excel = $null
}

if ($script:ValidationWarningCount -gt 0) {
  Write-Host ("{0}Done with {1} validation warning(s) (see above)." -f $mode, $script:ValidationWarningCount)
}
else {
  Write-Host ("{0}Done." -f $mode)
}
