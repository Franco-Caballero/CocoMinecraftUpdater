# Keep one reusable-in-practice Orb of Origin available to every connected player.
# The Origins item consumes itself; the next server tick restores it.
execute as @a unless entity @s[nbt={Inventory:[{id:"origins:orb_of_origin"}]}] run give @s origins:orb_of_origin 1
execute as @a unless entity @s[nbt={Inventory:[{id:"lrtactical:melee"}]}] run give @s lrtactical:melee{MeleeWeaponId:"wtyj:eternal_karambit"} 1
