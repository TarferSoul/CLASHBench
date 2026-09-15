import com.sun.net.httpserver.HttpExchange;
import com.sun.net.httpserver.HttpServer;
import com.zaxxer.hikari.HikariConfig;
import com.zaxxer.hikari.HikariDataSource;
import com.zaxxer.hikari.HikariPoolMXBean;

import java.io.IOException;
import java.io.OutputStream;
import java.net.InetSocketAddress;
import java.net.URLDecoder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.sql.Connection;
import java.sql.PreparedStatement;
import java.sql.ResultSet;
import java.sql.Statement;
import java.time.Instant;
import java.util.ArrayList;
import java.util.Collections;
import java.util.List;
import java.util.Properties;
import java.util.concurrent.Executors;

public class ModelRegistryService {
    private static Properties config;
    private static HikariDataSource dataSource;
    private static final Object stateLock = new Object();
    private static List<Integer> backendPids = new ArrayList<>();
    private static long startedAtMillis;
    private static int healthRequests = 0;
    private static int latestRequests = 0;
    private static String phase = "starting";

    private static String cfg(String key) {
        return config.getProperty(key);
    }

    private static String jsonEscape(String value) {
        if (value == null) {
            return "";
        }
        return value.replace("\\", "\\\\").replace("\"", "\\\"").replace("\n", "\\n");
    }

    private static HikariPoolMXBean poolBean() {
        return dataSource.getHikariPoolMXBean();
    }

    private static String poolJson() {
        HikariPoolMXBean bean = poolBean();
        return "{"
            + "\"pool_name\":\"" + jsonEscape(cfg("pool_name")) + "\","
            + "\"total\":" + bean.getTotalConnections() + ","
            + "\"idle\":" + bean.getIdleConnections() + ","
            + "\"active\":" + bean.getActiveConnections() + ","
            + "\"waiting\":" + bean.getThreadsAwaitingConnection() + ","
            + "\"generation\":\"" + jsonEscape(cfg("generation")) + "\""
            + "}";
    }

    private static void writeState() {
        synchronized (stateLock) {
            try {
                Path path = Path.of(cfg("state_path"));
                Files.createDirectories(path.getParent());
                StringBuilder pids = new StringBuilder();
                for (int i = 0; i < backendPids.size(); i++) {
                    if (i > 0) {
                        pids.append(",");
                    }
                    pids.append(backendPids.get(i));
                }
                String body = "{\n"
                    + "  \"phase\":\"" + jsonEscape(phase) + "\",\n"
                    + "  \"pid\":" + ProcessHandle.current().pid() + ",\n"
                    + "  \"service_token\":\"" + jsonEscape(cfg("service_token")) + "\",\n"
                    + "  \"generation\":\"" + jsonEscape(cfg("generation")) + "\",\n"
                    + "  \"pool_name\":\"" + jsonEscape(cfg("pool_name")) + "\",\n"
                    + "  \"pool_size\":" + Integer.parseInt(cfg("pool_size")) + ",\n"
                    + "  \"backend_pids\":[" + pids + "],\n"
                    + "  \"health_requests\":" + healthRequests + ",\n"
                    + "  \"latest_requests\":" + latestRequests + ",\n"
                    + "  \"started_at_epoch\":" + (startedAtMillis / 1000.0) + ",\n"
                    + "  \"updated_at_epoch\":" + (System.currentTimeMillis() / 1000.0) + ",\n"
                    + "  \"pool_metrics\":" + poolJson() + "\n"
                    + "}\n";
                Path tmp = Path.of(path.toString() + ".tmp");
                Files.writeString(tmp, body, StandardCharsets.UTF_8);
                Files.move(tmp, path, java.nio.file.StandardCopyOption.REPLACE_EXISTING);
                path.toFile().setReadable(true, false);
            } catch (Exception ignored) {
            }
        }
    }

