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

  $exact = Join-Path $ExcelDir $HintName
  if (Test-Path -LiteralPath $exact) { return (Resolve-Path -LiteralPath $exact).Path }

  $base = [System.IO.Path]::GetFileNameWithoutExtension($HintName)
  $stem = [regex]::Replace($base, '_v\d+$', '')

  $best = Get-ChildItem -Path $ExcelDir -File |
    Where-Object {
      ($_.Extension -eq '.xlsx' -or $_.Extension -eq '.xlsm') -and
      $_.Name -notlike '~$*' -and
      $_.BaseName -notmatch '(?i)_expanded' -and
      ([regex]::Replace($_.BaseName, '_v\d+$', '') -eq $stem)
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
if (-not (Test-Path -LiteralPath $OutputPath)) {
  throw "Enterprise output workbook not found (create the base file first): $OutputPath"
}
$OutputPath = (Resolve-Path -LiteralPath $OutputPath).Path

Write-Host ("Enterprise : {0}" -f $config.enterprise.name)
Write-Host ("Config     : {0}" -f $configPathResolved)
Write-Host ("Output     : {0}" -f $OutputPath)
Write-Host ("Mode       : {0}" -f $(if ($DryRun) { 'DRY RUN' } else { 'BUILD' }))
Write-Host ''

# --- Resolve selected modules -------------------------------------------------
$selectedModules = New-Object System.Collections.Generic.List[object]
foreach ($m in @($config.modules)) {
  if ($m -is [string]) {
    $selectedModules.Add([pscustomobject]@{ Id = $m; Include = $null })
  } else {
    $selectedModules.Add([pscustomobject]@{ Id = [string] $m.id; Include = $m.include })
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
  param([string] $Name, [string] $Category, [string] $SourceHint)
  if ([string]::IsNullOrWhiteSpace($Name)) { return }
  if ($seenSheet.Contains($Name)) { return }
  [void] $seenSheet.Add($Name)
  $plan.Add([pscustomobject]@{ Name = $Name; Category = $Category; SourceHint = $SourceHint; ProviderPath = $null })
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
    foreach ($sn in $sheets) { Add-SheetToPlan -Name ([string] $sn) -Category $cat -SourceHint $hint }
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
    # Common sheet: find first module workbook (in selection order) that contains it.
    foreach ($hint in $moduleWorkbookHints) {
      $rp = $hintToResolved[$hint]
      if ($sourceSheetSets[$rp].Contains($entry.Name)) { $entry.ProviderPath = $rp; break }
    }
  }

  # --- Open target and determine what already exists --------------------------
  $target = $excel.Workbooks.Open($OutputPath, 0, $false)
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
    Write-Host ("  [{0,-11}] {1}  <-  {2}" -f $entry.Category, $entry.Name, $providerName)

    if (-not $DryRun) {
      $srcWb = $openSources[$entry.ProviderPath]
      $srcWs = $srcWb.Worksheets.Item($entry.Name)
      $after = $target.Worksheets.Item($target.Worksheets.Count)
      [void] $srcWs.Copy([System.Reflection.Missing]::Value, $after)
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

  # --- Reorder sheets by options.sheetOrder ----------------------------------
  if (-not $DryRun -and $config.options -and $config.options.sheetOrder) {
    $order = @($config.options.sheetOrder)
    $catRank = @{}
    for ($i = 0; $i -lt $order.Count; $i++) { $catRank[[string] $order[$i]] = $i }

    # Build desired category per sheet name.
    $sheetCategory = @{}
    foreach ($cs in @($config.customSheets)) { $sheetCategory[[string] $cs.name] = 'custom' }
    foreach ($entry in $plan) { if (-not $sheetCategory.ContainsKey($entry.Name)) { $sheetCategory[$entry.Name] = $entry.Category } }

    $rankOf = {
      param($name)
      $c = if ($sheetCategory.ContainsKey($name)) { $sheetCategory[$name] } else { 'zzz' }
      if ($catRank.ContainsKey($c)) { return $catRank[$c] } else { return 999 }
    }

    $ordered = @()
    foreach ($ws in $target.Worksheets) { $ordered += [pscustomobject]@{ Name = [string] $ws.Name; Rank = (& $rankOf ([string] $ws.Name)) } }
    $desired = $ordered | Sort-Object Rank
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
    Write-Host ("Excel Labs modules add : {0}" -f @($mergedModules).Count)
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
