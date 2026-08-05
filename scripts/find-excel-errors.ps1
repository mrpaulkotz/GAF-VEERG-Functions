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

$grand = @{ cell = 0; name = 0; link = 0; wbWithIssues = 0 }

foreach ($path in $workbooks) {
  $leaf = Split-Path $path -Leaf
  $cellErrors = @(); $nameErrors = @(); $extLinks = @()
  try {
    $zip = [System.IO.Compression.ZipFile]::Open($path, [System.IO.Compression.ZipArchiveMode]::Read)
    try {
      $sheetMap   = @(Get-SheetMap -Zip $zip)
      $cellErrors = @(Get-CellErrors  -Zip $zip -SheetMap $sheetMap)
      $nameErrors = @(Get-NameErrors  -Zip $zip -SheetMap $sheetMap -IncludeLibraryFunctions:$IncludeLibraryFunctions)
      $extLinks   = @(Get-ExternalLinks -Zip $zip)
    } finally { $zip.Dispose() }
  } catch {
    Write-Host ''
    Write-Host ('=' * 78)
    Write-Host ("Workbook : {0}" -f $leaf)
    Write-Warning ("  Could not read workbook: {0}" -f $_.Exception.Message)
    continue
  }

  $total = $cellErrors.Count + $nameErrors.Count + $extLinks.Count
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
}

Write-Host ''
Write-Host ('=' * 78)
if ($grand.wbWithIssues -eq 0) {
  Write-Host ("CLEAN: no errors found in {0} workbook(s)." -f @($workbooks).Count) -ForegroundColor Green
} else {
  Write-Host ("TOTAL: {0} cell error(s), {1} broken name(s), {2} external link(s) across {3} of {4} workbook(s)." -f `
    $grand.cell, $grand.name, $grand.link, $grand.wbWithIssues, @($workbooks).Count)
}

if ($FailOnError -and ($grand.cell -gt 0 -or $grand.name -gt 0)) { exit 1 }
