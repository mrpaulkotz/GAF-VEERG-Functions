# GAF-VEERG-Functions
This file includes instructions from getting information from a VEERG document and adding it to a VEERG equation template.
The file extension is .xlf

Rules:
1. Use spaces instead of tab characters for indenting. Tab characters are not valid in .xlf Excel formula syntax.
2. Do not escape backslashes in LatexEquation strings. For example, the string "\times" should remain as "\times" and not "\\times".
3. Formula variables in the source text may include subscripts eg: MN_{jm=5,T=1} . When generating variables, use the following format example: MN_jm5T1 instead of MNjm5T1.
4. Do not use SUMPRODUCT Excel formulas. For example, "SUMPRODUCT(MN_jmT23, 1 - EF_mT23 - FracGASM_mT23) * PF" should be "(MN_jmT23 * (1 - EF_mT23 - FracGASM_mT23)) * PF"
5. Sum symbols can be used in latex equations.

Function naming convention:

FunctionPrefix template:
VEERG_ChapterNumber_Methodology_MethodNumber__EquationNumber__FunctionName

VEERG equation template:

/* 
--------------------------------------
FunctionPrefix
Title
Variable
Unit
LatexEquation
Arguments
--------------------------------------
*/


FunctionPrefix
  =LAMBDA(
    FormulaArguments,
    Formula
  );

FunctionPrefix_Title
  =LAMBDA("Title");

FunctionPrefix_Variable
  =LAMBDA("Variable");

FunctionPrefix_Unit
  =LAMBDA("Unit");

FunctionPrefix_Source
  =LAMBDA("Source");

FunctionPrefix_NIRReference
  =LAMBDA("NIRReference");

FunctionPrefix_LatexEquation
  =LAMBDA("LatexEquation");

FunctionPrefix_Arguments
  =LAMBDA(
    MAKEARRAY(NumberOfArguments, 4, 
      LAMBDA(r,c, 
        INDEX({
          "Argument.ArgumentVariable","Argument.ArgumentDescription", "Argument.ArgumentUnit", "Argument.ArgumentType";
          "Argument.ArgumentVariable","Argument.ArgumentDescription", "Argument.ArgumentUnit", "Argument.ArgumentType"
        }, r, c)
      )
    )
  );

==========================================================================

Example: If:
- Chapter is "5 Fertiliser Use"
- the section is "5.1 Inorganic fertiliser application"
- the methodology is "5.1.1	Estimation methodology"
- The method is "5.1.1.1	Method 1 – Inorganic Fertiliser Application N2O Emissions"
- The equation number is (2)
- The equation description is "Mass of nitrogen in inorganic fertiliser applied to soil, MN_jf (kg N), is calculated as:"
- The equation as Microsoft professional equation is : "〖MN〗_jf=TM_jf×FN_(inorganic,f)"
- The equation arguments are: "Where	TM_jf = total mass of inorganic fertiliser type f applied to production system j (kg) FN_(inorganic,f) = fraction of nitrogen in inorganic fertiliser type f (kg N/kg)"


FunctionPrefix will be:
VEERG_5_1_1_1__2__MassOfNitrogenInInorganicFertiliser

Title will be:
Mass of nitrogen in inorganic fertiliser applied to soil

Variable will be:
MN_jf

Uunit will be:
kg N

LatexEquation will be:
{MN}_{jf}=TM_{jf}\times FN_{inorganic,f}

Arguments will be:
"TMjf","total mass of inorganic fertiliser type f applied to production system j (kg)";
"FNinorganicf","fraction of nitrogen in inorganic fertiliser type f (kg N/kg)";


VEERG Equation template populated with values from the example:

/* 
--------------------------------------
VEERG_5_1_1_1__2_MassOfNitrogenInInorganicFertiliser
Mass of nitrogen in inorganic fertiliser applied to soil, MN_jf (kg N), is calculated as:
MNjf
kg N
{MN}_{jf}=TM_{jf}\times FN_{inorganic,f}
TM_jf = total mass of inorganic fertiliser type f applied to production system j (kg) Calculated by X.X.X.X (X)
FN_(inorganic,f) = fraction of nitrogen in inorganic fertiliser type f (kg N/kg) Constant
j = Production system Input
inorganic =Inorganic fertiliser Input
f = Inorganic fertiliser type Input
--------------------------------------
*/


VEERG_5_1_1_1__2_MassOfNitrogenInInorganicFertiliser
  =LAMBDA(
    TM_jf, FN_inorganicf,
    TM_jf * FN_inorganicf
  );

VEERG_5_1_1_1__2_MassOfNitrogenInInorganicFertiliser_Title
  =LAMBDA("Mass of nitrogen in inorganic fertiliser applied to soil");

VEERG_5_1_1_1__2_MassOfNitrogenInInorganicFertiliser_Variable
  =LAMBDA("MN_jf");

