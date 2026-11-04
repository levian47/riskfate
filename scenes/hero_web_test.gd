extends Control

# RF-DEV-001: these dimensions and speed are test parameters, not game balance.
const TILE_SIZE := 32
const WALK_SPEED := 100.0
const DIRECTION_NAMES := ["S", "SE", "E", "NE", "N", "NW", "W", "SW"]
const DIRECTIONS := [
    Vector2i(0, 1), Vector2i(1, 1), Vector2i(1, 0), Vector2i(1, -1),
    Vector2i(0, -1), Vector2i(-1, -1), Vector2i(-1, 0), Vector2i(-1, 1)
]
const ZOOM_LEVELS := [1, 2, 4, 8]

@onready var world_view: SubViewportContainer = $WorldView
@onready var world: SubViewport = $WorldView/World
@onready var grid: Node2D = $WorldView/World/Grid
@onready var hero: Sprite2D = $WorldView/World/Grid/Hero
@onready var follow_camera: Camera2D = $WorldView/World/Grid/Camera2D

var _world_position := Vector2.ZERO
var _joystick_direction := Vector2.ZERO
var _joystick_finger := -1
var _joystick_center := Vector2.ZERO
var _joystick_radius := 54.0
var _show_joystick := false
var _facing_index := 0
var _zoom_level := 4
var _ui: Control
var _header: VBoxContainer
var _joystick: Control
var _status_label: Label
var _hint: Label


func _ready() -> void:
    _show_joystick = DisplayServer.is_touchscreen_available()
    _build_ui()
    grid.draw.connect(_draw_grid)
    resized.connect(_layout)
    _layout()
    _set_zoom(4)
    follow_camera.make_current()


func _notification(what: int) -> void:
    if what == NOTIFICATION_APPLICATION_FOCUS_OUT or what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
        _clear_touch()


func _clear_touch() -> void:
    _joystick_finger = -1
    _joystick_direction = Vector2.ZERO
    if _joystick != null:
        _joystick.queue_redraw()


func _input(event: InputEvent) -> void:
    if not _show_joystick:
        return
    if event is InputEventScreenTouch:
        if event.pressed:
            if _joystick_finger == -1 and _joystick.get_global_rect().has_point(event.position):
                _joystick_finger = event.index
                _update_joystick(event.position)
                get_viewport().set_input_as_handled()
        elif event.index == _joystick_finger:
            _clear_touch()
            get_viewport().set_input_as_handled()
    elif event is InputEventScreenDrag and event.index == _joystick_finger:
        _update_joystick(event.position)
        get_viewport().set_input_as_handled()


func _update_joystick(screen_position: Vector2) -> void:
    var local := _joystick.get_global_transform_with_canvas().affine_inverse() * screen_position
    var offset := local - _joystick_center
    # Dead zone prevents unintended movement when resting a thumb on the center.
    _joystick_direction = Vector2.ZERO if offset.length() < 12.0 else offset.limit_length(_joystick_radius) / _joystick_radius
    _joystick.queue_redraw()


func _draw_joystick() -> void:
    if not _show_joystick:
        return
    _joystick.draw_circle(_joystick_center, _joystick_radius + 13.0, Color(0.08, 0.12, 0.16, 0.55))
    _joystick.draw_arc(_joystick_center, _joystick_radius + 13.0, 0.0, TAU, 64, Color(0.68, 0.78, 0.84, 0.65), 2.0, true)
    _joystick.draw_circle(_joystick_center + _joystick_direction * _joystick_radius, 25.0, Color(0.58, 0.75, 0.86, 0.85))


func _movement_direction() -> Vector2:
    var direction := Vector2.ZERO
    if Input.is_key_pressed(KEY_LEFT) or Input.is_key_pressed(KEY_A) or Input.is_physical_key_pressed(KEY_A):
        direction.x -= 1.0
    if Input.is_key_pressed(KEY_RIGHT) or Input.is_key_pressed(KEY_D) or Input.is_physical_key_pressed(KEY_D):
        direction.x += 1.0
    if Input.is_key_pressed(KEY_UP) or Input.is_key_pressed(KEY_W) or Input.is_physical_key_pressed(KEY_W):
        direction.y -= 1.0
    if Input.is_key_pressed(KEY_DOWN) or Input.is_key_pressed(KEY_S) or Input.is_physical_key_pressed(KEY_S):
        direction.y += 1.0
    if _joystick_finger != -1:
        return _joystick_direction
    return direction.normalized()


func _physics_process(delta: float) -> void:
    var direction := _movement_direction()
    if direction.is_zero_approx():
        return
    _world_position += direction * WALK_SPEED * delta
    hero.position = _world_position.round()
    # Center the complete 48x64 frame, preserving the approved (24, 62) foot anchor.
    follow_camera.position = hero.position + Vector2(0, -30)
    _set_facing(direction)
    grid.queue_redraw()


func _set_facing(direction: Vector2) -> void:
    if direction.is_zero_approx():
        return
    # Equal 45-degree sectors select the nearest view; movement remains analog.
    var frame_index := posmod(2 - int(roundf(direction.angle() / (PI / 4.0))), 8)
    _facing_index = frame_index
    hero.frame = frame_index
    _refresh_status()


func _next_facing() -> void:
    _set_facing(Vector2(DIRECTIONS[(_facing_index + 1) % 8]))


func _set_zoom(level: int) -> void:
    if level not in ZOOM_LEVELS:
        return
    _zoom_level = level
    follow_camera.zoom = Vector2.ONE * level
    _refresh_status()
    grid.queue_redraw()


