<#
.SYNOPSIS
  Rewrite raw cross-sheet cell references so they route through workbook-scoped
  named ranges ("link killer").

.DESCRIPTION
  When the enterprise builder copies a worksheet one-at-a-time, any raw
  cross-sheet reference (e.g. ='4.2.1.1-2 Methane'!E84) is externalised to
  ='[book.xlsx]4.2.1.1-2 Methane'!E84 and left as a dangling external link that
  cannot be re-pointed with ChangeLink (that crashes Excel).

  This script eliminates those links at the source. For every cell whose formula
  is a PURE single cross-sheet cell reference (e.g. ='Sheet'!$C$R) whose target
  cell falls inside a workbook-scoped named range on that target sheet, it
  rewrites the formula to reference the NAME instead:

      ='4.2.1.1-2 Methane'!E84   ->   =INDEX(M1_Table_I_j_k_l, 2, 2)

  If the smallest containing name is a single cell that exactly equals the
  target, it rewrites to  =Name  directly.

  Because the reference now goes through a workbook-scoped name, a single-sheet
  copy no longer externalises the cell formula: the external link (if any) lands
  in the NAME's RefersTo, which the enterprise importer already re-links to the
  local sheet. Cell layout, headers, formatting and computed values are
  unchanged.

  Cross-sheet references whose target is NOT inside any named range (e.g. raw
  'Input - Pasture Beef'!H110 input pulls) are left untouched and reported as
  "unhandled" so they can be addressed separately.

  Runs read-only by default; pass -Commit to write and save (a one-time
  *.prelink.bak.xlsx backup is created before the first save).

.PARAMETER WorkbookPath
  Full path to the .xlsx. Defaults to the latest pasture-beef manure workbook.

.PARAMETER Commit
  Actually rewrite formulas and save. Without it, reports the plan only.
