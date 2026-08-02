package cl.coco.valorant;

import com.mojang.blaze3d.platform.InputConstants;
import net.minecraft.client.KeyMapping;
import net.minecraft.client.Minecraft;
import net.minecraftforge.api.distmarker.Dist;
import net.minecraftforge.client.event.RegisterKeyMappingsEvent;
import net.minecraftforge.event.TickEvent;
import net.minecraftforge.eventbus.api.SubscribeEvent;
import net.minecraftforge.fml.common.Mod;
import org.lwjgl.glfw.GLFW;

@Mod.EventBusSubscriber(modid = CocoValorantTools.MOD_ID, value = Dist.CLIENT, bus = Mod.EventBusSubscriber.Bus.MOD)
public final class CocoValorantClient {
    private static final KeyMapping MENU_KEY = new KeyMapping(
        "key.coco_valorant_tools.menu",
        InputConstants.Type.KEYSYM,
        GLFW.GLFW_KEY_M,
        "key.categories.coco_valorant_tools");

    private CocoValorantClient() {
    }

    @SubscribeEvent
    public static void registerKeyMappings(RegisterKeyMappingsEvent event) {
        event.register(MENU_KEY);
    }

    @Mod.EventBusSubscriber(modid = CocoValorantTools.MOD_ID, value = Dist.CLIENT)
    public static final class ClientEvents {
        private ClientEvents() {
        }

        @SubscribeEvent
        public static void onClientTick(TickEvent.ClientTickEvent event) {
            if (event.phase != TickEvent.Phase.END || !MENU_KEY.consumeClick()) {
                return;
            }
            Minecraft minecraft = Minecraft.getInstance();
            if (minecraft.player != null && minecraft.player.connection != null) {
                minecraft.player.connection.sendCommand("coco menu");
            }
        }
    }
}
