package com.ird.beyond.lo.test.util;

import com.fasterxml.jackson.databind.ObjectMapper;
import org.apache.poi.ss.usermodel.*;
import org.apache.poi.ss.util.CellRangeAddress;
import org.apache.poi.xssf.usermodel.XSSFColor;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;

import java.io.*;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardCopyOption;
import java.text.SimpleDateFormat;
import java.util.*;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

/**
 * KarateExcelReporter
 * ------------------
 * Custom Excel report generator for Karate API test executions.
 * Parses Karate JSON execution reports in target/karate-reports and creates
 * a user-understandable, tester-friendly Excel report (.xlsx) with total test case counts,
 * feature-wise breakdown for features 04, 05, 06, 07, passed/failed statuses,
 * and detailed root-cause failure reasons.
 */
public class KarateExcelReporter {

    public static class TestCaseDetail {
        public String featureId = "";        // e.g., "04", "05", "06", "07"
        public String featureName = "";      // e.g., "04-BLO-LifeCycle.feature"
        public String testCaseId = "";       // e.g., "TC-PTY0035" or Scenario Name
        public String description = "";      // e.g., "Retail PERSONAL_LOAN - PL005DEFAULTUSD"
        public String customerName = "";     // e.g., "Mohan Kumar"
        public String cbsAccountNumber = ""; // CBS Loan / OD Account Number
        public String status = "PASSED";     // "PASSED" or "FAILED"
        public double durationSeconds = 0.0;
        public String failedStep = "";       // Step text where failure occurred
        public int line = 0;                 // Line number of failed step
        public String failureReason = "";    // Short error summary
        public String stackTrace = "";       // Detailed stack trace / log snippet
    }

    public static class FeatureSummary {
        public String featureId = "";        // "04", "05", "06", "07", etc.
        public String featureName = "";
        public String relativePath = "";
        public int totalScenarios = 0;
        public int passedCount = 0;
        public int failedCount = 0;
        public int skippedCount = 0;
        public double durationSeconds = 0.0;
        public String status = "PASSED";     // "PASSED" or "FAILED"
        public List<TestCaseDetail> testCases = new ArrayList<>();
    }

    public static class SuiteSummary {
        public String environment = "dev";
        public String executionDate = "";
        public int totalFeatures = 0;
        public int totalTestCases = 0;
        public int totalPassed = 0;
        public int totalFailed = 0;
        public int totalSkipped = 0;
        public double totalDurationSeconds = 0.0;
        public double passPercentage = 0.0;
        public List<FeatureSummary> features = new ArrayList<>();
        public List<TestCaseDetail> failedTestCases = new ArrayList<>();
    }

    public static void main(String[] args) {
        String reportsDir = (args.length > 0 && args[0] != null && !args[0].trim().isEmpty())
                ? args[0].trim()
                : "target/karate-reports";
        generateReport(reportsDir);
    }

    /**
     * Entry point to parse Karate reports directory and produce Excel & Text reports.
     */
    public static void generateReport(String reportsDirFolder) {
        File reportsDir = new File(reportsDirFolder);
        if (!reportsDir.exists() || !reportsDir.isDirectory()) {
            System.err.println("[KarateExcelReporter] Directory does not exist: " + reportsDir.getAbsolutePath());
            return;
        }

        System.out.println("[KarateExcelReporter] Parsing Karate test results from: " + reportsDir.getAbsolutePath());
        SuiteSummary suite = parseKarateResults(reportsDir);

        if (suite.features.isEmpty()) {
            System.out.println("[KarateExcelReporter] No feature execution JSON files found in " + reportsDir.getAbsolutePath());
            return;
        }

        // Correlate self-healing rewrites with final test outcomes (RESOLVED / UNRESOLVED)
        Map<String, String> statusByTc = new LinkedHashMap<>();
        Map<String, String> cbsByTc = new LinkedHashMap<>();
        Map<String, String> failByTc = new LinkedHashMap<>();
        for (FeatureSummary f : suite.features) {
            for (TestCaseDetail tc : f.testCases) {
                statusByTc.put(tc.testCaseId, tc.status);
                cbsByTc.put(tc.testCaseId, tc.cbsAccountNumber);
                failByTc.put(tc.testCaseId, tc.failureReason);
            }
        }
        CbsConfigSelfHealingAgent.finalizeResolutions(statusByTc, cbsByTc, failByTc, reportsDirFolder);

        // Generate Excel Workbook
        Workbook workbook = createExcelWorkbook(suite);
        
        // Save Excel Files
        String timestamp = new SimpleDateFormat("yyyyMMdd_HHmmss").format(new Date());
        File mainReportFile = new File(reportsDir, "Karate_Test_Execution_Report.xlsx");
        File timestampedReportFile = new File(reportsDir, "Karate_Test_Report_" + timestamp + ".xlsx");

        saveWorkbook(workbook, mainReportFile);
        saveWorkbook(workbook, timestampedReportFile);

        // Generate Text & HTML Summaries for Build Logs / Mail
        File txtSummary = new File(reportsDir, "karate-build-summary.txt");
        File htmlSummary = new File(reportsDir, "karate-build-summary.html");
        generateTextSummary(suite, txtSummary);
        generateHtmlSummary(suite, htmlSummary);

        // Mirror reports into configured local brain/reports directory
        Path brainReports = CbsConfigSelfHealingAgent.resolveBrainReportsDir();
        if (brainReports != null) {
            try {
                Files.createDirectories(brainReports);
                for (File f : List.of(mainReportFile, timestampedReportFile, txtSummary, htmlSummary)) {
                    if (f.exists()) {
                        Files.copy(f.toPath(), brainReports.resolve(f.getName()), StandardCopyOption.REPLACE_EXISTING);
                    }
                }
            } catch (Exception e) {
                System.err.println("[KarateExcelReporter] Warning mirroring reports to brain/reports: " + e.getMessage());
            }
        }

        System.out.println("[KarateExcelReporter] Report generation completed successfully!");
        System.out.println("[KarateExcelReporter] Excel Report: " + mainReportFile.getAbsolutePath());
    }