#>
param(
  [string] $RepoRoot = (Split-Path $PSScriptRoot -Parent),
  [string] $WorkbookPath,
  [switch] $Commit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
function Resolve-Workbook {
  param([string] $RepoRoot, [string] $WorkbookPath)
  if (-not [string]::IsNullOrWhiteSpace($WorkbookPath)) {
    if (-not (Test-Path -LiteralPath $WorkbookPath)) { throw "Workbook not found: $WorkbookPath" }
    return (Resolve-Path -LiteralPath $WorkbookPath).Path
  }
  $excelDir = Join-Path $RepoRoot 'Excel'
  $candidates = Get-ChildItem -LiteralPath $excelDir -Filter '4_2_ManureManagement_BeefPasture_WIP_v*.xlsx' -File |
    Sort-Object { if ($_.BaseName -match '_v(\d+)$') { [int] $Matches[1] } else { 0 } } -Descending
  if (-not $candidates -or @($candidates).Count -eq 0) { throw "No pasture-beef manure workbook found in $excelDir" }
  return $candidates[0].FullName
}

function ConvertTo-ColNum {
  param([string] $Letters)
  $n = 0
  foreach ($ch in $Letters.ToUpperInvariant().ToCharArray()) {
    $n = $n * 26 + ([int][char] $ch - 64)
  }
  return $n
}

# ---------------------------------------------------------------------------
# Regexes.
#   Cell formula that is a single cross-sheet cell reference:
#     ='Sheet Name'!$C$R   or   =SheetName!C$R  (any $ combination)
$reCellRef = "^=(?:'([^']+)'|([A-Za-z0-9_.]+))!\`$?([A-Z]{1,3})\`$?(\d{1,7})$"
#   Cell formula that is a single cross-sheet RANGE reference:
$reRangeRef = "^=(?:'([^']+)'|([A-Za-z0-9_.]+))!\`$?([A-Z]{1,3})\`$?(\d{1,7}):\`$?([A-Z]{1,3})\`$?(\d{1,7})$"

# ---------------------------------------------------------------------------
$resolved = Resolve-Workbook -RepoRoot $RepoRoot -WorkbookPath $WorkbookPath
Write-Host ("Workbook : {0}" -f $resolved)
Write-Host ("Mode     : {0}" -f ($(if ($Commit) { 'COMMIT' } else { 'DRY-RUN' })))
Write-Host ''

$excel = $null
$wb = $null
try {
  $excel = New-Object -ComObject Excel.Application
  $excel.Visible = $false
  $excel.DisplayAlerts = $false
  $excel.AskToUpdateLinks = $false
  $excel.ScreenUpdating = $false

  $readOnly = -not $Commit
  $wb = $excel.Workbooks.Open($resolved, 0, $readOnly)

  # -- Build a lookup of named single-area ranges: sheet -> list of rectangles.
  Write-Host 'Indexing named ranges...'
  $namedRanges = New-Object System.Collections.Generic.List[object]
  foreach ($n in $wb.Names) {
    $rr = $null
    try { $rr = $n.RefersToRange } catch { continue }
    if ($null -eq $rr) { continue }
    try {
      if ($rr.Areas.Count -ne 1) { continue }
      $top = [int] $rr.Row
      $left = [int] $rr.Column
      $h = [int] $rr.Rows.Count
      $w = [int] $rr.Columns.Count
    } catch { continue }
    $area = $h * $w
    if ($area -gt 100000) { continue }   # skip whole-column / whole-row names
    $namedRanges.Add([pscustomobject]@{
      Name = [string] $n.Name
      Sheet = [string] $rr.Worksheet.Name
      Top = $top; Left = $left; Bottom = ($top + $h - 1); Right = ($left + $w - 1)
      Area = $area
    })
  }
  Write-Host ("  indexed {0} single-area named ranges" -f $namedRanges.Count)

  # Group by sheet for faster containment lookup.
  $bySheet = @{}
  foreach ($nr in $namedRanges) {
    if (-not $bySheet.ContainsKey($nr.Sheet)) { $bySheet[$nr.Sheet] = New-Object System.Collections.Generic.List[object] }
    $bySheet[$nr.Sheet].Add($nr)
  }

  function Resolve-Containing {
    param([hashtable] $BySheet, [string] $Sheet, [int] $Row, [int] $Col)
    if (-not $BySheet.ContainsKey($Sheet)) { return $null }
    $best = $null
    foreach ($nr in $BySheet[$Sheet]) {
      if ($Row -ge $nr.Top -and $Row -le $nr.Bottom -and $Col -ge $nr.Left -and $Col -le $nr.Right) {
        if ($null -eq $best -or $nr.Area -lt $best.Area) { $best = $nr }
      }
    }
    return $best
  }

  # -- Scan every worksheet's used range for pure cross-sheet cell references.
  $plan = New-Object System.Collections.Generic.List[object]
  $unhandled = New-Object System.Collections.Generic.List[object]

  foreach ($ws in $wb.Worksheets) {
    $sheetName = [string] $ws.Name
    $ur = $ws.UsedRange
    $r0 = [int] $ur.Row
    $c0 = [int] $ur.Column
    $nRows = [int] $ur.Rows.Count
    $nCols = [int] $ur.Columns.Count
    if ($nRows -lt 1 -or $nCols -lt 1) { continue }

    $formulas = $ur.Formula
    $isScalar = ($nRows -eq 1 -and $nCols -eq 1)

    for ($i = 1; $i -le $nRows; $i++) {
      for ($j = 1; $j -le $nCols; $j++) {
        $f = if ($isScalar) { $formulas } else { $formulas.GetValue($i, $j) }
        if ($f -isnot [string]) { continue }
        if ($f.Length -lt 2 -or $f[0] -ne '=' -or -not $f.Contains('!')) { continue }

        $row = $r0 + $i - 1
        $col = $c0 + $j - 1

        $m = [regex]::Match($f, $reCellRef)
        if ($m.Success) {
          $tgtSheet = if ($m.Groups[1].Success) { $m.Groups[1].Value } else { $m.Groups[2].Value }
          $tgtCol = ConvertTo-ColNum $m.Groups[3].Value
          $tgtRow = [int] $m.Groups[4].Value
          if ($tgtSheet -eq $sheetName) { continue }   # same-sheet qualified ref: no external link

          $nr = Resolve-Containing -BySheet $bySheet -Sheet $tgtSheet -Row $tgtRow -Col $tgtCol
          if ($null -eq $nr) {
            $unhandled.Add([pscustomobject]@{ Sheet = $sheetName; Cell = "R${row}C${col}"; Target = $tgtSheet; Formula = $f })
            continue
          }
          $relRow = $tgtRow - $nr.Top + 1
          $relCol = $tgtCol - $nr.Left + 1
          if ($nr.Area -eq 1) {
            $newF = "=$($nr.Name)"
          } else {
            $newF = "=INDEX($($nr.Name),$relRow,$relCol)"
          }
          $plan.Add([pscustomobject]@{
            Sheet = $sheetName; Row = $row; Col = $col
            Old = $f; New = $newF; Name = $nr.Name; Kind = 'cell'
          })
          continue
        }

        $mr = [regex]::Match($f, $reRangeRef)
        if ($mr.Success) {
          $tgtSheet = if ($mr.Groups[1].Success) { $mr.Groups[1].Value } else { $mr.Groups[2].Value }
          if ($tgtSheet -eq $sheetName) { continue }
          $t = ConvertTo-ColNum $mr.Groups[3].Value; $tr = [int] $mr.Groups[4].Value
          $b = ConvertTo-ColNum $mr.Groups[5].Value; $br = [int] $mr.Groups[6].Value
          # Match an exact named range rectangle on the target sheet.
          $exact = $null
          if ($bySheet.ContainsKey($tgtSheet)) {
            foreach ($nr in $bySheet[$tgtSheet]) {
              if ($nr.Top -eq $tr -and $nr.Left -eq $t -and $nr.Bottom -eq $br -and $nr.Right -eq $b) { $exact = $nr; break }
            }
          }
          if ($null -eq $exact) {
            $unhandled.Add([pscustomobject]@{ Sheet = $sheetName; Cell = "R${row}C${col}"; Target = $tgtSheet; Formula = $f })
            continue
          }
          $plan.Add([pscustomobject]@{
            Sheet = $sheetName; Row = $row; Col = $col
            Old = $f; New = "=$($exact.Name)"; Name = $exact.Name; Kind = 'range'
          })
          continue
        }

        # Formula contains '!' but is not a pure single reference.
        $unhandled.Add([pscustomobject]@{ Sheet = $sheetName; Cell = "R${row}C${col}"; Target = '(mixed)'; Formula = $f })
      }
    }
  }

  # -- Report -----------------------------------------------------------------
  Write-Host ''
  Write-Host ("Rewrite plan ({0} cells):" -f $plan.Count)
  foreach ($grp in ($plan | Group-Object Sheet | Sort-Object Name)) {
    Write-Host ("  {0}: {1} cells" -f $grp.Name, $grp.Count)
    foreach ($nameGrp in ($grp.Group | Group-Object Name | Sort-Object Name)) {
      Write-Host ("      -> {0,-28} x{1}" -f $nameGrp.Name, $nameGrp.Count)
    }
  }

  Write-Host ''
  Write-Host ("Unhandled cross-sheet formulas ({0} cells):" -f $unhandled.Count)
  foreach ($grp in ($unhandled | Group-Object Target | Sort-Object Name)) {
    Write-Host ("  target '{0}': {1} cells" -f $grp.Name, $grp.Count)
    $sample = @($grp.Group)[0]
    Write-Host ("      e.g. {0}!{1}: {2}" -f $sample.Sheet, $sample.Cell, $sample.Formula)
  }

  # -- Commit -----------------------------------------------------------------
  $written = 0; $failed = 0
  if ($Commit -and $plan.Count -gt 0) {
    $bak = [System.IO.Path]::ChangeExtension($resolved, $null).TrimEnd('.') + '.prelink.bak.xlsx'
    if (-not (Test-Path -LiteralPath $bak)) {
      Copy-Item -LiteralPath $resolved -Destination $bak
      Write-Host ''
      Write-Host ("Backup created: {0}" -f $bak)
    }
    foreach ($p in $plan) {
      try {
        $ws = $wb.Worksheets.Item($p.Sheet)
        $ws.Cells.Item($p.Row, $p.Col).Formula = $p.New
        $written++
      } catch {
        $failed++
        Write-Warning ("Failed R{0}C{1} on '{2}': {3}" -f $p.Row, $p.Col, $p.Sheet, $_.Exception.Message)
      }
    }
    if ($written -gt 0) { $wb.Save() }
  }

  # -- Summary ----------------------------------------------------------------
  Write-Host ''
  Write-Host '===================== Summary ====================='
  Write-Host ("Rewrites planned  : {0}" -f $plan.Count)
  Write-Host ("Unhandled refs    : {0}" -f $unhandled.Count)
  if ($Commit) {
    Write-Host ("Rewrites written  : {0}" -f $written)
    Write-Host ("Rewrites failed   : {0}" -f $failed)
  } else {
    Write-Host '(dry-run: nothing written; re-run with -Commit to apply)'
  }
  Write-Host '==================================================='
}
finally {
  if ($null -ne $wb) { try { $wb.Close($false) } catch { } }
  if ($null -ne $excel) {
    try { $excel.Quit() } catch { }
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel)
  }
}
