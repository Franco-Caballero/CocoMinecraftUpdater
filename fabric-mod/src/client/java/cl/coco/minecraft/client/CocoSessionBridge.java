package cl.coco.minecraft.client;

import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.util.regex.Matcher;
import java.util.regex.Pattern;

import net.fabricmc.api.ClientModInitializer;
import net.fabricmc.fabric.api.client.event.lifecycle.v1.ClientTickEvents;
import net.fabricmc.fabric.api.client.networking.v1.ClientPlayConnectionEvents;
import net.fabricmc.fabric.api.client.networking.v1.ClientPlayNetworking;
import net.fabricmc.fabric.api.client.rendering.v1.hud.HudElementRegistry;
import net.minecraft.client.Minecraft;
import net.minecraft.resources.Identifier;
import net.minecraft.util.CommonColors;
import cl.coco.minecraft.CocoProtocol;

public final class CocoSessionBridge implements ClientModInitializer {
    private static final Pattern MESSAGE = Pattern.compile("\\\"message\\\"\\s*:\\s*\\\"([^\\\"]*)");
    private static final Pattern DETAIL = Pattern.compile("\\\"detail\\\"\\s*:\\s*\\\"([^\\\"]*)");
    private static final Pattern PROGRESS = Pattern.compile("\\\"progress\\\"\\s*:\\s*(\\d+)");
    private static volatile State state = new State("Comprobando Coco Pack…", "Conectando con GitHub", 0, true);
    private static Path stateFile;
    private int ticks;

    @Override public void onInitializeClient() {
        var client = Minecraft.getInstance();
        long pid = ProcessHandle.current().pid();
        stateFile = Path.of(System.getenv("LOCALAPPDATA"), "CocoMinecraftUpdater", "session", pid + ".json");
        launchUpdater(client.gameDirectory.toPath(), pid);

        ClientTickEvents.END_CLIENT_TICK.register(mc -> {
            if (++ticks % 10 == 0) readState();
        });
        ClientPlayConnectionEvents.JOIN.register((listener, sender, mc) ->
            ClientPlayNetworking.send(new CocoProtocol.Hello(CocoProtocol.PACK_ID, CocoProtocol.PACK_VERSION)));
        HudElementRegistry.addLast(Identifier.fromNamespaceAndPath("coco", "update_progress"), (graphics, delta) -> {
            State s = state;
            if (!s.visible) return;
            int width = Math.min(460, graphics.guiWidth() - 36);
            int x = (graphics.guiWidth() - width) / 2;
            int y = 24;
            graphics.fill(x - 8, y - 8, x + width + 8, y + 55, 0xDA160D25);
            graphics.fill(x, y + 34, x + width, y + 45, 0xFF3A2451);
            int fill = Math.max(4, width * Math.max(0, Math.min(100, s.progress)) / 100);
            graphics.fill(x, y + 34, x + fill, y + 45, 0xFFB15CFF);
            graphics.pose().pushMatrix();
            graphics.pose().scale(1.35f);
            graphics.centeredText(Minecraft.getInstance().font, "✦ " + s.message + " ✦",
                (int)(graphics.guiWidth()/2/1.35f), (int)(y/1.35f), 0xFFE6C7FF);
            graphics.pose().popMatrix();
            graphics.centeredText(Minecraft.getInstance().font, s.detail + "  •  " + s.progress + "%", graphics.guiWidth()/2, y + 16, CommonColors.WHITE);
        });
    }

    private static void launchUpdater(Path gameDir, long pid) {
        Path exe = Path.of(System.getenv("LOCALAPPDATA"), "CocoMinecraftUpdater", "CocoUpdater.exe");
        if (!Files.isRegularFile(exe)) {
            state = new State("Coco Updater no está instalado", "Ejecuta CocoUpdater.exe una vez", 0, true);
            return;
        }
        try {
            new ProcessBuilder(exe.toString(), "-GameDir", gameDir.toString(), "-MinecraftPid", Long.toString(pid),
                "-SessionStatePath", stateFile.toString(), "-Silent").start();
        } catch (IOException e) {
            state = new State("No se pudo iniciar Coco Updater", e.getMessage(), 0, true);
        }
    }

    private static void readState() {
        if (!Files.isRegularFile(stateFile)) return;
        try {
            String json = Files.readString(stateFile, StandardCharsets.UTF_8);
            state = new State(value(MESSAGE, json, "Comprobando…"), value(DETAIL, json, ""),
                Integer.parseInt(value(PROGRESS, json, "0")), !json.contains("\"visible\":false"));
        } catch (Exception ignored) { }
    }

    private static String value(Pattern pattern, String input, String fallback) {
        Matcher matcher = pattern.matcher(input);
        return matcher.find() ? matcher.group(1).replace("\\n", " ").replace("\\\"", "\"") : fallback;
    }
    private record State(String message, String detail, int progress, boolean visible) { }
}
