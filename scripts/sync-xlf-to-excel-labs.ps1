param(
  [string] $RepoRoot = $(Split-Path $PSScriptRoot -Parent),
  [switch] $DryRun
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

function Normalize-Text {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string] $Text
  )

  return $Text.Replace("`r`n", "`n").Replace("`r", "`n")
}

function Get-ExplicitModuleName {
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string] $Content
  )

  $match = [regex]::Match($Content, '(?mi)^\s*Excel module name:\s*(.+?)\s*$')
  if ($match.Success) {
    return $match.Groups[1].Value.Trim()
  }

  return $null
}

function Add-Candidate {
  param(
    [Parameter()]
    [System.Collections.Generic.List[string]] $Candidates,

    [AllowNull()]
    [string] $Value
  )

  if ([string]::IsNullOrWhiteSpace($Value)) {
    return
  }

  if (-not $Candidates.Contains($Value)) {
    $Candidates.Add($Value)
  }
}

function Get-ModuleCandidateNames {
  param(
    [Parameter(Mandatory = $true)]
    [string] $XlfPath,

    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string] $Content
  )

  $candidates = [System.Collections.Generic.List[string]]::new()
  $baseName = [System.IO.Path]::GetFileNameWithoutExtension($XlfPath)
  $explicitName = Get-ExplicitModuleName -Content $Content

  Add-Candidate -Candidates $candidates -Value $explicitName
  Add-Candidate -Candidates $candidates -Value $baseName
  Add-Candidate -Candidates $candidates -Value ($baseName -replace '_Equations$', '')

  $segments = $XlfPath -split '[\\/]'
  $manureIndex = [Array]::IndexOf($segments, 'ManureManagement')
  if ($manureIndex -ge 0 -and ($manureIndex + 1) -lt $segments.Length) {
    $subType = $segments[$manureIndex + 1]
    $suffix = ($baseName -replace '^MMS_', '') -replace '_Equations$', ''
    if ($suffix.StartsWith("$subType" + '_')) {
      Add-Candidate -Candidates $candidates -Value ("ManureManagement_{0}" -f $suffix)
    } elseif (-not [string]::IsNullOrWhiteSpace($suffix)) {
      Add-Candidate -Candidates $candidates -Value ("ManureManagement_{0}_{1}" -f $subType, $suffix)
    }
  }

  $sourceIndex = [Array]::IndexOf($segments, 'source-data')
  if ($sourceIndex -ge 0) {
    Add-Candidate -Candidates $candidates -Value $baseName
  }

  return $candidates
}

function Resolve-WorkbookModule {
  param(
    [Parameter(Mandatory = $true)]
    [string] $XlfPath,

    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string] $Content,

    [Parameter(Mandatory = $true)]
    [object[]] $ProjectFiles
  )

  $projectLookup = @{}
  foreach ($projectFile in $ProjectFiles) {
    $projectLookup[$projectFile.path] = $projectFile
  }

  foreach ($candidate in (Get-ModuleCandidateNames -XlfPath $XlfPath -Content $Content)) {
    $projectPath = "/projects/{0}" -f $candidate
    if ($projectLookup.ContainsKey($projectPath)) {
      return [pscustomobject]@{
        ModuleName = $candidate
        Project    = $projectLookup[$projectPath]
      }
    }
  }

  return $null
}

function Get-AfeBlobEntry {
  param(
    [Parameter(Mandatory = $true)]
    [System.IO.Compression.ZipArchive] $ZipArchive
  )

  foreach ($entry in $ZipArchive.Entries) {
    if ($entry.FullName -notlike 'customXml/item*.xml') {
      continue
    }

    $reader = [System.IO.StreamReader]::new($entry.Open())
    try {
      $xml = $reader.ReadToEnd()
    } finally {
      $reader.Dispose()
    }

    if ($xml -match '<AFEJSONBlob') {
      return [pscustomobject]@{
        Entry = $entry
        Xml   = $xml
      }
    }
  }

  return $null
}

function Save-AfeBlobEntry {
  param(
    [Parameter(Mandatory = $true)]
    [System.IO.Compression.ZipArchive] $ZipArchive,

    [Parameter(Mandatory = $true)]
    [string] $EntryName,

    [Parameter(Mandatory = $true)]
    [string] $XmlContent
  )

  $existingEntry = $ZipArchive.GetEntry($EntryName)
  if ($null -ne $existingEntry) {
    $existingEntry.Delete()
  }

  $newEntry = $ZipArchive.CreateEntry($EntryName)
  $writer = [System.IO.StreamWriter]::new($newEntry.Open(), [System.Text.UTF8Encoding]::new($false))
  try {
    $writer.Write($XmlContent)
  } finally {
    $writer.Dispose()
  }
}

