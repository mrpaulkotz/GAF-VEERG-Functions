<#
.SYNOPSIS
  Build the Scope 3 workbook from the Scope 3 template by importing the current
  Input / Calculation / Constants sheets (and their Excel Labs modules) from the
  latest versioned source workbooks.

.DESCRIPTION
  Mirrors build-enterprise-excel.ps1 but is data-driven from a fixed import map
  rather than a module registry. The Scope 3 template already contains
  placeholder copies of every imported sheet, so - unlike the enterprise build,
  which SKIPS sheets already present - this build REPLACES each placeholder with
  a fresh copy from the source workbook (deleting the placeholder and re-copying
  the source sheet into the same tab position).

  Deleting a sheet turns any direct '<sheet>'!cell reference from OTHER (kept)
  sheets into #REF!. Only a handful of native template sheets reference a
  replaced sheet directly (all into 'Constants - Fertiliser'); those formulas
  are captured verbatim before the delete and rewritten afterwards, once the
  replacement sheet exists again.

  After import the script re-links workbook-scoped names, localises the
  externalised cross-sheet/table references the one-at-a-time sheet copy
  produces, breaks leftover external links, prunes redundant sheet-scoped
  shadow names, merges the Excel Labs (AFE) modules from the source workbooks
  and re-publishes their named functions to the Name Manager - exactly as the
  enterprise build does.

.PARAMETER RepoRoot
  Repository root (defaults to the parent of this script's folder).

.PARAMETER TemplatePath
  Scope 3 template workbook. Defaults to the latest Excel\13_Scope3_Template_WIP_v*.xlsx.

.PARAMETER OutputPath
  Output workbook. Defaults to the template name with "_Template" removed
  (e.g. 13_Scope3_Template_WIP_v13.xlsx -> Excel\13_Scope3_WIP_v13.xlsx).

.PARAMETER DryRun
  Report the resolved template, sources and import plan without writing anything.
#>
param(
  [string] $RepoRoot = (Split-Path $PSScriptRoot -Parent),
  [string] $TemplatePath,
  [string] $OutputPath,
  [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

# Shared Excel Labs (AFE) named-function re-publish helper.
. (Join-Path $PSScriptRoot 'afe-named-functions.ps1')

# Shared left-hand navigation-menu generator (Set-NavMenu).
. (Join-Path $PSScriptRoot 'nav-menu.ps1')

# Shared worksheet view helpers (Set-WorkbookZoom).
. (Join-Path $PSScriptRoot 'worksheet-view.ps1')

# Shared pre-flight file-accessibility guard (Assert-FilesAccessible).
. (Join-Path $PSScriptRoot 'file-access.ps1')

# ---------------------------------------------------------------------------
# Import map: which sheet to pull from which source workbook (version-agnostic
# stem - Resolve-SourceWorkbook always picks the latest _v<NN>). Sheet names are
# the ACTUAL source tab names.
# ---------------------------------------------------------------------------
$ImportMap = @(
  # --- Inputs ---
  [pscustomobject]@{ Category = 'input';       Source = '5_Fertiliser';                      Sheet = 'Input - Site' }
  [pscustomobject]@{ Category = 'input';       Source = '5_Fertiliser';                      Sheet = 'Input - Fertiliser' }
  [pscustomobject]@{ Category = 'input';       Source = '8_Fuel';                            Sheet = 'Input - Fuel' }
  [pscustomobject]@{ Category = 'input';       Source = '10_SolidWaste';                     Sheet = 'Input - Solid waste' }
  [pscustomobject]@{ Category = 'input';       Source = '14_Electricity_Scope2';             Sheet = 'Input - Electricity' }

  # --- Calculations ---
  [pscustomobject]@{ Category = 'calculation'; Source = '8_Fuel';                            Sheet = '8.1.1.1-2 Transport fuel' }
  [pscustomobject]@{ Category = 'calculation'; Source = '8_Fuel';                            Sheet = '8.2.1.1-2 Stationary fuel' }
  [pscustomobject]@{ Category = 'calculation'; Source = '10_SolidWaste';                     Sheet = '10.1.1-2 Solid waste treatment' }

  # --- Constants ---
  [pscustomobject]@{ Category = 'constants';   Source = '8_Fuel';                            Sheet = 'Constants - Fuel' }
  [pscustomobject]@{ Category = 'constants';   Source = '10_SolidWaste';                     Sheet = 'Constants - Solid Waste' }
  [pscustomobject]@{ Category = 'constants';   Source = '5_Fertiliser';                      Sheet = 'Constants - Fertiliser' }
  [pscustomobject]@{ Category = 'constants';   Source = '14_Electricity_Scope2';             Sheet = 'Constants - Electricity' }
  [pscustomobject]@{ Category = 'constants';   Source = '4_2_ManureManagement_BeefPasture';  Sheet = 'Constants - Pasture Beef' }
  [pscustomobject]@{ Category = 'constants';   Source = '4_3_ManureManagement_Dairy';        Sheet = 'Constants - Dairy' }
  [pscustomobject]@{ Category = 'constants';   Source = '4_5_ManureManagement_Swine';        Sheet = 'Constants - Swine' }
  [pscustomobject]@{ Category = 'constants';   Source = '4_6_ManureManagement_Poultry';      Sheet = 'Constants - Poultry' }
  [pscustomobject]@{ Category = 'constants';   Source = '4_2_ManureManagement_BeefPasture';  Sheet = 'Constants - Common Livestock' }
)

# ===========================================================================
# Helpers (mirrored from build-enterprise-excel.ps1)
# ===========================================================================

function Resolve-SourceWorkbook {
  param([string] $ExcelDir, [string] $HintName)

  $exact = Join-Path $ExcelDir $HintName
  if (Test-Path -LiteralPath $exact) { return (Resolve-Path -LiteralPath $exact).Path }

  $base = [System.IO.Path]::GetFileNameWithoutExtension($HintName)
  $stem = [regex]::Replace($base, '_v\d+$', '')
  $stemRegex = '(?i)^' + [regex]::Escape($stem) + '(_.*)?_v\d+$'

  $best = Get-ChildItem -Path $ExcelDir -File |
    Where-Object {
      ($_.Extension -eq '.xlsx' -or $_.Extension -eq '.xlsm') -and
      $_.Name -notlike '~$*' -and
      $_.BaseName -notmatch '(?i)_expanded' -and
      $_.BaseName -notmatch '(?i)\.bak$' -and
      ($_.BaseName -match $stemRegex -or
       [regex]::Replace($_.BaseName, '_v\d+$', '') -eq $stem)
    } |
    Sort-Object @{ Expression = { if ($_.BaseName -match '_v(\d+)$') { [int] $matches[1] } else { -1 } } }, Name -Descending |
    Select-Object -First 1

  if ($null -ne $best) { return $best.FullName }
  throw "Source workbook not found for '$HintName' (stem '$stem') under $ExcelDir"
}

function Read-AfeProject {
  param([string] $WorkbookPath)

  $zip = [System.IO.Compression.ZipFile]::Open($WorkbookPath, 'Read')
  try {
    foreach ($entry in $zip.Entries) {
      if ($entry.FullName -notlike 'customXml/item*.xml') { continue }
      $reader = [System.IO.StreamReader]::new($entry.Open())
      try { $xml = $reader.ReadToEnd() } finally { $reader.Dispose() }
      if ($xml -match '<AFEJSONBlob') {
        $b64 = [regex]::Match($xml, '(?s)<AFEJSONBlob[^>]*>(.*)</AFEJSONBlob>').Groups[1].Value
        if ([string]::IsNullOrWhiteSpace($b64)) { continue }
        $json = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($b64))
        return [pscustomobject]@{
          EntryName = $entry.FullName
          Xml       = $xml
          Project   = ($json | ConvertFrom-Json)
        }
      }
    }
  } finally { $zip.Dispose() }
  return $null
}

function Get-AfeModulePaths {
  # Returns the AFE module paths (/projects/<Module>) declared in a workbook,
  # excluding the workbook-specific /projects/Workbook module.
  param([string] $WorkbookPath)
  $paths = New-Object System.Collections.Generic.List[string]
  $proj = Read-AfeProject -WorkbookPath $WorkbookPath
  if ($null -eq $proj) { return $paths }
  foreach ($f in @($proj.Project.files)) {
    $p = [string] $f.path
    if ([string]::IsNullOrWhiteSpace($p)) { continue }
    if ($p -ieq '/projects/Workbook') { continue }
    $paths.Add($p)
  }
  return $paths
}

function Merge-AfeModules {
  param(
    [string] $TargetPath,
    [string[]] $RequiredModulePaths,
    [string[]] $SourceWorkbookPaths
  )

  $target = Read-AfeProject -WorkbookPath $TargetPath
  if ($null -eq $target) {
    Write-Warning "Target workbook has no Excel Labs (AFE) project; skipping module merge."
    return [pscustomobject]@{ Added = @(); Updated = @() }
  }

  $existing = @{}
  foreach ($f in @($target.Project.files)) { $existing[$f.path] = $f }

  $available = @{}
  foreach ($src in ($SourceWorkbookPaths | Select-Object -Unique)) {
    $proj = Read-AfeProject -WorkbookPath $src
    if ($null -eq $proj) { continue }
    foreach ($f in @($proj.Project.files)) {
      if (-not $available.ContainsKey($f.path)) { $available[$f.path] = $f }
    }
  }

  $added = New-Object System.Collections.Generic.List[string]
  $updated = New-Object System.Collections.Generic.List[string]
  $missing = New-Object System.Collections.Generic.List[string]
  $toAdd = New-Object System.Collections.Generic.List[object]

  foreach ($mp in ($RequiredModulePaths | Select-Object -Unique)) {
    if (-not $available.ContainsKey($mp)) {
      if (-not $existing.ContainsKey($mp)) { $missing.Add($mp) }
      continue
    }
    $src = $available[$mp]
    if ($existing.ContainsKey($mp)) {
      $tgt = $existing[$mp]
      $srcText = [string] $src.text
      $tgtText = [string] $tgt.text
      if (($srcText -replace "`r`n?", "`n") -ne ($tgtText -replace "`r`n?", "`n")) {
        $tgt.text = $src.text
        $updated.Add($mp)
      }
    } else {
      $toAdd.Add($src)
      $added.Add($mp)
    }
  }

  foreach ($m in $missing) { Write-Warning "Excel Labs module not found in any source workbook: $m" }

  if ($toAdd.Count -eq 0 -and $updated.Count -eq 0) { return [pscustomobject]@{ Added = @(); Updated = @() } }
  if ($DryRun) { return [pscustomobject]@{ Added = @($added); Updated = @($updated) } }

  $fileList = New-Object System.Collections.Generic.List[object]
  foreach ($f in @($target.Project.files)) { $fileList.Add($f) }
  foreach ($f in $toAdd) { $fileList.Add($f) }
  $target.Project | Add-Member -NotePropertyName files -NotePropertyValue ($fileList.ToArray()) -Force
  $newJson = $target.Project | ConvertTo-Json -Depth 100 -Compress
  $newB64 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($newJson))
  $newXml = [regex]::Replace($target.Xml, '(?s)(<AFEJSONBlob[^>]*>).*?(</AFEJSONBlob>)', ('$1' + $newB64 + '$2'))

  $zip = [System.IO.Compression.ZipFile]::Open($TargetPath, [System.IO.Compression.ZipArchiveMode]::Update)
  try {
    $old = $zip.GetEntry($target.EntryName)
    if ($null -ne $old) { $old.Delete() }
    $newEntry = $zip.CreateEntry($target.EntryName)
    $writer = [System.IO.StreamWriter]::new($newEntry.Open(), [System.Text.UTF8Encoding]::new($false))
    try { $writer.Write($newXml) } finally { $writer.Dispose() }
  } finally { $zip.Dispose() }

  return [pscustomobject]@{ Added = @($added); Updated = @($updated) }
}

function Get-WorkbookScopedNameSet {
  param([string] $Path)

  $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  $mainNs = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
  $zip = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Read)
  try {
    $entry = $zip.GetEntry('xl/workbook.xml')
    if ($null -eq $entry) { return $set }
    $reader = [System.IO.StreamReader]::new($entry.Open(), [System.Text.Encoding]::UTF8)
    try { $xmlText = $reader.ReadToEnd() } finally { $reader.Dispose() }
    $doc = New-Object System.Xml.XmlDocument
    $doc.LoadXml($xmlText)
    $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
    $ns.AddNamespace('x', $mainNs)
    foreach ($n in @($doc.SelectNodes('//x:definedName', $ns))) {
      if (-not [string]::IsNullOrEmpty($n.GetAttribute('localSheetId'))) { continue }
      $nm = $n.GetAttribute('name')
      if ([string]::IsNullOrEmpty($nm)) { continue }
      $rt = $n.InnerText
      if ([string]::IsNullOrWhiteSpace($rt) -or $rt -match '#REF!') { continue }
      [void] $set.Add($nm)
    }
  } finally { $zip.Dispose() }
  return $set
}

