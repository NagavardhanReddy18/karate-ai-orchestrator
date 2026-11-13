import com.ird.beyond.lo.test.util.CbsConfigSelfHealingAgent;
import com.ird.beyond.lo.test.util.ExcelDataLoader;

import java.nio.file.Path;
import java.nio.file.Paths;
import java.time.LocalDate;
import java.util.*;

/**
 * Offline self-healing simulation tool inside brain/tools.
 * Simulates CBS product configuration drift against Retail-Excel-Automation.xlsx
 * without requiring an active server connection.
 */
public class VerifyCbsAgent {
    public static void main(String[] args) throws Exception {
        Path root = Paths.get(System.getProperty("user.dir")).toAbsolutePath();
        String excelPath = args.length > 0
                ? args[0]
                : root.resolve("src/test/resources/features/loans/testdata/Retail-Excel-Automation.xlsx").toString();

        System.setProperty("karate.agent.heal", "false");
        List<Map<String, Object>> rows = ExcelDataLoader.load(excelPath);

        CbsConfigSelfHealingAgent.LiveCbsState simulatedCbs = new CbsConfigSelfHealingAgent.LiveCbsState();
        simulatedCbs.baseUrl = "http://simulated-cbs-drift";
        simulatedCbs.businessDate = LocalDate.now();

        for (String code : List.of("PL001DEFAULTUSD", "PL002DEFAULTUSD", "PL003DEFAULTUSD", "05040DEFAULTUSD")) {
            Map<String, Object> prod = new LinkedHashMap<>();
            prod.put("productCode", code);
            prod.put("minLoanAmount", 5000000L);
            prod.put("maxLoanAmount", 20000000L);
            prod.put("minTenure", 6);
            prod.put("maxTenure", 36);
            prod.put("defaultFloatingRateId", "FLT-CBS-2026");
            prod.put("pepApplicable", false);
            simulatedCbs.products.put(code, prod);
        }

        CbsConfigSelfHealingAgent.clearHealingLog();
        CbsConfigSelfHealingAgent.healRows(excelPath, rows, simulatedCbs, false);
        CbsConfigSelfHealingAgent.printSummary();
        System.out.println("VERIFIED: Healed records count = " + CbsConfigSelfHealingAgent.getHealingLog().size());
    }
}
