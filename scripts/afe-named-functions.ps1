# ===========================================================================
# afe-named-functions.ps1  (dot-sourced helper)
#
# Re-publishes Excel Labs (AFE) module LAMBDA functions to the workbook's
# Name Manager so that updating a module's `.text` blob actually changes the
# formulas Excel evaluates.
#
# Background: Excel Labs stores each module function twice -- once as source
# text inside the AFE JSON blob (customXml/item*.xml) and once as a published
# <definedName> "<ModuleName>.<FuncName>" in xl/workbook.xml (the Name
# Manager). Excel evaluates the DEFINED NAME, not the blob. Merging/syncing a
# new blob therefore has no runtime effect until the defined name is
# re-published (the user's manual fix was: delete the name, re-save the module
# in Excel Labs, which republishes it).
#
# The published defined name is a heavily encoded form of the source formula:
#   - future functions get an `_xlfn.` prefix (LAMBDA, UNIQUE, ISOMITTED, ...)
#   - required LAMBDA params get `_xlpm.`; optional `[param]` params get
#     `_xlop.` in the signature (and `_xlpm.` where referenced in the body)
#   - sibling/other-module function calls are module-qualified
#     (`Utility_Foo` -> `Common_InputFunctions.Utility_Foo`)
#
# We do NOT reimplement that encoder. Excel COM does it for us: assigning a
# user-facing formula to `Names.Add`/`Name.RefersTo` makes Excel add the
# `_xlfn`/`_xlpm`/`_xlop` prefixes automatically (validated byte-for-byte
# against real published names). The ONE thing Excel does not do is qualify
# bare sibling calls, so we do that ourselves before assigning.
#
# Self-healing (no state, no switch): for every module function we compute the
# desired user-facing formula, and compare a normalised (encoder-agnostic)
# canonical form of it against the currently published defined name. Only
# missing/mismatched names are republished. On the first run every name is
# stale/missing so all are republished; on later runs only functions whose
# source actually changed differ, so only those are touched.
# ===========================================================================

function Remove-AfeFormulaComments {
  # Strip AFE source comments (`/* ... */` block and `// ...` line comments)
  # from module text, string-aware so `/*`, `//` or `;` inside a "..." literal
  # are preserved. Excel Labs strips these when it publishes a module function,
  # and Excel COM REJECTS a RefersTo formula that still contains them, so we
  # must remove them before both publishing and canonical comparison. A block
  # comment is replaced by a single space to avoid merging adjacent tokens.
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string] $Text
  )

  if ([string]::IsNullOrEmpty($Text)) { return $Text }

  $sb = New-Object System.Text.StringBuilder
  $inString = $false
  $i = 0
  $n = $Text.Length
  while ($i -lt $n) {
    $ch = $Text[$i]
    if ($inString) {
      [void] $sb.Append($ch)
      if ($ch -eq '"') {
        if (($i + 1) -lt $n -and $Text[$i + 1] -eq '"') { [void] $sb.Append($Text[$i + 1]); $i += 2; continue }
        $inString = $false
      }
      $i++; continue
    }
    if ($ch -eq '"') { $inString = $true; [void] $sb.Append($ch); $i++; continue }
    if ($ch -eq '/' -and ($i + 1) -lt $n -and $Text[$i + 1] -eq '*') {
      $i += 2
      while (($i + 1) -lt $n -and -not ($Text[$i] -eq '*' -and $Text[$i + 1] -eq '/')) { $i++ }
      $i += 2  # skip closing */
      [void] $sb.Append(' ')
      continue
    }
    if ($ch -eq '/' -and ($i + 1) -lt $n -and $Text[$i + 1] -eq '/') {
      $i += 2
      while ($i -lt $n -and $Text[$i] -ne "`n") { $i++ }
      continue  # keep the newline itself
    }
    [void] $sb.Append($ch); $i++
  }
  return $sb.ToString()
}

