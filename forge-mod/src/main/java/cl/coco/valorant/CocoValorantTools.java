package cl.coco.valorant;

import com.mojang.brigadier.CommandDispatcher;
import com.mojang.brigadier.arguments.StringArgumentType;
import com.mojang.brigadier.context.CommandContext;
import net.minecraft.ChatFormatting;
import net.minecraft.commands.CommandSourceStack;
import net.minecraft.commands.Commands;
import net.minecraft.core.BlockPos;
import net.minecraft.network.chat.ClickEvent;
import net.minecraft.network.chat.Component;
import net.minecraft.network.chat.MutableComponent;
import net.minecraft.resources.ResourceLocation;
import net.minecraft.server.MinecraftServer;
import net.minecraft.server.level.ServerLevel;
import net.minecraft.server.level.ServerPlayer;
import net.minecraft.world.item.Item;
import net.minecraft.world.item.ItemStack;
import net.minecraft.world.item.BlockItem;
import net.minecraft.world.item.BucketItem;
import net.minecraft.world.level.GameType;
import net.minecraft.world.level.GameRules;
import net.minecraft.world.level.block.state.BlockState;
import net.minecraftforge.common.MinecraftForge;
import net.minecraftforge.event.RegisterCommandsEvent;
import net.minecraftforge.event.TickEvent;
import net.minecraftforge.event.entity.player.PlayerEvent;
import net.minecraftforge.event.entity.player.PlayerInteractEvent;
import net.minecraftforge.event.level.BlockEvent;
import net.minecraftforge.event.server.ServerStartedEvent;
import net.minecraftforge.eventbus.api.SubscribeEvent;
import net.minecraftforge.fml.common.Mod;
import net.minecraftforge.registries.ForgeRegistries;

import java.util.ArrayList;
import java.util.Comparator;
import java.util.List;
import java.util.Locale;

@Mod(CocoValorantTools.MOD_ID)
public final class CocoValorantTools {
    public static final String MOD_ID = "coco_valorant_tools";
    private static final String TAG_TEAM_T = "coco_team_t";
    private static final String TAG_TEAM_CT = "coco_team_ct";
    private static final String TAG_TEAM_SPEC = "coco_team_spec";
    private static final String TAG_READY = "coco_ready";
    private static final ResourceLocation ORB_ID = new ResourceLocation("origins", "orb_of_origin");

    private static final int HOST_PERMISSION = 2;
    private static final int COMMAND_PERMISSION = 4;

    private static boolean editMode;
    private static long maintenanceTicks;

    public CocoValorantTools() {
        MinecraftForge.EVENT_BUS.register(this);
    }

    @SubscribeEvent
    public void onRegisterCommands(RegisterCommandsEvent event) {
        registerCommands(event.getDispatcher());
    }

    @SubscribeEvent
    public void onServerStarted(ServerStartedEvent event) {
        editMode = false;
        applyCompetitiveRules(event.getServer());
    }

    @SubscribeEvent
    public void onPlayerLogin(PlayerEvent.PlayerLoggedInEvent event) {
        if (event.getEntity() instanceof ServerPlayer player) {
            ensureOrb(player, false);
            applyLobbyProtection(player);
            sendWelcome(player);
        }
    }

    @SubscribeEvent
    public void onServerTick(TickEvent.ServerTickEvent event) {
        if (event.phase != TickEvent.Phase.END || ++maintenanceTicks % 40 != 0) {
            return;
        }

        MinecraftServer server = event.getServer();
        for (ServerPlayer player : server.getPlayerList().getPlayers()) {
            ensureOrb(player, false);
        }
    }

    @SubscribeEvent
    public void onBreakBlock(BlockEvent.BreakEvent event) {
        if (event.getPlayer() instanceof ServerPlayer player && !canEditMap(player)) {
            event.setCanceled(true);
            player.sendSystemMessage(Component.literal("El mapa está protegido. El host puede activar el modo edición desde M."));
        }
    }

