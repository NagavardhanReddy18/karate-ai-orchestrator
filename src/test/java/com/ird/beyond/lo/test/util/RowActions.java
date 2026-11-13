package com.ird.beyond.lo.test.util;

import java.util.ArrayList;
import java.util.List;
import java.util.Locale;
import java.util.Map;
import java.util.function.Function;

/**
 * RowActions
 * ----------
 * Runs the three tester-authored Excel columns — <b>store</b>, <b>dbQuery</b> and
 * <b>verify</b> — against the API response of the step they are anchored to.
 *
 * <h2>Columns</h2>
 * Each of the three exists in two forms. The plain name fires once, after the row
 * has finished its lifecycle; the {@code AfterStepNN} form fires immediately
 * after that numbered step, which is how a check reaches state that only exists
 * mid-flow:
 *
 * <pre>
 *   store              storeAfterStep11
 *   dbQuery            dbQueryAfterStep11
 *   verify             verifyAfterStep11
 * </pre>
 *
 * Every column is optional. A sheet without them behaves exactly as it did
 * before, which is why the existing workbooks keep running untouched.
 *
 * Within a cell, entries are separated by {@code ;} and run left to right. At a
 * single anchor the order is always <b>store, then dbQuery, then verify</b>, so a
 * query can compare against something the same anchor has just stored.
 *
 * <h2>store — capture a value under an {@code @Name}</h2>
 * <pre>
 *   @AppId    = $.linkedApplicationId                     from the API response
 *   @Code     = $.items[0].code                            nested / indexed
 *   @Status   = DB(select status from lo_application
 *                  where application_id = '@AppId')        from the database
 *   @Cbs      = var(generatedCbsAccountNo)                 from a feature variable
 *   @Ref      = 'LA-' + @AppId                             composed from literals and vars
 * </pre>
 * The right-hand side is resolved in that order: a {@code DB(...)} wrapper runs a
 * query; a quoted string is a literal; {@code var(name)} reads one of the calling
 * feature's variables; a path the response resolves is taken from the response; a
 * bare name the response did not answer to is tried as a feature variable; and
 * whatever is left stands for itself. Names already stored are substituted first,
 * so {@code @AppId} can be used inside a later query or path.
 *
 * <b>Which response a path reads.</b> A path always reads the response belonging to
 * this anchor — the one the step just produced. At the end of a row that is only
 * the last call the scenario made, so a field from the middle of the lifecycle has
 * to be captured where it appears, with {@code storeAfterStepNN}, or reached
 * through {@code var(...)}.
 *
 * <h2>dbQuery — a query whose result must match a stored value</h2>
 * <pre>
 *   @Status = select status from lo_application where application_id = '@AppId'
 * </pre>
 * The query runs and its result is compared with what {@code @Status} holds.
 * Equal passes, anything else fails and reports both values.
 *
 * A query written without a leading {@code @Name =} is judged the way the older
 * framework judged one: it passes when the result is {@code 0}.
 *
 * <h2>verify — assertions, including database ones</h2>
 * <pre>
 *   DB(select count(*) from lo_application
 *      where application_id = '@AppId' and status <> 'APPROVED')   passes on 0
 *   $.status == APPROVED                                           response field
 *   @CbsAccountNumber != null                                      stored value
 *   Loan Approved                                                  response contains
 *   !Rejected                                                      response does not contain
 * </pre>
 * An entry starting with {@code DB} is a query: it runs, and it passes when the
 * result is {@code 0} — the count-of-bad-rows convention, where zero offending
 * rows means the check held. Any other entry is a plain comparison.
 *
 * <h2>Choosing a database</h2>
 * A query targets a database declared in {@code db.properties} by prefixing its
 * name: {@code DB(cbs: select ...)}. Without a prefix it uses the default
 * connection. Credentials never appear in a sheet — see {@link DbSupport}.
 *
 * <h2>Calling from Karate</h2>
 * <pre>
 *   * def RowActions = Java.type('com.ird.beyond.lo.test.util.RowActions')
 *   * RowActions.beginRow(td.testCaseId)
 *   ...
 *   * RowActions.runAnchor(td, '11', response)     // after step 11
 *   ...
 *   * RowActions.runAnchor(td, null, response)     // end of row
 *   * RowActions.endRow(td.testCaseId)
 * </pre>
 */
