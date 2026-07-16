package cl.coco.minecraft;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.time.Instant;
import java.time.Duration;
import java.util.ArrayList;
import java.util.List;
import java.util.regex.Matcher;
import java.util.regex.Pattern;
import java.net.URI;
import java.net.http.HttpClient;
import java.net.http.HttpRequest;
import java.net.http.HttpResponse;

import net.fabricmc.api.EnvType;
import net.fabricmc.loader.api.FabricLoader;

/** Starts CocoUpdater without depending on a client lifecycle event. */
public final class CocoUpdaterLauncher {
    private static final long PID = ProcessHandle.current().pid();
    private static final Path ROOT = Path.of(System.getenv("LOCALAPPDATA"), "CocoMinecraftUpdater");
    private static final Path NETWORK_STATE_FILE = ROOT.resolve("session").resolve(PID + "-network.json");
    private static final Path UPDATE_STATE_FILE = ROOT.resolve("session").resolve(PID + "-update.json");
    private static final Path LOG_FILE = ROOT.resolve("logs").resolve("bridge-" + PID + ".log");
    private static final URI MANIFEST_URI = URI.create("https://github.com/Franco-Caballero/CocoMinecraftUpdater/releases/latest/download/latest.json");
    private static final Pattern MANIFEST_VERSION = Pattern.compile("\\\"version\\\"\\s*:\\s*\\\"([^\\\"]+)\\\"");
    private static final HttpClient HTTP = HttpClient.newBuilder().followRedirects(HttpClient.Redirect.ALWAYS)
        .connectTimeout(Duration.ofSeconds(8)).build();
    private static boolean initialized;
    private static boolean networkReady;
    private static Process networkProcess;
    private static int networkAttempts;
    private static long nextNetworkAttemptAt;
    private static Process fullProcess;
    private static boolean fullCheckRequested;
    private static int fullAttempts;
    private static long nextFullAttemptAt;
    private static boolean versionCheckInFlight;

    private CocoUpdaterLauncher() { }

    public static synchronized void initializeEarly() {
        if (FabricLoader.getInstance().getEnvironmentType() != EnvType.CLIENT) return;
        if (!initialized) {
            initialized = true;
            try {
                Files.deleteIfExists(NETWORK_STATE_FILE);
                Files.deleteIfExists(UPDATE_STATE_FILE);
            } catch (IOException error) {
                log("No se pudo borrar el estado anterior: " + error);
            }
            log("Launcher inicializado. PID=" + PID + " user.dir=" + System.getProperty("user.dir"));
        }
        ensureNetworkCheck(Path.of(System.getProperty("user.dir")), "main-entrypoint");
    }

    public static synchronized void ensureNetworkCheck(Path gameDir, String source) {
        if (FabricLoader.getInstance().getEnvironmentType() != EnvType.CLIENT) return;
        if (!initialized) initializeEarly();
        if (networkReady || stateIsReady()) {
            if (!networkReady) log("Red confirmada por el estado de sesion.");
            networkReady = true;
            return;
        }
        if (networkProcess != null && networkProcess.isAlive()) return;
        long now = System.currentTimeMillis();
        if (now < nextNetworkAttemptAt) return;
        networkAttempts++;
        nextNetworkAttemptAt = now + 10_000L;
        networkProcess = start(gameDir, NETWORK_STATE_FILE, true, source + " intento=" + networkAttempts);
    }

    public static synchronized void launchFullCheck(Path gameDir, String source) {
        if (fullProcess != null && fullProcess.isAlive()) {
            log("Chequeo completo ya activo. source=" + source + " childPid=" + fullProcess.pid());
            return;
        }
        fullCheckRequested = true;
        fullAttempts = 0;
        nextFullAttemptAt = 0L;
        try {
            Files.deleteIfExists(UPDATE_STATE_FILE);
        } catch (IOException error) {
            log("No se pudo limpiar el estado de actualizacion anterior: " + error);
        }
        ensureFullCheck(gameDir, source);
    }