function Remove-RedundantSheetScopedNames {
  param(
    [string] $TargetPath,
    [System.Collections.Generic.HashSet[string]] $AuthoritativeNames = $null
  )

  $result = [pscustomobject]@{ Removed = 0; Kept = 0 }
  $mainNs = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'

  $zip = [System.IO.Compression.ZipFile]::Open($TargetPath, [System.IO.Compression.ZipArchiveMode]::Update)
  try {
    $entry = $zip.GetEntry('xl/workbook.xml')
    if ($null -eq $entry) { return $result }

    $reader = [System.IO.StreamReader]::new($entry.Open(), [System.Text.Encoding]::UTF8)
    try { $xmlText = $reader.ReadToEnd() } finally { $reader.Dispose() }

    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $true
    $doc.LoadXml($xmlText)

    $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
    $ns.AddNamespace('x', $mainNs)

    $definedNamesNode = $doc.SelectSingleNode('//x:definedNames', $ns)
    if ($null -eq $definedNamesNode) { return $result }

    $nameNodes = @($definedNamesNode.SelectNodes('x:definedName', $ns))

    $wbScoped = @{}
    foreach ($n in $nameNodes) {
      if (-not [string]::IsNullOrEmpty($n.GetAttribute('localSheetId'))) { continue }
      $nm = $n.GetAttribute('name')
      if ([string]::IsNullOrEmpty($nm)) { continue }
      if (-not $wbScoped.ContainsKey($nm)) { $wbScoped[$nm] = $n.InnerText }
    }

    $removed = 0; $kept = 0
    foreach ($n in $nameNodes) {
      if ([string]::IsNullOrEmpty($n.GetAttribute('localSheetId'))) { continue }
      $nm = $n.GetAttribute('name')
      if ([string]::IsNullOrEmpty($nm)) { continue }
      if (-not $wbScoped.ContainsKey($nm)) { $kept++; continue }
      $isAuthoritative = ($null -ne $AuthoritativeNames -and $AuthoritativeNames.Contains($nm))
      if (-not $isAuthoritative -and $n.InnerText -ne $wbScoped[$nm]) { $kept++; continue }
      [void] $definedNamesNode.RemoveChild($n)
      $removed++
    }

    $workbookNode = $doc.SelectSingleNode('//x:workbook', $ns)
    $calcPr = $doc.SelectSingleNode('//x:calcPr', $ns)
    $calcChanged = $false
    if ($null -eq $calcPr -and $null -ne $workbookNode) {
      $calcPr = $doc.CreateElement('calcPr', $mainNs)
      [void] $workbookNode.InsertAfter($calcPr, $definedNamesNode)
    }
    if ($null -ne $calcPr -and $calcPr.GetAttribute('fullCalcOnLoad') -ne '1') {
      $calcPr.SetAttribute('fullCalcOnLoad', '1')
      $calcChanged = $true
    }

    if ($removed -gt 0 -or $calcChanged) {
      $old = $zip.GetEntry('xl/workbook.xml')
      if ($null -ne $old) { $old.Delete() }
      $newEntry = $zip.CreateEntry('xl/workbook.xml')
      $writer = [System.IO.StreamWriter]::new($newEntry.Open(), [System.Text.UTF8Encoding]::new($false))
      try { $doc.Save($writer) } finally { $writer.Dispose() }
    }

    $result.Removed = $removed; $result.Kept = $kept
  } finally { $zip.Dispose() }

  return $result
}

