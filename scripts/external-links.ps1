# ===========================================================================
# Shared external-link artifact remover. Dot-sourced by workbook assemblers
# (build-enterprise-excel.ps1, and available to others) that copy sheets one at
# a time and are left with phantom 'xlPathMissing' external-workbook links.
#
# These links are dead references to sheets that were NOT imported into the
# assembled workbook (e.g. another module's 'Constants - Dairy', crop-residue
# calc sheets). They are held ONLY by orphan '[N]'-prefixed defined names; no
# cell formula references them, so removing them is safe. COM cannot do this -
# BreakLink throws on missing paths and .RefersTo throws on unresolvable [N]
# names - so it is done in XML.
#
# IMPORTANT: only external-reference indices >= 1 are stripped. The '[0]!'
# prefix is Excel's self-reference (this-workbook) qualifier used inside
# published AFE / Excel Labs LAMBDA named functions when one calls another;
# those names are legitimate and MUST be kept. External references in a workbook
# are 1-based, so '[0]' never corresponds to an external-link part.
# ===========================================================================

function Remove-ExternalLinkArtifacts {
  # Removes, atomically:
  #   1. every workbook.xml <definedName> whose RefersTo carries a '[N]' (N>=1) book ref
  #   2. the workbook.xml <externalReferences> block
  #   3. the externalLink relationships in xl/_rels/workbook.xml.rels
  #   4. the xl/externalLinks/** parts
  #   5. the [Content_Types].xml overrides for those parts
  param([string] $TargetPath)

  $result = [pscustomobject]@{ NamesRemoved = 0; ReferencesRemoved = 0; PartsRemoved = 0 }
  $mainNs = 'http://schemas.openxmlformats.org/spreadsheetml/2006/main'
  # Match external book refs [1], [2], ... but NOT the [0] self-reference.
  $reExt  = [regex] '\[[1-9]\d*\]'

  $zip = [System.IO.Compression.ZipFile]::Open($TargetPath, [System.IO.Compression.ZipArchiveMode]::Update)
  try {
    # --- 1 & 2: workbook.xml -------------------------------------------------
    $wbEntry = $zip.GetEntry('xl/workbook.xml')
    if ($null -eq $wbEntry) { return $result }
    $reader = [System.IO.StreamReader]::new($wbEntry.Open(), [System.Text.Encoding]::UTF8)
    try { $wbText = $reader.ReadToEnd() } finally { $reader.Dispose() }

    $doc = New-Object System.Xml.XmlDocument
    $doc.PreserveWhitespace = $true
    $doc.LoadXml($wbText)
    $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
    $ns.AddNamespace('x', $mainNs)

    $namesRemoved = 0
    $definedNamesNode = $doc.SelectSingleNode('//x:definedNames', $ns)
    if ($null -ne $definedNamesNode) {
      foreach ($n in @($definedNamesNode.SelectNodes('x:definedName', $ns))) {
        if ($reExt.IsMatch($n.InnerText)) { [void] $definedNamesNode.RemoveChild($n); $namesRemoved++ }
      }
      if (-not $definedNamesNode.HasChildNodes) { [void] $definedNamesNode.ParentNode.RemoveChild($definedNamesNode) }
    }

    $refsRemoved = 0
    $extRefsNode = $doc.SelectSingleNode('//x:externalReferences', $ns)
    if ($null -ne $extRefsNode) {
      $refsRemoved = @($extRefsNode.SelectNodes('x:externalReference', $ns)).Count
      [void] $extRefsNode.ParentNode.RemoveChild($extRefsNode)
    }

    if ($namesRemoved -gt 0 -or $refsRemoved -gt 0) {
      $wbEntry.Delete()
      $newWb = $zip.CreateEntry('xl/workbook.xml')
      $writer = [System.IO.StreamWriter]::new($newWb.Open(), [System.Text.UTF8Encoding]::new($false))
      try { $doc.Save($writer) } finally { $writer.Dispose() }
    }

    # --- 3: xl/_rels/workbook.xml.rels --------------------------------------
    $relEntry = $zip.GetEntry('xl/_rels/workbook.xml.rels')
    if ($null -ne $relEntry) {
      $reader = [System.IO.StreamReader]::new($relEntry.Open(), [System.Text.Encoding]::UTF8)
      try { $relText = $reader.ReadToEnd() } finally { $reader.Dispose() }
      $relDoc = New-Object System.Xml.XmlDocument
      $relDoc.PreserveWhitespace = $true
      $relDoc.LoadXml($relText)
      $relNs = New-Object System.Xml.XmlNamespaceManager($relDoc.NameTable)
      $relNs.AddNamespace('r', 'http://schemas.openxmlformats.org/package/2006/relationships')
      $relChanged = $false
      foreach ($rel in @($relDoc.SelectNodes('//r:Relationship', $relNs))) {
        if ($rel.GetAttribute('Type') -like '*externalLink') {
          [void] $rel.ParentNode.RemoveChild($rel); $relChanged = $true
        }
      }
      if ($relChanged) {
        $relEntry.Delete()
        $newRel = $zip.CreateEntry('xl/_rels/workbook.xml.rels')
        $writer = [System.IO.StreamWriter]::new($newRel.Open(), [System.Text.UTF8Encoding]::new($false))
        try { $relDoc.Save($writer) } finally { $writer.Dispose() }
      }
    }

    # --- 4: delete the externalLink parts -----------------------------------
    $partsRemoved = 0
    foreach ($e in @($zip.Entries | Where-Object { $_.FullName -like 'xl/externalLinks/*' })) {
      $e.Delete(); $partsRemoved++
    }

    # --- 5: [Content_Types].xml overrides -----------------------------------
    $ctEntry = $zip.GetEntry('[Content_Types].xml')
    if ($null -ne $ctEntry) {
      $reader = [System.IO.StreamReader]::new($ctEntry.Open(), [System.Text.Encoding]::UTF8)
      try { $ctText = $reader.ReadToEnd() } finally { $reader.Dispose() }
      $ctDoc = New-Object System.Xml.XmlDocument
      $ctDoc.PreserveWhitespace = $true
      $ctDoc.LoadXml($ctText)
      $ctNs = New-Object System.Xml.XmlNamespaceManager($ctDoc.NameTable)
      $ctNs.AddNamespace('c', 'http://schemas.openxmlformats.org/package/2006/content-types')
      $ctChanged = $false
      foreach ($ov in @($ctDoc.SelectNodes('//c:Override', $ctNs))) {
        if ($ov.GetAttribute('PartName') -like '/xl/externalLinks/*') {
          [void] $ov.ParentNode.RemoveChild($ov); $ctChanged = $true
        }
      }
      if ($ctChanged) {
        $ctEntry.Delete()
        $newCt = $zip.CreateEntry('[Content_Types].xml')
        $writer = [System.IO.StreamWriter]::new($newCt.Open(), [System.Text.UTF8Encoding]::new($false))
        try { $ctDoc.Save($writer) } finally { $writer.Dispose() }
      }
    }

    $result.NamesRemoved      = $namesRemoved
    $result.ReferencesRemoved = $refsRemoved
    $result.PartsRemoved      = $partsRemoved
  } finally { $zip.Dispose() }

  return $result
}
