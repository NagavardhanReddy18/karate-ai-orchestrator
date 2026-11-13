package com.ird.beyond.lo.test.util;

import com.intuit.karate.JsonUtils;
import org.apache.poi.ss.usermodel.*;
import org.apache.poi.xssf.usermodel.XSSFWorkbook;

import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.time.DayOfWeek;
import java.time.Duration;
import java.time.Instant;
import java.time.LocalDate;
import java.util.*;
import java.util.concurrent.CopyOnWriteArrayList;

/**
 * CbsConfigSelfHealingAgent
 * -------------------------
 * Agentic ReAct Pre-Flight & Row-Level Self-Healer for Karate + Excel suites.
 *
 * When CBS product rules (min/max loan amount, min/max tenor, default interest rate type,
 * repayment options, or CBS business date) change, positive Excel test rows become stale.
 * This agent:
 *   1. Discovers live CBS product config & business date via REST tools.
 *   2. Reasons over each positive row (preserving intentional negative tests).
 *   3. Heals drifted values in-memory (and optionally writes back to .xlsx if
 *      -Dkarate.agent.writeExcel=true).
 *   4. Writes an audit report to target/karate-reports/cbs-agent-healing-report.json.
 */
public class CbsConfigSelfHealingAgent {

    public static final String REPORT_FILENAME = "cbs-agent-healing-report.json";
    public static final String TEXT_REPORT_FILENAME = "Autonomous_QA_Healing_Summary.txt";
    private static final List<HealingRecord> HEALING_LOG = new CopyOnWriteArrayList<>();
    private static final Properties FILE_CONFIG = loadAgentConfig();
    private static volatile LiveCbsState cachedLiveState = null;
    private static volatile boolean discoveryAttempted = false;

    public static class HealingRecord {
        public String filePath;
        public String workbookName;
        public String testCaseId;
        public String productCode;
        public String field;
        public Object oldValue;
        public Object newValue;
        public String firstTimeFailureReason;
        public String thought;
        public String action;
        public String rewriteSummary;
        public String resolutionStatus = "PENDING_VERIFICATION";
        public String cbsAccountNumber = "";
        public String timestamp;

        public Map<String, Object> toMap() {
            Map<String, Object> m = new LinkedHashMap<>();
            m.put("filePath", filePath);
            m.put("workbookName", workbookName);
            m.put("testCaseId", testCaseId);
            m.put("productCode", productCode);
            m.put("field", field);
            m.put("oldValue", oldValue);
            m.put("newValue", newValue);
            m.put("firstTimeFailureReason", firstTimeFailureReason);
            m.put("thought", thought);
            m.put("action", action);
            m.put("rewriteSummary", rewriteSummary);
            m.put("resolutionStatus", resolutionStatus);
            m.put("cbsAccountNumber", cbsAccountNumber);
            m.put("timestamp", timestamp);
            return m;
        }
    }

    public static class LiveCbsState {
        public String baseUrl;
        public LocalDate businessDate;
        public Map<String, Map<String, Object>> products = new LinkedHashMap<>();
    }

    private static Properties loadAgentConfig() {
        Properties props = new Properties();
        String customPath = System.getProperty("agent.config.file", "config/agent-config.properties");
        Path p = Paths.get(customPath);
        if (Files.isRegularFile(p)) {
            try (FileInputStream fis = new FileInputStream(p.toFile())) {
                props.load(fis);
                System.out.println("[CbsConfigSelfHealingAgent] Loaded config: " + p.toAbsolutePath());
            } catch (Exception e) {
                System.err.println("[CbsConfigSelfHealingAgent] Warning reading config " + p + ": " + e.getMessage());
            }
        }
        return props;
    }

    public static String getConfig(String key, String defaultValue) {
        String sys = System.getProperty(key);
        if (sys != null && !sys.isBlank()) return sys.trim();
        String fileVal = FILE_CONFIG.getProperty(key);
        if (fileVal != null && !fileVal.isBlank()) return fileVal.trim();
        return defaultValue;
    }

    public static Path resolveBrainDir() {
        String raw = getConfig("agent.brain.dir", "./brain");
        Path p = Paths.get(raw);
        return p.isAbsolute() ? p.normalize() : Paths.get(System.getProperty("user.dir")).resolve(p).normalize();
    }

    public static Path resolveBrainReportsDir() {
        Path brain = resolveBrainDir();
        return Files.isDirectory(brain) ? brain.resolve("reports") : null;
    }

    public static boolean isHealingEnabled() {
        return !"false".equalsIgnoreCase(getConfig("karate.agent.heal", "true"));
    }

