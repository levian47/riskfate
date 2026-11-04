extends SceneTree

var _failures := 0


func _initialize() -> void:
    _run.call_deferred()


func _check(condition: bool, description: String) -> void:
    if condition:
        print("PASS: ", description)
    else:
        _failures += 1
        push_error(description)


func _key(code: Key, down: bool) -> void:
    var event := InputEventKey.new()
    event.keycode = code
    event.physical_keycode = code
    event.pressed = down
    Input.parse_input_event(event)
    Input.flush_buffered_events()


func _touch(scene: Control, index: int, point: Vector2, down: bool) -> void:
    var event := InputEventScreenTouch.new()
    event.index = index
    event.position = point
    event.pressed = down
    scene._input(event)


func _run() -> void:
    var scene = load("res://scenes/hero_web_test.tscn").instantiate()
    root.add_child(scene)
    await process_frame
    scene.set_physics_process(false)
    var atlas := Image.load_from_file("res://assets_source/character_sprites/base_hero_v1/riskfate_hero_8dir_atlas_384x64.png")
    var runtime := Image.new()
    runtime.load_png_from_buffer(FileAccess.get_file_as_bytes("res://characters/player/base_hero/hero_8dir.png"))
    _check(FileAccess.get_file_as_bytes("res://assets_source/character_sprites/base_hero_v1/riskfate_hero_8dir_atlas_384x64.png") ==
        FileAccess.get_file_as_bytes("res://characters/player/base_hero/hero_8dir.png"), "runtime atlas is byte-identical to approved PNG")
    _check(runtime.get_size() == Vector2i(384, 64), "atlas size is 384x64")
    _check(not runtime.has_mipmaps(), "no sprite mipmaps")
    for index in scene.DIRECTIONS.size():
        var name: String = scene.DIRECTION_NAMES[index]
        var source := Image.load_from_file("res://assets_source/character_sprites/base_hero_v1/riskfate_hero_%s_48x64.png" % name)
        _check(atlas.get_region(Rect2i(index * 48, 0, 48, 64)).get_data() == source.get_data(),
            "frame %d matches approved %s PNG" % [index, name])
        scene._set_facing(Vector2(scene.DIRECTIONS[index]))
        _check(scene.hero.frame == index, "movement maps to frame " + name)
    _check(scene.hero.offset == Vector2(-24, -62) and not scene.hero.centered, "approved (24,62) foot anchor")
    var before: int = scene.hero.frame
    scene._physics_process(1.0)
    _check(scene.hero.frame == before, "idle preserves facing")
    for index in 8:
        scene._next_facing()
    _check(scene.hero.frame == before, "stationary facing button cycles all eight directions")

    var origin: Vector2 = scene._world_position
    _key(KEY_RIGHT, true)
    scene._physics_process(1.0)
    _key(KEY_RIGHT, false)
    var straight: float = scene._world_position.distance_to(origin)
    _check(is_equal_approx(straight, scene.WALK_SPEED), "arrow key produces expected movement")
    origin = scene._world_position
    _key(KEY_W, true)
    _key(KEY_D, true)
    scene._physics_process(1.0)
    _key(KEY_W, false)
    _key(KEY_D, false)
    _check(is_equal_approx(straight, scene._world_position.distance_to(origin)), "WASD diagonal speed equals arrow straight speed")
    _check(scene.hero.frame == 3, "W+D selects NE")
    _check(scene.hero.position == scene.hero.position.round(), "integer sprite placement")

    for window_size in [Vector2i(360, 640), Vector2i(640, 360), Vector2i(480, 800), Vector2i(1280, 720)]:
        root.size = window_size
        scene.size = Vector2(window_size)
        scene._layout()
        await process_frame
        var view: Rect2 = scene.world_view.get_global_rect()
        _check(not view.intersects(scene._pad.get_global_rect()), "pad outside world at " + str(window_size))
        _check(not view.intersects(scene._header.get_global_rect()), "header outside world at " + str(window_size))
        _check(scene.world.size == Vector2i(scene.world_view.size) and not scene.world_view.stretch,
            "native render target at " + str(window_size))
        for level in scene.ZOOM_LEVELS:
            scene._set_zoom(level)
            _check(scene.follow_camera.zoom == Vector2.ONE * level, "integer camera scale " + str(level))
        for index in scene._pad_buttons.size():
            var button: Button = scene._pad_buttons[index]
            _check(button.size.x >= 52 and button.size.y >= 52, "finger-sized button")
            _touch(scene, 0, button.get_global_rect().get_center(), true)
            var direction: Vector2 = scene._movement_direction()
            _check(direction.is_equal_approx(Vector2(scene._pad_directions[index]).normalized()), "touch maps to " + button.text)
            scene._physics_process(0.1)
            _touch(scene, 0, Vector2(-10, -10), false)
            _check(scene._movement_direction() == Vector2.ZERO, "release outside stops touch movement")
        var first: Vector2 = scene._pad_buttons[0].get_global_rect().get_center()
        _touch(scene, 0, first, true)
        _touch(scene, 1, scene._pad_buttons[1].get_global_rect().get_center(), true)
        _touch(scene, 0, first, false)
        _check(not scene._movement_direction().is_zero_approx(), "one released finger preserves the other")
        var drag := InputEventScreenDrag.new()
        drag.index = 1
        drag.position = Vector2(-10, -10)
        scene._input(drag)
        _check(scene._movement_direction() == Vector2.ZERO, "drag off pad stops movement")
        var cancel := InputEventScreenTouch.new()
        cancel.index = 1
        cancel.position = first
        cancel.canceled = true
        scene._mouse_pressed(scene._pad_directions[0])
        scene._input(cancel)
        _check(scene._movement_direction() == Vector2.ZERO, "canceled touch clears emulated mouse hold")
        _touch(scene, 0, first, true)
        scene._notification(Control.NOTIFICATION_APPLICATION_FOCUS_OUT)
        _check(scene._touches.is_empty(), "focus loss clears held touches")

    scene.queue_free()
    await process_frame
    print("RF-DEV-001 checks complete; failures: ", _failures)
    quit(0 if _failures == 0 else 1)