    /**
     * Parses all Karate JSON output files to build full suite & feature statistics.
     */
    private static SuiteSummary parseKarateResults(File reportsDir) {
        SuiteSummary suite = new SuiteSummary();
        suite.executionDate = new SimpleDateFormat("yyyy-MM-dd HH:mm:ss").format(new Date());
        ObjectMapper mapper = new ObjectMapper();

        // 1. Check for summary JSON
        File summaryJsonFile = new File(reportsDir, "karate-summary-json.txt");
        if (!summaryJsonFile.exists()) {
            summaryJsonFile = new File(reportsDir, "karate-summary.json");
        }
        if (summaryJsonFile.exists()) {
            try {
                Map<String, Object> sumData = mapper.readValue(summaryJsonFile, Map.class);
                if (sumData.get("env") != null) {
                    suite.environment = String.valueOf(sumData.get("env"));
                }
                if (sumData.get("resultDate") != null) {
                    suite.executionDate = String.valueOf(sumData.get("resultDate"));
                }
            } catch (Exception e) {
                // Ignore summary JSON read errors, fallback to feature details
            }
        }

        // 2. Find all feature *.karate-json.txt or *.json files
        File[] jsonFiles = reportsDir.listFiles((dir, name) ->
                (name.endsWith(".karate-json.txt") || name.endsWith(".json")) && !name.contains("summary")
        );

        if (jsonFiles != null) {
            Arrays.sort(jsonFiles, Comparator.comparing(File::getName));

            for (File file : jsonFiles) {
                try {
                    Map<String, Object> featureMap = mapper.readValue(file, Map.class);
                    FeatureSummary fSummary = parseFeatureJson(featureMap);
                    if (fSummary != null && !fSummary.testCases.isEmpty()) {
                        suite.features.add(fSummary);
                        suite.totalFeatures++;
                        suite.totalTestCases += fSummary.testCases.size();
                        suite.totalPassed += fSummary.passedCount;
                        suite.totalFailed += fSummary.failedCount;
                        suite.totalSkipped += fSummary.skippedCount;
                        suite.totalDurationSeconds += fSummary.durationSeconds;
                        suite.failedTestCases.addAll(extractFailures(fSummary));
                    }
                } catch (Exception e) {
                    System.err.println("[KarateExcelReporter] Warning: Failed to parse feature JSON: " + file.getName() + " - " + e.getMessage());
                }
            }
        }

        if (suite.totalTestCases > 0) {
            suite.passPercentage = ((double) suite.totalPassed / (double) suite.totalTestCases) * 100.0;
        }

        return suite;
    }

    private static List<TestCaseDetail> extractFailures(FeatureSummary fSummary) {
        List<TestCaseDetail> fails = new ArrayList<>();
        for (TestCaseDetail tc : fSummary.testCases) {
            if ("FAILED".equalsIgnoreCase(tc.status)) {
                fails.add(tc);
            }
        }
        return fails;
    }

    private static FeatureSummary parseFeatureJson(Map<String, Object> featureMap) {
        FeatureSummary fSummary = new FeatureSummary();
        String relPath = (String) featureMap.get("relativePath");
        if (relPath == null) {
            relPath = (String) featureMap.get("packageQualifiedName");
        }
        fSummary.relativePath = relPath != null ? relPath : "Unknown Feature";
        fSummary.featureName = extractBasename(fSummary.relativePath);
        fSummary.featureId = extractFeatureId(fSummary.featureName);

        Number durMillis = (Number) featureMap.get("durationMillis");
        fSummary.durationSeconds = durMillis != null ? durMillis.doubleValue() / 1000.0 : 0.0;

        List<Map<String, Object>> scenarioResults = (List<Map<String, Object>>) featureMap.get("scenarioResults");
        if (scenarioResults != null) {
            for (Map<String, Object> sc : scenarioResults) {
                processScenarioResult(sc, fSummary);
            }
        }

        if (fSummary.failedCount > 0) {
            fSummary.status = "FAILED";
        } else {
            fSummary.status = "PASSED";
        }

        return fSummary;
    }

    private static void processScenarioResult(Map<String, Object> scenario, FeatureSummary fSummary) {
        List<Map<String, Object>> testCaseCalls = extractTestCaseCalls(scenario);
        if (!testCaseCalls.isEmpty()) {
            for (Map<String, Object> call : testCaseCalls) {
                processCallResult(call, fSummary);
            }
            return;
        }

        TestCaseDetail tc = new TestCaseDetail();
        tc.featureId = fSummary.featureId;
        tc.featureName = fSummary.featureName;
        tc.testCaseId = (String) scenario.get("refId");
        if (tc.testCaseId == null || tc.testCaseId.isEmpty()) {
            tc.testCaseId = (String) scenario.get("name");
        }
        tc.description = (String) scenario.get("name");
        tc.cbsAccountNumber = findCbsAccount(tc.testCaseId, scenario, null);
        
        Number durMillis = (Number) scenario.get("durationMillis");
        tc.durationSeconds = durMillis != null ? durMillis.doubleValue() / 1000.0 : 0.0;

        boolean isFailed = Boolean.TRUE.equals(scenario.get("failed"));

        List<Map<String, Object>> stepResults = (List<Map<String, Object>>) scenario.get("stepResults");
        if (stepResults != null) {
            for (Map<String, Object> stepRes : stepResults) {
                Map<String, Object> res = (Map<String, Object>) stepRes.get("result");
                if (res != null && "failed".equalsIgnoreCase((String) res.get("status"))) {
                    isFailed = true;
                    Map<String, Object> stepObj = (Map<String, Object>) stepRes.get("step");
                    if (stepObj != null) {
                        tc.failedStep = (String) stepObj.get("text");
                        Number lineNum = (Number) stepObj.get("line");
                        tc.line = lineNum != null ? lineNum.intValue() : 0;
                    }
                    tc.failureReason = (String) res.get("error");
                    if (tc.failureReason == null) {
                        tc.failureReason = (String) res.get("errorMessage");
                    }
                    tc.stackTrace = str(stepRes.get("stepLog"));
                }
            }
        }

        tc.status = isFailed ? "FAILED" : "PASSED";
        fSummary.testCases.add(tc);
        if (isFailed) {
            fSummary.failedCount++;
        } else {
            fSummary.passedCount++;
        }
        fSummary.totalScenarios++;
    }

    private static List<Map<String, Object>> extractTestCaseCalls(Map<String, Object> scenario) {
        List<Map<String, Object>> testCaseCalls = new ArrayList<>();
        
        // 1. Direct callResults on scenario if present
        List<Map<String, Object>> directCalls = (List<Map<String, Object>>) scenario.get("callResults");
        if (directCalls != null) {
            for (Map<String, Object> call : directCalls) {
                if (isTestCaseCall(call)) {
                    testCaseCalls.add(call);
                }
            }
        }
        
        // 2. callResults inside stepResults
        List<Map<String, Object>> stepResults = (List<Map<String, Object>>) scenario.get("stepResults");
        if (stepResults != null) {
            for (Map<String, Object> stepRes : stepResults) {
                List<Map<String, Object>> stepCalls = (List<Map<String, Object>>) stepRes.get("callResults");
                if (stepCalls != null) {
                    for (Map<String, Object> call : stepCalls) {
                        if (isTestCaseCall(call)) {
                            testCaseCalls.add(call);
                        }
                    }
                }
            }
        }
        return testCaseCalls;
    }

