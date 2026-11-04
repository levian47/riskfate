extends Node2D

# Approved sprite atlas: eight 48x64 frames ordered S, SE, E, NE, N, NW, W, SW.
const TILE_SIZE: int = 32
const GRID_RADIUS: int = 64
const WALK_SPEED: float = 100.0
const DIRECTION_NAMES := ["S", "SE", "E", "NE", "N", "NW", "W", "SW"]

@onready var hero: Sprite2D = $Hero
@onready var follow_camera: Camera2D = $Camera2D

var _world_position := Vector2.ZERO
var _touch_direction := Vector2i.ZERO
var _facing_index: int = 0
var _zoom_level: int = 4
var _status_label: Label


func _ready() -> void:
    follow_camera.make_current()
    _build_ui()
    _set_zoom(4)
    _refresh_status()


func _draw() -> void:
    var border: float = float(GRID_RADIUS * TILE_SIZE)
    draw_rect(Rect2(-border, -border, border * 2.0, border * 2.0), Color(0.09, 0.14, 0.17))
    var grid_color := Color(0.19, 0.25, 0.27, 0.7)
    for index in range(-GRID_RADIUS, GRID_RADIUS + 1):
        var coordinate: float = float(index * TILE_SIZE)
        draw_line(Vector2(coordinate, -border), Vector2(coordinate, border), grid_color, 1.0, false)
        draw_line(Vector2(-border, coordinate), Vector2(border, coordinate), grid_color, 1.0, false)


func _physics_process(delta: float) -> void:
    var direction := Vector2.ZERO

    if Input.is_key_pressed(KEY_LEFT) or Input.is_physical_key_pressed(KEY_A):
        direction.x -= 1.0
    if Input.is_key_pressed(KEY_RIGHT) or Input.is_physical_key_pressed(KEY_D):
        direction.x += 1.0
    if Input.is_key_pressed(KEY_UP) or Input.is_physical_key_pressed(KEY_W):
        direction.y -= 1.0
    if Input.is_key_pressed(KEY_DOWN) or Input.is_physical_key_pressed(KEY_S):
        direction.y += 1.0

    if _touch_direction != Vector2i.ZERO:
        direction = Vector2(_touch_direction)

    if direction.is_zero_approx():
        return

    direction = direction.normalized()
    _world_position += direction * WALK_SPEED * delta
    hero.position = _world_position.round()
    follow_camera.position = hero.position
    _set_facing(direction)


func _set_facing(direction: Vector2) -> void:
    var x: int = -1 if direction.x < -0.2 else (1 if direction.x > 0.2 else 0)
    var y: int = -1 if direction.y < -0.2 else (1 if direction.y > 0.2 else 0)

    var new_frame: int = 0
    if y > 0:
        new_frame = 7 if x < 0 else (1 if x > 0 else 0)
    elif y < 0:
        new_frame = 5 if x < 0 else (3 if x > 0 else 4)
    elif x < 0:
        new_frame = 6
    elif x > 0:
        new_frame = 2

    if new_frame != _facing_index:
        _facing_index = new_frame
        hero.frame = new_frame
        _refresh_status()


func _set_zoom(level: int) -> void:
    _zoom_level = level
    follow_camera.zoom = Vector2(float(level), float(level))
    _refresh_status()


func _refresh_status() -> void:
    if _status_label != null:
        _status_label.text = "Direction: %s   Zoom: x%d" % [DIRECTION_NAMES[_facing_index], _zoom_level]


func _on_touch_pressed(direction: Vector2i) -> void:
    _touch_direction = direction
    _set_facing(Vector2(direction))


func _on_touch_released(direction: Vector2i) -> void:
    if _touch_direction == direction:
        _touch_direction = Vector2i.ZERO


func _make_button(caption: String, size: Vector2) -> Button:
    var button := Button.new()
    button.text = caption
    button.custom_minimum_size = size
    button.focus_mode = Control.FOCUS_NONE
    button.add_theme_font_size_override("font_size", 17)
    return button


func _build_ui() -> void:
    var canvas := CanvasLayer.new()
    add_child(canvas)

    var overlay := Control.new()
    canvas.add_child(overlay)
    overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
    overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE

    var header := PanelContainer.new()
    overlay.add_child(header)
    header.anchor_left = 0.0
    header.anchor_right = 0.0
    header.anchor_top = 0.0
    header.anchor_bottom = 0.0
    header.offset_left = 12.0
    header.offset_top = 12.0
    header.offset_right = 285.0
    header.offset_bottom = 76.0

    var header_content := VBoxContainer.new()
    header.add_child(header_content)
    var heading := Label.new()
    heading.text = "RISKFATE - SPRITE TEST"
    heading.add_theme_font_size_override("font_size", 15)
    header_content.add_child(heading)

    _status_label = Label.new()
    _status_label.add_theme_font_size_override("font_size", 14)
    header_content.add_child(_status_label)

    var zoom_controls := VBoxContainer.new()
    overlay.add_child(zoom_controls)
    zoom_controls.anchor_left = 1.0
    zoom_controls.anchor_right = 1.0
    zoom_controls.anchor_top = 0.0
    zoom_controls.anchor_bottom = 0.0
    zoom_controls.offset_left = -98.0
    zoom_controls.offset_right = -12.0
    zoom_controls.offset_top = 12.0
    zoom_controls.offset_bottom = 245.0

    var zoom_heading := Label.new()
    zoom_heading.text = "ZOOM"
    zoom_heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
    zoom_controls.add_child(zoom_heading)

    for value in [1, 2, 4, 8]:
        var zoom_button := _make_button("x%d" % value, Vector2(84.0, 43.0))
        zoom_controls.add_child(zoom_button)
        zoom_button.pressed.connect(_set_zoom.bind(value))

    var controls := GridContainer.new()
    controls.columns = 3
    controls.add_theme_constant_override("h_separation", 5)
    controls.add_theme_constant_override("v_separation", 5)
    overlay.add_child(controls)
    controls.anchor_left = 0.0
    controls.anchor_right = 0.0
    controls.anchor_top = 1.0
    controls.anchor_bottom = 1.0
    controls.offset_left = 12.0
    controls.offset_right = 217.0
    controls.offset_top = -194.0
    controls.offset_bottom = -12.0

    var labels := ["NW", "N", "NE", "W", "", "E", "SW", "S", "SE"]
    var directions := [
        Vector2i(-1, -1), Vector2i(0, -1), Vector2i(1, -1),
        Vector2i(-1, 0), Vector2i.ZERO, Vector2i(1, 0),
        Vector2i(-1, 1), Vector2i(0, 1), Vector2i(1, 1)
    ]

    for index in range(labels.size()):
        if index == 4:
            var center := Label.new()
            center.text = "MOVE"
            center.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
            center.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
            center.custom_minimum_size = Vector2(62.0, 54.0)
            controls.add_child(center)
            continue

        var pad := _make_button(labels[index], Vector2(62.0, 54.0))
        controls.add_child(pad)
        pad.button_down.connect(_on_touch_pressed.bind(directions[index]))
        pad.button_up.connect(_on_touch_released.bind(directions[index]))