function Get-WorkbookScopedNameMap {
  # Return a hashtable {name -> RefersTo innerText} for every workbook-scoped
  # defined name with a valid (non-#REF, non-empty) definition. Used to restore
  # names that Excel breaks to =#REF!#REF! when their target sheet is replaced.
  param([string] $Path)

  $map = @{}
  $mainNs = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
  $zip = [System.IO.Compression.ZipFile]::Open($Path, [System.IO.Compression.ZipArchiveMode]::Read)
  try {
    $entry = $zip.GetEntry('xl/workbook.xml')
    if ($null -eq $entry) { return $map }
    $reader = [System.IO.StreamReader]::new($entry.Open(), [System.Text.Encoding]::UTF8)
    try { $xmlText = $reader.ReadToEnd() } finally { $reader.Dispose() }
    $doc = New-Object System.Xml.XmlDocument
    $doc.LoadXml($xmlText)
    $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
    $ns.AddNamespace('x', $mainNs)
    foreach ($n in @($doc.SelectNodes('//x:definedName', $ns))) {
      if (-not [string]::IsNullOrEmpty($n.GetAttribute('localSheetId'))) { continue }
      $nm = $n.GetAttribute('name')
      if ([string]::IsNullOrEmpty($nm)) { continue }
      $rt = $n.InnerText
      if ([string]::IsNullOrWhiteSpace($rt) -or $rt -match '#REF!' -or $rt -match '\[') { continue }
      if (-not $map.ContainsKey($nm)) { $map[$nm] = $rt }
    }
  } finally { $zip.Dispose() }
  return $map
}

function Repair-BrokenWorkbookNames {
  # Deterministically restore workbook-scoped names that Excel left as
  # =#REF!#REF! after sheet replacement. Operates on the saved workbook XML so
  # nothing downstream can re-break them (the in-COM approach is defeated by
  # Excel relinking a name to its source file the moment a copied sheet that
  # consumes it lands in the workbook).
  param(
    [string] $TargetPath,
    [hashtable] $NameMap
  )

  $result = [pscustomobject]@{ Repaired = 0 }
  if ($null -eq $NameMap -or $NameMap.Count -eq 0) { return $result }
  $mainNs = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'

  $zip = [System.IO.Compression.ZipFile]::Open($TargetPath, [System.IO.Compression.ZipArchiveMode]::Update)
  try {
    $entry = $zip.GetEntry('xl/workbook.xml')
    if ($null -eq $entry) { return $result }
    $reader = [System.IO.StreamReader]::new($entry.Open(), [System.Text.Encoding]::UTF8)
    try { $xmlText = $reader.ReadToEnd() } finally { $reader.Dispose() }

    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $true
    $doc.LoadXml($xmlText)
    $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
    $ns.AddNamespace('x', $mainNs)

    $definedNamesNode = $doc.SelectSingleNode('//x:definedNames', $ns)
    if ($null -eq $definedNamesNode) { return $result }

    $repaired = 0
    foreach ($n in @($definedNamesNode.SelectNodes('x:definedName', $ns))) {
      if (-not [string]::IsNullOrEmpty($n.GetAttribute('localSheetId'))) { continue }  # workbook-scoped only
      $nm = $n.GetAttribute('name')
      if ([string]::IsNullOrEmpty($nm)) { continue }
      if ($n.InnerText -notmatch '#REF!') { continue }
      if (-not $NameMap.ContainsKey($nm)) { continue }
      $n.InnerText = $NameMap[$nm]
      $repaired++
    }

    if ($repaired -gt 0) {
      $old = $zip.GetEntry('xl/workbook.xml')
      if ($null -ne $old) { $old.Delete() }
      $newEntry = $zip.CreateEntry('xl/workbook.xml')
      $writer = [System.IO.StreamWriter]::new($newEntry.Open(), [System.Text.UTF8Encoding]::new($false))
      try { $doc.Save($writer) } finally { $writer.Dispose() }
    }
    $result.Repaired = $repaired
  } finally { $zip.Dispose() }

  return $result
}

