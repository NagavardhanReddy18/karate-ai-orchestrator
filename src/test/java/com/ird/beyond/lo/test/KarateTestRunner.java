package com.ird.beyond.lo.test;

import com.intuit.karate.junit5.Karate;
import com.ird.beyond.lo.test.util.CbsConfigSelfHealingAgent;
import com.ird.beyond.lo.test.util.KarateExcelReporter;
import org.junit.jupiter.api.AfterAll;
import org.yaml.snakeyaml.Yaml;

import java.io.InputStream;
import java.util.*;

/**
 * Entry point for executing Karate API test suites within the Beyond LO automation suite.
 * Integrated with Jenkins CI/CD post-deployment pipelines (`Jenkinsfile.dev` & `Jenkinsfile.test`).
 *
 * Feature Execution Resolution:
 *   1. Command-Line Override:    -Dkarate.features="01, 05" or -Dkarate.features="config, enterprise"
 *   2. YAML Configuration:       src/test/resources/application.yml (environment-specific or default)
 *   3. Default Fallback:         04, 05, 06, 07 lifecycle features
 *
 * Execution Modes:
 *   - Default Jenkins Execution: Reads features configured for the environment and filters by @data-driven.
 *   - Tag-Based Execution:       mvn test -Dkarate.env=dev -Dkarate.tags="@data-driven"
 *   - Suite Profile Execution:   mvn test -Psmoke -Dkarate.env=dev (-Psmoke / -Pregression)
 *   - Feature Path Execution:    mvn test -Dkarate.options="classpath:features/loans/04-BLO-LifeCycle.feature"
 */
class KarateTestRunner {

    // Feature Catalog Mapping (supports short aliases, numbers, and file names)
    private static final Map<String, String> FEATURE_CATALOG = new LinkedHashMap<>() {{
        put("00", "classpath:features/loans/00-Setup-Cbs-Sync.feature");
        put("cbs", "classpath:features/loans/00-Setup-Cbs-Sync.feature");
        put("01", "classpath:features/loans/01-Setup-Configurations.feature");
        put("config", "classpath:features/loans/01-Setup-Configurations.feature");
        put("02", "classpath:features/loans/02-Setup-Approval-Limits.feature");
        put("limits", "classpath:features/loans/02-Setup-Approval-Limits.feature");
        put("03", "classpath:features/loans/03-Setup-Document-Checklists.feature");
        put("checklists", "classpath:features/loans/03-Setup-Document-Checklists.feature");
        put("03a", "classpath:features/loans/03A-Setup-Incident-Charges.feature");
        put("charges", "classpath:features/loans/03A-Setup-Incident-Charges.feature");
        put("03b", "classpath:features/loans/03B-Setup-Notifications.feature");
        put("notifications", "classpath:features/loans/03B-Setup-Notifications.feature");
        put("04", "classpath:features/loans/04-BLO-LifeCycle.feature");
        put("retail", "classpath:features/loans/04-BLO-LifeCycle.feature");
        put("05", "classpath:features/loans/05-BLO-Enterprise-LifeCycle.feature");
        put("enterprise", "classpath:features/loans/05-BLO-Enterprise-LifeCycle.feature");
        put("06", "classpath:features/loans/06-BLO-Overdraft-LifeCycle.feature");
        put("overdraft", "classpath:features/loans/06-BLO-Overdraft-LifeCycle.feature");
        put("rod", "classpath:features/loans/06-BLO-Overdraft-LifeCycle.feature");
        put("07", "classpath:features/loans/07-BLO-Enterprise-Overdraft-LifeCycle.feature");
        put("eod", "classpath:features/loans/07-BLO-Enterprise-Overdraft-LifeCycle.feature");
        put("08", "classpath:features/loans/08-BLO-SendBack-and-Rejection.feature");
        put("sendback", "classpath:features/loans/08-BLO-SendBack-and-Rejection.feature");
        put("09", "classpath:features/loans/09-customer-lookup.feature");
        put("10", "classpath:features/loans/10-list-and-search.feature");
        put("15", "classpath:features/loans/15-application-lifecycle.feature");
        put("16", "classpath:features/loans/16-CRUD-Configurations.feature");
        put("17", "classpath:features/loans/17-Setup-All-Configurations.feature");
        put("18", "classpath:features/loans/18-BLO-Channel-Personal-Overdraft.feature");
        put("cpod", "classpath:features/loans/18-BLO-Channel-Personal-Overdraft.feature");
        put("channel-pod", "classpath:features/loans/18-BLO-Channel-Personal-Overdraft.feature");
        put("19", "classpath:features/loans/19-BLO-Channel-Enterprise-Overdraft.feature");
        put("ceod", "classpath:features/loans/19-BLO-Channel-Enterprise-Overdraft.feature");
        put("channel-eod", "classpath:features/loans/19-BLO-Channel-Enterprise-Overdraft.feature");
        put("20", "classpath:features/loans/20-BLO-User-DateFormat-CrossRole-Lifecycle.feature");
        put("date-format", "classpath:features/loans/20-BLO-User-DateFormat-CrossRole-Lifecycle.feature");
    }};