function Split-AfeModuleFunctions {
  # Parse a module's `.text` (== the .xlf content) into its function
  # definitions. Each definition is a bare identifier line followed by an
  # `=LAMBDA(...)` formula, terminated by a `;` at paren/brace/quote depth 0
  # (array constants like {1;2} contain `;` inside braces, so a naive split on
  # `;` is wrong -- we track depth). Comments are stripped first so a `;`
  # inside a comment cannot prematurely terminate a definition.
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string] $ModuleText
  )

  $functions = New-Object System.Collections.Generic.List[object]
  if ([string]::IsNullOrWhiteSpace($ModuleText)) { return $functions }

  $text = $ModuleText.Replace("`r`n", "`n").Replace("`r", "`n")
  $text = Remove-AfeFormulaComments -Text $text

  # Split into statements on top-level `;`.
  $statements = New-Object System.Collections.Generic.List[string]
  $depth = 0
  $inString = $false
  $sb = New-Object System.Text.StringBuilder
  for ($i = 0; $i -lt $text.Length; $i++) {
    $ch = $text[$i]
    if ($inString) {
      [void] $sb.Append($ch)
      if ($ch -eq '"') {
        # doubled "" inside a string is an escaped quote, stay in-string
        if (($i + 1) -lt $text.Length -and $text[$i + 1] -eq '"') {
          [void] $sb.Append($text[$i + 1]); $i++
        } else {
          $inString = $false
        }
      }
      continue
    }
    switch ($ch) {
      '"' { $inString = $true; [void] $sb.Append($ch) }
      '(' { $depth++; [void] $sb.Append($ch) }
      '{' { $depth++; [void] $sb.Append($ch) }
      ')' { if ($depth -gt 0) { $depth-- }; [void] $sb.Append($ch) }
      '}' { if ($depth -gt 0) { $depth-- }; [void] $sb.Append($ch) }
      ';' {
        if ($depth -eq 0) {
          [void] $statements.Add($sb.ToString())
          $sb = New-Object System.Text.StringBuilder
        } else {
          [void] $sb.Append($ch)
        }
      }
      default { [void] $sb.Append($ch) }
    }
  }
  if ($sb.Length -gt 0) { [void] $statements.Add($sb.ToString()) }

  foreach ($stmt in $statements) {
    $lines = $stmt.Split("`n")
    $eqIdx = -1
    for ($j = 0; $j -lt $lines.Length; $j++) {
      if ($lines[$j].TrimStart().StartsWith('=')) { $eqIdx = $j; break }
    }
    if ($eqIdx -lt 0) { continue }  # no formula in this chunk -> not a function

    # Name = last bare-identifier line before the '=' line.
    $name = $null
    for ($k = $eqIdx - 1; $k -ge 0; $k--) {
      $candidate = $lines[$k].Trim()
      if ([string]::IsNullOrWhiteSpace($candidate)) { continue }
      if ($candidate -match '^[A-Za-z_][A-Za-z0-9_]*$') { $name = $candidate }
      break
    }
    if ([string]::IsNullOrWhiteSpace($name)) { continue }

    $formula = ($lines[$eqIdx..($lines.Length - 1)] -join "`n").Trim()
    if (-not $formula.StartsWith('=')) { continue }

    $functions.Add([pscustomobject]@{ Name = $name; Formula = $formula })
  }

  return $functions
}

function Read-AfeWorkbookModules {
  # Read the AFE project from a workbook and return its module files as
  # [pscustomobject]@{ ModuleName; Text }. ModuleName is the blob path minus
  # the leading "/projects/".
  param([Parameter(Mandatory = $true)][string] $WorkbookPath)

  $modules = New-Object System.Collections.Generic.List[object]
  $zip = [System.IO.Compression.ZipFile]::Open($WorkbookPath, 'Read')
  try {
    foreach ($entry in $zip.Entries) {
      if ($entry.FullName -notlike 'customXml/item*.xml') { continue }
      $reader = [System.IO.StreamReader]::new($entry.Open())
      try { $xml = $reader.ReadToEnd() } finally { $reader.Dispose() }
      if ($xml -notmatch '<AFEJSONBlob') { continue }
      $b64 = [regex]::Match($xml, '(?s)<AFEJSONBlob[^>]*>(.*)</AFEJSONBlob>').Groups[1].Value
      if ([string]::IsNullOrWhiteSpace($b64)) { continue }
      $json = [System.Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($b64))
      $project = $json | ConvertFrom-Json
      foreach ($f in @($project.files)) {
        $path = [string] $f.path
        if ([string]::IsNullOrWhiteSpace($path)) { continue }
        $moduleName = $path -replace '^/projects/', ''
        $modules.Add([pscustomobject]@{ ModuleName = $moduleName; Text = [string] $f.text })
      }
      break
    }
  } finally { $zip.Dispose() }
  return $modules
}

