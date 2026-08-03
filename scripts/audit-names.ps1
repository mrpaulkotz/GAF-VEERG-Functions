<#
.SYNOPSIS
  Audit (and optionally clean up) defined-name hygiene issues in VEERG workbooks.

.DESCRIPTION
  Scans every defined name (workbook-scoped and sheet-local) in each target
  workbook and classifies it into issue categories:

    [dangling]  RefersTo is a plain reference (no function call) that resolves to
                an Excel error, e.g. =#REF!#REF!, ='Sheet'!#REF!, =#NAME?.
                -> Pure cruft. DELETED on -Commit.

    [broken-fn] RefersTo is a formula / LAMBDA that CONTAINS an error, e.g.
                =LAMBDA(..., FILTER(#REF!#REF!, ...)). These are real functions
                (Excel-Labs named functions maintained in the .xlf source) with
                broken internal references. -> REPORTED, never auto-deleted.

    [external]  RefersTo points at another workbook, e.g. =[Book1.xlsx]Sheet!$A$1.
                -> REPORTED; DELETED only if -RemoveExternal is given.

    [empty]     RefersTo is empty / missing. -> REPORTED.

    [hidden]    Name.Visible = False (often add-in / import cruft).
                -> REPORTED; DELETED only if -RemoveHidden is given.

    [dup]       Two or more names point at the SAME target cell/range.
                -> REPORTED (needs human judgement; never auto-deleted).

  Any formulas that reference a name being DELETED are reported first so you can
  see the impact.

  This is a STANDALONE maintenance script: run it whenever you like (e.g. after
  `npm run build-enterprise`). It runs on ALL top-level Excel/*.xlsx workbooks by
  default; pass -WorkbookPath to target a single workbook.

  DRY-RUN by default: issues are reported but nothing is written. Pass -Commit to
  apply deletions and save. Add -Backup to also write a one-time backup under
  Excel/Backups/Backup_PreAudit/ before saving.

.PARAMETER WorkbookPath
  Full path to a single .xlsx to process. If omitted, every top-level
  Excel/*.xlsx (excluding lock files, *_expanded* and *.bak backups) is processed.

.PARAMETER Commit
  Actually delete the flagged names and save. Without it, reports only.

.PARAMETER RemoveExternal
  Also delete [external] workbook-link names (on -Commit).

.PARAMETER RemoveHidden
  Also delete [hidden] names (on -Commit).

.PARAMETER Backup
  When saving (-Commit), first write a one-time backup copy of the workbook
  under Excel/Backups/Backup_PreAudit/. Off by default.
#>
param(
  [string] $RepoRoot = (Split-Path $PSScriptRoot -Parent),
  [string] $WorkbookPath,
  [switch] $Commit,
  [switch] $RemoveExternal,
  [switch] $RemoveHidden,
  [switch] $Backup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Excel error tokens that can appear in a name's RefersTo.
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
  Get-ChildItem -LiteralPath $excelDir -Filter '*.xlsx' -File |
    Where-Object { $_.Name -notlike '~$*' -and $_.BaseName -notmatch '(?i)_expanded' -and $_.Name -notmatch '(?i)\.bak' } |
    Sort-Object FullName |
    ForEach-Object { $_.FullName }
}

# ---------------------------------------------------------------------------
# Classify a single defined name.
#   Returns @{ Name; RefersTo; Category; Hidden; Delete }
# ---------------------------------------------------------------------------
function Get-NameIssue {
  param([string] $Name, [string] $RefersTo, [bool] $Visible,
        [switch] $RemoveExternal, [switch] $RemoveHidden)

  $rt = if ($null -eq $RefersTo) { '' } else { $RefersTo }
  $hasFormula = ($rt.IndexOf('(') -ge 0)
  $hasError = $script:ErrorRegex.IsMatch($rt)
  # Real external links are PLAIN references to another workbook FILE, e.g.
  # =[Budget.xlsx]Sheet1!$A$1. Square brackets inside a formula are LAMBDA
  # optional params ([Arg]), string literals or table refs (Table[Col]) - not
  # external links, so require a non-formula ref that names a workbook file.
  $isExternal = (-not $hasFormula) -and [regex]::IsMatch($rt, '\[[^\]]*\.xls[a-z]{0,2}\]', 'IgnoreCase')
  $isEmpty = [string]::IsNullOrWhiteSpace($rt) -or ($rt -replace '^\s*=\s*', '') -eq ''

  $category = $null
  $delete = $false
  if ($hasError -and -not $hasFormula) { $category = 'dangling'; $delete = $true }
  elseif ($hasError -and $hasFormula) { $category = 'broken-fn'; $delete = $false }
  elseif ($isExternal) { $category = 'external'; $delete = [bool] $RemoveExternal }
  elseif ($isEmpty) { $category = 'empty'; $delete = $false }
  elseif (-not $Visible) { $category = 'hidden'; $delete = [bool] $RemoveHidden }

  if ($null -eq $category) { return $null }
  return [pscustomobject]@{ Name = $Name; RefersTo = $rt; Category = $category; Hidden = (-not $Visible); Delete = $delete }
}

# ---------------------------------------------------------------------------
# Process a single workbook.
# ---------------------------------------------------------------------------
function Invoke-Workbook {
  param($Excel, [string] $Path, [switch] $Commit, [switch] $RemoveExternal, [switch] $RemoveHidden)

  Write-Host ''
  Write-Host ('=' * 78)
  Write-Host ("Workbook : {0}" -f (Split-Path $Path -Leaf))

  $wb = $Excel.Workbooks.Open($Path, 0, $false)   # read-write; we control saving
  $counts = @{ dangling = 0; 'broken-fn' = 0; external = 0; empty = 0; hidden = 0; dup = 0 }
  $removed = 0

  try {
    # ---- Snapshot names (deleting while iterating live COM is unsafe). ---
    $names = New-Object System.Collections.Generic.List[object]
    foreach ($n in $wb.Names) {
      $name = $null; $refersTo = $null; $visible = $true
      try { $name = [string] $n.Name; $refersTo = [string] $n.RefersTo } catch { continue }
      try { $visible = [bool] $n.Visible } catch { $visible = $true }
      if ([string]::IsNullOrWhiteSpace($name)) { continue }
      # Skip Excel-internal names. The '_xl' prefix is reserved by Excel for
      # engine-managed names: LAMBDA required/optional parameter placeholders
      # (_xlpm.*, _xlop.*), future-function / worksheet shims (_xlfn.*, _xlws.*)
      # and built-ins (_xlnm.Print_Area etc.). These are not user cruft.
      if ($name -match '(?i)^_xl') { continue }
      $names.Add([pscustomobject]@{ Name = $name; RefersTo = $refersTo; Visible = $visible })
    }

    # ---- Classify. ------------------------------------------------------
    $issues = New-Object System.Collections.Generic.List[object]
    foreach ($nm in $names) {
      $iss = Get-NameIssue -Name $nm.Name -RefersTo $nm.RefersTo -Visible $nm.Visible -RemoveExternal:$RemoveExternal -RemoveHidden:$RemoveHidden
      if ($null -ne $iss) { $issues.Add($iss) }
    }

    # ---- Duplicate targets (valid plain refs sharing a RefersTo). -------
    $byTarget = @{}
    foreach ($nm in $names) {
      $rt = if ($null -eq $nm.RefersTo) { '' } else { $nm.RefersTo }
      if ($rt.IndexOf('(') -ge 0) { continue }              # skip formulas/LAMBDAs
      if ($script:ErrorRegex.IsMatch($rt)) { continue }     # skip errors
      if ([string]::IsNullOrWhiteSpace($rt)) { continue }
      $key = ($rt -replace '\s', '')
      if (-not $byTarget.ContainsKey($key)) { $byTarget[$key] = New-Object System.Collections.Generic.List[string] }
      $byTarget[$key].Add($nm.Name)
    }

    if ($issues.Count -eq 0 -and -not ($byTarget.Values | Where-Object { $_.Count -gt 1 })) {
      Write-Host '  No name issues found.' -ForegroundColor DarkGray
      return [pscustomobject]@{ Counts = $counts; Removed = 0; ToDelete = 0 }
    }

    # ---- Report which formulas reference a name we will DELETE. ---------
    $toDeleteBare = @{}
    foreach ($iss in $issues) {
      if (-not $iss.Delete) { continue }
      $bare = $iss.Name
      $bang = $bare.IndexOf('!')
      if ($bang -ge 0) { $bare = $bare.Substring($bang + 1) }
      if (-not [string]::IsNullOrWhiteSpace($bare)) { $toDeleteBare[$bare] = $iss.Name }
    }
    if ($toDeleteBare.Count -gt 0) {
      foreach ($ws in $wb.Worksheets) {
        $ur = $null
        try { $ur = $ws.UsedRange } catch { continue }
        if ($null -eq $ur) { continue }
        $data = $ur.Formula
        $rows = [int] $ur.Rows.Count; $cols = [int] $ur.Columns.Count
        $baseRow = [int] $ur.Row; $baseCol = [int] $ur.Column
        for ($r = 1; $r -le $rows; $r++) {
          for ($c = 1; $c -le $cols; $c++) {
            $f = if ($rows -eq 1 -and $cols -eq 1) { [string] $data } else { [string] $data.GetValue($r, $c) }
            if ([string]::IsNullOrWhiteSpace($f) -or $f[0] -ne '=') { continue }
            foreach ($bare in $toDeleteBare.Keys) {
              if ($f -match ('(?<![A-Za-z0-9_.])' + [regex]::Escape($bare) + '(?![A-Za-z0-9_.])')) {
                $addr = $ws.Cells.Item($baseRow + $r - 1, $baseCol + $c - 1).Address($false, $false)
                Write-Host ("  [used]  '{0}' referenced by {1}!{2}: {3}" -f $bare, $ws.Name, $addr, $f) -ForegroundColor DarkYellow
              }
            }
          }
        }
      }
    }

    # ---- Report issues by category. ------------------------------------
    foreach ($iss in ($issues | Sort-Object Category, Name)) {
      $counts[$iss.Category]++
      $tag = $iss.Category
      $verb = if ($iss.Delete) { if ($Commit) { 'delete' } else { 'DELETE' } } else { 'keep' }
      $colour = switch ($iss.Category) {
        'dangling'  { 'Cyan' }
        'broken-fn' { 'DarkYellow' }
        'external'  { if ($iss.Delete) { 'Cyan' } else { 'Yellow' } }
        'hidden'    { if ($iss.Delete) { 'Cyan' } else { 'DarkGray' } }
        default     { 'Gray' }
      }
      Write-Host ("  [{0,-9}] ({1}) '{2}'  ->  {3}" -f $tag, $verb, $iss.Name, $iss.RefersTo) -ForegroundColor $colour
    }

    # ---- Report duplicate-target clusters. -----------------------------
    foreach ($key in ($byTarget.Keys | Sort-Object)) {
      $group = $byTarget[$key]
      if ($group.Count -le 1) { continue }
      $counts['dup']++
      Write-Host ("  [dup      ] {0} names share target {1}: {2}" -f $group.Count, $key, ($group -join ', ')) -ForegroundColor Magenta
    }

    # ---- Delete flagged names (commit only). ---------------------------
    if ($Commit) {
      foreach ($iss in $issues) {
        if (-not $iss.Delete) { continue }
        try { $wb.Names.Item($iss.Name).Delete(); $removed++ }
        catch { Write-Host ("  [ERR]   could not delete '{0}': {1}" -f $iss.Name, $_.Exception.Message) -ForegroundColor Red }
      }
    }

    $delCandidates = @($issues | Where-Object { $_.Delete }).Count
    Write-Host ('  Summary: ' +
      ("dangling={0} broken-fn={1} external={2} empty={3} hidden={4} dup={5}" -f `
        $counts['dangling'], $counts['broken-fn'], $counts['external'], $counts['empty'], $counts['hidden'], $counts['dup']) +
      ("  |  {0} {1}" -f $(if ($Commit) { $removed } else { $delCandidates }), $(if ($Commit) { 'deleted' } else { 'to delete' })))

    # ---- Save (commit only). -------------------------------------------
    if ($Commit -and $removed -gt 0) {
      if ($Backup) {
        $backupDir = [IO.Path]::Combine((Split-Path $Path -Parent), 'Backups', 'Backup_PreAudit')
        if (-not (Test-Path -LiteralPath $backupDir)) {
          New-Item -ItemType Directory -Path $backupDir -Force | Out-Null
        }
        $bak = [IO.Path]::Combine($backupDir, [IO.Path]::GetFileName($Path))
        if (-not (Test-Path -LiteralPath $bak)) {
          Copy-Item -LiteralPath $Path -Destination $bak -Force
          Write-Host ("  Backup : {0}" -f (Join-Path 'Backups\Backup_PreAudit' (Split-Path $bak -Leaf))) -ForegroundColor DarkGray
        }
      }
      $wb.Save()
      Write-Host '  Saved.' -ForegroundColor Green
    }

    return [pscustomobject]@{ Counts = $counts; Removed = $removed; ToDelete = $delCandidates }
  }
  finally {
    try { $wb.Close($false) } catch { }
    if ($null -ne $wb) { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($wb) }
  }
}

# ---------------------------------------------------------------------------
# Main.
# ---------------------------------------------------------------------------
$workbooks = @(Get-TargetWorkbooks -RepoRoot $RepoRoot -WorkbookPath $WorkbookPath)
Write-Host ("Mode      : {0}" -f ($(if ($Commit) { 'COMMIT' } else { 'DRY-RUN (no files written)' })))
Write-Host ("Workbooks : {0}" -f $workbooks.Count)
Write-Host ("Options   : RemoveExternal={0} RemoveHidden={1}" -f [bool]$RemoveExternal, [bool]$RemoveHidden)

$excel = $null
$grand = @{ dangling = 0; 'broken-fn' = 0; external = 0; empty = 0; hidden = 0; dup = 0 }
$totRemoved = 0
$totToDelete = 0
try {
  $excel = New-Object -ComObject Excel.Application
  $excel.Visible = $false
  $excel.DisplayAlerts = $false
  $excel.AskToUpdateLinks = $false
  $excel.ScreenUpdating = $false

  foreach ($path in $workbooks) {
    try {
      $res = Invoke-Workbook -Excel $excel -Path $path -Commit:$Commit -RemoveExternal:$RemoveExternal -RemoveHidden:$RemoveHidden
      foreach ($k in @($grand.Keys)) { $grand[$k] += [int] $res.Counts[$k] }
      $totRemoved += $res.Removed
      $totToDelete += $res.ToDelete
    } catch {
      Write-Host ("  [FATAL] {0}: {1}" -f (Split-Path $path -Leaf), $_.Exception.Message) -ForegroundColor Red
      # Recreate Excel in case the COM server crashed.
      try { $excel.Quit() } catch { }
      try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel) } catch { }
      $excel = New-Object -ComObject Excel.Application
      $excel.Visible = $false
      $excel.DisplayAlerts = $false
      $excel.AskToUpdateLinks = $false
      $excel.ScreenUpdating = $false
    }
  }
}
finally {
  if ($null -ne $excel) {
    try { $excel.Quit() } catch { }
    try { [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel) } catch { }
  }
  [System.GC]::Collect()
  [System.GC]::WaitForPendingFinalizers()
}

Write-Host ''
Write-Host ('=' * 78)
Write-Host ("TOTAL: dangling={0} broken-fn={1} external={2} empty={3} hidden={4} dup={5}  |  {6} name(s) {7} across {8} workbook(s)." -f `
    $grand['dangling'], $grand['broken-fn'], $grand['external'], $grand['empty'], $grand['hidden'], $grand['dup'], `
    $(if ($Commit) { $totRemoved } else { $totToDelete }), ($(if ($Commit) { 'deleted' } else { 'flagged for deletion' })), $workbooks.Count)
if (-not $Commit) { Write-Host 'DRY-RUN: nothing was written. Re-run with -Commit to apply.' -ForegroundColor Yellow }
