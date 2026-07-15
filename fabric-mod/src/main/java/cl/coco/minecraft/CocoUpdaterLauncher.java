package cl.coco.minecraft;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.StandardOpenOption;
import java.time.Instant;
import java.util.ArrayList;
import java.util.List;

import net.fabricmc.api.EnvType;
import net.fabricmc.loader.api.FabricLoader;

/** Starts CocoUpdater without depending on a client lifecycle event. */
public final class CocoUpdaterLauncher {
    private static final long PID = ProcessHandle.current().pid();
    private static final Path ROOT = Path.of(System.getenv("LOCALAPPDATA"), "CocoMinecraftUpdater");
    private static final Path STATE_FILE = ROOT.resolve("session").resolve(PID + ".json");
    private static final Path LOG_FILE = ROOT.resolve("logs").resolve("bridge-" + PID + ".log");
    private static boolean initialized;
    private static boolean networkReady;
    private static Process networkProcess;
    private static int networkAttempts;
    private static long nextNetworkAttemptAt;

    private CocoUpdaterLauncher() { }

    public static synchronized void initializeEarly() {
        if (FabricLoader.getInstance().getEnvironmentType() != EnvType.CLIENT) return;
        if (!initialized) {
            initialized = true;
            try {
                Files.deleteIfExists(STATE_FILE);
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
        networkProcess = start(gameDir, true, source + " intento=" + networkAttempts);
    }

    public static synchronized void launchFullCheck(Path gameDir, String source) {
        start(gameDir, false, source);
    }

    public static Path stateFile() {
        return STATE_FILE;
    }

    public static void logClientEntrypoint() {
        log("Entrypoint cliente inicializado.");
    }

    private static Process start(Path gameDir, boolean networkOnly, String source) {
        Path exe = ROOT.resolve("CocoUpdater.exe");
        if (!Files.isRegularFile(exe)) {
            log("No existe el EXE canonico. source=" + source + " path=" + exe);
            return null;
        }
        List<String> command = new ArrayList<>(List.of(
            exe.toString(), "-GameDir", gameDir.toAbsolutePath().normalize().toString(),
            "-MinecraftPid", Long.toString(PID), "-SessionStatePath", STATE_FILE.toString(), "-Silent"
        ));
        if (networkOnly) command.add("-NetworkOnly");
        try {
            Process process = new ProcessBuilder(command)
                .redirectOutput(ProcessBuilder.Redirect.DISCARD)
                .redirectError(ProcessBuilder.Redirect.DISCARD)
                .start();
            log("CocoUpdater iniciado. childPid=" + process.pid() + " networkOnly=" + networkOnly + " source=" + source
                + " gameDir=" + gameDir.toAbsolutePath().normalize());
            return process;
        } catch (IOException error) {
            log("Fallo al iniciar CocoUpdater. networkOnly=" + networkOnly + " source=" + source + " error=" + error);
            return null;
        }
    }

    private static boolean stateIsReady() {
        if (!Files.isRegularFile(STATE_FILE)) return false;
        try {
            String json = Files.readString(STATE_FILE, StandardCharsets.UTF_8);
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