function ConvertFrom-AfeLongText {
  # Excel stores a string literal longer than the 255-char formula-string limit
  # as `_LONGTEXT("chunk1","chunk2",...)`, splitting the text into <=255-char
  # chunks that concatenate back to the original. The source has a single
  # "..." literal, so we unwrap each `_LONGTEXT(...)` back to one merged string
  # for comparison. String-aware paren matching is required because the chunks
  # contain (), {} and [] as literal text.
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string] $Text
  )

  if ([string]::IsNullOrEmpty($Text)) { return $Text }
  $token = '_LONGTEXT('
  while ($true) {
    $idx = $Text.IndexOf($token)
    if ($idx -lt 0) { break }
    $openParen = $idx + $token.Length - 1  # index of the '('
    $i = $openParen
    $depth = 0
    $inStr = $false
    $close = -1
    while ($i -lt $Text.Length) {
      $ch = $Text[$i]
      if ($inStr) {
        if ($ch -eq '"') {
          if (($i + 1) -lt $Text.Length -and $Text[$i + 1] -eq '"') { $i += 2; continue }
          $inStr = $false
        }
        $i++; continue
      }
      if ($ch -eq '"') { $inStr = $true }
      elseif ($ch -eq '(') { $depth++ }
      elseif ($ch -eq ')') { $depth--; if ($depth -eq 0) { $close = $i; break } }
      $i++
    }
    if ($close -lt 0) { break }  # malformed; leave as-is
    $inner = $Text.Substring($openParen + 1, $close - $openParen - 1)
    # Merge the split chunks: the separator between chunks is exactly `","`.
    $merged = $inner -replace '","', ''
    $Text = $Text.Substring(0, $idx) + $merged + $Text.Substring($close + 1)
  }
  return $Text
}

function Get-CanonicalAfeFormula {
  # Normalise a formula (either the raw published refersTo or a user-facing
  # formula) into an encoder-agnostic canonical string for comparison. We strip
  # ONLY what Excel reliably adds/removes, so any residual difference errs
  # toward "changed" (a harmless extra republish) rather than a missed one.
  param(
    [Parameter(Mandatory = $true)]
    [AllowEmptyString()]
    [string] $Text
  )

  $s = $Text
  # Excel prefixes encoded tokens with _xlfn. (future functions), _xlpm.
  # (required params), _xlop. (optional params), _xlws. (worksheet functions
  # like FILTER), and can stack them (_xlfn._xlws.FILTER). Strip any _xl<..>.
  # marker generically -- real params/functions never start with "_xl".
  $s = [regex]::Replace($s, '(?i)_xl[a-z]+\.', '')
  $s = $s -replace '\s+', ''         # whitespace/newlines (do before _LONGTEXT so chunk separators are exactly `","`)
  # Excel prefixes a cross-module defined-name reference with a self-workbook
  # external index, e.g. `[0]!Common_InputFunctions.Utility_Foo`. Strip the
  # `[<n>]!` prefix (self-ref, semantically a no-op) so both sides converge.
  $s = [regex]::Replace($s, '\[\d+\]!', '')
  $s = ConvertFrom-AfeLongText -Text $s   # unwrap Excel's long-string chunking
  $s = $s -replace '[\[\]]', ''      # optional-param brackets (stripped both sides)
  # Excel normalises numeric literals (strips trailing zeros: 0.50 -> 0.5, and
  # rewrites scientific notation: 1.132e-4 -> 0.0001132). Parse every numeric
  # token to a canonical round-trip value so data-array/scalar constants
  # converge. Both the expected and stored forms pass through here, so the same
  # transform applies to each side (safe for comparison). Identifiers with
  # digits (e.g. VEERG_11_1) are protected by the leading (?<![\w.]) boundary.
  $numRx = [regex]'(?<![\w.])\d+(?:\.\d+)?(?:[eE][+-]?\d+)?'
  $s = $numRx.Replace($s, {
      param($m)
      $d = 0.0
      if ([double]::TryParse($m.Value,
          [System.Globalization.NumberStyles]::Float,
          [System.Globalization.CultureInfo]::InvariantCulture, [ref] $d)) {
        return $d.ToString('R', [System.Globalization.CultureInfo]::InvariantCulture)
      }
      return $m.Value
    })
  if ($s.StartsWith('=')) { $s = $s.Substring(1) }
  return $s
}

