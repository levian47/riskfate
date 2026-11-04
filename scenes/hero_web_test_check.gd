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
    # Analog input must choose the nearest sector, including slight axis deviations.
    for sample in [
        [0.0, 2], [10.0, 2], [-10.0, 2], [20.0, 2], [-20.0, 2],
        [25.0, 1], [-25.0, 3], [45.0, 1], [80.0, 0], [100.0, 0],
        [135.0, 7], [170.0, 6], [-170.0, 6], [-135.0, 5], [-100.0, 4], [-80.0, 4]
    ]:
        scene._set_facing(Vector2.from_angle(deg_to_rad(sample[0])) * 0.5)
        _check(scene.hero.frame == sample[1], "nearest facing at " + str(sample[0]) + " degrees")
    var facing_before_zero: int = scene.hero.frame
    scene._set_facing(Vector2.ZERO)
    _check(scene.hero.frame == facing_before_zero, "zero analog input keeps last facing")
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

    # Headless CI has no touchscreen. Verify desktop layout first, then emulate
    # touchscreen availability without changing keyboard bindings.
    _check(not scene._show_joystick and scene._joystick == null, "desktop hides touch joystick")
    for window_size in [Vector2i(360, 640), Vector2i(640, 360)]:
        root.size = window_size
        scene.size = Vector2(window_size)
        scene._layout()
        await process_frame
        _check(not scene.world_view.get_global_rect().intersects(scene._header.get_global_rect()),
            "desktop header outside world at " + str(window_size))
        _check(scene.world.size == Vector2i(scene.world_view.size) and not scene.world_view.stretch,
            "desktop native render target at " + str(window_size))

    _touch(scene, 0, Vector2(84, 716), true)
    _check(scene._joystick_finger == -1, "desktop ignores joystick touches")

    scene._show_joystick = true
    scene._joystick = Control.new()
    scene._joystick.mouse_filter = Control.MOUSE_FILTER_IGNORE
    scene._joystick.custom_minimum_size = Vector2(156, 156)
    scene._joystick_center = Vector2(78, 78)
    scene._ui.add_child(scene._joystick)
    scene._joystick.draw.connect(scene._draw_joystick)

    for window_size in [Vector2i(360, 640), Vector2i(640, 360), Vector2i(480, 800), Vector2i(1280, 720)]:
        root.size = window_size
        scene.size = Vector2(window_size)
        scene._layout()
        await process_frame
        var view: Rect2 = scene.world_view.get_global_rect()
        _check(not view.intersects(scene._joystick.get_global_rect()), "joystick outside world at " + str(window_size))
        _check(not view.intersects(scene._header.get_global_rect()), "header outside world at " + str(window_size))
        _check(scene.world.size == Vector2i(scene.world_view.size) and not scene.world_view.stretch,
            "native render target at " + str(window_size))
        for level in scene.ZOOM_LEVELS:
            scene._set_zoom(level)
            _check(scene.follow_camera.zoom == Vector2.ONE * level, "integer camera scale " + str(level))

        var center: Vector2 = scene._joystick.get_global_rect().get_center()
        _touch(scene, 0, center, true)
        _check(scene._movement_direction() == Vector2.ZERO, "joystick dead zone prevents drift")
        var right: Vector2 = center + Vector2(54, 0)
        var drag := InputEventScreenDrag.new()
        drag.index = 0
        drag.position = right
        scene._input(drag)
        _check(scene._movement_direction().is_equal_approx(Vector2.RIGHT), "joystick full right")
        drag.position = center + Vector2(0, -27)
        scene._input(drag)
        _check(is_equal_approx(scene._movement_direction().length(), 0.5), "joystick proportional speed")
        _check(scene._movement_direction().y < 0.0, "joystick moves north")
        drag.position = center + Vector2(30, -7)
        scene._input(drag)
        var analog: Vector2 = Vector2(30, -7) / 54.0
        _check(scene._movement_direction().is_equal_approx(analog), "arbitrary analog vector is not snapped")
        var analog_origin: Vector2 = scene._world_position
        scene._physics_process(1.0)
        _check((scene._world_position - analog_origin).is_equal_approx(analog * scene.WALK_SPEED),
            "analog displacement and proportional speed")
        _check(scene.hero.frame == 2, "slightly northeast movement keeps nearest east view")
        for index in scene.DIRECTIONS.size():
            drag.position = center + Vector2(scene.DIRECTIONS[index]).normalized() * 54.0
            scene._input(drag)
            scene._physics_process(0.1)
            _check(scene.hero.frame == index, "joystick selects " + scene.DIRECTION_NAMES[index])
        drag.position = center + Vector2(300, -300)
        scene._input(drag)
        _check(is_equal_approx(scene._movement_direction().length(), 1.0), "outside drag caps speed")
        _touch(scene, 1, center + Vector2(54, 0), true)
        _touch(scene, 1, center + Vector2(54, 0), false)
        _check(scene._joystick_finger == 0, "second finger does not steal joystick")
        _touch(scene, 0, Vector2(-10, -10), false)
        _check(scene._movement_direction() == Vector2.ZERO, "release outside stops movement")
        _touch(scene, 0, center + Vector2(54, 0), true)
        scene._layout()
        _check(scene._joystick_finger == -1 and scene._movement_direction() == Vector2.ZERO,
            "resize clears held joystick")
        scene._input(drag)
        _check(scene._movement_direction() == Vector2.ZERO, "old finger drag cannot resume after resize")
        for notification in [Control.NOTIFICATION_APPLICATION_FOCUS_OUT, Control.NOTIFICATION_WM_WINDOW_FOCUS_OUT]:
            _touch(scene, 0, center + Vector2(54, 0), true)
            scene._notification(notification)
            _check(scene._joystick_finger == -1 and scene._movement_direction() == Vector2.ZERO,
                "focus loss clears joystick")
        _touch(scene, 0, center + Vector2(54, 0), true)
        var cancel := InputEventScreenTouch.new()
        cancel.index = 0
        cancel.canceled = true
        scene._input(cancel)
        _check(scene._movement_direction() == Vector2.ZERO, "touch cancellation stops joystick")
    scene.queue_free()
    await process_frame
    print("RF-DEV-001 checks complete; failures: ", _failures)
    quit(0 if _failures == 0 else 1)