function Remove-ExternalLinkArtifacts {
  # Strip every trace of the phantom external-workbook links the one-sheet-at-a-
  # time copy leaves behind. These are all dead 'xlPathMissing' links to calc
  # sheets Scope 3 never imports (e.g. '14.1.1-2 Purchased electricity',
  # '4.3.1.1-2 Methane', the manure/fertiliser calc ranges). They are held ONLY
  # by orphan '[N]'-prefixed defined names (the M1_Table_* helper tables the AFE
  # manure/fertiliser LAMBDA modules consume); no cell formula references them,
  # so removing them is safe. COM cannot do this - BreakLink throws on missing
  # paths and .RefersTo throws on unresolvable [N] names - so it is done in XML.
  #
  # Removes, atomically:
  #   1. every workbook.xml <definedName> whose RefersTo carries a '[N]' book ref
  #   2. the workbook.xml <externalReferences> block
  #   3. the externalLink relationships in xl/_rels/workbook.xml.rels
  #   4. the xl/externalLinks/** parts
  #   5. the [Content_Types].xml overrides for those parts
  param([string] $TargetPath)

  $result = [pscustomobject]@{ NamesRemoved = 0; ReferencesRemoved = 0; PartsRemoved = 0 }
  $mainNs = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
  $reExt  = [regex] '\[\d+\]'

  $zip = [System.IO.Compression.ZipFile]::Open($TargetPath, [System.IO.Compression.ZipArchiveMode]::Update)
  try {
    # --- 1 & 2: workbook.xml -------------------------------------------------
    $wbEntry = $zip.GetEntry('xl/workbook.xml')
    if ($null -eq $wbEntry) { return $result }
    $reader = [System.IO.StreamReader]::new($wbEntry.Open(), [System.Text.Encoding]::UTF8)
    try { $wbText = $reader.ReadToEnd() } finally { $reader.Dispose() }

    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $true
    $doc.LoadXml($wbText)
    $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
    $ns.AddNamespace('x', $mainNs)

    $namesRemoved = 0
    $definedNamesNode = $doc.SelectSingleNode('//x:definedNames', $ns)
    if ($null -ne $definedNamesNode) {
      foreach ($n in @($definedNamesNode.SelectNodes('x:definedName', $ns))) {
        if ($reExt.IsMatch($n.InnerText)) { [void] $definedNamesNode.RemoveChild($n); $namesRemoved++ }
      }
      if (-not $definedNamesNode.HasChildNodes) { [void] $definedNamesNode.ParentNode.RemoveChild($definedNamesNode) }
    }

    $refsRemoved = 0
    $extRefsNode = $doc.SelectSingleNode('//x:externalReferences', $ns)
    if ($null -ne $extRefsNode) {
      $refsRemoved = @($extRefsNode.SelectNodes('x:externalReference', $ns)).Count
      [void] $extRefsNode.ParentNode.RemoveChild($extRefsNode)
    }

    if ($namesRemoved -gt 0 -or $refsRemoved -gt 0) {
      $wbEntry.Delete()
      $newWb = $zip.CreateEntry('xl/workbook.xml')
      $writer = [System.IO.StreamWriter]::new($newWb.Open(), [System.Text.UTF8Encoding]::new($false))
      try { $doc.Save($writer) } finally { $writer.Dispose() }
    }

    # --- 3: xl/_rels/workbook.xml.rels --------------------------------------
    $relEntry = $zip.GetEntry('xl/_rels/workbook.xml.rels')
    if ($null -ne $relEntry) {
      $reader = [System.IO.StreamReader]::new($relEntry.Open(), [System.Text.Encoding]::UTF8)
      try { $relText = $reader.ReadToEnd() } finally { $reader.Dispose() }
      $relDoc = New-Object System.Xml.XmlDocument
      $relDoc.PreserveWhitespace = $true
      $relDoc.LoadXml($relText)
      $relNs = New-Object System.Xml.XmlNamespaceManager($relDoc.NameTable)
      $relNs.AddNamespace('r', 'http://schemas.openxmlformats.org/package/2006/relationships')
      $relChanged = $false
      foreach ($rel in @($relDoc.SelectNodes('//r:Relationship', $relNs))) {
        if ($rel.GetAttribute('Type') -like '*externalLink') {
          [void] $rel.ParentNode.RemoveChild($rel); $relChanged = $true
        }
      }
      if ($relChanged) {
        $relEntry.Delete()
        $newRel = $zip.CreateEntry('xl/_rels/workbook.xml.rels')
        $writer = [System.IO.StreamWriter]::new($newRel.Open(), [System.Text.UTF8Encoding]::new($false))
        try { $relDoc.Save($writer) } finally { $writer.Dispose() }
      }
    }

    # --- 4: delete the externalLink parts -----------------------------------
    $partsRemoved = 0
    foreach ($e in @($zip.Entries | Where-Object { $_.FullName -like 'xl/externalLinks/*' })) {
      $e.Delete(); $partsRemoved++
    }

    # --- 5: [Content_Types].xml overrides -----------------------------------
    $ctEntry = $zip.GetEntry('[Content_Types].xml')
    if ($null -ne $ctEntry) {
      $reader = [System.IO.StreamReader]::new($ctEntry.Open(), [System.Text.Encoding]::UTF8)
      try { $ctText = $reader.ReadToEnd() } finally { $reader.Dispose() }
      $ctDoc = New-Object System.Xml.XmlDocument
      $ctDoc.PreserveWhitespace = $true
      $ctDoc.LoadXml($ctText)
      $ctNs = New-Object System.Xml.XmlNamespaceManager($ctDoc.NameTable)
      $ctNs.AddNamespace('c', 'http://schemas.openxmlformats.org/package/2006/content-types')
      $ctChanged = $false
      foreach ($ov in @($ctDoc.SelectNodes('//c:Override', $ctNs))) {
        if ($ov.GetAttribute('PartName') -like '/xl/externalLinks/*') {
          [void] $ov.ParentNode.RemoveChild($ov); $ctChanged = $true
        }
      }
      if ($ctChanged) {
        $ctEntry.Delete()
        $newCt = $zip.CreateEntry('[Content_Types].xml')
        $writer = [System.IO.StreamWriter]::new($newCt.Open(), [System.Text.UTF8Encoding]::new($false))
        try { $ctDoc.Save($writer) } finally { $writer.Dispose() }
      }
    }

    $result.NamesRemoved      = $namesRemoved
    $result.ReferencesRemoved = $refsRemoved
    $result.PartsRemoved      = $partsRemoved
  } finally { $zip.Dispose() }

  return $result
}

function Invoke-FinalRecalcAndLinkCleanup {
  # Force Excel to do a FULL recalculation the next time the workbook is opened,
  # by setting calcPr/@fullCalcOnLoad="1" in workbook.xml. This is what removes
  # the need to press F9 to clear the stale #REF! results that the XML name
  # repair leaves cached (e.g. 'Input - Electricity'!E16, which depends on the
  # repaired X_Cell_* names).
  #
  # Deliberately does NOT recalculate here via COM: this build runs headless,
  # where the Excel Labs (AFE) add-in is absent, so a headless rebuild would
  # evaluate the module-namespaced calls (e.g. 'SourceData_Swine.<fn>()') to
  # #NAME? and bake that in. Letting the user's Excel - which has the add-in -
  # do the on-open recalc keeps those cells correct while still fixing E16.
  param([string] $TargetPath)

  $result = [pscustomobject]@{ Set = $false }
  $mainNs = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'

  $zip = [System.IO.Compression.ZipFile]::Open($TargetPath, [System.IO.Compression.ZipArchiveMode]::Update)
  try {
    $wbEntry = $zip.GetEntry('xl/workbook.xml')
    if ($null -eq $wbEntry) { return $result }
    $reader = [System.IO.StreamReader]::new($wbEntry.Open(), [System.Text.Encoding]::UTF8)
    try { $wbText = $reader.ReadToEnd() } finally { $reader.Dispose() }

    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $true
    $doc.LoadXml($wbText)
    $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
    $ns.AddNamespace('x', $mainNs)

    $calcPr = $doc.SelectSingleNode('//x:calcPr', $ns)
    if ($null -eq $calcPr) {
      $wbNode = $doc.SelectSingleNode('/x:workbook', $ns)
      $calcPr = $doc.CreateElement('calcPr', $mainNs)
      # calcPr must sit after definedNames (CT_Workbook order); append is safe as
      # Excel repairs ordering, but place after definedNames when present.
      $definedNames = $doc.SelectSingleNode('//x:definedNames', $ns)
      if ($null -ne $definedNames) { [void] $wbNode.InsertAfter($calcPr, $definedNames) }
      else { [void] $wbNode.AppendChild($calcPr) }
    }
    $calcPr.SetAttribute('fullCalcOnLoad', '1')

    $wbEntry.Delete()
    $newWb = $zip.CreateEntry('xl/workbook.xml')
    $writer = [System.IO.StreamWriter]::new($newWb.Open(), [System.Text.UTF8Encoding]::new($false))
    try { $doc.Save($writer) } finally { $writer.Dispose() }
    $result.Set = $true
  } finally { $zip.Dispose() }

  return $result
}

function Convert-StringifiedFormula {
  param([Parameter(Mandatory = $true)] $Workbook)

  $converted = 0
  foreach ($ws in $Workbook.Worksheets) {
    $ur = $null
    try { $ur = $ws.UsedRange } catch { $ur = $null }
    if ($null -eq $ur) { continue }
    $v = $ur.Value2
    $rowBase = [int] $ur.Row
    $colBase = [int] $ur.Column
    if ($v -is [System.Array]) {
      $rows = $v.GetLength(0); $cols = $v.GetLength(1)
      for ($i = 1; $i -le $rows; $i++) {
        for ($j = 1; $j -le $cols; $j++) {
          $cellVal = $v.GetValue($i, $j)
          if ($cellVal -isnot [string] -or -not $cellVal.StartsWith('=')) { continue }
          try {
            $cell = $ws.Cells.Item($rowBase + $i - 1, $colBase + $j - 1)
            if ([bool] $cell.HasFormula) { continue }
            $cell.Formula2 = $cellVal
            $converted++
          } catch { }
        }
      }
    } elseif ($v -is [string] -and $v.StartsWith('=')) {
      try {
        $cell = $ws.Cells.Item($rowBase, $colBase)
        if (-not [bool] $cell.HasFormula) { $cell.Formula2 = $v; $converted++ }
      } catch { }
    }
  }
  return $converted
}

