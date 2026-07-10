<#
.SYNOPSIS
  Assembles a single enterprise test-input JSON from the per-module TestInput_*.json
  files under Test/, choosing which modules to include from an enterprise config
  (e.g. Enterprises/Enterprise_PastureBeef.json).

.DESCRIPTION
  The enterprise config's "modules" array decides which module test inputs are merged.
  For each selected module:
    1. Its registry entry (_ModuleRegistry.json) gives the sourceWorkbook name.
    2. The version-stripped workbook base is matched against Test/Test.json's
       TestExcelFile values to locate that module's TestInputFile.
    3. The module's TestInput JSON (flat X_Cell_* fields + an InputTables array) is
       merged into the enterprise result.

  Merge rules:
    * Scalar X_Cell_* fields  - on conflict the "winner" designated by the enterprise
                                config wins: the module that keeps the canonical shared
                                input sheet beats one that defers to it via renameSheets
                                (Enteric renames 'Input - Pasture Beef', so Manure wins).
                                Among modules with equal deferral status the earlier one
                                in the config wins.
    * Site fields (X_Cell_Site_*) - overridden by the module named as the
                                "Input - Site" provider in options.commonSheetProviders
                                (site data is duplicated across modules and their test
                                values differ; the provider is the canonical source).
    * InputTables             - concatenated across modules; a duplicate TableName keeps
                                the winning module's copy (same rule as fields).

  Per-module "include" subsetting in the enterprise config is NOT applied to the test
  input: the full module TestInput is merged (extra cells/tables that have no matching
  named range in the enterprise workbook are simply ignored downstream).

.PARAMETER ConfigPath
  Enterprise config JSON. Defaults to Enterprises/Enterprise_PastureBeef.json.

.PARAMETER RegistryPath
  Module registry JSON. Defaults to options.registry (resolved next to the config),
  falling back to Enterprises/_ModuleRegistry.json.

.PARAMETER TestConfigPath
  Test catalog JSON. Defaults to Test/Test.json.

.PARAMETER OutputPath
  Output file. Defaults to Test/Enterprises/TestInput_Enterprise_<id>.json.

.PARAMETER DryRun
  Resolve and report but write no file.
#>
param(
  [string] $RepoRoot = $(Split-Path $PSScriptRoot -Parent),
  [string] $ConfigPath,
  [string] $RegistryPath,
  [string] $TestConfigPath,
  [string] $OutputPath,
  [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $RepoRoot)) {
  throw "RepoRoot path '$RepoRoot' was not found."
}
$RepoRoot = (Resolve-Path -LiteralPath $RepoRoot).Path

if ([string]::IsNullOrWhiteSpace($ConfigPath)) {
  $ConfigPath = Join-Path $RepoRoot 'Enterprises\Enterprise_PastureBeef.json'
}
if (-not (Test-Path -LiteralPath $ConfigPath)) {
  throw "Enterprise config not found: $ConfigPath"
}
$ConfigPath = (Resolve-Path -LiteralPath $ConfigPath).Path
$configDir = Split-Path -Parent $ConfigPath

if ([string]::IsNullOrWhiteSpace($TestConfigPath)) {
  $TestConfigPath = Join-Path $RepoRoot 'Test\Test.json'
}
if (-not (Test-Path -LiteralPath $TestConfigPath)) {
  throw "Test catalog not found: $TestConfigPath"
}
$TestConfigPath = (Resolve-Path -LiteralPath $TestConfigPath).Path
$testRoot = Split-Path -Parent $TestConfigPath

# ---------------------------------------------------------------------------
# Load configs
# ---------------------------------------------------------------------------

$config = Get-Content -LiteralPath $ConfigPath -Raw | ConvertFrom-Json

$enterpriseId = 'Enterprise'
if ($config.PSObject.Properties.Name -contains 'enterprise' -and $null -ne $config.enterprise -and
    $config.enterprise.PSObject.Properties.Name -contains 'id') {
  $enterpriseId = [string] $config.enterprise.id
}