func _refresh_status() -> void:
    if _status_label != null:
        _status_label.text = "%s · ×%d · сітка 32×32 (тест)" % [
            DIRECTION_NAMES[_facing_index], _zoom_level
        ]
    if _hint != null:
        var cropped := world.size.x < 48 * _zoom_level or world.size.y < 64 * _zoom_level
        _hint.text = "Кадр частково поза вікном — зменште масштаб." if cropped else ("Рух: сенсорний джойстик. Параметри тестові." if _show_joystick else "Рух: WASD / стрілки. Параметри тестові.")


func _draw_grid() -> void:
    var view_size := Vector2(world.size) / follow_camera.zoom
    var bounds := Rect2(follow_camera.position - view_size / 2.0, view_size)
    var first := Vector2i((bounds.position / TILE_SIZE).floor()) - Vector2i.ONE
    var last := Vector2i((bounds.end / TILE_SIZE).ceil()) + Vector2i.ONE
    var color := Color(0.23, 0.28, 0.30)
    for x in range(first.x, last.x + 1):
        grid.draw_line(Vector2(x * TILE_SIZE, first.y * TILE_SIZE),
            Vector2(x * TILE_SIZE, last.y * TILE_SIZE), color, 1.0, false)
    for y in range(first.y, last.y + 1):
        grid.draw_line(Vector2(first.x * TILE_SIZE, y * TILE_SIZE),
            Vector2(last.x * TILE_SIZE, y * TILE_SIZE), color, 1.0, false)


func _make_button(caption: String, minimum: Vector2) -> Button:
    var button := Button.new()
    button.text = caption
    button.custom_minimum_size = minimum
    button.focus_mode = Control.FOCUS_NONE
    button.add_theme_font_size_override("font_size", 16)
    return button


func _build_ui() -> void:
    _ui = Control.new()
    _ui.mouse_filter = Control.MOUSE_FILTER_IGNORE
    add_child(_ui)
    _header = VBoxContainer.new()
    _ui.add_child(_header)
    var title := Label.new()
    title.text = "RISKFATE · RF-DEV-001"
    title.add_theme_font_size_override("font_size", 16)
    _header.add_child(title)
    _status_label = Label.new()
    _status_label.add_theme_font_size_override("font_size", 13)
    _header.add_child(_status_label)
    var toolbar := HBoxContainer.new()
    _header.add_child(toolbar)
    for level in ZOOM_LEVELS:
        var button := _make_button("×%d" % level, Vector2(48, 48))
        toolbar.add_child(button)
        button.pressed.connect(_set_zoom.bind(level))
    var turn := _make_button("Ракурс", Vector2(100, 48))
    toolbar.add_child(turn)
    turn.pressed.connect(_next_facing)

    if _show_joystick:
        _joystick = Control.new()
        _joystick.mouse_filter = Control.MOUSE_FILTER_IGNORE
        _joystick.custom_minimum_size = Vector2(156, 156)
        _joystick_center = Vector2(78, 78)
        _ui.add_child(_joystick)
        _joystick.draw.connect(_draw_joystick)

    _hint = Label.new()
    _hint.add_theme_font_size_override("font_size", 13)
    _hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _ui.add_child(_hint)


func _layout() -> void:
    if _header == null:
        return
    _clear_touch()
    # Scale only UI for high-DPI phones; the game render target stays native-sized.
    var ui_scale := maxf(0.5, DisplayServer.screen_get_scale()) if OS.has_feature("web") else 1.0
    var logical_size := size / ui_scale
    _ui.scale = Vector2.ONE * ui_scale
    _ui.size = logical_size
    var margin := 6.0
    var header_height := ceilf(_header.get_combined_minimum_size().y) + margin * 2.0
    var pad_size := Vector2(156, 156) if _show_joystick else Vector2.ZERO
    _header.position = Vector2(margin, margin)
    _header.size = Vector2(logical_size.x - margin * 2.0, header_height - margin)
    var area: Rect2
    if logical_size.x > logical_size.y:
        if _show_joystick:
            _joystick.position = Vector2(margin, maxf(header_height, logical_size.y - pad_size.y - margin))
            _joystick.size = pad_size
        _hint.position = Vector2(margin, header_height)
        _hint.size = Vector2(maxf(1.0, logical_size.x - margin * 2.0), 34)
        var side_width := pad_size.x + margin * 2.0 if _show_joystick else margin
        area = Rect2(side_width, header_height + 36.0,
            maxf(1.0, logical_size.x - side_width - margin), maxf(1.0, logical_size.y - header_height - 42.0))
    else:
        if _show_joystick:
            _joystick.position = Vector2(margin, logical_size.y - pad_size.y - margin)
            _joystick.size = pad_size
        _hint.position = Vector2(pad_size.x + margin * 2.0 if _show_joystick else margin,
            logical_size.y - 70.0)
        _hint.size = Vector2(maxf(1.0, logical_size.x - _hint.position.x - margin), 64)
        area = Rect2(margin, header_height, maxf(1.0, logical_size.x - margin * 2.0),
            maxf(1.0, logical_size.y - header_height - (pad_size.y + margin * 2.0 if _show_joystick else 12.0)))
    # Native-sized render target: no viewport stretch, texture scaling or CSS shell.
    world_view.position = (area.position * ui_scale).round()
    world.size = Vector2i((area.size * ui_scale).floor())
    world_view.size = Vector2(world.size)
    _refresh_status()
    grid.queue_redraw()
