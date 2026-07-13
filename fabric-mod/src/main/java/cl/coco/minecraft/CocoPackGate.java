package cl.coco.minecraft;

import java.util.Map;
import java.util.UUID;
import java.util.concurrent.ConcurrentHashMap;

import net.fabricmc.api.ModInitializer;
import net.fabricmc.fabric.api.event.lifecycle.v1.ServerTickEvents;
import net.fabricmc.fabric.api.networking.v1.PayloadTypeRegistry;
import net.fabricmc.fabric.api.networking.v1.ServerPlayConnectionEvents;
import net.fabricmc.fabric.api.networking.v1.ServerPlayNetworking;
import net.minecraft.network.chat.Component;

public final class CocoPackGate implements ModInitializer {
    private final Map<UUID, Long> waiting = new ConcurrentHashMap<>();

    @Override public void onInitialize() {
        PayloadTypeRegistry.serverboundPlay().register(CocoProtocol.Hello.TYPE, CocoProtocol.Hello.CODEC);
        ServerPlayConnectionEvents.JOIN.register((listener, sender, server) ->
            waiting.put(listener.getPlayer().getUUID(), server.getTickCount() + 160L));
        ServerPlayConnectionEvents.DISCONNECT.register((listener, server) -> waiting.remove(listener.getPlayer().getUUID()));
        ServerPlayNetworking.registerGlobalReceiver(CocoProtocol.Hello.TYPE, (payload, context) -> {
            var player = context.player();
            if (!CocoProtocol.PACK_ID.equals(payload.packId()) || !CocoProtocol.PACK_VERSION.equals(payload.version())) {
                player.connection.disconnect(Component.literal("§5✦ COCO PACK DESACTUALIZADO ✦\n§fTu versión: §d" + payload.version()
                    + "§f  •  Servidor: §d" + CocoProtocol.PACK_VERSION
                    + "\n\n§fCierra Minecraft. Coco Updater terminará la actualización automáticamente."));
            } else {
                waiting.remove(player.getUUID());
            }
        });
        ServerTickEvents.END_SERVER_TICK.register(server -> waiting.entrySet().removeIf(entry -> {
            if (server.getTickCount() < entry.getValue()) return false;
            var player = server.getPlayerList().getPlayer(entry.getKey());
            if (player != null) player.connection.disconnect(Component.literal(
                "§5✦ FALTA COCO SESSION BRIDGE ✦\n§fEjecuta §dCocoUpdater.exe §funa vez y vuelve a abrir Minecraft."));
            return true;
        }));
    }
}
