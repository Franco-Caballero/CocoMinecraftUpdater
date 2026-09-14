# Compatibilidad con bootstrappers antiguos.
#
# Versiones viejas de Coco validan que este archivo exista dentro del engine.
# Desde esta version no contiene ni expone ninguna funcion para desactivar o
# reactivar Windows Defender: Coco usa exclusivamente exclusiones persistentes.

$script:CocoDefenderControlCompatibility = 'exclusions-only'