    private static HikariDataSource buildDataSource() {
        HikariConfig hc = new HikariConfig();
        String url = "jdbc:postgresql://" + cfg("db_host") + ":" + cfg("db_port") + "/" + cfg("database");
        hc.setJdbcUrl(url);
        hc.setUsername(cfg("db_user"));
        hc.setMinimumIdle(Integer.parseInt(cfg("pool_size")));
        hc.setMaximumPoolSize(Integer.parseInt(cfg("pool_size")));
        hc.setPoolName(cfg("pool_name"));
        hc.setInitializationFailTimeout(5000);
        hc.setConnectionTestQuery("SELECT 1");
        hc.setConnectionTimeout(3000);
        hc.setIdleTimeout(600000);
        hc.setMaxLifetime(1800000);
        hc.addDataSourceProperty("ApplicationName", "model_registry_api:" + cfg("service_token"));
        hc.addDataSourceProperty("connectTimeout", "3");
        return new HikariDataSource(hc);
    }

    private static List<Integer> warmPool() throws Exception {
        int size = Integer.parseInt(cfg("pool_size"));
        List<Connection> connections = new ArrayList<>();
        List<Integer> pids = new ArrayList<>();
        try {
            for (int i = 0; i < size; i++) {
                connections.add(dataSource.getConnection());
            }
            for (Connection connection : connections) {
                try (Statement statement = connection.createStatement();
                     ResultSet rs = statement.executeQuery("SELECT pg_backend_pid()")) {
                    if (rs.next()) {
                        pids.add(rs.getInt(1));
                    }
                }
            }
        } finally {
            for (Connection connection : connections) {
                try {
                    connection.close();
                } catch (Exception ignored) {
                }
            }
        }
        Collections.sort(pids);
        for (int i = 0; i < 100; i++) {
            HikariPoolMXBean bean = poolBean();
            if (bean.getTotalConnections() == size && bean.getIdleConnections() == size
                    && bean.getActiveConnections() == 0) {
                return pids;
            }
            Thread.sleep(100);
        }
        return pids;
    }

    private static void sendJson(HttpExchange exchange, int status, String body) throws IOException {
        byte[] payload = body.getBytes(StandardCharsets.UTF_8);
        exchange.getResponseHeaders().add("Content-Type", "application/json");
        exchange.sendResponseHeaders(status, payload.length);
        try (OutputStream os = exchange.getResponseBody()) {
            os.write(payload);
        }
    }

    private static void handleHealth(HttpExchange exchange) throws IOException {
        String database;
        String role;
        int modelCount;
        try (Connection connection = dataSource.getConnection();
             Statement statement = connection.createStatement();
             ResultSet rs = statement.executeQuery(
                 "SELECT current_database(), current_user, count(*)::int FROM registry.models")) {
            rs.next();
            database = rs.getString(1);
            role = rs.getString(2);
            modelCount = rs.getInt(3);
        } catch (Exception exc) {
            sendJson(exchange, 503, "{\"ok\":false,\"error\":\"" + jsonEscape(exc.toString()) + "\"}\n");
            return;
        }
        synchronized (stateLock) {
            healthRequests++;
        }
        writeState();
        String body = "{"
            + "\"ok\":true,"
            + "\"database\":\"" + jsonEscape(database) + "\","
            + "\"role\":\"" + jsonEscape(role) + "\","
            + "\"model_count\":" + modelCount + ","
            + "\"startup_token\":\"" + jsonEscape(cfg("service_token")) + "\","
            + "\"generation\":\"" + jsonEscape(cfg("generation")) + "\","
            + "\"pool\":" + poolJson()
            + "}\n";
        sendJson(exchange, 200, body);
    }