    private static boolean isTestCaseCall(Map<String, Object> call) {
        if (call == null) return false;
        Map<String, Object> callArg = (Map<String, Object>) call.get("callArg");
        if (callArg != null && callArg.get("testCaseId") != null && !str(callArg.get("testCaseId")).isEmpty()) {
            return true;
        }
        String path = str(call.get("prefixedPath"));
        if (path.isEmpty()) path = str(call.get("relativePath"));
        if (path.contains("helper") || path.contains("auth") || path.contains("resolve-users")) {
            return false;
        }
        return path.contains("LifeCycle");
    }

    private static void processCallResult(Map<String, Object> call, FeatureSummary fSummary) {
        Map<String, Object> callArg = (Map<String, Object>) call.get("callArg");
        String testCaseId = null;
        String customerName = null;
        String description = null;
        if (callArg != null) {
            testCaseId = str(callArg.get("testCaseId"));
            customerName = str(callArg.get("customerName"));
            description = str(callArg.get("description"));
        }

        List<Map<String, Object>> scenarioResults = (List<Map<String, Object>>) call.get("scenarioResults");
        if (scenarioResults != null && !scenarioResults.isEmpty()) {
            for (Map<String, Object> sc : scenarioResults) {
                TestCaseDetail tc = new TestCaseDetail();
                tc.featureId = fSummary.featureId;
                tc.featureName = fSummary.featureName;
                tc.testCaseId = (testCaseId != null && !testCaseId.isEmpty()) ? testCaseId : str(sc.get("name"));
                tc.customerName = customerName;
                tc.description = (description != null && !description.isEmpty()) ? description : str(sc.get("name"));
                tc.cbsAccountNumber = findCbsAccount(tc.testCaseId, sc, call);

                boolean isFailed = Boolean.TRUE.equals(sc.get("failed"))
                        || (call.get("failedCount") != null && ((Number) call.get("failedCount")).intValue() > 0);

                Number durMillis = (Number) sc.get("durationMillis");
                if (durMillis == null || durMillis.doubleValue() == 0) {
                    durMillis = (Number) call.get("durationMillis");
                }
                tc.durationSeconds = durMillis != null ? durMillis.doubleValue() / 1000.0 : 0.0;

                List<Map<String, Object>> stepResults = (List<Map<String, Object>>) sc.get("stepResults");
                if (stepResults != null) {
                    for (Map<String, Object> stepRes : stepResults) {
                        Map<String, Object> res = (Map<String, Object>) stepRes.get("result");
                        if (res != null && "failed".equalsIgnoreCase((String) res.get("status"))) {
                            isFailed = true;
                            Map<String, Object> stepObj = (Map<String, Object>) stepRes.get("step");
                            if (stepObj != null) {
                                tc.failedStep = str(stepObj.get("text"));
                                Number lineNum = (Number) stepObj.get("line");
                                tc.line = lineNum != null ? lineNum.intValue() : 0;
                            }
                            tc.failureReason = str(res.get("error"));
                            if (tc.failureReason.isEmpty()) {
                                tc.failureReason = str(res.get("errorMessage"));
                            }
                            tc.stackTrace = str(stepRes.get("stepLog"));
                        }
                    }
                }

                tc.status = isFailed ? "FAILED" : "PASSED";
                fSummary.testCases.add(tc);
                if (isFailed) {
                    fSummary.failedCount++;
                } else {
                    fSummary.passedCount++;
                }
                fSummary.totalScenarios++;
            }
        }
    }

    private static String extractFeatureId(String featureName) {
        if (featureName.startsWith("04")) return "04";
        if (featureName.startsWith("05")) return "05";
        if (featureName.startsWith("06")) return "06";
        if (featureName.startsWith("07")) return "07";
        if (featureName.startsWith("01")) return "01";
        if (featureName.startsWith("02")) return "02";
        if (featureName.startsWith("03")) return "03";
        return "Misc";
    }

    private static String extractBasename(String path) {
        if (path == null) return "";
        int slash = Math.max(path.lastIndexOf('/'), path.lastIndexOf('\\'));
        return slash >= 0 ? path.substring(slash + 1) : path;
    }

    private static String str(Object val) {
        return val == null ? "" : String.valueOf(val).trim();
    }

    private static final Pattern CBS_ACCOUNT_PATTERN = Pattern.compile(
            "(?i)(?:CBS Loan Account Number|CBS OD Limit / Account|CBS Loan Account|Loan ID|Account opened in CBS -> Account|@Cbs\\s*=)\\s*[:\\->=]?\\s*([A-Za-z0-9_-]+)"
    );

    private static String findCbsAccount(String testCaseId, Map<String, Object> scenario, Map<String, Object> call) {
        // 1. Check in-memory PersistentVars first
        try {
            Map<String, Map<String, String>> allRecords = PersistentVars.getAllTestRecords();
            if (allRecords != null && testCaseId != null && !testCaseId.isEmpty()) {
                Map<String, String> vars = allRecords.get(testCaseId);
                if (vars != null) {
                    String cbs = vars.get("@Cbs");
                    if (cbs == null || cbs.isEmpty()) cbs = vars.get("@cbs");
                    if (cbs == null || cbs.isEmpty()) cbs = vars.get("@CbsAccountNumber");
                    if (isValidCbs(cbs)) return cbs.trim();
                }
                for (Map.Entry<String, Map<String, String>> entry : allRecords.entrySet()) {
                    if (entry.getKey() != null && (entry.getKey().equalsIgnoreCase(testCaseId)
                            || entry.getKey().contains(testCaseId) || testCaseId.contains(entry.getKey()))) {
                        String cbs = entry.getValue().get("@Cbs");
                        if (cbs == null || cbs.isEmpty()) cbs = entry.getValue().get("@cbs");
                        if (isValidCbs(cbs)) return cbs.trim();
                    }
                }
            }
        } catch (Throwable ignored) {
        }

        // 2. Scan step logs from scenario
        if (scenario != null) {
            String cbs = scanForCbs(scenario);
            if (isValidCbs(cbs)) return cbs;
        }

        // 3. Scan step logs from call
        if (call != null) {
            String cbs = scanForCbs(call);
            if (isValidCbs(cbs)) return cbs;
        }

        return "";
    }

    private static boolean isValidCbs(String cbs) {
        if (cbs == null) return false;
        String clean = cbs.trim();
        return !clean.isEmpty()
                && !clean.equalsIgnoreCase("null")
                && !clean.equalsIgnoreCase("N/A")
                && !clean.equalsIgnoreCase("true")
                && !clean.equalsIgnoreCase("false");
    }