function New-ExcelApp {
  $x = New-Object -ComObject Excel.Application
  $x.Visible = $false
  $x.DisplayAlerts = $false
  $x.ScreenUpdating = $false
  $x.AskToUpdateLinks = $false
  return $x
}

function Get-WorksheetNames {
  param($Workbook)
  $names = New-Object System.Collections.Generic.List[string]
  foreach ($ws in $Workbook.Worksheets) { $names.Add([string] $ws.Name) }
  return $names
}

function Get-RefersToSheetNames {
  # Extract the distinct worksheet names a defined-name RefersTo string depends
  # on (quoted 'Sheet'! or '[book]Sheet'! qualifiers and bare Sheet! tokens).
  # Used to skip upserting source names that point at sheets NOT imported into
  # the Scope 3 workbook - adding those would create phantom external references
  # and clutter the Name Manager with unresolvable names.
  param([string] $RefersTo)
  $sheets = New-Object System.Collections.Generic.List[string]
  if ([string]::IsNullOrEmpty($RefersTo)) { return $sheets }
  foreach ($m in [regex]::Matches($RefersTo, "'((?:\[[^\]]*\])?[^']*)'!")) {
    $s = [regex]::Replace($m.Groups[1].Value, '^\[[^\]]*\]', '')   # strip [book] token
    if (-not [string]::IsNullOrEmpty($s)) { [void] $sheets.Add($s) }
  }
  foreach ($m in [regex]::Matches($RefersTo, "(?:^|[=,\s(+\-*/&:])([A-Za-z_][A-Za-z0-9_.]*)!")) {
    [void] $sheets.Add($m.Groups[1].Value)
  }
  return ($sheets | Select-Object -Unique)
}

# ===========================================================================
# Main
# ===========================================================================

$excelDir = Join-Path $RepoRoot 'Excel'
if (-not (Test-Path -LiteralPath $excelDir)) { throw "Excel directory not found: $excelDir" }

# --- Resolve template -------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($TemplatePath)) {
  $TemplatePath = Resolve-SourceWorkbook -ExcelDir $excelDir -HintName '13_Scope3_Template_WIP'
} else {
  if (-not [System.IO.Path]::IsPathRooted($TemplatePath)) { $TemplatePath = Join-Path $excelDir $TemplatePath }
  if (-not (Test-Path -LiteralPath $TemplatePath)) { throw "Template workbook not found: $TemplatePath" }
}
$TemplatePath = (Resolve-Path -LiteralPath $TemplatePath).Path

# --- Resolve output ---------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  $tplBase = [System.IO.Path]::GetFileNameWithoutExtension($TemplatePath)
  $outBase = $tplBase -replace '_Template', ''
  $OutputPath = Join-Path $excelDir ($outBase + '.xlsx')
} else {
  if (-not [System.IO.Path]::IsPathRooted($OutputPath)) { $OutputPath = Join-Path $excelDir $OutputPath }
}

Write-Host ("Template : {0}" -f $TemplatePath)
Write-Host ("Output   : {0}" -f $OutputPath)
Write-Host ("Mode     : {0}" -f $(if ($DryRun) { 'DRY RUN' } else { 'BUILD' }))
Write-Host ''

# Capture the template's authoritative workbook-scoped names before import.
$templateNameSet = Get-WorkbookScopedNameSet -Path $TemplatePath
$templateNameMap = Get-WorkbookScopedNameMap -Path $TemplatePath

# --- Resolve source workbooks ----------------------------------------------
$sourceHints = @($ImportMap | ForEach-Object { $_.Source } | Select-Object -Unique)
$hintToResolved = @{}
foreach ($h in $sourceHints) { $hintToResolved[$h] = Resolve-SourceWorkbook -ExcelDir $excelDir -HintName $h }
$resolvedSources = @($hintToResolved.Values | Select-Object -Unique)

Write-Host "Source workbooks:"
foreach ($h in ($sourceHints | Sort-Object)) {
  Write-Host ("  {0,-34} -> {1}" -f $h, [System.IO.Path]::GetFileName($hintToResolved[$h]))
}
Write-Host ''

# Pre-flight: template + every source must exist and be closed; the output must
# not be open (a build overwrites it). Fails fast with a clear list otherwise.
$writePreflight = if ($DryRun) { @() } else { @($OutputPath) }
Assert-FilesAccessible -RequiredReadPaths (@($TemplatePath) + $resolvedSources) -WritePaths $writePreflight

if (-not $DryRun) {
  Copy-Item -LiteralPath $TemplatePath -Destination $OutputPath -Force
}
if (Test-Path -LiteralPath $OutputPath) { $OutputPath = (Resolve-Path -LiteralPath $OutputPath).Path }

$excel = $null
$openSources = @{}

