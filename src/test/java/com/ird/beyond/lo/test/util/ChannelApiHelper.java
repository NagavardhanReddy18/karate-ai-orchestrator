package com.ird.beyond.lo.test.util;

import com.fasterxml.jackson.databind.ObjectMapper;

import java.io.*;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.*;

/**
 * ChannelApiHelper
 * ----------------
 * Provides reliable multipart/form-data submission for BeyondLO Channel APIs:
 * - Sends 'application' part as application/json
 * - Sends 'document.<CODE>' part as application/pdf with exact naming (e.g. document.National ID Card)
 * - Returns a Map containing 'status' (int) and 'body' (deserialized JSON Map/List or String)
 */
public class ChannelApiHelper {

    private static final ObjectMapper MAPPER = new ObjectMapper();

    public static Map<String, Object> postMultipart(String endpointUrl, String token, Object appPayload, String docCode, String docFileName) {
        Map<String, Object> result = new HashMap<>();
        HttpURLConnection conn = null;
        try {
            String boundary = "BeyondLoChannelBoundary" + System.currentTimeMillis();
            URL url = new URL(endpointUrl);
            conn = (HttpURLConnection) url.openConnection();
            conn.setRequestMethod("POST");
            conn.setDoOutput(true);
            conn.setConnectTimeout(15000);
            conn.setReadTimeout(15000);
            conn.setRequestProperty("Authorization", "Bearer " + token);
            conn.setRequestProperty("Content-Type", "multipart/form-data; boundary=" + boundary);

            String jsonString = (appPayload instanceof String) ? (String) appPayload : MAPPER.writeValueAsString(appPayload);

            try (OutputStream out = conn.getOutputStream();
                 PrintWriter writer = new PrintWriter(new OutputStreamWriter(out, StandardCharsets.UTF_8), true)) {

                // Part 1: application (application/json)
                writer.append("--").append(boundary).append("\r\n");
                writer.append("Content-Disposition: form-data; name=\"application\"; filename=\"application.json\"\r\n");
                writer.append("Content-Type: application/json; charset=UTF-8\r\n\r\n");
                writer.append(jsonString).append("\r\n");
                writer.flush();

                // Part 2: document.<CODE> (application/pdf)
                if (docCode != null && !docCode.trim().isEmpty()) {
                    String partName = "document." + docCode.trim();
                    String fileName = (docFileName != null && !docFileName.trim().isEmpty()) ? docFileName.trim() : (docCode + ".pdf");
                    writer.append("--").append(boundary).append("\r\n");
                    writer.append("Content-Disposition: form-data; name=\"").append(partName).append("\"; filename=\"").append(fileName).append("\"\r\n");
                    writer.append("Content-Type: application/pdf\r\n\r\n");
                    writer.flush();
                    out.write("%PDF-1.4 sample dummy document content".getBytes(StandardCharsets.UTF_8));
                    out.flush();
                    writer.append("\r\n");
                    writer.flush();
                }

                // End boundary
                writer.append("--").append(boundary).append("--\r\n");
                writer.flush();
            }

            int statusCode = conn.getResponseCode();
            result.put("status", statusCode);

            InputStream is = (statusCode >= 200 && statusCode < 400) ? conn.getInputStream() : conn.getErrorStream();
            if (is != null) {
                ByteArrayOutputStream buffer = new ByteArrayOutputStream();
                byte[] data = new byte[1024];
                int nRead;
                while ((nRead = is.read(data, 0, data.length)) != -1) {
                    buffer.write(data, 0, nRead);
                }
                String respBody = buffer.toString(StandardCharsets.UTF_8);
                try {
                    result.put("body", MAPPER.readValue(respBody, Object.class));
                } catch (Exception e) {
                    result.put("body", respBody);
                }
            } else {
                result.put("body", Collections.emptyMap());
            }

        } catch (Exception e) {
            result.put("status", 500);
            result.put("error", e.getMessage());
        } finally {
            if (conn != null) conn.disconnect();
        }
        return result;
    }
}
