package com.ird.beyond.lo.test.util;

import org.apache.poi.ss.usermodel.*;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;

import java.io.File;
import java.io.FileInputStream;
import java.util.*;

/**
 * ExcelDataLoader
 * ---------------
 * Reads an .xlsx test-data file and returns only the rows whose "run" column
 * value equals "Y" (case-insensitive).
 *
 * Called directly from Karate feature files via Java interop:
 *
 *   * def loader  = Java.type('com.ird.beyond.lo.test.util.ExcelDataLoader')
 *   * def rowData = loader.load('src/test/resources/features/loans/testdata/loan-lifecycle-test-data.xlsx')
 *
 * Excel rules:
 *   - Row 1  : column headers (must match JSON key names exactly)
 *   - Column "run" : Y → include row | N (or anything else) → skip row
 *   - Blank rows are skipped automatically.
 *
 * Numeric columns are returned as Java Numbers so Karate embeds them
 * correctly into JSON request bodies without string quotes.
 */
public class ExcelDataLoader {

    /** Columns whose values should be stored as numbers in the returned map. */
    private static final Set<String> NUMERIC_COLS = new HashSet<>(Arrays.asList(
            "loanAmount", "totalAmount", "customerContribution",
            "loanTerm", "monthlyGrossIncome", "existingEmiObligations", "periodOfEmployment", "otherIncome", "monthlyLivingExpenses",
            "approvalLimitAmount", "limitAmount", "votesRequired", "overriddenInterestRate",
            "offerRateAdjustment", "offerPrincipalReduction",
            "businessVintageYears", "annualTurnover", "avgMonthlyCredits", "promoterCibilScore",
            "annualRevenue", "costOfGoodsSold", "operatingExpenses", "depreciationAmortization",
            "interestExpense", "taxExpense", "ebitda", "operatingCashFlow",
            "cashAndEquivalents", "tradeReceivables", "inventory", "otherCurrentAssets",
            "grossFixedAssets", "otherNonCurrentAssets", "tradePayables", "shortTermBorrowings",
            "otherCurrentLiabilities", "longTermDebt", "shareCapital", "retainedEarnings",
            "collateralEstimatedValue", "collateralForcedSaleValue",
            "passScore", "autoRejectScore", "flatAmount", "rate", "taxRate", "minCharge", "maxCharge",
            "amendLoanTerm", "uwAmendLoanTerm", "appAmendLoanTerm",
            "effectiveInterestRate", "customerMarginInterest", "fixedInterestRate", "debitInterestMargin",
            "debitInterestRate", "odReviewPeriodMonths", "odAnnualFeeRate",
            "balloonAmount", "moratoriumMonths"
    ));

    /** Columns holding a JSON array/object (Interest &amp; Schedule grids); parsed so a feature can send them as-is. */
    private static final Set<String> JSON_COLS = new HashSet<>(Arrays.asList(
            "pepRows", "stepRows", "mixedBlocks", "scheduleOverride", "manualSchedule", "createAccountOverride"
    ));

    /**
     * Load the Excel file at {@code filePath} and return a list of row maps
     * where the "run" column equals "Y".
     *
     * @param filePath absolute or project-relative path to the .xlsx file
     * @return list of maps (column name → cell value), ready for Karate consumption
     */
    public static List<Map<String, Object>> load(String filePath) throws Exception {
        return load(filePath, null);
    }