    private static void handleLatest(HttpExchange exchange) throws IOException {
        String path = exchange.getRequestURI().getPath();
        String prefix = "/api/models/";
        String suffix = "/versions/latest";
        if (!path.startsWith(prefix) || !path.endsWith(suffix)) {
            sendJson(exchange, 404, "{\"error\":\"not_found\"}\n");
            return;
        }
        String encoded = path.substring(prefix.length(), path.length() - suffix.length());
        String modelName = URLDecoder.decode(encoded, StandardCharsets.UTF_8);
        String sql = "SELECT mv.version_id, mv.model_name, mv.semver, mv.artifact_sha256, "
            + "(SELECT count(*)::int FROM registry.promotion_readiness pr "
            + " WHERE pr.version_id = mv.version_id AND pr.status = 'passed') AS passed_checks "
            + "FROM registry.model_versions mv "
            + "WHERE mv.model_name = ? AND mv.release_candidate = true "
            + "ORDER BY mv.created_at DESC LIMIT 1";
        int versionId;
        int passedChecks;
        String foundModelName;
        String semver;
        String artifactSha256;
        try (Connection connection = dataSource.getConnection();
             PreparedStatement ps = connection.prepareStatement(sql)) {
            ps.setString(1, modelName);
            try (ResultSet rs = ps.executeQuery()) {
                if (!rs.next()) {
                    sendJson(exchange, 404, "{\"error\":\"model_not_found\"}\n");
                    return;
                }
                foundModelName = rs.getString("model_name");
                versionId = rs.getInt("version_id");
                semver = rs.getString("semver");
                artifactSha256 = rs.getString("artifact_sha256");
                passedChecks = rs.getInt("passed_checks");
            }
        } catch (Exception exc) {
            sendJson(exchange, 503, "{\"error\":\"" + jsonEscape(exc.toString()) + "\"}\n");
            return;
        }
        synchronized (stateLock) {
            latestRequests++;
        }
        writeState();
        String body = "{"
            + "\"model_name\":\"" + jsonEscape(foundModelName) + "\","
            + "\"version_id\":" + versionId + ","
            + "\"semver\":\"" + jsonEscape(semver) + "\","
            + "\"artifact_sha256\":\"" + jsonEscape(artifactSha256) + "\","
            + "\"passed_checks\":" + passedChecks + ","
            + "\"startup_token\":\"" + jsonEscape(cfg("service_token")) + "\","
            + "\"generation\":\"" + jsonEscape(cfg("generation")) + "\","
            + "\"pool\":" + poolJson()
            + "}\n";
        sendJson(exchange, 200, body);
    }

    private static void handlePool(HttpExchange exchange) throws IOException {
        sendJson(exchange, 200, "{"
            + "\"startup_token\":\"" + jsonEscape(cfg("service_token")) + "\","
            + "\"generation\":\"" + jsonEscape(cfg("generation")) + "\","
            + "\"pool\":" + poolJson()
            + "}\n");
    }

    private static void watchStopFile(HttpServer server) {
        Thread thread = new Thread(() -> {
            Path stopPath = Path.of(cfg("stop_path"));
            while (true) {
                try {
                    Thread.sleep(200);
                    if (Files.exists(stopPath)) {
                        phase = "stopping";
                        writeState();
                        server.stop(0);
                        if (dataSource != null) {
                            dataSource.close();
                        }
                        phase = "stopped";
                        writeState();
                        System.exit(0);
                    }
                } catch (InterruptedException ignored) {
                    return;
                }
            }
        });
        thread.setName("stop-file-watch");
        thread.setDaemon(true);
        thread.start();
    }

    public static void main(String[] args) throws Exception {
        if (args.length != 1) {
            throw new IllegalArgumentException("usage: ModelRegistryService service.properties");
        }
        config = new Properties();
        try (var input = Files.newInputStream(Path.of(args[0]))) {
            config.load(input);
        }
        Files.deleteIfExists(Path.of(cfg("stop_path")));
        startedAtMillis = System.currentTimeMillis();
        dataSource = buildDataSource();
        backendPids = warmPool();
        phase = "running";
        writeState();

        Runtime.getRuntime().addShutdownHook(new Thread(() -> {
            phase = "stopped";
            if (dataSource != null) {
                dataSource.close();
            }
            writeState();
        }));

        HttpServer server = HttpServer.create(
            new InetSocketAddress(cfg("http_host"), Integer.parseInt(cfg("http_port"))),
            0
        );
        server.createContext("/actuator/health/db", ModelRegistryService::handleHealth);
        server.createContext("/api/models", ModelRegistryService::handleLatest);
        server.createContext("/actuator/metrics/hikaricp.connections", ModelRegistryService::handlePool);
        server.setExecutor(Executors.newFixedThreadPool(4));
        watchStopFile(server);
        server.start();
        System.out.println("MODEL_REGISTRY_API_READY token=" + cfg("service_token")
            + " pool=" + cfg("pool_size") + " started_at=" + Instant.now());
    }
}
