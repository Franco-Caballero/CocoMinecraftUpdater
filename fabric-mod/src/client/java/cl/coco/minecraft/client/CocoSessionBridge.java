package cl.coco.minecraft.client;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientLifecycleEvents;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientTickEvents;
import net.fabricmc.fabric.api.client.networking.v1.ClientLoginConnectionEvents;
import net.fabricmc.fabric.api.client.networking.v1.ClientPlayConnectionEvents;
import net.fabricmc.fabric.api.client.networking.v1.ClientPlayNetworking;
import net.minecraft.client.Minecraft;
import net.minecraft.client.multiplayer.ServerData;
import net.minecraft.client.multiplayer.ServerList;
import cl.coco.minecraft.CocoProtocol;

public final class CocoSessionBridge implements ClientModInitializer {
    private static final Pattern ACTION = Pattern.compile("\\\"action\\\"\\s*:\\s*\\\"([^\\\"]*)");
    private static final Pattern ADDRESS = Pattern.compile("\\\"address\\\"\\s*:\\s*\\\"([^\\\"]+)");
    private static Path stateFile;
    private int ticks;
    private boolean closing;

    @Override public void onInitializeClient() {
        long pid = ProcessHandle.current().pid();
        stateFile = Path.of(System.getenv("LOCALAPPDATA"), "CocoMinecraftUpdater", "session", pid + ".json");
        try {
            Files.deleteIfExists(stateFile);
        } catch (IOException ignored) {
            // A stale file must never close a new session if Windows reuses a PID.
        }
        ClientTickEvents.END_CLIENT_TICK.register(mc -> {
            if (!closing && ++ticks % 10 == 0 && shouldCloseMinecraft()) {
                closing = true;
                mc.stop();
            }
        });
        ClientLifecycleEvents.CLIENT_STARTED.register(mc -> {
            installServerEntry(mc);
            // El host debe aceptar nodos mientras Minecraft este abierto. Los
            // clientes conservan el flujo historico: solo revisan al conectar.
            if (Files.isRegularFile(mc.gameDirectory.toPath().resolve("config").resolve("coco-host.json"))) {
                launchUpdater(mc.gameDirectory.toPath(), pid);
            }
        });
        // INIT happens before registry synchronization. A client missing a newly
        // added content mod is rejected during that synchronization and never
        // reaches the play JOIN event.
        ClientLoginConnectionEvents.INIT.register((listener, mc) ->
            launchUpdater(mc.gameDirectory.toPath(), pid));
        ClientPlayConnectionEvents.JOIN.register((listener, sender, mc) -> {
            ClientPlayNetworking.send(new CocoProtocol.Hello(CocoProtocol.PACK_ID, CocoProtocol.PACK_VERSION));
        });
    }

    private static void launchUpdater(Path gameDir, long pid) {
        Path exe = Path.of(System.getenv("LOCALAPPDATA"), "CocoMinecraftUpdater", "CocoUpdater.exe");
        if (!Files.isRegularFile(exe)) {
            return;
        }
        try {
            new ProcessBuilder(exe.toString(), "-GameDir", gameDir.toString(), "-MinecraftPid", Long.toString(pid),
                "-SessionStatePath", stateFile.toString(), "-Silent").start();
        } catch (IOException e) {
            // El Gate explicará cómo instalarlo si este cliente intenta entrar desactualizado.
        }
    }

    private static boolean shouldCloseMinecraft() {
        if (!Files.isRegularFile(stateFile)) return false;
        try {
            String json = Files.readString(stateFile, StandardCharsets.UTF_8);
            return "closeMinecraft".equals(value(ACTION, json, ""));
        } catch (Exception ignored) { return false; }
    }

    private static void installServerEntry(Minecraft minecraft) {
        Path config = minecraft.gameDirectory.toPath().resolve("config").resolve("coco-network.json");
        if (!Files.isRegularFile(config)) return;
        try {
            String json = Files.readString(config, StandardCharsets.UTF_8);
            String address = value(ADDRESS, json, "");
            if (address.isBlank()) return;
            ServerList servers = new ServerList(minecraft);
            servers.load();
            ServerData desired = new ServerData("Coco Minecraft", address, ServerData.Type.OTHER);
            boolean replaced = false;
            for (int i = 0; i < servers.size(); i++) {
                ServerData current = servers.get(i);
                if ("Coco Minecraft".equals(current.name)) {
                    if (!address.equals(current.ip)) servers.replace(i, desired);
                    replaced = true;
                    break;
                }
            }
            if (!replaced) servers.add(desired, false);
            servers.save();
        } catch (Exception ignored) {
            // Un servers.dat bloqueado o antiguo no debe impedir arrancar Minecraft.
        }
    }

    private static String value(Pattern pattern, String input, String fallback) {
        Matcher matcher = pattern.matcher(input);
        return matcher.find() ? matcher.group(1).replace("\\n", " ").replace("\\\"", "\"") : fallback;
    }
}