    /** Checks only the public version in-process; starts the visible updater only when needed. */
    public static synchronized void checkLatestAndLaunchFullUpdate(Path gameDir, String source) {
        if (versionCheckInFlight || (fullProcess != null && fullProcess.isAlive())) return;
        versionCheckInFlight = true;
        Thread.ofVirtual().name("coco-version-check").start(() -> {
            boolean launchUpdater = true;
            String result = "unknown";
            try {
                URI uncached = URI.create(MANIFEST_URI + "?bridge=" + System.currentTimeMillis());
                HttpRequest request = HttpRequest.newBuilder(uncached).timeout(Duration.ofSeconds(12))
                    .header("Cache-Control", "no-cache").GET().build();
                String json = HTTP.send(request, HttpResponse.BodyHandlers.ofString(StandardCharsets.UTF_8)).body();
                Matcher match = MANIFEST_VERSION.matcher(json);
                if (!match.find()) throw new IOException("El manifiesto no contiene version.");
                result = match.group(1);
                launchUpdater = !CocoProtocol.PACK_VERSION.equals(result);
                log("Version publica=" + result + " cargada=" + CocoProtocol.PACK_VERSION + " source=" + source);
            } catch (Exception error) {
                // A failed probe delegates retries and the visible diagnostic to
                // the updater instead of silently abandoning a possible update.
                log("No se pudo consultar la version publica; se delega al updater. source=" + source + " error=" + error);
            } finally {
                synchronized (CocoUpdaterLauncher.class) { versionCheckInFlight = false; }
            }
            if (launchUpdater) launchFullCheck(gameDir, source + " publica=" + result);
        });
    }

    public static synchronized void ensureFullCheck(Path gameDir, String source) {
        if (!fullCheckRequested) return;
        if (fullProcess != null) {
            if (fullProcess.isAlive()) return;
            int exitCode = fullProcess.exitValue();
            log("Chequeo completo termino. childPid=" + fullProcess.pid() + " exitCode=" + exitCode
                + " state=" + Files.isRegularFile(UPDATE_STATE_FILE));
            if (exitCode == 0 && Files.isRegularFile(UPDATE_STATE_FILE)) {
                fullCheckRequested = false;
                fullProcess = null;
                return;
            }
            fullProcess = null;
        }
        long now = System.currentTimeMillis();
        if (now < nextFullAttemptAt || fullAttempts >= 3) return;
        fullAttempts++;
        nextFullAttemptAt = now + 5_000L;
        fullProcess = start(gameDir, UPDATE_STATE_FILE, false, source + " intento=" + fullAttempts);
    }

    public static Path stateFile() {
        return UPDATE_STATE_FILE;
    }

    public static void logClientEntrypoint() {
        log("Entrypoint cliente inicializado.");
    }

    private static Process start(Path gameDir, Path stateFile, boolean networkOnly, String source) {
        Path exe = ROOT.resolve("CocoUpdater.exe");
        if (!Files.isRegularFile(exe)) {
            log("No existe el EXE canonico. source=" + source + " path=" + exe);
            return null;
        }
        List<String> command = new ArrayList<>(List.of(
            exe.toString(), "-GameDir", gameDir.toAbsolutePath().normalize().toString(),
            "-MinecraftPid", Long.toString(PID), "-SessionStatePath", stateFile.toString(), "-Silent"
        ));
        if (networkOnly) command.add("-NetworkOnly");
        try {
            ProcessBuilder builder = new ProcessBuilder(command)
                .redirectOutput(ProcessBuilder.Redirect.DISCARD)
                .redirectError(ProcessBuilder.Redirect.DISCARD);
            if (!networkOnly) {
                // Environment variables keep this handshake compatible with an
                // older canonical bootstrapper that does not know new switches.
                builder.environment().put("COCO_RUNNING_PACK_VERSION", CocoProtocol.PACK_VERSION);
                builder.environment().put("COCO_SHOW_ON_UPDATE", "1");
            }
            Process process = builder.start();
            log("CocoUpdater iniciado. childPid=" + process.pid() + " networkOnly=" + networkOnly + " source=" + source
                + " gameDir=" + gameDir.toAbsolutePath().normalize());
            return process;
        } catch (IOException error) {
            log("Fallo al iniciar CocoUpdater. networkOnly=" + networkOnly + " source=" + source + " error=" + error);
            return null;
        }
    }

    private static boolean stateIsReady() {
        if (!Files.isRegularFile(NETWORK_STATE_FILE)) return false;
        try {
            String json = Files.readString(NETWORK_STATE_FILE, StandardCharsets.UTF_8);
            return json.contains("\"message\":\"Red Coco lista\"") && json.contains("\"progress\":100");
        } catch (IOException ignored) {
            return false;
        }
    }

    private static void log(String message) {
        try {
            Files.createDirectories(LOG_FILE.getParent());
            Files.writeString(LOG_FILE, Instant.now() + " " + message + System.lineSeparator(), StandardCharsets.UTF_8,
                StandardOpenOption.CREATE, StandardOpenOption.APPEND);
        } catch (IOException ignored) {
            // The updater remains usable manually even if diagnostics cannot be written.
        }
    }
}
