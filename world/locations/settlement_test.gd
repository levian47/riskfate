extends "res://scenes/hero_web_test.gd"

# RF-DEV-002: bounded graphics test, not an approved world scale or location system.
const MAP_CELLS := Vector2i(64, 48)
const SPAWN := Vector2(1024, 864)
const TERRAIN_LAYOUT := "res://world/tilesets/settlement_v1/terrain_layout.json"
const GRASS := preload("res://world/tilesets/settlement_v1/grass_32.png")
const DIRT := preload("res://world/tilesets/settlement_v1/dirt_32.png")
const TRANSITIONS := preload("res://world/tilesets/settlement_v1/dirt_grass_47_atlas.png")
const NEIGHBORS := [Vector2i.UP, Vector2i(1, -1), Vector2i.RIGHT,
    Vector2i(1, 1), Vector2i.DOWN, Vector2i(-1, 1), Vector2i.LEFT, Vector2i(-1, -1)]
# Foot anchors and polygons from RF-GRAPHICS-004 metadata.json, translated below.
# Kept in the runtime script so the source-art directory remains excluded from export.
const PROPS := {
    "tree_large": {"texture": preload("res://world/environment/settlement_v1/tree_large.png"),
        "pivot": Vector2(112, 252), "polygon": [Vector2(94, 229), Vector2(129, 229),
            Vector2(138, 245), Vector2(112, 252), Vector2(84, 245)]},
    "well": {"texture": preload("res://world/environment/settlement_v1/well.png"),
        "pivot": Vector2(64, 150), "polygon": [Vector2(17, 124), Vector2(30, 107),
            Vector2(96, 107), Vector2(111, 124), Vector2(99, 149), Vector2(31, 149)]},
    "fence_horizontal": {"texture": preload("res://world/environment/settlement_v1/fence_horizontal.png"),
        "pivot": Vector2(48, 32), "polygon": [Vector2(0, 17), Vector2(96, 17), Vector2(96, 32), Vector2(0, 32)]},
    "fence_vertical": {"texture": preload("res://world/environment/settlement_v1/fence_vertical.png"),
        "pivot": Vector2(12, 64), "polygon": [Vector2(1, 0), Vector2(23, 0), Vector2(23, 64), Vector2(1, 64)]},
    "fence_corner": {"texture": preload("res://world/environment/settlement_v1/fence_corner.png"),
        "pivot": Vector2(108, 96), "polygon": [Vector2(0, 79), Vector2(97, 79),
            Vector2(97, 0), Vector2(119, 0), Vector2(119, 85), Vector2(108, 96), Vector2(0, 96)]}
}

var ground: TileMapLayer
var paths: TileMapLayer
var actors: Node2D
var player: CharacterBody2D
var terrain_regions: Dictionary = {}
var dirt_cells: Dictionary = {}


func _ready() -> void:
    super._ready()
    # Reuse the tested input, UI, atlas and camera; only this scene adds physics.
    for connection in _scene_switch.pressed.get_connections():
        _scene_switch.pressed.disconnect(connection["callable"])
    _scene_switch.text = "Герой"
    _scene_switch.pressed.connect(func():
        _clear_touch()
        get_tree().change_scene_to_file("res://scenes/hero_web_test.tscn")
    )
    _build_terrain()
    actors = Node2D.new()
    actors.name = "Actors"
    actors.y_sort_enabled = true
    grid.add_child(actors)
    hero.reparent(actors)
    _add_prop("tree_large", Vector2(832, 928))
    _add_prop("tree_large", Vector2(912, 624))
    _add_prop("tree_large", Vector2(1328, 688))
    _add_prop("tree_large", Vector2(1280, 1200))
    _add_prop("well", Vector2(1152, 832))
    for x in [812, 908, 1100, 1196]:
        _add_prop("fence_horizontal", Vector2(x, 1008))
    _add_prop("fence_corner", Vector2(1352, 1008))
    _add_prop("fence_vertical", Vector2(1352, 912))
    _build_player()
    _add_boundaries()
    follow_camera.limit_left = 0
    follow_camera.limit_top = 0
    follow_camera.limit_right = MAP_CELLS.x * TILE_SIZE
    follow_camera.limit_bottom = MAP_CELLS.y * TILE_SIZE
    _sync_player()
    _set_zoom(1)