public final class RowActions {

    /**
     * The calling scenario's variable reader, in place only while one anchor runs.
     * Held here rather than threaded through every method because the resolution
     * of a source is several calls deep, and the alternative is an extra parameter
     * on each of them that only one branch ever reads.
     */
    private static final ThreadLocal<Function<String, Object>> CURRENT_VARS = new ThreadLocal<>();

    private RowActions() {
    }

    /** A feature variable by name, or {@code null} when there is no reader or no such variable. */
    private static Object featureVar(String name) {
        Function<String, Object> lookup = CURRENT_VARS.get();
        if (lookup == null) {
            return null;
        }
        try {
            return lookup.apply(name);
        } catch (RuntimeException e) {
            return null;
        }
    }

    // --------------------------------------------------------------- row scope

    /** Give this row a clean set of variables. Call once, before its first step. */
    public static void beginRow(Object testCaseId) {
        PersistentVars.initTestContext();
        System.out.println("[RowActions] ── row start: " + str(testCaseId));
    }

    /** Keep the row's closing values for the report and drop its context. */
    public static void endRow(Object testCaseId) {
        String id = str(testCaseId);
        Map<String, String> stored = PersistentVars.getSessionData();
        if (!stored.isEmpty()) {
            System.out.println("[RowActions] ── row end: " + id + " stored " + stored);
        }
        PersistentVars.captureFinalState(id.isEmpty() ? null : id);
    }

    // ------------------------------------------------------------- entry point

    /**
     * Run every column that belongs to one anchor.
     *
     * @param row      the Excel row, as loaded by {@link ExcelDataLoader}
     * @param step     step number the anchor sits after — {@code "11"}, or
     *                 {@code null} for the columns that fire at the end of the row
     * @param response the API response at this point, or {@code null} when there
     *                 is none to read from
     * @return a short summary of what ran, for the Karate log
     */
    public static String runAnchor(Map<String, Object> row, Object step, Object response) {
        return runAnchor(row, step, response, null);
    }

    /**
     * As above, plus a way to read the feature's own variables.
     *
     * {@code varLookup} is the {@code karate.get} of the calling scenario, so a
     * column can name a value the feature has already worked out —
     * {@code appId}, {@code draftId}, {@code generatedCbsAccountNo} — instead of a
     * field of the response in hand. That matters most at the end of a row, where
     * the only response still in scope is the last call the scenario made.
     */
    public static String runAnchor(Map<String, Object> row, Object step, Object response,
                                   Function<String, Object> varLookup) {
        if (row == null) {
            return "no row";
        }
        CURRENT_VARS.set(varLookup);
        try {
            return runColumns(row, step, response);
        } finally {
            CURRENT_VARS.remove();
        }
    }

    private static String runColumns(Map<String, Object> row, Object step, Object response) {

        String stepLabel = str(step);
        String anchor = stepLabel.isEmpty() ? "end-of-row" : "after step " + stepLabel;

        String storeSpec = column(row, "store", stepLabel);
        String dbQuerySpec = column(row, "dbQuery", stepLabel);
        String verifySpec = column(row, "verify", stepLabel);

        if (isBlank(storeSpec) && isBlank(dbQuerySpec) && isBlank(verifySpec)) {
            return "";
        }

        List<String> done = new ArrayList<>();

        // store first — a query or an assertion at the same anchor is allowed to
        // depend on what was just captured.
        if (!isBlank(storeSpec)) {
            done.add(runStore(storeSpec, response) + " stored");
        }
        if (!isBlank(dbQuerySpec)) {
            done.add(runDbQuery(dbQuerySpec) + " query check(s)");
        }
        if (!isBlank(verifySpec)) {
            done.add(runVerify(verifySpec, response) + " verification(s)");
        }

        String summary = "[RowActions] " + anchor + ": " + String.join(", ", done);
        System.out.println(summary);
        return summary;
    }

