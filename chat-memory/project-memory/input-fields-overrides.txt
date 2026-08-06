# InputFields override mechanism (build-input-fields-json.ps1)

- Per-field override files live at `InputFields/_overrides/<Module>.json`, hand-maintained, never regenerated. Merged over generated output on every `npm run build:input-fields`.
- SEPARATE from enterprise defs in `Enterprises/<Enterprise>.json` (do NOT put input-field overrides there).
- `Merge-Override` does deep per-field merge (rewritten from old shallow whole-value replace):
  - Top-level keys starting with `_` are ignored (docs/schema/comments).
  - `InputCells` = map keyed by CellName; props shallow-applied onto matching ordered-dict field.
  - `InputTables` = map keyed by TableName; nested `Columns` map keyed by column key. Columns live under `Rows.Row.<key>` (RowsToCols) or `Cols.Column.<key>` (ColsToRows).
  - Unknown cell/table/column targets -> Add-ValidationWarning.
  - Other top-level keys fall back to whole-value replace (backward compat).
- Override props are passthrough (Label, Group, Order, Hidden, UseDefault, Default, ...); can also override generated props like CellType.
- Example starter file: `InputFields/_overrides/Enterprise_PastureBeef.json`.

# Cascading (dependent) select options
- Dependent dropdowns use validation like =INDIRECT("Table_..._" & SUBSTITUTE($E$7," ","") & "[Region]"). Parent driver $E$7 may itself be a passthrough formula (=X_Cell_Site_State).
- Resolve-ParentInfo follows passthrough formulas to find the true source cell w/ the list validation. It must follow BOTH cell-address passthroughs (=$X$Y) AND bare defined-name passthroughs (=X_Cell_Site_State). Fixed a bug where only address form was followed, leaving Options={} and DependentOn as a raw address (e.g. E7). Now DependentOn resolves to the named cell and Options are the nested per-parent lists ("n/a" for parent values with no child table).
- The concatenated-cascade branch was unified (removed the fragile single-SUBSTITUTE regex that mis-parsed nested calls, producing broken DependentOn like "SUBSTITUTE(SUBSTITUTE(SUBSTITUTE(F63"). Now: Get-InnerCallArg pulls the INDIRECT arg, Split-TopLevelAmpersand isolates the single non-literal driver seg + prefix/suffix literals, then Resolve-CascadeDriver peels nested SUBSTITUTE(inner,"from","to") wrappers to the bare ref + ordered (innermost-first) sub pairs. Each parent value is normalised with the SAME sub chain to build <prefix><norm><suffix>; Options are keyed by the normalised value (matches Excel's SUBSTITUTE, e.g. "Sardines (whole)" -> "Sardineswhole"). DependentOn prefers the sibling table-column key (e.g. Ingredient1). Helpers: Split-TopLevelComma, Resolve-CascadeDriver.
- Header-range structured refs: =INDIRECT("Table[[#Headers],[ColA]:[ColB]]") now resolve. Resolve-StructuredOrEvaluated detects the [#Headers] range form (checked before the single-column regex, which its nested brackets defeat) and Get-ListObjectHeaderRangeValues returns the header labels of columns ColA..ColB from the ListObject (Worksheet.Evaluate is unreliable for cross-sheet structured refs).

# Date field typing
- Set-DateFieldTypes runs before ConvertTo-InputFieldsModel returns: any field whose KEY contains 'date' (case-insensitive) with CellType 'number'/'text' becomes CellType 'date' (Excel stores dates as numbers so format detection misses them). Covers InputCells + table Rows/Cols columns. Leaves select/formula alone.

# Name field typing
- Set-NameFieldTypes runs right after Set-DateFieldTypes: any field whose KEY contains 'name' (case-insensitive) with CellType 'number' becomes 'text'. Root cause: Get-CellTypeByFormat falls back to 'number' when the representative body cell is blank, so free-text label columns (e.g. TransactionName in Table_Input_LivestockSales/Purchases) were mistyped 'number' whenever their sample cell happened to be empty. Leaves select/formula/date alone.
