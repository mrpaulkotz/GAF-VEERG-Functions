<#
.SYNOPSIS
  Strip orphaned ("phantom") external-workbook link artifacts from Excel/*.xlsx.

.DESCRIPTION
  An OOXML workbook can carry xl/externalLinks/* parts (cross-workbook link
  bookkeeping) that Excel's COM API never cleans up, even after every cell
  formula and defined name that referenced them is gone - Name.Delete() on the
  last name pointing at an external workbook does not touch the link itself,
  and COM's BreakLink throws on a missing/renamed path. The leftover part is
  otherwise invisible: Excel's own Edit Links dialog and Name Manager don't
  surface it once nothing references it, so it can only be found by reading
  the package XML directly.

  For each workbook, this reads xl/workbook.xml's <externalReferences> list
  (each entry's 1-based position is the [N] index formulas/names use) and
  scans every worksheet's stored <f> formula text plus every defined name's
  RefersTo for a live [N] reference. An entry with zero references anywhere
  is phantom and gets removed:
    - the <externalReference> entry (and the whole <externalReferences>
      element, if it becomes empty)
    - its relationship in xl/_rels/workbook.xml.rels
    - the xl/externalLinks/externalLinkN.xml part and its _rels sibling
    - the [Content_Types].xml <Override> for that part

  If a workbook has multiple external references and only some are phantom,
  the remaining live ones are renumbered to close the gap (e.g. [1],[2],[3]
  with [2] phantom -> [1],[2]) and every formula/name using an old index is
  rewritten to the new one, in a single pass so no rewrite can collide with
  another.

  A [0]! prefix inside a LAMBDA body (Excel Labs' own convention for one
  named function calling another within the same workbook) is NOT a real
  external-link index - position 0 does not exist in <externalReferences> -
  so it is never treated as a "usage" of, or renumbered against, anything.

  Read-only (reports only) unless -Commit is passed, matching apply-names.ps1
  / audit-names.ps1. XML/zip-only - no Excel, no COM.

.PARAMETER RepoRoot
  Repository root. Defaults to the parent of the scripts folder.

.PARAMETER WorkbookPath
  Full path to a single .xlsx to process. If omitted, every top-level
  Excel/*.xlsx and Excel/Enterprises/*.xlsx is scanned (skips ~$*, *_expanded*,
  *_template*, *.bak).

.PARAMETER Commit
  Write the changes. Without it, only reports what would be removed.

.EXAMPLE
  npm run remove-phantom-links
  npm run remove-phantom-links:commit
  powershell -File .\scripts\remove-phantom-external-links.ps1 -WorkbookPath .\Excel\10_SolidWaste_WIP_v02.xlsx -Commit
#>
param(
  [string] $RepoRoot = (Split-Path $PSScriptRoot -Parent),
  [string] $WorkbookPath,
  [switch] $Commit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

$script:NsMain = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
$script:NsRel  = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships'
$script:NsPkg  = 'http://schemas.openxmlformats.org/package/2006/relationships'
$script:NsCt   = 'http://schemas.openxmlformats.org/package/2006/content-types'

# A real external-link index: [N] where N is 1+ digits and N != 0, used ONLY
# in genuine external-reference syntax - [N]!Name, [N]SheetName!, or
# '[N]Sheet Name'! (all zero-width-checked via lookahead so the match itself
# stays exactly "[N]", which the renumber pass below depends on). A bare [N]
# substring is NOT enough: source-citation text like "Dairy Australia [1]" or
# "IPCC (2019), Chapter 10 [4]" shows up verbatim in LAMBDA description
# strings and their cached <v> results, and a plain \[([1-9][0-9]*)\] match
# false-positives on those, making a genuinely phantom link look "used" and
# never get cleaned up (found via 13_Scope3_WIP_v14.xlsx and 3 other
# workbooks still reporting the Common_v03.xlsx external link after a
# reported-clean run). 0 is Excel Labs' internal self/LAMBDA-cross-reference
# marker, unrelated to <externalReferences> positions (which start at 1).
$script:ExtRefRegex = [regex]::new(
  '\[(?<idx>[1-9][0-9]*)\](?=!)' +
  "|(?<=')\[(?<idx>[1-9][0-9]*)\](?=[^'\r\n]*'!)" +
  '|\[(?<idx>[1-9][0-9]*)\](?=[A-Za-z_][A-Za-z0-9_.]*!)'
)

# ---------------------------------------------------------------------------
# Workbook discovery (matches find-excel-errors.ps1 / audit-names.ps1).
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

function Write-ZipEntryText {
  param($Zip, [string] $EntryName, [string] $Text)
  $existing = $Zip.GetEntry($EntryName)
  if ($null -ne $existing) { $existing.Delete() }
  $entry = $Zip.CreateEntry($EntryName)
  $writer = [System.IO.StreamWriter]::new($entry.Open(), [System.Text.UTF8Encoding]::new($false))
  try { $writer.Write($Text) } finally { $writer.Dispose() }
}

function Save-XmlDocEntry {
  param($Zip, [string] $EntryName, $Doc)
  $existing = $Zip.GetEntry($EntryName)
  if ($null -ne $existing) { $existing.Delete() }
  $entry = $Zip.CreateEntry($EntryName)
  $writer = [System.IO.StreamWriter]::new($entry.Open(), [System.Text.UTF8Encoding]::new($false))
  try { $Doc.Save($writer) } finally { $writer.Dispose() }
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
  return ,$ns
}

# ---------------------------------------------------------------------------
# Collect every [N] (N>=1) index referenced anywhere in the workbook: every
# worksheet's stored formula text, and every defined name's RefersTo.
# ---------------------------------------------------------------------------
function Get-UsedExternalIndices {
  param($Zip)
  $used = New-Object 'System.Collections.Generic.HashSet[int]'

  foreach ($entry in $Zip.Entries) {
    if ($entry.FullName -notmatch '^xl/worksheets/sheet\d+\.xml$') { continue }
    $text = Read-ZipEntryText -Zip $Zip -EntryName $entry.FullName
    if ($null -eq $text -or $text.IndexOf('[') -lt 0) { continue }
    foreach ($m in $script:ExtRefRegex.Matches($text)) { [void] $used.Add([int] $m.Groups['idx'].Value) }
  }

  $wbText = Read-ZipEntryText -Zip $Zip -EntryName 'xl/workbook.xml'
  if ($null -ne $wbText) {
    foreach ($m in $script:ExtRefRegex.Matches($wbText)) { [void] $used.Add([int] $m.Groups['idx'].Value) }
  }

  return ,$used   # comma prevents PowerShell from enumerating (and un-wrapping to $null when empty)
}

# ---------------------------------------------------------------------------
# Process a single workbook. Returns a summary; performs no writes unless
# $Commit is set.
# ---------------------------------------------------------------------------
function Repair-PhantomExternalLinks {
  param([string] $Path, [switch] $Commit)

  $zipMode = if ($Commit) { [System.IO.Compression.ZipArchiveMode]::Update } else { [System.IO.Compression.ZipArchiveMode]::Read }
  $zip = [System.IO.Compression.ZipFile]::Open($Path, $zipMode)
  try {
    $wbText = Read-ZipEntryText -Zip $zip -EntryName 'xl/workbook.xml'
    if ($null -eq $wbText -or $wbText.IndexOf('<externalReferences') -lt 0) {
      return [pscustomobject]@{ Total = 0; PhantomPositions = @(); Committed = $false }
    }

    $wbDoc = New-XmlDoc -Text $wbText
    $wbNs = New-NsManager -Doc $wbDoc -Namespaces @{ x = $script:NsMain; r = $script:NsRel }
    $extRefsNode = $wbDoc.SelectSingleNode('/x:workbook/x:externalReferences', $wbNs)
    if ($null -eq $extRefsNode) {
      return [pscustomobject]@{ Total = 0; PhantomPositions = @(); Committed = $false }
    }

    $order = @()
    $pos = 1
    foreach ($ref in @($extRefsNode.SelectNodes('x:externalReference', $wbNs))) {
      $order += [pscustomobject]@{ Position = $pos; RId = $ref.GetAttribute('id', $script:NsRel) }
      $pos++
    }
    if ($order.Count -eq 0) {
      return [pscustomobject]@{ Total = 0; PhantomPositions = @(); Committed = $false }
    }

    $used = Get-UsedExternalIndices -Zip $zip
    $phantom = @($order | Where-Object { -not $used.Contains($_.Position) })
    $kept    = @($order | Where-Object { $used.Contains($_.Position) })

    $result = [pscustomobject]@{
      Total            = $order.Count
      PhantomPositions = @($phantom | ForEach-Object { $_.Position })
      Committed        = $false
    }
    if ($phantom.Count -eq 0 -or -not $Commit) { return $result }

    # --- Resolve target parts for the phantom rIds via workbook.xml.rels. --------
    $relText = Read-ZipEntryText -Zip $zip -EntryName 'xl/_rels/workbook.xml.rels'
    $relDoc = New-XmlDoc -Text $relText
    $relNs = New-NsManager -Doc $relDoc -Namespaces @{ p = $script:NsPkg }
    $relById = @{}
    foreach ($rel in @($relDoc.SelectNodes('/p:Relationships/p:Relationship', $relNs))) {
      $relById[$rel.GetAttribute('Id')] = $rel
    }

    # --- Old->new position mapping for the KEPT (live) entries. -------------------
    $renumber = @{}
    $newPos = 1
    foreach ($k in $kept) {
      if ($k.Position -ne $newPos) { $renumber[$k.Position] = $newPos }
      $newPos++
    }

    # --- Renumber [oldPos] -> [newPos] for every live entry whose index shifted,
    #     across every worksheet and workbook.xml, in one pass per file so no two
    #     renumbers can collide (mirrors the lookup-MatchEvaluator approach used to
    #     fix the same class of collision risk in sync-xlf-to-excel-labs.ps1). ------
    if ($renumber.Count -gt 0) {
      # Same genuine-usage-only constraint as $script:ExtRefRegex above - a bare
      # \[(oldPos)\] would also rewrite citation text like "Chapter 10 [4]"
      # into "Chapter 10 [3]" if 4 happened to be a renumbered position.
      $digits = ($renumber.Keys | Sort-Object -Descending) -join '|'
      $renumberPattern = [regex]::new(
        "\[(?<idx>$digits)\](?=!)" +
        "|(?<=')\[(?<idx>$digits)\](?=[^'\r\n]*'!)" +
        "|\[(?<idx>$digits)\](?=[A-Za-z_][A-Za-z0-9_.]*!)"
      )
      $renumberEval = [System.Text.RegularExpressions.MatchEvaluator] { param($m) '[' + $renumber[[int] $m.Groups['idx'].Value] + ']' }

      foreach ($entry in @($zip.Entries | Where-Object { $_.FullName -match '^xl/worksheets/sheet\d+\.xml$' })) {
        $text = Read-ZipEntryText -Zip $zip -EntryName $entry.FullName
        if ($null -eq $text -or -not $renumberPattern.IsMatch($text)) { continue }
        Write-ZipEntryText -Zip $zip -EntryName $entry.FullName -Text ($renumberPattern.Replace($text, $renumberEval))
      }

      $wbText = $renumberPattern.Replace($wbText, $renumberEval)
      $wbDoc = New-XmlDoc -Text $wbText
      $wbNs = New-NsManager -Doc $wbDoc -Namespaces @{ x = $script:NsMain; r = $script:NsRel }
      $extRefsNode = $wbDoc.SelectSingleNode('/x:workbook/x:externalReferences', $wbNs)
    }

    # --- Remove the phantom <externalReference> nodes. ----------------------------
    foreach ($p in $phantom) {
      $node = $extRefsNode.SelectSingleNode("x:externalReference[@r:id='" + $p.RId + "']", $wbNs)
      if ($null -ne $node) { [void] $extRefsNode.RemoveChild($node) }
    }
    if (-not $extRefsNode.HasChildNodes) { [void] $extRefsNode.ParentNode.RemoveChild($extRefsNode) }
    Save-XmlDocEntry -Zip $zip -EntryName 'xl/workbook.xml' -Doc $wbDoc

    # --- Remove the phantom relationships + their target parts. -------------------
    $partsToDelete = New-Object System.Collections.Generic.List[string]
    $relChanged = $false
    foreach ($p in $phantom) {
      $rel = $relById[$p.RId]
      if ($null -eq $rel) { continue }
      $target = $rel.GetAttribute('Target')
      $partPath = if ($target.StartsWith('/')) { $target.TrimStart('/') } else { 'xl/' + $target }
      $partsToDelete.Add($partPath)
      [void] $rel.ParentNode.RemoveChild($rel)
      $relChanged = $true
    }
    if ($relChanged) { Save-XmlDocEntry -Zip $zip -EntryName 'xl/_rels/workbook.xml.rels' -Doc $relDoc }

    foreach ($partPath in $partsToDelete) {
      $partRelsPath = ($partPath -replace '^(xl/externalLinks)/([^/]+)$', '$1/_rels/$2') + '.rels'
      foreach ($p in @($partPath, $partRelsPath)) {
        $e = $zip.GetEntry($p)
        if ($null -ne $e) { $e.Delete() }
      }
    }

    # --- [Content_Types].xml overrides for the removed parts. ---------------------
    if ($partsToDelete.Count -gt 0) {
      $ctText = Read-ZipEntryText -Zip $zip -EntryName '[Content_Types].xml'
      if ($null -ne $ctText) {
        $ctDoc = New-XmlDoc -Text $ctText
        $ctNs = New-NsManager -Doc $ctDoc -Namespaces @{ c = $script:NsCt }
        $ctChanged = $false
        foreach ($ov in @($ctDoc.SelectNodes('/c:Types/c:Override', $ctNs))) {
          $partName = $ov.GetAttribute('PartName').TrimStart('/')
          if ($partsToDelete -contains $partName) { [void] $ov.ParentNode.RemoveChild($ov); $ctChanged = $true }
        }
        if ($ctChanged) { Save-XmlDocEntry -Zip $zip -EntryName '[Content_Types].xml' -Doc $ctDoc }
      }
    }

    $result.Committed = $true
    return $result
  } finally {
    $zip.Dispose()
  }
}

# ===========================================================================
# Main.
# ===========================================================================
$workbooks = Get-TargetWorkbooks -RepoRoot $RepoRoot -WorkbookPath $WorkbookPath
if (@($workbooks).Count -eq 0) { Write-Host 'No workbooks found to scan.'; return }

$mode = if ($Commit) { 'COMMIT' } else { 'DRY RUN' }
Write-Host ("Scanning {0} workbook(s) for phantom external links [{1}]..." -f @($workbooks).Count, $mode)

$grand = @{ workbooksWithPhantom = 0; phantomLinks = 0 }

foreach ($path in $workbooks) {
  $leaf = Split-Path $path -Leaf
  try {
    $r = Repair-PhantomExternalLinks -Path $path -Commit:$Commit
  } catch {
    Write-Host ''
    Write-Warning ("{0}: could not process - {1}" -f $leaf, $_.Exception.Message)
    continue
  }

  if ($r.Total -eq 0) { continue }
  if ($r.PhantomPositions.Count -eq 0) { continue }

  $grand.workbooksWithPhantom++
  $grand.phantomLinks += $r.PhantomPositions.Count
  $verb = if ($r.Committed) { 'removed' } else { 'phantom (dry-run, use -Commit to remove)' }
  Write-Host ("{0}: {1}/{2} external reference(s) {3} - positions [{4}]" -f `
    $leaf, $r.PhantomPositions.Count, $r.Total, $verb, ($r.PhantomPositions -join ','))
}

Write-Host ''
if ($grand.workbooksWithPhantom -eq 0) {
  Write-Host ("CLEAN: no phantom external links found in {0} workbook(s)." -f @($workbooks).Count) -ForegroundColor Green
} else {
  Write-Host ("TOTAL: {0} phantom external link(s) across {1} of {2} workbook(s)." -f `
    $grand.phantomLinks, $grand.workbooksWithPhantom, @($workbooks).Count)
}