# Resolve the registry path: explicit param > options.registry (next to config) > default.
if ([string]::IsNullOrWhiteSpace($RegistryPath)) {
  $registryName = $null
  if ($config.PSObject.Properties.Name -contains 'options' -and $null -ne $config.options -and
      $config.options.PSObject.Properties.Name -contains 'registry') {
    $registryName = [string] $config.options.registry
  }
  if (-not [string]::IsNullOrWhiteSpace($registryName)) {
    $RegistryPath = Join-Path $configDir $registryName
  } else {
    $RegistryPath = Join-Path $configDir '_ModuleRegistry.json'
  }
}
if (-not (Test-Path -LiteralPath $RegistryPath)) {
  throw "Module registry not found: $RegistryPath"
}
$RegistryPath = (Resolve-Path -LiteralPath $RegistryPath).Path
$registry = Get-Content -LiteralPath $RegistryPath -Raw | ConvertFrom-Json

$testConfig = Get-Content -LiteralPath $TestConfigPath -Raw | ConvertFrom-Json

if ([string]::IsNullOrWhiteSpace($OutputPath)) {
  $OutputPath = Join-Path $testRoot ("Enterprises\TestInput_Enterprise_{0}.json" -f $enterpriseId)
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Get-WorkbookBaseName {
  # Strip extension and trailing version suffix (_WIP_v07, _v02, ...).
  param([Parameter(Mandatory = $true)] [string] $WorkbookFile)
  $base = [System.IO.Path]::GetFileNameWithoutExtension($WorkbookFile)
  return ($base -replace '(?i)_(?:WIP_)?v\d+$', '')
}

function Get-TestEntries {
  # Recursively collect every node in Test.json that defines a TestID + TestInputFile.
  param([Parameter(Mandatory = $true)] [AllowNull()] $Node)
  $results = New-Object System.Collections.Generic.List[object]
  if ($null -eq $Node -or $Node -isnot [psobject]) { return $results }
  $props = @($Node.PSObject.Properties)
  $names = @($props.Name)
  if (($names -contains 'TestID') -and ($names -contains 'TestInputFile')) {
    [void]$results.Add($Node)
    return $results
  }
  foreach ($p in $props) {
    if ($null -ne $p.Value -and $p.Value -is [psobject]) {
      foreach ($child in (Get-TestEntries -Node $p.Value)) { [void]$results.Add($child) }
    }
  }
  return $results
}

function Resolve-TestEntryForBase {
  # Match a version-stripped workbook base to a Test.json entry by exact name or a
  # token-boundary prefix (e.g. base '14_Electricity_Scope2' matches TestExcelFile
  # '14_Electricity'). Longest matching TestExcelFile wins.
  param(
    [Parameter(Mandatory = $true)] $Entries,
    [Parameter(Mandatory = $true)] [string] $Base
  )
  $best = $null
  $bestLen = -1
  foreach ($e in $Entries) {
    $tef = [string] $e.TestExcelFile
    if ([string]::IsNullOrWhiteSpace($tef)) { continue }
    $isMatch = $false
    if ($Base -ieq $tef) { $isMatch = $true }
    elseif ($Base.StartsWith($tef + '_', [System.StringComparison]::OrdinalIgnoreCase)) { $isMatch = $true }
    elseif ($tef.StartsWith($Base + '_', [System.StringComparison]::OrdinalIgnoreCase)) { $isMatch = $true }
    if ($isMatch -and $tef.Length -gt $bestLen) {
      $best = $e
      $bestLen = $tef.Length
    }
  }
  return $best
}

function ConvertTo-JsonStringLiteral {
  param([Parameter(Mandatory = $true)] [AllowEmptyString()] [string] $Text)
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.Append('"')
  foreach ($ch in $Text.ToCharArray()) {
    switch ($ch) {
      '"' { [void]$sb.Append('\"') }
      '\' { [void]$sb.Append('\\') }
      "`b" { [void]$sb.Append('\b') }
      "`f" { [void]$sb.Append('\f') }
      "`n" { [void]$sb.Append('\n') }
      "`r" { [void]$sb.Append('\r') }
      "`t" { [void]$sb.Append('\t') }
      default {
        if ([int][char]$ch -lt 32) { [void]$sb.Append(('\u{0:x4}' -f [int][char]$ch)) }
        else { [void]$sb.Append($ch) }
      }
    }
  }
  [void]$sb.Append('"')
  return $sb.ToString()
}

function ConvertTo-TabJson {
  # Tab-indented JSON serializer matching the module TestInput files. PowerShell 5.1's
  # ConvertTo-Json emits space indentation with formatting quirks, so serialize manually.
  param([Parameter(Mandatory = $true)] [AllowNull()] $Value, [int] $Indent = 0)

  if ($null -eq $Value) { return 'null' }
  if ($Value -is [bool]) { return $(if ($Value) { 'true' } else { 'false' }) }
  if ($Value -is [string]) { return (ConvertTo-JsonStringLiteral -Text $Value) }
  if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or
      $Value -is [decimal] -or $Value -is [single] -or $Value -is [byte] -or $Value -is [int16]) {
    return ([System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture))
  }

  $childIndent = $Indent + 1
  $pad = "`t" * $Indent
  $childPad = "`t" * $childIndent

  if ($Value -is [System.Collections.IDictionary]) {
    $keys = @($Value.Keys)
    if ($keys.Count -eq 0) { return '{}' }
    $lines = foreach ($k in $keys) {
      '{0}{1}: {2}' -f $childPad, (ConvertTo-JsonStringLiteral -Text ([string]$k)), (ConvertTo-TabJson -Value $Value[$k] -Indent $childIndent)
    }
    return "{`n" + ($lines -join ",`n") + "`n$pad}"
  }

  if ($Value -is [System.Management.Automation.PSCustomObject]) {
    $props = @($Value.PSObject.Properties)
    if ($props.Count -eq 0) { return '{}' }
    $lines = foreach ($p in $props) {
      '{0}{1}: {2}' -f $childPad, (ConvertTo-JsonStringLiteral -Text $p.Name), (ConvertTo-TabJson -Value $p.Value -Indent $childIndent)
    }
    return "{`n" + ($lines -join ",`n") + "`n$pad}"
  }

  if ($Value -is [System.Collections.IEnumerable]) {
    $items = @($Value)
    if ($items.Count -eq 0) { return '[]' }
    $lines = foreach ($item in $items) {
      '{0}{1}' -f $childPad, (ConvertTo-TabJson -Value $item -Indent $childIndent)
    }
    return "[`n" + ($lines -join ",`n") + "`n$pad]"
  }

  return (ConvertTo-JsonStringLiteral -Text ([string]$Value))
}