VEERG_5_1_1_1__2_MassOfNitrogenInInorganicFertiliser_Unit
  =LAMBDA("kg N");

VEERG_5_1_1_1__2_MassOfNitrogenInInorganicFertiliser_Source
  =LAMBDA("VEERG 2026: 5.1.1.1, Equation (2)");

VEERG_5_1_1_1__2_MassOfNitrogenInInorganicFertiliser_NIRReference
  =LAMBDA("National Inventory Report Volume 1, 2023: Equation 3.D.A_1");

VEERG_5_1_1_1__2_MassOfNitrogenInInorganicFertiliser_LatexEquation
  =LAMBDA("{MN}_{jf}=TM_{jf}\times FN_{inorganic,f}");

VEERG_5_1_1_1__2_MassOfNitrogenInInorganicFertiliser_Arguments
  =LAMBDA(
    MAKEARRAY(5, 4, 
      LAMBDA(r,c, 
        INDEX({
          "TM_jf","total mass of inorganic fertiliser type f applied to production system j", "kg", "Calculated by";
          "FN_inorganicf","fraction of nitrogen in inorganic fertiliser type f", "kg N/kg", "Constant";
          "j","Production system", "", "Input";
          "inorganic", "Inorganic fertiliser", "", "Lookup";
          "f","Fertiliser type", "", "Lookup"
        }, r, c)
      )
    )
  );

==========================================================================

# Source-data JSON generation

Source-data lookup tables (crude protein, digestibility, liveweight, etc.) are
authored as named Excel LAMBDA definitions in the `.xlf` files under
`source-data/` (e.g. `source-data/SourceData_PastureBeef.xlf`). Those `.xlf`
files are the **source of truth**.

At runtime the app does not parse the LAMBDA grammar. Instead, a build step
converts each `.xlf` into a canonical, machine-readable JSON artifact
(`<basename>.sourcedata.json`) written to `generated-sourcedata/`. The
`generated-sourcedata/` files are **derived artifacts** — never edit them by
hand; regenerate them from the `.xlf` source instead.

## How the .xlf tables are encoded

Each table is owned by a `<Prefix>_Data` LAMBDA:

```
<Prefix>_Data =LAMBDA(MAKEARRAY(<rows>, <cols>, LAMBDA(r,c, INDEX({ <matrix> }, r, c))))
```

- `<matrix>` uses `;` to separate rows and `,` to separate cells.
- The first matrix row is the header.
- Strings are double-quoted, with `""` as an escaped quote.
- Sentinel cell values (`"NO"`, `"n/a"`, `"na"`, `"-"`) are quoted in the source
  and preserved verbatim as strings.
- Numeric cells are emitted as JSON numbers; everything else stays a string.
- Scalar `<Prefix>_Data =LAMBDA(0.08)` definitions (no `MAKEARRAY`) are not
  tables and are skipped.

Per-table metadata lives in sibling LAMBDAs sharing the same `<Prefix>`:
`<Prefix>_Title`, `<Prefix>_Variable`, `<Prefix>_Unit`, `<Prefix>_Source`,
`<Prefix>_Variation`.

## Regenerating the JSON

Run one of the npm scripts from the repo root:

```powershell
# Convert every source-data/SourceData_*.xlf into generated-sourcedata/*.sourcedata.json
npm run build:source-data

# Validate/parse only — prints what would be written, writes nothing
npm run build:source-data:dry
```

Both wrap `scripts/build-source-data-json.ps1`. You can also call the script
directly for finer control:

```powershell
# All .xlf files
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-source-data-json.ps1

# A single .xlf file
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-source-data-json.ps1 -XlfPath .\source-data\SourceData_PastureBeef.xlf

# Dry run (no writes)
powershell -NoProfile -ExecutionPolicy Bypass -File .\scripts\build-source-data-json.ps1 -DryRun
```

Script parameters:

- `-RepoRoot` — repository root. Defaults to the parent of `scripts/`.
- `-XlfPath` — optional path to a single `SourceData_*.xlf`. When omitted, every
  `source-data/SourceData_*.xlf` is processed.
- `-DryRun` — parse and validate but write nothing.

The generated JSON uses `schemaVersion = 1`. The full `build.ps1` also runs this
step automatically (after syncing the `.xlf` sources to Excel Labs and before
building the input-fields JSON), so a plain `npm run build` refreshes the
source-data JSON too.

## How the JSON is consumed

The conversational-input app reads the generated JSON via
`getGeneratedSourceDataRoot()` (resolves to `<package>/generated-sourcedata`,
overridable with the `SOURCE_DATA_JSON_DIR` env var). InputFields / `_overrides`
files pin a dataset by setting `DefaultDataDocumentType: "JSON"` and a
`DefaultDataFile` path. That path is resolved from the app's project root, so it
must include the package prefix, for example:

```
node_modules/gaf-veerg-functions/generated-sourcedata/SourceData_PastureBeef.sourcedata.json
```

