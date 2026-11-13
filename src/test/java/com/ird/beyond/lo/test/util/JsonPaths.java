package com.ird.beyond.lo.test.util;

import java.util.List;
import java.util.Map;

/**
 * JsonPaths
 * ---------
 * Reads a field out of a JSON response by a dotted path.
 *
 * Karate hands a parsed response to Java as plain {@link Map} and {@link List}
 * instances, so walking it needs nothing beyond the JDK — this deliberately
 * avoids pulling a JSONPath library into the test module for what amounts to a
 * few field lookups.
 *
 * Accepted forms, all equivalent where they name the same field:
 *
 * <pre>
 *   status
 *   .status
 *   $.status
 *   response.status
 *   $.items[0].code
 *   applicant.address.city
 * </pre>
 *
 * A path that does not resolve returns {@code null} rather than throwing, which
 * is what lets a store entry fall back to treating its right-hand side as a
 * literal.
 */
public final class JsonPaths {

    private JsonPaths() {
    }

    /**
     * Value at {@code path}, or {@code null} when any step of the path is absent.
     *
     * @param root  the response, usually a Map or a List
     * @param path  dotted path, with optional {@code $.} or {@code response.} lead-in
     */
    public static Object read(Object root, String path) {
        if (root == null || path == null) {
            return null;
        }

        String cleaned = path.trim();
        if (cleaned.startsWith("$")) {
            cleaned = cleaned.substring(1);
        }
        if (cleaned.startsWith(".")) {
            cleaned = cleaned.substring(1);
        }
        if (cleaned.startsWith("response.")) {
            cleaned = cleaned.substring("response.".length());
        }
        if (cleaned.isEmpty()) {
            return root;
        }

        Object current = root;

        for (String segment : cleaned.split("\\.")) {
            if (current == null || segment.isEmpty()) {
                return null;
            }

            String name = segment;

            // Peel any [n] suffixes off the field name: items[0][1] is valid.
            int bracket = segment.indexOf('[');
            if (bracket >= 0) {
                name = segment.substring(0, bracket);
            }

            if (!name.isEmpty()) {
                current = field(current, name);
            }

            if (bracket >= 0) {
                current = indexes(current, segment.substring(bracket));
            }
        }
        return current;
    }

    /** One named field of a Map. Anything that is not a Map has no fields. */
    private static Object field(Object node, String name) {
        if (node instanceof Map) {
            return ((Map<?, ?>) node).get(name);
        }
        return null;
    }

    /** Apply a run of {@code [n]} subscripts to a List. */
    private static Object indexes(Object node, String subscripts) {
        Object current = node;
        int at = 0;

        while (at < subscripts.length()) {
            int open = subscripts.indexOf('[', at);
            int close = open < 0 ? -1 : subscripts.indexOf(']', open);
            if (open < 0 || close < 0) {
                return current;
            }

            int index;
            try {
                index = Integer.parseInt(subscripts.substring(open + 1, close).trim());
            } catch (NumberFormatException e) {
                return null;
            }

            if (!(current instanceof List)) {
                return null;
            }
            List<?> list = (List<?>) current;
            // A negative index counts back from the end, so [-1] is the last element.
            int resolved = index < 0 ? list.size() + index : index;
            if (resolved < 0 || resolved >= list.size()) {
                return null;
            }

            current = list.get(resolved);
            at = close + 1;
        }
        return current;
    }
}
