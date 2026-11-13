package com.ird.beyond.lo.test.util;

import java.io.BufferedReader;
import java.io.IOException;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.Hashtable;
import java.util.List;
import java.util.Map;
import java.util.Properties;
import java.util.concurrent.ConcurrentHashMap;

/**
 * PersistentVars
 * --------------
 * Named values captured during a run, so a later step — or a later column — can
 * use something an earlier one produced.
 *
 * The storing behaviour is carried over unchanged from the older automation
 * framework, deliberately, so sheets and habits move across as they are:
 *
 * <ul>
 *   <li>a name starts with {@code @}, as in {@code @AppId}</li>
 *   <li>{@link #load()} seeds the globals from a variables file, when one exists</li>
 *   <li>{@link #initTestContext()} gives each row its own copy of the globals, so
 *       one row can never see what another row stored</li>
 *   <li>{@link #substituteVariables(String)} replaces every known name inside a
 *       string, longest name first so {@code @Acc} can never eat {@code @AccountNo}</li>
 *   <li>{@link #captureFinalState(String)} keeps the row's closing values for the report</li>
 * </ul>
 *
 * Reads fall back to the globals when no row context is active, which is what
 * makes the same helper usable from a Background section.
 */
public final class PersistentVars {

    /** Seeded once per run from the variables file; visible to every row. */
    private static final Hashtable<String, String> globalVariables = new Hashtable<>();

    /** Per-row values. A row starts from a copy of the globals and diverges from there. */
    private static final ThreadLocal<Map<String, String>> localVars = new ThreadLocal<>();

    /** Closing values of every row that has finished, keyed by test case id. */
    private static final Map<String, Map<String, String>> testExecutionRecords = new ConcurrentHashMap<>();

    private static boolean loaded = false;

    private PersistentVars() {
    }

    // -------------------------------------------------------------- lifecycle

    /**
     * Path of the optional variables file: {@code -Dvariables.file=...}, else
     * {@code variables.dat} beside the test resources.
     */
    private static Path variablesFile() {
        String configured = System.getProperty("variables.file");
        if (configured != null && !configured.trim().isEmpty()) {
            return Paths.get(configured.trim());
        }
        return Paths.get("src", "test", "resources", "variables.dat");
    }

    /**
     * Seed the globals from the variables file. Missing file is not an error —
     * most runs start with nothing stored and fill up as they go.
     */
    public static synchronized void load() {
        loaded = true;
        globalVariables.clear();

        Path file = variablesFile();
        if (Files.notExists(file)) {
            return;
        }

        Properties p = new Properties();
        try (BufferedReader reader = Files.newBufferedReader(file)) {
            p.load(reader);
        } catch (IOException e) {
            System.out.println("[PersistentVars] Problem reading variables file " + file + ": " + e.getMessage());
            return;
        }

        for (String name : p.stringPropertyNames()) {
            globalVariables.put(name, p.getProperty(name));
        }
        System.out.println("[PersistentVars] Loaded " + globalVariables.size() + " global variable(s) from " + file);
    }

    /** Start a row with its own copy of the globals. Loads the globals on first use. */
    public static void initTestContext() {
        if (!loaded) {
            load();
        }
        localVars.set(new HashMap<>(globalVariables));
    }

    /**
     * Keep the row's closing values under {@code testId} and end the row context.
     * Nothing a row stored survives into the next one.
     */
    public static void captureFinalState(String testId) {
        Map<String, String> vars = localVars.get();
        if (vars != null && testId != null) {
            testExecutionRecords.put(testId, new HashMap<>(vars));
        }
        localVars.remove();
    }

    // ------------------------------------------------------------------ access

    public static void put(String key, String value) {
        if (key == null || key.trim().isEmpty()) {
            return;
        }
        Map<String, String> vars = localVars.get();
        if (vars == null) {
            initTestContext();
            vars = localVars.get();
        }
        vars.put(key.trim(), value);
    }

    public static String get(String key) {
        if (key == null) {
            return null;
        }
        Map<String, String> vars = localVars.get();
        return vars != null ? vars.get(key.trim()) : globalVariables.get(key.trim());
    }

    public static boolean isDefined(String key) {
        return get(key) != null;
    }

    public static void remove(String key) {
        Map<String, String> vars = localVars.get();
        if (vars != null && key != null) {
            vars.remove(key.trim());
        }
    }

    /** Everything visible to the current row, globals included. */
    public static Map<String, String> getVariables() {
        Map<String, String> vars = localVars.get();
        return vars != null ? new HashMap<>(vars) : new HashMap<>(globalVariables);
    }

    /** Only what this row stored or changed — what the globals did not already say. */
    public static Map<String, String> getSessionData() {
        Map<String, String> local = localVars.get();
        if (local == null) {
            return new HashMap<>();
        }
        Map<String, String> sessionData = new HashMap<>();
        for (Map.Entry<String, String> entry : local.entrySet()) {
            String globalValue = globalVariables.get(entry.getKey());
            if (globalValue == null || !globalValue.equals(entry.getValue())) {
                sessionData.put(entry.getKey(), entry.getValue());
            }
        }
        return sessionData;
    }

    public static Map<String, Map<String, String>> getAllTestRecords() {
        return testExecutionRecords;
    }

    // ------------------------------------------------------------ substitution

    /**
     * Replace every stored name appearing in {@code input} with its value.
     *
     * Names are applied longest first. Without that ordering a short name is
     * able to consume the opening characters of a longer one that shares its
     * prefix — {@code @Acc} rewriting the front of {@code @AccountNo} — and the
     * remaining text is silently corrupted.
     *
     * An unknown name is left exactly as written, so a typo shows up in the
     * failure message instead of turning into an empty string.
     */
    public static String substituteVariables(String input) {
        if (input == null || input.isEmpty()) {
            return input;
        }

        Map<String, String> vars = localVars.get();
        if (vars == null) {
            vars = globalVariables;
        }

        List<String> keysLongestFirst = new ArrayList<>(vars.keySet());
        keysLongestFirst.sort((a, b) -> Integer.compare(b.length(), a.length()));

        String result = input;
        for (String key : keysLongestFirst) {
            String value = vars.get(key);
            if (value != null) {
                result = result.replace(key, value);
            }
        }
        return result;
    }

    /** Spelling used by the older framework, kept so ported logic still compiles. */
    public static String substitueVariables(String input) {
        return substituteVariables(input);
    }
}
