<#
.SYNOPSIS
  Scan VEERG Excel workbooks for remaining errors and report them in one place.

.DESCRIPTION
  A single, read-only checker that consolidates the error categories the build
  pipeline can leave behind. It reads the .xlsx package XML directly (no Excel,
  no COM, no add-in required) so it is fast and never produces the false #NAME?
  results a headless recalc would (VEERG.* LAMBDAs only resolve with the Excel
  Labs add-in loaded). It reports whatever was last computed and saved:

    [cell]      Cells whose cached value is an Excel error (t="e"), e.g.
                #REF!, #NAME?, #VALUE!, #DIV/0!, #N/A, #NULL!, #NUM!, #SPILL!,
                #CALC!. The sheet, cell address, error token and formula (if
                stored) are listed.

    [name]      Defined names whose RefersTo contains an Excel error token
                (dangling / broken function) or is empty. Workbook- and
                sheet-scoped names are both checked. The .xlf-maintained library
                LAMBDAs that carry an internal #REF! (category broken-fn) are
                NOISE here and are hidden by default; pass -IncludeLibraryFunctions
                to list them too.

    [link]      Leftover external links to other workbook files. A
                self-contained VEERG workbook should have none.

    [sum]       SUM(...) calls whose literal range argument (e.g. SUM(D10:D25))
                is a different size than the contiguous block of data actually
                sitting in those rows/columns. Catches the classic "rows were
                added/removed but the SUM range wasn't updated" mistake.
                Structured table references (Table[Column]) and plain named
                ranges are skipped on purpose - those resize automatically.
                Text cells reading "N/A", "Not used", "Summed above" or "Enter
                value" count as valid data, not a label, since they're a
                deliberate stand-in for a number. To document a SUM that is
                intentionally partial, add a no-op comment to the formula, e.g.
                =SUM(G128:G131)+N("Partial: subtotal 1 of 3, see also I138")
                - N() turns the text into 0 so the result is unaffected, and
                the checker skips any formula containing N("Partial...").
                Advisory only (heuristic, not included in -FailOnError).

  DRY / read-only ALWAYS: nothing is ever written. Use it after a build (e.g.
  `npm run build-enterprise`) to confirm the workbooks are clean.

.PARAMETER RepoRoot
  Repository root. Defaults to the parent of the scripts folder.

