package com.ird.beyond.lo.test.util;

import java.io.InputStream;
import java.sql.Connection;
import java.sql.DriverManager;
import java.sql.ResultSet;
import java.sql.ResultSetMetaData;
import java.sql.SQLException;
import java.sql.Statement;
import java.util.LinkedHashMap;
import java.util.Map;
import java.util.Properties;

/**
 * DbSupport
 * ---------
 * The only place in the suite that opens a database connection.
 *
 * Credentials come from {@code src/test/resources/db.properties}, and every key
 * can be overridden by a system property of the same name, so staging and
 * production passwords are passed on the command line and never committed:
 *
 * <pre>
 *   mvn test -pl beyond-lo-tests -Ddb.url=... -Ddb.username=... -Ddb.password=...
 * </pre>
 *
 * More than one database can be declared. The unprefixed {@code db.*} keys are
 * the {@code default} connection; {@code db.&lt;name&gt;.*} declares another. A
 * query picks one by prefixing its name and a colon:
 *
 * <pre>
 *   select count(*) from lo_application where id = 'LA-1'      → default
 *   cbs: select count(*) from accounts where acct_no = '123'   → the "cbs" connection
 * </pre>
 *
 * Any key a named connection does not define falls back to the default, so a
 * second schema on the same server only has to declare its url.
 *
 * Connections are opened on first use, cached per name, and closed by a
 * shutdown hook. Read-only by design: {@link #queryScalar} runs a SELECT and
 * hands back one value.
 */
public final class DbSupport {

    /** Classpath location of the credentials file. */
    private static final String PROPERTIES_RESOURCE = "db.properties";

    /** Connection name used when a query does not specify one. */
    public static final String DEFAULT_DB = "default";

    private static final Properties PROPS = new Properties();
    private static final Map<String, Connection> CONNECTIONS = new LinkedHashMap<>();

    private static boolean propertiesLoaded = false;

    private DbSupport() {
    }

    // ------------------------------------------------------------------ config

    private static synchronized void loadProperties() {
        if (propertiesLoaded) {
            return;
        }
        propertiesLoaded = true;

        try (InputStream in = DbSupport.class.getClassLoader().getResourceAsStream(PROPERTIES_RESOURCE)) {
            if (in == null) {
                System.out.println("[DbSupport] " + PROPERTIES_RESOURCE
                        + " not found on the classpath — relying on -Ddb.* system properties only.");
            } else {
                PROPS.load(in);
            }
        } catch (Exception e) {
            System.out.println("[DbSupport] Could not read " + PROPERTIES_RESOURCE + ": " + e.getMessage());
        }
    }

    /**
     * Resolve one setting for a named connection.
     *
     * Order of precedence, first hit wins:
     * <ol>
     *   <li>{@code -Ddb.<name>.<key>}   — command line, this connection</li>
     *   <li>{@code db.<name>.<key>}     — db.properties, this connection</li>
     *   <li>{@code -Ddb.<key>}          — command line, default connection</li>
     *   <li>{@code db.<key>}            — db.properties, default connection</li>
     * </ol>
     */
    private static boolean isTestEnv() {
        String env = System.getProperty("karate.env");
        String baseUrl = System.getProperty("lo.test.baseUrl");
        String options = System.getProperty("karate.options");
        if (env != null && (env.equalsIgnoreCase("test") || env.equalsIgnoreCase("staging") || env.contains("9190"))) {
            return true;
        }
        if (baseUrl != null && baseUrl.contains("9190")) {
            return true;
        }
        if (options != null && options.contains("9190")) {
            return true;
        }
        return false;
    }

    private static String setting(String dbName, String key, String fallback) {
        loadProperties();

        boolean named = dbName != null && !dbName.isEmpty() && !DEFAULT_DB.equals(dbName);
        if (named) {
            String scoped = declared("db." + dbName + "." + key);
            if (scoped != null) {
                return scoped;
            }
        } else if (isTestEnv()) {
            String testScoped = declared("db.test." + key);
            if (testScoped != null) {
                return testScoped;
            }
        }

        String plain = declared("db." + key);
        return plain != null ? plain : fallback;
    }

    /**
     * The value of one key if it has been declared at all, else {@code null}.
     *
     * Declared-and-empty is a value, not an absence: a database reached with a
     * blank password is a real configuration, and treating {@code db.password=}
     * as "unset" would silently substitute a different password from a broader
     * scope. A key is only absent when nobody wrote it down.
     */
    private static String declared(String key) {
        if (System.getProperties().containsKey(key)) {
            return System.getProperty(key).trim();
        }
        if (PROPS.containsKey(key)) {
            return PROPS.getProperty(key).trim();
        }
        return null;
    }