try {
  $excel = New-ExcelApp

  # Open sources read-only + cache their sheet-name sets.
  $sourceSheetSets = @{}
  foreach ($rp in $resolvedSources) {
    if ($openSources.ContainsKey($rp)) { continue }
    $wb = $excel.Workbooks.Open($rp, 0, $true)
    $openSources[$rp] = $wb
    $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($n in (Get-WorksheetNames -Workbook $wb)) { [void] $set.Add($n) }
    $sourceSheetSets[$rp] = $set
  }

  # Validate every import entry resolves to a real source sheet.
  $plan = New-Object System.Collections.Generic.List[object]
  foreach ($e in $ImportMap) {
    $rp = $hintToResolved[$e.Source]
    if (-not $sourceSheetSets[$rp].Contains($e.Sheet)) {
      throw ("Source '{0}' ({1}) does not contain sheet '{2}'." -f $e.Source, [System.IO.Path]::GetFileName($rp), $e.Sheet)
    }
    $plan.Add([pscustomobject]@{ Category = $e.Category; Sheet = $e.Sheet; ProviderPath = $rp })
  }

  # Open target (read-only for a dry run, since nothing was copied).
  $basisPath = if ($DryRun) { $TemplatePath } else { $OutputPath }
  $target = $excel.Workbooks.Open($basisPath, 0, [bool] $DryRun)
  $targetSheetNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($n in (Get-WorksheetNames -Workbook $target)) { [void] $targetSheetNames.Add($n) }

  # Which imports replace an existing placeholder vs. add a new sheet.
  $replaceNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($p in $plan) { if ($targetSheetNames.Contains($p.Sheet)) { [void] $replaceNames.Add($p.Sheet) } }

  Write-Host "Import plan:"
  foreach ($p in $plan) {
    $mode = if ($replaceNames.Contains($p.Sheet)) { 'replace' } else { 'add    ' }
    Write-Host ("  [{0,-11}] {1}  {2}  <-  {3}" -f $p.Category, $mode, $p.Sheet, [System.IO.Path]::GetFileName($p.ProviderPath))
  }
  Write-Host ''

  if ($DryRun) {
    Write-Host "Excel Labs modules that would be merged:"
    $preview = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($rp in $resolvedSources) { foreach ($mp in (Get-AfeModulePaths -WorkbookPath $rp)) { [void] $preview.Add($mp) } }
    foreach ($mp in ($preview | Sort-Object)) { Write-Host ("  {0}" -f $mp) }
    $target.Close($false)
    foreach ($wb in $openSources.Values) { $wb.Close($false) }
    $excel.Quit()
    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel) | Out-Null
    $excel = $null
    Write-Host ''
    Write-Host "DRY RUN complete - no workbook written."
    return
  }

  # --- Capture direct refs from KEPT sheets into REPLACED sheets --------------
  # Deleting a placeholder turns '<replaced>'!cell refs on other sheets into
  # #REF!. Capture them verbatim now; restore after the replacement exists again.
  # Structured table references (TableName[col]) to a table hosted on a replaced
  # sheet break the same way but carry no '!' qualifier, so also capture any
  # formula that references a table living on a sheet we are about to replace.
  $capturedRefs = New-Object System.Collections.Generic.List[object]
  if ($replaceNames.Count -gt 0) {
    $escaped = ($replaceNames | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $reCapture = [regex] ("'(?:" + $escaped + ")'!")

    $replacedTableNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ws in $target.Worksheets) {
      if (-not $replaceNames.Contains([string] $ws.Name)) { continue }
      try { foreach ($lo in $ws.ListObjects) { [void] $replacedTableNames.Add([string] $lo.Name) } } catch { }
    }
    $reTable = $null
    if ($replacedTableNames.Count -gt 0) {
      $escTables = ($replacedTableNames | ForEach-Object { [regex]::Escape($_) }) -join '|'
      $reTable = [regex] ("(?:" + $escTables + ")\[")
    }

    foreach ($ws in $target.Worksheets) {
      if ($replaceNames.Contains([string] $ws.Name)) { continue }  # replaced sheets arrive fresh
      $ur = $null
      try { $ur = $ws.UsedRange } catch { $ur = $null }
      if ($null -eq $ur) { continue }
      $f = $ur.Formula2
      $rowBase = [int] $ur.Row
      $colBase = [int] $ur.Column
      if ($f -is [System.Array]) {
        $rows = $f.GetLength(0); $cols = $f.GetLength(1)
        for ($i = 1; $i -le $rows; $i++) {
          for ($j = 1; $j -le $cols; $j++) {
            $v = $f.GetValue($i, $j)
            if ($v -isnot [string]) { continue }
            $hit = ($v.Contains('!') -and $reCapture.IsMatch($v)) -or ($null -ne $reTable -and $reTable.IsMatch($v))
            if (-not $hit) { continue }
            $capturedRefs.Add([pscustomobject]@{ Sheet = [string] $ws.Name; Row = ($rowBase + $i - 1); Col = ($colBase + $j - 1); Formula = $v })
          }
        }
      } elseif ($f -is [string]) {
        $hit = ($f.Contains('!') -and $reCapture.IsMatch($f)) -or ($null -ne $reTable -and $reTable.IsMatch($f))
        if ($hit) {
          $capturedRefs.Add([pscustomobject]@{ Sheet = [string] $ws.Name; Row = $rowBase; Col = $colBase; Formula = $f })
        }
      }
    }
    Write-Host ("Captured {0} direct reference(s) from kept sheets into replaced sheets." -f $capturedRefs.Count)
  }

  # --- Capture template workbook-scoped names that point into replaced sheets -
  # Deleting a placeholder breaks these to =#REF!#REF!. The source workbooks
  # frequently do NOT redefine them (e.g. VEERG_8_*_Result, X_Cell_Site_State),
  # so capture the template's own valid definitions now and restore them once
  # the target sheet has been re-imported under the same name.
  $capturedNames = @{}
  if ($replaceNames.Count -gt 0) {
    foreach ($tn in $target.Names) {
      $nm = $null; $rt = $null; $ln = $null
      try { $nm = [string] $tn.Name; $rt = [string] $tn.RefersTo; $ln = [string] $tn.NameLocal } catch { continue }
      if ([string]::IsNullOrWhiteSpace($nm)) { continue }
      if ($ln -like '*!*') { continue }                        # workbook-scoped only
      if ($rt -match '#REF' -or $rt -match '\[') { continue }   # already broken / external
      $sheets = @(Get-RefersToSheetNames -RefersTo $rt)
      if ($sheets.Count -eq 0) { continue }                    # constants / LAMBDA: cannot break
      $touchesReplaced = $false
      foreach ($s in $sheets) { if ($replaceNames.Contains($s)) { $touchesReplaced = $true; break } }
      if ($touchesReplaced) { $capturedNames[$nm] = $rt }
    }
    Write-Host ("Captured {0} template name definition(s) that point into replaced sheets." -f $capturedNames.Count)
  }

  # --- Import (replace placeholders in place; add new sheets at end) ----------
  $imported = New-Object System.Collections.Generic.List[string]
  foreach ($p in $plan) {
    $srcWb = $openSources[$p.ProviderPath]
    $srcWs = $srcWb.Worksheets.Item($p.Sheet)

    if ($replaceNames.Contains($p.Sheet)) {
      $existingWs = $target.Worksheets.Item($p.Sheet)
      $idx = [int] $existingWs.Index
      $existingWs.Delete()
      if ($idx -le 1) {
        [void] $srcWs.Copy($target.Worksheets.Item(1))                                   # Before first
      } else {
        [void] $srcWs.Copy([System.Reflection.Missing]::Value, $target.Worksheets.Item($idx - 1))  # After idx-1
      }
    } else {
      $after = $target.Worksheets.Item($target.Worksheets.Count)
      [void] $srcWs.Copy([System.Reflection.Missing]::Value, $after)
    }
    [void] $targetSheetNames.Add($p.Sheet)
    $imported.Add($p.Sheet)
  }

  # --- Restore captured references (targets now exist again) ------------------
  $refsRestored = 0
  foreach ($c in $capturedRefs) {
    try { $target.Worksheets.Item($c.Sheet).Cells.Item($c.Row, $c.Col).Formula2 = $c.Formula; $refsRestored++ } catch { }
  }
  if ($refsRestored -gt 0) { Write-Host ("Restored {0} captured reference(s)." -f $refsRestored) }

  # --- Single enumeration of target.Names, reused below by both the restore
  #     pass and the upsert pass. Previously each did its own full COM
  #     enumeration, and the restore pass additionally re-scanned the whole
  #     collection PER CAPTURED NAME (O(capturedNames x totalNames) COM
  #     property reads on a workbook that can carry thousands of names). Every
  #     entry seen for a given Name string is kept (not just the first), so
  #     the restore pass's workbook-scoped-vs-sheet-scoped filtering still has
  #     every candidate to check, exactly as the original per-name re-scan did.
  $targetNamesByString = @{}
  foreach ($tn in $target.Names) {
    $nm2 = $null
    try { $nm2 = [string] $tn.Name } catch { continue }
    if ([string]::IsNullOrWhiteSpace($nm2)) { continue }
    if (-not $targetNamesByString.ContainsKey($nm2)) { $targetNamesByString[$nm2] = New-Object System.Collections.Generic.List[object] }
    $targetNamesByString[$nm2].Add($tn)
  }

  # --- Restore template names that broke when placeholders were deleted -------
  # Only repair a name that is currently broken (#REF! / empty) and whose
  # captured definition now targets sheets that are all present locally.
  $namesRestored = 0
  foreach ($entry in $capturedNames.GetEnumerator()) {
    $nm = $entry.Key; $rt = $entry.Value
    $sheets = @(Get-RefersToSheetNames -RefersTo $rt)
    $allLocal = $true
    foreach ($s in $sheets) { if (-not $targetSheetNames.Contains($s)) { $allLocal = $false; break } }
    if (-not $allLocal) { continue }
    # Locate the WORKBOOK-SCOPED entry specifically. An imported sheet may carry
    # a sheet-scoped duplicate of the same name; Names.Item() can return that
    # (valid) duplicate and mask the broken workbook-scoped name, so match by
    # NameLocal having no '!' qualifier instead.
    $cur = $null
    if ($targetNamesByString.ContainsKey($nm)) {
      foreach ($tn in $targetNamesByString[$nm]) {
        $ln = $null
        try { $ln = [string] $tn.NameLocal } catch { continue }
        if ($ln -like '*!*') { continue }   # skip sheet-scoped duplicate
        $cur = $tn; break
      }
    }
    $curRt = ''
    if ($null -ne $cur) { try { $curRt = [string] $cur.RefersTo } catch { } }
    # Restore when the current definition is broken (#REF!), empty, or was
    # re-pointed to an external [source] link. Copying a source sheet that
    # consumes one of these names makes Excel relink the workbook-scoped name
    # to the source file; the template's own local definition is authoritative.
    if ($null -eq $cur -or $curRt -match '#REF' -or $curRt -match '\[' -or [string]::IsNullOrWhiteSpace($curRt)) {
      try {
        if ($null -ne $cur) {
          $cur.RefersTo = $rt
        } else {
          $added = $target.Names.Add($nm, $rt)
          if (-not $targetNamesByString.ContainsKey($nm)) { $targetNamesByString[$nm] = New-Object System.Collections.Generic.List[object] }
          $targetNamesByString[$nm].Add($added)
        }
        $namesRestored++
      } catch { }
    }
  }
  if ($namesRestored -gt 0) { Write-Host ("Restored {0} broken template name definition(s)." -f $namesRestored) }

  # --- Upsert workbook-scoped defined names from the source workbooks --------
  # $targetNameSet mirrors the original "last entry wins per Name string" of a
  # fresh foreach ($tn in $target.Names) enumeration, sourced from the same
  # pass above (now including anything the restore step just added).
  $namesAdded = 0; $namesFixed = 0; $namesFailed = 0; $namesSkippedNonLocal = 0
  $targetNameSet = @{}
  foreach ($nm2 in $targetNamesByString.Keys) {
    $list = $targetNamesByString[$nm2]
    $targetNameSet[$nm2] = $list[$list.Count - 1]
  }
  foreach ($rp in $resolvedSources) {
    $srcWb = $openSources[$rp]
    foreach ($sn in $srcWb.Names) {
      $nm = $null; $refers = $null; $localName = $null
      try { $nm = [string] $sn.Name; $refers = [string] $sn.RefersTo; $localName = [string] $sn.NameLocal } catch { continue }
      if ([string]::IsNullOrWhiteSpace($nm)) { continue }
      if ($localName -like '*!*') { continue }          # sheet-scoped: travels with the sheet
      if ($refers -match '^=?#REF') { continue }

      if ($targetNameSet.ContainsKey($nm)) {
        $existing = $targetNameSet[$nm]
        $curRefers = ''
        try { $curRefers = [string] $existing.RefersTo } catch { }
        if ($curRefers -match '\[' -and $refers -notmatch '\[') {
          try { $existing.RefersTo = $refers; $namesFixed++ } catch { }
        }
        continue
      }

      # Skip names whose definition references a sheet that was NOT imported:
      # adding them would externalise to the source workbook (phantom links) and
      # clutter the Name Manager with unresolvable entries.
      $refSheets = Get-RefersToSheetNames -RefersTo $refers
      $allLocal = $true
      foreach ($rs in $refSheets) { if (-not $targetSheetNames.Contains($rs)) { $allLocal = $false; break } }
      if (-not $allLocal) { $namesSkippedNonLocal++; continue }

      try {
        $added = $target.Names.Add($nm, $refers)
        $targetNameSet[$nm] = $added
        $namesAdded++
      } catch { $namesFailed++ }
    }
  }

  # --- Localise externalised references (strip workbook prefix) --------------
  $stringifiedFixed = Convert-StringifiedFormula -Workbook $target
  if ($stringifiedFixed -gt 0) { Write-Host ("Converted {0} stringified formula cell(s) to real formulas." -f $stringifiedFixed) }

  $script:__localSheets = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($ws in $target.Worksheets) { [void] $script:__localSheets.Add([string] $ws.Name) }
  $script:__localTables = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($ws in $target.Worksheets) {
    try { foreach ($lo in $ws.ListObjects) { [void] $script:__localTables.Add([string] $lo.Name) } } catch { }
  }

  $reExtRef = [regex] "'(?<pre>[^']*)\[(?<file>[^\[\]]+)\](?<sheet>[^']*)'"
  $eval = [System.Text.RegularExpressions.MatchEvaluator] {
    param($m)
    $sheet = $m.Groups['sheet'].Value
    if ($script:__localSheets.Contains($sheet)) { return "'" + $sheet + "'" }
    return $m.Value
  }
  $reTableRef = [regex] "'[^']*\.xls[a-z]*[^']*'!(?<name>[A-Za-z_\\][A-Za-z0-9_.\\]*)(?=\[)"
  $evalTable = [System.Text.RegularExpressions.MatchEvaluator] {
    param($m)
    $name = $m.Groups['name'].Value
    if ($script:__localTables.Contains($name)) { return $name }
    return $m.Value
  }

  $refsLocalised = 0
  foreach ($ws in $target.Worksheets) {
    $ur = $ws.UsedRange
    $f = $ur.Formula2
    $rowBase = [int] $ur.Row
    $colBase = [int] $ur.Column
    if ($f -is [System.Array]) {
      $rows = $f.GetLength(0); $cols = $f.GetLength(1)
      for ($i = 1; $i -le $rows; $i++) {
        for ($j = 1; $j -le $cols; $j++) {
          $v = $f.GetValue($i, $j)
          if ($v -isnot [string] -or -not $v.Contains('[')) { continue }
          $new = $reExtRef.Replace($v, $eval)
          $new = $reTableRef.Replace($new, $evalTable)
          if ($new -ne $v) {
            try { $ws.Cells.Item($rowBase + $i - 1, $colBase + $j - 1).Formula2 = $new; $refsLocalised++ } catch { }
          }
        }
      }
    } elseif ($f -is [string] -and $f.Contains('[')) {
      $new = $reExtRef.Replace($f, $eval)
      $new = $reTableRef.Replace($new, $evalTable)
      if ($new -ne $f) {
        try { $ws.Cells.Item($rowBase, $colBase).Formula2 = $new; $refsLocalised++ } catch { }
      }
    }
  }
  if ($refsLocalised -gt 0) { Write-Host ("Localised {0} externalised reference cell(s)." -f $refsLocalised) }

  # --- Localise externalised defined-name RefersTo ----------------------------
  $namesLocalised = 0; $namesStillExternal = 0
  foreach ($n in $target.Names) {
    $rt = $null
    try { $rt = [string] $n.RefersTo } catch { continue }
    if ([string]::IsNullOrEmpty($rt) -or -not $rt.Contains('[')) { continue }
    $newRt = $reExtRef.Replace($rt, $eval)
    if ($newRt -ne $rt) {
      try { $n.RefersTo = $newRt } catch { }
      $rt2 = $newRt
      try { $rt2 = [string] $n.RefersTo } catch { }
      if ($rt2.Contains('[')) { $namesStillExternal++ } else { $namesLocalised++ }
    } else {
      $namesStillExternal++
    }
  }
  if ($namesLocalised -gt 0) { Write-Host ("Localised {0} externalised defined-name(s)." -f $namesLocalised) }
  if ($namesStillExternal -gt 0) { Write-Host ("Defined names still external (target sheet absent): {0}" -f $namesStillExternal) }

  # --- Break leftover external links (self-contained workbook) ---------------
  $linksBroken = 0
  try {
    $preLinks = $target.LinkSources(1)  # xlExcelLinks
    if ($null -ne $preLinks) {
      foreach ($l in @($preLinks)) {
        try { $target.BreakLink($l, 1); $linksBroken++ }
        catch { Write-Warning ("Could not break external link: {0} ({1})" -f $l, $_.Exception.Message) }
      }
    }
  } catch { }
  if ($linksBroken -gt 0) { Write-Host ("Broke {0} leftover external link source(s)." -f $linksBroken) }

  $externalLinks = @()
  try {
    $links = $target.LinkSources(1)
    if ($null -ne $links) { $externalLinks = @($links) }
  } catch { }

  # --- Regenerate the column-A navigation menu on every sheet ----------------
  # Seed categories from the tab-naming heuristic (covers template sheets not in
  # the import map, e.g. '15 Scope 3' and 'Calcs - manure sent off-site'), then
  # overlay the authoritative import-map categories. Home/Overview/Results and
  # any Input* sheet are grouped by name inside Set-NavMenu.
  $menuSheetsUpdated = 0
  if (-not $DryRun) {
    $menuCategory = Get-InferredCategoryMap -Workbook $target
    foreach ($e in $ImportMap) { $menuCategory[[string] $e.Sheet] = [string] $e.Category }
    try {
      $menuSheetsUpdated = Set-NavMenu -Target $target -CategoryMap $menuCategory -Labels @{}
      if ($menuSheetsUpdated -gt 0) { Write-Host ("Regenerated navigation menu on {0} sheet(s)." -f $menuSheetsUpdated) }
    } catch {
      Write-Warning ("Navigation menu generation failed: {0}" -f $_.Exception.Message)
    }
  }

  # --- Save & close -----------------------------------------------------------
  $target.Save()
  $target.Close($false)
  foreach ($wb in $openSources.Values) { $wb.Close($false) }
  $excel.Quit()
  [System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel) | Out-Null
  $excel = $null

  # --- Prune redundant sheet-scoped shadow names (post-save, via XML) ---------
  $dedup = Remove-RedundantSheetScopedNames -TargetPath $OutputPath -AuthoritativeNames $templateNameSet
  $namesDeduped = [int] $dedup.Removed
  if ($namesDeduped -gt 0) {
    Write-Host ("Removed {0} redundant sheet-scoped defined name(s) (kept {1})." -f $namesDeduped, $dedup.Kept)
  }

  # --- Merge Excel Labs modules from the source workbooks --------------------
  $requiredModulePaths = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($rp in $resolvedSources) { foreach ($mp in (Get-AfeModulePaths -WorkbookPath $rp)) { [void] $requiredModulePaths.Add($mp) } }
  $mergedModules = Merge-AfeModules -TargetPath $OutputPath -RequiredModulePaths @($requiredModulePaths) -SourceWorkbookPaths $resolvedSources

  # --- Re-publish AFE module functions to the Name Manager -------------------
  $republishResult = Invoke-AfeNamedFunctionRepublish -WorkbookPath $OutputPath
  if (@($republishResult.Republished).Count -gt 0) {
    Write-Host ("Re-published {0} named function(s) to the Name Manager." -f @($republishResult.Republished).Count)
  }
  foreach ($rf in @($republishResult.Failed)) { Write-Warning ("Named-function re-publish failed: {0}" -f $rf) }

  # --- Deterministically restore workbook-scoped names broken to #REF! --------
  # Final XML pass: any workbook-scoped name Excel left as =#REF!#REF! (because
  # its target sheet was replaced and a copied sheet relinked the name) is reset
  # to the template's authoritative definition. Runs last so nothing re-breaks.
  $nameRepair = Repair-BrokenWorkbookNames -TargetPath $OutputPath -NameMap $templateNameMap
  $namesRepairedXml = [int] $nameRepair.Repaired
  if ($namesRepairedXml -gt 0) {
    Write-Host ("Repaired {0} broken workbook-scoped name(s) via XML." -f $namesRepairedXml)
  }

  # --- Strip phantom external-workbook links (dead xlPathMissing links) -------
  # Removes the orphan '[N]'-prefixed defined names and every externalLink part
  # they keep alive, so the workbook opens without the "contains links to other
  # data sources" prompt. Runs in XML because COM cannot break missing-path links.
  $extStrip = Remove-ExternalLinkArtifacts -TargetPath $OutputPath
  $extNamesRemoved = [int] $extStrip.NamesRemoved
  $extPartsRemoved = [int] $extStrip.PartsRemoved
  if ($extPartsRemoved -gt 0 -or $extNamesRemoved -gt 0) {
    Write-Host ("Stripped {0} external-link part(s) and {1} orphan '[N]' name(s)." -f $extPartsRemoved, $extNamesRemoved)
  }

  # --- Force recalc-on-open so the user's Excel refreshes cached values -------
  # Sets fullCalcOnLoad so the workbook recalculates when opened (fixes the
  # stale #REF! that otherwise needs a manual F9, e.g. 'Input - Electricity'!E16)
  # without a headless rebuild that would mis-evaluate add-in module functions.
  $finalPass = Invoke-FinalRecalcAndLinkCleanup -TargetPath $OutputPath
  $externalLinks = @()   # all dead external links were stripped in XML above
  if ($finalPass.Set) { Write-Host "Set fullCalcOnLoad (workbook recalculates on open)." }

  # Normalise the view zoom of every sheet to 100%.
  $zoomChanged = Set-WorkbookZoom -Path $OutputPath -Zoom 100
  if ($zoomChanged -gt 0) { Write-Host ("Set zoom to 100% on {0} sheet(s)." -f $zoomChanged) }

  # --- Summary ----------------------------------------------------------------
  Write-Host ''
  Write-Host "===================== Summary ====================="
  Write-Host ("Sheets imported        : {0}" -f $imported.Count)
  Write-Host ("  replaced placeholders: {0}" -f $replaceNames.Count)
  Write-Host ("  added new            : {0}" -f ($imported.Count - $replaceNames.Count))
  Write-Host ("Refs captured/restored : {0} / {1}" -f $capturedRefs.Count, $refsRestored)
  Write-Host ("Names repaired (broken): {0}" -f $namesRestored)
  Write-Host ("Names repaired via XML : {0}" -f $namesRepairedXml)
  Write-Host ("Defined names added    : {0}" -f $namesAdded)
  Write-Host ("Defined names re-linked: {0}" -f $namesFixed)
  Write-Host ("Defined names skipped  : {0}" -f $namesFailed)
  Write-Host ("Names skipped non-local: {0}" -f $namesSkippedNonLocal)
  Write-Host ("Sheet-scoped dupes rm  : {0}" -f $namesDeduped)
  Write-Host ("Excel Labs modules add : {0}" -f @($mergedModules.Added).Count)
  Write-Host ("Excel Labs modules upd : {0}" -f @($mergedModules.Updated).Count)
  foreach ($um in @($mergedModules.Updated)) { Write-Host ("  updated: {0}" -f $um) }
  Write-Host ("Named funcs re-published: {0}" -f @($republishResult.Republished).Count)
  Write-Host ("Named funcs republish fail: {0}" -f @($republishResult.Failed).Count)
  Write-Host ("Refs localised (strip) : {0}" -f $refsLocalised)
  Write-Host ("Names localised (strip): {0}" -f $namesLocalised)
  Write-Host ("Names still external   : {0}" -f $namesStillExternal)
  Write-Host ("External links broken  : {0}" -f $linksBroken)
  Write-Host ("Ext-link parts stripped : {0}" -f $extPartsRemoved)
  Write-Host ("Orphan [N] names removed: {0}" -f $extNamesRemoved)
  if (@($externalLinks).Count -gt 0) {
    Write-Warning ("Workbook still has {0} external link source(s); some cross-sheet references may not have resolved locally:" -f @($externalLinks).Count)
    foreach ($l in $externalLinks) { Write-Warning ("  {0}" -f $l) }
  }
  Write-Host ("Output                 : {0}" -f $OutputPath)
  Write-Host "==================================================="
}
finally {
  if ($null -ne $excel) {
    try { $excel.Quit() } catch { }
    try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel) | Out-Null } catch { }
  }
}
