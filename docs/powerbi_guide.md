# Power BI dashboard guide

How to build the ECL dashboard by hand in Power BI Desktop from the CSV files
the batch exports. The CSVs are the interface: Power BI never connects to
Oracle, so the dashboard shows exactly the numbers the HTML report shows.

> The project doesn't include a `.pbix`. These steps were written against the
> CSV layout below. Power BI Desktop isn't installed on the machine the
> project was built on, so they haven't been clicked through there.

## What the batch gives you

`scripts/run_all_months.sh` leaves one folder per reporting date in `reports/`:

| File | Grain | Columns |
|---|---|---|
| `ecl_detail.csv` | one row per loan | `REPORTING_DATE, LOAN_ID, GRADE, SUB_GRADE, ADDR_STATE, PURPOSE, STAGE, REASON_CODE, BALANCE, INT_RATE, REMAINING_MONTHS, HORIZON_MONTHS, DPD, RESTRUCTURED_FLAG, MONTHS_IN_STAGE3, LGD, PD_12M, ECL_BASE, ECL_DOWNSIDE, ECL_SEVERE, ECL_WEIGHTED, FLOOR_RATE, FLOOR_AMOUNT, ECL_FINAL, FLOOR_APPLIED` |
| `ecl_movement.csv` | stage | `REPORTING_DATE, PREV_DATE, STAGE, OPENING_ECL, NEW_LOANS, TRANSFERS_IN, TRANSFERS_OUT, EXITS, REMEASUREMENT, CLOSING_ECL, DIFFERENCE` |
| `stage_migration.csv` | from-stage × to-stage | `REPORTING_DATE, PREV_DATE, FROM_STAGE, TO_STAGE, LOANS, BALANCE_FROM, BALANCE_TO` |
| `scenario_sensitivity.csv` | date | `REPORTING_DATE, LOANS, ECL_BASE, ECL_DOWNSIDE, ECL_SEVERE, ECL_WEIGHTED, ECL_FINAL` |
| `dq_summary.csv` | rule | `REPORTING_DATE, RULE_ID, RULE_NAME, SEVERITY, ERRORS, ROWS_RECEIVED, SHARE_OF_ROWS` |
| `ecl_by_stage.csv`, `ecl_by_grade.csv`, `ecl_by_state.csv`, `floor_impact.csv` | stage, grade or state | Aggregates of `ecl_detail.csv`. Power BI rebuilds them with measures; keep them for cross-checking. |

Money is in US dollars with up to two decimals, rates are fractions (0.0789 is
7.89%), and dates are ISO (`2019-09-30`). `STAGE` is 1, 2 or 3. In the
migration file the stages are text, because the rows include `NEW` and the
columns include `EXITED`.

## 1. Load the data (Power Query)

Use the Folder connector, so a new month's folder is picked up on refresh.

1. **Get data → Folder**, choose the project's `reports/` folder, then **Transform Data**.
2. Filter `Name` to `ecl_detail.csv` and click **Combine Files** on the `Content` column. Name the query `ECL detail` and remove the `Source.Name` column.
3. Set the column types with **Change Type → Using Locale → English (United States)**. Then the `.` decimals and ISO dates parse the same way whatever the Windows region is.
   - `REPORTING_DATE`: Date
   - `LOAN_ID`, `STAGE`, `DPD`, `REMAINING_MONTHS`, `HORIZON_MONTHS`, `MONTHS_IN_STAGE3`: Whole Number
   - `BALANCE`, `ECL_*`, `FLOOR_AMOUNT`: Fixed Decimal Number
   - `INT_RATE`, `LGD`, `PD_12M`, `FLOOR_RATE`: Decimal Number
   - everything else: Text