    @SubscribeEvent
    public void onPlaceBlock(BlockEvent.EntityPlaceEvent event) {
        if (event.getEntity() instanceof ServerPlayer player && !canEditMap(player)) {
            event.setCanceled(true);
            player.sendSystemMessage(Component.literal("No puedes colocar bloques durante la partida."));
        }
    }

    @SubscribeEvent
    public void onToolModification(BlockEvent.BlockToolModificationEvent event) {
        if (event.getPlayer() instanceof ServerPlayer player && !canEditMap(player)) {
            event.setCanceled(true);
        }
    }

    @SubscribeEvent
    public void onMapInteract(PlayerInteractEvent.RightClickBlock event) {
        if (event.getEntity() instanceof ServerPlayer player && !canEditMap(player)) {
            ItemStack stack = event.getItemStack();
            if (stack.getItem() instanceof BlockItem || stack.getItem() instanceof BucketItem) {
                event.setCanceled(true);
                player.sendSystemMessage(Component.literal("El mapa está protegido: no puedes colocar bloques ni líquidos."));
            }
        }
    }

    @SubscribeEvent
    public void onFarmlandTrample(BlockEvent.FarmlandTrampleEvent event) {
        if (!editMode) {
            event.setCanceled(true);
        }
    }

    private static void registerCommands(CommandDispatcher<CommandSourceStack> dispatcher) {
        dispatcher.register(Commands.literal("coco")
            .then(Commands.literal("menu")
                .executes(context -> showMenu(context.getSource().getPlayerOrException())))
            .then(Commands.literal("help")
                .executes(context -> showHelp(context.getSource().getPlayerOrException())))
            .then(Commands.literal("agent")
                .executes(context -> openAgentMenu(context.getSource().getPlayerOrException())))
            .then(Commands.literal("ready")
                .executes(context -> toggleReady(context.getSource().getPlayerOrException())))
            .then(Commands.literal("team")
                .then(Commands.literal("t").executes(context -> chooseTeam(context.getSource().getPlayerOrException(), "t")))
                .then(Commands.literal("ct").executes(context -> chooseTeam(context.getSource().getPlayerOrException(), "ct")))
                .then(Commands.literal("spec").executes(context -> chooseTeam(context.getSource().getPlayerOrException(), "spec"))))
            .then(Commands.literal("host")
                .requires(source -> source.hasPermission(HOST_PERMISSION))
                .then(Commands.literal("start").executes(context -> hostStart(context, false)))
                .then(Commands.literal("force-start").executes(context -> hostStart(context, true)))
                .then(Commands.literal("balance").executes(context -> balanceTeams(context.getSource().getServer())))
                .then(Commands.literal("lobby").executes(context -> resetLobby(context.getSource().getServer())))
                .then(Commands.literal("save").executes(context -> runHostCommand(context.getSource(), "cs save")))
                .then(Commands.literal("edit").executes(context -> toggleEditMode(context.getSource().getPlayerOrException())))
                .then(Commands.literal("menu").executes(context -> showHostMenu(context.getSource().getPlayerOrException())))));
    }