    public static boolean isWriteExcelEnabled() {
        return "true".equalsIgnoreCase(getConfig("karate.agent.writeExcel", "false"));
    }

    /** Called automatically by ExcelDataLoader.load(...) */
    public static List<Map<String, Object>> healLoadedRows(String filePath, List<Map<String, Object>> rows) {
        if (!isHealingEnabled() || rows == null || rows.isEmpty()) {
            return rows;
        }

        // Only heal origination/lifecycle rows that carry product/loan fields (skip config setup sheets)
        boolean looksLikeLoanSheet = rows.stream().anyMatch(r ->
                r.containsKey("selectedProductCode") || r.containsKey("loanAmount") || r.containsKey("loanStartDate"));
        if (!looksLikeLoanSheet) {
            return rows;
        }

        LiveCbsState state = getOrDiscoverLiveState();
        if (state == null || (state.businessDate == null && state.products.isEmpty())) {
            return rows;
        }

        return healRows(filePath, rows, state, isWriteExcelEnabled());
    }

    /** Core ReAct healing entry point (also directly callable in offline tests with a simulated LiveCbsState). */
    public static List<Map<String, Object>> healRows(
            String filePath,
            List<Map<String, Object>> rows,
            LiveCbsState state,
            boolean writeExcel) {

        if (rows == null || rows.isEmpty() || state == null) return rows;

        Map<String, Map<String, Object>> healedCellsByTestCaseId = new LinkedHashMap<>();

        for (Map<String, Object> row : rows) {
            String tcId = str(row.get("testCaseId"));
            if (isNegativeRow(row)) {
                continue; // Preserve intentional negative/exception tests
            }

            String productCode = str(row.get("selectedProductCode"));
            Map<String, Object> product = productCode.isEmpty() ? null : state.products.get(productCode);
            Map<String, Object> rowEdits = new LinkedHashMap<>();

            // 1. Loan Amount & Approval Limit Drift
            if (product != null && row.containsKey("loanAmount")) {
                healLoanAmount(filePath, tcId, productCode, row, product, rowEdits);
            }

            // 2. Tenor Drift
            if (product != null && row.containsKey("loanTerm")) {
                healLoanTenure(filePath, tcId, productCode, row, product, rowEdits);
            }

            // 3. Interest Type / Default Rate Drift
            if (product != null && row.containsKey("interestType")) {
                healInterestType(filePath, tcId, productCode, row, product, rowEdits);
            }

            // 4. CBS Business Date Drift (Past dates or weekends)
            if (state.businessDate != null) {
                healDates(filePath, tcId, productCode, row, state.businessDate, rowEdits);
            }

            // 5. Disabled Repayment Options Drift (PEP / Balloon / Moratorium / Step)
            if (product != null) {
                healDisabledOptions(filePath, tcId, productCode, row, product, rowEdits);
            }

            if (!rowEdits.isEmpty() && !tcId.isEmpty()) {
                healedCellsByTestCaseId.put(tcId, rowEdits);
            }
        }

        if (writeExcel && !healedCellsByTestCaseId.isEmpty() && filePath != null) {
            writeHealedValuesToExcel(filePath, healedCellsByTestCaseId);
        }

        writeReport("target/karate-reports");
        return rows;
    }