# ---------------------------------------------------------------------------
# Resolve selected modules -> test input files
# ---------------------------------------------------------------------------

$testEntries = @(Get-TestEntries -Node $testConfig)
if ($testEntries.Count -eq 0) {
  throw "No test entries found in $TestConfigPath"
}

if (-not ($config.PSObject.Properties.Name -contains 'modules') -or $null -eq $config.modules) {
  throw "Enterprise config has no 'modules' array: $ConfigPath"
}

# Site-field provider module (its X_Cell_Site_* values are canonical).
$siteProvider = $null
if ($config.PSObject.Properties.Name -contains 'options' -and $null -ne $config.options -and
    $config.options.PSObject.Properties.Name -contains 'commonSheetProviders' -and
    $null -ne $config.options.commonSheetProviders -and
    $config.options.commonSheetProviders.PSObject.Properties.Name -contains 'Input - Site') {
  $siteProvider = [string] $config.options.commonSheetProviders.'Input - Site'
}

$merged = [ordered]@{}
$mergedSources = @{}                          # field name -> module id that set it
$mergedRank = @{}                             # field name -> rank of the winning module
$tables = New-Object System.Collections.Generic.List[object]
$tablePos = @{}                               # table name -> index in $tables
$tableRank = @{}                              # table name -> rank of the winning module
$tableSource = @{}                            # table name -> module id that set it
$loadedInputs = [ordered]@{}                   # module id -> parsed TestInput object
$warnings = 0