    @SuppressWarnings("unchecked")
    private static String scanForCbs(Map<String, Object> map) {
        if (map == null) return null;
        List<Map<String, Object>> stepResults = (List<Map<String, Object>>) map.get("stepResults");
        if (stepResults != null) {
            for (Map<String, Object> sr : stepResults) {
                String log = str(sr.get("stepLog"));
                if (!log.isEmpty()) {
                    Matcher m = CBS_ACCOUNT_PATTERN.matcher(log);
                    if (m.find()) {
                        String matched = m.group(1).trim();
                        if (isValidCbs(matched)) return matched;
                    }
                }
                List<Map<String, Object>> nestedCalls = (List<Map<String, Object>>) sr.get("callResults");
                if (nestedCalls != null) {
                    for (Map<String, Object> nc : nestedCalls) {
                        String found = scanForCbs(nc);
                        if (isValidCbs(found)) return found;
                    }
                }
            }
        }
        List<Map<String, Object>> scenarioResults = (List<Map<String, Object>>) map.get("scenarioResults");
        if (scenarioResults != null) {
            for (Map<String, Object> subSc : scenarioResults) {
                String found = scanForCbs(subSc);
                if (isValidCbs(found)) return found;
            }
        }
        return null;
    }

    private static String truncate(String text, int maxLength) {
        if (text == null) return "";
        String s = text.trim();
        if (s.length() <= maxLength) return s;
        return s.substring(0, maxLength) + " ... [TRUNCATED (" + s.length() + " chars)]";
    }

    // =========================================================================
    // EXCEL WORKBOOK GENERATION
    // =========================================================================

    private static Workbook createExcelWorkbook(SuiteSummary suite) {
        Workbook workbook = new XSSFWorkbook();

        // Cell Styles
        CellStyle titleStyle = createTitleStyle(workbook);
        CellStyle metaHeaderStyle = createMetaHeaderStyle(workbook);
        CellStyle metaValueStyle = createMetaValueStyle(workbook);
        CellStyle tableHeaderStyle = createTableHeaderStyle(workbook);
        CellStyle normalStyle = createNormalStyle(workbook);
        CellStyle passStyle = createStatusStyle(workbook, IndexedColors.GREEN.getIndex());
        CellStyle failStyle = createStatusStyle(workbook, IndexedColors.RED.getIndex());

        // ---------------------------------------------------------------------
        // Sheet 1: Executive Summary
        // ---------------------------------------------------------------------
        Sheet summarySheet = workbook.createSheet("Executive Summary");
        buildExecutiveSummarySheet(summarySheet, suite, titleStyle, metaHeaderStyle, metaValueStyle, tableHeaderStyle, normalStyle, passStyle, failStyle);

        // ---------------------------------------------------------------------
        // Sheet 2: Features 04-07 Breakdown
        // ---------------------------------------------------------------------
        Sheet features047Sheet = workbook.createSheet("Features (04,05,06,07)");
        buildFeatures047Sheet(features047Sheet, suite, titleStyle, tableHeaderStyle, normalStyle, passStyle, failStyle);

        // ---------------------------------------------------------------------
        // Sheet 3: All Test Cases Detail
        // ---------------------------------------------------------------------
        Sheet allDetailsSheet = workbook.createSheet("All Test Cases");
        buildAllTestCasesSheet(allDetailsSheet, suite, titleStyle, tableHeaderStyle, normalStyle, passStyle, failStyle);

        // ---------------------------------------------------------------------
        // Sheet 4: Failure Details & RCA
        // ---------------------------------------------------------------------
        Sheet failureSheet = workbook.createSheet("Failure Details & Root Cause");
        buildFailureDetailsSheet(failureSheet, suite, titleStyle, tableHeaderStyle, normalStyle, failStyle);

        // ---------------------------------------------------------------------
        // Sheet 5: Autonomous Self-Healing RCA
        // ---------------------------------------------------------------------
        Sheet healingSheet = workbook.createSheet("Autonomous Self-Healing RCA");
        buildSelfHealingRcaSheet(healingSheet, titleStyle, tableHeaderStyle, normalStyle, passStyle, failStyle);

        return workbook;
    }

    private static void buildExecutiveSummarySheet(Sheet sheet, SuiteSummary suite,
                                                   CellStyle titleStyle, CellStyle metaHeaderStyle, CellStyle metaValueStyle,
                                                   CellStyle tableHeaderStyle, CellStyle normalStyle,
                                                   CellStyle passStyle, CellStyle failStyle) {
        int rowIdx = 0;

        // Title Banner
        Row titleRow = sheet.createRow(rowIdx++);
        Cell titleCell = titleRow.createCell(0);
        titleCell.setCellValue(truncate("BEYOND LO AUTOMATION — KARATE API TEST EXECUTION REPORT", 30000));
        titleCell.setCellStyle(titleStyle);
        sheet.addMergedRegion(new CellRangeAddress(0, 0, 0, 7));

        rowIdx++; // Blank row

        // Executive Metrics Block
        String[][] meta = {
                {"Environment:", suite.environment.toUpperCase(), "Total Features:", String.valueOf(suite.totalFeatures)},
                {"Execution Date:", suite.executionDate, "Total Test Cases (Rows):", String.valueOf(suite.totalTestCases)},
                {"Total Duration:", String.format("%.2f sec", suite.totalDurationSeconds), "Passed Test Cases:", String.valueOf(suite.totalPassed)},
                {"Pass Percentage:", String.format("%.2f%%", suite.passPercentage), "Failed Test Cases:", String.valueOf(suite.totalFailed)}
        };

        for (String[] mRow : meta) {
            Row r = sheet.createRow(rowIdx++);
            Cell c0 = r.createCell(0); c0.setCellValue(truncate(mRow[0], 30000)); c0.setCellStyle(metaHeaderStyle);
            Cell c1 = r.createCell(1); c1.setCellValue(truncate(mRow[1], 30000)); c1.setCellStyle(metaValueStyle);
            Cell c3 = r.createCell(3); c3.setCellValue(truncate(mRow[2], 30000)); c3.setCellStyle(metaHeaderStyle);
            Cell c4 = r.createCell(4); c4.setCellValue(truncate(mRow[3], 30000)); c4.setCellStyle(metaValueStyle);
        }

        rowIdx += 2; // Blank rows

        // Feature Breakdown Table Header
        Row tableHeader = sheet.createRow(rowIdx++);
        String[] cols = {"Feature ID", "Feature File / Module", "Total Test Cases", "Passed", "Failed", "Pass Rate", "Duration (s)", "Status"};
        for (int i = 0; i < cols.length; i++) {
            Cell c = tableHeader.createCell(i);
            c.setCellValue(truncate(cols[i], 30000));
            c.setCellStyle(tableHeaderStyle);
        }

        // Feature Rows
        for (FeatureSummary f : suite.features) {
            Row r = sheet.createRow(rowIdx++);
            Cell c0 = r.createCell(0); c0.setCellValue(truncate(f.featureId, 30000)); c0.setCellStyle(normalStyle);
            Cell c1 = r.createCell(1); c1.setCellValue(truncate(f.featureName, 30000)); c1.setCellStyle(normalStyle);
            Cell c2 = r.createCell(2); c2.setCellValue(f.totalScenarios); c2.setCellStyle(normalStyle);
            Cell c3 = r.createCell(3); c3.setCellValue(f.passedCount); c3.setCellStyle(normalStyle);
            Cell c4 = r.createCell(4); c4.setCellValue(f.failedCount); c4.setCellStyle(f.failedCount > 0 ? failStyle : normalStyle);
            
            double pRate = f.totalScenarios > 0 ? ((double) f.passedCount / (double) f.totalScenarios) * 100.0 : 0.0;
            Cell c5 = r.createCell(5); c5.setCellValue(String.format("%.1f%%", pRate)); c5.setCellStyle(normalStyle);
            Cell c6 = r.createCell(6); c6.setCellValue(String.format("%.2f", f.durationSeconds)); c6.setCellStyle(normalStyle);
            Cell c7 = r.createCell(7); c7.setCellValue(truncate(f.status, 30000)); c7.setCellStyle("PASSED".equalsIgnoreCase(f.status) ? passStyle : failStyle);
        }

        for (int i = 0; i < cols.length; i++) {
            sheet.autoSizeColumn(i);
        }
    }

