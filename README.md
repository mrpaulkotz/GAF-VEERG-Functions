# GAF-VEERG-Functions
This file includes instructions from getting information from a VEERG document and adding it to a VEERG equation template.

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
  )
;

FunctionPrefix_FunctionName
  =LAMBDA("FunctionPrefix");

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
    MAKEARRAY(NumberOfArguments, 2, 
      LAMBDA(r,c, 
        INDEX({
          "Argument.ArgumentVariable","Argument.ArgumentDescription : Argument.ArgumentUnit";
          "Argument.ArgumentVariable","Argument.ArgumentDescription : Argument.ArgumentUnit"
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
TM_jf = total mass of inorganic fertiliser type f applied to production system j (kg)
FN_(inorganic,f) = fraction of nitrogen in inorganic fertiliser type f (kg N/kg)
j = Production system
inorganic =Inorganic fertiliser
f = Inorganic fertiliser type
--------------------------------------
*/


VEERG_5_1_1_1__2_MassOfNitrogenInInorganicFertiliser
  =LAMBDA(
    TMjf, FNinorganicf,
    TMjf * FNinorganicf
  )
;

VEERG_5_1_1_1__2_MassOfNitrogenInInorganicFertiliser_FunctionName
  =LAMBDA("VEERG_5_1_1_1__2_MassOfNitrogenInInorganicFertiliser");

VEERG_5_1_1_1__2_MassOfNitrogenInInorganicFertiliser_Title
  =LAMBDA("Mass of nitrogen in inorganic fertiliser applied to soil");

VEERG_5_1_1_1__2_MassOfNitrogenInInorganicFertiliser_Variable
  =LAMBDA("MNjf");

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
    MAKEARRAY(5, 2, 
      LAMBDA(r,c, 
        INDEX({
          "TMjf","total mass of inorganic fertiliser type f applied to production system j (kg)";
          "FNinorganicf","fraction of nitrogen in inorganic fertiliser type f (kg N/kg)";
          "j","Production system";
          "inorganic", "Inorganic fertiliser";
          "f","Fertiliser type"
        }, r, c)
      )
    )
  );