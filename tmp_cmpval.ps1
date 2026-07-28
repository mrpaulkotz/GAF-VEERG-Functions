$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
$src = 'C:\htdocs\zneagcrc\GAF-VEERG-Functions\Excel\10_SolidWaste_WIP_v02.xlsx'
$out = 'C:\htdocs\zneagcrc\GAF-VEERG-Functions\Excel\13_Scope3_WIP_v13.xlsx'
$sheetName = 'Input - Solid waste'

function Get-SheetCells {
  param([string]$path, [string]$sheetName)
  $z = [System.IO.Compression.ZipFile]::OpenRead($path)
  try {
    # shared strings
    $sst = @()
    $e = $z.GetEntry('xl/sharedStrings.xml')
    if ($e) {
      $r = New-Object System.IO.StreamReader($e.Open()); $t = $r.ReadToEnd(); $r.Close()
      $xml = [xml]$t
      foreach ($si in $xml.sst.si) { $sst += ,([string]$si.InnerText) }
    }
    # workbook -> rId for sheet name
    $e = $z.GetEntry('xl/workbook.xml'); $r = New-Object System.IO.StreamReader($e.Open()); $wbT = $r.ReadToEnd(); $r.Close()
    $m = [regex]::Match($wbT, '<sheet[^>]*name="' + [regex]::Escape($sheetName) + '"[^>]*r:id="(rId\d+)"')
    if (-not $m.Success) { $m = [regex]::Match($wbT, '<sheet[^>]*r:id="(rId\d+)"[^>]*name="' + [regex]::Escape($sheetName) + '"') }
    $rid = $m.Groups[1].Value
    $e = $z.GetEntry('xl/_rels/workbook.xml.rels'); $r = New-Object System.IO.StreamReader($e.Open()); $relT = $r.ReadToEnd(); $r.Close()
    $tgt = [regex]::Match($relT, '<Relationship[^>]*Id="' + $rid + '"[^>]*Target="([^"]+)"').Groups[1].Value
    $part = 'xl/' + ($tgt -replace '^/xl/','' -replace '^\./','')
    $e = $z.GetEntry($part); $r = New-Object System.IO.StreamReader($e.Open()); $shT = $r.ReadToEnd(); $r.Close()
    $cells = @{}
    foreach ($cm in [regex]::Matches($shT, '<c r="([A-Z]+\d+)"([^>]*)>(.*?)</c>')) {
      $ref = $cm.Groups[1].Value; $attr = $cm.Groups[2].Value; $inner = $cm.Groups[3].Value
      $ty = [regex]::Match($attr, 't="([^"]+)"').Groups[1].Value
      $v = [regex]::Match($inner, '<v>(.*?)</v>').Groups[1].Value
      if ($ty -eq 's' -and $v -ne '') { $v = $sst[[int]$v] }
      elseif ($ty -eq 'str') { $v = $v }
      $cells[$ref] = $v
    }
    return $cells
  } finally { $z.Dispose() }
}

$sc = Get-SheetCells -path $src -sheetName $sheetName
$oc = Get-SheetCells -path $out -sheetName $sheetName
Write-Host ("Source cells: {0}  Output cells: {1}" -f $sc.Count, $oc.Count)

$allRefs = @($sc.Keys + $oc.Keys | Select-Object -Unique)
$diffs = 0; $shown = 0
foreach ($ref in $allRefs) {
  $sv = if ($sc.ContainsKey($ref)) { $sc[$ref] } else { '<absent>' }
  $ov = if ($oc.ContainsKey($ref)) { $oc[$ref] } else { '<absent>' }
  if ($sv -ne $ov) {
    $diffs++
    if ($shown -lt 50) {
      Write-Host ("DIFF {0}: src=[{1}] out=[{2}]" -f $ref, $sv, $ov)
      $shown++
    }
  }
}
Write-Host ("`nTotal differing cached values: {0}" -f $diffs)