function ConvertTo-QualifiedAfeFormula {
  # Module-qualify bare sibling/other-module function calls in a formula:
  # `Utility_Foo(` -> `Common_InputFunctions.Utility_Foo(`. Already-qualified
  # references (preceded by `.`) and same-name substrings of longer identifiers
  # are left alone.
  param(
    [Parameter(Mandatory = $true)][string] $Formula,
    [Parameter(Mandatory = $true)][hashtable] $FuncModuleMap
  )

  if ($FuncModuleMap.Count -eq 0) { return $Formula }

  # Longest names first so alternation is greedy for the fuller identifier.
  $names = @($FuncModuleMap.Keys | Sort-Object { $_.Length } -Descending)
  $escaped = ($names | ForEach-Object { [regex]::Escape($_) }) -join '|'
  $pattern = '(?<![\w.])(' + $escaped + ')(?=\s*\()'
  $rx = [regex]::new($pattern)
  $map = $FuncModuleMap
  return $rx.Replace($Formula, {
      param($m)
      $fn = $m.Groups[1].Value
      return ('{0}.{1}' -f $map[$fn], $fn)
    })
}

function Get-WorkbookDefinedNameMap {
  # Fast (no COM) read of xl/workbook.xml -> hashtable of defined name -> its
  # refersTo (InnerText). Used to detect which module functions need
  # republishing before paying for a COM session.
  param([Parameter(Mandatory = $true)][string] $WorkbookPath)

  $map = @{}
  $zip = [System.IO.Compression.ZipFile]::Open($WorkbookPath, 'Read')
  try {
    $entry = $zip.GetEntry('xl/workbook.xml')
    if ($null -eq $entry) { return $map }
    $reader = [System.IO.StreamReader]::new($entry.Open(), [System.Text.Encoding]::UTF8)
    try { $xmlText = $reader.ReadToEnd() } finally { $reader.Dispose() }
    $doc = New-Object System.Xml.XmlDocument
    $doc.LoadXml($xmlText)
    $ns = New-Object System.Xml.XmlNamespaceManager($doc.NameTable)
    $ns.AddNamespace('x', 'http://schemas.openxmlformats.org/spreadsheetml/2006/main')
    foreach ($n in @($doc.SelectNodes('//x:definedName', $ns))) {
      # Only workbook-scoped names (module functions are workbook-scoped).
      if (-not [string]::IsNullOrEmpty($n.GetAttribute('localSheetId'))) { continue }
      $nm = $n.GetAttribute('name')
      if ([string]::IsNullOrEmpty($nm)) { continue }
      if (-not $map.ContainsKey($nm)) { $map[$nm] = $n.InnerText }
    }
  } finally { $zip.Dispose() }
  return $map
}

