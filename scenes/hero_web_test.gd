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
var _mouse_direction := Vector2i.ZERO
var _touches: Dictionary = {}
var _facing_index := 0
var _zoom_level := 4
var _ui: Control
var _header: VBoxContainer
var _pad: GridContainer
var _pad_buttons: Array[Button] = []
var _pad_directions: Array[Vector2i] = []
var _status_label: Label
var _hint: Label


func _ready() -> void:
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
    _touches.clear()
    _mouse_direction = Vector2i.ZERO


func _input(event: InputEvent) -> void:
    # Track fingers separately; release/drag outside a button must stop movement.
    # Buttons remain standard Godot UI controls, including mouse hold support.
    if event is InputEventScreenTouch:
        if not event.pressed or event.canceled:
            _touches.erase(event.index)
            if _touches.is_empty():
                _mouse_direction = Vector2i.ZERO
        else:
            var direction := _pad_direction_at(event.position)
            if direction != Vector2i.ZERO:
                _touches[event.index] = direction
    elif event is InputEventScreenDrag and _touches.has(event.index):
        _touches[event.index] = _pad_direction_at(event.position)


func _pad_direction_at(point: Vector2) -> Vector2i:
    for index in _pad_buttons.size():
        if _pad_buttons[index].get_global_rect().has_point(point):
            return _pad_directions[index]
    return Vector2i.ZERO


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
    if not _touches.is_empty():
        direction = Vector2(_touches.values().back())
    elif _mouse_direction != Vector2i.ZERO:
        direction = Vector2(_mouse_direction)
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
    var discrete := Vector2i(int(signf(direction.x)), int(signf(direction.y)))
    var frame_index := DIRECTIONS.find(discrete)
    if frame_index >= 0:
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
        _hint.text = "Кадр частково поза вікном — збільште вікно або зменште масштаб." if cropped else "WASD / стрілки або утримуйте кнопки руху. Параметри тестові."


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

    _pad = GridContainer.new()
    _pad.columns = 3
    _pad.add_theme_constant_override("h_separation", 4)
    _pad.add_theme_constant_override("v_separation", 4)
    _ui.add_child(_pad)
    for direction in [
        Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
        Vector2i(-1, 0), Vector2i.ZERO, Vector2i(1, 0),
        Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1)
    ]:
        if direction == Vector2i.ZERO:
            var center := Label.new()
            center.text = "РУХ"
            center.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
            center.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
            _pad.add_child(center)
            continue
        var button := _make_button(DIRECTION_NAMES[DIRECTIONS.find(direction)], Vector2(52, 52))
        _pad.add_child(button)
        _pad_buttons.append(button)
        _pad_directions.append(direction)
        button.button_down.connect(_mouse_pressed.bind(direction))
        button.button_up.connect(_mouse_released.bind(direction))

    _hint = Label.new()
    _hint.add_theme_font_size_override("font_size", 13)
    _hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
    _hint.mouse_filter = Control.MOUSE_FILTER_IGNORE
    _ui.add_child(_hint)


func _mouse_pressed(direction: Vector2i) -> void:
    _mouse_direction = direction
    _set_facing(Vector2(direction))


func _mouse_released(direction: Vector2i) -> void:
    if _mouse_direction == direction:
        _mouse_direction = Vector2i.ZERO


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
    var pad_size := Vector2(164, 164)
    _header.position = Vector2(margin, margin)
    _header.size = Vector2(logical_size.x - margin * 2.0, header_height - margin)
    var area: Rect2
    if logical_size.x > logical_size.y:
        _pad.position = Vector2(margin, header_height)
        _pad.size = pad_size
        _hint.position = Vector2(margin, header_height + pad_size.y + margin)
        _hint.size = Vector2(pad_size.x, maxf(0.0, logical_size.y - _hint.position.y - margin))
        area = Rect2(pad_size.x + margin * 2.0, header_height,
            maxf(1.0, logical_size.x - pad_size.x - margin * 3.0), maxf(1.0, logical_size.y - header_height - margin))
    else:
        _pad.position = Vector2(margin, logical_size.y - pad_size.y - margin)
        _pad.size = pad_size
        _hint.position = Vector2(pad_size.x + margin * 2.0, _pad.position.y)
        _hint.size = Vector2(maxf(1.0, logical_size.x - _hint.position.x - margin), pad_size.y)
        area = Rect2(margin, header_height, maxf(1.0, logical_size.x - margin * 2.0),
            maxf(1.0, _pad.position.y - header_height - margin))
    # Native-sized render target: no viewport stretch, texture scaling or CSS shell.
    world_view.position = (area.position * ui_scale).round()
    world.size = Vector2i((area.size * ui_scale).floor())
    world_view.size = Vector2(world.size)
    _refresh_status()
    grid.queue_redraw()