# Conflict resolution rank (lower wins). When two modules define the same field/table,
# the module that keeps the canonical shared input sheet wins over one that defers to it
# by renaming its copy (renameSheets). Enteric renames 'Input - Pasture Beef', so Manure
# (the master, no rename) wins the shared Pasture Beef fields/tables. Among modules with
# equal deferral status, the earlier one in the config wins (stable first-wins).
function Get-ModuleRank {
  param([Parameter(Mandatory = $true)] [AllowNull()] $ModuleEntry, [Parameter(Mandatory = $true)] [int] $Index)
  $defers = $false
  if ($ModuleEntry -isnot [string] -and $null -ne $ModuleEntry -and
      ($ModuleEntry.PSObject.Properties.Name -contains 'renameSheets') -and
      $null -ne $ModuleEntry.renameSheets -and
      (@($ModuleEntry.renameSheets.PSObject.Properties).Count -gt 0)) {
    $defers = $true
  }
  $base = if ($defers) { 1000 } else { 0 }
  return ($base + $Index)
}

$moduleList = @($config.modules)
for ($mi = 0; $mi -lt $moduleList.Count; $mi++) {
  $moduleEntry = $moduleList[$mi]
  $moduleId = if ($moduleEntry -is [string]) { $moduleEntry } else { [string] $moduleEntry.id }
  if ([string]::IsNullOrWhiteSpace($moduleId)) {
    Write-Warning "Skipping module entry with no id."
    $warnings++
    continue
  }

  $moduleRank = Get-ModuleRank -ModuleEntry $moduleEntry -Index $mi

  $registryModule = $null
  if ($registry.PSObject.Properties.Name -contains 'modules' -and $null -ne $registry.modules -and
      $registry.modules.PSObject.Properties.Name -contains $moduleId) {
    $registryModule = $registry.modules.$moduleId
  }
  if ($null -eq $registryModule) {
    Write-Warning "Module '$moduleId' not found in registry; skipping."
    $warnings++
    continue
  }

  $sourceWorkbook = [string] $registryModule.sourceWorkbook
  if ([string]::IsNullOrWhiteSpace($sourceWorkbook)) {
    Write-Warning "Module '$moduleId' has no sourceWorkbook in registry; skipping."
    $warnings++
    continue
  }

  $base = Get-WorkbookBaseName -WorkbookFile $sourceWorkbook
  $entry = Resolve-TestEntryForBase -Entries $testEntries -Base $base
  if ($null -eq $entry) {
    Write-Warning "No Test.json entry matches module '$moduleId' (workbook base '$base'); no test input merged."
    $warnings++
    continue
  }

  $inputRel = [string] $entry.TestInputFile
  $inputPath = if ([System.IO.Path]::IsPathRooted($inputRel)) { $inputRel } else { Join-Path $testRoot $inputRel }
  if (-not (Test-Path -LiteralPath $inputPath)) {
    Write-Warning "Test input file for module '$moduleId' not found: $inputPath"
    $warnings++
    continue
  }

  $inputObj = Get-Content -LiteralPath $inputPath -Raw | ConvertFrom-Json
  $loadedInputs[$moduleId] = $inputObj

  $cellCount = 0
  $tableCount = 0
  foreach ($prop in @($inputObj.PSObject.Properties)) {
    if ($prop.Name -eq 'InputTables') {
      foreach ($tbl in @($prop.Value)) {
        $tn = [string] $tbl.TableName
        if ([string]::IsNullOrWhiteSpace($tn)) {
          [void]$tables.Add($tbl); $tableCount++
          continue
        }
        if (-not $tablePos.ContainsKey($tn)) {
          [void]$tables.Add($tbl)
          $tablePos[$tn] = $tables.Count - 1
          $tableRank[$tn] = $moduleRank
          $tableSource[$tn] = $moduleId
          $tableCount++
        }
        elseif ($moduleRank -lt $tableRank[$tn]) {
          $tables[$tablePos[$tn]] = $tbl
          Write-Warning ("InputTable '{0}': '{1}' overrides copy from '{2}'." -f $tn, $moduleId, $tableSource[$tn])
          $tableRank[$tn] = $moduleRank
          $tableSource[$tn] = $moduleId
          $warnings++
        }
        else {
          Write-Warning ("InputTable '{0}': keeping copy from '{1}' over '{2}'." -f $tn, $tableSource[$tn], $moduleId)
          $warnings++
        }
      }
      continue
    }

    # Scalar field: the higher-priority (lower-rank) module wins on conflict.
    if ($merged.Contains($prop.Name)) {
      # Site fields are resolved authoritatively by the provider override below, so
      # ignore any mid-merge disagreement between modules for them.
      if (-not [string]::IsNullOrWhiteSpace($siteProvider) -and $prop.Name -like 'X_Cell_Site_*') {
        continue
      }
      $existing = [string] $merged[$prop.Name]
      $incoming = [string] $prop.Value
      if ($existing -ne $incoming) {
        if ($moduleRank -lt $mergedRank[$prop.Name]) {
          Write-Warning ("Field '{0}': '{1}'='{2}' overrides '{3}' from '{4}'." -f `
              $prop.Name, $moduleId, $incoming, $existing, $mergedSources[$prop.Name])
          $merged[$prop.Name] = $prop.Value
          $mergedSources[$prop.Name] = $moduleId
          $mergedRank[$prop.Name] = $moduleRank
        }
        else {
          Write-Warning ("Field '{0}': keeping '{1}' from '{2}' over '{3}' from '{4}'." -f `
              $prop.Name, $existing, $mergedSources[$prop.Name], $incoming, $moduleId)
        }
        $warnings++
      }
      continue
    }
    $merged[$prop.Name] = $prop.Value
    $mergedSources[$prop.Name] = $moduleId
    $mergedRank[$prop.Name] = $moduleRank
    $cellCount++
  }

  Write-Host ("  {0,-28} <- {1} ({2} new cell(s), {3} table(s))" -f $moduleId, (Split-Path $inputPath -Leaf), $cellCount, $tableCount)
}

