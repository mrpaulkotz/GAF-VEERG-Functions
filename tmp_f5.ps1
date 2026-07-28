$ErrorActionPreference='Stop'
Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null

function Get-CellXml {
  param([string]$Path,[string]$SheetName,[string]$Cell)
  $z=[System.IO.Compression.ZipFile]::OpenRead($Path)
  try {
    # read workbook.xml to map sheet name -> r:id -> file
    $wb=$z.GetEntry('xl/workbook.xml'); $r=New-Object System.IO.StreamReader($wb.Open()); $wx=$r.ReadToEnd(); $r.Close()
    $rels=$z.GetEntry('xl/_rels/workbook.xml.rels'); $r=New-Object System.IO.StreamReader($rels.Open()); $rx=$r.ReadToEnd(); $r.Close()
    $m=[regex]::Match($wx,'<sheet[^>]*name="'+[regex]::Escape($SheetName)+'"[^>]*r:id="([^"]+)"')
    if(-not $m.Success){ $m=[regex]::Match($wx,'<sheet[^>]*r:id="([^"]+)"[^>]*name="'+[regex]::Escape($SheetName)+'"') }
    if(-not $m.Success){ Write-Host "  SHEET NOT FOUND: $SheetName"; return }
    $rid=$m.Groups[1].Value
    $tm=[regex]::Match($rx,'Id="'+[regex]::Escape($rid)+'"[^>]*Target="([^"]+)"')
    $target=$tm.Groups[1].Value -replace '^/xl/','' -replace '^\.\./',''
    if($target -notlike 'xl/*' -and $target -notlike 'worksheets/*'){ $target="xl/$target" }
    if($target -like 'worksheets/*'){ $target="xl/$target" }
    $se=$z.GetEntry($target); if($null -eq $se){ Write-Host "  part not found: $target"; return }
    $r=New-Object System.IO.StreamReader($se.Open()); $sx=$r.ReadToEnd(); $r.Close()
    $cm=[regex]::Match($sx,'<c r="'+$Cell+'"[^>]*?(/>|>.*?</c>)')
    if(-not $cm.Success){ Write-Host "  $Cell : <empty/absent>"; return }
    $raw=$cm.Value
    # resolve shared string
    $val=$raw
    if($raw -match 't="s"'){
      $vi=[regex]::Match($raw,'<v>(\d+)</v>').Groups[1].Value
      $sst=$z.GetEntry('xl/sharedStrings.xml'); $r=New-Object System.IO.StreamReader($sst.Open()); $sstx=$r.ReadToEnd(); $r.Close()
      $sis=[regex]::Matches($sstx,'(?s)<si>(.*?)</si>')
      $txt=([regex]::Replace($sis[[int]$vi].Groups[1].Value,'<[^>]+>',''))
      $val="[shared #$vi] -> '$txt'"
    }
    Write-Host "  $Cell RAW: $raw"
    Write-Host "  $Cell VAL: $val"
  } finally { $z.Dispose() }
}

$src='C:\htdocs\zneagcrc\GAF-VEERG-Functions\Excel\10_SolidWaste_WIP_v02.xlsx'
$out='C:\htdocs\zneagcrc\GAF-VEERG-Functions\Excel\13_Scope3_WIP_v13.xlsx'
Write-Host "SOURCE ($src):"
Get-CellXml -Path $src -SheetName 'Input - Solid waste' -Cell 'F5'
Write-Host ""
Write-Host "OUTPUT ($out):"
Get-CellXml -Path $out -SheetName 'Input - Solid waste' -Cell 'F5'