    private static void healLoanAmount(
            String filePath, String tcId, String productCode,
            Map<String, Object> row, Map<String, Object> product, Map<String, Object> rowEdits) {

        Double currentAmt = toDouble(row.get("loanAmount"));
        if (currentAmt == null) return;

        Double minAmt = firstNonNullDouble(product.get("minLoanAmount"), product.get("minAmount"), product.get("minimumAmount"));
        Double maxAmt = firstNonNullDouble(product.get("maxLoanAmount"), product.get("maxAmount"), product.get("maximumAmount"));

        Double healedAmt = null;
        String reason = null;
        if (minAmt != null && currentAmt < minAmt) {
            healedAmt = (maxAmt != null && maxAmt >= minAmt) ? Math.min(maxAmt, Math.ceil(minAmt * 1.25)) : minAmt;
            reason = String.format("CBS raised minimum loan amount for %s to %.0f (Excel had %.0f).", productCode, minAmt, currentAmt);
        } else if (maxAmt != null && maxAmt > 0 && currentAmt > maxAmt) {
            healedAmt = (minAmt != null && minAmt <= maxAmt) ? Math.max(minAmt, Math.floor(maxAmt * 0.8)) : maxAmt;
            reason = String.format("CBS lowered maximum loan amount for %s to %.0f (Excel had %.0f).", productCode, maxAmt, currentAmt);
        }

        if (healedAmt != null) {
            Number formatted = (healedAmt == Math.floor(healedAmt)) ? (Number) healedAmt.longValue() : healedAmt;
            row.put("loanAmount", formatted);
            rowEdits.put("loanAmount", formatted);
            recordHealing(filePath, tcId, productCode, "loanAmount", currentAmt, formatted,
                    reason, "HEAL_LOAN_AMOUNT");

            // Keep totalAmount / approvalLimitAmount consistent so downstream checks don't fail
            Double totalAmt = toDouble(row.get("totalAmount"));
            if (totalAmt != null && totalAmt < healedAmt) {
                row.put("totalAmount", formatted);
                rowEdits.put("totalAmount", formatted);
                recordHealing(filePath, tcId, productCode, "totalAmount", totalAmt, formatted,
                        "Adjusted totalAmount to match healed loanAmount.", "SYNC_TOTAL_AMOUNT");
            }
            Double limitAmt = toDouble(row.get("approvalLimitAmount"));
            if (limitAmt != null && limitAmt < healedAmt) {
                Number newLimit = Math.round(healedAmt * 2);
                row.put("approvalLimitAmount", newLimit);
                rowEdits.put("approvalLimitAmount", newLimit);
                recordHealing(filePath, tcId, productCode, "approvalLimitAmount", limitAmt, newLimit,
                        "Raised approvalLimitAmount above healed loanAmount.", "SYNC_APPROVAL_LIMIT");
            }
        }
    }

    private static void healLoanTenure(
            String filePath, String tcId, String productCode,
            Map<String, Object> row, Map<String, Object> product, Map<String, Object> rowEdits) {

        Double rawTerm = toDouble(row.get("loanTerm"));
        if (rawTerm == null) return;

        String freq = str(row.get("termFrequency")).toUpperCase();
        boolean isYears = "YEARS".equals(freq);
        double termMonths = isYears ? rawTerm * 12 : rawTerm;

        Double minTen = firstNonNullDouble(product.get("minTenure"), product.get("minTermMonths"), product.get("minimumTenure"));
        Double maxTen = firstNonNullDouble(product.get("maxTenure"), product.get("maxTermMonths"), product.get("maximumTenure"));

        Double healedMonths = null;
        String reason = null;
        if (minTen != null && termMonths < minTen) {
            healedMonths = minTen;
            reason = String.format("CBS raised min tenure for %s to %.0f months (Excel had %.0f months).", productCode, minTen, termMonths);
        } else if (maxTen != null && maxTen > 0 && termMonths > maxTen) {
            healedMonths = (minTen != null && minTen <= maxTen) ? Math.max(minTen, Math.min(maxTen, 24.0)) : maxTen;
            reason = String.format("CBS lowered max tenure for %s to %.0f months (Excel had %.0f months).", productCode, maxTen, termMonths);
        }

        if (healedMonths != null) {
            long healedTermValue = isYears ? Math.max(1L, Math.round(healedMonths / 12.0)) : Math.round(healedMonths);
            if (isYears && healedTermValue * 12L > (maxTen != null ? maxTen.longValue() : Long.MAX_VALUE)) {
                row.put("termFrequency", "MONTHS");
                rowEdits.put("termFrequency", "MONTHS");
                healedTermValue = Math.round(healedMonths);
            }
            row.put("loanTerm", healedTermValue);
            rowEdits.put("loanTerm", healedTermValue);
            recordHealing(filePath, tcId, productCode, "loanTerm", rawTerm, healedTermValue, reason, "HEAL_TENURE");
        }
    }

    private static void healInterestType(
            String filePath, String tcId, String productCode,
            Map<String, Object> row, Map<String, Object> product, Map<String, Object> rowEdits) {

        String currentType = str(row.get("interestType")).toUpperCase();
        if (currentType.isEmpty()) return;

        boolean hasFixed = !str(product.get("defaultFixedRateId")).isEmpty();
        boolean hasFloating = !str(product.get("defaultFloatingRateId")).isEmpty();
        boolean hasProgressive = !str(product.get("defaultProgressiveRateId")).isEmpty();

        if (!hasFixed && !hasFloating && !hasProgressive) return; // Product config didn't carry rate IDs

        boolean currentSupported = ("FIXED".equals(currentType) && hasFixed)
                || ("FLOATING".equals(currentType) && hasFloating)
                || ("PROGRESSIVE".equals(currentType) && hasProgressive);

        if (!currentSupported) {
            String fallbackType = hasFloating ? "FLOATING" : (hasFixed ? "FIXED" : "PROGRESSIVE");
            row.put("interestType", fallbackType);
            rowEdits.put("interestType", fallbackType);
            recordHealing(filePath, tcId, productCode, "interestType", currentType, fallbackType,
                    String.format("CBS product %s no longer configures a default rate for %s; switched to %s.", productCode, currentType, fallbackType),
                    "HEAL_INTEREST_TYPE");
        }
    }