    private static int showMenu(ServerPlayer player) {
        player.sendSystemMessage(Component.literal(""));
        player.sendSystemMessage(Component.literal("╔══ COCO VALORANT ══╗").withStyle(ChatFormatting.GOLD));
        player.sendSystemMessage(Component.literal("Rol: ").withStyle(ChatFormatting.GRAY)
            .append(Component.literal(player.hasPermissions(HOST_PERMISSION) ? "HOST" : "JUGADOR")
                .withStyle(player.hasPermissions(HOST_PERMISSION) ? ChatFormatting.RED : ChatFormatting.AQUA)));
        player.sendSystemMessage(line("Agente", button("[ELEGIR / CAMBIAR]", "/coco agent")));
        player.sendSystemMessage(line("Equipo actual", Component.literal(teamName(player)).withStyle(ChatFormatting.WHITE)));
        player.sendSystemMessage(Component.literal("  ")
            .append(button("[T]", "/coco team t"))
            .append(Component.literal("  "))
            .append(button("[CT]", "/coco team ct"))
            .append(Component.literal("  "))
            .append(button("[ESPECTADOR]", "/coco team spec")));
        player.sendSystemMessage(line("Estado", Component.literal(player.getTags().contains(TAG_READY) ? "LISTO" : "NO LISTO")
            .withStyle(player.getTags().contains(TAG_READY) ? ChatFormatting.GREEN : ChatFormatting.YELLOW)));
        player.sendSystemMessage(Component.literal("  ").append(button("[MARCAR LISTO / CANCELAR]", "/coco ready")));
        player.sendSystemMessage(Component.literal("Tienda: pulsa ").withStyle(ChatFormatting.GRAY)
            .append(Component.literal("B").withStyle(ChatFormatting.YELLOW))
            .append(Component.literal(" | menú Coco: pulsa ").withStyle(ChatFormatting.GRAY))
            .append(Component.literal("M").withStyle(ChatFormatting.YELLOW)));
        player.sendSystemMessage(Component.literal("  ").append(button("[CONTROLES Y REGLAS]", "/coco help")));
        if (player.hasPermissions(HOST_PERMISSION)) {
            player.sendSystemMessage(Component.literal("  ").append(button("[PANEL HOST]", "/coco host menu")));
        }
        player.sendSystemMessage(Component.literal("╚════════════════════╝").withStyle(ChatFormatting.GOLD));
        return 1;
    }

    private static int showHostMenu(ServerPlayer player) {
        showMenu(player);
        player.sendSystemMessage(Component.literal("PANEL HOST").withStyle(ChatFormatting.RED));
        player.sendSystemMessage(Component.literal("  ").append(button("[EQUILIBRAR EQUIPOS]", "/coco host balance")));
        player.sendSystemMessage(Component.literal("  ").append(button("[INICIAR CUANDO TODOS ESTÉN LISTOS]", "/coco host start")));
        player.sendSystemMessage(Component.literal("  ").append(button("[INICIAR PRUEBA]", "/coco host force-start")));
        player.sendSystemMessage(Component.literal("  ").append(button("[PREPARAR LOBBY]", "/coco host lobby")));
        player.sendSystemMessage(Component.literal("  ").append(button("[GUARDAR CONFIGURACIÓN CSmain]", "/coco host save")));
        player.sendSystemMessage(Component.literal("  ").append(button(editMode ? "[BLOQUEAR MAPA]" : "[MODO EDICIÓN DEL MAPA]", "/coco host edit")));
        return 1;
    }

    private static int showHelp(ServerPlayer player) {
        player.sendSystemMessage(Component.literal("CONTROLES Y REGLAS").withStyle(ChatFormatting.GOLD));
        player.sendSystemMessage(Component.literal("C = habilidad primaria | X = habilidad secundaria | R = recargar | Y = inspeccionar").withStyle(ChatFormatting.GRAY));
        player.sendSystemMessage(Component.literal("F = cuchillo | V = mira | B = tienda | G = recoger Spike | M = menú Coco").withStyle(ChatFormatting.GRAY));
        player.sendSystemMessage(Component.literal("El agente se elige antes de iniciar; el equipo puede cambiarse solo desde el lobby.").withStyle(ChatFormatting.GRAY));
        player.sendSystemMessage(Component.literal("El mapa está protegido: no se pueden romper ni colocar bloques.").withStyle(ChatFormatting.GRAY));
        player.sendSystemMessage(Component.literal("El host es el jugador con permisos de operador y tiene el panel adicional.").withStyle(ChatFormatting.GRAY));
        return 1;
    }

