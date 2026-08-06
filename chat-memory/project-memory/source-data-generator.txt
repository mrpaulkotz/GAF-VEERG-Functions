# build-source-data-json.ps1

- Parses LAMBDA text in .xlf -> generated-sourcedata/<basename>.sourcedata.json.
- Discovery: source-data/SourceData_*.xlf (glob) PLUS explicit list of module
  files `<Module>_SourceData.xlf` (AgResidue, Common, CommonCropping,
  CommonLivestock, Electricity, Fertiliser, Fuel, Refrigerants, RiceCultivation,
  Scope3, WasteSolid, Wastewater). Missing ones warn+skip. -XlfPath = single file.
- Prefix in regex is generic: `[A-Za-z][A-Za-z0-9_]*?` (handles SourceData_*,
  Fuel_*, and single-token like CropPurposeAndYield_Data with no internal `_`).
- Metadata value may be single OR double paren: =LAMBDA("x") or =LAMBDA(("x")).
  Regex tail: LAMBDA\(\s*\(?\s*"..."\s*\)?\s*\).
- Metadata kinds: Title|Variable|Description|Unit|Source|Variation. Model has both
  `variable` (old files) and `description` (new module files) fields; each empty when absent.
- Row-count mismatch warnings (e.g. Refrigerants declares MAKEARRAY(81,2) but has 8
  rows; off-by-one in Common/Poultry) are SOURCE data-authoring discrepancies, not
  parser bugs. Parser extracts actual matrix rows and warns.