    private static void buildFeatures047Sheet(Sheet sheet, SuiteSummary suite,
                                              CellStyle titleStyle, CellStyle tableHeaderStyle,
                                              CellStyle normalStyle, CellStyle passStyle, CellStyle failStyle) {
        int rowIdx = 0;

        Row titleRow = sheet.createRow(rowIdx++);
        Cell titleCell = titleRow.createCell(0);
        titleCell.setCellValue(truncate("CORE LIFECYCLE FEATURES BREAKDOWN (FEATURES 04, 05, 06, 07)", 30000));
        titleCell.setCellStyle(titleStyle);
        sheet.addMergedRegion(new CellRangeAddress(0, 0, 0, 7));

        rowIdx++;

        Row tableHeader = sheet.createRow(rowIdx++);
        String[] cols = {"Feature ID", "Feature File Name", "Test Case ID / Excel Row", "Customer / Context Description", "CBS Account Number", "Status", "Duration (s)", "Failure Reason / Notes"};
        for (int i = 0; i < cols.length; i++) {
            Cell c = tableHeader.createCell(i);
            c.setCellValue(truncate(cols[i], 30000));
            c.setCellStyle(tableHeaderStyle);
        }

        for (FeatureSummary f : suite.features) {
            if ("04".equals(f.featureId) || "05".equals(f.featureId) || "06".equals(f.featureId) || "07".equals(f.featureId)) {
                for (TestCaseDetail tc : f.testCases) {
                    Row r = sheet.createRow(rowIdx++);
                    Cell c0 = r.createCell(0); c0.setCellValue(truncate(f.featureId, 30000)); c0.setCellStyle(normalStyle);
                    Cell c1 = r.createCell(1); c1.setCellValue(truncate(f.featureName, 30000)); c1.setCellStyle(normalStyle);
                    Cell c2 = r.createCell(2); c2.setCellValue(truncate(tc.testCaseId, 30000)); c2.setCellStyle(normalStyle);
                    String desc = (tc.customerName != null && !tc.customerName.isEmpty()) ? tc.customerName + " | " + tc.description : tc.description;
                    Cell c3 = r.createCell(3); c3.setCellValue(truncate(desc, 30000)); c3.setCellStyle(normalStyle);
                    String cbsVal = (tc.cbsAccountNumber != null && !tc.cbsAccountNumber.isEmpty()) ? tc.cbsAccountNumber : "—";
                    Cell c4 = r.createCell(4); c4.setCellValue(truncate(cbsVal, 30000)); c4.setCellStyle(normalStyle);
                    Cell c5 = r.createCell(5); c5.setCellValue(truncate(tc.status, 30000)); c5.setCellStyle("PASSED".equalsIgnoreCase(tc.status) ? passStyle : failStyle);
                    Cell c6 = r.createCell(6); c6.setCellValue(String.format("%.2f", tc.durationSeconds)); c6.setCellStyle(normalStyle);
                    Cell c7 = r.createCell(7); c7.setCellValue(truncate(tc.failureReason, 30000)); c7.setCellStyle(normalStyle);
                }
            }
        }

        for (int i = 0; i < cols.length; i++) {
            sheet.autoSizeColumn(i);
        }
    }

    private static void buildAllTestCasesSheet(Sheet sheet, SuiteSummary suite,
                                               CellStyle titleStyle, CellStyle tableHeaderStyle,
                                               CellStyle normalStyle, CellStyle passStyle, CellStyle failStyle) {
        int rowIdx = 0;

        Row titleRow = sheet.createRow(rowIdx++);
        Cell titleCell = titleRow.createCell(0);
        titleCell.setCellValue(truncate("ALL TEST CASES EXECUTION BREAKDOWN", 30000));
        titleCell.setCellStyle(titleStyle);
        sheet.addMergedRegion(new CellRangeAddress(0, 0, 0, 7));

        rowIdx++;

        Row tableHeader = sheet.createRow(rowIdx++);
        String[] cols = {"Feature ID", "Feature File Name", "Test Case ID", "Scenario Description", "CBS Account Number", "Status", "Duration (s)", "Failure Reason"};
        for (int i = 0; i < cols.length; i++) {
            Cell c = tableHeader.createCell(i);
            c.setCellValue(truncate(cols[i], 30000));
            c.setCellStyle(tableHeaderStyle);
        }

        for (FeatureSummary f : suite.features) {
            for (TestCaseDetail tc : f.testCases) {
                Row r = sheet.createRow(rowIdx++);
                Cell c0 = r.createCell(0); c0.setCellValue(truncate(tc.featureId, 30000)); c0.setCellStyle(normalStyle);
                Cell c1 = r.createCell(1); c1.setCellValue(truncate(tc.featureName, 30000)); c1.setCellStyle(normalStyle);
                Cell c2 = r.createCell(2); c2.setCellValue(truncate(tc.testCaseId, 30000)); c2.setCellStyle(normalStyle);
                Cell c3 = r.createCell(3); c3.setCellValue(truncate(tc.description, 30000)); c3.setCellStyle(normalStyle);
                String cbsVal = (tc.cbsAccountNumber != null && !tc.cbsAccountNumber.isEmpty()) ? tc.cbsAccountNumber : "—";
                Cell c4 = r.createCell(4); c4.setCellValue(truncate(cbsVal, 30000)); c4.setCellStyle(normalStyle);
                Cell c5 = r.createCell(5); c5.setCellValue(truncate(tc.status, 30000)); c5.setCellStyle("PASSED".equalsIgnoreCase(tc.status) ? passStyle : failStyle);
                Cell c6 = r.createCell(6); c6.setCellValue(String.format("%.2f", tc.durationSeconds)); c6.setCellStyle(normalStyle);
                Cell c7 = r.createCell(7); c7.setCellValue(truncate(tc.failureReason, 30000)); c7.setCellStyle(normalStyle);
            }
        }

        for (int i = 0; i < cols.length; i++) {
            sheet.autoSizeColumn(i);
        }
    }