function Invoke-AfeNamedFunctionRepublish {
  # Self-healing republish of every AFE module LAMBDA function in $WorkbookPath.
  # Only names that are missing or whose canonical form differs from the source
  # module text are (re)written, so the first run fixes everything and later
  # runs touch only changed functions. Returns a summary object.
  param(
    [Parameter(Mandatory = $true)][string] $WorkbookPath,
    $ExcelApp = $null,           # optional existing Excel.Application to reuse
    [switch] $DryRun
  )

  $result = [pscustomobject]@{
    Checked     = 0
    Republished = New-Object System.Collections.Generic.List[string]
    Failed      = New-Object System.Collections.Generic.List[string]
    Skipped     = New-Object System.Collections.Generic.List[string]
    HasAfe      = $false
  }

  $modules = Read-AfeWorkbookModules -WorkbookPath $WorkbookPath
  if ($modules.Count -eq 0) { return $result }
  $result.HasAfe = $true

  # Build function -> owning module map and the list of desired names.
  $funcModuleMap = @{}
  $moduleFunctions = New-Object System.Collections.Generic.List[object]
  foreach ($module in $modules) {
    foreach ($fn in (Split-AfeModuleFunctions -ModuleText $module.Text)) {
      if (-not $funcModuleMap.ContainsKey($fn.Name)) {
        $funcModuleMap[$fn.Name] = $module.ModuleName
      }
      $moduleFunctions.Add([pscustomobject]@{
          ModuleName = $module.ModuleName
          FuncName   = $fn.Name
          Formula    = $fn.Formula
        })
    }
  }
  if ($moduleFunctions.Count -eq 0) { return $result }

  # Excel caps a defined name's RefersTo at ~8192 chars.
  $maxRefersToLen = 8192

  # Desired defined names + expected canonical form.
  $desired = New-Object System.Collections.Generic.List[object]
  foreach ($mf in $moduleFunctions) {
    $name = ('{0}.{1}' -f $mf.ModuleName, $mf.FuncName)
    # Only =LAMBDA(...) functions are published by Excel Labs as reusable named
    # functions. Non-LAMBDA helpers (plain formulas using structured table refs
    # or [#This Row]) cannot be valid workbook-scoped defined names -- trying to
    # add them fails and would otherwise leave a bogus name behind.
    if ($mf.Formula -notmatch '^(?i)=\s*LAMBDA\s*\(') {
      [void] $result.Skipped.Add(('{0} (not a LAMBDA)' -f $name))
      continue
    }
    $qualified = ConvertTo-QualifiedAfeFormula -Formula $mf.Formula -FuncModuleMap $funcModuleMap
    # Giant data-array LAMBDAs exceed the RefersTo length limit and cannot be
    # stored as a full defined name (Excel Labs itself truncates them).
    if ($qualified.Length -gt $maxRefersToLen) {
      [void] $result.Skipped.Add(('{0} (refersTo {1} > {2} chars)' -f $name, $qualified.Length, $maxRefersToLen))
      continue
    }
    $desired.Add([pscustomobject]@{
        Name              = $name
        Formula           = $qualified
        CanonicalExpected = (Get-CanonicalAfeFormula -Text $qualified)
      })
  }
  $result.Checked = $desired.Count

  # Detect mismatches without COM.
  $currentNames = Get-WorkbookDefinedNameMap -WorkbookPath $WorkbookPath
  $mismatches = New-Object System.Collections.Generic.List[object]
  foreach ($d in $desired) {
    $needs = $true
    if ($currentNames.ContainsKey($d.Name)) {
      $canonCurrent = Get-CanonicalAfeFormula -Text ([string] $currentNames[$d.Name])
      if ($canonCurrent -eq $d.CanonicalExpected) { $needs = $false }
    }
    if ($needs) { $mismatches.Add($d) }
  }

  if ($mismatches.Count -eq 0) { return $result }
  if ($DryRun) {
    foreach ($m in $mismatches) { [void] $result.Republished.Add($m.Name) }
    return $result
  }

  # COM session: pass 1 ensures every mismatched name exists (forward-ref
  # safety), pass 2 assigns the real formula (Excel re-encodes on assignment).
  $ownExcel = $false
  $excel = $ExcelApp
  $wb = $null
  $prevCalc = $null
  try {
    if ($null -eq $excel) {
      $excel = New-Object -ComObject Excel.Application
      $excel.Visible = $false
      $ownExcel = $true
    }
    $excel.DisplayAlerts = $false
    $wb = $excel.Workbooks.Open($WorkbookPath)
    try { $prevCalc = $excel.Calculation; $excel.Calculation = -4135 } catch { }  # xlCalculationManual (after Open)

    $newlyAdded = @{}
    foreach ($m in $mismatches) {
      if (-not $currentNames.ContainsKey($m.Name)) {
        try { $wb.Names.Add($m.Name, '=0') | Out-Null; $newlyAdded[$m.Name] = $true } catch { }
      }
    }

    foreach ($m in $mismatches) {
      try {
        $existing = $null
        try { $existing = $wb.Names.Item($m.Name) } catch { $existing = $null }
        if ($null -ne $existing) {
          $existing.RefersTo = $m.Formula
        } else {
          $wb.Names.Add($m.Name, $m.Formula) | Out-Null
        }
        [void] $result.Republished.Add($m.Name)
      } catch {
        [void] $result.Failed.Add(('{0}: {1}' -f $m.Name, $_.Exception.Message))
        # Roll back the pass-1 '=0' placeholder so a failed add never leaves a
        # bogus name behind (restores the pre-run "name absent" state).
        if ($newlyAdded.ContainsKey($m.Name)) {
          try { $wb.Names.Item($m.Name).Delete() } catch { }
        }
      }
    }

    try { if ($null -ne $prevCalc) { $excel.Calculation = $prevCalc } } catch { }
    $wb.Save()
    $wb.Close($false)
    $wb = $null
  } finally {
    if ($null -ne $wb) {
      try { $wb.Close($false) } catch { }
      try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($wb) | Out-Null } catch { }
    }
    if ($ownExcel -and $null -ne $excel) {
      try { $excel.Quit() } catch { }
      try { [System.Runtime.InteropServices.Marshal]::ReleaseComObject($excel) | Out-Null } catch { }
      [GC]::Collect(); [GC]::WaitForPendingFinalizers()
    }
  }

  return $result
}
