extends SceneTree

var _failures := 0
var _checks := 0


func _initialize() -> void:
    _run.call_deferred()


func _check(condition: bool, description: String) -> void:
    _checks += 1
    if not condition:
        _failures += 1
        push_error(description)


func _probe(scene: Control, start: Vector2, motion: Vector2, expected: String) -> void:
    var hit := KinematicCollision2D.new()
    var blocked: bool = scene.player.test_move(Transform2D(0, start), motion, hit)
    _check(blocked == not expected.is_empty(), "collision at " + str(start))
    if blocked and not expected.is_empty():
        _check(str(hit.get_collider().name).begins_with(expected), "correct blocker: " + expected)


func _drive(scene: Control, direction: Vector2, steps: int) -> void:
    scene._joystick_finger = 0
    scene._joystick_direction = direction
    for step in steps:
        await physics_frame
        scene._physics_process(1.0 / 60.0)
    scene._clear_touch()


func _run() -> void:
    var scene = load("res://world/locations/settlement_test.tscn").instantiate()
    root.add_child(scene)
    await process_frame
    scene.set_physics_process(false)
    await physics_frame
    await process_frame
    _check(scene.player != null and scene.actors.y_sort_enabled, "physics player and standard Y sort")
    _check(scene.hero.get_parent() == scene.actors, "hero participates in prop sorting")
    _check(scene.hero.offset == Vector2(-24, -62) and scene.hero.scale == Vector2.ONE,
        "approved unscaled hero anchor")
    _check(scene.ground.get_used_cells().size() == scene.MAP_CELLS.x * scene.MAP_CELLS.y,
        "grass covers test map")
    _check(scene.paths.get_used_cells().size() == scene.dirt_cells.size(), "every dirt cell placed")
    var layout: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(scene.TERRAIN_LAYOUT))
    _check(layout["bits"] == ["N", "NE", "E", "SE", "S", "SW", "W", "NW"], "declared neighbor bit order")
    _check(scene.terrain_regions.size() == 47, "all 47 atlas regions loaded")
    var atlas: TileSetAtlasSource = scene.paths.tile_set.get_source(2)
    for tile in layout["tiles"]:
        var region: Array = tile["rect"]
        var cell := Vector2i(int(region[0]) / 32, int(region[1]) / 32)
        _check(scene.terrain_regions[int(tile["neighbor_bits"])] == cell and atlas.has_tile(cell),
            "atlas mapping follows JSON rect " + str(tile["id"]))
    _check(not atlas.has_tile(Vector2i(7, 5)), "unused atlas cell excluded")
    # Exercise all raw neighbor combinations, independently filtering invalid diagonals.
    var saved_cells: Dictionary = scene.dirt_cells.duplicate()
    var normalized: Dictionary = {}
    for raw in 256:
        scene.dirt_cells.clear()
        var expected := raw
        for bit in 8:
            if raw & (1 << bit):
                scene.dirt_cells[scene.NEIGHBORS[bit]] = true
        for diagonal in [1, 3, 5, 7]:
            var cardinals: int = (1 << (diagonal - 1)) | (1 << ((diagonal + 1) % 8))
            if (raw & cardinals) != cardinals:
                expected &= ~(1 << diagonal)
        var mask: int = scene._terrain_mask(Vector2i.ZERO)
        _check(mask == expected and scene.terrain_regions.has(mask), "neighbor mask " + str(raw))
        normalized[mask] = true
    _check(normalized.size() == 47, "exactly 47 canonical transition states reachable")
    scene.dirt_cells = saved_cells
    var sources: Dictionary = {}
    for cell in scene.paths.get_used_cells():
        var mask: int = scene._terrain_mask(cell)
        var source: int = scene.paths.get_cell_source_id(cell)
        sources[source] = true
        _check(source == (1 if mask == 255 else 2), "solid/transition selection at " + str(cell))
        _check(scene.paths.get_cell_atlas_coords(cell) == (Vector2i.ZERO if mask == 255 else scene.terrain_regions[mask]),
            "placed atlas region at " + str(cell))
    _check(sources.has(1) and sources.has(2), "both dirt PNG and transition atlas used")
    var dirt := Image.new()
    dirt.load_png_from_buffer(FileAccess.get_file_as_bytes("res://world/tilesets/settlement_v1/dirt_32.png"))
    var transitions := Image.new()
    transitions.load_png_from_buffer(FileAccess.get_file_as_bytes("res://world/tilesets/settlement_v1/dirt_grass_47_atlas.png"))
    _check(dirt.get_data() == transitions.get_region(Rect2i(192, 160, 32, 32)).get_data(),
        "solid dirt matches actual mask-255 atlas pixels")
    var metadata: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(
        "res://assets_source/environment_tests/rf_graphics_004/metadata.json"))
    var manifest: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(
        "res://assets_source/environment_tests/rf_graphics_004/asset_manifest.json"))
    for asset in manifest["assets"]:
        if str(asset["path"]).begins_with("world/"):
            _check(FileAccess.get_sha256("res://" + asset["path"]) == asset["sha256"],
                "unchanged original bytes: " + asset["path"])
    for kind in scene.PROPS:
        var source: Dictionary = metadata["objects"][kind]
        var spec: Dictionary = scene.PROPS[kind]
        _check(spec["texture"].get_size() == Vector2(source["canvas"][0], source["canvas"][1]), "texture dimensions: " + kind)
        _check(spec["pivot"] == Vector2(source["pivot"][0], source["pivot"][1]), "metadata anchor: " + kind)
        for index in source["collision_polygon_test"].size():
            var point: Array = source["collision_polygon_test"][index]
            _check(spec["polygon"][index] == Vector2(point[0], point[1]), "metadata collision: " + kind)
    for prop in scene.actors.get_children():
        if prop == scene.hero:
            continue
        # Multiple instances get generated names; inspect their actual texture instead.
        var sprite: Sprite2D = prop.get_node("Sprite")
        _check(sprite.scale == Vector2.ONE and sprite.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
            "native pixels on " + str(prop.name))
        _check(prop.position == prop.position.round(), "integer prop foot position")
        _check(prop.get_node("Footprint").polygon.size() >= 4, "prop has foot collision")
    # Physics queries use the real registered shapes, not rectangles inferred from PNGs.
    _probe(scene, Vector2(832, 970), Vector2(0, -100), "tree_large")
    _probe(scene, Vector2(780, 820), Vector2(100, 0), "") # under canopy, away from root
    _probe(scene, Vector2(1152, 880), Vector2(0, -120), "well")
    _probe(scene, Vector2(812, 1040), Vector2(0, -100), "fence_horizontal")
    _probe(scene, Vector2(812, 950), Vector2(0, 100), "fence_horizontal")
    _probe(scene, Vector2(1300, 880), Vector2(100, 0), "fence_vertical")
    _probe(scene, Vector2(1300, 960), Vector2(0, 80), "fence_corner")
    _probe(scene, Vector2(1320, 940), Vector2(60, 0), "fence_corner")
    _probe(scene, Vector2(1004, 1040), Vector2(0, -100), "") # deliberate gate
    _probe(scene, Vector2(16, 800), Vector2(-32, 0), "TestBounds")
    # Real move_and_slide must stop on the root, allow the gate and retain analog speed.
    scene.player.position = Vector2(832, 980)
    await _drive(scene, Vector2.UP, 90)
    _check(scene.player.position.y > 928 and scene.player.position.y < 945, "movement stops at tree root")
    scene.player.position = Vector2(1004, 1040)
    await _drive(scene, Vector2.UP, 60)
    _check(scene.player.position.y < 960, "movement passes through open gate")
    scene.player.position = scene.SPAWN
    await _drive(scene, Vector2.RIGHT * 0.5, 30)
    var slow: float = scene.player.position.x - scene.SPAWN.x
    scene.player.position = scene.SPAWN
    await _drive(scene, Vector2.RIGHT, 30)
    var full: float = scene.player.position.x - scene.SPAWN.x
    # Float32 world coordinates around 1024 accumulate subpixel rounding during 30 steps.
    _check(absf(full - slow * 2.0) < 0.05 and absf(full - 50.0) < 0.05,
        "proportional analog movement with physics: half=%f full=%f" % [slow, full])
    var stopped: Vector2 = scene.player.position
    await _drive(scene, Vector2.ZERO, 10)
    _check(scene.player.position == stopped, "released input stops physics player")
    _check(scene.hero.position == scene.player.position.round(), "sprite stays on integer pixel after physics")
    for zoom in scene.ZOOM_LEVELS:
        scene._set_zoom(zoom)
        _check(scene.follow_camera.zoom == Vector2.ONE * zoom, "settlement zoom " + str(zoom))
    _check(not scene.world_view.stretch, "no intermediate viewport resampling")
    scene.queue_free()
    await process_frame
    print("RF-DEV-002 checks: ", _checks, "; failures: ", _failures)
    quit(0 if _failures == 0 else 1)