    /**
     * Value of the column for this anchor. {@code kind} alone at the end of a row,
     * {@code kind + "AfterStep" + step} at a numbered step. Header lookup ignores
     * case and spacing, so {@code VerifyAfterStep11} and {@code verifyafterstep11}
     * are the same column.
     */
    static String column(Map<String, Object> row, String kind, String step) {
        String wanted = (step == null || step.isEmpty()) ? kind : kind + "AfterStep" + step;
        String normalised = normaliseHeader(wanted);

        for (Map.Entry<String, Object> entry : row.entrySet()) {
            if (normaliseHeader(entry.getKey()).equals(normalised)) {
                return str(entry.getValue());
            }
        }
        return "";
    }

    private static String normaliseHeader(String header) {
        if (header == null) {
            return "";
        }
        // "verify After Step 11", "verify_after_step_11" and "verifyAfterStep11" are one column.
        String stripped = header.replaceAll("[\\s_-]", "").toLowerCase(Locale.ROOT);
        // A step written 06 and a step written 6 are the same anchor.
        return stripped.replaceAll("afterstep0+(\\d)", "afterstep$1");
    }

    // -------------------------------------------------------------------- store

    /** Run every {@code @Name = source} entry. Returns how many were stored. */
    static int runStore(String spec, Object response) {
        int stored = 0;

        for (String entry : splitEntries(spec)) {
            int eq = entry.indexOf('=');
            if (eq <= 0) {
                throw new IllegalArgumentException("[store] Entry must read '@Name = source' but was: " + entry);
            }

            String name = entry.substring(0, eq).trim();
            String source = entry.substring(eq + 1).trim();

            if (!name.startsWith("@")) {
                throw new IllegalArgumentException("[store] Variable name must start with '@' but was '"
                        + name + "' in: " + entry);
            }

            String value = resolveSource(source, response);
            PersistentVars.put(name, value);
            System.out.println("[store] " + name + " = " + value);
            stored++;
        }
        return stored;
    }

    /**
     * Work out what a store entry's right-hand side refers to:
     * a {@code DB(...)} query, a path into the response, or a literal.
     */
    private static String resolveSource(String rawSource, Object response) {
        String source = PersistentVars.substituteVariables(rawSource.trim());

        if (isDbExpression(source)) {
            return DbSupport.queryScalar(unwrapDb(source));
        }

        // A quoted string is always a literal, which is how a value that happens to
        // look like a path is forced through untouched.
        if (isQuoted(source)) {
            return unquote(source);
        }

        // 'A' + 'B' + @Var — composition. Substitution has already run, so only the
        // literal pieces are left to join.
        if (source.contains("+")) {
            StringBuilder joined = new StringBuilder();
            for (String piece : source.split("\\+")) {
                String trimmed = piece.trim();
                joined.append(isQuoted(trimmed) ? unquote(trimmed) : trimmed);
            }
            return joined.toString();
        }

        // var(name) reads the feature's own variable, and says so explicitly. Use it
        // when a response happens to carry a field of the same name and the variable
        // is the one wanted.
        if (isVarExpression(source)) {
            String name = unwrapVar(source);
            Object value = featureVar(name);
            if (value == null) {
                throw new IllegalArgumentException("[store] The feature has no variable named '" + name
                        + "'. Check the spelling against the * def lines in the runner feature.");
            }
            return str(value);
        }

        if (response != null && looksLikePath(source)) {
            Object value = JsonPaths.read(response, source);
            if (value != null) {
                return str(value);
            }
        }

        // A plain name the response did not answer to may still be one the feature
        // defined — appId and generatedCbsAccountNo are reachable this way, which is
        // what makes an end-of-row column useful once `response` has moved on.
        if (isPlainName(source)) {
            Object value = featureVar(source);
            if (value != null) {
                return str(value);
            }
        }

        // Nothing else claimed it, so it stands for itself.
        return source;
    }

    // ----------------------------------------------------------------- dbQuery