    private static void buildFailureDetailsSheet(Sheet sheet, SuiteSummary suite,
                                                 CellStyle titleStyle, CellStyle tableHeaderStyle,
                                                 CellStyle normalStyle, CellStyle failStyle) {
        int rowIdx = 0;

        Row titleRow = sheet.createRow(rowIdx++);
        Cell titleCell = titleRow.createCell(0);
        titleCell.setCellValue(truncate("FAILED TEST CASES & ROOT CAUSE ANALYSIS", 30000));
        titleCell.setCellStyle(titleStyle);
        sheet.addMergedRegion(new CellRangeAddress(0, 0, 0, 5));

        rowIdx++;

        Row tableHeader = sheet.createRow(rowIdx++);
        String[] cols = {"Feature ID", "Feature File Name", "Test Case ID / Scenario", "Failed Step Text (Line)", "Error / Failure Reason", "Step Log Snippet"};
        for (int i = 0; i < cols.length; i++) {
            Cell c = tableHeader.createCell(i);
            c.setCellValue(truncate(cols[i], 30000));
            c.setCellStyle(tableHeaderStyle);
        }

        if (suite.failedTestCases.isEmpty()) {
            Row r = sheet.createRow(rowIdx++);
            Cell c0 = r.createCell(0);
            c0.setCellValue(truncate("NO FAILURES DETECTED — ALL TEST CASES PASSED SUCCESSFULLY!", 30000));
            c0.setCellStyle(normalStyle);
            sheet.addMergedRegion(new CellRangeAddress(rowIdx - 1, rowIdx - 1, 0, 5));
        } else {
            for (TestCaseDetail tc : suite.failedTestCases) {
                Row r = sheet.createRow(rowIdx++);
                Cell c0 = r.createCell(0); c0.setCellValue(truncate(tc.featureId, 30000)); c0.setCellStyle(normalStyle);
                Cell c1 = r.createCell(1); c1.setCellValue(truncate(tc.featureName, 30000)); c1.setCellStyle(normalStyle);
                Cell c2 = r.createCell(2); c2.setCellValue(truncate(tc.testCaseId, 30000)); c2.setCellStyle(normalStyle);
                Cell c3 = r.createCell(3); c3.setCellValue(truncate("Line " + tc.line + ": " + tc.failedStep, 30000)); c3.setCellStyle(normalStyle);
                Cell c4 = r.createCell(4); c4.setCellValue(truncate(tc.failureReason, 30000)); c4.setCellStyle(failStyle);
                Cell c5 = r.createCell(5); c5.setCellValue(truncate(tc.stackTrace, 30000)); c5.setCellStyle(normalStyle);
            }
        }

        for (int i = 0; i < cols.length; i++) {
            sheet.autoSizeColumn(i);
        }
    }

    private static void buildSelfHealingRcaSheet(Sheet sheet,
                                                 CellStyle titleStyle, CellStyle tableHeaderStyle,
                                                 CellStyle normalStyle, CellStyle passStyle, CellStyle failStyle) {
        int rowIdx = 0;

        Row titleRow = sheet.createRow(rowIdx++);
        Cell titleCell = titleRow.createCell(0);
        titleCell.setCellValue(truncate("AUTONOMOUS QA SELF-HEALING — FIRST-TIME FAILURE, REWRITE & RESOLUTION", 30000));
        titleCell.setCellStyle(titleStyle);
        sheet.addMergedRegion(new CellRangeAddress(0, 0, 0, 8));

        rowIdx++;

        Row tableHeader = sheet.createRow(rowIdx++);
        String[] cols = {
                "Test Case ID", "Sub-Product", "Workbook", "Healed Field",
                "Old Value", "Rewritten Value", "First-Time Failure Reason",
                "Rewrite Summary", "Resolution Status"
        };
        for (int i = 0; i < cols.length; i++) {
            Cell c = tableHeader.createCell(i);
            c.setCellValue(truncate(cols[i], 30000));
            c.setCellStyle(tableHeaderStyle);
        }

        List<CbsConfigSelfHealingAgent.HealingRecord> healingLog = CbsConfigSelfHealingAgent.getHealingLog();
        if (healingLog.isEmpty()) {
            Row r = sheet.createRow(rowIdx++);
            Cell c0 = r.createCell(0);
            c0.setCellValue("NO CBS CONFIG DRIFT DETECTED — ALL EXCEL ROWS MATCHED LIVE CBS CONFIGURATION.");
            c0.setCellStyle(passStyle);
            sheet.addMergedRegion(new CellRangeAddress(rowIdx - 1, rowIdx - 1, 0, 8));
        } else {
            for (CbsConfigSelfHealingAgent.HealingRecord hr : healingLog) {
                Row r = sheet.createRow(rowIdx++);
                Cell c0 = r.createCell(0); c0.setCellValue(truncate(hr.testCaseId, 30000)); c0.setCellStyle(normalStyle);
                Cell c1 = r.createCell(1); c1.setCellValue(truncate(hr.productCode, 30000)); c1.setCellStyle(normalStyle);
                Cell c2 = r.createCell(2); c2.setCellValue(truncate(hr.workbookName, 30000)); c2.setCellStyle(normalStyle);
                Cell c3 = r.createCell(3); c3.setCellValue(truncate(hr.field, 30000)); c3.setCellStyle(normalStyle);
                Cell c4 = r.createCell(4); c4.setCellValue(truncate(String.valueOf(hr.oldValue), 30000)); c4.setCellStyle(normalStyle);
                Cell c5 = r.createCell(5); c5.setCellValue(truncate(String.valueOf(hr.newValue), 30000)); c5.setCellStyle(normalStyle);
                Cell c6 = r.createCell(6); c6.setCellValue(truncate(hr.firstTimeFailureReason, 30000)); c6.setCellStyle(normalStyle);
                Cell c7 = r.createCell(7); c7.setCellValue(truncate(hr.rewriteSummary, 30000)); c7.setCellStyle(normalStyle);
                Cell c8 = r.createCell(8); c8.setCellValue(truncate(hr.resolutionStatus, 30000));
                c8.setCellStyle(hr.resolutionStatus != null && hr.resolutionStatus.startsWith("RESOLVED") ? passStyle : failStyle);
            }
        }

        for (int i = 0; i < cols.length; i++) {
            sheet.autoSizeColumn(i);
        }
    }