func _build_terrain() -> void:
    var tiles := TileSet.new()
    tiles.tile_size = Vector2i(TILE_SIZE, TILE_SIZE)
    for texture in [GRASS, DIRT, TRANSITIONS]:
        var source := TileSetAtlasSource.new()
        source.texture = texture
        source.texture_region_size = tiles.tile_size
        tiles.add_source(source)
    (tiles.get_source(0) as TileSetAtlasSource).create_tile(Vector2i.ZERO)
    (tiles.get_source(1) as TileSetAtlasSource).create_tile(Vector2i.ZERO)
    var layout: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(TERRAIN_LAYOUT))
    for tile in layout["tiles"]:
        var rect: Array = tile["rect"]
        var cell := Vector2i(int(rect[0]) / TILE_SIZE, int(rect[1]) / TILE_SIZE)
        terrain_regions[int(tile["neighbor_bits"])] = cell
        (tiles.get_source(2) as TileSetAtlasSource).create_tile(cell)
    ground = TileMapLayer.new()
    ground.name = "Grass"
    ground.tile_set = tiles
    ground.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    ground.z_index = -2
    grid.add_child(ground)
    paths = TileMapLayer.new()
    paths.name = "Dirt"
    paths.tile_set = tiles
    paths.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    paths.z_index = -1
    grid.add_child(paths)
    for y in MAP_CELLS.y:
        for x in MAP_CELLS.x:
            ground.set_cell(Vector2i(x, y), 0, Vector2i.ZERO)
    # A plaza, narrow connecting paths and separate patches expose inner/outer corners.
    for rect in [Rect2i(29, 23, 11, 7), Rect2i(19, 26, 25, 2), Rect2i(31, 17, 2, 18),
            Rect2i(22, 18, 5, 4), Rect2i(37, 33, 6, 3), Rect2i(25, 20, 7, 1)]:
        for y in range(rect.position.y, rect.end.y):
            for x in range(rect.position.x, rect.end.x):
                dirt_cells[Vector2i(x, y)] = true
    for cell in dirt_cells:
        var mask := _terrain_mask(cell)
        # The solid tile is identical to atlas mask 255; use the supplied standalone PNG.
        paths.set_cell(cell, 1 if mask == 255 else 2,
            Vector2i.ZERO if mask == 255 else terrain_regions[mask])


func _terrain_mask(cell: Vector2i) -> int:
    var mask := 0
    for bit in NEIGHBORS.size():
        if dirt_cells.has(cell + NEIGHBORS[bit]):
            mask |= 1 << bit
    # A diagonal matters only when both of its cardinal neighbors are dirt.
    for bit in [1, 3, 5, 7]:
        if (mask & (1 << (bit - 1))) == 0 or (mask & (1 << ((bit + 1) % 8))) == 0:
            mask &= ~(1 << bit)
    return mask


func _add_prop(kind: String, foot: Vector2) -> StaticBody2D:
    var spec: Dictionary = PROPS[kind]
    var body := StaticBody2D.new()
    body.name = kind
    body.position = foot
    body.collision_layer = 1
    body.collision_mask = 0
    actors.add_child(body)
    var sprite := Sprite2D.new()
    sprite.name = "Sprite"
    sprite.texture = spec["texture"]
    sprite.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
    sprite.centered = false
    sprite.offset = -spec["pivot"]
    body.add_child(sprite)
    var collision := CollisionPolygon2D.new()
    collision.name = "Footprint"
    var points := PackedVector2Array()
    for point in spec["polygon"]:
        points.append(point - spec["pivot"])
    collision.polygon = points
    body.add_child(collision)
    return body


func _build_player() -> void:
    player = CharacterBody2D.new()
    player.name = "PlayerBody"
    player.motion_mode = CharacterBody2D.MOTION_MODE_FLOATING
    player.collision_layer = 2
    player.collision_mask = 1
    player.position = SPAWN
    grid.add_child(player)
    var collision := CollisionShape2D.new()
    var circle := CircleShape2D.new()
    circle.radius = 6.0
    collision.shape = circle
    collision.position = Vector2(0, -5)
    player.add_child(collision)


func _add_boundaries() -> void:
    var boundary := StaticBody2D.new()
    boundary.name = "TestBounds"
    boundary.collision_mask = 0
    grid.add_child(boundary)
    var extent := Vector2(MAP_CELLS * TILE_SIZE)
    for rect in [Rect2(-32, -32, extent.x + 64, 32), Rect2(-32, extent.y, extent.x + 64, 32),
            Rect2(-32, 0, 32, extent.y), Rect2(extent.x, 0, 32, extent.y)]:
        var collision := CollisionShape2D.new()
        var shape := RectangleShape2D.new()
        shape.size = rect.size
        collision.shape = shape
        collision.position = rect.get_center()
        boundary.add_child(collision)


func _physics_process(_delta: float) -> void:
    if player == null:
        return
    var direction := _movement_direction()
    player.velocity = direction * WALK_SPEED
    player.move_and_slide()
    _sync_player()
    _set_facing(direction)


func _sync_player() -> void:
    _world_position = player.position
    hero.position = player.position.round()
    follow_camera.position = hero.position + Vector2(0, -30)


func _draw_grid() -> void:
    pass # The original laboratory keeps its grid; settlement uses real terrain.


func _refresh_status() -> void:
    super._refresh_status()
    if _status_label != null:
        _status_label.text = "%s · ×%d · поселення (тест)" % [DIRECTION_NAMES[_facing_index], _zoom_level]