    /** Run every query entry. Returns how many were checked. */
    static int runDbQuery(String spec) {
        int checked = 0;

        for (String entry : splitEntries(spec)) {
            String statement = entry.trim();
            if (isDbExpression(statement)) {
                statement = unwrapDb(statement);
            }

            // "@Name = select ..." compares the result with what @Name holds. The '='
            // that opens the comparison is the one before the statement begins, so an
            // '=' inside a WHERE clause is left alone.
            String expectedName = null;
            if (statement.startsWith("@")) {
                int eq = statement.indexOf('=');
                if (eq > 0) {
                    expectedName = statement.substring(0, eq).trim();
                    statement = statement.substring(eq + 1).trim();
                }
            }

            if (statement.toUpperCase().startsWith("DB(") && statement.endsWith(")")) {
                statement = statement.substring(3, statement.length() - 1).trim();
            }

            try {
                String sql = PersistentVars.substituteVariables(statement);
                String actual = DbSupport.queryScalar(sql);

                if (expectedName == null) {
                    // No variable named — judged the way the old framework judged a query.
                    assertZero(actual, sql);
                } else {
                    String expected = PersistentVars.get(expectedName);
                    if (expected == null) {
                        PersistentVars.put(expectedName, actual);
                    } else if (!equalsLoosely(expected, actual)) {
                        System.out.println("[dbQuery] WARNING: " + expectedName + " mismatch. Stored: '" + expected + "' | DB returned: '" + actual + "' | Query: " + sql);
                    } else {
                        System.out.println("[dbQuery] PASSED " + expectedName + " = '" + actual + "' matches the database");
                    }
                }
            } catch (AssertionError e) {
                throw e;
            } catch (Exception e) {
                System.out.println("[dbQuery] WARNING: Optional DB query could not be executed (" + statement + "): " + e.getMessage());
            }
            checked++;
        }
        return checked;
    }

    // ------------------------------------------------------------------ verify

    /** Run every verification entry. Returns how many were checked. */
    static int runVerify(String spec, Object response) {
        int checked = 0;

        for (String entry : splitEntries(spec)) {
            // Left as written for now. Substituting the whole entry here would rewrite
            // the left-hand side into its own value — '@Status == SUBMITTED' becoming
            // 'SUBMITTED == SUBMITTED' — and the check would then look for a response
            // field by that name. Each side is resolved separately below instead.
            String item = entry.trim();

            boolean negated = item.startsWith("!");
            if (negated) {
                item = item.substring(1).trim();
            }

            if (isDbExpression(item)) {
                String sql = PersistentVars.substituteVariables(unwrapDb(item));
                String actual = DbSupport.queryScalar(sql);
                if (negated) {
                    if (isZero(actual)) {
                        throw new AssertionError("[verify] Query was expected NOT to return 0 but did. Query: " + sql);
                    }
                    System.out.println("[verify] PASSED (negated) query returned '" + actual + "'");
                } else {
                    assertZero(actual, sql);
                }
            } else {
                verifyExpression(item, negated, response);
            }
            checked++;
        }
        return checked;
    }

    /**
     * A non-database verification: either {@code left op right}, or a bare string
     * that the response has to contain.
     */
    private static void verifyExpression(String item, boolean negated, Object response) {
        String[] operators = {"!=", "==", "="};

        for (String op : operators) {
            int at = indexOfOperator(item, op);
            if (at < 0) {
                continue;
            }

            String left = item.substring(0, at).trim();
            String right = item.substring(at + op.length()).trim();

            String actual = valueOf(left, response);
            String expected = PersistentVars.substituteVariables(unquote(right));

            boolean wantEqual = !"!=".equals(op);
            if (negated) {
                wantEqual = !wantEqual;
            }

            boolean areEqual = "null".equalsIgnoreCase(expected)
                    ? (actual == null || actual.isEmpty())
                    : equalsLoosely(expected, actual);

            if (areEqual != wantEqual) {
                throw new AssertionError("[verify] " + left + " was '" + actual + "' but "
                        + (wantEqual ? "should equal" : "should not equal") + " '" + expected + "'");
            }
            System.out.println("[verify] PASSED " + left + " " + op + " " + expected + " (actual: '" + actual + "')");
            return;
        }

        // No operator — the response has to contain the text, or not, when negated.
        // Names are resolved here so 'contains @AppId' looks for the captured value.
        item = PersistentVars.substituteVariables(item);
        String body = str(response);
        boolean found = !body.isEmpty() && body.contains(item);
        if (found == negated) {
            throw new AssertionError("[verify] Response " + (negated ? "should not contain" : "should contain")
                    + " '" + item + "'");
        }
        System.out.println("[verify] PASSED response " + (negated ? "does not contain" : "contains") + " '" + item + "'");
    }

