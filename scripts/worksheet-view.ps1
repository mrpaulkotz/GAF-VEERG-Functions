# ===========================================================================
# Shared worksheet view helpers. Dot-sourced by the enterprise, Scope 3 and
# generic chapter build scripts. XML-only (no COM) so it is headless-safe and
# does not require activating sheets.
# ===========================================================================

# ---------------------------------------------------------------------------
# Set-WorkbookZoom
# ---------------------------------------------------------------------------
# Forces the normal-view zoom of every worksheet in an .xlsx to $Zoom (default
# 100%) by rewriting the <sheetView> zoomScale attributes directly in the zip.
# Returns the number of sheet parts changed.
function Set-WorkbookZoom {
  param(
    [Parameter(Mandatory = $true)][string] $Path,
    [int] $Zoom = 100
  )

  Add-Type -AssemblyName System.IO.Compression.FileSystem | Out-Null
  $zip = [System.IO.Compression.ZipFile]::Open($Path, 'Update')
  try {
    $sheetEntries = @($zip.Entries | Where-Object { $_.FullName -match '^xl/worksheets/sheet\d+\.xml$' })

    # Phase 1: read + compute new content (don't mutate the archive while reading).
    $updates = @{}
    foreach ($entry in $sheetEntries) {
      $reader = New-Object System.IO.StreamReader($entry.Open())
      try { $text = $reader.ReadToEnd() } finally { $reader.Dispose() }
      $orig = $text

      $text = [regex]::Replace($text, '<sheetView\b[^>]*?/?>', {
        param($m)
        $tag = $m.Value
        $selfClose = $tag.EndsWith('/>')
        $close = if ($selfClose) { '/>' } else { '>' }
        $body = $tag.Substring(0, $tag.Length - $close.Length)
        # Drop any existing zoom attributes, then set normal-view zoom.
        $body = [regex]::Replace($body, '\s+zoomScale(Normal|Sheet|PageLayoutView)?="[^"]*"', '')
        return ($body + (' zoomScale="{0}" zoomScaleNormal="{0}"' -f $Zoom) + $close)
      })

      if ($text -ne $orig) { $updates[$entry.FullName] = $text }
    }

    # Phase 2: apply the changes (delete + recreate each modified part).
    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    foreach ($name in @($updates.Keys)) {
      $existing = $zip.GetEntry($name)
      if ($null -ne $existing) { $existing.Delete() }
      $newEntry = $zip.CreateEntry($name)
      $writer = New-Object System.IO.StreamWriter($newEntry.Open(), $utf8NoBom)
      try { $writer.Write($updates[$name]) } finally { $writer.Dispose() }
    }

    return $updates.Count
  } finally {
    $zip.Dispose()
  }
}
