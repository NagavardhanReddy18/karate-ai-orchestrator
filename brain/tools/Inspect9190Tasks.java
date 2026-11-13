import com.fasterxml.jackson.databind.ObjectMapper;

import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;
import java.time.Duration;
import java.util.*;

/**
 * Diagnostic inspection tool inside brain/tools.
 * Inspects an application's loan status, Flowable tasks, pre-checklists, and assessment state.
 * Usage: Inspect9190Tasks <appId> [applicationRef] [baseUrl]
 */
public class Inspect9190Tasks {
    private static final ObjectMapper MAPPER = new ObjectMapper();

    public static void main(String[] args) throws Exception {
        String appId = args.length > 0 ? args[0] : "7570";
        String appRef = args.length > 1 ? args[1] : "";
        String baseUrl = args.length > 2 ? args[2] : "http://164.52.210.93:9190/api";

        HttpClient http = HttpClient.newBuilder().connectTimeout(Duration.ofSeconds(5)).build();
        String token = login(http, baseUrl, "underwriter1", List.of("Password123", "Password@123"));
        if (token == null) {
            token = login(http, baseUrl, "admin", List.of("Password123", "Password@123"));
        }
        System.out.println("Base URL: " + baseUrl + " | Token acquired: " + (token != null));

        List<String> paths = new ArrayList<>(List.of(
                "/v1/loans/" + appId,
                "/v1/loans/" + appId + "/tasks",
                "/v1/assessment/" + appId
        ));
        if (!appRef.isBlank()) {
            paths.add("/v1/pre-checklist/" + appRef + "/APPLICATION");
            paths.add("/v1/pre-checklist/" + appRef + "/ASSESSMENT");
        }

        for (String path : paths) {
            HttpRequest req = HttpRequest.newBuilder()
                    .uri(URI.create(baseUrl + path))
                    .timeout(Duration.ofSeconds(10))
                    .header("Authorization", "Bearer " + token)
                    .GET().build();
            HttpResponse<String> res = http.send(req, HttpResponse.BodyHandlers.ofString());
            System.out.println("\n=== GET " + path + " -> HTTP " + res.statusCode() + " ===");
            System.out.println(res.body());
        }
    }

    @SuppressWarnings("unchecked")
    private static String login(HttpClient http, String baseUrl, String user, List<String> passwords) throws Exception {
        for (String p : passwords) {
            String payload = MAPPER.writeValueAsString(Map.of("username", user, "password", p));
            HttpRequest req = HttpRequest.newBuilder()
                    .uri(URI.create(baseUrl + "/auth/login"))
                    .timeout(Duration.ofSeconds(5))
                    .header("Content-Type", "application/json")
                    .POST(HttpRequest.BodyPublishers.ofString(payload)).build();
            HttpResponse<String> res = http.send(req, HttpResponse.BodyHandlers.ofString());
            if (res.statusCode() == 200) {
                Map<String, Object> body = MAPPER.readValue(res.body(), Map.class);
                if (Boolean.TRUE.equals(body.get("requiresSessionConfirm"))) {
                    String cPayload = MAPPER.writeValueAsString(Map.of("confirmToken", body.get("confirmToken")));
                    HttpRequest cReq = HttpRequest.newBuilder()
                            .uri(URI.create(baseUrl + "/auth/confirm-session"))
                            .header("Content-Type", "application/json")
                            .POST(HttpRequest.BodyPublishers.ofString(cPayload)).build();
                    HttpResponse<String> cRes = http.send(cReq, HttpResponse.BodyHandlers.ofString());
                    if (cRes.statusCode() == 200) body = MAPPER.readValue(cRes.body(), Map.class);
                }
                return String.valueOf(body.get("token"));
            }
        }
        return null;
    }
}