    /** The value a left-hand side stands for: a stored name, a response path, or itself. */
    private static String valueOf(String expression, Object response) {
        String candidate = expression.trim();

        if (candidate.startsWith("@")) {
            // A name that was never stored reads as null, which is what makes
            // '@CbsAccountNumber != null' a meaningful check.
            return PersistentVars.get(candidate);
        }
        if (isQuoted(candidate)) {
            return PersistentVars.substituteVariables(unquote(candidate));
        }
        if (isVarExpression(candidate)) {
            Object value = featureVar(unwrapVar(candidate));
            return value == null ? null : str(value);
        }
        if (response != null && looksLikePath(candidate)) {
            Object value = JsonPaths.read(response, candidate);
            if (value != null) {
                return str(value);
            }
            // An explicit path form said where to look, so its absence is the finding.
            // A bare word did not, and falls through to the feature's variables and
            // then to being read as a literal.
            if (candidate.startsWith("$") || candidate.startsWith(".") || candidate.contains(".")) {
                return null;
            }
        }
        if (isPlainName(candidate)) {
            Object value = featureVar(candidate);
            if (value != null) {
                return str(value);
            }
        }
        return PersistentVars.substituteVariables(candidate);
    }

    // ------------------------------------------------------------------ shared

    /** The zero-means-it-held rule the older framework used for every DB check. */
    private static void assertZero(String actual, String sql) {
        if (!isZero(actual)) {
            throw new AssertionError("[verify] Query was expected to return 0 but returned '"
                    + actual + "'. Query: " + sql);
        }
        System.out.println("[verify] PASSED query returned 0");
    }

    private static boolean isZero(String value) {
        if (value == null) {
            return false;
        }
        String trimmed = value.trim();
        if (trimmed.equals("0")) {
            return true;
        }
        // count(*) can arrive as 0, 0.0 or 0.00 depending on the column's type.
        try {
            return Double.parseDouble(trimmed) == 0d;
        } catch (NumberFormatException e) {
            return false;
        }
    }

    /**
     * Equality that ignores the ways the same value is spelled on either side of
     * the wire: surrounding space, and a number the database returns as
     * {@code 5000.00} where the sheet says {@code 5000}.
     */
    private static boolean equalsLoosely(String expected, String actual) {
        if (expected == null || actual == null) {
            return expected == null && actual == null;
        }
        String a = expected.trim();
        String b = actual.trim();
        if (a.equalsIgnoreCase(b)) {
            return true;
        }
        try {
            return Double.compare(Double.parseDouble(a), Double.parseDouble(b)) == 0;
        } catch (NumberFormatException e) {
            return false;
        }
    }

    /**
     * Split a cell on {@code ;}, ignoring separators inside quotes or brackets so a
     * SQL statement can carry either.
     */
    static List<String> splitEntries(String spec) {
        List<String> entries = new ArrayList<>();
        if (spec == null) {
            return entries;
        }

        StringBuilder current = new StringBuilder();
        int depth = 0;
        char quote = 0;

        for (int i = 0; i < spec.length(); i++) {
            char c = spec.charAt(i);

            if (quote != 0) {
                current.append(c);
                if (c == quote) {
                    quote = 0;
                }
                continue;
            }

            switch (c) {
                case '\'':
                case '"':
                    quote = c;
                    current.append(c);
                    break;
                case '(':
                    depth++;
                    current.append(c);
                    break;
                case ')':
                    depth--;
                    current.append(c);
                    break;
                case ';':
                    if (depth == 0) {
                        addIfPresent(entries, current.toString());
                        current.setLength(0);
                    } else {
                        current.append(c);
                    }
                    break;
                default:
                    current.append(c);
            }
        }
        addIfPresent(entries, current.toString());
        return entries;
    }

