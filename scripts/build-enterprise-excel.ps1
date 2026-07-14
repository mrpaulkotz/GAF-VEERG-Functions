param(
  [string] $RepoRoot = (Split-Path $PSScriptRoot -Parent),
  [string] $ConfigPath,
  [string] $EnterpriseId,
  [string] $OutputPath,
  [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression | Out-Null
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

# ---------------------------------------------------------------------------
# Configuration loading
# ---------------------------------------------------------------------------

function Resolve-EnterpriseConfigPath {
  param([string] $RepoRoot, [string] $ConfigPath, [string] $EnterpriseId)

  if (-not [string]::IsNullOrWhiteSpace($ConfigPath)) {
    if (-not (Test-Path -LiteralPath $ConfigPath)) { throw "Config not found: $ConfigPath" }
    return (Resolve-Path -LiteralPath $ConfigPath).Path
  }
  if (-not [string]::IsNullOrWhiteSpace($EnterpriseId)) {
    $p = Join-Path $RepoRoot ("Enterprises\Enterprise_{0}.json" -f $EnterpriseId)
    if (-not (Test-Path -LiteralPath $p)) { throw "Config not found for enterprise '$EnterpriseId': $p" }
    return (Resolve-Path -LiteralPath $p).Path
  }
  throw "Provide -ConfigPath or -EnterpriseId."
}

# ---------------------------------------------------------------------------
# Workbook version resolution (registry names drift: _v02 -> _v03 etc.)
# ---------------------------------------------------------------------------

function Resolve-SourceWorkbook {
  param([string] $ExcelDir, [string] $HintName)

  # Exact match first (hint includes a real filename + extension) - backward compatible.
  $exact = Join-Path $ExcelDir $HintName
  if (Test-Path -LiteralPath $exact) { return (Resolve-Path -LiteralPath $exact).Path }

  # Otherwise treat the hint as a version-agnostic stem/prefix. Drop any extension
  # and a trailing _v<NN>, then match workbooks whose base name is that stem
  # optionally followed by more segments (e.g. "_WIP") and ending in a _v<NN>
  # version suffix. This lets the registry name just the stable module prefix
  # (e.g. "4_2_ManureManagement_BeefPasture") and always resolve to the latest
  # matching versioned workbook on disk. Legacy fully-versioned hints
  # ("4_2_..._WIP_v08.xlsx") still resolve via the stem-equality fallback.
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

# ---------------------------------------------------------------------------
# Excel Labs (AFE) blob helpers (mirrors sync-xlf-to-excel-labs.ps1)
# ---------------------------------------------------------------------------

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

function Merge-AfeModules {
  param(
    [string] $TargetPath,
    [string[]] $RequiredModulePaths,
    [string[]] $SourceWorkbookPaths
  )

  $target = Read-AfeProject -WorkbookPath $TargetPath
  if ($null -eq $target) {
    Write-Warning "Target workbook has no Excel Labs (AFE) project; skipping module merge."
    return @()
  }

  $existing = @{}
  foreach ($f in @($target.Project.files)) { $existing[$f.path] = $true }

  # Build a lookup of module path -> file object from all source workbooks.
  $available = @{}
  foreach ($src in ($SourceWorkbookPaths | Select-Object -Unique)) {
    $proj = Read-AfeProject -WorkbookPath $src
    if ($null -eq $proj) { continue }
    foreach ($f in @($proj.Project.files)) {
      if (-not $available.ContainsKey($f.path)) { $available[$f.path] = $f }
    }
  }

  $added = New-Object System.Collections.Generic.List[string]
  $missing = New-Object System.Collections.Generic.List[string]
  $toAdd = New-Object System.Collections.Generic.List[object]

  foreach ($mp in ($RequiredModulePaths | Select-Object -Unique)) {
    if ($existing.ContainsKey($mp)) { continue }
    if ($available.ContainsKey($mp)) {
      $toAdd.Add($available[$mp])
      $added.Add($mp)
    } else {
      $missing.Add($mp)
    }
  }

  foreach ($m in $missing) { Write-Warning "Excel Labs module not found in any source workbook: $m" }

  if ($toAdd.Count -eq 0) { return @($added) }
  if ($DryRun) { return @($added) }

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

  return @($added)
}

function Get-WorkbookScopedNameSet {
  # Returns a case-insensitive set of the workbook-scoped defined names (no
  # localSheetId) declared in a workbook's xl/workbook.xml. Used to capture the
  # enterprise template's authoritative names before module sheets are imported.
  # Names whose definition is broken (#REF!) or empty are EXCLUDED: a template
  # placeholder that points nowhere is not canonical, so it must not be treated
  # as authoritative (otherwise the prune would delete the valid sheet-scoped
  # copies that modules bring in, e.g. X_Cell_PastureBeef_* on the input sheets).
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
      if ([string]::IsNullOrWhiteSpace($rt) -or $rt -match '#REF!') { continue }  # broken placeholder: not authoritative
      [void] $set.Add($nm)
    }
  } finally { $zip.Dispose() }
  return $set
}

function Remove-RedundantSheetScopedNames {
  # Copying sheets one-at-a-time makes Excel duplicate every workbook-scoped name
  # a sheet references as a SHEET-SCOPED copy: Excel Labs (AFE) LAMBDA functions
  # ('Module.Func'), X_Cell_*/X_Table_* input ranges, etc. The enterprise book
  # accumulates thousands of these ('Sheet'!Name) duplicates, which collide with
  # the single workbook-scoped original and surface as name conflicts in the
  # Excel Labs / Advanced Formula Environment.
  #
  # Deleting them one-by-one via COM is pathologically slow (each Name.Delete()
  # re-resolves the whole dependency graph, and thousands of deletes peg every
  # core recalculating for tens of minutes). Instead prune them directly from
  # xl/workbook.xml in the saved .xlsx zip: for each <definedName localSheetId>
  # whose name also exists workbook-scoped (no localSheetId), drop the sheet-
  # scoped node so unqualified formulas fall through to the single workbook-
  # scoped name. A sheet-scoped name is removed when EITHER:
  #   (a) its definition is IDENTICAL to the workbook-scoped one (a pure copy), OR
  #   (b) the name is AUTHORITATIVE (defined workbook-scoped in the enterprise
  #       template) - the template's definition wins even if the sheet-scoped
  #       copy points somewhere else, because importing a source sheet drags in a
  #       stale shadow (e.g. X_Cell_Site_StartDate -> 'Input - Site'!E12 shadowing
  #       the template's 'Input - Enterprise'!E12). Sheet-scoped names with no
  #       workbook counterpart (Print_Area, per-sheet tables like M1_Table_*, TOC
  #       bookmarks) and non-template names whose definition genuinely differs
  #       (e.g. a valid sheet-scoped copy shadowing a #REF! workbook name) are
  #       left untouched.
  #
  # After pruning, cells that referenced a removed shadow still hold the CACHED
  # error value Excel computed while the shadow was in force; Excel loads cached
  # values without recalculating, so those cells show #VALUE!/#REF! until the
  # formula is re-entered. To fix this we force a full recalc on next open by
  # setting <calcPr fullCalcOnLoad="1">.
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

    # Index workbook-scoped names (no localSheetId) -> definition text.
    $wbScoped = @{}
    foreach ($n in $nameNodes) {
      if (-not [string]::IsNullOrEmpty($n.GetAttribute('localSheetId'))) { continue }
      $nm = $n.GetAttribute('name')
      if ([string]::IsNullOrEmpty($nm)) { continue }
      if (-not $wbScoped.ContainsKey($nm)) { $wbScoped[$nm] = $n.InnerText }
    }

    $removed = 0; $kept = 0
    foreach ($n in $nameNodes) {
      if ([string]::IsNullOrEmpty($n.GetAttribute('localSheetId'))) { continue }  # wb-scoped: keep
      $nm = $n.GetAttribute('name')
      if ([string]::IsNullOrEmpty($nm)) { continue }
      if (-not $wbScoped.ContainsKey($nm)) { $kept++; continue }        # no wb counterpart -> keep
      $isAuthoritative = ($null -ne $AuthoritativeNames -and $AuthoritativeNames.Contains($nm))
      if (-not $isAuthoritative -and $n.InnerText -ne $wbScoped[$nm]) { $kept++; continue }  # non-template & differs -> keep
      [void] $definedNamesNode.RemoveChild($n)
      $removed++
    }

    # Force a full recalculation on next open so cells that referenced a removed
    # shadow drop their stale cached error values. Set <calcPr fullCalcOnLoad="1">
    # (creating the element after definedNames if absent); Excel then recomputes
    # every formula on open, replacing the cached #VALUE!/#REF! results.
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

# ---------------------------------------------------------------------------
# Excel COM helpers
# ---------------------------------------------------------------------------

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

# ---------------------------------------------------------------------------
# Navigation menu generation (column A of every sheet)
# ---------------------------------------------------------------------------
# Rebuilds the left-hand navigation menu on every worksheet from the final
# sheet set, so it always matches the assembled enterprise. Layout mirrors the
# source workbooks:
#   A1              logo (in-cell image, style 'Input page heading') - preserved
#   A3..            untitled group (Home, Results) - no title
#   (blank) INPUTS  title + one link per input sheet
#   (blank) CALC..  title + one link per equation sheet
#   (blank) APPEND. title + one link per appendix sheet
# Each link is =HYPERLINK("#'Sheet'!A1","Label"). The link to the sheet the menu
# is drawn on uses that group's 'selected' style; all others use the default.
function Set-EnterpriseNavMenu {
  param(
    $Target,        # target workbook COM object
    [hashtable] $CategoryMap,  # sheet name -> category (input|calculation|constants|common|custom)
    [hashtable] $Labels        # sheet name -> friendly menu label (override; else derived)
  )

  $titleStyle   = 'Menu section title'
  $defaultStyle = 'Menu link default'
  $logoStyle    = 'Input page heading'
  $firstMenuRow = 3      # A1 = logo, A2 = gap
  $clearToRow   = 160    # column A is a pure nav gutter; safe to blank below the logo

  # Fixed group definitions (order = render order). Title colour mirrors the
  # source design (INPUTS blue, CALCULATIONS green, APPENDICES grey).
  $groups = @(
    [pscustomobject]@{ Id = 'untitled';   Title = $null;          Selected = 'Menu link selected results';   TitleColor = $null },
    [pscustomobject]@{ Id = 'inputs';     Title = 'INPUTS';       Selected = 'Menu link selected input';     TitleColor = 26316 },
    [pscustomobject]@{ Id = 'equations';  Title = 'CALCULATIONS'; Selected = 'Menu link selected equations'; TitleColor = 32768 },
    [pscustomobject]@{ Id = 'appendices'; Title = 'APPENDICES';   Selected = 'Menu link selected';           TitleColor = 4210752 }
  )

  # Resolve Style objects once (assigning by object is more reliable via COM).
  $styleCache = @{}
  $getStyle = {
    param($name)
    if (-not $styleCache.ContainsKey($name)) { $styleCache[$name] = $Target.Styles.Item($name) }
    return $styleCache[$name]
  }

  # Group assignment for a sheet.
  $groupOf = {
    param($name)
    if ($name -eq 'Home' -or $name -eq 'Results') { return 'untitled' }
    if ($name -like 'Input*') { return 'inputs' }
    $cat = if ($CategoryMap.ContainsKey($name)) { [string] $CategoryMap[$name] } else { '' }
    if ($cat -eq 'calculation') { return 'equations' }
    return 'appendices'
  }

  # Friendly label for a sheet (explicit override, else strip 'Input - ' prefix).
  $labelOf = {
    param($name)
    if ($Labels.ContainsKey($name)) { return [string] $Labels[$name] }
    if ($name -like 'Input - *') { return $name.Substring(8) }
    return $name
  }

  # Collect members per group in worksheet tab order.
  $members = @{ 'untitled' = @(); 'inputs' = @(); 'equations' = @(); 'appendices' = @() }
  foreach ($ws in $Target.Worksheets) {
    $n = [string] $ws.Name
    $g = & $groupOf $n
    $members[$g] += $n
  }
  # Untitled group always leads with Home then Results.
  $ut = @()
  foreach ($x in @('Home', 'Results')) { if ($members['untitled'] -contains $x) { $ut += $x } }
  foreach ($x in $members['untitled']) { if ($ut -notcontains $x) { $ut += $x } }
  $members['untitled'] = $ut

  # Flatten into an ordered render plan (blank marker between groups).
  $rows = New-Object System.Collections.Generic.List[object]
  $firstGroup = $true
  foreach ($grp in $groups) {
    $mem = @($members[$grp.Id])
    if ($mem.Count -eq 0) { continue }
    if (-not $firstGroup) { $rows.Add([pscustomobject]@{ Kind = 'blank' }) }
    $firstGroup = $false
    if ($grp.Title) { $rows.Add([pscustomobject]@{ Kind = 'title'; Text = $grp.Title; Color = $grp.TitleColor }) }
    foreach ($n in $mem) {
      $rows.Add([pscustomobject]@{ Kind = 'link'; Text = (& $labelOf $n); Target = $n; Selected = $grp.Selected })
    }
  }

  # Locate a donor sheet that carries the logo, to seed sheets missing it.
  $logoDonor = $null
  foreach ($ws in $Target.Worksheets) {
    try { if ([string] $ws.Cells.Item(1, 1).Style.Name -eq $logoStyle) { $logoDonor = $ws; break } } catch { }
  }

  $updated = 0
  foreach ($ws in $Target.Worksheets) {
    $sn = [string] $ws.Name

    # Ensure the A1 logo is present (copy the whole cell incl. in-cell image).
    if ($null -ne $logoDonor) {
      $hasLogo = $false
      try { $hasLogo = ([string] $ws.Cells.Item(1, 1).Style.Name -eq $logoStyle) } catch { }
      if (-not $hasLogo -and $ws.Name -ne $logoDonor.Name) {
        try { $logoDonor.Range('A1').Copy($ws.Range('A1')) | Out-Null } catch { Write-Warning ("Menu: could not copy logo to '{0}': {1}" -f $sn, $_.Exception.Message) }
      }
    }

    # Blank the old menu (contents + formats) below the logo.
    try { $ws.Range("A2:A$clearToRow").Clear() | Out-Null } catch { }

    # Write the unified menu.
    $r = $firstMenuRow
    foreach ($row in $rows) {
      switch ($row.Kind) {
        'blank' { $r++ ; continue }
        'title' {
          $cell = $ws.Cells.Item($r, 1)
          try { $cell.Style = (& $getStyle $titleStyle) } catch { }
          $cell.Value2 = $row.Text
          if ($null -ne $row.Color) { try { $cell.Font.Color = $row.Color } catch { } }
        }
        'link' {
          $cell = $ws.Cells.Item($r, 1)
          $styleName = if ($row.Target -eq $sn) { $row.Selected } else { $defaultStyle }
          # Write the formula first: entering a HYPERLINK auto-applies Excel's
          # built-in 'Hyperlink' style, so the menu style must be set afterwards.
          $cell.Formula = "=HYPERLINK(""#'$($row.Target)'!A1"", ""$($row.Text)"")"
          try { $cell.Style = (& $getStyle $styleName) } catch { }
        }
      }
      $r++
    }
    $updated++
  }

  return $updated
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

$configPathResolved = Resolve-EnterpriseConfigPath -RepoRoot $RepoRoot -ConfigPath $ConfigPath -EnterpriseId $EnterpriseId
$config = Get-Content -Raw -LiteralPath $configPathResolved | ConvertFrom-Json
$configDir = Split-Path -Parent $configPathResolved

$registryName = if ($config.options -and $config.options.registry) { [string] $config.options.registry } else { '_ModuleRegistry.json' }
$registryPath = Join-Path $configDir $registryName
if (-not (Test-Path -LiteralPath $registryPath)) { throw "Registry not found: $registryPath" }
$registry = Get-Content -Raw -LiteralPath $registryPath | ConvertFrom-Json

$excelDir = Join-Path $RepoRoot 'Excel'

# Output workbook (template == output when they share a name).
$outWorkbookName = [string] $config.enterprise.outputWorkbook
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  $OutputPath = Join-Path (Join-Path $excelDir 'Enterprises') $outWorkbookName
}

# Template workbook: holds the enterprise's hand-designed base sheets (Home,
# Results, Input - Site, Input - Enterprise, Constants - Common, ...). When one
# is configured, every build starts from a FRESH copy of it so those sheets
# always reflect the template, then module sheets are imported on top (a full,
# deterministic rebuild). The per-enterprise value wins; the registry provides a
# shared fallback. If none is configured the legacy in-place behaviour applies
# (the output workbook must already exist).
$enterprisesDir = Join-Path $excelDir 'Enterprises'
$templateName = [string] $config.enterprise.templateWorkbook
if ([string]::IsNullOrWhiteSpace($templateName)) { $templateName = [string] $registry.templateWorkbook }
$templatePath = $null
$templateNameSet = $null
if (-not [string]::IsNullOrWhiteSpace($templateName)) {
  $templatePath = if ([System.IO.Path]::IsPathRooted($templateName)) { $templateName } else { Join-Path $enterprisesDir $templateName }
  if (-not (Test-Path -LiteralPath $templatePath)) { throw "Enterprise template workbook not found: $templatePath" }
  $templatePath = (Resolve-Path -LiteralPath $templatePath).Path
  # Capture the template's workbook-scoped names BEFORE import. These are
  # authoritative: any sheet-scoped shadow of them dragged in by a copied source
  # sheet is pruned after save so references resolve to the template's cell.
  $templateNameSet = Get-WorkbookScopedNameSet -Path $templatePath
  if (-not $DryRun) {
    $destDir = Split-Path -Parent $OutputPath
    if ($destDir -and -not (Test-Path -LiteralPath $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
    Copy-Item -LiteralPath $templatePath -Destination $OutputPath -Force
  }
}

if (-not $DryRun -and -not (Test-Path -LiteralPath $OutputPath)) {
  throw "Enterprise output workbook not found (create the base file first, or configure enterprise.templateWorkbook): $OutputPath"
}
if (Test-Path -LiteralPath $OutputPath) { $OutputPath = (Resolve-Path -LiteralPath $OutputPath).Path }

Write-Host ("Enterprise : {0}" -f $config.enterprise.name)
Write-Host ("Config     : {0}" -f $configPathResolved)
if ($templatePath) { Write-Host ("Template   : {0}" -f $templatePath) }
Write-Host ("Output     : {0}" -f $OutputPath)
Write-Host ("Mode       : {0}" -f $(if ($DryRun) { 'DRY RUN' } else { 'BUILD' }))
Write-Host ''

# --- Resolve selected modules -------------------------------------------------
$selectedModules = New-Object System.Collections.Generic.List[object]
foreach ($m in @($config.modules)) {
  if ($m -is [string]) {
    $selectedModules.Add([pscustomobject]@{ Id = $m; Include = $null; RenameSheets = $null })
  } else {
    $props = $m.PSObject.Properties.Name
    $inc = if ($props -contains 'include') { $m.include } else { $null }
    $rs = $null
    if (($props -contains 'renameSheets') -and $null -ne $m.renameSheets) {
      $rs = @{}
      foreach ($p in $m.renameSheets.PSObject.Properties) { $rs[[string] $p.Name] = [string] $p.Value }
    }
    $selectedModules.Add([pscustomobject]@{ Id = [string] $m.id; Include = $inc; RenameSheets = $rs })
  }
}

# Optional per-sheet provider overrides for common sheets (sheetName -> module id).
# By default a common sheet is taken from the first selected module workbook that
# contains it; this lets a specific module supply a richer/canonical version.
$commonSheetProviders = @{}
if ($config.options -and ($config.options.PSObject.Properties.Name -contains 'commonSheetProviders') -and $null -ne $config.options.commonSheetProviders) {
  foreach ($p in $config.options.commonSheetProviders.PSObject.Properties) { $commonSheetProviders[[string] $p.Name] = [string] $p.Value }
}

# Optional navigation-menu generation. options.menu.enabled (default true) turns
# on rebuilding the column-A menu; options.menu.labels maps sheet name -> label.
$menuEnabled = $true
$menuLabels = @{}
$menuLabelOrder = New-Object System.Collections.Generic.List[string]
if ($config.options -and ($config.options.PSObject.Properties.Name -contains 'menu') -and $null -ne $config.options.menu) {
  $menuCfg = $config.options.menu
  if ($menuCfg.PSObject.Properties.Name -contains 'enabled') { $menuEnabled = [bool] $menuCfg.enabled }
  if (($menuCfg.PSObject.Properties.Name -contains 'labels') -and $null -ne $menuCfg.labels) {
    foreach ($p in $menuCfg.labels.PSObject.Properties) {
      $menuLabels[[string] $p.Name] = [string] $p.Value
      $menuLabelOrder.Add([string] $p.Name)
    }
  }
}

# --- Build the ordered, de-duplicated sheet plan ------------------------------
# Each plan entry: Name, Category (input|calculation|constants|common), SourceHint (workbook file name), ProviderPath (resolved, filled later)
$plan = New-Object System.Collections.Generic.List[object]
$seenSheet = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)

$afeModulePaths = New-Object System.Collections.Generic.List[string]
function Add-AfeModule { param([string] $Name) if (-not [string]::IsNullOrWhiteSpace($Name)) { $afeModulePaths.Add('/projects/' + $Name) } }

# Common Excel Labs modules (always).
foreach ($lm in @($registry.common.excelLabsModules)) { Add-AfeModule -Name $lm }

$moduleWorkbookHints = New-Object System.Collections.Generic.List[string]

function Add-SheetToPlan {
  param([string] $Name, [string] $Category, [string] $SourceHint, [string] $OriginalName)
  if ([string]::IsNullOrWhiteSpace($Name)) { return }
  if ($seenSheet.Contains($Name)) { return }
  [void] $seenSheet.Add($Name)
  if ([string]::IsNullOrWhiteSpace($OriginalName)) { $OriginalName = $Name }
  $plan.Add([pscustomobject]@{ Name = $Name; Category = $Category; SourceHint = $SourceHint; ProviderPath = $null; OriginalName = $OriginalName })
}

# Track which sheet groups are active (for group sheets/labs), and a hint workbook per group.
$activeGroups = @{}

foreach ($sel in $selectedModules) {
  $mod = $registry.modules.($sel.Id)
  if ($null -eq $mod) { throw "Module '$($sel.Id)' is not defined in the registry." }
  $hint = [string] $mod.sourceWorkbook
  if (-not $moduleWorkbookHints.Contains($hint)) { $moduleWorkbookHints.Add($hint) }

  # Category sheets (with optional per-module include subset).
  foreach ($cat in @('input', 'calculation', 'constants')) {
    $sheets = @($mod.sheets.$cat)
    if ($null -ne $sel.Include -and $null -ne $sel.Include.$cat) { $sheets = @($sel.Include.$cat) }
    foreach ($sn in $sheets) {
      $orig = [string] $sn
      $newName = $orig
      if ($null -ne $sel.RenameSheets -and $sel.RenameSheets.ContainsKey($orig)) { $newName = $sel.RenameSheets[$orig] }
      Add-SheetToPlan -Name $newName -Category $cat -SourceHint $hint -OriginalName $orig
    }
  }

  # Module-specific Excel Labs modules.
  foreach ($lm in @($mod.excelLabsModules)) { Add-AfeModule -Name $lm }

  # Groups (shared constants + labs, deduped).
  foreach ($g in @($mod.groups)) {
    if (-not $activeGroups.ContainsKey($g)) { $activeGroups[$g] = $hint }
  }
}

# Group sheets + labs.
foreach ($g in $activeGroups.Keys) {
  $grp = $registry.sheetGroups.$g
  if ($null -eq $grp) { continue }
  foreach ($sn in @($grp.sheets)) { Add-SheetToPlan -Name ([string] $sn) -Category 'constants' -SourceHint $activeGroups[$g] }
  foreach ($lm in @($grp.excelLabsModules)) { Add-AfeModule -Name $lm }
}

# Common sheets (dedupe/template) - provider resolved later from first module workbook that has it.
if (-not $config.options -or $config.options.includeCommonSheets -ne $false) {
  foreach ($cs in @($registry.common.sheets)) {
    Add-SheetToPlan -Name ([string] $cs.name) -Category 'common' -SourceHint $null
  }
}

# --- Resolve module workbook paths + cache their sheet name sets -------------
$excel = $null
$openSources = @{}   # resolvedPath -> workbook COM
$sourceSheetSets = @{}  # resolvedPath -> HashSet of sheet names
$resolvedModuleWorkbooks = New-Object System.Collections.Generic.List[string]

try {
  $excel = New-ExcelApp

  foreach ($hint in $moduleWorkbookHints) {
    $resolved = Resolve-SourceWorkbook -ExcelDir $excelDir -HintName $hint
    if (-not $resolvedModuleWorkbooks.Contains($resolved)) { $resolvedModuleWorkbooks.Add($resolved) }
    if (-not $openSources.ContainsKey($resolved)) {
      $wb = $excel.Workbooks.Open($resolved, 0, $true)
      $openSources[$resolved] = $wb
      $set = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
      foreach ($n in (Get-WorksheetNames -Workbook $wb)) { [void] $set.Add($n) }
      $sourceSheetSets[$resolved] = $set
    }
  }

  # Map each plan entry's SourceHint -> resolved provider path.
  $hintToResolved = @{}
  foreach ($hint in $moduleWorkbookHints) {
    $hintToResolved[$hint] = Resolve-SourceWorkbook -ExcelDir $excelDir -HintName $hint
  }

  foreach ($entry in $plan) {
    if (-not [string]::IsNullOrWhiteSpace($entry.SourceHint)) {
      $entry.ProviderPath = $hintToResolved[$entry.SourceHint]
      continue
    }
    # Common sheet: honour an explicit provider override (options.commonSheetProviders),
    # else use the first module workbook (in selection order) that contains it.
    $preferredPath = $null
    if ($commonSheetProviders.ContainsKey($entry.Name)) {
      $ovModId = $commonSheetProviders[$entry.Name]
      $ovMod = $registry.modules.$ovModId
      if ($null -eq $ovMod) { throw "commonSheetProviders: module '$ovModId' (for sheet '$($entry.Name)') is not defined in the registry." }
      $ovHint = [string] $ovMod.sourceWorkbook
      if ($hintToResolved.ContainsKey($ovHint) -and $sourceSheetSets[$hintToResolved[$ovHint]].Contains($entry.Name)) {
        $preferredPath = $hintToResolved[$ovHint]
      } else {
        Write-Warning ("commonSheetProviders: module '{0}' does not provide sheet '{1}'; falling back to selection order." -f $ovModId, $entry.Name)
      }
    }
    if ($preferredPath) {
      $entry.ProviderPath = $preferredPath
    } else {
      foreach ($hint in $moduleWorkbookHints) {
        $rp = $hintToResolved[$hint]
        if ($sourceSheetSets[$rp].Contains($entry.Name)) { $entry.ProviderPath = $rp; break }
      }
    }
  }

  # --- Renamed-sheet bookkeeping ---------------------------------------------
  # A module may import a sheet under a distinct name (options renameSheets) so
  # it does not collide with another module's same-named sheet + duplicate
  # named ranges. Record the originals per provider so the name-upsert can skip
  # the renamed copy's defs (master keeps them) and the ref-repoint pass can
  # rebind that module's own formulas to the renamed sheet.
  $renameRecords = @()
  $renamedOriginalsByProvider = @{}
  foreach ($entry in $plan) {
    if ($entry.Name -ne $entry.OriginalName) {
      $renameRecords += [pscustomobject]@{ Original = $entry.OriginalName; NewName = $entry.Name; ProviderPath = $entry.ProviderPath }
      if (-not $renamedOriginalsByProvider.ContainsKey($entry.ProviderPath)) {
        $renamedOriginalsByProvider[$entry.ProviderPath] = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
      }
      [void] $renamedOriginalsByProvider[$entry.ProviderPath].Add($entry.OriginalName)
    }
  }

  # --- Open target and determine what already exists --------------------------
  # A real build opens the freshly-seeded output read-write. A dry run has not
  # copied the template, so it previews against the template (read-only) when one
  # is configured, otherwise the existing output.
  $basisPath = if ($DryRun -and $templatePath) { $templatePath } else { $OutputPath }
  $target = $excel.Workbooks.Open($basisPath, 0, [bool] $DryRun)
  $targetSheetNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($n in (Get-WorksheetNames -Workbook $target)) { [void] $targetSheetNames.Add($n) }

  # Custom sheets: ensure present (created blank if missing); never imported.
  $customNames = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
  foreach ($cs in @($config.customSheets)) {
    $cn = [string] $cs.name
    [void] $customNames.Add($cn)
    if (-not $targetSheetNames.Contains($cn)) {
      if (-not $DryRun) {
        $ws = $target.Worksheets.Add([System.Reflection.Missing]::Value, $target.Worksheets.Item($target.Worksheets.Count))
        $ws.Name = $cn
      }
      [void] $targetSheetNames.Add($cn)
      Write-Host ("  + custom sheet (blank): {0}" -f $cn)
    }
  }

  # --- Report / execute the plan ----------------------------------------------
  Write-Host ''
  Write-Host "Sheets to import:"
  $imported = New-Object System.Collections.Generic.List[string]
  $skippedExisting = New-Object System.Collections.Generic.List[string]
  $unresolved = New-Object System.Collections.Generic.List[string]

  foreach ($entry in $plan) {
    if ($customNames.Contains($entry.Name)) { continue }
    if ($targetSheetNames.Contains($entry.Name)) { $skippedExisting.Add($entry.Name); continue }
    if ([string]::IsNullOrWhiteSpace($entry.ProviderPath)) { $unresolved.Add($entry.Name); continue }

    $providerName = [System.IO.Path]::GetFileName($entry.ProviderPath)
    $label = if ($entry.Name -ne $entry.OriginalName) { "{0}  (renamed from '{1}')" -f $entry.Name, $entry.OriginalName } else { [string] $entry.Name }
    Write-Host ("  [{0,-11}] {1}  <-  {2}" -f $entry.Category, $label, $providerName)

    if (-not $DryRun) {
      $srcWb = $openSources[$entry.ProviderPath]
      $srcWs = $srcWb.Worksheets.Item($entry.OriginalName)
      $after = $target.Worksheets.Item($target.Worksheets.Count)
      [void] $srcWs.Copy([System.Reflection.Missing]::Value, $after)
      if ($entry.Name -ne $entry.OriginalName) {
        $copied = $target.Worksheets.Item($target.Worksheets.Count)
        $copied.Name = $entry.Name
      }
    }
    [void] $targetSheetNames.Add($entry.Name)
    $imported.Add($entry.Name)
  }

  # --- Upsert workbook-scoped defined names (functions + ranges) --------------
  $namesAdded = 0; $namesFixed = 0; $namesFailed = 0
  if (-not $DryRun) {
    # Snapshot existing target names.
    $targetNameSet = @{}
    foreach ($tn in $target.Names) {
      try { $targetNameSet[[string] $tn.Name] = $tn } catch { }
    }

    foreach ($rp in $resolvedModuleWorkbooks) {
      $srcWb = $openSources[$rp]
      foreach ($sn in $srcWb.Names) {
        $nm = $null; $refers = $null; $localName = $null
        try { $nm = [string] $sn.Name; $refers = [string] $sn.RefersTo; $localName = [string] $sn.NameLocal } catch { continue }
        if ([string]::IsNullOrWhiteSpace($nm)) { continue }
        if ($localName -like '*!*') { continue }          # sheet-scoped: travels with the sheet
        if ($refers -match '^=?#REF') { continue }

        # Skip names that back a sheet this module renamed on import: the master
        # copy (kept under the canonical name) owns those ranges, so carrying the
        # renamed module's identical definitions would collide or bind to the
        # wrong rows.
        if ($renamedOriginalsByProvider.ContainsKey($rp)) {
          $isRenamedTarget = $false
          foreach ($o in $renamedOriginalsByProvider[$rp]) {
            if ($refers -match ("'" + [regex]::Escape($o) + "'!")) { $isRenamedTarget = $true; break }
          }
          if ($isRenamedTarget) { continue }
        }

        if ($targetNameSet.ContainsKey($nm)) {
          # Fix names that got externalised (point back to a local sheet) during sheet copy.
          $existing = $targetNameSet[$nm]
          $curRefers = ''
          try { $curRefers = [string] $existing.RefersTo } catch { }
          if ($curRefers -match '\[' -and $refers -notmatch '\[') {
            try { $existing.RefersTo = $refers; $namesFixed++ } catch { }
          }
          continue
        }

        try {
          $added = $target.Names.Add($nm, $refers)
          $targetNameSet[$nm] = $added
          $namesAdded++
        } catch { $namesFailed++ }
      }
    }
  }

  # --- Reorder sheets --------------------------------------------------------
  # Tab order follows options.menu.labels (authoritative when present) so the
  # physical tab order matches the navigation menu. Sheets not listed in the
  # menu labels fall back to options.sheetOrder (by category) and are placed
  # after all labelled sheets.
  if (-not $DryRun -and $config.options -and ($config.options.sheetOrder -or $menuLabelOrder.Count -gt 0)) {
    $order = @($config.options.sheetOrder)
    $catRank = @{}
    for ($i = 0; $i -lt $order.Count; $i++) { $catRank[[string] $order[$i]] = $i }

    # Build desired category per sheet name.
    $sheetCategory = @{}
    foreach ($cs in @($config.customSheets)) { $sheetCategory[[string] $cs.name] = 'custom' }
    foreach ($entry in $plan) { if (-not $sheetCategory.ContainsKey($entry.Name)) { $sheetCategory[$entry.Name] = $entry.Category } }

    # Explicit tab order from menu labels (file order).
    $labelRank = @{}
    for ($i = 0; $i -lt $menuLabelOrder.Count; $i++) {
      if (-not $labelRank.ContainsKey($menuLabelOrder[$i])) { $labelRank[[string] $menuLabelOrder[$i]] = $i }
    }

    $rankOf = {
      param($name)
      if ($labelRank.ContainsKey($name)) { return $labelRank[$name] }
      # Not listed in menu labels: cluster after labelled sheets, by category.
      $base = if ($labelRank.Count -gt 0) { 100000 } else { 0 }
      $c = if ($sheetCategory.ContainsKey($name)) { $sheetCategory[$name] } else { 'zzz' }
      $cr = if ($catRank.ContainsKey($c)) { $catRank[$c] } else { 999 }
      return $base + $cr
    }

    # Include a stable secondary key (original index) so ties keep their order.
    $ordered = @()
    $idx = 0
    foreach ($ws in $target.Worksheets) {
      $ordered += [pscustomobject]@{ Name = [string] $ws.Name; Rank = (& $rankOf ([string] $ws.Name)); Index = $idx }
      $idx++
    }
    $desired = $ordered | Sort-Object Rank, Index
    for ($i = 0; $i -lt $desired.Count; $i++) {
      $wsName = $desired[$i].Name
      $ws = $target.Worksheets.Item($wsName)
      if ($i -eq 0) {
        $ws.Move($target.Worksheets.Item(1))
      } else {
        $ws.Move([System.Reflection.Missing]::Value, $target.Worksheets.Item($i))
      }
    }
  }

  # --- Localise externalised references (strip workbook prefix) --------------
  # Copying sheets one-at-a-time externalises cross-sheet refs to the form
  #   '<path>[book.xlsx]Sheet Name'!$A$1
  # Every sheet those refs target is now present in the enterprise workbook, so
  # strip the "<path>[book.xlsx]" token to rebind them to the local sheet.
  # References whose target sheet is NOT present are left external (correct).
  # This complements the source-side named-range routing (matrix consumers):
  # it clears the remaining input/constant/mixed cross-sheet references.
  $refsLocalised = 0
  $namesLocalised = 0
  $namesStillExternal = 0
  $refsRepointed = 0
  if (-not $DryRun) {
    # Authoritative set of local sheet names (script-scoped so the regex
    # MatchEvaluator can see it reliably).
    $script:__localSheets = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ws in $target.Worksheets) { [void] $script:__localSheets.Add([string] $ws.Name) }

    # Authoritative set of local Excel Table (ListObject) names. External
    # structured-table references carry the workbook filename in the sheet slot
    # ('<path>[book.xlsx]book.xlsx'!Table_X[Col]) so the sheet-based strip below
    # never matches them; this set lets us rebind them when the table is present.
    $script:__localTables = New-Object 'System.Collections.Generic.HashSet[string]' ([System.StringComparer]::OrdinalIgnoreCase)
    foreach ($ws in $target.Worksheets) {
      try { foreach ($lo in $ws.ListObjects) { [void] $script:__localTables.Add([string] $lo.Name) } } catch { }
    }

    # Matches a quoted external qualifier: '<path>[<file>]<sheet>'
    # (Excel always quotes a reference that carries a [workbook] token.)
    $reExtRef = [regex] "'(?<pre>[^']*)\[(?<file>[^\[\]]+)\](?<sheet>[^']*)'"
    $eval = [System.Text.RegularExpressions.MatchEvaluator] {
      param($m)
      $sheet = $m.Groups['sheet'].Value
      if ($script:__localSheets.Contains($sheet)) { return "'" + $sheet + "'" }
      return $m.Value
    }

    # Matches an external qualifier that names another workbook by path and is
    # immediately followed by a structured-table reference, e.g.
    #   '<full path>\book.xlsx'!Table_X[Col]     (no [..] brackets: workbook-level name)
    #   '<path>[book.xlsx]sheet'!Table_X[Col]
    # The table is a workbook-scoped ListObject, so when it is now local drop the
    # whole '...'! qualifier to leave the bare TableName[...] structured reference.
    # Requiring ".xls" in the quoted span keeps local 'Sheet'!Range refs untouched.
    $reTableRef = [regex] "'[^']*\.xls[a-z]*[^']*'!(?<name>[A-Za-z_\\][A-Za-z0-9_.\\]*)(?=\[)"
    $evalTable = [System.Text.RegularExpressions.MatchEvaluator] {
      param($m)
      $name = $m.Groups['name'].Value
      if ($script:__localTables.Contains($name)) { return $name }
      return $m.Value
    }

    foreach ($ws in $target.Worksheets) {
      $ur = $ws.UsedRange
      # Formula2 (dynamic-array aware) preserves spilling structured refs like
      # Table[Col]. Writing via the legacy .Formula would force an implicit
      # intersection '@' (Table[@[Col]]) that then errors #VALUE! off-table.
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

    # --- Localise externalised defined-name RefersTo ------------------------
    # Copying sheets one-at-a-time also externalises the sheet-scoped names that
    # travel with them (M1_Table_*, X_Table_*, X_Cell_*, VEERG_*_Result_*) to
    #   '<path>[book.xlsx]Sheet'!$A$1
    # The upsert pass above only re-links WORKBOOK-scoped names, so these remain
    # external and any OFFSET/INDEX cell that reads them errors (#VALUE!/#REF!).
    # Apply the same strip to every name whose target sheet is now local.
    # Names whose target sheet is NOT present are left external and counted.
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

    # --- Repoint refs on renamed-module sheets to the renamed copy -----------
    # A module whose input sheet was imported under a distinct name still holds
    # formulas that reference the ORIGINAL sheet name. After the localise pass
    # those bind to the master copy (different row layout) and misread. Rebind
    # every '<Original>'! reference on that module's own sheets to '<NewName>'!.
    foreach ($rec in $renameRecords) {
      $needle = "'" + $rec.Original + "'!"
      $repl = "'" + $rec.NewName + "'!"
      $moduleSheets = @($plan | Where-Object { $_.ProviderPath -eq $rec.ProviderPath } | ForEach-Object { $_.Name }) | Select-Object -Unique
      foreach ($sName in $moduleSheets) {
        if (-not $script:__localSheets.Contains($sName)) { continue }
        $ws = $target.Worksheets.Item($sName)
        $ur = $ws.UsedRange
        $f = $ur.Formula2
        $rowBase = [int] $ur.Row
        $colBase = [int] $ur.Column
        if ($f -is [System.Array]) {
          $rows = $f.GetLength(0); $cols = $f.GetLength(1)
          for ($i = 1; $i -le $rows; $i++) {
            for ($j = 1; $j -le $cols; $j++) {
              $v = $f.GetValue($i, $j)
              if ($v -isnot [string] -or -not $v.Contains($needle)) { continue }
              $new = $v.Replace($needle, $repl)
              if ($new -ne $v) {
                try { $ws.Cells.Item($rowBase + $i - 1, $colBase + $j - 1).Formula2 = $new; $refsRepointed++ } catch { }
              }
            }
          }
        } elseif ($f -is [string] -and $f.Contains($needle)) {
          $new = $f.Replace($needle, $repl)
          if ($new -ne $f) {
            try { $ws.Cells.Item($rowBase, $colBase).Formula2 = $new; $refsRepointed++ } catch { }
          }
        }
      }
    }
    if ($refsRepointed -gt 0) { Write-Host ("Repointed {0} reference(s) to renamed sheet copies." -f $refsRepointed) }
  }

  # Redundant sheet-scoped defined names are pruned AFTER save, directly from
  # xl/workbook.xml (see Remove-RedundantSheetScopedNames), because deleting them
  # via COM re-resolves the dependency graph on every delete and pegs all cores
  # recalculating for tens of minutes. $namesDeduped is populated post-save.
  $namesDeduped = 0

  # --- Regenerate the column-A navigation menu on every sheet ----------------
  # Rebuilt from the final sheet set so it always matches the assembled
  # enterprise (links, labels, groups). Runs after reorder so tab order (used
  # for within-group ordering) is final.
  $menuSheetsUpdated = 0
  if (-not $DryRun -and $menuEnabled) {
    $menuCategory = @{}
    foreach ($cs in @($config.customSheets)) { $menuCategory[[string] $cs.name] = 'custom' }
    foreach ($entry in $plan) { if (-not $menuCategory.ContainsKey($entry.Name)) { $menuCategory[$entry.Name] = $entry.Category } }
    $menuSheetsUpdated = Set-EnterpriseNavMenu -Target $target -CategoryMap $menuCategory -Labels $menuLabels
    if ($menuSheetsUpdated -gt 0) { Write-Host ("Regenerated navigation menu on {0} sheet(s)." -f $menuSheetsUpdated) }
  }

  # --- Break any leftover external links (make workbook self-contained) -------
  # Every resolvable cross-sheet reference was localised/repointed above, so any
  # link source still registered is either a phantom entry (link table row with
  # no cached cell data) or points at a sheet that was not imported. BreakLink
  # converts any remaining references to their current values and drops the
  # orphaned link-table parts, so the saved workbook reports zero external
  # sources instead of prompting the user to update links on open.
  $linksBroken = 0
  if (-not $DryRun) {
    try {
      $preLinks = $target.LinkSources(1)  # xlExcelLinks
      if ($null -ne $preLinks) {
        foreach ($l in @($preLinks)) {
          try { $target.BreakLink($l, 1); $linksBroken++ }  # xlLinkTypeExcelLinks
          catch { Write-Warning ("Could not break external link: {0} ({1})" -f $l, $_.Exception.Message) }
        }
      }
    } catch { }
    if ($linksBroken -gt 0) { Write-Host ("Broke {0} leftover external link source(s)." -f $linksBroken) }
  }

  # --- Detect leftover external links ----------------------------------------
  $externalLinks = @()
  try {
    $links = $target.LinkSources(1)  # xlExcelLinks
    if ($null -ne $links) { $externalLinks = @($links) }
  } catch { }

  # --- Save & close -----------------------------------------------------------
  if (-not $DryRun) {
    $target.Save()
  }
  $target.Close($false)

  foreach ($wb in $openSources.Values) { $wb.Close($false) }
  $excel.Quit()
  [System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel) | Out-Null
  $excel = $null

  # --- Prune redundant sheet-scoped defined names (post-save, via XML) --------
  if (-not $DryRun) {
    $dedup = Remove-RedundantSheetScopedNames -TargetPath $OutputPath -AuthoritativeNames $templateNameSet
    $namesDeduped = [int] $dedup.Removed
    if ($namesDeduped -gt 0) {
      Write-Host ("Removed {0} redundant sheet-scoped defined name(s) (kept {1})." -f $namesDeduped, $dedup.Kept)
    }
  }

  # --- Merge Excel Labs modules into the saved workbook -----------------------
  $mergedModules = @()
  if (-not $DryRun) {
    $mergedModules = Merge-AfeModules -TargetPath $OutputPath -RequiredModulePaths $afeModulePaths -SourceWorkbookPaths $resolvedModuleWorkbooks
  } else {
    Write-Host ''
    Write-Host "Excel Labs modules required:"
    foreach ($mp in ($afeModulePaths | Select-Object -Unique | Sort-Object)) { Write-Host ("  {0}" -f $mp) }
  }

  # --- Summary ----------------------------------------------------------------
  Write-Host ''
  Write-Host "===================== Summary ====================="
  Write-Host ("Sheets imported        : {0}" -f $imported.Count)
  Write-Host ("Sheets already present : {0}" -f $skippedExisting.Count)
  if ($unresolved.Count -gt 0) {
    Write-Host ("Sheets UNRESOLVED      : {0}" -f $unresolved.Count)
    foreach ($u in $unresolved) { Write-Warning "No source workbook contained sheet: $u" }
  }
  if (-not $DryRun) {
    Write-Host ("Defined names added    : {0}" -f $namesAdded)
    Write-Host ("Defined names re-linked: {0}" -f $namesFixed)
    Write-Host ("Defined names skipped  : {0}" -f $namesFailed)
    Write-Host ("Sheet-scoped dupes rm  : {0}" -f $namesDeduped)
    Write-Host ("Excel Labs modules add : {0}" -f @($mergedModules).Count)
    Write-Host ("Refs localised (strip) : {0}" -f $refsLocalised)
    Write-Host ("Names localised (strip): {0}" -f $namesLocalised)
    Write-Host ("Names still external   : {0}" -f $namesStillExternal)
    Write-Host ("Refs repointed (rename): {0}" -f $refsRepointed)
    Write-Host ("External links broken  : {0}" -f $linksBroken)
    Write-Host ("Nav menu regenerated   : {0}" -f $menuSheetsUpdated)
  }
  if (@($externalLinks).Count -gt 0) {
    Write-Warning ("Workbook still has {0} external link source(s); some cross-sheet references may not have resolved locally:" -f @($externalLinks).Count)
    foreach ($l in $externalLinks) { Write-Warning ("  {0}" -f $l) }
  }
  Write-Host "==================================================="
}
finally {
  if ($null -ne $excel) {
    try { $excel.Quit() } catch { }
    try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel) | Out-Null } catch { }
  }
}