function Get-XlfFiles {
  param(
    [Parameter(Mandatory = $true)]
    [string] $RepoRoot
  )

  return Get-ChildItem -Path $RepoRoot -Filter '*.xlf' -Recurse -File |
    Where-Object {
      $_.FullName -notmatch '\\node_modules\\' -and
      $_.FullName -notmatch '\\dist\\' -and
      $_.FullName -notmatch '\\tmp_xlsx_inspect\\'
    }
}

function Sync-Workbook {
  param(
    [Parameter(Mandatory = $true)]
    [string] $WorkbookPath,

    [Parameter(Mandatory = $true)]
    [System.IO.FileInfo[]] $XlfFiles,

    [switch] $DryRun
  )

  $updatedModules = [System.Collections.Generic.List[string]]::new()
  $skippedFiles = [System.Collections.Generic.List[string]]::new()

  $zipMode = [System.IO.Compression.ZipArchiveMode]::Update
  $zip = [System.IO.Compression.ZipFile]::Open($WorkbookPath, $zipMode)
  try {
    $blobEntry = Get-AfeBlobEntry -ZipArchive $zip
    if ($null -eq $blobEntry) {
      return [pscustomobject]@{
        Workbook      = $WorkbookPath
        Updated       = @()
        Skipped       = @()
        HasAfeProject = $false
      }
    }

    $base64 = [regex]::Match($blobEntry.Xml, '(?s)<AFEJSONBlob[^>]*>(.*)</AFEJSONBlob>').Groups[1].Value
    if ([string]::IsNullOrWhiteSpace($base64)) {
      throw "AFEJSONBlob payload was empty in $WorkbookPath"
    }

    $projectJson = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($base64))
    $project = $projectJson | ConvertFrom-Json

    foreach ($xlfFile in $XlfFiles) {
      $xlfText = Normalize-Text -Text ([System.IO.File]::ReadAllText($xlfFile.FullName))
      $resolvedModule = Resolve-WorkbookModule -XlfPath $xlfFile.FullName -Content $xlfText -ProjectFiles $project.files
      if ($null -eq $resolvedModule) {
        continue
      }

      $moduleText = Normalize-Text -Text ([string] $resolvedModule.Project.text)
      if ($moduleText -eq $xlfText) {
        continue
      }

      if (-not $DryRun) {
        $resolvedModule.Project.text = $xlfText
      }

      $updatedModules.Add($resolvedModule.ModuleName)
    }

    if ($updatedModules.Count -gt 0 -and -not $DryRun) {
      $newProjectJson = $project | ConvertTo-Json -Depth 100 -Compress
      $newBase64 = [Convert]::ToBase64String([System.Text.Encoding]::Unicode.GetBytes($newProjectJson))
      $newXml = [regex]::Replace(
        $blobEntry.Xml,
        '(?s)(<AFEJSONBlob[^>]*>).*?(</AFEJSONBlob>)',
        ('$1' + $newBase64 + '$2')
      )
      Save-AfeBlobEntry -ZipArchive $zip -EntryName $blobEntry.Entry.FullName -XmlContent $newXml
    }

    return [pscustomobject]@{
      Workbook      = $WorkbookPath
      Updated       = $updatedModules.ToArray()
      Skipped       = $skippedFiles.ToArray()
      HasAfeProject = $true
    }
  } finally {
    $zip.Dispose()
  }
}

$repoRootPath = (Resolve-Path $RepoRoot).Path
$workbooks = Get-ChildItem -Path (Join-Path $repoRootPath 'Excel') -Filter '*.xlsx' -File
if ($workbooks.Count -eq 0) {
  Write-Host 'No Excel workbooks found under Excel/; nothing to sync.'
  exit 0
}

$xlfFiles = @(Get-XlfFiles -RepoRoot $repoRootPath)
if ($xlfFiles.Count -eq 0) {
  Write-Host 'No .xlf files found; nothing to sync.'
  exit 0
}

$anyUpdates = $false
foreach ($workbook in $workbooks) {
  try {
    $result = Sync-Workbook -WorkbookPath $workbook.FullName -XlfFiles $xlfFiles -DryRun:$DryRun
  } catch {
    Write-Host ("Skipping {0}: {1}" -f $workbook.Name, $_.Exception.Message)
    continue
  }

  if (-not $result.HasAfeProject) {
    Write-Host ("Skipping {0}: no Excel Labs AFE project found." -f $workbook.Name)
    continue
  }

  if ($result.Updated.Count -eq 0) {
    Write-Host ("{0}: no module updates needed." -f $workbook.Name)
    continue
  }

  $anyUpdates = $true
  $action = if ($DryRun) { 'Would update' } else { 'Updated' }
  Write-Host ("{0}: {1} modules {2}" -f $workbook.Name, $action, (($result.Updated | Sort-Object -Unique) -join ', '))
}