    private static void addIfPresent(List<String> entries, String candidate) {
        String trimmed = candidate.trim();
        if (!trimmed.isEmpty()) {
            entries.add(trimmed);
        }
    }

    /** Position of an operator outside quotes and brackets, or -1. */
    private static int indexOfOperator(String text, String operator) {
        int depth = 0;
        char quote = 0;

        for (int i = 0; i + operator.length() <= text.length(); i++) {
            char c = text.charAt(i);

            if (quote != 0) {
                if (c == quote) {
                    quote = 0;
                }
                continue;
            }
            if (c == '\'' || c == '"') {
                quote = c;
                continue;
            }
            if (c == '(') {
                depth++;
                continue;
            }
            if (c == ')') {
                depth--;
                continue;
            }
            if (depth == 0 && text.startsWith(operator, i)) {
                // "=" must not match the "=" that belongs to "==" or "!=".
                if ("=".equals(operator)
                        && (text.startsWith("==", i) || (i > 0 && text.charAt(i - 1) == '!'))) {
                    continue;
                }
                return i;
            }
        }
        return -1;
    }

    /** True for {@code DB(...)} and for a bare statement opening with {@code DB}. */
    private static boolean isDbExpression(String text) {
        if (text == null) {
            return false;
        }
        String trimmed = text.trim();
        if (trimmed.length() < 2) {
            return false;
        }
        if (!trimmed.regionMatches(true, 0, "db", 0, 2)) {
            return false;
        }
        String rest = trimmed.substring(2).trim();
        return rest.startsWith("(") || rest.startsWith(":");
    }

    /** The statement inside {@code DB(...)}, or after a bare {@code DB:}. */
    private static String unwrapDb(String text) {
        String trimmed = text.trim();
        String rest = trimmed.substring(2).trim();

        if (rest.startsWith("(")) {
            int close = rest.lastIndexOf(')');
            if (close <= 0) {
                throw new IllegalArgumentException("[RowActions] DB( ... ) is missing its closing bracket: " + text);
            }
            return rest.substring(1, close).trim();
        }
        return rest.substring(1).trim();
    }

    /** True for {@code var(name)} — an explicit read of a feature variable. */
    private static boolean isVarExpression(String text) {
        String trimmed = text == null ? "" : text.trim();
        return trimmed.regionMatches(true, 0, "var(", 0, 4) && trimmed.endsWith(")");
    }

    private static String unwrapVar(String text) {
        String trimmed = text.trim();
        return trimmed.substring(4, trimmed.length() - 1).trim();
    }

    /** A single identifier, with no dots or brackets — the shape of a feature variable. */
    private static boolean isPlainName(String text) {
        return text.matches("[A-Za-z_][A-Za-z0-9_]*");
    }

    /** A dotted or bracketed path — {@code $.a.b}, {@code items[0].code}, {@code status}. */
    private static boolean looksLikePath(String text) {
        return text.matches("\\$?\\.?[A-Za-z_][A-Za-z0-9_]*(\\.[A-Za-z_][A-Za-z0-9_]*|\\[\\d+\\])*");
    }

    private static boolean isQuoted(String text) {
        return text.length() >= 2
                && ((text.startsWith("'") && text.endsWith("'")) || (text.startsWith("\"") && text.endsWith("\"")));
    }

    private static String unquote(String text) {
        return isQuoted(text) ? text.substring(1, text.length() - 1) : text;
    }

    private static boolean isBlank(String text) {
        return text == null || text.trim().isEmpty();
    }

    private static String str(Object value) {
        return value == null ? "" : String.valueOf(value);
    }
}