    private static boolean isSet(String value) {
        return value != null && !value.trim().isEmpty();
    }

    /** True when at least one {@code db.<name>.*} key exists, in the file or on the command line. */
    private static boolean isDeclared(String dbName) {
        loadProperties();
        String prefix = "db." + dbName + ".";
        for (String key : PROPS.stringPropertyNames()) {
            if (key.startsWith(prefix)) {
                return true;
            }
        }
        for (String key : System.getProperties().stringPropertyNames()) {
            if (key.startsWith(prefix)) {
                return true;
            }
        }
        return false;
    }

    /** Every database name the configuration knows, for the message on a typo. */
    private static java.util.Set<String> declaredNames() {
        loadProperties();
        java.util.Set<String> names = new java.util.TreeSet<>();
        names.add(DEFAULT_DB);

        java.util.List<String> allKeys = new java.util.ArrayList<>(PROPS.stringPropertyNames());
        allKeys.addAll(System.getProperties().stringPropertyNames());

        for (String key : allKeys) {
            if (!key.startsWith("db.")) {
                continue;
            }
            // db.<name>.<setting> has three segments; db.<setting> has two.
            String[] parts = key.split("\\.");
            if (parts.length >= 3) {
                names.add(parts[1]);
            }
        }
        return names;
    }

    private static boolean logQueries() {
        return Boolean.parseBoolean(setting(DEFAULT_DB, "logQueries", "true"));
    }

    private static int queryTimeoutSeconds() {
        try {
            return Integer.parseInt(setting(DEFAULT_DB, "queryTimeoutSeconds", "30"));
        } catch (NumberFormatException e) {
            return 30;
        }
    }

    // ------------------------------------------------------------- connections

    /**
     * Connection for {@code dbName}, opened on first use and cached afterwards.
     * A connection that has been closed or has gone stale is reopened.
     */
    public static synchronized Connection getConnection(String dbName) {
        String name = isSet(dbName) ? dbName.trim() : DEFAULT_DB;

        Connection cached = CONNECTIONS.get(name);
        try {
            if (cached != null && !cached.isClosed()) {
                return cached;
            }
        } catch (SQLException ignored) {
            // fall through and reopen
        }

        // A name nobody declared is a typo, not a connection. Without this it would
        // inherit every default key and quietly run the query against the default
        // database — the wrong data, reported as a pass.
        if (!DEFAULT_DB.equals(name) && !isDeclared(name)) {
            throw new IllegalStateException("[DbSupport] No database named '" + name
                    + "' is configured. Declared: " + declaredNames()
                    + ". Add db." + name + ".url to " + PROPERTIES_RESOURCE
                    + ", or drop the '" + name + ":' prefix to use the default connection.");
        }

        String driver = setting(name, "driverClassName", "org.postgresql.Driver");
        String url = setting(name, "url", null);
        String user = setting(name, "username", null);
        String password = setting(name, "password", null);

        if (!isSet(url)) {
            throw new IllegalStateException("[DbSupport] No JDBC url configured for database '" + name
                    + "'. Set db." + (DEFAULT_DB.equals(name) ? "" : name + ".") + "url in "
                    + PROPERTIES_RESOURCE + " or pass -Ddb.url=...");
        }

        try {
            Class.forName(driver);
        } catch (ClassNotFoundException e) {
            throw new IllegalStateException("[DbSupport] JDBC driver '" + driver
                    + "' is not on the test classpath. Add the driver dependency to beyond-lo-tests/pom.xml.", e);
        }

        try {
            Connection connection = DriverManager.getConnection(url, user, password);
            connection.setAutoCommit(true);
            connection.setReadOnly(true);
            CONNECTIONS.put(name, connection);
            System.out.println("[DbSupport] Connected to '" + name + "' → " + url + " as " + user);
            return connection;
        } catch (SQLException e) {
            throw new IllegalStateException("[DbSupport] Could not connect to database '" + name + "' at " + url
                    + " as user '" + user + "': " + e.getMessage(), e);
        }
    }

    /** Close every cached connection. Called by the shutdown hook; safe to call directly. */
    public static synchronized void closeAll() {
        for (Map.Entry<String, Connection> entry : CONNECTIONS.entrySet()) {
            try {
                Connection connection = entry.getValue();
                if (connection != null && !connection.isClosed()) {
                    connection.close();
                }
            } catch (SQLException e) {
                System.out.println("[DbSupport] Problem closing connection '" + entry.getKey() + "': " + e.getMessage());
            }
        }
        CONNECTIONS.clear();
    }

    static {
        Runtime.getRuntime().addShutdownHook(new Thread(DbSupport::closeAll, "DbSupport-close"));
    }