    private static int openAgentMenu(ServerPlayer player) {
        MinecraftServer server = player.getServer();
        if (server == null) {
            return 0;
        }
        int result = server.getCommands().performPrefixedCommand(
            player.createCommandSourceStack().withPermission(COMMAND_PERMISSION),
            "origin gui " + player.getName().getString() + " origins:origin");
        if (result == 0) {
            player.sendSystemMessage(Component.literal("No se pudo abrir la pantalla de agente. Usa /origin gui "
                + player.getName().getString() + " origins:origin como respaldo."));
        }
        return result;
    }

    private static int chooseTeam(ServerPlayer player, String team) {
        clearTeamTags(player);
        switch (team) {
            case "t" -> {
                player.addTag(TAG_TEAM_T);
                runPlayerCommand(player, "joint");
                player.sendSystemMessage(Component.literal("Equipo seleccionado: T."));
            }
            case "ct" -> {
                player.addTag(TAG_TEAM_CT);
                runPlayerCommand(player, "joinct");
                player.sendSystemMessage(Component.literal("Equipo seleccionado: CT."));
            }
            default -> {
                player.addTag(TAG_TEAM_SPEC);
                player.removeTag(TAG_READY);
                runPlayerCommand(player, "joinspec");
                player.sendSystemMessage(Component.literal("Modo espectador seleccionado."));
            }
        }
        showMenu(player);
        return 1;
    }

    private static int toggleReady(ServerPlayer player) {
        if (player.getTags().contains(TAG_TEAM_SPEC) || (!player.getTags().contains(TAG_TEAM_T) && !player.getTags().contains(TAG_TEAM_CT))) {
            player.sendSystemMessage(Component.literal("Primero selecciona T o CT."));
            return 0;
        }
        if (player.getTags().contains(TAG_READY)) {
            player.removeTag(TAG_READY);
            player.sendSystemMessage(Component.literal("Estado: no listo."));
        } else {
            player.addTag(TAG_READY);
            player.sendSystemMessage(Component.literal("Estado: LISTO."));
        }
        showMenu(player);
        return 1;
    }

    private static int hostStart(CommandContext<CommandSourceStack> context, boolean force) {
        MinecraftServer server = context.getSource().getServer();
        List<ServerPlayer> beforeAssignment = activePlayers(server);
        if (beforeAssignment.stream().noneMatch(player -> player.getTags().contains(TAG_TEAM_T) || player.getTags().contains(TAG_TEAM_CT))) {
            balanceTeams(server);
        } else {
            assignMissingTeams(server);
        }
        List<ServerPlayer> active = activePlayers(server);
        List<String> unassigned = active.stream()
            .filter(player -> !player.hasPermissions(HOST_PERMISSION) &&
                !player.getTags().contains(TAG_TEAM_SPEC) &&
                !player.getTags().contains(TAG_TEAM_T) &&
                !player.getTags().contains(TAG_TEAM_CT))
            .map(player -> player.getName().getString())
            .toList();
        if (!force && !unassigned.isEmpty()) {
            broadcast(server, Component.literal("Coco: faltan equipos por elegir: " + String.join(", ", unassigned) + "."));
            return 0;
        }
        long teams = active.stream().filter(player -> player.getTags().contains(TAG_TEAM_T) || player.getTags().contains(TAG_TEAM_CT)).count();
        long t = active.stream().filter(player -> player.getTags().contains(TAG_TEAM_T)).count();
        long ct = active.stream().filter(player -> player.getTags().contains(TAG_TEAM_CT)).count();
        if (teams < 2 || t == 0 || ct == 0) {
            broadcast(server, Component.literal("Coco: selecciona al menos un jugador T y uno CT antes de iniciar."));
            return 0;
        }
        List<String> notReady = active.stream()
            .filter(player -> (player.getTags().contains(TAG_TEAM_T) || player.getTags().contains(TAG_TEAM_CT)) && !player.getTags().contains(TAG_READY))
            .map(player -> player.getName().getString())
            .toList();
        if (!force && !notReady.isEmpty()) {
            broadcast(server, Component.literal("Coco: faltan jugadores listos: " + String.join(", ", notReady) + "."));
            return 0;
        }
        int result = runServerCommand(server, "cs start");
        if (result > 0) {
            broadcast(server, Component.literal(force ? "Coco: partida de prueba iniciada." : "Coco: partida iniciada."));
        } else {
            broadcast(server, Component.literal("Coco: CSmain no pudo iniciar la partida; revisa el mapa guardado."));
        }
        return result;
    }