    @Karate.Test
    Karate testAll() {
        String env = CbsConfigSelfHealingAgent.getConfig("karate.env", "dev").toLowerCase();
        System.setProperty("karate.env", env);
        String explicitUrl = CbsConfigSelfHealingAgent.getConfig("lo.test.baseUrl", "");
        if (!explicitUrl.isEmpty() && System.getProperty("lo.test.baseUrl") == null) {
            System.setProperty("lo.test.baseUrl", explicitUrl);
        }
        String tags = System.getProperty("karate.tags");
        String options = System.getProperty("karate.options");
        String cliFeatures = CbsConfigSelfHealingAgent.getConfig("karate.features", "");

        // 1. Resolve ordered feature list dynamically (CLI -> application.yml -> Default)
        List<String> featurePaths = resolveFeatureList(cliFeatures, env);

        System.out.println("=======================================================");
        System.out.println("[KarateTestRunner] Target Environment : " + env.toUpperCase());
        System.out.println("[KarateTestRunner] Executing Features In Order (" + featurePaths.size() + "):");
        for (int i = 0; i < featurePaths.size(); i++) {
            System.out.println("  " + (i + 1) + ". " + featurePaths.get(i));
        }
        System.out.println("=======================================================");

        // 2. Resolve tags if specified (e.g. Jenkins passes -Dkarate.tags="@data-driven")
        String tagToUse = null;
        if (tags != null && !tags.trim().isEmpty()) {
            tagToUse = tags.trim();
        } else if (options != null && !options.trim().isEmpty() && (options.startsWith("@") || options.startsWith("--tags"))) {
            tagToUse = options.trim();
        }

        if (tagToUse != null) {
            if (tagToUse.startsWith("--tags")) {
                tagToUse = tagToUse.replace("--tags", "").trim();
            }
            // CRITICAL: Clear 'karate.options' so Karate doesn't misinterpret tags as a file path
            System.clearProperty("karate.options");
            return Karate.run(featurePaths.toArray(new String[0]))
                    .tags(tagToUse)
                    .relativeTo(getClass());
        }

        // 3. Fallback for explicit -Dkarate.options feature path
        if (options != null && !options.trim().isEmpty()) {
            return Karate.run(options.trim()).relativeTo(getClass());
        }

        // 4. Default: run the dynamically resolved feature list
        return Karate.run(featurePaths.toArray(new String[0])).relativeTo(getClass());
    }

    /**
     * Resolves the list of feature classpath URLs from CLI, application.yml, or defaults.
     */
    @SuppressWarnings("unchecked")
    private static List<String> resolveFeatureList(String cliFeatures, String env) {
        List<String> rawNames = new ArrayList<>();

        // Priority 1: Command line property -Dkarate.features="config, enterprise"
        if (cliFeatures != null && !cliFeatures.trim().isEmpty()) {
            for (String f : cliFeatures.split(",")) {
                if (!f.trim().isEmpty()) rawNames.add(f.trim());
            }
        }

        // Priority 2: KArateapplication.yml
        if (rawNames.isEmpty()) {
            InputStream in = null;
            String[] candidateFiles = {"KArateapplication.yml", "karateapplication.yml", "application.yml"};
            for (String cFile : candidateFiles) {
                in = KarateTestRunner.class.getClassLoader().getResourceAsStream(cFile);
                if (in != null) break;
            }
            if (in != null) {
                try (InputStream yamlStream = in) {
                    Map<String, Object> yamlData = new Yaml().load(yamlStream);
                    if (yamlData != null && yamlData.containsKey("karate")) {
                        Map<String, Object> karateCfg = (Map<String, Object>) yamlData.get("karate");

                        // Check environment-specific list first (e.g. karate.environments.dev.features)
                        if (karateCfg.containsKey("environments")) {
                            Map<String, Object> envs = (Map<String, Object>) karateCfg.get("environments");
                            if (envs != null && envs.containsKey(env)) {
                                Map<String, Object> envCfg = (Map<String, Object>) envs.get(env);
                                if (envCfg != null && envCfg.containsKey("features")) {
                                    rawNames.addAll((List<String>) envCfg.get("features"));
                                }
                            }
                        }

                        // Fall back to default karate.features list
                        if (rawNames.isEmpty() && karateCfg.containsKey("features")) {
                            rawNames.addAll((List<String>) karateCfg.get("features"));
                        }
                    }
                } catch (Exception e) {
                    System.err.println("[KarateTestRunner] Warning: Could not read KArateapplication.yml: " + e.getMessage());
                }
            }
        }

        // Priority 3: Fallback default (04, 05, 06, 07)
        if (rawNames.isEmpty()) {
            rawNames = Arrays.asList("04", "05", "06", "07");
        }

        // Map names to full classpath paths preserving user order
        List<String> resolvedPaths = new ArrayList<>();
        for (String raw : rawNames) {
            String path = toClasspathPath(raw.trim());
            if (path != null && !resolvedPaths.contains(path)) {
                resolvedPaths.add(path);
            }
        }
        return resolvedPaths;
    }

    private static String toClasspathPath(String name) {
        if (name.startsWith("classpath:")) return name;
        if (name.endsWith(".feature")) {
            if (name.contains("/")) return "classpath:" + name;
            return "classpath:features/loans/" + name;
        }
        String key = name.toLowerCase();
        if (FEATURE_CATALOG.containsKey(key)) {
            return FEATURE_CATALOG.get(key);
        }
        for (Map.Entry<String, String> entry : FEATURE_CATALOG.entrySet()) {
            if (entry.getValue().toLowerCase().contains(key)) {
                return entry.getValue();
            }
        }
        return "classpath:features/loans/" + name + ".feature";
    }

    @AfterAll
    static void generateExcelReport() {
        try {
            System.out.println("[KarateTestRunner] Generating Excel Test Report & Summaries...");
            KarateExcelReporter.generateReport("target/karate-reports");
            CbsConfigSelfHealingAgent.printSummary();
        } catch (Exception e) {
            System.err.println("[KarateTestRunner] Error generating Excel report: " + e.getMessage());
            e.printStackTrace();
        }
    }
}