    private static void saveWorkbook(Workbook workbook, File outputFile) {
        try (FileOutputStream out = new FileOutputStream(outputFile)) {
            workbook.write(out);
            out.flush();
        } catch (IOException e) {
            System.err.println("[KarateExcelReporter] Error saving Excel report: " + e.getMessage());
        }
    }

    // =========================================================================
    // TEXT & HTML SUMMARY GENERATORS (FOR JENKINS BUILD LOG & EMAILS)
    // =========================================================================

    private static void generateTextSummary(SuiteSummary suite, File summaryFile) {
        StringBuilder sb = new StringBuilder();
        sb.append("================================================================================\n");
        sb.append("BEYOND LO AUTOMATION — KARATE API TEST EXECUTION SUMMARY\n");
        sb.append("================================================================================\n");
        sb.append(String.format("Environment     : %s\n", suite.environment.toUpperCase()));
        sb.append(String.format("Execution Date  : %s\n", suite.executionDate));
        sb.append(String.format("Total Features  : %d\n", suite.totalFeatures));
        sb.append(String.format("Total Test Cases: %d (Passed: %d, Failed: %d, Pass Rate: %.2f%%)\n",
                suite.totalTestCases, suite.totalPassed, suite.totalFailed, suite.passPercentage));
        sb.append(String.format("Total Duration  : %.2f seconds\n", suite.totalDurationSeconds));
        sb.append("--------------------------------------------------------------------------------\n");
        sb.append("FEATURE BREAKDOWN (04, 05, 06, 07):\n");
        for (FeatureSummary f : suite.features) {
            if ("04".equals(f.featureId) || "05".equals(f.featureId) || "06".equals(f.featureId) || "07".equals(f.featureId)) {
                sb.append(String.format("  - [Feature %s] %-48s : %s (%d/%d Passed, %.2fs)\n",
                        f.featureId, f.featureName, f.status, f.passedCount, f.totalScenarios, f.durationSeconds));
            }
        }
        sb.append("--------------------------------------------------------------------------------\n");
        if (suite.totalFailed == 0) {
            sb.append("RESULT STATUS: SUCCESS - ALL TEST CASES PASSED SUCCESSFULLY!\n");
        } else {
            sb.append("RESULT STATUS: FAILURE - ").append(suite.totalFailed).append(" TEST CASE(S) FAILED:\n");
            for (TestCaseDetail fail : suite.failedTestCases) {
                sb.append(String.format("  * [%s - %s] Test Case: %s\n", fail.featureId, fail.featureName, fail.testCaseId));
                sb.append(String.format("    Failed Step: Line %d: %s\n", fail.line, fail.failedStep));
                sb.append(String.format("    Reason     : %s\n", fail.failureReason));
            }
        }
        List<CbsConfigSelfHealingAgent.HealingRecord> healed = CbsConfigSelfHealingAgent.getHealingLog();
        if (!healed.isEmpty()) {
            sb.append("--------------------------------------------------------------------------------\n");
            sb.append("AUTONOMOUS SELF-HEALING RCA (FIRST-TIME FAILURE -> REWRITE -> RESOLVED):\n");
            for (CbsConfigSelfHealingAgent.HealingRecord hr : healed) {
                sb.append(String.format("  * [%s | %s] %s: %s -> %s%n",
                        hr.testCaseId, hr.productCode, hr.field, hr.oldValue, hr.newValue));
                sb.append(String.format("    Why It Would Fail : %s%n", hr.firstTimeFailureReason));
                sb.append(String.format("    Rewrite Applied   : %s%n", hr.rewriteSummary));
                sb.append(String.format("    Resolution Status : %s%n", hr.resolutionStatus));
            }
        }
        sb.append("================================================================================\n");

        System.out.println("\n" + sb.toString());

        try (FileWriter fw = new FileWriter(summaryFile, StandardCharsets.UTF_8)) {
            fw.write(sb.toString());
        } catch (IOException e) {
            System.err.println("[KarateExcelReporter] Warning: Failed to save text summary: " + e.getMessage());
        }
    }