    /**
     * Same as {@link #load(String)} but reads the sheet called {@code sheetName} instead of the first
     * one, so a workbook can carry several configuration sheets (e.g. Product_Configurations and
     * Approval_Limits). A missing sheet fails with the names that do exist.
     */
    public static List<Map<String, Object>> load(String filePath, String sheetName) throws Exception {
        File file = new File(filePath);
        if (!file.exists()) {
            throw new IllegalArgumentException(
                    "[ExcelDataLoader] Excel file not found: " + file.getAbsolutePath()
            );
        }

        List<Map<String, Object>> result = new ArrayList<>();

        try (FileInputStream fis = new FileInputStream(file);
             Workbook workbook = new XSSFWorkbook(fis)) {

            Sheet sheet;
            if (sheetName == null || sheetName.trim().isEmpty()) {
                sheet = workbook.getSheetAt(0);
            } else {
                sheet = workbook.getSheet(sheetName.trim());
                if (sheet == null) {
                    List<String> names = new ArrayList<>();
                    for (int i = 0; i < workbook.getNumberOfSheets(); i++) names.add(workbook.getSheetName(i));
                    throw new IllegalArgumentException("[ExcelDataLoader] Sheet '" + sheetName + "' not found in "
                            + file.getName() + ". Sheets present: " + names);
                }
            }
            Row headerRow = sheet.getRow(0);

            if (headerRow == null) {
                throw new IllegalStateException("[ExcelDataLoader] Excel sheet has no header row.");
            }

            // Build header index
            List<String> headers = new ArrayList<>();
            for (Cell cell : headerRow) {
                headers.add(cell.getStringCellValue().trim());
            }

            int runColIdx = headers.indexOf("run");
            int createColIdx = headers.indexOf("create");
            if (createColIdx < 0) createColIdx = headers.indexOf("crete");
            int amendColIdx = headers.indexOf("amend");
            int deleteColIdx = headers.indexOf("delete");
            int actionColIdx = headers.indexOf("action");
            if (runColIdx < 0 && createColIdx < 0 && amendColIdx < 0 && deleteColIdx < 0 && actionColIdx < 0) {
                throw new IllegalStateException(
                        "[ExcelDataLoader] Neither 'run' nor action columns ('create', 'amend', 'delete') found in Excel headers: " + headers
                );
            }

            // Iterate data rows (skip header = row 0)
            for (int rowIdx = 1; rowIdx <= sheet.getLastRowNum(); rowIdx++) {
                Row row = sheet.getRow(rowIdx);
                if (row == null || isRowBlank(row)) {
                    continue;
                }

                // Check if row should run
                boolean shouldRun = false;
                if (runColIdx >= 0) {
                    String runValue = getCellString(row.getCell(runColIdx)).trim();
                    if (isTruthy(runValue)) {
                        shouldRun = true;
                    } else if (!runValue.isEmpty() && !isTruthy(runValue)) {
                        shouldRun = false;
                    } else {
                        // run cell is empty/blank -> check create/amend/delete/action
                        if (createColIdx >= 0 && isTruthy(getCellString(row.getCell(createColIdx)))) shouldRun = true;
                        if (amendColIdx >= 0 && isTruthy(getCellString(row.getCell(amendColIdx)))) shouldRun = true;
                        if (deleteColIdx >= 0 && isTruthy(getCellString(row.getCell(deleteColIdx)))) shouldRun = true;
                        if (actionColIdx >= 0 && !getCellString(row.getCell(actionColIdx)).trim().isEmpty()) shouldRun = true;
                    }
                } else {
                    if (createColIdx >= 0 && isTruthy(getCellString(row.getCell(createColIdx)))) shouldRun = true;
                    if (amendColIdx >= 0 && isTruthy(getCellString(row.getCell(amendColIdx)))) shouldRun = true;
                    if (deleteColIdx >= 0 && isTruthy(getCellString(row.getCell(deleteColIdx)))) shouldRun = true;
                    if (actionColIdx >= 0 && !getCellString(row.getCell(actionColIdx)).trim().isEmpty()) shouldRun = true;
                }
                if (!shouldRun) {
                    continue;
                }

                // Build map for this row
                Map<String, Object> rowMap = new LinkedHashMap<>();
                for (int colIdx = 0; colIdx < headers.size(); colIdx++) {
                    String header = headers.get(colIdx);
                    if (header.isEmpty()) continue;

                    Cell cell = row.getCell(colIdx, Row.MissingCellPolicy.RETURN_BLANK_AS_NULL);
                    Object value;

                    if (cell == null) {
                        value = null;
                    } else if (NUMERIC_COLS.contains(header)) {
                        value = getNumericValue(cell);
                    } else if (JSON_COLS.contains(header)) {
                        String text = getCellString(cell);
                        value = text.isEmpty() ? null : com.intuit.karate.JsonUtils.fromJson(text);
                    } else {
                        value = getCellString(cell);
                    }

                    rowMap.put(header, value);
                }

                System.out.printf("[ExcelDataLoader] Loaded row %d → testCaseId=%s%n",
                        rowIdx + 1, rowMap.get("testCaseId"));
                result.add(rowMap);
            }
        }

        System.out.printf("[ExcelDataLoader] Total rows to execute: %d%n", result.size());
        return CbsConfigSelfHealingAgent.healLoadedRows(filePath, result);
    }

    // ------------------------------------------------------------------ helpers

    private static boolean isRowBlank(Row row) {
        for (Cell cell : row) {
            if (cell != null && cell.getCellType() != CellType.BLANK) {
                String val = getCellString(cell);
                if (!val.isEmpty()) return false;
            }
        }
        return true;
    }

    /** Reusable DataFormatter — avoids re-creating per cell. */
    private static final DataFormatter DATA_FORMATTER = new DataFormatter();

    private static String getCellString(Cell cell) {
        if (cell == null) return "";
        switch (cell.getCellType()) {
            case STRING:  return cell.getStringCellValue().trim();
            case NUMERIC:
                // A date-formatted cell is sent as ISO yyyy-MM-dd, the format every date field of the API expects.
                if (DateUtil.isCellDateFormatted(cell)) return cell.getLocalDateTimeCellValue().toLocalDate().toString();
                return DATA_FORMATTER.formatCellValue(cell).trim();
            case BOOLEAN: return String.valueOf(cell.getBooleanCellValue());
            case FORMULA:
                try { return String.valueOf(cell.getNumericCellValue()); }
                catch (Exception e) { return cell.getStringCellValue().trim(); }
            default:      return "";
        }
    }

    private static Number getNumericValue(Cell cell) {
        if (cell == null) return null;
        try {
            switch (cell.getCellType()) {
                case NUMERIC:
                case FORMULA: {
                    double d = cell.getNumericCellValue();
                    // Return int when there is no fractional part, else double
                    return (d == Math.floor(d) && !Double.isInfinite(d))
                            ? (Number)(long) d
                            : d;
                }
                case STRING: {
                    String s = cell.getStringCellValue().trim().replace(",", "");
                    if (s.isEmpty()) return null;
                    double d = Double.parseDouble(s);
                    return (d == Math.floor(d)) ? (Number)(long) d : d;
                }
                default: return null;
            }
        } catch (NumberFormatException e) {
            return null;
        }
    }

    private static boolean isTruthy(String s) {
        if (s == null) return false;
        String t = s.trim().toLowerCase();
        return "true".equals(t) || "y".equals(t) || "yes".equals(t) || "1".equals(t);
    }

    /** Thin wrapper so DataFormatter can be used as a static utility. */
    private static String formatCellValue(Cell cell) {
        return DATA_FORMATTER.formatCellValue(cell);
    }
}
