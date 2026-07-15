package cl.coco.minecraft.client;

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
import cl.coco.minecraft.CocoUpdaterLauncher;

public final class CocoSessionBridge implements ClientModInitializer {
    private static final Pattern ACTION = Pattern.compile("\\\"action\\\"\\s*:\\s*\\\"([^\\\"]*)");
    private static final Pattern ADDRESS = Pattern.compile("\\\"address\\\"\\s*:\\s*\\\"([^\\\"]+)");
    private static Path stateFile;
    private static boolean host;
    private static boolean serverEntryInstalled;
    private int ticks;
    private boolean closing;

    @Override public void onInitializeClient() {
        stateFile = CocoUpdaterLauncher.stateFile();
        CocoUpdaterLauncher.logClientEntrypoint();
        CocoUpdaterLauncher.initializeEarly();
        host = Files.isRegularFile(Path.of(System.getProperty("user.dir"), "config", "coco-host.json"));
        ClientTickEvents.END_CLIENT_TICK.register(mc -> {
            ticks++;
            // The main entrypoint launches early. Ticks verify the exact
            // gameDirectory and retry if the child did not report ready.
            if (ticks % 20 == 0) {
                host = Files.isRegularFile(mc.gameDirectory.toPath().resolve("config").resolve("coco-host.json"));
                serverEntryInstalled = installServerEntry(mc);
                CocoUpdaterLauncher.ensureNetworkCheck(mc.gameDirectory.toPath(), "client-tick");
            }
            if (!closing && ticks % 10 == 0 && shouldCloseMinecraft()) {
                closing = true;
                mc.stop();
            }
            if (!serverEntryInstalled && ticks % 100 == 0) serverEntryInstalled = installServerEntry(mc);
        });
        ClientLifecycleEvents.CLIENT_STARTED.register(mc -> {
            host = Files.isRegularFile(mc.gameDirectory.toPath().resolve("config").resolve("coco-host.json"));
            serverEntryInstalled = installServerEntry(mc);
            CocoUpdaterLauncher.ensureNetworkCheck(mc.gameDirectory.toPath(), "client-started");
        });
        // INIT happens before registry synchronization. A client missing a newly
        // added content mod is rejected during that synchronization and never
        // reaches the play JOIN event.
        ClientLoginConnectionEvents.INIT.register((listener, mc) ->
            CocoUpdaterLauncher.launchFullCheck(mc.gameDirectory.toPath(), "login-init"));
        ClientPlayConnectionEvents.JOIN.register((listener, sender, mc) -> {
            ClientPlayNetworking.send(new CocoProtocol.Hello(CocoProtocol.PACK_ID, CocoProtocol.PACK_VERSION));
            if (host) CocoUpdaterLauncher.ensureNetworkCheck(mc.gameDirectory.toPath(), "host-join");
        });
    }

    private static boolean shouldCloseMinecraft() {
        if (!Files.isRegularFile(stateFile)) return false;
        try {
            String json = Files.readString(stateFile, StandardCharsets.UTF_8);
            return "closeMinecraft".equals(value(ACTION, json, ""));
        } catch (Exception ignored) { return false; }
    }

    private static boolean installServerEntry(Minecraft minecraft) {
        Path config = minecraft.gameDirectory.toPath().resolve("config").resolve("coco-network.json");
        if (!Files.isRegularFile(config)) return false;
        try {
            String json = Files.readString(config, StandardCharsets.UTF_8);
            String address = value(ADDRESS, json, "");
            if (address.isBlank()) return false;
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
            return true;
        } catch (Exception ignored) {
            // A locked or old servers.dat must not prevent Minecraft startup.
            return false;
        }
    }

    private static String value(Pattern pattern, String input, String fallback) {
        Matcher matcher = pattern.matcher(input);
        return matcher.find() ? matcher.group(1).replace("\\n", " ").replace("\\\"", "\"") : fallback;
    }
}