    private static void generateHtmlSummary(SuiteSummary suite, File htmlFile) {
        StringBuilder sb = new StringBuilder();
        sb.append("<!DOCTYPE html>\n<html>\n<head>\n<meta charset=\"UTF-8\">\n");
        sb.append("<style>\n");
        sb.append("body { font-family: 'Segoe UI', Arial, sans-serif; background-color: #f4f6f9; color: #333; margin: 20px; }\n");
        sb.append(".container { background: #fff; border-radius: 8px; padding: 25px; box-shadow: 0 4px 12px rgba(0,0,0,0.08); }\n");
        sb.append("h2 { color: #1b365d; border-bottom: 2px solid #1b365d; padding-bottom: 8px; }\n");
        sb.append(".metric-box { display: inline-block; width: 22%; background: #f8f9fa; border: 1px solid #e9ecef; border-radius: 6px; padding: 15px; margin-right: 2%; text-align: center; box-sizing: border-box; }\n");
        sb.append(".metric-val { font-size: 24px; font-weight: bold; margin-top: 5px; }\n");
        sb.append(".pass { color: #28a745; } .fail { color: #dc3545; }\n");
        sb.append("table { width: 100%; border-collapse: collapse; margin-top: 20px; }\n");
        sb.append("th, td { border: 1px solid #dee2e6; padding: 10px 12px; text-align: left; }\n");
        sb.append("th { background-color: #1b365d; color: #fff; }\n");
        sb.append("tr:nth-child(even) { background-color: #f8f9fa; }\n");
        sb.append(".status-badge { padding: 4px 8px; border-radius: 4px; font-weight: bold; text-align: center; }\n");
        sb.append(".badge-pass { background-color: #d4edda; color: #155724; }\n");
        sb.append(".badge-fail { background-color: #f8d7da; color: #721c24; }\n");
        sb.append("</style>\n</head>\n<body>\n");
        sb.append("<div class=\"container\">\n");
        sb.append("<h2>Beyond LO — Karate API Test Execution Summary</h2>\n");

        sb.append("<div style=\"margin-bottom: 20px;\">\n");
        sb.append(String.format("<div class=\"metric-box\"><div>Total Test Cases</div><div class=\"metric-val\">%d</div></div>\n", suite.totalTestCases));
        sb.append(String.format("<div class=\"metric-box\"><div>Passed</div><div class=\"metric-val pass\">%d</div></div>\n", suite.totalPassed));
        sb.append(String.format("<div class=\"metric-box\"><div>Failed</div><div class=\"metric-val fail\">%d</div></div>\n", suite.totalFailed));
        sb.append(String.format("<div class=\"metric-box\"><div>Pass Rate</div><div class=\"metric-val\">%.1f%%</div></div>\n", suite.passPercentage));
        sb.append("</div>\n");

        sb.append("<h3>Feature Execution Breakdown (Features 04, 05, 06, 07)</h3>\n");
        sb.append("<table>\n<thead><tr><th>Feature ID</th><th>Feature File</th><th>Test Cases</th><th>Passed</th><th>Failed</th><th>Duration (s)</th><th>Status</th></tr></thead>\n<tbody>\n");
        for (FeatureSummary f : suite.features) {
            String badge = "PASSED".equalsIgnoreCase(f.status) ? "badge-pass" : "badge-fail";
            sb.append(String.format("<tr><td>%s</td><td>%s</td><td>%d</td><td>%d</td><td>%d</td><td>%.2f</td><td><span class=\"status-badge %s\">%s</span></td></tr>\n",
                    f.featureId, f.featureName, f.totalScenarios, f.passedCount, f.failedCount, f.durationSeconds, badge, f.status));
        }
        sb.append("</tbody>\n</table>\n");

        if (suite.totalFailed > 0) {
            sb.append("<h3 style=\"color: #dc3545;\">Failed Test Cases Details</h3>\n");
            sb.append("<table>\n<thead><tr><th>Feature</th><th>Test Case ID</th><th>Failed Step</th><th>Failure Reason</th></tr></thead>\n<tbody>\n");
            for (TestCaseDetail fail : suite.failedTestCases) {
                sb.append(String.format("<tr><td>%s</td><td>%s</td><td>Line %d: %s</td><td style=\"color: #dc3545;\">%s</td></tr>\n",
                        fail.featureName, fail.testCaseId, fail.line, fail.failedStep, fail.failureReason));
            }
            sb.append("</tbody>\n</table>\n");
        }

        List<CbsConfigSelfHealingAgent.HealingRecord> healedHtml = CbsConfigSelfHealingAgent.getHealingLog();
        if (!healedHtml.isEmpty()) {
            sb.append("<h3 style=\"color: #1b365d;\">Autonomous Self-Healing RCA (First-Time Failure &rarr; Rewrite &rarr; Resolution)</h3>\n");
            sb.append("<table>\n<thead><tr><th>Test Case ID</th><th>Sub-Product</th><th>Field Change</th><th>First-Time Failure Reason</th><th>Rewrite Applied</th><th>Resolution</th></tr></thead>\n<tbody>\n");
            for (CbsConfigSelfHealingAgent.HealingRecord hr : healedHtml) {
                String resBadge = (hr.resolutionStatus != null && hr.resolutionStatus.startsWith("RESOLVED")) ? "badge-pass" : "badge-fail";
                sb.append(String.format("<tr><td>%s</td><td>%s</td><td>%s: %s &rarr; %s</td><td>%s</td><td>%s</td><td><span class=\"status-badge %s\">%s</span></td></tr>\n",
                        hr.testCaseId, hr.productCode, hr.field, hr.oldValue, hr.newValue,
                        hr.firstTimeFailureReason, hr.rewriteSummary, resBadge, hr.resolutionStatus));
            }
            sb.append("</tbody>\n</table>\n");
        }

        sb.append("</div>\n</body>\n</html>\n");

        try (FileWriter fw = new FileWriter(htmlFile, StandardCharsets.UTF_8)) {
            fw.write(sb.toString());
        } catch (IOException e) {
            System.err.println("[KarateExcelReporter] Warning: Failed to save HTML summary: " + e.getMessage());
        }
    }

    // =========================================================================
    // STYLING HELPERS FOR POI
    // =========================================================================

    private static CellStyle createTitleStyle(Workbook wb) {
        CellStyle style = wb.createCellStyle();
        Font font = wb.createFont();
        font.setBold(true);
        font.setFontHeightInPoints((short) 14);
        font.setColor(IndexedColors.WHITE.getIndex());
        style.setFont(font);
        style.setFillForegroundColor(IndexedColors.DARK_BLUE.getIndex());
        style.setFillPattern(FillPatternType.SOLID_FOREGROUND);
        style.setAlignment(HorizontalAlignment.CENTER);
        style.setVerticalAlignment(VerticalAlignment.CENTER);
        return style;
    }

    private static CellStyle createMetaHeaderStyle(Workbook wb) {
        CellStyle style = wb.createCellStyle();
        Font font = wb.createFont();
        font.setBold(true);
        style.setFont(font);
        style.setFillForegroundColor(IndexedColors.GREY_25_PERCENT.getIndex());
        style.setFillPattern(FillPatternType.SOLID_FOREGROUND);
        style.setBorderBottom(BorderStyle.THIN);
        style.setBorderTop(BorderStyle.THIN);
        style.setBorderLeft(BorderStyle.THIN);
        style.setBorderRight(BorderStyle.THIN);
        return style;
    }

    private static CellStyle createMetaValueStyle(Workbook wb) {
        CellStyle style = wb.createCellStyle();
        style.setBorderBottom(BorderStyle.THIN);
        style.setBorderTop(BorderStyle.THIN);
        style.setBorderLeft(BorderStyle.THIN);
        style.setBorderRight(BorderStyle.THIN);
        return style;
    }

    private static CellStyle createTableHeaderStyle(Workbook wb) {
        CellStyle style = wb.createCellStyle();
        Font font = wb.createFont();
        font.setBold(true);
        font.setColor(IndexedColors.WHITE.getIndex());
        style.setFont(font);
        style.setFillForegroundColor(IndexedColors.ROYAL_BLUE.getIndex());
        style.setFillPattern(FillPatternType.SOLID_FOREGROUND);
        style.setAlignment(HorizontalAlignment.CENTER);
        style.setBorderBottom(BorderStyle.MEDIUM);
        style.setBorderTop(BorderStyle.MEDIUM);
        style.setBorderLeft(BorderStyle.THIN);
        style.setBorderRight(BorderStyle.THIN);
        return style;
    }

    private static CellStyle createNormalStyle(Workbook wb) {
        CellStyle style = wb.createCellStyle();
        style.setBorderBottom(BorderStyle.THIN);
        style.setBorderTop(BorderStyle.THIN);
        style.setBorderLeft(BorderStyle.THIN);
        style.setBorderRight(BorderStyle.THIN);
        return style;
    }

    private static CellStyle createStatusStyle(Workbook wb, short colorIndex) {
        CellStyle style = wb.createCellStyle();
        Font font = wb.createFont();
        font.setBold(true);
        font.setColor(colorIndex);
        style.setFont(font);
        style.setAlignment(HorizontalAlignment.CENTER);
        style.setBorderBottom(BorderStyle.THIN);
        style.setBorderTop(BorderStyle.THIN);
        style.setBorderLeft(BorderStyle.THIN);
        style.setBorderRight(BorderStyle.THIN);
        return style;
    }
}