4. Repeat steps 1 to 3 for each summary file: `ecl_movement.csv` → `ECL movement`, `stage_migration.csv` → `Stage migration`, `scenario_sensitivity.csv` → `Scenarios`, `dq_summary.csv` → `Data quality`. Use a new Folder query each time rather than duplicating the first one. **Combine Files** builds a helper from a sample file, and the detail file's helper expects the detail file's columns. The amounts are Fixed Decimal; `FROM_STAGE` and `TO_STAGE` stay Text.
5. In `ECL movement`, select `REPORTING_DATE`, `PREV_DATE` and `STAGE`, then **Unpivot Other Columns**. Rename `Attribute` to `Line` and `Value` to `Amount`.
6. **Enter Data** to add two small lookup tables:

   `Movement line`

   | Line | Order | Label |
   |---|---|---|
   | OPENING_ECL | 1 | Opening ECL |
   | NEW_LOANS | 2 | New loans |
   | TRANSFERS_IN | 3 | Transfers in |
   | TRANSFERS_OUT | 4 | Transfers out |
   | EXITS | 5 | Exits |
   | REMEASUREMENT | 6 | Remeasurement |
   | CLOSING_ECL | 7 | Closing ECL |
   | DIFFERENCE | 8 | Check: opening + movements − closing |

   `Stage`

   | Stage | Stage name |
   |---|---|
   | 1 | Stage 1 |
   | 2 | Stage 2 |
   | 3 | Stage 3 |

   In `Stage migration`, add a sort column for both stage columns (**Add Column → Conditional Column**): `1`→1, `2`→2, `3`→3, `NEW` or `EXITED`→4.

7. **Close & Apply.** All seven months of `ecl_detail.csv` add up to about 100 MB, which Import mode handles easily.

## 2. Model

- A date table: **Modeling → New Table**:

  ```dax
  Date =
  ADDCOLUMNS (
      CALENDARAUTO (),
      "Month", FORMAT ( [Date], "mmm yyyy" ),
      "Month sort", YEAR ( [Date] ) * 100 + MONTH ( [Date] )
  )
  ```

  Mark it as the date table, and sort `Month` by `Month sort`.
- Relationships, all one-to-many with single-direction filtering:
  - `Date[Date]` → `REPORTING_DATE` in `ECL detail`, `ECL movement`, `Stage migration`, `Scenarios` and `Data quality`
  - `Stage[Stage]` → `ECL detail[STAGE]` and `ECL movement[STAGE]`
  - `Movement line[Line]` → `ECL movement[Line]`
- Sort `Movement line[Label]` by `Order`. Use `Stage[Stage name]` and `Movement line[Label]` on visuals, not the raw columns.

## 3. Measures

Put them in one empty table (**Enter Data**, call it `Measures`) so they're easy to find.

```dax
Loans          = COUNTROWS ( 'ECL detail' )
Balance        = SUM ( 'ECL detail'[BALANCE] )
ECL            = SUM ( 'ECL detail'[ECL_FINAL] )
Coverage       = DIVIDE ( SUM ( 'ECL detail'[ECL_FINAL] ), SUM ( 'ECL detail'[BALANCE] ) )
Balance share  = DIVIDE ( [Balance], CALCULATE ( [Balance], REMOVEFILTERS ( 'Stage' ) ) )

Model ECL       = SUM ( 'ECL detail'[ECL_WEIGHTED] )
Added by floors = [ECL] - [Model ECL]
Loans floored   = CALCULATE ( [Loans], 'ECL detail'[FLOOR_APPLIED] = "Y" )

ECL previous month = CALCULATE ( [ECL], PREVIOUSMONTH ( 'Date'[Date] ) )
ECL change         = [ECL] - [ECL previous month]

Movement amount = SUM ( 'ECL movement'[Amount] )
Migration loans = SUM ( 'Stage migration'[LOANS] )
DQ errors       = SUM ( 'Data quality'[ERRORS] )
Rows received   = MAX ( 'Data quality'[ROWS_RECEIVED] )
```

Why these work:

