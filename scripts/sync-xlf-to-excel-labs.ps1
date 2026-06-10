param(
  [string] $RepoRoot = $(Split-Path $PSScriptRoot -Parent),
  [string] $WorkbookPath,
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
$allWorkbooks = @(Get-ChildItem -Path (Join-Path $repoRootPath 'Excel') -Filter '*.xlsx' -File)
$workbooks = $allWorkbooks
if (-not [string]::IsNullOrWhiteSpace($WorkbookPath)) {
  $resolvedWorkbookPath = (Resolve-Path -LiteralPath $WorkbookPath).Path
  $workbooks = @($allWorkbooks | Where-Object { $_.FullName -eq $resolvedWorkbookPath })
}
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

function Test-IsTransientExcelComException {
  param(
    [Parameter(Mandatory = $true)]
    [System.Management.Automation.ErrorRecord] $ErrorRecord
  )

  $exception = $ErrorRecord.Exception
  if ($exception -isnot [System.Runtime.InteropServices.COMException]) {
    return $false
  }

  return (
    $exception.HResult -eq -2147418111 -or # RPC_E_CALL_REJECTED
    $exception.HResult -eq -2147417848 -or # RPC_E_DISCONNECTED
    $exception.Message -match 'RPC_E_CALL_REJECTED|Call was rejected by callee|RPC_E_DISCONNECTED|disconnected from its clients'
  )
}

function Invoke-ComObjectCleanup {
  param(
    [Parameter()]
    $ComObject,

    [Parameter()]
    [scriptblock] $Action
  )

  if ($null -eq $ComObject) {
    return
  }

  if ($null -ne $Action) {
    try {
      & $Action $ComObject
    } catch {
      if (-not (Test-IsTransientExcelComException $_)) {
        Write-Verbose ("Ignoring COM cleanup error: {0}" -f $_.Exception.Message)
      }
    }
  }

  try {
    if ([System.Runtime.InteropServices.Marshal]::IsComObject($ComObject)) {
      [void] [System.Runtime.InteropServices.Marshal]::FinalReleaseComObject($ComObject)
    }
  } catch {
    Write-Verbose ("Ignoring COM release error: {0}" -f $_.Exception.Message)
  }
}

function Sync-CommonSheetsAcrossWorkbooks {
  param(
    [Parameter(Mandatory = $true)]
    [System.IO.FileInfo[]] $Workbooks,

    [switch] $DryRun
  )

  $commonCandidates = @(
    $Workbooks |
      Where-Object { $_.BaseName -like 'Common*' } |
      Sort-Object @{ Expression = {
          $versionMatch = [regex]::Match($_.BaseName, '(?i)_v(?<version>\d+)$')
          if ($versionMatch.Success) {
            [int] $versionMatch.Groups['version'].Value
          } else {
            -1
          }
        }; Descending = $true },
        @{ Expression = 'LastWriteTime'; Descending = $true }
  )
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

    $sourceSheetNames = [System.Collections.Generic.List[string]]::new()
    for ($sheetIndex = 1; $sheetIndex -le [int] $sourceWorkbook.Worksheets.Count; $sheetIndex++) {
      $sourceSheet = $sourceWorkbook.Worksheets.Item($sheetIndex)
      $sourceSheetName = [string] $sourceSheet.Name
      if (-not [string]::IsNullOrWhiteSpace($sourceSheetName) -and -not $sourceSheetNames.Contains($sourceSheetName)) {
        $sourceSheetNames.Add($sourceSheetName)
      }
    }

    function Get-UniqueWorksheetName {
      param(
        [Parameter(Mandatory = $true)]
        $Workbook,

        [Parameter(Mandatory = $true)]
        [string] $BaseName
      )

      $candidate = $BaseName
      if ($candidate.Length -gt 31) {
        $candidate = $candidate.Substring(0, 31)
      }

      $suffix = 1
      while ($true) {
        $exists = $false
        try {
          [void] $Workbook.Worksheets.Item($candidate)
          $exists = $true
        } catch {
          $exists = $false
        }

        if (-not $exists) {
          return $candidate
        }

        $rawSuffix = "_{0}" -f $suffix
        $maxBaseLen = [Math]::Max(1, 31 - $rawSuffix.Length)
        $base = if ($BaseName.Length -gt $maxBaseLen) { $BaseName.Substring(0, $maxBaseLen) } else { $BaseName }
        $candidate = $base + $rawSuffix
        $suffix++
      }
    }

    function Replace-WorkbookTableReferences {
      param(
        [Parameter(Mandatory = $true)]
        $Workbook,

        [Parameter(Mandatory = $true)]
        [string] $OldTableName,

        [Parameter(Mandatory = $true)]
        [string] $NewTableName
      )

      if ([string]::IsNullOrWhiteSpace($OldTableName) -or [string]::IsNullOrWhiteSpace($NewTableName)) {
        return
      }

      if ($OldTableName -eq $NewTableName) {
        return
      }

      $maxAttempts = 8
      $attempt = 0
      while ($true) {
        $attempt++
        try {
          $wsCount = [int] $Workbook.Worksheets.Count
          for ($wsIndex = 1; $wsIndex -le $wsCount; $wsIndex++) {
            $worksheet = $Workbook.Worksheets.Item($wsIndex)
            try {
              $formulaCells = $worksheet.UsedRange.SpecialCells(-4123)
              if ($null -ne $formulaCells) {
                [void] $formulaCells.Replace($OldTableName, $NewTableName, 2, 1, $false, $false, $false, $false)
              }
            } catch {
              # No formula cells on this worksheet.
            }
          }

          $nameCount = 0
          try {
            if ($null -ne $Workbook.Names) {
              $nameCount = [int] $Workbook.Names.Count
            }
          } catch {
            $nameCount = 0
          }

          for ($nameIndex = 1; $nameIndex -le $nameCount; $nameIndex++) {
            $name = $null
            try {
              $name = $Workbook.Names.Item($nameIndex)
            } catch {
              continue
            }

            if ($null -eq $name) {
              continue
            }

            try {
              $refersTo = [string] $name.RefersTo
              if (-not [string]::IsNullOrEmpty($refersTo) -and $refersTo.Contains($OldTableName)) {
                $name.RefersTo = $refersTo.Replace($OldTableName, $NewTableName)
              }
            } catch {
              # Skip names that cannot be read or updated.
            }
          }

          break
        } catch {
          if ((Test-IsTransientExcelComException $_) -and $attempt -lt $maxAttempts) {
            Start-Sleep -Milliseconds (120 * $attempt)
            continue
          }

          throw
        }
      }
    }

    function Split-ScopedName {
      param(
        [Parameter(Mandatory = $true)]
        [string] $NameText
      )

      $bangIndex = $NameText.IndexOf('!')
      if ($bangIndex -lt 0) {
        return $null
      }

      $scopeText = $NameText.Substring(0, $bangIndex).Trim()
      $simpleName = $NameText.Substring($bangIndex + 1).Trim()

      if ($scopeText.StartsWith("'") -and $scopeText.EndsWith("'")) {
        $scopeText = $scopeText.Substring(1, $scopeText.Length - 2).Replace("''", "'")
      }

      return [pscustomobject]@{
        ScopeName  = $scopeText
        SimpleName = $simpleName
      }
    }

    function Remove-WorksheetScopedCommonModuleNames {
      param(
        [Parameter(Mandatory = $true)]
        $Workbook,

        [Parameter(Mandatory = $true)]
        [string[]] $WorksheetNames
      )

      foreach ($worksheetName in $WorksheetNames) {
        if ([string]::IsNullOrWhiteSpace($worksheetName)) {
          continue
        }

        $worksheet = $null
        try {
          $worksheet = $Workbook.Worksheets.Item($worksheetName)
        } catch {
          continue
        }

        $candidateNames = [System.Collections.Generic.List[object]]::new()
        $wsNameCount = 0
        try {
          $wsNameCount = [int] $worksheet.Names.Count
        } catch {
          $wsNameCount = 0
        }

        for ($nameIndex = 1; $nameIndex -le $wsNameCount; $nameIndex++) {
          $nameObj = $worksheet.Names.Item($nameIndex)
          try {
            $nameText = [string] $nameObj.Name
            if ([string]::IsNullOrWhiteSpace($nameText)) {
              continue
            }

            $simpleName = $nameText
            $bangIndex = $simpleName.IndexOf('!')
            if ($bangIndex -ge 0) {
              $simpleName = $simpleName.Substring($bangIndex + 1).Trim()
            }

            if ($simpleName -match '^(?i)Common_(?:SourceData|InputFunctions|Equations)_') {
              $candidateNames.Add($nameObj)
            }
          } catch {
            # Skip names that cannot be inspected.
          }
        }

        foreach ($candidateName in $candidateNames) {
          try {
            [void] $candidateName.Delete()
          } catch {
            # Skip names that cannot be deleted.
          }
        }
      }
    }

    function Get-WorksheetScopedCommonModuleNameDefinitions {
      param(
        [Parameter(Mandatory = $true)]
        $Workbook,

        [Parameter(Mandatory = $true)]
        [string[]] $WorksheetNames
      )

      $definitions = @{}
      foreach ($worksheetName in $WorksheetNames) {
        if ([string]::IsNullOrWhiteSpace($worksheetName)) {
          continue
        }

        $worksheet = $null
        try {
          $worksheet = $Workbook.Worksheets.Item($worksheetName)
        } catch {
          continue
        }

        $wsNameCount = 0
        try {
          $wsNameCount = [int] $worksheet.Names.Count
        } catch {
          $wsNameCount = 0
        }

        for ($nameIndex = 1; $nameIndex -le $wsNameCount; $nameIndex++) {
          $nameObj = $worksheet.Names.Item($nameIndex)
          try {
            $nameText = [string] $nameObj.Name
            if ([string]::IsNullOrWhiteSpace($nameText)) {
              continue
            }

            $simpleName = $nameText
            $bangIndex = $simpleName.IndexOf('!')
            if ($bangIndex -ge 0) {
              $simpleName = $simpleName.Substring($bangIndex + 1).Trim()
            }

            if ($simpleName -notmatch '^(?i)Common_(?:SourceData|InputFunctions|Equations)_') {
              continue
            }

            $definitions[$simpleName] = [string] $nameObj.RefersTo
          } catch {
            # Skip names that cannot be inspected.
          }
        }
      }

      return $definitions
    }

    function Upsert-WorkbookScopedCommonModuleNames {
      param(
        [Parameter(Mandatory = $true)]
        $Workbook,

        [Parameter(Mandatory = $true)]
        [hashtable] $Definitions
      )

      foreach ($nameKey in $Definitions.Keys) {
        try {
          $existing = $Workbook.Names.Item($nameKey)
          if ($null -ne $existing) {
            [void] $existing.Delete()
          }
        } catch {
          # Missing is expected.
        }

        try {
          [void] $Workbook.Names.Add($nameKey, [string] $Definitions[$nameKey])
        } catch {
          # Ignore single-name failures so one bad entry does not block the workbook.
        }
      }
    }

    function Normalize-WorksheetScopedLambdaNames {
      param(
        [Parameter(Mandatory = $true)]
        $Workbook,

        [Parameter(Mandatory = $true)]
        [string[]] $WorksheetNames
      )

      $pending = [System.Collections.Generic.List[object]]::new()

      foreach ($worksheetName in $WorksheetNames) {
        if ([string]::IsNullOrWhiteSpace($worksheetName)) {
          continue
        }

        $worksheet = $null
        try {
          $worksheet = $Workbook.Worksheets.Item($worksheetName)
        } catch {
          continue
        }

        $wsNameCount = 0
        try {
          $wsNameCount = [int] $worksheet.Names.Count
        } catch {
          $wsNameCount = 0
        }

        for ($nameIndex = 1; $nameIndex -le $wsNameCount; $nameIndex++) {
          $nameObj = $worksheet.Names.Item($nameIndex)
          try {
            $nameText = [string] $nameObj.Name
            if ([string]::IsNullOrWhiteSpace($nameText)) {
              continue
            }

            $simpleName = $nameText
            $bangIndex = $simpleName.IndexOf('!')
            if ($bangIndex -ge 0) {
              $simpleName = $simpleName.Substring($bangIndex + 1).Trim()
            }
            if ([string]::IsNullOrWhiteSpace($simpleName)) {
              continue
            }

            $refersTo = [string] $nameObj.RefersTo
            if ([string]::IsNullOrWhiteSpace($refersTo)) {
              continue
            }

            if ($refersTo -notmatch '(?i)\bLAMBDA\s*\(') {
              continue
            }

            $pending.Add([pscustomobject]@{
              NameObj     = $nameObj
              SimpleName  = $simpleName
              RefersTo    = $refersTo
            })
          } catch {
            # Skip names that cannot be inspected.
          }
        }
      }

      foreach ($entry in $pending) {
        $hasWorkbookScoped = $false
        try {
          $existing = $Workbook.Names.Item($entry.SimpleName)
          if ($null -ne $existing) {
            $existing.RefersTo = [string] $entry.RefersTo
            $hasWorkbookScoped = $true
          }
        } catch {
          $hasWorkbookScoped = $false
        }

        if (-not $hasWorkbookScoped) {
          try {
            [void] $Workbook.Names.Add([string] $entry.SimpleName, [string] $entry.RefersTo)
            $hasWorkbookScoped = $true
          } catch {
            $hasWorkbookScoped = $false
          }
        }

        if ($hasWorkbookScoped) {
          try {
            [void] $entry.NameObj.Delete()
          } catch {
            # Skip names that cannot be deleted.
          }
        }
      }
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

        foreach ($sheetName in $sourceSheetNames) {
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
            $sourceSheet = $null
            try {
              $sourceSheet = $sourceWorkbook.Worksheets.Item($sheetName)
            } catch {
              if (Test-IsTransientExcelComException $_) {
                throw ("Excel disconnected while resolving source sheet '{0}' for workbook '{1}': {2}" -f $sheetName, $targetWorkbookFile.Name, $_.Exception.Message)
              }

              throw
            }

            $isConstantsCommon = $sheetName -match '^(?i)Constants(?:\s*-\s*|_|\s+)Common$'
            if ($isConstantsCommon) {
              $oldSheet = $targetSheet
              $oldSheetName = Get-UniqueWorksheetName -Workbook $targetWorkbook -BaseName 'Constants_Common_Old'
              $oldSheet.Name = $oldSheetName

              $existingSheetNames = @{}
              for ($sheetIndex = 1; $sheetIndex -le [int] $targetWorkbook.Worksheets.Count; $sheetIndex++) {
                $ws = $targetWorkbook.Worksheets.Item($sheetIndex)
                $existingSheetNames[[string] $ws.Name] = $true
              }

              $copied = $false

              try {
                [void] $sourceSheet.Copy([Type]::Missing, $oldSheet)
                $copied = $true
              } catch {
                try {
                  [void] $sourceSheet.Copy($oldSheet)
                  $copied = $true
                } catch {
                  throw ("Unable to copy sheet '{0}' into workbook '{1}': {2}" -f $sheetName, $targetWorkbookFile.Name, $_.Exception.Message)
                }
              }

              if (-not $copied) {
                throw ("Copy operation did not create a new worksheet for '{0}' in '{1}'." -f $sheetName, $targetWorkbookFile.Name)
              }

              $newSheet = $null
              for ($sheetIndex = 1; $sheetIndex -le [int] $targetWorkbook.Worksheets.Count; $sheetIndex++) {
                $ws = $targetWorkbook.Worksheets.Item($sheetIndex)
                $wsName = [string] $ws.Name
                if (-not $existingSheetNames.ContainsKey($wsName)) {
                  $newSheet = $ws
                  break
                }
              }

              if ($null -eq $newSheet) {
                $newSheet = $targetWorkbook.ActiveSheet
              }

              if ($null -eq $newSheet) {
                throw ("Unable to resolve copied worksheet for '{0}' in '{1}'." -f $sheetName, $targetWorkbookFile.Name)
              }

              if ($newSheet.Name -ne $sheetName) {
                $newSheet.Name = $sheetName
              }

              $incomingCommonNames = Get-WorksheetScopedCommonModuleNameDefinitions -Workbook $targetWorkbook -WorksheetNames @($sheetName)
              if ($incomingCommonNames.Count -gt 0) {
                Upsert-WorkbookScopedCommonModuleNames -Workbook $targetWorkbook -Definitions $incomingCommonNames
              }

              Normalize-WorksheetScopedLambdaNames -Workbook $targetWorkbook -WorksheetNames @($oldSheetName, $sheetName)

              $sourceTables = @($sourceSheet.ListObjects)
              $newTables = @($newSheet.ListObjects)
              $tableCount = [Math]::Min($sourceTables.Count, $newTables.Count)

              for ($i = 0; $i -lt $tableCount; $i++) {
                $previousTableName = [string] $sourceTables[$i].DisplayName
                $incomingTableName = [string] $newTables[$i].DisplayName

                if ([string]::IsNullOrWhiteSpace($previousTableName) -or [string]::IsNullOrWhiteSpace($incomingTableName)) {
                  Write-Warning ("Skipping table reference sync for workbook '{0}', sheet '{1}', table index {2}: source name='{3}', target name='{4}'" -f $targetWorkbookFile.Name, $sheetName, $i, $previousTableName, $incomingTableName)
                  continue
                }

                Replace-WorkbookTableReferences -Workbook $targetWorkbook -OldTableName $previousTableName -NewTableName $incomingTableName
              }

              # When the original tab was renamed, Excel rewrote all cell formulas that
              # contained 'Constants - Common'! to use the new temporary name.  Redirect
              # those references back to the canonical sheet name now that the new copy
              # is in place, before we delete the old tab (after deletion they become #REF!).
              #
              # Excel only wraps a sheet name in single quotes when the name contains
              # characters that would otherwise be ambiguous in a formula (spaces, hyphens,
              # or other non-alphanumeric/underscore chars, or a leading digit).
              # Using the wrong quoting means Replace() will never find a match.
              $needsQuoting = { param([string] $n) $n -match "[^A-Za-z0-9_]" -or $n -match "^\d" }
              $sheetRefOld = if (& $needsQuoting $oldSheetName) { "'" + $oldSheetName.Replace("'", "''") + "'!" } else { $oldSheetName + "!" }
              $sheetRefNew = if (& $needsQuoting $sheetName)    { "'" + $sheetName.Replace("'",   "''") + "'!" } else { $sheetName    + "!" }
              $wsCount2 = 0
              try {
                if ($null -ne $targetWorkbook.Worksheets) {
                  $wsCount2 = [int] $targetWorkbook.Worksheets.Count
                }
              } catch {
                $wsCount2 = 0
              }
              for ($wsIndex2 = 1; $wsIndex2 -le $wsCount2; $wsIndex2++) {
                $ws2 = $targetWorkbook.Worksheets.Item($wsIndex2)
                if ($ws2.Name -eq $sheetName -or $ws2.Name -eq $oldSheetName) { continue }
                try {
                  $formulaCells2 = $ws2.UsedRange.SpecialCells(-4123)
                  if ($null -ne $formulaCells2) {
                    [void] $formulaCells2.Replace($sheetRefOld, $sheetRefNew, 2, 1, $false, $false, $false, $false)
                  }
                } catch { }
              }
              # Also fix named ranges (Lambda definitions) that may have had their
              # sheet qualifier rewritten when the old tab was renamed.
              $nameCount2 = 0
              try {
                if ($null -ne $targetWorkbook.Names) {
                  $nameCount2 = [int] $targetWorkbook.Names.Count
                }
              } catch {
                $nameCount2 = 0
              }

              for ($nameIndex2 = 1; $nameIndex2 -le $nameCount2; $nameIndex2++) {
                $name2 = $null
                try {
                  $name2 = $targetWorkbook.Names.Item($nameIndex2)
                } catch {
                  continue
                }

                if ($null -eq $name2) {
                  continue
                }

                try {
                  $refersTo2 = [string] $name2.RefersTo
                  if (-not [string]::IsNullOrEmpty($refersTo2) -and $refersTo2.Contains($sheetRefOld)) {
                    $name2.RefersTo = $refersTo2.Replace($sheetRefOld, $sheetRefNew)
                  }
                } catch { }
              }

              [void] $oldSheet.Delete()

              # Rename tables back to canonical names.
              for ($i = 0; $i -lt $tableCount; $i++) {
                $canonicalTableName = [string] $sourceTables[$i].DisplayName
                $currentTableName   = [string] $newTables[$i].DisplayName
                if ($currentTableName -ne $canonicalTableName) {
                  $newTables[$i].DisplayName = $canonicalTableName
                }
              }
            } else {
              [void] $targetSheet.Cells.Clear()

              $sourceUsedRange = $null
              try {
                $sourceUsedRange = $sourceSheet.UsedRange
              } catch {
                if (Test-IsTransientExcelComException $_) {
                  Write-Warning ("Skipping sheet copy for workbook '{0}', sheet '{1}' after transient Excel COM error while reading UsedRange: {2}" -f $targetWorkbookFile.Name, $sheetName, $_.Exception.Message)
                  continue
                }

                throw
              }

              if ($null -ne $sourceUsedRange) {
                try {
                  [void] $sourceUsedRange.Copy($targetSheet.Range('A1'))
                } catch {
                  if (Test-IsTransientExcelComException $_) {
                    Write-Warning ("Skipping sheet copy for workbook '{0}', sheet '{1}' after transient Excel COM error while copying UsedRange: {2}" -f $targetWorkbookFile.Name, $sheetName, $_.Exception.Message)
                    continue
                  }

                  throw
                }
              }
            }
          }

          $touchedSheets.Add($sheetName)
        }

        if ($touchedSheets.Count -gt 0) {
          $action = if ($DryRun) { 'Would replace' } else { 'Replaced' }
          Write-Host ("{0}: {1} sheet contents from {2} -> {3}" -f $targetWorkbookFile.Name, $action, $sourceWorkbookFile.Name, (($touchedSheets | Sort-Object -Unique) -join ', '))

          if (-not $DryRun) {
            # Defensive final pass: remove any worksheet-scoped Common_* names that
            # may exist anywhere in the workbook so only workbook-scoped definitions remain.
            $allWorksheetNames = [System.Collections.Generic.List[string]]::new()
            for ($wsIdx = 1; $wsIdx -le [int] $targetWorkbook.Worksheets.Count; $wsIdx++) {
              $wsObj = $targetWorkbook.Worksheets.Item($wsIdx)
              $allWorksheetNames.Add([string] $wsObj.Name)
            }
            Normalize-WorksheetScopedLambdaNames -Workbook $targetWorkbook -WorksheetNames $allWorksheetNames.ToArray()

            [void] $targetWorkbook.Save()
          }
        } else {
          Write-Host ("{0}: no matching sheet names found for propagation from {1}." -f $targetWorkbookFile.Name, $sourceWorkbookFile.Name)
        }
      } catch {
        if (Test-IsTransientExcelComException $_) {
          Write-Host ("Skipping target workbook {0} after transient Excel COM error: {1}" -f $targetWorkbookFile.Name, $_.Exception.Message)
          continue
        }

        throw
      } finally {
        if ($null -ne $targetWorkbook) {
          Invoke-ComObjectCleanup -ComObject $targetWorkbook -Action { param($workbook) [void] $workbook.Close($false) }
        }
      }
    }
  } finally {
    if ($null -ne $sourceWorkbook) {
      Invoke-ComObjectCleanup -ComObject $sourceWorkbook -Action { param($workbook) [void] $workbook.Close($false) }
    }

    if ($null -ne $excel) {
      Invoke-ComObjectCleanup -ComObject $excel -Action { param($app) $app.Quit() }
    }

    [GC]::Collect()
    [GC]::WaitForPendingFinalizers()
  }
}

Sync-CommonSheetsAcrossWorkbooks -Workbooks $allWorkbooks -DryRun:$DryRun