.PARAMETER WorkbookPath
  Full path to a single .xlsx to scan. If omitted, every Excel/*.xlsx and
  Excel/Enterprises/*.xlsx (excluding lock files, *_expanded*, *_template* and
  *.bak backups) is scanned.

.PARAMETER Max
  Maximum rows to list per category per workbook before summarising the rest.
  Default 50. Pass 0 for unlimited.

.PARAMETER FailOnError
  Exit with code 1 if any [cell] or [name] error is found (useful for CI /
  pre-commit gating). External links are always reported but never fail on their
  own. Off by default (always exits 0).

.PARAMETER IncludeLibraryFunctions
  Also report broken-fn names: the .xlf-maintained Excel Labs library LAMBDAs
  (Module.Func) whose body contains an internal #REF!. Hidden by default because
  they are known, tracked in the .xlf source, and never auto-deleted.

.PARAMETER SkipSumCheck
  Skip the [sum] SUM-range-size heuristic (see DESCRIPTION). Use this to speed
  up a scan when you only care about hard errors.

.EXAMPLE
  npm run find-errors
  npm run find-errors -- -WorkbookPath .\Excel\Enterprises\Enterprise_Dairy_WIP_v01.xlsx
  npm run find-errors -- -Max 0 -FailOnError
  npm run find-errors -- -IncludeLibraryFunctions
#>
param(
  [string] $RepoRoot = (Split-Path $PSScriptRoot -Parent),
  [string] $WorkbookPath,
  [int]    $Max = 50,
  [switch] $IncludeLibraryFunctions,
  [switch] $SkipSumCheck,
  [switch] $FailOnError
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

# Namespaces used across the OOXML parts.
$script:NsMain = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
$script:NsRel  = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
$script:NsPkg  = 'http://schemas.openxmlformats.org/package/2006/relationships'

# Excel error tokens that can appear in a defined name's RefersTo.
$script:ErrorRegex = [regex]::new('#(REF!|NAME\?|DIV/0!|VALUE!|N/A|NULL!|NUM!|SPILL!|CALC!|FIELD!|GETTING_DATA|BLOCKED!|CONNECT!|BUSY!|UNKNOWN!)', 'IgnoreCase')

# --- [sum] SUM-range-size check regexes -------------------------------------
# A call to SUM( - lookbehind blocks SUMIF/SUMIFS/SUMPRODUCT/SUMSQ/CUSTOM_SUM etc,
# since those have something other than '(' right after "SUM".
$script:SumCallRegex = [regex]::new('(?<![A-Za-z0-9_.])SUM\(', 'IgnoreCase')
# A single plain A1-style range argument, optionally sheet-qualified. Deliberately
# does NOT match structured refs (Table[Col]) or bare defined names - both are
# skipped on purpose (tables/names resize themselves).
$script:RangeArgRegex = [regex]::new("^(?:(?<sheet>'[^']+'|[A-Za-z_][A-Za-z0-9_]*)!)?\`$?(?<c1>[A-Za-z]{1,3})\`$?(?<r1>[0-9]+):\`$?(?<c2>[A-Za-z]{1,3})\`$?(?<r2>[0-9]+)$")
$script:CellRefRegex = [regex]::new('^([A-Za-z]+)([0-9]+)$')
# Cells holding one of these are treated as a summary/total row, not list data,
# so they never get swept into a "the data actually extends further" verdict.
$script:AggregateFnRegex = [regex]::new('(?<![A-Za-z0-9_])(SUM|SUBTOTAL|AGGREGATE)\s*\(', 'IgnoreCase')
# Text cells holding one of these placeholder phrases are a deliberate stand-in
# for a number (SUM ignores text anyway) - treat the cell as valid data, not a
# label/title, so it doesn't look like the row/column is missing from the SUM.
$script:ValidPlaceholderTextRegex = [regex]::new('^\s*(n/a|not used|summed above|enter value|-|No data)\s*$', 'IgnoreCase')
# Deliberate-partial-sum marker: a formula carrying `+N("Partial...")` (or
# "Partial:"/"Partial -"/etc) documents in the formula bar, in plain human
# language, that the SUM range is intentionally smaller/larger than the
# surrounding data block. N() coerces text to 0, so it never changes the
# result. Any SUM range mismatch in a formula that carries this marker is
# skipped rather than reported.
$script:PartialSumMarkerRegex = [regex]::new('N\(\s*"\s*partial\b', 'IgnoreCase')

# ---------------------------------------------------------------------------
# Workbook discovery.
# ---------------------------------------------------------------------------
function Get-TargetWorkbooks {
  param([string] $RepoRoot, [string] $WorkbookPath)
  if (-not [string]::IsNullOrWhiteSpace($WorkbookPath)) {
    if (-not (Test-Path -LiteralPath $WorkbookPath)) { throw "Workbook not found: $WorkbookPath" }
    return @((Resolve-Path -LiteralPath $WorkbookPath).Path)
  }
  $excelDir = Join-Path $RepoRoot 'Excel'
  if (-not (Test-Path -LiteralPath $excelDir)) { throw "Excel folder not found: $excelDir" }
  $dirs = @($excelDir, (Join-Path $excelDir 'Enterprises')) | Where-Object { Test-Path -LiteralPath $_ }
  $files = foreach ($d in $dirs) {
    Get-ChildItem -LiteralPath $d -Filter '*.xlsx' -File |
      Where-Object {
        $_.Name -notlike '~$*' -and
        $_.BaseName -notmatch '(?i)_expanded' -and
        $_.BaseName -notmatch '(?i)_template' -and
        $_.Name -notmatch '(?i)\.bak'
      }
  }
  $files | Sort-Object FullName | ForEach-Object { $_.FullName }
}

# ---------------------------------------------------------------------------
# Zip / XML helpers.
# ---------------------------------------------------------------------------
function Read-ZipEntryText {
  param($Zip, [string] $EntryName)
  $entry = $Zip.GetEntry($EntryName)
  if ($null -eq $entry) { return $null }
  $reader = [System.IO.StreamReader]::new($entry.Open(), [System.Text.Encoding]::UTF8)
  try { return $reader.ReadToEnd() } finally { $reader.Dispose() }
}

function New-XmlDoc {
  param([string] $Text)
  $doc = New-Object System.Xml.XmlDocument
  $doc.PreserveWhitespace = $true
  $doc.LoadXml($Text)
  return ,$doc   # comma prevents PowerShell from enumerating the doc's child nodes
}

function New-NsManager {
  param($Doc, [hashtable] $Namespaces)
  $ns = New-Object System.Xml.XmlNamespaceManager($Doc.NameTable)
  foreach ($k in $Namespaces.Keys) { $ns.AddNamespace($k, $Namespaces[$k]) }
  return ,$ns   # comma prevents PowerShell from enumerating the manager's prefixes
}

# ---------------------------------------------------------------------------
# Map each worksheet to its part name, in workbook order.
#   Returns an ordered array of @{ Name; Part } plus a 0-based index lookup used
#   to resolve a defined name's localSheetId to a sheet name.
# ---------------------------------------------------------------------------
function Get-SheetMap {
  param($Zip)
  $result = @()
  $wbText = Read-ZipEntryText -Zip $Zip -EntryName 'xl/workbook.xml'
  if ($null -eq $wbText) { return $result }
  $relText = Read-ZipEntryText -Zip $Zip -EntryName 'xl/_rels/workbook.xml.rels'

  # rId -> target part
  $relMap = @{}
  if ($null -ne $relText) {
    $relDoc = New-XmlDoc -Text $relText
    $relNs = New-NsManager -Doc $relDoc -Namespaces @{ p = $script:NsPkg }
    foreach ($r in @($relDoc.SelectNodes('//p:Relationship', $relNs))) {
      $relMap[$r.GetAttribute('Id')] = $r.GetAttribute('Target')
    }
  }

  $wbDoc = New-XmlDoc -Text $wbText
  $wbNs = New-NsManager -Doc $wbDoc -Namespaces @{ x = $script:NsMain; r = $script:NsRel }
  foreach ($s in @($wbDoc.SelectNodes('//x:sheets/x:sheet', $wbNs))) {
    $name = $s.GetAttribute('name')
    $rid  = $s.GetAttribute('id', $script:NsRel)
    $part = $null
    if ($relMap.ContainsKey($rid)) {
      $tgt = $relMap[$rid]
      if ($tgt -match '^/') { $part = $tgt.TrimStart('/') } else { $part = 'xl/' + $tgt }
    }
    $result += [pscustomobject]@{ Name = $name; Part = $part }
  }
  return $result
}

# ---------------------------------------------------------------------------
# Cell errors. Two kinds are reported:
#   * cached error   - the cell's stored value is an Excel error (t="e"), i.e. it
#                      currently EVALUATES to an error.
#   * formula error  - the cell's stored <f> formula TEXT contains an error token
#                      (e.g. a #REF! left in the arguments) even though the cell
#                      currently evaluates to a valid value because a function
#                      swallowed the bad reference. A #REF! baked into a formula
#                      is always a real problem, so it is flagged regardless of
#                      the cached result.
# ---------------------------------------------------------------------------
function Get-CellErrors {
  param($Zip, [array] $SheetMap)
  $errors = @()
  foreach ($sheet in $SheetMap) {
    if ([string]::IsNullOrEmpty($sheet.Part)) { continue }
    $text = Read-ZipEntryText -Zip $Zip -EntryName $sheet.Part
    if ($null -eq $text) { continue }
    # Fast skip: nothing to find unless the sheet has a cached error cell or an
    # error token somewhere in its text (e.g. #REF! inside a formula).
    if ($text.IndexOf('t="e"') -lt 0 -and -not $script:ErrorRegex.IsMatch($text)) { continue }
    $doc = New-XmlDoc -Text $text
    $ns = New-NsManager -Doc $doc -Namespaces @{ x = $script:NsMain }
    foreach ($c in @($doc.SelectNodes("//x:c[@t='e' or x:f]", $ns))) {
      $ref = $c.GetAttribute('r')
      $isCachedError = ($c.GetAttribute('t') -eq 'e')
      # Cells with a value-metadata pointer (vm) are RICH VALUES - an in-cell
      # ("Place in Cell") image, a linked data type, etc. Their t="e"/#VALUE! is
      # just the fallback text for clients that can't render the rich value, not
      # a real error, so skip them.
      if ($isCachedError -and -not [string]::IsNullOrEmpty($c.GetAttribute('vm'))) { continue }
      $vNode = $c.SelectSingleNode('x:v', $ns)
      $fNode = $c.SelectSingleNode('x:f', $ns)
      $formulaText = if ($null -ne $fNode) { $fNode.InnerText } else { '' }
      $formulaMatch = $script:ErrorRegex.Match($formulaText)

      if ($isCachedError) {
        # Currently evaluates to an error.
        $val = if ($null -ne $vNode) { $vNode.InnerText } else { '#(error)' }
      } elseif ($formulaMatch.Success) {
        # Latent error: the formula carries an error token but the cell currently
        # evaluates fine (a function masked the bad reference).
        $val = $formulaMatch.Value + ' (in formula)'
      } else {
        continue   # ordinary formula cell, no error
      }
      $formula = if ($null -ne $fNode) { '=' + $formulaText } else { '' }
      $errors += [pscustomobject]@{
        Sheet = $sheet.Name; Cell = $ref; Error = $val; Formula = $formula
      }
    }
  }
  return $errors
}

# ---------------------------------------------------------------------------
# Broken defined names: RefersTo contains an error token or is empty.
# ---------------------------------------------------------------------------
function Get-NameErrors {
  param($Zip, [array] $SheetMap, [switch] $IncludeLibraryFunctions)
  $issues = @()
  $wbText = Read-ZipEntryText -Zip $Zip -EntryName 'xl/workbook.xml'
  if ($null -eq $wbText) { return $issues }
  $doc = New-XmlDoc -Text $wbText
  $ns = New-NsManager -Doc $doc -Namespaces @{ x = $script:NsMain }
  foreach ($n in @($doc.SelectNodes('//x:definedNames/x:definedName', $ns))) {
    $nm = $n.GetAttribute('name')
    if ([string]::IsNullOrEmpty($nm)) { continue }
    $rt = $n.InnerText
    $localId = $n.GetAttribute('localSheetId')
    $scope = 'workbook'
    if (-not [string]::IsNullOrEmpty($localId)) {
      $idx = 0; [void][int]::TryParse($localId, [ref]$idx)
      $scope = if ($idx -ge 0 -and $idx -lt $SheetMap.Count) { "'" + $SheetMap[$idx].Name + "'" } else { "sheet#$localId" }
    }
    $category = $null
    if ([string]::IsNullOrWhiteSpace($rt)) { $category = 'empty' }
    elseif ($script:ErrorRegex.IsMatch($rt)) {
      # A plain (non-formula) ref that errors is dangling cruft; a formula that
      # contains an error token is a broken function.
      $category = if ($rt.IndexOf('(') -ge 0) { 'broken-fn' } else { 'dangling' }
    }
    if ($null -eq $category) { continue }
    # broken-fn = .xlf library LAMBDAs with an internal #REF!: known noise, hidden
    # unless explicitly requested.
    if ($category -eq 'broken-fn' -and -not $IncludeLibraryFunctions) { continue }
    $issues += [pscustomobject]@{
      Name = $nm; Scope = $scope; Category = $category; RefersTo = $rt
    }
  }
  return $issues
}

# ---------------------------------------------------------------------------
# Leftover external links to other workbook files.
# ---------------------------------------------------------------------------
function Get-ExternalLinks {
  param($Zip)
  $links = @()
  foreach ($entry in $Zip.Entries) {
    if ($entry.FullName -notmatch '(?i)^xl/externalLinks/_rels/externalLink\d+\.xml\.rels$') { continue }
    $text = Read-ZipEntryText -Zip $Zip -EntryName $entry.FullName
    if ($null -eq $text) { continue }
    $doc = New-XmlDoc -Text $text
    $ns = New-NsManager -Doc $doc -Namespaces @{ p = $script:NsPkg }
    foreach ($r in @($doc.SelectNodes('//p:Relationship', $ns))) {
      $tgt = $r.GetAttribute('Target')
      if (-not [string]::IsNullOrWhiteSpace($tgt)) { $links += $tgt }
    }
  }
  return $links
}

# ---------------------------------------------------------------------------
# [sum] SUM-range-size check.
#
# For every literal-range SUM(...) argument, walk outward from the stated
# range along its own axis (a single-row SUM only looks left/right in that
# row; a single-column SUM only looks up/down in that column; a genuine
# multi-row+multi-column block looks in both axes) and find the true extent
# of contiguous data. A text cell (label/title) or a summary-formula cell
# (SUM/SUBTOTAL/AGGREGATE) stops the walk without being counted as data, so
# row/column titles at the near edge and "Total" cells at the far edge are
# both ignored, per design. If the actual extent differs from what the SUM
# argument states, it's reported.
# ---------------------------------------------------------------------------
function ConvertFrom-ColumnLetters {
  param([string] $Letters)
  $n = 0
  foreach ($ch in $Letters.ToUpperInvariant().ToCharArray()) {
    $n = $n * 26 + ([int]$ch - [int][char]'A' + 1)
  }
  return $n
}

function ConvertTo-ColumnLetters {
  param([int] $Number)
  $n = $Number
  $letters = ''
  while ($n -gt 0) {
    $rem = ($n - 1) % 26
    $letters = [string][char](65 + $rem) + $letters
    $n = [int](($n - $rem - 1) / 26)
  }
  return $letters
}

function Format-RangeAddr {
  param([int] $R1, [int] $R2, [int] $C1, [int] $C2)
  $a1 = (ConvertTo-ColumnLetters $C1) + $R1
  if ($R1 -eq $R2 -and $C1 -eq $C2) { return $a1 }
  $a2 = (ConvertTo-ColumnLetters $C2) + $R2
  return "$a1`:$a2"
}

# Extracts the text between the '(' at $OpenParenIndex and its matching ')',
# respecting nested parens and quoted strings (sheet names / string literals).
function Get-BalancedArgsText {
  param([string] $Text, [int] $OpenParenIndex)
  $depth = 0; $inSingle = $false; $inDouble = $false
  for ($i = $OpenParenIndex; $i -lt $Text.Length; $i++) {
    $ch = $Text[$i]
    if ($inSingle) { if ($ch -eq "'") { $inSingle = $false }; continue }
    if ($inDouble) { if ($ch -eq '"') { $inDouble = $false }; continue }
    switch ($ch) {
      "'"  { $inSingle = $true }
      '"'  { $inDouble = $true }
      '('  { $depth++ }
      ')'  {
        $depth--
        if ($depth -eq 0) { return $Text.Substring($OpenParenIndex + 1, $i - $OpenParenIndex - 1) }
      }
    }
  }
  return $null   # unbalanced - malformed/unsupported, caller should skip
}

# Splits on top-level commas only (ignores commas nested in parens/quotes).
function Split-TopLevelCommaText {
  param([string] $Text)
  $parts = New-Object System.Collections.Generic.List[string]
  $depth = 0; $inSingle = $false; $inDouble = $false; $start = 0
  for ($i = 0; $i -lt $Text.Length; $i++) {
    $ch = $Text[$i]
    if ($inSingle) { if ($ch -eq "'") { $inSingle = $false }; continue }
    if ($inDouble) { if ($ch -eq '"') { $inDouble = $false }; continue }
    switch ($ch) {
      "'"  { $inSingle = $true }
      '"'  { $inDouble = $true }
      '('  { $depth++ }
      ')'  { $depth-- }
      ','  { if ($depth -eq 0) { $parts.Add($Text.Substring($start, $i - $start)); $start = $i + 1 } }
    }
  }
  $parts.Add($Text.Substring($start))
  return ,@($parts)
}

# Parses xl/sharedStrings.xml into an index-ordered list of display strings
# (each <si> may be a plain <t> or several rich-text <r><t> runs to concatenate).
function Get-SharedStrings {
  param($Zip)
  $result = New-Object System.Collections.Generic.List[string]
  $text = Read-ZipEntryText -Zip $Zip -EntryName 'xl/sharedStrings.xml'
  if ($null -eq $text) { return ,$result }
  $doc = New-XmlDoc -Text $text
  $ns = New-NsManager -Doc $doc -Namespaces @{ x = $script:NsMain }
  foreach ($si in @($doc.SelectNodes('/x:sst/x:si', $ns))) {
    $sb = New-Object System.Text.StringBuilder
    foreach ($t in @($si.SelectNodes('.//x:t', $ns))) { [void] $sb.Append($t.InnerText) }
    $result.Add($sb.ToString())
  }
  return ,$result
}

# Resolves the display text of a text-typed cell (t="s"/"str"/"inlineStr").
# Returns $null if it can't be resolved (e.g. a shared-string index out of range).
function Get-CellDisplayText {
  param($Cell, [string] $Type, $VNode, $Ns, $SharedStrings)
  switch ($Type) {
    's' {
      if ($null -eq $VNode -or [string]::IsNullOrEmpty($VNode.InnerText)) { return $null }
      $idx = 0
      if (-not [int]::TryParse($VNode.InnerText, [ref] $idx)) { return $null }
      if ($idx -lt 0 -or $idx -ge $SharedStrings.Count) { return $null }
      return $SharedStrings[$idx]
    }
    'str' { if ($null -eq $VNode) { return $null } else { return $VNode.InnerText } }
    'inlineStr' {
      $isNode = $Cell.SelectSingleNode('x:is', $Ns)
      if ($null -eq $isNode) { return $null }
      $sb = New-Object System.Text.StringBuilder
      foreach ($t in @($isNode.SelectNodes('.//x:t', $Ns))) { [void] $sb.Append($t.InnerText) }
      return $sb.ToString()
    }
    default { return $null }
  }
}

# Builds three sparse "row,col" -> $true maps for one sheet:
#   Numeric      - unconditional data: a non-empty, non-text value that is not
#                  itself a summary/total formula (SUM/SUBTOTAL/AGGREGATE).
#   Placeholder  - text cells matching a recognised placeholder (N/A, Not used,
#                  Summed above). These are CONDITIONAL data: they only count
#                  when they sit among numbers, not among real text labels (see
#                  Test-StripHasData) - a "N/A" mixed into a label column is a
#                  label, not a stand-in number.
#   Label        - text cells that do NOT match a placeholder: real labels/
#                  titles. Never data; also what disqualifies a Placeholder
#                  cell from counting in the same row/column.
function Build-SheetCellMaps {
  param($Zip, $Sheet, $SharedStrings)
  $numeric = @{}; $placeholder = @{}; $label = @{}
  $result = [pscustomobject]@{ Numeric = $numeric; Placeholder = $placeholder; Label = $label }
  if ([string]::IsNullOrEmpty($Sheet.Part)) { return $result }
  $text = Read-ZipEntryText -Zip $Zip -EntryName $Sheet.Part
  if ($null -eq $text) { return $result }
  $doc = New-XmlDoc -Text $text
  $ns = New-NsManager -Doc $doc -Namespaces @{ x = $script:NsMain }
  foreach ($c in @($doc.SelectNodes('//x:sheetData/x:row/x:c', $ns))) {
    $ref = $c.GetAttribute('r')
    if ([string]::IsNullOrEmpty($ref)) { continue }
    $m = $script:CellRefRegex.Match($ref)
    if (-not $m.Success) { continue }
    $t = $c.GetAttribute('t')
    $vNode = $c.SelectSingleNode('x:v', $ns)
    $col = ConvertFrom-ColumnLetters $m.Groups[1].Value
    $row = [int]$m.Groups[2].Value
    $key = "$row,$col"
    if ($t -eq 's' -or $t -eq 'str' -or $t -eq 'inlineStr') {
      $cellText = Get-CellDisplayText -Cell $c -Type $t -VNode $vNode -Ns $ns -SharedStrings $SharedStrings
      if ([string]::IsNullOrEmpty($cellText)) { continue }   # empty text cell
      if ($script:ValidPlaceholderTextRegex.IsMatch($cellText)) { $placeholder[$key] = $true }
      else { $label[$key] = $true }   # real label/title
    } else {
      $fNode = $c.SelectSingleNode('x:f', $ns)
      if ($null -ne $fNode -and $script:AggregateFnRegex.IsMatch($fNode.InnerText)) { continue }   # total/subtotal cell
      if ($null -eq $vNode -or [string]::IsNullOrEmpty($vNode.InnerText)) { continue }   # empty cell
      $numeric[$key] = $true
    }
  }
  return $result
}

# A strip [R1..R2]x[C1..C2] "has data" if it contains a Numeric cell outright,
# or contains a Placeholder cell AND the reference range [RefR1..RefR2]x
# [RefC1..RefC2] - "the other values in the column/row being summed" - has no
# real Label cell. The reference range is usually the strip itself (block
# sums, where the cross-axis already spans several cells); for a single-row/
# single-column sum it's the SUM's own stated range on that same row/column,
# since the strip there is just one candidate cell with nothing else to judge
# it by (see Resolve-AxisRange).
function Test-StripHasData {
  param($Maps, [int] $R1, [int] $R2, [int] $C1, [int] $C2, [int] $RefR1, [int] $RefR2, [int] $RefC1, [int] $RefC2)
  for ($r = $R1; $r -le $R2; $r++) {
    for ($c = $C1; $c -le $C2; $c++) {
      if ($Maps.Numeric.ContainsKey("$r,$c")) { return $true }
    }
  }
  $hasPlaceholder = $false
  for ($r = $R1; $r -le $R2; $r++) {
    for ($c = $C1; $c -le $C2; $c++) {
      if ($Maps.Placeholder.ContainsKey("$r,$c")) { $hasPlaceholder = $true }
    }
  }
  if (-not $hasPlaceholder) { return $false }
  for ($r = $RefR1; $r -le $RefR2; $r++) {
    for ($c = $RefC1; $c -le $RefC2; $c++) {
      if ($Maps.Label.ContainsKey("$r,$c")) { return $false }   # a real label sits alongside - this is a label column/row
    }
  }
  return $true
}

# Resolves the true [From,To] extent along one axis, walking outward from the
# stated [StateFrom,StateTo] while the cross-strip (fixed at CrossFrom..CrossTo
# on the OTHER axis) has data, or walking inward while it does NOT (handles a
# SUM that over-includes now-empty rows/cols after a deletion). Axis 'row'
# means the moving position is a row number (cross = a column range); 'col'
# means it's a column number (cross = a row range).
function Resolve-AxisRange {
  param($Maps, [string] $Axis, [int] $CrossFrom, [int] $CrossTo, [int] $StateFrom, [int] $StateTo, [int] $MinBound = 1)
  # Multi-cell cross (a genuine block axis) judges a candidate line by its own
  # span; a single-cell cross (a plain row/column sum) has nothing else to
  # compare within the strip, so it falls back to the SUM's own stated range
  # on that same fixed line.
  $crossIsBlock = ($CrossFrom -ne $CrossTo)
  $hasData = {
    param($pos)
    if ($Axis -eq 'row') {
      if ($crossIsBlock) {
        return Test-StripHasData -Maps $Maps -R1 $pos -R2 $pos -C1 $CrossFrom -C2 $CrossTo -RefR1 $pos -RefR2 $pos -RefC1 $CrossFrom -RefC2 $CrossTo
      } else {
        return Test-StripHasData -Maps $Maps -R1 $pos -R2 $pos -C1 $CrossFrom -C2 $CrossTo -RefR1 $StateFrom -RefR2 $StateTo -RefC1 $CrossFrom -RefC2 $CrossTo
      }
    } else {
      if ($crossIsBlock) {
        return Test-StripHasData -Maps $Maps -R1 $CrossFrom -R2 $CrossTo -C1 $pos -C2 $pos -RefR1 $CrossFrom -RefR2 $CrossTo -RefC1 $pos -RefC2 $pos
      } else {
        return Test-StripHasData -Maps $Maps -R1 $CrossFrom -R2 $CrossTo -C1 $pos -C2 $pos -RefR1 $CrossFrom -RefR2 $CrossTo -RefC1 $StateFrom -RefC2 $StateTo
      }
    }
  }
  $from = $StateFrom
  if (& $hasData $from) {
    while (($from - 1) -ge $MinBound -and (& $hasData ($from - 1))) { $from-- }
  } else {
    while ($from -lt $StateTo -and -not (& $hasData $from)) { $from++ }
  }
  $to = $StateTo
  if (& $hasData $to) {
    while (& $hasData ($to + 1)) { $to++ }
  } else {
    while ($to -gt $from -and -not (& $hasData $to)) { $to-- }
  }
  return [pscustomobject]@{ From = $from; To = $to }
}

function Get-SumRangeMismatches {
  param($Zip, [array] $SheetMap)
  $issues = @()
  $markedCount = 0
  $dataMapCache = @{}
  $sharedStrings = Get-SharedStrings -Zip $Zip

  foreach ($sheet in $SheetMap) {
    if ([string]::IsNullOrEmpty($sheet.Part)) { continue }
    $text = Read-ZipEntryText -Zip $Zip -EntryName $sheet.Part
    if ($null -eq $text) { continue }
    if ($text.IndexOf('SUM', [System.StringComparison]::OrdinalIgnoreCase) -lt 0) { continue }
    $doc = New-XmlDoc -Text $text
    $ns = New-NsManager -Doc $doc -Namespaces @{ x = $script:NsMain }
    foreach ($fNode in @($doc.SelectNodes('//x:sheetData/x:row/x:c/x:f', $ns))) {
      $formulaText = $fNode.InnerText
      if ([string]::IsNullOrEmpty($formulaText)) { continue }   # e.g. non-master shared formula
      $sumMatches = @($script:SumCallRegex.Matches($formulaText))
      if ($sumMatches.Count -eq 0) { continue }
      if ($script:PartialSumMarkerRegex.IsMatch($formulaText)) { $markedCount++; continue }   # deliberately partial, documented in-cell
      $cellRef = $fNode.ParentNode.GetAttribute('r')

      foreach ($sm in $sumMatches) {
        $openParenIdx = $sm.Index + $sm.Length - 1
        $argsText = Get-BalancedArgsText -Text $formulaText -OpenParenIndex $openParenIdx
        if ($null -eq $argsText) { continue }

        foreach ($arg in (Split-TopLevelCommaText -Text $argsText)) {
          $a = $arg.Trim()
          $rm = $script:RangeArgRegex.Match($a)
          if (-not $rm.Success) { continue }   # not a plain range (table ref, named range, literal, nested call, ...)

          $rangeSheetName = if ($rm.Groups['sheet'].Success) { $rm.Groups['sheet'].Value.Trim("'") } else { $sheet.Name }
          $c1 = ConvertFrom-ColumnLetters $rm.Groups['c1'].Value
          $c2 = ConvertFrom-ColumnLetters $rm.Groups['c2'].Value
          $r1 = [int] $rm.Groups['r1'].Value
          $r2 = [int] $rm.Groups['r2'].Value
          if ($c1 -gt $c2) { $tmp = $c1; $c1 = $c2; $c2 = $tmp }
          if ($r1 -gt $r2) { $tmp = $r1; $r1 = $r2; $r2 = $tmp }
          if ($r1 -eq $r2 -and $c1 -eq $c2) { continue }   # single cell, not a range

          if (-not $dataMapCache.ContainsKey($rangeSheetName)) {
            $rangeSheetInfo = $SheetMap | Where-Object { $_.Name -eq $rangeSheetName } | Select-Object -First 1
            if ($null -eq $rangeSheetInfo) { $dataMapCache[$rangeSheetName] = $null }
            else { $dataMapCache[$rangeSheetName] = Build-SheetCellMaps -Zip $Zip -Sheet $rangeSheetInfo -SharedStrings $sharedStrings }
          }
          $maps = $dataMapCache[$rangeSheetName]
          if ($null -eq $maps) { continue }   # sheet not found (e.g. unresolved external ref) - skip rather than guess

          $actR1 = $r1; $actR2 = $r2; $actC1 = $c1; $actC2 = $c2
          if ($r1 -eq $r2) {
            # Single row, multiple columns: only look left/right within that row.
            $res = Resolve-AxisRange -Maps $maps -Axis 'col' -CrossFrom $r1 -CrossTo $r1 -StateFrom $c1 -StateTo $c2
            $actC1 = $res.From; $actC2 = $res.To
          } elseif ($c1 -eq $c2) {
            # Single column, multiple rows: only look up/down within that column.
            $res = Resolve-AxisRange -Maps $maps -Axis 'row' -CrossFrom $c1 -CrossTo $c1 -StateFrom $r1 -StateTo $r2
            $actR1 = $res.From; $actR2 = $res.To
          } else {
            # A genuine block: check both axes, each against the OTHER axis's
            # original stated span (not the evolving one - keeps the walk
            # simple/predictable and avoids one axis dragging the other along).
            $resCols = Resolve-AxisRange -Maps $maps -Axis 'col' -CrossFrom $r1 -CrossTo $r2 -StateFrom $c1 -StateTo $c2
            $resRows = Resolve-AxisRange -Maps $maps -Axis 'row' -CrossFrom $c1 -CrossTo $c2 -StateFrom $r1 -StateTo $r2
            $actC1 = $resCols.From; $actC2 = $resCols.To
            $actR1 = $resRows.From; $actR2 = $resRows.To
          }

          $stated = Format-RangeAddr -R1 $r1 -R2 $r2 -C1 $c1 -C2 $c2
          $actual = Format-RangeAddr -R1 $actR1 -R2 $actR2 -C1 $actC1 -C2 $actC2
          if ($stated -eq $actual) { continue }

          $issues += [pscustomobject]@{
            Sheet = $sheet.Name; Cell = $cellRef; RangeSheet = $rangeSheetName
            Stated = $stated; Actual = $actual; Formula = '=' + $formulaText
          }
        }
      }
    }
  }
  return [pscustomobject]@{ Issues = $issues; Marked = $markedCount }
}

# ---------------------------------------------------------------------------
# Report a capped list.
# ---------------------------------------------------------------------------
function Write-Capped {
  param([array] $Items, [int] $Max, [scriptblock] $Format)
  $shown = if ($Max -le 0) { $Items.Count } else { [Math]::Min($Max, $Items.Count) }
  for ($i = 0; $i -lt $shown; $i++) { Write-Host ('    ' + (& $Format $Items[$i])) }
  if ($shown -lt $Items.Count) { Write-Host ("    ... and {0} more" -f ($Items.Count - $shown)) }
}

# ===========================================================================
# Main.
# ===========================================================================
$workbooks = Get-TargetWorkbooks -RepoRoot $RepoRoot -WorkbookPath $WorkbookPath
if (@($workbooks).Count -eq 0) { Write-Host 'No workbooks found to scan.'; return }

Write-Host ("Scanning {0} workbook(s) for errors (read-only)..." -f @($workbooks).Count)

$grand = @{ cell = 0; name = 0; link = 0; sum = 0; marked = 0; wbWithIssues = 0 }

foreach ($path in $workbooks) {
  $leaf = Split-Path $path -Leaf
  $cellErrors = @(); $nameErrors = @(); $extLinks = @(); $sumMismatches = @(); $sumMarked = 0
  try {
    $zip = [System.IO.Compression.ZipFile]::Open($path, [System.IO.Compression.ZipArchiveMode]::Read)
    try {
      $sheetMap   = @(Get-SheetMap -Zip $zip)
      $cellErrors = @(Get-CellErrors  -Zip $zip -SheetMap $sheetMap)
      $nameErrors = @(Get-NameErrors  -Zip $zip -SheetMap $sheetMap -IncludeLibraryFunctions:$IncludeLibraryFunctions)
      $extLinks   = @(Get-ExternalLinks -Zip $zip)
      if (-not $SkipSumCheck) {
        $sumResult     = Get-SumRangeMismatches -Zip $zip -SheetMap $sheetMap
        $sumMismatches = @($sumResult.Issues)
        $sumMarked     = $sumResult.Marked
      }
    } finally { $zip.Dispose() }
  } catch {
    Write-Host ''
    Write-Host ('=' * 78)
    Write-Host ("Workbook : {0}" -f $leaf)
    Write-Warning ("  Could not read workbook: {0}" -f $_.Exception.Message)
    continue
  }

  $grand.marked += $sumMarked
  $total = $cellErrors.Count + $nameErrors.Count + $extLinks.Count + $sumMismatches.Count
  if ($total -eq 0) { continue }
  $grand.wbWithIssues++

  Write-Host ''
  Write-Host ('=' * 78)
  Write-Host ("Workbook : {0}" -f $leaf)

  if ($cellErrors.Count -gt 0) {
    $grand.cell += $cellErrors.Count
    Write-Host ("  Cell errors ({0}):" -f $cellErrors.Count) -ForegroundColor Red
    Write-Capped -Items $cellErrors -Max $Max -Format {
      param($e) "[{0,-8}] '{1}'!{2}  {3}" -f $e.Error, $e.Sheet, $e.Cell, $e.Formula
    }
  }

  if ($nameErrors.Count -gt 0) {
    $grand.name += $nameErrors.Count
    Write-Host ("  Broken defined names ({0}):" -f $nameErrors.Count) -ForegroundColor DarkYellow
    Write-Capped -Items $nameErrors -Max $Max -Format {
      param($n) "[{0,-9}] {1} ({2})  {3}" -f $n.Category, $n.Name, $n.Scope, $n.RefersTo
    }
  }

  if ($extLinks.Count -gt 0) {
    $grand.link += $extLinks.Count
    Write-Host ("  External links ({0}):" -f $extLinks.Count) -ForegroundColor Yellow
    Write-Capped -Items $extLinks -Max $Max -Format { param($l) $l }
  }

  if ($sumMismatches.Count -gt 0) {
    $grand.sum += $sumMismatches.Count
    Write-Host ("  SUM range size mismatches ({0}):" -f $sumMismatches.Count) -ForegroundColor Cyan
    Write-Capped -Items $sumMismatches -Max $Max -Format {
      param($s)
      $sheetTag = if ($s.RangeSheet -eq $s.Sheet) { '' } else { " [range on '$($s.RangeSheet)']" }
      "'{0}'!{1}  SUM range {2} but data spans {3}{4}   {5}" -f $s.Sheet, $s.Cell, $s.Stated, $s.Actual, $sheetTag, $s.Formula
    }
    if ($sumMarked -gt 0) {
      Write-Host ("    ({0} other SUM formula(s) marked intentional via N(`"Partial...`") - skipped)" -f $sumMarked) -ForegroundColor DarkGray
    }
  }
}

Write-Host ''
Write-Host ('=' * 78)
if ($grand.wbWithIssues -eq 0) {
  Write-Host ("CLEAN: no errors found in {0} workbook(s)." -f @($workbooks).Count) -ForegroundColor Green
} else {
  Write-Host ("TOTAL: {0} cell error(s), {1} broken name(s), {2} external link(s), {3} SUM range mismatch(es) across {4} of {5} workbook(s)." -f `
    $grand.cell, $grand.name, $grand.link, $grand.sum, $grand.wbWithIssues, @($workbooks).Count)
}
if ($grand.marked -gt 0) {
  Write-Host ("       ({0} SUM formula(s) marked intentional via N(`"Partial...`") across all scanned workbooks)" -f $grand.marked) -ForegroundColor DarkGray
}

if ($FailOnError -and ($grand.cell -gt 0 -or $grand.name -gt 0)) { exit 1 }