    private static int assignMissingTeams(MinecraftServer server) {
        List<ServerPlayer> missing = activePlayers(server).stream()
            .filter(player -> !player.getTags().contains(TAG_TEAM_SPEC) &&
                !player.getTags().contains(TAG_TEAM_T) &&
                !player.getTags().contains(TAG_TEAM_CT))
            .sorted(Comparator.comparing(player -> player.getName().getString().toLowerCase(Locale.ROOT)))
            .toList();
        if (missing.isEmpty()) {
            return 0;
        }
        int t = (int) activePlayers(server).stream().filter(player -> player.getTags().contains(TAG_TEAM_T)).count();
        int ct = (int) activePlayers(server).stream().filter(player -> player.getTags().contains(TAG_TEAM_CT)).count();
        for (ServerPlayer player : missing) {
            String team = t <= ct ? "t" : "ct";
            chooseTeam(player, team);
            player.removeTag(TAG_READY);
            if (team.equals("t")) {
                t++;
            } else {
                ct++;
            }
        }
        broadcast(server, Component.literal("Coco: jugadores nuevos asignados automaticamente (T " + t + " / CT " + ct + ")."));
        return missing.size();
    }

    private static int balanceTeams(MinecraftServer server) {
        List<ServerPlayer> candidates = activePlayers(server).stream()
            .filter(player -> !player.getTags().contains(TAG_TEAM_SPEC))
            .sorted(Comparator.comparing(player -> player.getName().getString().toLowerCase(Locale.ROOT)))
            .toList();
        if (candidates.isEmpty()) {
            broadcast(server, Component.literal("Coco: no hay jugadores activos para equilibrar."));
            return 0;
        }
        int t = 0;
        int ct = 0;
        for (ServerPlayer player : candidates) {
            String team = t <= ct ? "t" : "ct";
            chooseTeam(player, team);
            player.removeTag(TAG_READY);
            if (team.equals("t")) {
                t++;
            } else {
                ct++;
            }
        }
        broadcast(server, Component.literal("Coco: equipos equilibrados automáticamente (T " + t + " / CT " + ct + ")."));
        return 1;
    }

    private static int resetLobby(MinecraftServer server) {
        for (ServerPlayer player : server.getPlayerList().getPlayers()) {
            clearTeamTags(player);
            player.removeTag(TAG_READY);
            applyLobbyProtection(player);
            player.sendSystemMessage(Component.literal("Coco: lobby preparado. Elige agente, equipo y pulsa LISTO."));
            showMenu(player);
        }
        broadcast(server, Component.literal("Coco: se limpió el estado del lobby. No se modificó ningún mundo."));
        return 1;
    }

    private static int toggleEditMode(ServerPlayer player) {
        editMode = !editMode;
        broadcast(player.getServer(), Component.literal(editMode
            ? "Coco: modo edición activado para el host; el resto sigue protegido."
            : "Coco: mapa bloqueado nuevamente."));
        showHostMenu(player);
        return 1;
    }

    private static int runHostCommand(CommandSourceStack source, String command) {
        int result = runServerCommand(source.getServer(), command);
        source.sendSuccess(() -> Component.literal("Coco ejecutó: /" + command), false);
        return result;
    }

    private static int runPlayerCommand(ServerPlayer player, String command) {
        MinecraftServer server = player.getServer();
        return server == null ? 0 : server.getCommands().performPrefixedCommand(
            player.createCommandSourceStack().withPermission(COMMAND_PERMISSION), command);
    }

    private static int runServerCommand(MinecraftServer server, String command) {
        return server.getCommands().performPrefixedCommand(
            server.createCommandSourceStack().withPermission(COMMAND_PERMISSION), command);
    }