if (-not $anyUpdates) {
  Write-Host 'Excel Labs modules are already in sync with .xlf files.'
}

function Sync-CommonSheetsAcrossWorkbooks {
  param(
    [Parameter(Mandatory = $true)]
    [System.IO.FileInfo[]] $Workbooks,

    [switch] $DryRun
  )

  $commonCandidates = @($Workbooks | Where-Object { $_.BaseName -like 'Common*' } | Sort-Object LastWriteTime -Descending)
  if ($commonCandidates.Count -eq 0) {
    Write-Host 'No Common*.xlsx source workbook found; skipping sheet propagation.'
    return
  }

  $excel = $null
  $sourceWorkbook = $null
  $sourceWorkbookFile = $null

  try {
    $excel = New-Object -ComObject Excel.Application
    $excel.Visible = $false
    $excel.DisplayAlerts = $false
    $excel.ScreenUpdating = $false
    $excel.EnableEvents = $false
    $excel.AskToUpdateLinks = $false

    foreach ($candidate in $commonCandidates) {
      try {
        $sourceWorkbook = $excel.Workbooks.Open($candidate.FullName, $null, $true)
        $sourceWorkbookFile = $candidate
        break
      } catch {
        Write-Host ("Skipping candidate source workbook {0}: {1}" -f $candidate.Name, $_.Exception.Message)
      }
    }

    if ($null -eq $sourceWorkbook -or $null -eq $sourceWorkbookFile) {
      Write-Host 'No accessible Common*.xlsx source workbook found; skipping sheet propagation.'
      return
    }

    $targetWorkbookFiles = @($Workbooks | Where-Object { $_.FullName -ne $sourceWorkbookFile.FullName })
    if ($targetWorkbookFiles.Count -eq 0) {
      Write-Host ("{0} is the only workbook found; no target workbooks for sheet propagation." -f $sourceWorkbookFile.Name)
      return
    }

    $sourceSheetsByName = @{}
    foreach ($sourceSheet in @($sourceWorkbook.Worksheets)) {
      $sourceSheetsByName[$sourceSheet.Name] = $sourceSheet
    }

    foreach ($targetWorkbookFile in $targetWorkbookFiles) {
      $targetWorkbook = $null
      $touchedSheets = [System.Collections.Generic.List[string]]::new()

      try {
        try {
          $targetWorkbook = $excel.Workbooks.Open($targetWorkbookFile.FullName, $null, $DryRun.IsPresent)
        } catch {
          Write-Host ("Skipping target workbook {0}: {1}" -f $targetWorkbookFile.Name, $_.Exception.Message)
          continue
        }

        foreach ($sheetName in $sourceSheetsByName.Keys) {
          $targetSheet = $null

          try {
            $targetSheet = $targetWorkbook.Worksheets.Item($sheetName)
          } catch {
            $targetSheet = $null
          }

          if ($null -eq $targetSheet) {
            continue
          }

          if (-not $DryRun) {
            $sourceSheet = $sourceSheetsByName[$sheetName]
            [void] $targetSheet.Cells.Clear()

            $sourceUsedRange = $sourceSheet.UsedRange
            if ($null -ne $sourceUsedRange) {
              $rowCount = [int] $sourceUsedRange.Rows.Count
              $colCount = [int] $sourceUsedRange.Columns.Count

              if ($rowCount -gt 0 -and $colCount -gt 0) {
                [void] $sourceUsedRange.Copy($targetSheet.Range('A1'))
              }
            }
          }

          $touchedSheets.Add($sheetName)
        }

        if ($touchedSheets.Count -gt 0) {
          $action = if ($DryRun) { 'Would replace' } else { 'Replaced' }
          Write-Host ("{0}: {1} sheet contents from {2} -> {3}" -f $targetWorkbookFile.Name, $action, $sourceWorkbookFile.Name, (($touchedSheets | Sort-Object -Unique) -join ', '))

          if (-not $DryRun) {
            [void] $targetWorkbook.Save()
          }
        } else {
          Write-Host ("{0}: no matching sheet names found for propagation from {1}." -f $targetWorkbookFile.Name, $sourceWorkbookFile.Name)
        }
      } finally {
        if ($null -ne $targetWorkbook) {
          [void] $targetWorkbook.Close($false)
          [void] [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($targetWorkbook)
        }
      }
    }
  } finally {
    if ($null -ne $sourceWorkbook) {
      [void] $sourceWorkbook.Close($false)
      [void] [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($sourceWorkbook)
    }

    if ($null -ne $excel) {
      $excel.Quit()
      [void] [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($excel)
    }

    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
  }
}

Sync-CommonSheetsAcrossWorkbooks -Workbooks $workbooks -DryRun:$DryRun