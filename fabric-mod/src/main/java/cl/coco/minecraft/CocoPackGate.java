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
        // The main entrypoint is delivered reliably even when a launcher misses
        // client lifecycle callbacks. The launcher itself checks EnvType.CLIENT.
        CocoUpdaterLauncher.initializeEarly();
        PayloadTypeRegistry.serverboundPlay().register(CocoProtocol.Hello.TYPE, CocoProtocol.Hello.CODEC);
        ServerPlayConnectionEvents.JOIN.register((listener, sender, server) ->
            waiting.put(listener.getPlayer().getUUID(), server.getTickCount() + 160L));
        ServerPlayConnectionEvents.DISCONNECT.register((listener, server) -> waiting.remove(listener.getPlayer().getUUID()));
        ServerPlayNetworking.registerGlobalReceiver(CocoProtocol.Hello.TYPE, (payload, context) -> {
            var player = context.player();
            if (!CocoProtocol.PACK_ID.equals(payload.packId()) || !CocoProtocol.PACK_VERSION.equals(payload.version())) {
                player.connection.disconnect(Component.literal("\u00a75\u2726 COCO PACK DESACTUALIZADO \u2726\n\u00a7fTu version: \u00a7d" + payload.version()
                    + "\u00a7f  -  Servidor: \u00a7d" + CocoProtocol.PACK_VERSION
                    + "\n\n\u00a7fCoco Updater se abrira y cerrara Minecraft automaticamente."
                    + "\n\u00a7fEspera \u00a7aTODO LISTO \u00a7fy pulsa \u00a7aACEPTAR\u00a7f."));
            } else {
                waiting.remove(player.getUUID());
            }
        });
        ServerTickEvents.END_SERVER_TICK.register(server -> waiting.entrySet().removeIf(entry -> {
            if (server.getTickCount() < entry.getValue()) return false;
            var player = server.getPlayerList().getPlayer(entry.getKey());
            if (player != null) player.connection.disconnect(Component.literal(
                "\u00a75\u2726 FALTA COCO SESSION BRIDGE \u2726\n\u00a7fEjecuta \u00a7dCocoUpdater.exe \u00a7funa vez y vuelve a abrir Minecraft."));
            return true;
        }));
    }
}