    private static void healDates(
            String filePath, String tcId, String productCode,
            Map<String, Object> row, LocalDate businessDate, Map<String, Object> rowEdits) {

        LocalDate loanStart = parseDate(str(row.get("loanStartDate")));
        LocalDate minStart = nextBusinessDay(businessDate);

        if (loanStart != null && (loanStart.isBefore(businessDate) || isWeekend(loanStart))) {
            row.put("loanStartDate", minStart.toString());
            rowEdits.put("loanStartDate", minStart.toString());
            recordHealing(filePath, tcId, productCode, "loanStartDate", loanStart.toString(), minStart.toString(),
                    "Excel loanStartDate was before CBS businessDate (" + businessDate + ") or fell on a weekend.",
                    "SHIFT_LOAN_START_DATE");
            loanStart = minStart;
        }

        LocalDate baseRef = loanStart != null ? loanStart : minStart;

        LocalDate disbDate = parseDate(str(row.get("disbursementDate")));
        if (disbDate != null && (disbDate.isBefore(baseRef) || isWeekend(disbDate))) {
            LocalDate healedDisb = nextBusinessDay(baseRef);
            row.put("disbursementDate", healedDisb.toString());
            rowEdits.put("disbursementDate", healedDisb.toString());
            recordHealing(filePath, tcId, productCode, "disbursementDate", disbDate.toString(), healedDisb.toString(),
                    "Excel disbursementDate preceded loanStartDate/businessDate or fell on a weekend.",
                    "SHIFT_DISBURSEMENT_DATE");
            baseRef = healedDisb;
        }

        LocalDate repayStart = parseDate(str(row.get("repaymentStartDate")));
        if (repayStart != null && (repayStart.isBefore(baseRef) || isWeekend(repayStart))) {
            LocalDate healedRepay = nextBusinessDay(baseRef.plusMonths(1));
            row.put("repaymentStartDate", healedRepay.toString());
            rowEdits.put("repaymentStartDate", healedRepay.toString());
            recordHealing(filePath, tcId, productCode, "repaymentStartDate", repayStart.toString(), healedRepay.toString(),
                    "Excel repaymentStartDate preceded disbursement/businessDate or fell on a weekend.",
                    "SHIFT_REPAYMENT_START_DATE");
        }
    }

    @SuppressWarnings("unchecked")
    private static void healDisabledOptions(
            String filePath, String tcId, String productCode,
            Map<String, Object> row, Map<String, Object> product, Map<String, Object> rowEdits) {

        Map<String, Object> modes = product.get("repaymentFieldModes") instanceof Map
                ? (Map<String, Object>) product.get("repaymentFieldModes") : Collections.emptyMap();

        if (row.get("pepRows") != null && (Boolean.FALSE.equals(product.get("pepApplicable"))
                || (modes.containsKey("PEP") && !"E".equals(str(modes.get("PEP")))))) {
            Object prev = row.get("pepRows");
            row.put("pepRows", null);
            rowEdits.put("pepRows", "");
            recordHealing(filePath, tcId, productCode, "pepRows", prev, null,
                    "CBS disabled PEP for product " + productCode + "; cleared stale pepRows.", "CLEAR_DISABLED_PEP");
        }

        if (row.get("balloonAmount") != null && (Boolean.FALSE.equals(product.get("balloonPayment"))
                || (modes.containsKey("BALLOON") && !"E".equals(str(modes.get("BALLOON")))))) {
            Object prev = row.get("balloonAmount");
            row.put("balloonAmount", null);
            rowEdits.put("balloonAmount", "");
            recordHealing(filePath, tcId, productCode, "balloonAmount", prev, null,
                    "CBS disabled Balloon payment for product " + productCode + "; cleared stale balloonAmount.", "CLEAR_DISABLED_BALLOON");
        }
    }

    // =========================================================================
    // LIVE CBS DISCOVERY TOOLS
    // =========================================================================

    private static synchronized LiveCbsState getOrDiscoverLiveState() {
        if (discoveryAttempted) return cachedLiveState;
        discoveryAttempted = true;
        try {
            cachedLiveState = discoverLiveCbsState();
        } catch (Exception e) {
            System.out.println("[CbsConfigSelfHealingAgent] Live CBS discovery skipped (" + e.getMessage() + ")");
            cachedLiveState = null;
        }
        return cachedLiveState;
    }

