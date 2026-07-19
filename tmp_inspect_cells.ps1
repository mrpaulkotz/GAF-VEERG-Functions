$ErrorActionPreference = 'Stop'
$path = 'C:\htdocs\zneagcrc\GAF-VEERG-Functions\Excel\Enterprises\Enterprise_PastureBeef_Template_WIP_v01.xlsx'
$x = New-Object -ComObject Excel.Application
$x.Visible = $false; $x.DisplayAlerts = $false
try {
  $wb = $x.Workbooks.Open($path, $false, $true)  # ReadOnly
  $ws = $wb.Worksheets.Item('Input - Enterprise')
  foreach ($addr in @('E20','E21','E22','E23','E24','E25','E26')) {
    $c = $ws.Range($addr)
    $v2 = $c.Value2
    $t = if ($null -eq $v2) { '<null>' } else { $v2.GetType().Name }
    $pfx = ''
    try { $pfx = [string]$c.PrefixCharacter } catch { $pfx = '<err>' }
    $hf = ''
    try { $hf = [string]$c.HasFormula } catch { $hf = '<err>' }
    $fm = ''
    try { $fm = [string]$c.Formula } catch { $fm = '<err>' }
    Write-Host ("{0} | type={1} | HasFormula={2} | Prefix='{3}' | Value2=[{4}] | Formula=[{5}]" -f $addr, $t, $hf, $pfx, $v2, $fm)
  }
  $wb.Close($false)
} finally {
  $x.Quit()
  [System.Runtime.InteropServices.Marshal]::ReleaseComObject($x) | Out-Null
}
