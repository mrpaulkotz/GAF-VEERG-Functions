# Shared build modules: nav-menu.ps1 + worksheet-view.ps1

Dot-sourced helpers under `scripts/`, used by build-enterprise-excel.ps1,
build-scope3-excel.ps1, and the generic chapter build sync-xlf-to-excel-labs.ps1.
Pattern: `. (Join-Path $PSScriptRoot 'name.ps1')` near the other dot-sources.

## scripts/nav-menu.ps1 (COM-based; caller passes an OPEN workbook)
- `Set-NavMenu -Target <wb COM> -CategoryMap <hashtable sheet->category> -Labels <hashtable>`
  rebuilds the column-A menu on EVERY sheet. Returns count of sheets updated.
  - Groups (render order): untitled (Home,Overview,Results) -> INPUTS (Input*) ->
    CALCULATIONS (category 'calculation') -> APPENDICES (else).
  - Untitled order forced: Home, Overview, Results.
  - Styles used: `Menu section title`, `Menu link default`,
    `Menu link selected results|input|equations`, `Menu link selected`,
    `Input page heading` (A1 logo, copied from a donor sheet).
  - Clears A2:A160, writes `=HYPERLINK("#'Sheet'!A1","Label")` then applies style
    (HYPERLINK auto-applies built-in Hyperlink style, so set menu style AFTER).
  - Style assignment wrapped in try/catch -> missing styles just skip styling.
- `Get-InferredCategoryMap -Workbook <wb COM>` -> hashtable by tab-name convention:
  `Input*`->input; `Constants*`->constants; `^\s*\d` OR `Calc*`->calculation.
  (Home/Overview/Results handled by name inside Set-NavMenu.)

## scripts/worksheet-view.ps1 (XML-only; headless-safe)
- `Set-WorkbookZoom -Path <xlsx> [-Zoom 100]` returns count of changed sheet parts.
  - Loads System.IO.Compression.FileSystem itself (self-contained).
  - Opens zip 'Update'; for each `^xl/worksheets/sheet\d+\.xml$` rewrites every
    `<sheetView ...>` start tag (regex `'<sheetView\b[^>]*?/?>'`): strips existing
    `zoomScale(Normal|Sheet|PageLayoutView)?="..."`, appends
    ` zoomScale="N" zoomScaleNormal="N"`. Two-phase (read all, then delete+recreate).
    UTF8 no BOM.
  - Wired into all 3 builders, guarded `if (-not $DryRun)`, after the final XML
    passes / near summary. COM Save preserves the XML-set zoom.

## Chapter build nav-menu integration (sync-xlf-to-excel-labs.ps1)
- OPT-IN via `-Menu` switch (default OFF; normal `npm run build` does not rewrite
  menus). `build.ps1` threads `-Menu` through; npm script `build:menu`.
- `Update-ChapterNavMenus -Workbooks <FileInfo[]> -DryRun` opens each workbook via
  COM, `Get-InferredCategoryMap` -> `Set-NavMenu`, Save, Close. Same COM cleanup
  (`Invoke-ComObjectCleanup`) + transient-COM handling as the propagation pass.
  Called LAST (after Sync-CommonSheetsAcrossWorkbooks) so menu reflects final sheets.
- Verified all chapter workbooks carry the 7 menu styles and tab names match the
  inference conventions (fast XML probe of styles.xml + workbook.xml, no COM).
- Scope3 seeds `Get-InferredCategoryMap` then overlays its `$ImportMap` categories
  before calling Set-NavMenu (so template calc sheets not in ImportMap classify right).

## Gotchas
- Verify zoom/menu via XML (read sheetN.xml for zoomScale / count `HYPERLINK("#`),
  NOT via headless recalc.
- File-lock IOException on rebuild = workbook open in Excel; ask user to close.
- Kill ONLY headless Excel: `Get-Process EXCEL | ? { $_.MainWindowHandle -eq 0 } | Stop-Process -Force`.