    @SuppressWarnings("unchecked")
    public static LiveCbsState discoverLiveCbsState() throws Exception {
        String baseUrl = resolveBaseUrl();
        HttpClient http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(4)).build();
        String token = authenticate(http, baseUrl);
        if (token == null) {
            System.out.println("[CbsConfigSelfHealingAgent] Could not authenticate against " + baseUrl + " — skipping live sync.");
            return null;
        }

        LiveCbsState state = new LiveCbsState();
        state.baseUrl = baseUrl;

        // Tool 1: Fetch CBS Business Date
        try {
            HttpRequest req = HttpRequest.newBuilder()
                    .uri(URI.create(baseUrl + "/v1/system/business-date"))
                    .timeout(Duration.ofSeconds(5))
                    .header("Authorization", "Bearer " + token)
                    .GET().build();
            HttpResponse<String> res = http.send(req, HttpResponse.BodyHandlers.ofString());
            if (res.statusCode() == 200 && res.body() != null) {
                Map<String, Object> body = (Map<String, Object>) JsonUtils.fromJson(res.body());
                state.businessDate = parseDate(str(body.get("businessDate")));
            }
        } catch (Exception ignored) { /* Non-fatal */ }

        // Tool 2: Fetch Live Sub-Product Configurations
        for (String query : List.of("?currency=USD&size=200", "?size=200")) {
            if (!state.products.isEmpty() && "?size=200".equals(query)) {
                break;
            }
            try {
                HttpRequest req = HttpRequest.newBuilder()
                        .uri(URI.create(baseUrl + "/v1/origination/products/search" + query))
                        .timeout(Duration.ofSeconds(8))
                        .header("Authorization", "Bearer " + token)
                        .GET().build();
                HttpResponse<String> res = http.send(req, HttpResponse.BodyHandlers.ofString());
                if (res.statusCode() == 200 && res.body() != null) {
                    Object parsed = JsonUtils.fromJson(res.body());
                    List<Map<String, Object>> items = null;
                    if (parsed instanceof Map<?, ?> m && m.get("items") instanceof List<?> l) {
                        items = (List<Map<String, Object>>) l;
                    } else if (parsed instanceof List<?> l) {
                        items = (List<Map<String, Object>>) l;
                    }
                    if (items != null) {
                        for (Map<String, Object> item : items) {
                            String code = str(item.get("productCode"));
                            if (!code.isEmpty()) state.products.put(code, item);
                        }
                    }
                }
            } catch (Exception ignored) { /* Non-fatal */ }
        }