# ---------------------------------------------------------------------------
# Site-field override: the designated Input - Site provider is canonical.
# ---------------------------------------------------------------------------

if (-not [string]::IsNullOrWhiteSpace($siteProvider)) {
  if ($loadedInputs.Contains($siteProvider)) {
    $providerObj = $loadedInputs[$siteProvider]
    $overridden = 0
    foreach ($prop in @($providerObj.PSObject.Properties)) {
      if ($prop.Name -like 'X_Cell_Site_*') {
        $merged[$prop.Name] = $prop.Value
        $mergedSources[$prop.Name] = $siteProvider
        $overridden++
      }
    }
    Write-Host ("  site fields sourced from '{0}' ({1} field(s))" -f $siteProvider, $overridden)
  } else {
    Write-Warning "Site provider module '$siteProvider' was not among the merged modules; site fields left as first-wins."
    $warnings++
  }
}

# ---------------------------------------------------------------------------
# Assemble & write
# ---------------------------------------------------------------------------

$result = [ordered]@{}
foreach ($key in $merged.Keys) { $result[$key] = $merged[$key] }
$result['InputTables'] = $tables.ToArray()

$json = ConvertTo-TabJson -Value $result -Indent 0

$cellTotal = ($merged.Keys | Measure-Object).Count
Write-Host ("Enterprise '{0}': {1} cell(s), {2} table(s)." -f $enterpriseId, $cellTotal, $tables.Count)

if ($DryRun) {
  Write-Host ("[DryRun] Would write: {0}" -f $OutputPath)
} else {
  $outDir = Split-Path -Parent $OutputPath
  if (-not [string]::IsNullOrWhiteSpace($outDir) -and -not (Test-Path -LiteralPath $outDir)) {
    New-Item -ItemType Directory -Path $outDir -Force | Out-Null
  }
  $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
  [System.IO.File]::WriteAllText($OutputPath, $json, $utf8NoBom)
  Write-Host ("Wrote: {0}" -f $OutputPath)
}

if ($warnings -gt 0) {
  Write-Host ("Done with {0} warning(s)." -f $warnings)
} else {
  Write-Host 'Done.'
}