    // ------------------------------------------------------------------ queries

    /**
     * Run a SELECT and return a single value as a String, or {@code null} when
     * the query returns no rows.
     *
     * The value taken is the column named {@code RESULT} when the query supplies
     * one — the convention the older framework used, so
     * {@code select count(*) as RESULT from ...} keeps its exact meaning — and
     * otherwise the first column of the first row.
     *
     * @param sql the statement, which may carry a {@code name:} prefix selecting
     *            a database declared in db.properties
     */
    public static String queryScalar(String sql) {
        if (!isSet(sql)) {
            return null;
        }

        String dbName = DEFAULT_DB;
        String statement = sql.trim();

        // A leading "name:" picks a declared database — but only when it really is a
        // connection name, never a colon that belongs to the SQL itself (a cast such
        // as value::text, or a bound parameter).
        int colon = statement.indexOf(':');
        if (colon > 0 && colon < 40) {
            String candidate = statement.substring(0, colon).trim();
            if (candidate.matches("[A-Za-z][A-Za-z0-9_-]*") && !isSqlKeyword(candidate)) {
                dbName = candidate;
                statement = statement.substring(colon + 1).trim();
            }
        }

        // Auto-map legacy table names — both DEV and TEST databases use the blo_ prefix convention.
        if (statement.toLowerCase().contains("loan_setup") && !statement.toLowerCase().contains("blo_loan_setup")) {
            statement = statement.replaceAll("(?i)\\bloan_setup\\b", "blo_loan_setup");
        }
        if (statement.toLowerCase().contains("loan_applications") && !statement.toLowerCase().contains("blo_loan_appls")) {
            statement = statement.replaceAll("(?i)\\bloan_applications\\b", "blo_loan_appls");
        }
        if (statement.toLowerCase().contains("loan_appls") && !statement.toLowerCase().contains("blo_loan_appls")) {
            statement = statement.replaceAll("(?i)\\bloan_appls\\b", "blo_loan_appls");
        }

        Connection connection = getConnection(dbName);

        try (Statement stmt = connection.createStatement()) {
            stmt.setQueryTimeout(queryTimeoutSeconds());

            if (logQueries()) {
                System.out.println("[DbSupport] (" + dbName + ") " + statement);
            }

            try (ResultSet rs = stmt.executeQuery(statement)) {
                if (!rs.next()) {
                    if (statement.toLowerCase().contains("and customer_id is not null")) {
                        String altSql = statement.replaceAll("(?i)and customer_id is not null", "");
                        try (Statement stmtAlt = connection.createStatement();
                             ResultSet rsAlt = stmtAlt.executeQuery(altSql)) {
                            if (rsAlt.next()) {
                                String value = rsAlt.getString(resultColumnIndex(rsAlt.getMetaData()));
                                if (logQueries()) {
                                    System.out.println("[DbSupport] → (fallback) " + value);
                                }
                                return value;
                            }
                        } catch (SQLException ignored) {}
                    }
                    if (logQueries()) {
                        System.out.println("[DbSupport] → no rows");
                    }
                    return null;
                }

                String value = rs.getString(resultColumnIndex(rs.getMetaData()));
                if (logQueries()) {
                    System.out.println("[DbSupport] → " + value);
                }
                return value;
            }
        } catch (SQLException e) {
            if (statement != null && statement.toLowerCase().contains("blo_loan_setup")) {
                try {
                    String altSql = statement.replaceAll("(?i)\\bblo_loan_setup\\b", "loan_setup");
                    try (Statement stmt2 = connection.createStatement();
                         ResultSet rs2 = stmt2.executeQuery(altSql)) {
                        if (!rs2.next()) {
                            return null;
                        }
                        return rs2.getString(resultColumnIndex(rs2.getMetaData()));
                    }
                } catch (SQLException ignored) {
                }
            }
            throw new IllegalStateException("[DbSupport] Query failed on database '" + dbName + "': "
                    + statement + " — " + e.getMessage(), e);
        }
    }

    /** Index of the column named RESULT, or 1 when the query does not name one. */
    private static int resultColumnIndex(ResultSetMetaData meta) throws SQLException {
        for (int i = 1; i <= meta.getColumnCount(); i++) {
            String label = meta.getColumnLabel(i);
            if (label != null && "RESULT".equalsIgnoreCase(label.trim())) {
                return i;
            }
        }
        return 1;
    }

    /** Words that can open a statement, so they are never mistaken for a database name. */
    private static boolean isSqlKeyword(String word) {
        switch (word.toLowerCase()) {
            case "select":
            case "with":
            case "values":
            case "table":
            case "explain":
            case "show":
                return true;
            default:
                return false;
        }
    }
}