- `Coverage` divides the sums. It never averages loan-level ratios, which would give a $500 loan the same weight as a $35,000 one.
- `ECL previous month` works because every month's rows sit on its month-end date, and `PREVIOUSMONTH` returns every day of the month before the first date in the filter. With September 2019 selected, that means all of August, including 31 August.
- `DQ errors` counts failed checks, not rows. A row that breaks two rules counts twice, as it does in `DQ_ERROR`.

Formats: amounts as currency with no decimals on visuals (`$#,0`) and two in tables; `Coverage` and `Balance share` as percentages with two decimals.

## 4. Pages

Put a **Month** slicer (`Date[Month]`, single select) at the top of every
page and sync it across pages (**View → Sync slicers**). On the Overview page,
use **Format → Edit interactions** so the slicer doesn't filter the two trend
charts: they should always show every month.

**1. Overview**
- Cards: `Loans`, `Balance`, `ECL`, `Coverage`, `ECL change`.
- Stacked column chart: X `Date[Month]`, legend `Stage[Stage name]`, values `ECL`.
- Line chart: X `Date[Month]`, legend `Stage[Stage name]`, values `Coverage`. This is a separate chart, not a secondary axis on the column chart: amounts and ratios don't share a scale.
- Table: `Stage name`, `Loans`, `Balance`, `Balance share`, `ECL`, `Coverage`.

**2. Stage migration**
- Matrix: rows `FROM_STAGE` (sorted by its sort column), columns `TO_STAGE`, values `Migration loans`, with row and column subtotals on. A second matrix with `BALANCE_TO` shows the same moves in dollars.
- Row totals are last month's loans by stage; column totals are this month's.

**3. ECL movement**
- Matrix: rows `Movement line[Label]`, columns `Stage[Stage name]`, values `Movement amount`. It reads top to bottom from opening to closing ECL, and the check row is 0.00 in every column.
- Optional waterfall: category `Label`, values `Movement amount`, with *Closing ECL* and the check line filtered out. The waterfall's total bar then equals closing ECL.

**4. Floors and scenarios**
- Table: `Stage name`, `Loans`, `Loans floored`, `Model ECL`, `Added by floors`, `ECL`.
- Clustered column chart from `Scenarios`: `ECL_BASE`, `ECL_DOWNSIDE`, `ECL_SEVERE`, `ECL_WEIGHTED` and `ECL_FINAL` for the selected month.

**5. Grade and geography** (the cuts RBI Annex 4 asks for)
- Matrix: rows `GRADE`, columns `Stage name`, values `ECL` and `Coverage`.
- Bar chart: `ADDR_STATE` by `ECL`, with a Top N filter of 15. A bar chart works everywhere; the map visuals need to be enabled for the tenant.

**6. Data quality**
- Table: `RULE_ID`, `RULE_NAME`, `SEVERITY`, `DQ errors`, `SHARE_OF_ROWS`.
- Cards: `Rows received`; `DQ errors` filtered to `SEVERITY = REJECT`.

## 5. Colours

Use the same stage colours as the HTML report, so the two read the same way:
Stage 1 `#2a78d6`, Stage 2 `#eb6834`, Stage 3 `#1baf7a`. Save this as
`ecl_theme.json` and load it with **View → Themes → Browse for themes**:

```json
{
  "name": "IFRS 9 ECL",
  "dataColors": ["#2a78d6", "#eb6834", "#1baf7a"]
}
```

Theme colours are handed out in the order series appear. If a visual shows the
stages in a different order, set each stage's colour under **Format → Columns**
(or **Lines**) so a stage keeps its colour on every page.

## 6. After a new month

Run the batch for the month. A new `reports/YYYYMMDD/` folder appears;
**Home → Refresh** loads it with the rest.

## 7. Check it against the batch

- With September 2019 selected, the Overview cards should match the headline of `reports/20190930/ecl_report.html` and the batch summary for that run (83,720 loans, final ECL $51,730,340.00).
- The movement check row is 0.00 for every stage and month.
- Migration row totals equal last month's loan counts by stage, and column totals this month's. `tests/test_reports.py` checks the same against the database.
