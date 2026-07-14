package cl.coco.minecraft;

import net.minecraft.network.FriendlyByteBuf;
import net.minecraft.network.codec.ByteBufCodecs;
import net.minecraft.network.codec.StreamCodec;
import net.minecraft.network.protocol.common.custom.CustomPacketPayload;
import net.minecraft.resources.Identifier;

public final class CocoProtocol {
    public static final String PACK_ID = "coco-minecraft";
    public static final String PACK_VERSION = "0.5.13";

    private CocoProtocol() { }

    public record Hello(String packId, String version) implements CustomPacketPayload {
        public static final Type<Hello> TYPE = new Type<>(Identifier.fromNamespaceAndPath("coco", "pack_hello"));
        public static final StreamCodec<FriendlyByteBuf, Hello> CODEC = StreamCodec.composite(
            ByteBufCodecs.STRING_UTF8, Hello::packId,
            ByteBufCodecs.STRING_UTF8, Hello::version,
            Hello::new
        );
        @Override public Type<? extends CustomPacketPayload> type() { return TYPE; }
    }
}
