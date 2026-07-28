$ErrorActionPreference = 'Stop'
$src = 'C:\htdocs\zneagcrc\GAF-VEERG-Functions\Excel\10_SolidWaste_WIP_v02.xlsx'
$out = 'C:\htdocs\zneagcrc\GAF-VEERG-Functions\Excel\13_Scope3_WIP_v13.xlsx'
$sheet = 'Input - Solid waste'

$x = New-Object -ComObject Excel.Application
$x.Visible = $false; $x.DisplayAlerts = $false; $x.AskToUpdateLinks = $false
try {
  $ws = $x.Workbooks.Open($src, 0, $true).Worksheets.Item($sheet)
  $wo = $x.Workbooks.Open($out, 0, $true).Worksheets.Item($sheet)

  $ur = $ws.UsedRange
  $rows = $ur.Rows.Count; $cols = $ur.Columns.Count
  $r0 = $ur.Row; $c0 = $ur.Column
  Write-Host ("Source used range: {0} rows x {1} cols starting R{2}C{3}" -f $rows, $cols, $r0, $c0)
  $uo = $wo.UsedRange
  Write-Host ("Output used range: {0} rows x {1} cols starting R{2}C{3}" -f $uo.Rows.Count, $uo.Columns.Count, $uo.Row, $uo.Column)

  $diffs = 0; $shown = 0
  for ($i = 0; $i -lt $rows; $i++) {
    for ($j = 0; $j -lt $cols; $j++) {
      $rr = $r0 + $i; $cc = $c0 + $j
      $sf = [string]$ws.Cells.Item($rr, $cc).Formula
      $of = [string]$wo.Cells.Item($rr, $cc).Formula
      if ($sf -ne $of) {
        $diffs++
        if ($shown -lt 40) {
          $addr = $ws.Cells.Item($rr, $cc).Address($false, $false)
          Write-Host ("DIFF {0}:" -f $addr)
          Write-Host ("   src: {0}" -f $sf)
          Write-Host ("   out: {0}" -f $of)
          $shown++
        }
      }
    }
  }
  Write-Host ("`nTotal differing cells (formula): {0}" -f $diffs)
} finally { $x.Quit(); [System.Runtime.InteropServices.Marshal]::ReleaseComObject($x) | Out-Null }
