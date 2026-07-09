Set-StrictMode -Off
Get-Process EXCEL -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Milliseconds 800
$excel = New-Object -ComObject Excel.Application
$excel.Visible=$false; $excel.DisplayAlerts=$false; $excel.AskToUpdateLinks=$false
$out='C:\htdocs\zneagcrc\GAF-VEERG-Functions\Excel\Enterprises\Enterprise_PastureBeef_WIP_v01.xlsx'
$bak='C:\htdocs\zneagcrc\GAF-VEERG-Functions\Excel\Enterprises\Enterprise_PastureBeef_WIP_v01.bak.xlsx'

$outWb=$excel.Workbooks.Open($out,0,$true)   # read-only source (fixed Results)
$bakWb=$excel.Workbooks.Open($bak,0,$false)  # writable template

# 1. delete stale Results in template
$bakWb.Worksheets('Results').Delete()

# 2. copy fixed Results from OUT into BAK, after Home
$home = $bakWb.Worksheets('Home')
$outWb.Worksheets('Results').Copy([System.Reflection.Missing]::Value, $home)

# ensure it is named 'Results'
$newWs = $bakWb.Worksheets.Item($bakWb.Worksheets.Count)
if ($newWs.Name -ne 'Results') { $newWs.Name = 'Results' }

# 3. break any external links introduced by the cross-workbook copy
$links = $bakWb.LinkSources(1)   # xlExcelLinks
$broken=0
if ($links) { foreach($l in @($links)){ try { $bakWb.BreakLink($l,1); $broken++ } catch {} } }
Write-Host ("External links broken in BAK: {0}" -f $broken)

# 4. verify error cells in new Results
$ws=$bakWb.Worksheets('Results'); $ur=$ws.UsedRange; $v=$ur.Value2; $refc=0
if ($v -is [System.Array]) { for($i=1;$i -le $v.GetLength(0);$i++){for($j=1;$j -le $v.GetLength(1);$j++){ $cv=$v.GetValue($i,$j); if($cv -is [int] -and $cv -lt -1000){$refc++} }} }
Write-Host ("BAK Results error cells now: {0}" -f $refc)
Write-Host ("BAK sheets: {0}" -f (@($bakWb.Worksheets | ForEach-Object { $_.Name }) -join ', '))

$bakWb.Save()
$bakWb.Close($true)
$outWb.Close($false)
$excel.Quit(); [System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel) | Out-Null