        System.out.printf("[CbsConfigSelfHealingAgent] Connected to %s | BusinessDate=%s | Products Discovered=%d%n",
                baseUrl, state.businessDate, state.products.size());
        return state;
    }

    @SuppressWarnings("unchecked")
    private static String authenticate(HttpClient http, String baseUrl) {
        String pinnedPass = System.getProperty("lo.test.password");
        List<String> passwords = pinnedPass != null && !pinnedPass.isBlank()
                ? List.of(pinnedPass) : List.of("Password123", "Password@123");
        List<String> users = List.of("appuser01", "admin", "admin1", "naga");

        for (String user : users) {
            for (String pass : passwords) {
                try {
                    String payload = JsonUtils.toJson(Map.of("username", user, "password", pass));
                    HttpRequest req = HttpRequest.newBuilder()
                            .uri(URI.create(baseUrl + "/auth/login"))
                            .timeout(Duration.ofSeconds(3))
                            .header("Content-Type", "application/json")
                            .POST(HttpRequest.BodyPublishers.ofString(payload)).build();
                    HttpResponse<String> res = http.send(req, HttpResponse.BodyHandlers.ofString());
                    if (res.statusCode() == 200) {
                        Map<String, Object> body = (Map<String, Object>) JsonUtils.fromJson(res.body());
                        if (Boolean.TRUE.equals(body.get("requiresSessionConfirm"))) {
                            String cPayload = JsonUtils.toJson(Map.of("confirmToken", body.get("confirmToken")));
                            HttpRequest cReq = HttpRequest.newBuilder()
                                    .uri(URI.create(baseUrl + "/auth/confirm-session"))
                                    .header("Content-Type", "application/json")
                                    .POST(HttpRequest.BodyPublishers.ofString(cPayload)).build();
                            HttpResponse<String> cRes = http.send(cReq, HttpResponse.BodyHandlers.ofString());
                            if (cRes.statusCode() == 200) body = (Map<String, Object>) JsonUtils.fromJson(cRes.body());
                        }
                        String token = str(body.get("token"));
                        if (!token.isEmpty()) return token;
                    }
                } catch (Exception ignored) {
                    return null; // Server unreachable
                }
            }
        }
        return null;
    }

    private static String resolveBaseUrl() {
        String explicit = getConfig("lo.test.baseUrl", "");
        if (!explicit.isEmpty()) return explicit;
        String env = getConfig("karate.env", "dev").toLowerCase();
        return switch (env) {
            case "local" -> "http://localhost:9090/api";
            case "staging", "test", "9190" -> "http://164.52.210.93:9190/api";
            case "production" -> "http://prod.beyondlo.internal/api";
            default -> "http://164.52.210.93:9090/api";
        };
    }

    // =========================================================================
    // EXCEL PERSISTENCE & REPORTING
    // =========================================================================

    private static void writeHealedValuesToExcel(String filePath, Map<String, Map<String, Object>> editsByTestCaseId) {
        List<File> targets = new ArrayList<>();
        targets.add(new File(filePath));

        String normalized = filePath.replace('/', '\\');
        String compiledMarker = "\\target\\test-classes\\";
        int idx = normalized.indexOf(compiledMarker);
        if (idx >= 0) {
            String sourcePath = normalized.substring(0, idx) + "\\src\\test\\resources\\" + normalized.substring(idx + compiledMarker.length());
            File sourceFile = new File(sourcePath);
            if (sourceFile.exists() && !sourceFile.equals(targets.get(0))) {
                targets.add(sourceFile);
            }
        }

        for (File file : targets) {
            writeEditsToSingleWorkbook(file, editsByTestCaseId);
        }
    }

    private static void writeEditsToSingleWorkbook(File file, Map<String, Map<String, Object>> editsByTestCaseId) {
        if (!file.exists()) return;
        try (FileInputStream fis = new FileInputStream(file);
             Workbook wb = new XSSFWorkbook(fis)) {
            Sheet sheet = wb.getSheetAt(0);
            Row header = sheet.getRow(0);
            if (header == null) return;

            Map<String, Integer> colIndex = new LinkedHashMap<>();
            for (Cell c : header) {
                colIndex.put(c.getStringCellValue().trim(), c.getColumnIndex());
            }
            Integer tcCol = colIndex.get("testCaseId");
            if (tcCol == null) return;

            for (int r = 1; r <= sheet.getLastRowNum(); r++) {
                Row row = sheet.getRow(r);
                if (row == null) continue;
                Cell tcCell = row.getCell(tcCol);
                if (tcCell == null) continue;
                String tcId = tcCell.toString().trim();
                Map<String, Object> edits = editsByTestCaseId.get(tcId);
                if (edits == null) continue;

                for (Map.Entry<String, Object> e : edits.entrySet()) {
                    Integer targetCol = colIndex.get(e.getKey());
                    if (targetCol == null) continue;
                    Cell cell = row.getCell(targetCol, Row.MissingCellPolicy.CREATE_NULL_AS_BLANK);
                    if (e.getValue() instanceof Number n) {
                        cell.setCellValue(n.doubleValue());
                    } else {
                        cell.setCellValue(e.getValue() == null ? "" : e.getValue().toString());
                    }
                }
            }

            try (FileOutputStream fos = new FileOutputStream(file)) {
                wb.write(fos);
            }
            System.out.println("[CbsConfigSelfHealingAgent] Updated Excel workbook: " + file.getPath());
        } catch (Exception e) {
            System.err.println("[CbsConfigSelfHealingAgent] Failed writing Excel updates (" + file.getPath() + "): " + e.getMessage());
        }
    }

    public static void finalizeResolutions(
            Map<String, String> statusByTestCaseId,
            Map<String, String> cbsAccountByTestCaseId,
            Map<String, String> failureByTestCaseId,
            String reportDir) {
        if (!HEALING_LOG.isEmpty() && statusByTestCaseId != null) {
            for (HealingRecord r : HEALING_LOG) {
                String status = statusByTestCaseId.getOrDefault(r.testCaseId, "");
                String cbsAcc = cbsAccountByTestCaseId != null ? cbsAccountByTestCaseId.getOrDefault(r.testCaseId, "") : "";
                String failErr = failureByTestCaseId != null ? failureByTestCaseId.getOrDefault(r.testCaseId, "") : "";
                r.cbsAccountNumber = cbsAcc != null ? cbsAcc : "";
                if ("PASSED".equalsIgnoreCase(status)) {
                    r.resolutionStatus = (cbsAcc != null && !cbsAcc.isEmpty())
                            ? "RESOLVED — Test PASSED after rewrite (CBS Account: " + cbsAcc + ")"
                            : "RESOLVED — Test PASSED after rewrite";
                } else if ("FAILED".equalsIgnoreCase(status)) {
                    r.resolutionStatus = "UNRESOLVED — Test still failed after rewrite"
                            + (failErr != null && !failErr.isEmpty() ? ": " + failErr : "");
                }
            }
        }
        writeReport(reportDir);
    }

    public static void writeReport(String reportDir) {
        try {
            Map<String, Object> report = new LinkedHashMap<>();
            report.put("generatedAt", Instant.now().toString());
            report.put("environment", getConfig("karate.env", "dev"));
            report.put("brainDir", resolveBrainDir().toString());
            report.put("totalHealedFields", HEALING_LOG.size());
            report.put("writeExcelEnabled", isWriteExcelEnabled());
            List<Map<String, Object>> records = new ArrayList<>();
            for (HealingRecord r : HEALING_LOG) records.add(r.toMap());
            report.put("healingDecisions", records);

            String prettyJson = new com.fasterxml.jackson.databind.ObjectMapper()
                    .writerWithDefaultPrettyPrinter()
                    .writeValueAsString(report);
            String textSummary = buildTextReport();

            List<Path> targetDirs = new ArrayList<>();
            targetDirs.add(Paths.get(reportDir));
            Path brainReports = resolveBrainReportsDir();
            if (brainReports != null && !brainReports.toAbsolutePath().normalize().equals(Paths.get(reportDir).toAbsolutePath().normalize())) {
                targetDirs.add(brainReports);
            }

            for (Path dir : targetDirs) {
                Files.createDirectories(dir);
                Files.writeString(dir.resolve(REPORT_FILENAME), prettyJson, StandardCharsets.UTF_8);
                Files.writeString(dir.resolve(TEXT_REPORT_FILENAME), textSummary, StandardCharsets.UTF_8);
            }
        } catch (Exception e) {
            System.err.println("[CbsConfigSelfHealingAgent] Could not write healing report: " + e.getMessage());
        }
    }

    private static String buildTextReport() {
        StringBuilder sb = new StringBuilder();
        sb.append("================================================================================\n");
        sb.append("AUTONOMOUS QA AGENT — SELF-HEALING ROOT CAUSE & RESOLUTION REPORT\n");
        sb.append("================================================================================\n");
        sb.append("Generated At  : ").append(Instant.now()).append("\n");
        sb.append("Environment   : ").append(getConfig("karate.env", "dev").toUpperCase()).append("\n");
        sb.append("Excel Rewrite : ").append(isWriteExcelEnabled()).append("\n");
        sb.append("Brain Dir     : ").append(resolveBrainDir()).append("\n");
        sb.append("Healed Fields : ").append(HEALING_LOG.size()).append("\n");
        sb.append("--------------------------------------------------------------------------------\n");
        if (HEALING_LOG.isEmpty()) {
            sb.append("No configuration drift detected; all Excel rows already match live CBS config.\n");
        } else {
            int i = 1;
            for (HealingRecord r : HEALING_LOG) {
                sb.append(String.format("[%d] Test Case : %s | Sub-Product: %s%n", i++, r.testCaseId, r.productCode));
                sb.append("    1) First-Time Failure Error : ").append(r.firstTimeFailureReason).append("\n");
                sb.append("    2) Rewrite Applied          : ").append(r.rewriteSummary).append("\n");
                sb.append("    3) Final Resolution         : ").append(r.resolutionStatus).append("\n\n");
            }
        }
        sb.append("================================================================================\n");
        return sb.toString();
    }

    public static void printSummary() {
        System.out.println("=======================================================");
        System.out.println("[CbsConfigSelfHealingAgent] Summary: " + HEALING_LOG.size() + " field(s) auto-healed");
        for (HealingRecord r : HEALING_LOG) {
            System.out.printf("  • [%s | %s] %s: %s -> %s%n",
                    r.testCaseId, r.productCode, r.field, r.oldValue, r.newValue);
            System.out.printf("      First-Time Failure : %s%n", r.firstTimeFailureReason);
            System.out.printf("      Resolution Status  : %s%n", r.resolutionStatus);
        }
        System.out.println("=======================================================");
    }

    public static List<HealingRecord> getHealingLog() {
        return Collections.unmodifiableList(HEALING_LOG);
    }

    public static void clearHealingLog() {
        HEALING_LOG.clear();
    }

    // =========================================================================
    // HELPERS
    // =========================================================================

    private static void recordHealing(
            String filePath, String tcId, String productCode, String field,
            Object oldVal, Object newVal, String thought, String action) {
        String workbook = filePath == null ? "Excel" : new File(filePath).getName();
        HealingRecord rec = new HealingRecord();
        rec.filePath = filePath;
        rec.workbookName = workbook;
        rec.testCaseId = tcId;
        rec.productCode = productCode;
        rec.field = field;
        rec.oldValue = oldVal;
        rec.newValue = newVal;
        rec.thought = thought;
        rec.action = action;
        rec.firstTimeFailureReason = buildFirstTimeFailureReason(productCode, field, oldVal, thought, action);
        rec.rewriteSummary = String.format("Rewritten %s from '%s' to '%s' in %s per CBS sub-product %s configuration.",
                field, oldVal, newVal, workbook, productCode.isEmpty() ? "DEFAULT" : productCode);
        rec.timestamp = Instant.now().toString();
        HEALING_LOG.add(rec);

        System.out.printf("[CbsConfigSelfHealingAgent] THOUGHT: %s | ACTION: %s (%s: %s -> %s)%n",
                thought, action, field, oldVal, newVal);
    }

    private static String buildFirstTimeFailureReason(
            String productCode, String field, Object oldVal, String thought, String action) {
        String prod = productCode == null || productCode.isEmpty() ? "active CBS product" : "CBS sub-product " + productCode;
        return switch (action) {
            case "HEAL_LOAN_AMOUNT", "SYNC_TOTAL_AMOUNT", "SYNC_APPROVAL_LIMIT" ->
                    "First-time run would fail validation for " + prod + " because Excel " + field + "=" + oldVal
                            + " violates updated amount/limit rules: " + thought;
            case "HEAL_TENURE" ->
                    "First-time run would fail tenure validation for " + prod + " because Excel " + field + "=" + oldVal
                            + " violates updated min/max tenure bounds: " + thought;
            case "HEAL_INTEREST_TYPE" ->
                    "First-time schedule/draft step would fail for " + prod + " because rate type '" + oldVal
                            + "' has no configured default rateId in CBS: " + thought;
            case "SHIFT_LOAN_START_DATE", "SHIFT_DISBURSEMENT_DATE", "SHIFT_REPAYMENT_START_DATE" ->
                    "First-time schedule/origination step fails for " + prod + " because Excel " + field + "='" + oldVal
                            + "' violates CBS business-date / working-day rules: " + thought;
            case "CLEAR_DISABLED_PEP", "CLEAR_DISABLED_BALLOON" ->
                    "First-time schedule/draft save fails for " + prod + " because Excel " + field + "='" + oldVal
                            + "' sends a repayment option that is now disabled in CBS: " + thought;
            default -> "First-time validation failure for " + prod + ": " + thought;
        };
    }

    private static boolean isNegativeRow(Map<String, Object> row) {
        String tcId = str(row.get("testCaseId")).toUpperCase();
        return !str(row.get("expectedStatus")).isEmpty()
                || !str(row.get("expectedError")).isEmpty()
                || !str(row.get("scheduleOverride")).isEmpty()
                || !str(row.get("createAccountOverride")).isEmpty()
                || tcId.contains("-NEG-");
    }

    private static String str(Object o) {
        return o == null ? "" : o.toString().trim();
    }

    private static Double toDouble(Object o) {
        if (o == null) return null;
        if (o instanceof Number n) return n.doubleValue();
        try {
            String s = o.toString().trim().replace(",", "");
            return s.isEmpty() ? null : Double.parseDouble(s);
        } catch (NumberFormatException e) {
            return null;
        }
    }

    private static Double firstNonNullDouble(Object... vals) {
        for (Object v : vals) {
            Double d = toDouble(v);
            if (d != null) return d;
        }
        return null;
    }

    private static LocalDate parseDate(String s) {
        if (s == null || s.isEmpty()) return null;
        try {
            return LocalDate.parse(s.length() >= 10 ? s.substring(0, 10) : s);
        } catch (Exception e) {
            return null;
        }
    }

    private static boolean isWeekend(LocalDate d) {
        return d.getDayOfWeek() == DayOfWeek.SATURDAY || d.getDayOfWeek() == DayOfWeek.SUNDAY;
    }

    private static LocalDate nextBusinessDay(LocalDate d) {
        LocalDate cur = d;
        while (isWeekend(cur)) cur = cur.plusDays(1);
        return cur;
    }
}
