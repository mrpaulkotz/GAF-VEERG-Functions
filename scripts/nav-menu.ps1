# ===========================================================================
# Shared left-hand navigation-menu generator (column A of every sheet).
# Dot-sourced by build-enterprise-excel.ps1, build-scope3-excel.ps1, and any
# other workbook assembler that wants the same menu. COM-based: the caller
# passes an open Excel workbook plus a sheet -> category map.
# ===========================================================================

# ---------------------------------------------------------------------------
# Navigation menu generation (column A of every sheet)
# ---------------------------------------------------------------------------
# Rebuilds the left-hand navigation menu on every worksheet from the final
# sheet set, so it always matches the assembled workbook. Layout mirrors the
# source workbooks:
#   A1              logo (in-cell image, style 'Input page heading') - preserved
#   A3..            untitled group (Home, Results) - no title
#   (blank) INPUTS  title + one link per input sheet
#   (blank) CALC..  title + one link per equation sheet
#   (blank) APPEND. title + one link per appendix sheet
# Each link is =HYPERLINK("#'Sheet'!A1","Label"). The link to the sheet the menu
# is drawn on uses that group's 'selected' style; all others use the default.
# Column A is frozen (panes split at B1) on every sheet so the menu stays
# visible while the user scrolls.
function Set-NavMenu {
  param(
    $Target,        # target workbook COM object
    [hashtable] $CategoryMap,  # sheet name -> category (input|calculation|constants|common|custom)
    [hashtable] $Labels        # sheet name -> friendly menu label (override; else derived)
  )

  if ($null -eq $CategoryMap) { $CategoryMap = @{} }
  if ($null -eq $Labels) { $Labels = @{} }

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
    if ($name -eq 'Home' -or $name -eq 'Overview' -or $name -like 'Results*') { return 'untitled' }
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
  # Untitled group always leads with Home, then Overview, then any Results* sheets
  # (in tab order among themselves).
  $ut = @()
  foreach ($x in @('Home', 'Overview')) { if ($members['untitled'] -contains $x) { $ut += $x } }
  foreach ($x in $members['untitled']) { if ($x -like 'Results*' -and $ut -notcontains $x) { $ut += $x } }
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

    # Fix the menu column's width so labels are not clipped.
    try { $ws.Columns.Item(1).ColumnWidth = 36 } catch { }

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

    # Freeze column A (the nav menu) so it stays visible when the user scrolls.
    try {
      $ws.Activate()
      $ws.Range('B1').Select() | Out-Null
      $Target.Windows.Item(1).FreezePanes = $true
    } catch { Write-Warning ("Menu: could not freeze column A on '{0}': {1}" -f $sn, $_.Exception.Message) }

    $updated++
  }

  return $updated
}

# ---------------------------------------------------------------------------
# Category inference for workbooks that have no explicit sheet->category map
# (e.g. hand-authored chapter workbooks). Uses the standard VEERG tab-naming
# conventions; only the calculation/appendix split actually affects the menu.
#   'Input - *' / 'Input*'          -> input
#   'Constants - *' / 'Constants*'  -> constants
#   tab beginning with a digit code -> calculation  (e.g. '8.1.1.1-2 Transport fuel')
#   'Calc*' / 'Calcs - *'           -> calculation  (e.g. 'Calcs - manure sent off-site')
#   Home / Overview / Results       -> untitled (handled by name in Set-NavMenu)
#   anything else                   -> appendices (via the map returning nothing)
# Returns a hashtable sheetName -> category.
function Get-InferredCategoryMap {
  param($Workbook)
  $map = @{}
  foreach ($ws in $Workbook.Worksheets) {
    $n = [string] $ws.Name
    $cat = $null
    if ($n -match '^(?i)input\b' -or $n -like 'Input*') { $cat = 'input' }
    elseif ($n -match '^(?i)constants\b' -or $n -like 'Constants*') { $cat = 'constants' }
    elseif ($n -match '^\s*\d' -or $n -like 'Calc*') { $cat = 'calculation' }
    if ($null -ne $cat) { $map[$n] = $cat }
  }
  return $map
}