    private static void sendWelcome(ServerPlayer player) {
        player.sendSystemMessage(Component.literal("Coco VALORANT listo. Pulsa M para abrir el menú; si no aparece, usa /coco menu.").withStyle(ChatFormatting.GREEN));
        showMenu(player);
    }

    private static void applyLobbyProtection(ServerPlayer player) {
        if (!player.hasPermissions(HOST_PERMISSION) && !isRoundParticipant(player)) {
            player.setGameMode(GameType.ADVENTURE);
        }
    }

    private static boolean isRoundParticipant(ServerPlayer player) {
        return player.getTags().contains(TAG_READY) &&
            (player.getTags().contains(TAG_TEAM_T) || player.getTags().contains(TAG_TEAM_CT));
    }

    private static void ensureOrb(ServerPlayer player, boolean forceMessage) {
        Item orb = ForgeRegistries.ITEMS.getValue(ORB_ID);
        if (orb == null || orb == ForgeRegistries.ITEMS.getValue(new ResourceLocation("minecraft", "air"))) {
            return;
        }
        boolean hasOrb = player.getInventory().items.stream().anyMatch(stack -> stack.is(orb)) ||
            player.getInventory().offhand.stream().anyMatch(stack -> stack.is(orb));
        if (hasOrb) {
            return;
        }
        ItemStack stack = new ItemStack(orb);
        if (!player.getInventory().add(stack)) {
            player.drop(stack, false);
        }
        if (forceMessage) {
            player.sendSystemMessage(Component.literal("Orb of Origin restaurado: puedes cambiar de agente cuando quieras."));
        }
    }

    private static void applyCompetitiveRules(MinecraftServer server) {
        for (ServerLevel level : server.getAllLevels()) {
            setRule(level, GameRules.RULE_DOFIRETICK, false, server);
            setRule(level, GameRules.RULE_MOBGRIEFING, false, server);
            setRule(level, GameRules.RULE_DOMOBSPAWNING, false, server);
            setRule(level, GameRules.RULE_DAYLIGHT, false, server);
            setRule(level, GameRules.RULE_WEATHER_CYCLE, false, server);
        }
    }

    private static void setRule(ServerLevel level, GameRules.Key<GameRules.BooleanValue> key, boolean value, MinecraftServer server) {
        level.getGameRules().getRule(key).set(value, server);
    }

    private static boolean canEditMap(ServerPlayer player) {
        return editMode && player.hasPermissions(HOST_PERMISSION);
    }

    private static List<ServerPlayer> activePlayers(MinecraftServer server) {
        return new ArrayList<>(server.getPlayerList().getPlayers());
    }

    private static void clearTeamTags(ServerPlayer player) {
        player.removeTag(TAG_TEAM_T);
        player.removeTag(TAG_TEAM_CT);
        player.removeTag(TAG_TEAM_SPEC);
    }

    private static String teamName(ServerPlayer player) {
        if (player.getTags().contains(TAG_TEAM_T)) {
            return "T";
        }
        if (player.getTags().contains(TAG_TEAM_CT)) {
            return "CT";
        }
        if (player.getTags().contains(TAG_TEAM_SPEC)) {
            return "Espectador";
        }
        return "Sin seleccionar";
    }

    private static MutableComponent line(String label, Component value) {
        return Component.literal(label + ": ").withStyle(ChatFormatting.GRAY).append(value);
    }

    private static MutableComponent button(String label, String command) {
        return Component.literal(label).withStyle(style -> style
            .withColor(ChatFormatting.AQUA)
            .withClickEvent(new ClickEvent(ClickEvent.Action.RUN_COMMAND, command)));
    }

    private static void broadcast(MinecraftServer server, Component message) {
        if (server == null) {
            return;
        }
        for (ServerPlayer player : server.getPlayerList().getPlayers()) {
            player.sendSystemMessage(message);
        }
    }
}
