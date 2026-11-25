extends Node3D
# Gắn script này vào node gốc Node3D của scene main.tscn. Toàn bộ cảnh được dựng bằng code.

const LAT := 21.03   # Hà Nội. Đổi theo thành phố của bạn
const LON := 105.85
const REFRESH_SEC := 900.0
const FY := 0.2      # độ cao mặt sàn nhà
const WH := 3.4      # chiều cao tường

var env: Environment
var sky_mat: ProceduralSkyMaterial
var sun: DirectionalLight3D
var room_light: OmniLight3D
var fire_light: OmniLight3D
var fire_mat: StandardMaterial3D
var glass_mat: StandardMaterial3D
var fire_t := 0.0
var rbox_cache := {}
var rain: GPUParticles3D
var clouds: Node3D
var cal_month: Label3D
var cal_day: Label3D
var cal_week: Label3D
var cam: Camera3D
var yaw := 40.0
var pitch := -32.0
var dist := 17.0
var cloud_cover := 0.0
var is_day := true
var code := 0

# ===== Chế độ xuất frame cho widget Android =====
# Đặt EXPORT_WIDGET = true rồi nhấn F5: game tự chạy, lưu PNG vào res://widget_frames/ rồi tự thoát.
# Xong nhớ đặt lại false.
const EXPORT_WIDGET := false
const EXP_SIZE := Vector2i(480, 540)   # kích thước mỗi frame (px)
const EXP_FRAMES := 8                  # số frame mỗi biến thể (widget sẽ chạy tới-lui nên vòng lặp mượt)
const EXP_YAW := 40.0                  # góc camera khi chụp
const EXP_PITCH := -32.0
const EXP_DIST := 17.0                 # nhỏ hơn = zoom gần hơn
const EXP_T0 := 20.0                   # thời điểm bắt đầu của gió/lá (giây)
const EXP_DT := 0.2                    # bước thời gian giữa 2 frame
const EXP_VARIANTS := [
	{"name": "day", "is_day": true, "code": 0, "cloud": 10.0, "hour": 14.0},
	{"name": "night", "is_day": false, "code": 0, "cloud": 10.0, "hour": 22.0},
	{"name": "dayrain", "is_day": true, "code": 61, "cloud": 90.0, "hour": 14.0},
	{"name": "nightrain", "is_day": false, "code": 61, "cloud": 90.0, "hour": 22.0},
]
var exporting := EXPORT_WIDGET
var anim_clock := 0.0      # đồng hồ chung cho shader (thay TIME của shader để điều khiển được từng frame)
var hour_override := -1.0  # >= 0: ép giờ mặt trời (dùng khi xuất frame)

func _ready() -> void:
	RenderingServer.global_shader_parameter_add("anim_t", RenderingServer.GLOBAL_VAR_TYPE_FLOAT, 0.0)
	get_viewport().msaa_3d = Viewport.MSAA_4X   # viền mịn, hết răng cưa
	_build_environment()
	_build_house()
	_build_garden()
	_build_calendar()
	_build_rain()
	clouds = Node3D.new()
	add_child(clouds)
	cam = Camera3D.new()
	cam.fov = 45.0
	cam.keep_aspect = Camera3D.KEEP_WIDTH   # màn hình dọc vẫn thấy đủ căn phòng
	add_child(cam)
	_update_camera()
	_update_calendar()
	var day_timer := Timer.new()
	day_timer.wait_time = 60.0
	day_timer.autostart = true
	add_child(day_timer)
	day_timer.timeout.connect(_update_calendar)   # qua nửa đêm: lịch + tranh tự đổi sang ngày mới
	_apply_weather()
	var http := HTTPRequest.new()
	add_child(http)
	http.request_completed.connect(_on_weather)
	var t := Timer.new()
	t.wait_time = REFRESH_SEC
	t.autostart = true
	add_child(t)
	t.timeout.connect(func(): _fetch(http))
	_fetch(http)
	if exporting:
		_export_frames.call_deferred()

# ---------- Helpers ----------
func _mat(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	return m

func _box(size: Vector3, pos: Vector3, c: Color, parent: Node = self) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var b := BoxMesh.new()
	b.size = size
	mi.mesh = b
	mi.material_override = _mat(c)
	mi.position = pos
	parent.add_child(mi)
	return mi

# Hộp bo tròn góc (mịn như đồ vật trong ảnh mẫu), có cache theo kích thước
func _rbox(size: Vector3, pos: Vector3, c: Color, parent: Node = self, r: float = 0.05) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	mi.mesh = _rbox_mesh(size, r)
	mi.material_override = _mat(c)
	mi.position = pos
	parent.add_child(mi)
	return mi

func _rbox_mesh(size: Vector3, r_in: float) -> ArrayMesh:
	var key := "%s|%s" % [size, r_in]
	if rbox_cache.has(key):
		return rbox_cache[key]
	var h := size / 2.0
	var r := minf(r_in, minf(h.x, minf(h.y, h.z)) * 0.98)
	var inner := h - Vector3(r, r, r)
	var ts := [0.0, 0.42, 0.73, 1.0]
	var bps: Array = []
	for a in 3:
		var arr: Array = []
		for t in ts:
			arr.append(-h[a] + t * r)
		for k in range(ts.size() - 1, -1, -1):
			arr.append(h[a] - ts[k] * r)
		bps.append(arr)
	var verts := PackedVector3Array()
	var norms := PackedVector3Array()
	for a in 3:
		var u := (a + 1) % 3
		var v := (a + 2) % 3
		for s in [-1.0, 1.0]:
			var n_i: int = bps[u].size()
			var grid: Array = []
			for i in n_i:
				var row: Array = []
				for j in n_i:
					var p := Vector3.ZERO
					p[a] = s * h[a]
					p[u] = bps[u][i]
					p[v] = bps[v][j]
					var q := Vector3(clampf(p.x, -inner.x, inner.x), clampf(p.y, -inner.y, inner.y), clampf(p.z, -inner.z, inner.z))
					var nn := (p - q).normalized()
					row.append([q + nn * r, nn])
				grid.append(row)
			for i in n_i - 1:
				for j in n_i - 1:
					var quad := [grid[i][j], grid[i + 1][j], grid[i + 1][j + 1], grid[i][j + 1]]
					for tri in [[0, 1, 2], [0, 2, 3]]:
						var A = quad[tri[0]]
						var B = quad[tri[1]]
						var C = quad[tri[2]]
						var cr: Vector3 = (B[0] - A[0]).cross(C[0] - A[0])
						var nsum: Vector3 = A[1] + B[1] + C[1]
						if cr.dot(nsum) > 0.0:   # Godot: mặt trước theo chiều kim đồng hồ
							var tmp = B
							B = C
							C = tmp
						for X in [A, B, C]:
							verts.append(X[0])
							norms.append(X[1])
	var arrays := []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = verts
	arrays[Mesh.ARRAY_NORMAL] = norms
	var m := ArrayMesh.new()
	m.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
	rbox_cache[key] = m
	return m

func _cyl(r_top: float, r_bot: float, h: float, pos: Vector3, c: Color, parent: Node = self) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = r_top
	cm.bottom_radius = r_bot
	cm.height = h
	mi.mesh = cm
	mi.material_override = _mat(c)
	mi.position = pos
	parent.add_child(mi)
	return mi

func _ball(r: float, pos: Vector3, c: Color, parent: Node = self) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = r
	sm.height = r * 2.0
	mi.mesh = sm
	mi.material_override = _mat(c)
	mi.position = pos
	parent.add_child(mi)
	return mi

# Node con đặt trên sàn nhà, xoay quanh trục Y (mặt trước của đồ vật = +Z cục bộ)
func _node(x: float, z: float, yaw_deg: float) -> Node3D:
	var n := Node3D.new()
	n.position = Vector3(x, FY, z)
	n.rotation_degrees.y = yaw_deg
	add_child(n)
	return n

# ---------- Môi trường ----------
func _build_environment() -> void:
	sky_mat = ProceduralSkyMaterial.new()
	var sky := Sky.new()
	sky.sky_material = sky_mat
	env = Environment.new()
	env.background_mode = Environment.BG_SKY
	env.sky = sky
	env.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	env.ambient_light_color = Color(0.82, 0.86, 0.95)
	env.ambient_light_energy = 0.9
	env.ssao_enabled = true            # bóng tối mềm ở góc (chỉ có tác dụng với renderer Forward+)
	env.ssao_radius = 0.8
	env.ssao_intensity = 2.0
	env.tonemap_mode = Environment.TONE_MAPPER_FILMIC
	var we := WorldEnvironment.new()
	we.environment = env
	add_child(we)
	sun = DirectionalLight3D.new()
	sun.shadow_enabled = true
	sun.directional_shadow_max_distance = 40.0
	sun.shadow_blur = 1.5
	sun.shadow_bias = 0.04
	sun.shadow_normal_bias = 1.2
	add_child(sun)
	room_light = OmniLight3D.new()
	room_light.position = Vector3(0, 3.2, 0)
	room_light.omni_range = 9.0
	room_light.light_color = Color(1.0, 0.88, 0.65)
	add_child(room_light)

# ---------- Nhà: căn phòng khách cắt lớp (mở mặt trước và bên phải) ----------
func _build_house() -> void:
	glass_mat = StandardMaterial3D.new()
	glass_mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glass_mat.albedo_color = Color(0.85, 0.93, 1.0, 0.12)
	glass_mat.roughness = 0.05
	glass_mat.metallic_specular = 0.8
	fire_mat = StandardMaterial3D.new()
	fire_mat.albedo_color = Color(1.0, 0.5, 0.15)
	fire_mat.emission_enabled = true
	fire_mat.emission = Color(1.0, 0.45, 0.1)
	fire_mat.emission_energy_multiplier = 1.6

	var wall := Color(0.84, 0.82, 0.79)
	var white := Color(0.97, 0.97, 0.97)
	# bệ nền + sàn gỗ xương cá
	_rbox(Vector3(8.4, FY, 6.4), Vector3(0, FY / 2.0, 0), Color(0.88, 0.88, 0.9))
	_build_floor()
	# tường trái (cửa sổ) và tường sau, mép trên màu trắng
	_rbox(Vector3(0.2, WH, 2.1), Vector3(-4.1, FY + WH / 2.0, -2.05), wall)    # tường trái: đoạn gần góc bếp
	_rbox(Vector3(0.2, WH, 0.6), Vector3(-4.1, FY + WH / 2.0, 2.9), wall)      # đoạn đầu gần
	_rbox(Vector3(0.2, 0.12, 3.6), Vector3(-4.1, FY + 0.06, 0.8), wall)        # dưới cửa sổ
	_rbox(Vector3(0.2, WH - 2.95, 3.6), Vector3(-4.1, FY + 2.95 + (WH - 2.95) / 2.0, 0.8), wall)  # trên cửa sổ
	_rbox(Vector3(8.4, WH, 0.2), Vector3(0, FY + WH / 2.0, -3.1), wall)
	_rbox(Vector3(0.26, 0.06, 6.36), Vector3(-4.1, FY + WH + 0.03, 0.05), white)
	_rbox(Vector3(8.46, 0.06, 0.26), Vector3(0, FY + WH + 0.03, -3.1), white)
	# len chân tường
	_box(Vector3(0.03, 0.14, 2.0), Vector3(-3.985, FY + 0.07, -2.0), white)
	_box(Vector3(0.03, 0.14, 0.4), Vector3(-3.985, FY + 0.07, 2.8), white)
	_box(Vector3(8.0, 0.14, 0.03), Vector3(0, FY + 0.07, -2.985), white)
	# mảng tường xám đậm quanh góc bếp lò
	_box(Vector3(2.0, WH, 0.02), Vector3(-3.0, FY + WH / 2.0, -2.99), Color(0.27, 0.28, 0.3))
	_box(Vector3(0.02, WH, 1.8), Vector3(-3.99, FY + WH / 2.0, -2.1), Color(0.27, 0.28, 0.3))

	_build_windows()
	_build_stove()
	_build_logs()
	_build_tv()
	_build_sideboard()
	_build_living()
	_build_dining()
	_build_plant(-3.4, 2.3)

# Sàn gỗ xương cá (tạo texture bằng code)
func _parquet_tex() -> ImageTexture:
	var S := 256
	var P := 32     # nửa chu kỳ ngang của hình chữ V
	var W := 16     # bề rộng một thanh gỗ
	var img := Image.create(S, S, false, Image.FORMAT_RGB8)
	var base := Color(0.74, 0.49, 0.26)
	for y in S:
		for x in S:
			var xm: int = x % (P * 2)
			var tri: int = xm if xm < P else (P * 2 - xm)
			var yy: int = y + tri
			var plank: int = yy / W
			var cell: int = x / P
			var v := float(absi(hash(Vector2i(plank, cell))) % 100) / 100.0
			var col := Color(base.r + (v - 0.5) * 0.16, base.g + (v - 0.5) * 0.13, base.b + (v - 0.5) * 0.08)
			if yy % W == 0 or x % P == 0:
				col = col.darkened(0.3)
			img.set_pixel(x, y, col)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

func _build_floor() -> void:
	var m := StandardMaterial3D.new()
	m.albedo_texture = _parquet_tex()
	m.uv1_scale = Vector3(2, 1.5, 1)
	m.roughness = 0.55
	m.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	var mi := MeshInstance3D.new()
	var pl := PlaneMesh.new()
	pl.size = Vector2(8, 6)
	mi.mesh = pl
	mi.material_override = m
	mi.position = Vector3(0, FY + 0.004, 0)
	add_child(mi)

# Cửa sổ sát sàn trên tường trái (z từ -1.0 đến 2.6)
func _build_windows() -> void:
	var wood := Color(0.62, 0.43, 0.26)
	for i in 3:
		var zc := -0.4 + i * 1.2
		var g := _box(Vector3(0.02, 2.8, 1.12), Vector3(-3.99, FY + 1.52, zc), Color.WHITE)
		g.material_override = glass_mat
		g.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	for i in 4:
		_box(Vector3(0.08, 2.95, 0.08), Vector3(-3.96, FY + 1.5, -1.0 + i * 1.2), wood)
	_box(Vector3(0.08, 0.08, 3.68), Vector3(-3.96, FY + 2.95, 0.8), wood)
	_box(Vector3(0.05, 0.04, 3.6), Vector3(-3.97, FY + 1.5, 0.8), wood)
	_box(Vector3(0.16, 0.06, 3.8), Vector3(-3.92, FY + 0.1, 0.8), wood)
	# tấm ốp gỗ ở đầu tường gần
	_box(Vector3(0.03, WH, 0.4), Vector3(-3.985, FY + WH / 2.0, 2.8), wood)

# Bếp củi đặt ở góc, có ống khói lên cao
func _build_stove() -> void:
	_rbox(Vector3(2.0, 0.05, 2.0), Vector3(-3.0, FY + 0.025, -2.0), Color(0.42, 0.43, 0.45))  # nền đá
	var n := Node3D.new()
	n.position = Vector3(-3.1, FY + 0.05, -2.2)
	n.rotation_degrees.y = 45.0
	add_child(n)
	var iron := Color(0.1, 0.1, 0.11)
	for sx in [-0.32, 0.32]:
		for sz in [-0.22, 0.22]:
			_rbox(Vector3(0.06, 0.15, 0.06), Vector3(sx, 0.075, sz), iron, n)
	_rbox(Vector3(0.8, 0.75, 0.6), Vector3(0, 0.525, 0), iron, n)
	_rbox(Vector3(0.9, 0.06, 0.7), Vector3(0, 0.93, 0), Color(0.07, 0.07, 0.08), n)
	_rbox(Vector3(0.6, 0.53, 0.02), Vector3(0, 0.5, 0.305), Color(0.22, 0.22, 0.24), n)
	var fire := _rbox(Vector3(0.5, 0.43, 0.02), Vector3(0, 0.5, 0.32), Color.WHITE, n)
	fire.material_override = fire_mat
	_rbox(Vector3(0.03, 0.2, 0.03), Vector3(0.3, 0.5, 0.34), Color(0.7, 0.7, 0.7), n)
	_cyl(0.06, 0.06, 2.6, Vector3(0, 2.26, 0), iron, n)       # ống khói
	_cyl(0.09, 0.09, 0.08, Vector3(0, 1.0, 0), Color(0.15, 0.15, 0.16), n)
	fire_light = OmniLight3D.new()
	fire_light.position = Vector3(-2.5, FY + 0.7, -1.6)
	fire_light.omni_range = 4.5
	fire_light.light_color = Color(1.0, 0.55, 0.2)
	fire_light.light_energy = 1.4
	add_child(fire_light)

# Đống củi nhỏ trên giá sắt cạnh bếp lò: 6 khúc xếp chồng + bó củi nhóm lửa
# Khúc củi có vân năm ở mặt cắt, vỏ cây sần sùi (shader), mỗi khúc một sắc độ
func _build_logs() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 11
	var n := _node(-2.5, -2.78, 0)
	n.position.y += 0.05   # nằm trên nền đá
	var iron := Color(0.09, 0.09, 0.1)
	# giá sắt: đáy + 4 trụ + 2 thanh ray hai bên
	_rbox(Vector3(0.64, 0.025, 0.44), Vector3(0, 0.0125, 0), iron, n, 0.008)
	for sx in [-0.31, 0.31]:
		for sz in [-0.2, 0.2]:
			_rbox(Vector3(0.018, 0.3, 0.018), Vector3(sx, 0.16, sz), iron, n, 0.006)
		_rbox(Vector3(0.018, 0.018, 0.42), Vector3(sx, 0.31, 0), iron, n, 0.006)

	var r0 := 0.083
	var log_mesh := CylinderMesh.new()
	log_mesh.top_radius = r0
	log_mesh.bottom_radius = r0
	log_mesh.height = 0.38
	log_mesh.radial_segments = 20
	var mat := _log_material()
	var spots := [
		Vector2(-0.166, 0.0), Vector2(0.0, 0.0), Vector2(0.166, 0.0),
		Vector2(-0.083, 0.144), Vector2(0.083, 0.144), Vector2(0.0, 0.288)]
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = log_mesh
	mm.instance_count = spots.size()
	for i in spots.size():
		var sp: Vector2 = spots[i]
		var sr := rng.randf_range(0.93, 1.07)
		var sl := rng.randf_range(0.9, 1.1)
		var b := Basis(Vector3.RIGHT, PI / 2.0) * Basis(Vector3.UP, rng.randf() * TAU) * Basis.IDENTITY.scaled(Vector3(sr, sl, sr))
		var pos := Vector3(sp.x, 0.025 + r0 + sp.y, rng.randf_range(-0.02, 0.02))
		mm.set_instance_transform(i, Transform3D(b, pos))
		mm.set_instance_custom_data(i, Color(rng.randf_range(0.8, 1.15), rng.randf(), 0.0, 0.0))
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = mat
	n.add_child(mmi)

	# bó củi nhóm lửa: que mảnh nằm trước đống củi
	var kmesh := CylinderMesh.new()
	kmesh.top_radius = 0.016
	kmesh.bottom_radius = 0.019
	kmesh.height = 0.3
	kmesh.radial_segments = 8
	var km := MultiMesh.new()
	km.transform_format = MultiMesh.TRANSFORM_3D
	km.use_custom_data = true
	km.mesh = kmesh
	km.instance_count = 5
	for i in 5:
		var yaw := rng.randf_range(-0.15, 0.15)
		var row := 0 if i < 3 else 1
		var col_i := i if i < 3 else i - 3
		var kb := Basis(Vector3.UP, PI / 2.0 + yaw) * Basis(Vector3.RIGHT, PI / 2.0)
		var kpos := Vector3(rng.randf_range(-0.03, 0.03), 0.019 + row * 0.034, 0.27 + col_i * 0.036 + row * 0.018)
		km.set_instance_transform(i, Transform3D(kb, kpos))
		km.set_instance_custom_data(i, Color(rng.randf_range(0.9, 1.2), rng.randf(), 0.0, 0.0))
	var kmi := MultiMeshInstance3D.new()
	kmi.multimesh = km
	kmi.material_override = mat
	n.add_child(kmi)

func _log_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode diffuse_burley;
global uniform float anim_t;

varying vec3 v_lp;
varying float v_cap;
varying float v_tint;
varying float v_phase;

void vertex() {
	v_lp = VERTEX;
	v_cap = step(0.9, abs(NORMAL.y));
	v_tint = INSTANCE_CUSTOM.x;
	v_phase = INSTANCE_CUSTOM.y;
}

void fragment() {
	float ang = atan(v_lp.z, v_lp.x);
	// vỏ cây: rãnh dọc thân, ngoằn ngoèo nhẹ
	float b1 = sin(ang * 9.0 + sin(v_lp.y * 28.0 + v_phase * 6.0) * 0.7) * 0.5 + 0.5;
	float b2 = sin(ang * 23.0 + v_lp.y * 14.0 + v_phase * 9.0) * 0.5 + 0.5;
	vec3 bark = mix(vec3(0.14, 0.08, 0.045), vec3(0.36, 0.23, 0.13), b1 * 0.6 + b2 * 0.4) * v_tint;
	// mặt cắt: vân năm tròn + nứt tỏa tia + viền vỏ
	float rn = length(v_lp.xz) / 0.083;
	float rings = sin(rn * 26.0 + v_phase * 6.28 + sin(ang * 3.0 + v_phase * 5.0) * 1.3) * 0.5 + 0.5;
	vec3 wood = mix(vec3(0.86, 0.64, 0.4), vec3(0.64, 0.42, 0.22), rings * 0.65) * v_tint;
	wood *= 0.88 + 0.12 * smoothstep(0.0, 0.5, rn);
	float crack = pow(abs(sin(ang * 3.0 + v_phase * 12.0)), 60.0) * smoothstep(0.1, 0.6, rn);
	wood = mix(wood, vec3(0.32, 0.18, 0.08), crack * 0.7);
	wood = mix(wood, vec3(0.17, 0.1, 0.05), smoothstep(0.88, 0.97, rn));
	ALBEDO = mix(bark, wood, v_cap);
	ROUGHNESS = mix(0.95, 0.8, v_cap);
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	return mat

# TV OLED siêu mỏng 86 inch treo tường + kệ TV gỗ sồi + loa thanh + đèn nền ambient
func _build_tv() -> void:
	var tx := 0.35
	# ánh sáng nền phía sau TV (glow lan ra tường)
	var glow := MeshInstance3D.new()
	var gq := QuadMesh.new()
	gq.size = Vector2(3.2, 2.1)
	glow.mesh = gq
	glow.material_override = _tv_glow_material()
	glow.position = Vector3(tx, FY + 1.5, -2.994)
	glow.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(glow)

	var black := Color(0.035, 0.035, 0.04)
	# thân TV mỏng + cụm điện tử phình nhẹ phía sau (như TV OLED thật)
	var body := _rbox(Vector3(1.96, 1.11, 0.03), Vector3(tx, FY + 1.5, -2.94), black, self, 0.012)
	body.material_override.metallic = 0.7
	body.material_override.roughness = 0.35
	var bulge := _rbox(Vector3(1.1, 0.62, 0.035), Vector3(tx, FY + 1.36, -2.973), Color(0.06, 0.06, 0.065), self, 0.012)
	bulge.material_override.metallic = 0.6
	bulge.material_override.roughness = 0.45
	# viền kim loại mảnh quanh khung
	var trim := _rbox(Vector3(1.972, 1.122, 0.006), Vector3(tx, FY + 1.5, -2.936), Color(0.55, 0.56, 0.6), self, 0.005)
	trim.material_override.metallic = 0.95
	trim.material_override.roughness = 0.25
	# màn hình kính
	var scr := MeshInstance3D.new()
	var sq := QuadMesh.new()
	sq.size = Vector2(1.9, 1.069)
	scr.mesh = sq
	scr.material_override = _tv_screen_material()
	scr.position = Vector3(tx, FY + 1.5, -2.9234)
	scr.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(scr)
	# đèn báo chờ nhỏ ở góc dưới
	var led := _ball(0.004, Vector3(tx + 0.88, FY + 0.97, -2.921), Color(1, 1, 1))
	led.material_override.emission_enabled = true
	led.material_override.emission = Color(0.9, 0.95, 1.0)
	led.material_override.emission_energy_multiplier = 2.0
	led.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	# ánh sáng xanh dịu từ màn hình hắt ra phòng
	var tvl := OmniLight3D.new()
	tvl.position = Vector3(tx, FY + 1.5, -2.3)
	tvl.omni_range = 3.6
	tvl.light_color = Color(0.45, 0.75, 1.0)
	tvl.light_energy = 0.3
	tvl.shadow_enabled = false
	add_child(tvl)

	# kệ TV: thân trắng ngà, cánh gỗ sồi, ô mở giữa, chân thon
	var n := _node(tx, -2.76, 0)
	var oak := Color(0.74, 0.57, 0.37)
	var cream := Color(0.92, 0.91, 0.88)
	for sx in [-1.02, 1.02]:
		for sz in [-0.15, 0.15]:
			var leg := _rbox(Vector3(0.035, 0.16, 0.035), Vector3(sx, 0.08, sz), Color(0.16, 0.12, 0.09), n, 0.01)
			leg.rotation_degrees = Vector3(sz * 20.0, 0.0, -sx * 6.0)
	_rbox(Vector3(2.3, 0.3, 0.42), Vector3(0, 0.31, 0), cream, n, 0.012)
	_rbox(Vector3(2.36, 0.03, 0.45), Vector3(0, 0.475, 0.005), oak, n, 0.012)
	_rbox(Vector3(0.7, 0.24, 0.02), Vector3(0, 0.31, 0.212), Color(0.1, 0.085, 0.075), n, 0.006)   # ô mở
	for sx in [-0.76, 0.76]:
		_rbox(Vector3(0.74, 0.26, 0.018), Vector3(sx, 0.31, 0.22), oak, n, 0.008)
		_rbox(Vector3(0.012, 0.1, 0.008), Vector3(sx + (0.33 if sx < 0 else -0.33), 0.31, 0.232), Color(0.3, 0.2, 0.12), n, 0.004)
	# đồ trong ô mở: đầu phát + chồng sách
	_rbox(Vector3(0.34, 0.045, 0.2), Vector3(-0.12, 0.2, 0.08), Color(0.95, 0.95, 0.95), n, 0.01)
	var ledb := _ball(0.004, Vector3(-0.12, 0.2, 0.182), Color.WHITE)
	ledb.material_override.emission_enabled = true
	ledb.material_override.emission = Color(0.3, 0.9, 1.0)
	ledb.material_override.emission_energy_multiplier = 2.5
	var bk := [Color(0.75, 0.3, 0.28), Color(0.25, 0.4, 0.55), Color(0.88, 0.8, 0.6)]
	for i in 3:
		_rbox(Vector3(0.22 - i * 0.02, 0.028, 0.16), Vector3(0.22, 0.188 + i * 0.028, 0.06), bk[i], n, 0.005)
	# loa thanh: thân đen, lưới vải xám phía trước, đèn nhỏ
	_rbox(Vector3(1.3, 0.07, 0.1), Vector3(0, 0.525, 0.0), Color(0.07, 0.07, 0.08), n, 0.02)
	_rbox(Vector3(1.24, 0.05, 0.008), Vector3(0, 0.525, 0.052), Color(0.2, 0.2, 0.22), n, 0.004)
	var sled := _ball(0.004, Vector3(0.58, 0.54, 0.056), Color.WHITE)
	sled.material_override.emission_enabled = true
	sled.material_override.emission = Color(1.0, 0.95, 0.85)
	sled.material_override.emission_energy_multiplier = 2.0
	# đồ trang trí: bình gốm + cành khô, chồng sách nhỏ
	_cyl(0.035, 0.05, 0.2, Vector3(0.95, 0.59, 0.0), Color(0.88, 0.85, 0.78), n)
	_ball(0.055, Vector3(0.95, 0.68, 0.0), Color(0.88, 0.85, 0.78), n)
	var srng := RandomNumberGenerator.new()
	srng.seed = 4
	for i in 5:
		var holder := Node3D.new()
		holder.position = Vector3(0.95, 0.7, 0.0)
		holder.rotation_degrees = Vector3(srng.randf_range(-16.0, 16.0), 0.0, srng.randf_range(-16.0, 16.0))
		n.add_child(holder)
		_cyl(0.004, 0.004, 0.45, Vector3(0, 0.225, 0), Color(0.6, 0.5, 0.35), holder)
		var puff := _ball(0.02, Vector3(0, 0.46, 0), Color(0.93, 0.87, 0.74), holder)
		puff.scale = Vector3(0.8, 1.5, 0.8)
	for i in 3:
		_rbox(Vector3(0.28 - i * 0.03, 0.03, 0.2), Vector3(-0.95, 0.505 + i * 0.03, 0.0), [Color(0.3, 0.45, 0.4), Color(0.85, 0.75, 0.55), Color(0.55, 0.3, 0.3)][i], n, 0.006)

# Màn hình: cực quang trên núi tuyết, sao nhấp nháy, kính bóng
func _tv_screen_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode diffuse_lambert;
global uniform float anim_t;

uniform float brightness = 1.35;

float h21(vec2 p) {
	p = fract(p * vec2(233.34, 851.73));
	p += dot(p, p + 23.45);
	return fract(p.x * p.y);
}

void fragment() {
	vec2 uv = UV;
	vec2 p = vec2(uv.x * 1.78, 1.0 - uv.y);
	float t = anim_t * 0.12;
	vec3 col = mix(vec3(0.01, 0.02, 0.07), vec3(0.03, 0.16, 0.22), pow(1.0 - p.y, 2.2));
	// sao
	vec2 g = floor(p * vec2(130.0, 75.0));
	float s = h21(g);
	float star = step(0.9965, s) * (0.5 + 0.5 * sin(anim_t * 2.0 + s * 60.0));
	col += star * vec3(0.9, 0.95, 1.0) * smoothstep(0.35, 0.8, p.y);
	// 3 dải cực quang
	vec3 aur = vec3(0.0);
	for (int i = 0; i < 3; i++) {
		float fi = float(i);
		float y = 0.62 + 0.06 * fi + 0.1 * sin(p.x * (1.6 + 0.5 * fi) + t * (1.2 + 0.4 * fi) + fi * 2.0) + 0.04 * sin(p.x * 6.0 - t * 2.5 + fi * 1.3);
		float d = p.y - y;
		float ray = 0.65 + 0.35 * sin(p.x * 18.0 + fi + t * 3.0);
		float curtain = exp(-d * d * 170.0) * ray;
		float haze = exp(-abs(d) * 4.5) * 0.1;
		vec3 ac = mix(vec3(0.1, 1.0, 0.55), vec3(0.55, 0.25, 0.95), clamp(fi * 0.4 + 0.2 * sin(p.x * 2.0 + t), 0.0, 1.0));
		aur += ac * (curtain * (0.6 - 0.14 * fi) + haze);
	}
	col += aur;
	// núi tuyết
	float ridge = 0.17 + 0.07 * sin(p.x * 3.1 + 0.5) + 0.035 * sin(p.x * 8.3 + 2.0) + 0.015 * sin(p.x * 21.0);
	float m = 1.0 - smoothstep(ridge - 0.004, ridge + 0.004, p.y);
	vec3 mount = vec3(0.01, 0.02, 0.03) + vec3(0.05, 0.1, 0.12) * smoothstep(ridge - 0.06, ridge, p.y) + aur * 0.12;
	col = mix(col, mount, m);
	float vg = smoothstep(1.2, 0.3, length(uv - 0.5) * 1.4);
	col *= 0.75 + 0.25 * vg;
	ALBEDO = vec3(0.008);
	EMISSION = col * brightness;
	ROUGHNESS = 0.06;
	SPECULAR = 0.9;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	return mat

# Ánh sáng ambient lan trên tường sau TV, đổi màu chậm
func _tv_glow_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode unshaded, blend_add, depth_draw_never, cull_back;
global uniform float anim_t;

void fragment() {
	vec2 p = (UV - 0.5) * vec2(3.2, 2.1);
	vec2 q = abs(p) - vec2(0.9, 0.5);
	float dist = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0);
	float glow = exp(-max(dist, 0.0) * 5.0) * 0.55;
	vec3 col = mix(vec3(0.1, 0.55, 0.95), vec3(0.55, 0.2, 0.9), 0.5 + 0.5 * sin(anim_t * 0.2 + p.x * 0.8));
	ALBEDO = col * glow;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	return mat

# Tủ thấp + tranh treo tường
func _build_sideboard() -> void:
	var n := _node(2.9, -2.7, 0)
	var wood := Color(0.36, 0.22, 0.13)
	for sx in [-0.72, 0.72]:
		for sz in [-0.2, 0.2]:
			_rbox(Vector3(0.05, 0.2, 0.05), Vector3(sx, 0.1, sz), Color(0.2, 0.12, 0.07), n)
	_rbox(Vector3(1.6, 0.75, 0.5), Vector3(0, 0.575, 0), wood, n)
	for i in 3:
		_rbox(Vector3(0.48, 0.6, 0.02), Vector3(-0.52 + i * 0.52, 0.575, 0.255), Color(0.44, 0.28, 0.17), n)
		_rbox(Vector3(0.1, 0.02, 0.02), Vector3(-0.52 + i * 0.52, 0.7, 0.275), Color(0.8, 0.7, 0.5), n)
	_cyl(0.05, 0.07, 0.25, Vector3(0.55, 1.075, 0), Color(0.85, 0.85, 0.82), n)   # bình hoa
	_ball(0.09, Vector3(0.55, 1.28, 0), Color(0.8, 0.3, 0.35), n)
	_rbox(Vector3(0.2, 0.15, 0.14), Vector3(-0.5, 1.025, 0), Color(0.6, 0.45, 0.3), n)
	# tranh phong cảnh treo tường: khung gỗ óc chó + viền vàng + passe-partout + kính
	var px := 3.0
	var py := FY + 2.0
	var fwood := Color(0.24, 0.14, 0.085)
	var gold_c := Color(0.85, 0.68, 0.32)
	_rbox(Vector3(0.86, 1.06, 0.02), Vector3(px, py, -2.99), fwood)                       # lưng khung
	var ow := 0.86
	var oh := 1.06
	var t := 0.07
	var wz := -2.9625   # khung gỗ nổi lên khỏi tường
	_rbox(Vector3(ow, t, 0.07), Vector3(px, py + oh / 2.0 - t / 2.0, wz), fwood, self, 0.012)
	_rbox(Vector3(ow, t, 0.07), Vector3(px, py - oh / 2.0 + t / 2.0, wz), fwood, self, 0.012)
	_rbox(Vector3(t, oh - 2.0 * t, 0.07), Vector3(px - ow / 2.0 + t / 2.0, py, wz), fwood, self, 0.012)
	_rbox(Vector3(t, oh - 2.0 * t, 0.07), Vector3(px + ow / 2.0 - t / 2.0, py, wz), fwood, self, 0.012)
	# viền vàng mỏng bên trong khung gỗ
	var gw := ow - 2.0 * t
	var gh := oh - 2.0 * t
	var gt := 0.014
	var gz := -2.9395
	for gm in [_box(Vector3(gw, gt, 0.008), Vector3(px, py + gh / 2.0 - gt / 2.0, gz), gold_c),
			_box(Vector3(gw, gt, 0.008), Vector3(px, py - gh / 2.0 + gt / 2.0, gz), gold_c),
			_box(Vector3(gt, gh - 2.0 * gt, 0.008), Vector3(px - gw / 2.0 + gt / 2.0, py, gz), gold_c),
			_box(Vector3(gt, gh - 2.0 * gt, 0.008), Vector3(px + gw / 2.0 - gt / 2.0, py, gz), gold_c)]:
		gm.material_override.metallic = 0.9
		gm.material_override.roughness = 0.3
	# passe-partout kem
	_box(Vector3(gw - 2.0 * gt, gh - 2.0 * gt, 0.02), Vector3(px, py, -2.96), Color(0.96, 0.94, 0.88))
	# bức tranh (vẽ bằng code)
	var art := MeshInstance3D.new()
	var aq := QuadMesh.new()
	aq.size = Vector2(0.56, 0.76)
	art.mesh = aq
	var am := StandardMaterial3D.new()
	am.emission_enabled = true
	art_mat = am   # ảnh tranh được nạp theo ngày trong _refresh_painting()
	am.emission_energy_multiplier = 0.3
	am.roughness = 0.7
	am.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	art.material_override = am
	art.position = Vector3(px, py, -2.947)
	add_child(art)
	# viền vàng quanh tranh
	var at := 0.008
	var azz := -2.9485
	for gm2 in [_box(Vector3(0.58, at, 0.004), Vector3(px, py + 0.39, azz), gold_c),
			_box(Vector3(0.58, at, 0.004), Vector3(px, py - 0.39, azz), gold_c),
			_box(Vector3(at, 0.78, 0.004), Vector3(px - 0.286, py, azz), gold_c),
			_box(Vector3(at, 0.78, 0.004), Vector3(px + 0.286, py, azz), gold_c)]:
		gm2.material_override.metallic = 0.9
		gm2.material_override.roughness = 0.3
	# lớp kính phản chiếu nhẹ
	var gl := MeshInstance3D.new()
	var glq := QuadMesh.new()
	glq.size = Vector2(gw, gh)
	gl.mesh = glq
	var glm := StandardMaterial3D.new()
	glm.albedo_color = Color(0.9, 0.95, 1.0, 0.07)
	glm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	glm.roughness = 0.05
	glm.metallic_specular = 0.9
	gl.material_override = glm
	gl.position = Vector3(px, py, -2.934)
	gl.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(gl)
	_refresh_painting()

# ---------- Tranh treo tường cạnh lịch: mặc định là "Rừng thu vàng" (các chủ đề khác vẫn còn, đổi ART_FIXED nếu muốn) ----------
var art_mat: StandardMaterial3D
var art_day := -1
const ART_THEMES := 7
const ART_FIXED := 3   # 3 = Rừng thu vàng

func _refresh_painting() -> void:
	if art_mat == null or art_day != -1:
		return
	art_day = 0
	var tex := _painting_tex(ART_FIXED, 3)   # tranh treo tường cố định: Rừng thu vàng
	art_mat.albedo_texture = tex
	art_mat.emission_texture = tex

func _hash2(x: float, y: float) -> float:
	return fposmod(sin(x * 12.9898 + y * 78.233) * 43758.5453, 1.0)

func _painting_theme(i: int) -> Dictionary:
	# mặc định = "Bình minh bên hồ"
	var t := {
		"name": "Bình minh bên hồ", "hor": 0.63,
		"sky_top": Color(0.36, 0.56, 0.84), "sky_bot": Color(0.98, 0.78, 0.66), "haze": Color(0.95, 0.86, 0.85),
		"sun_on": true, "sun_pos": Vector2(0.68, 0.43), "sun_r": 0.065, "sun_col": Color(1.0, 0.97, 0.84),
		"glow_col": Color(1.0, 0.85, 0.55), "glow_amt": 0.55,
		"stars": false, "clouds": 1.0, "cloud_col": Color(1.0, 0.9, 0.86),
		"ridges": [
			[0.50, 0.075, 0.9, 40.0, Color(0.70, 0.72, 0.88)],
			[0.545, 0.06, 1.5, 120.0, Color(0.50, 0.58, 0.76)],
			[0.585, 0.045, 2.4, 260.0, Color(0.30, 0.42, 0.55)]],
		"water": true, "water_col": Color(0.18, 0.36, 0.52), "water_mix": 0.42,
		"field_a": Color(0.3, 0.6, 0.25), "field_b": Color(0.15, 0.4, 0.15), "flowers": false,
		"bank_y": 0.84, "bank_a": Color(0.2, 0.36, 0.22), "bank_b": Color(0.1, 0.2, 0.14), "bank_hi": Color(0.5, 0.62, 0.3),
		"trees": 1, "tree_dark": Color(0.07, 0.2, 0.14), "tree_light": Color(0.14, 0.32, 0.2), "snow": false,
		"birds": true}
	match i:
		1:
			t.merge({"name": "Hoàng hôn trên biển", "hor": 0.66,
				"sky_top": Color(0.22, 0.18, 0.48), "sky_bot": Color(1.0, 0.52, 0.28), "haze": Color(0.9, 0.5, 0.4),
				"sun_pos": Vector2(0.5, 0.57), "sun_r": 0.09, "sun_col": Color(1.0, 0.86, 0.52),
				"glow_col": Color(1.0, 0.5, 0.25), "glow_amt": 0.85, "cloud_col": Color(1.0, 0.55, 0.45),
				"ridges": [[0.585, 0.03, 1.2, 300.0, Color(0.28, 0.16, 0.32)]],
				"water_col": Color(0.4, 0.2, 0.4), "water_mix": 0.3,
				"bank_y": 0.93, "bank_a": Color(0.78, 0.58, 0.4), "bank_b": Color(0.5, 0.36, 0.3), "bank_hi": Color(0.95, 0.75, 0.5),
				"trees": 0}, true)
		2:
			t.merge({"name": "Đêm trăng sao", "hor": 0.62,
				"sky_top": Color(0.02, 0.04, 0.15), "sky_bot": Color(0.18, 0.22, 0.42), "haze": Color(0.2, 0.26, 0.46),
				"sun_pos": Vector2(0.3, 0.24), "sun_r": 0.07, "sun_col": Color(0.97, 0.97, 0.88),
				"glow_col": Color(0.7, 0.8, 1.0), "glow_amt": 0.35, "stars": true, "clouds": 0.18, "cloud_col": Color(0.5, 0.55, 0.7),
				"ridges": [
					[0.50, 0.07, 0.9, 40.0, Color(0.12, 0.15, 0.3)],
					[0.56, 0.05, 1.6, 150.0, Color(0.06, 0.08, 0.18)]],
				"water_col": Color(0.04, 0.09, 0.24), "water_mix": 0.5,
				"bank_a": Color(0.05, 0.1, 0.1), "bank_b": Color(0.02, 0.05, 0.06), "bank_hi": Color(0.12, 0.2, 0.2),
				"tree_dark": Color(0.03, 0.08, 0.08), "tree_light": Color(0.08, 0.15, 0.16), "birds": false}, true)
		3:
			t.merge({"name": "Rừng thu vàng",
				"sky_top": Color(0.55, 0.72, 0.88), "sky_bot": Color(1.0, 0.88, 0.7), "haze": Color(1.0, 0.85, 0.65),
				"sun_pos": Vector2(0.3, 0.4), "sun_r": 0.05, "glow_col": Color(1.0, 0.8, 0.5), "glow_amt": 0.4, "clouds": 0.6,
				"ridges": [
					[0.50, 0.07, 0.9, 40.0, Color(0.78, 0.6, 0.45)],
					[0.55, 0.06, 1.5, 120.0, Color(0.7, 0.42, 0.22)],
					[0.59, 0.045, 2.4, 260.0, Color(0.55, 0.3, 0.15)]],
				"water_col": Color(0.5, 0.35, 0.25), "water_mix": 0.35,
				"bank_a": Color(0.45, 0.3, 0.12), "bank_b": Color(0.25, 0.15, 0.08), "bank_hi": Color(0.8, 0.5, 0.15),
				"trees": 2, "tree_dark": Color(0.72, 0.3, 0.08), "tree_light": Color(0.98, 0.68, 0.2)}, true)
		4:
			t.merge({"name": "Đồng cỏ ngày nắng", "hor": 0.66,
				"sky_top": Color(0.25, 0.55, 0.95), "sky_bot": Color(0.78, 0.92, 1.0), "haze": Color(0.85, 0.95, 1.0),
				"sun_pos": Vector2(0.76, 0.2), "sun_r": 0.06, "glow_col": Color(1.0, 1.0, 0.8), "glow_amt": 0.3,
				"cloud_col": Color(1, 1, 1),
				"ridges": [
					[0.55, 0.06, 0.9, 40.0, Color(0.55, 0.75, 0.62)],
					[0.59, 0.05, 1.5, 120.0, Color(0.35, 0.62, 0.38)],
					[0.63, 0.035, 2.4, 260.0, Color(0.2, 0.5, 0.25)]],
				"water": false, "flowers": true, "bank_y": 1.5,
				"trees": 2, "tree_dark": Color(0.08, 0.36, 0.14), "tree_light": Color(0.3, 0.65, 0.25)}, true)
		5:
			t.merge({"name": "Núi tuyết mùa đông",
				"sky_top": Color(0.55, 0.7, 0.88), "sky_bot": Color(0.92, 0.94, 0.99), "haze": Color(0.95, 0.97, 1.0),
				"sun_on": false, "clouds": 0.7, "cloud_col": Color(1, 1, 1),
				"ridges": [
					[0.42, 0.12, 0.8, 40.0, Color(0.86, 0.91, 0.98)],
					[0.50, 0.08, 1.4, 120.0, Color(0.7, 0.78, 0.9)],
					[0.56, 0.05, 2.4, 260.0, Color(0.55, 0.65, 0.8)]],
				"water_col": Color(0.7, 0.82, 0.92), "water_mix": 0.5,
				"bank_a": Color(0.93, 0.95, 0.99), "bank_b": Color(0.8, 0.85, 0.93), "bank_hi": Color(1, 1, 1),
				"tree_dark": Color(0.08, 0.22, 0.2), "tree_light": Color(0.2, 0.4, 0.35), "snow": true, "birds": false}, true)
		6:
			t.merge({"name": "Ruộng lúa chín", "hor": 0.6,
				"sky_top": Color(0.45, 0.7, 0.9), "sky_bot": Color(1.0, 0.9, 0.6), "haze": Color(1.0, 0.92, 0.7),
				"sun_pos": Vector2(0.25, 0.35), "sun_r": 0.07, "glow_col": Color(1.0, 0.85, 0.4), "glow_amt": 0.6, "clouds": 0.5,
				"ridges": [
					[0.46, 0.08, 0.9, 40.0, Color(0.6, 0.7, 0.8)],
					[0.53, 0.05, 1.6, 150.0, Color(0.35, 0.5, 0.55)]],
				"water": false, "field_a": Color(0.95, 0.75, 0.22), "field_b": Color(0.62, 0.4, 0.1), "bank_y": 1.5,
				"trees": 2, "tree_dark": Color(0.12, 0.34, 0.12), "tree_light": Color(0.35, 0.6, 0.2)}, true)
	return t

# màu phần phía trên đường chân trời (trời, mặt trời/trăng, mây, núi) — cũng dùng để phản chiếu xuống mặt nước
func _scene_col(nz: FastNoiseLite, x: float, v: float, w: float, h: float, th: Dictionary) -> Color:
	var hor: float = th["hor"]
	var t := clampf(v / hor, 0.0, 1.0)
	var c: Color = (th["sky_top"] as Color).lerp(th["sky_bot"], pow(t, 1.7))
	c = c.lerp(Color(1.0, 0.92, 0.72), pow(t, 5.0) * 0.25)
	if th["stars"] and t < 0.8:
		var hs := _hash2(floorf(x), floorf(v * h))
		if hs > 0.985:
			c = c.lerp(Color(1.0, 1.0, 0.95), clampf((hs - 0.985) * 60.0, 0.0, 1.0) * (1.0 - t))
	if th["sun_on"]:
		var spf: Vector2 = th["sun_pos"]
		var sr: float = th["sun_r"] * w
		var d := Vector2(x, v * h).distance_to(Vector2(spf.x * w, spf.y * h))
		c = c.lerp(th["glow_col"], clampf(1.0 - d / (0.34 * w), 0.0, 1.0) * float(th["glow_amt"]))
		if d < sr:
			c = th["sun_col"]
		elif d < sr * 1.15:
			c = c.lerp(th["sun_col"], 0.6)
	var cn := nz.get_noise_2d(x * 0.9, v * h * 3.2 + 500.0)
	if v < 0.46 and cn > 0.12:
		var ca := clampf((cn - 0.12) * 3.0, 0.0, 0.75) * (1.0 - v / 0.46) * float(th["clouds"])
		c = c.lerp(th["cloud_col"], ca)
	for r in th["ridges"]:
		var ry: float = float(r[0]) + nz.get_noise_2d(x * float(r[2]) * 0.5, float(r[3])) * float(r[1])
		if v > ry and v <= hor:
			var rc: Color = r[4]
			var k := clampf((v - ry) / (hor - ry + 0.001), 0.0, 1.0)
			c = rc.lerp(th["haze"], k * 0.35)
	return c

func _painting_tex(theme_idx: int, seed_v: int) -> ImageTexture:
	var th := _painting_theme(theme_idx)
	var w := 232
	var h := 316
	var hor: float = th["hor"]
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var nz := FastNoiseLite.new()
	nz.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	nz.frequency = 0.02
	nz.seed = seed_v % 100000
	var spf: Vector2 = th["sun_pos"]
	var water: bool = th["water"]
	var bank_y: float = th["bank_y"]
	var tkind: int = th["trees"]
	var snow: bool = th["snow"]
	var trees := [[26.0, 0.93, 64.0, 15.0], [48.0, 0.9, 46.0, 11.0], [12.0, 0.96, 52.0, 12.0],
		[70.0, 0.87, 30.0, 8.0], [208.0, 0.92, 54.0, 13.0], [186.0, 0.89, 36.0, 9.0], [222.0, 0.96, 44.0, 10.0]]
	for y in h:
		var v := float(y) / h
		for x in w:
			var c: Color
			if v <= hor:
				c = _scene_col(nz, x, v, w, h, th)
			elif water:
				# hồ: phản chiếu cảnh phía trên, gợn sóng ngang
				var dv := v - hor
				var rip := nz.get_noise_2d(x * 0.35, float(y) * 4.0) * 0.012 * (1.0 + dv * 6.0)
				var mv := clampf(hor - dv * 0.95 + rip, 0.0, hor)
				c = _scene_col(nz, x + rip * 300.0, mv, w, h, th)
				c = c.lerp(th["water_col"], clampf(float(th["water_mix"]) + dv * 0.5, 0.0, 0.95))
				if th["sun_on"]:
					var sg := nz.get_noise_2d(x * 0.5, float(y) * 6.0)
					var sd := absf(float(x) - spf.x * w)
					if sg > 0.2 and sd < 26.0 * (1.0 - dv * 0.8):
						c = c.lerp(th["sun_col"], 0.55 * (1.0 - sd / 30.0))
				var rl := nz.get_noise_2d(x * 0.2, float(y) * 8.0)
				if rl > 0.45:
					c = c.lerp(Color(0.8, 0.9, 1.0), 0.18)
			else:
				# đồng cỏ / ruộng lúa: luống chạy theo phối cảnh
				var fv := (v - hor) / (1.0 - hor)
				c = (th["field_a"] as Color).lerp(th["field_b"], fv)
				var stripe := 0.5 + 0.5 * sin(fv * 70.0 + nz.get_noise_2d(x * 0.3, 10.0) * 4.0)
				c = c.lerp(th["field_b"], stripe * 0.25 * (0.3 + fv))
				c = c.lerp(th["field_a"], clampf(nz.get_noise_2d(x * 1.2, float(y) * 2.0), 0.0, 1.0) * 0.2)
				if th["flowers"] and fv > 0.1:
					var hf := _hash2(float(x), float(y))
					if hf > 0.975:
						var hc := _hash2(float(x) + 1.0, float(y) + 3.0)
						c = Color(1.0, 0.85, 0.2) if hc < 0.33 else (Color(1.0, 1.0, 1.0) if hc < 0.66 else Color(0.95, 0.45, 0.6))
			# bờ cỏ / cát / tuyết phía trước
			var bank := bank_y + nz.get_noise_2d(x * 0.8, 77.0) * 0.045 + (1.0 - float(x) / w) * 0.03
			if v > bank:
				var g := clampf((v - bank) / (1.0 - bank), 0.0, 1.0)
				c = (th["bank_a"] as Color).lerp(th["bank_b"], g)
				c = c.lerp(th["bank_hi"], clampf(nz.get_noise_2d(x * 1.4, y * 1.4), 0.0, 1.0) * 0.28)
			# cây
			if tkind != 0:
				for tdef in trees:
					var tx: float = tdef[0]
					var tb: float = float(tdef[1]) * h
					var th2: float = tdef[2]
					var tw: float = tdef[3]
					if tkind == 1:
						if y > tb - th2 and y < tb:
							var f := (float(y) - (tb - th2)) / th2
							var hw := tw * (0.12 + f * 0.88) * (0.78 + 0.22 * absf(sin(f * 14.0)))
							if absf(x - tx) < hw:
								var shade := 0.5 + 0.5 * clampf((x - tx) / (hw + 0.01), -1.0, 1.0)
								c = (th["tree_dark"] as Color).lerp(th["tree_light"], (1.0 - shade) * 0.7)
								if snow:
									c = c.lerp(Color(0.95, 0.97, 1.0), 0.55 * (1.0 - shade * 0.5))
						elif y >= tb and y < tb + 5.0 and absf(x - tx) < 1.6:
							c = Color(0.22, 0.14, 0.09)
					else:
						var cc := Vector2(tx, tb - th2 * 0.5)
						var rr := tw * 0.95
						if y >= cc.y and y < tb + 4.0 and absf(x - tx) < 1.8:
							c = Color(0.28, 0.17, 0.1)
						if Vector2(x, y).distance_to(cc) < rr:
							var dap := clampf(nz.get_noise_2d(x * 2.2, y * 2.2) * 0.5 + 0.5, 0.0, 1.0)
							c = (th["tree_dark"] as Color).lerp(th["tree_light"], dap)
			# tuyết rơi
			if snow and _hash2(x * 1.7 + 3.0, float(y) * 2.3) > 0.988:
				c = c.lerp(Color(1, 1, 1), 0.85)
			img.set_pixel(x, y, c)
	# đàn chim bay
	if th["birds"]:
		var birds := [Vector2(70, 70), Vector2(88, 58), Vector2(58, 52), Vector2(112, 84), Vector2(98, 96)]
		for b in birds:
			var bp: Vector2 = b
			for dx in range(-6, 7):
				var yy: float = bp.y + absf(float(dx)) * 0.55 - 2.5
				_stamp(img, bp.x + float(dx), yy, 0.7, Color(0.16, 0.16, 0.24), 0.9)
	# vignette nhẹ
	for y in h:
		for x in w:
			var vx := (float(x) / w - 0.5) * 2.0
			var vy := (float(y) / h - 0.5) * 2.0
			var vg := clampf((vx * vx + vy * vy - 0.7) * 0.22, 0.0, 0.25)
			img.set_pixel(x, y, img.get_pixel(x, y).lerp(Color(0.05, 0.05, 0.08), vg))
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

# ---------- Nội thất ----------
# Chỉnh độ nhám / kim loại cho vật liệu của mesh vừa tạo
func _shiny(mi: MeshInstance3D, rough: float, metal: float = 0.0) -> MeshInstance3D:
	var m := mi.material_override as StandardMaterial3D
	m.roughness = rough
	m.metallic = metal
	return mi

# Chân thon, hơi choãi ra ngoài (đỉnh chân cố định tại x,z), gót chân bọc đồng
func _leg(parent: Node, x: float, z: float, h: float, r_top: float, r_bot: float, splay_deg: float, c: Color) -> void:
	var sx := signf(x)
	var sz := signf(z)
	var off := sin(deg_to_rad(splay_deg)) * h   # độ lệch ngang của gót chân
	var lg := _cyl(r_top, r_bot, h, Vector3(x + sx * off * 0.5, h / 2.0, z + sz * off * 0.5), c, parent)
	lg.rotation_degrees = Vector3(-splay_deg * sz, 0.0, splay_deg * sx)
	_shiny(lg, 0.45)
	var cap := _cyl(r_bot + 0.004, r_bot + 0.004, 0.022, Vector3(x + sx * off, 0.011, z + sz * off), Color(0.82, 0.66, 0.3), parent)
	_shiny(cap, 0.3, 0.9)

func _build_living() -> void:
	_armchair(-1.5, -1.8, 90.0, Color(0.78, 0.42, 0.3), 1.0)
	_armchair(-1.5, -0.1, 90.0, Color(0.9, 0.84, 0.72), -1.0)
	_armchair(2.1, -1.8, -90.0, Color(0.88, 0.66, 0.28), 1.0)
	_armchair(2.1, -0.1, -90.0, Color(0.78, 0.42, 0.3), -1.0)
	# ghế dài (ottoman) ở giữa: bọc nệm rút nút, chân gỗ thon, có khay nến + sách
	var n := _node(0.3, -0.95, 0)
	var wood := Color(0.36, 0.22, 0.13)
	var body := Color(0.7, 0.6, 0.46)
	var top := Color(0.82, 0.74, 0.6)
	var dark := Color(0.54, 0.45, 0.33)
	for sx in [-0.2, 0.2]:
		for sz in [-0.7, 0.7]:
			_leg(n, sx, sz, 0.18, 0.03, 0.019, 6.0, wood)
	_rbox(Vector3(0.56, 0.22, 1.6), Vector3(0, 0.27, 0), body, n, 0.05)
	_rbox(Vector3(0.575, 0.02, 1.615), Vector3(0, 0.38, 0), dark, n, 0.008)    # viền chỉ nổi
	_rbox(Vector3(0.53, 0.14, 1.54), Vector3(0, 0.45, 0), top, n, 0.06)        # nệm ngồi
	for bx in [-0.11, 0.11]:
		for i in 7:
			_ball(0.015, Vector3(bx, 0.518, -0.6 + i * 0.2), dark, n)          # nút rút
	# khay gỗ + nến + chậu sen đá
	_shiny(_rbox(Vector3(0.32, 0.025, 0.44), Vector3(0, 0.5325, 0.4), wood, n, 0.01), 0.4)
	_cyl(0.04, 0.04, 0.06, Vector3(-0.06, 0.575, 0.4), Color(0.97, 0.94, 0.85), n)
	_ball(0.009, Vector3(-0.06, 0.615, 0.4), Color(1.0, 0.75, 0.25), n)
	_shiny(_cyl(0.04, 0.03, 0.05, Vector3(0.07, 0.5725, 0.4), Color(0.92, 0.92, 0.88), n), 0.25)
	for lp in [Vector3(0.07, 0.61, 0.4), Vector3(0.045, 0.60, 0.42), Vector3(0.095, 0.60, 0.42)]:
		_ball(0.024, lp, Color(0.4, 0.62, 0.35), n)
	# chồng sách
	_rbox(Vector3(0.24, 0.035, 0.32), Vector3(0, 0.5375, -0.38), Color(0.6, 0.3, 0.2), n, 0.008)
	var b2 := _rbox(Vector3(0.22, 0.03, 0.29), Vector3(0, 0.5705, -0.38), Color(0.35, 0.42, 0.3), n, 0.008)
	b2.rotation_degrees.y = 12.0
	var b3 := _rbox(Vector3(0.18, 0.025, 0.25), Vector3(0, 0.598, -0.38), Color(0.9, 0.85, 0.7), n, 0.008)
	b3.rotation_degrees.y = -8.0

# Ghế bành: chân thon choãi, khung đế có viền, nệm ngồi có chỉ nổi, lưng rút nút,
# tay vịn cuộn tròn có mặt lõm + nút, gối tựa màu nhấn
func _armchair(x: float, z: float, yaw_deg: float, accent: Color = Color(0.78, 0.42, 0.3), flip: float = 1.0) -> void:
	var n := _node(x, z, yaw_deg)
	var gray := Color(0.52, 0.6, 0.47)
	var dark := Color(0.37, 0.45, 0.34)
	var light := Color(0.63, 0.7, 0.56)
	var wood := Color(0.36, 0.22, 0.13)
	for sx in [-0.38, 0.38]:
		for sz in [-0.36, 0.36]:
			_leg(n, sx, sz, 0.26, 0.032, 0.02, 7.0, wood)
	# khung đế + viền chân
	_rbox(Vector3(0.9, 0.2, 0.85), Vector3(0, 0.34, 0), gray, n, 0.05)
	_rbox(Vector3(0.93, 0.03, 0.88), Vector3(0, 0.255, 0), dark, n, 0.012)
	# nệm ngồi + chỉ nổi viền trên/dưới
	_rbox(Vector3(0.62, 0.14, 0.64), Vector3(0, 0.52, 0.08), light, n, 0.06)
	_rbox(Vector3(0.635, 0.014, 0.655), Vector3(0, 0.462, 0.08), dark, n, 0.006)
	_rbox(Vector3(0.625, 0.014, 0.645), Vector3(0, 0.578, 0.08), dark, n, 0.006)
	# lưng ghế + gờ cuộn phía trên
	_rbox(Vector3(0.9, 0.6, 0.2), Vector3(0, 0.74, -0.33), gray, n, 0.07)
	var roll_top := _cyl(0.085, 0.085, 0.86, Vector3(0, 1.05, -0.33), light, n)
	roll_top.rotation_degrees.z = 90.0
	# đệm lưng nghiêng nhẹ, rút nút
	var bp := Node3D.new()
	bp.position = Vector3(0, 0.8, -0.2)
	bp.rotation_degrees.x = -12.0
	n.add_child(bp)
	_rbox(Vector3(0.62, 0.42, 0.13), Vector3.ZERO, light, bp, 0.06)
	for bx in [-0.17, 0.0, 0.17]:
		for by in [-0.08, 0.08]:
			_ball(0.013, Vector3(bx, by, 0.066), dark, bp)
	# tay vịn cuộn tròn
	for sx in [-0.375, 0.375]:
		_rbox(Vector3(0.15, 0.28, 0.8), Vector3(sx, 0.54, 0.0), gray, n, 0.05)
		var roll := _cyl(0.085, 0.085, 0.82, Vector3(sx, 0.68, 0.0), light, n)
		roll.rotation_degrees.x = 90.0
		var face := _cyl(0.068, 0.068, 0.012, Vector3(sx, 0.68, 0.412), dark, n)
		face.rotation_degrees.x = 90.0
		_ball(0.014, Vector3(sx, 0.68, 0.42), light, n)
	# gối tựa màu nhấn (có hai dải sọc)
	var pp := Node3D.new()
	pp.position = Vector3(0.2 * flip, 0.75, -0.05)
	pp.rotation_degrees = Vector3(-18.0, 22.0 * flip, 6.0 * flip)
	n.add_child(pp)
	_rbox(Vector3(0.3, 0.3, 0.09), Vector3.ZERO, accent, pp, 0.04)
	_rbox(Vector3(0.305, 0.04, 0.094), Vector3(0, 0.06, 0), accent.lightened(0.35), pp, 0.012)
	_rbox(Vector3(0.305, 0.04, 0.094), Vector3(0, -0.06, 0), accent.lightened(0.35), pp, 0.012)

func _build_dining() -> void:
	var wood := Color(0.34, 0.2, 0.11)
	var dark := Color(0.26, 0.15, 0.08)
	var light := Color(0.5, 0.33, 0.19)
	var n := _node(0.8, 2.0, 0)
	# mặt bàn bo mép + mặt dát gỗ sáng
	_shiny(_rbox(Vector3(2.1, 0.05, 0.95), Vector3(0, 0.765, 0), wood, n, 0.02), 0.35)
	_rbox(Vector3(1.92, 0.006, 0.77), Vector3(0, 0.79, 0), light, n, 0.003)
	# thanh nẹp dưới mặt bàn + khối nối chân
	for sz in [-0.36, 0.36]:
		_rbox(Vector3(1.84, 0.09, 0.03), Vector3(0, 0.69, sz), dark, n, 0.01)
	for sx in [-0.9, 0.9]:
		_rbox(Vector3(0.03, 0.09, 0.7), Vector3(sx, 0.69, 0), dark, n, 0.01)
	for sx in [-0.92, 0.92]:
		for sz in [-0.36, 0.36]:
			_rbox(Vector3(0.075, 0.09, 0.075), Vector3(sx, 0.69, sz), dark, n, 0.012)
			_leg(n, sx, sz, 0.74, 0.04, 0.024, 2.5, wood)
	# khăn trải bàn dạng runner
	_rbox(Vector3(1.2, 0.006, 0.26), Vector3(0, 0.796, 0), Color(0.5, 0.6, 0.46), n, 0.002)
	for sz in [-0.1, 0.1]:
		_box(Vector3(1.2, 0.002, 0.016), Vector3(0, 0.8, sz), Color(0.95, 0.88, 0.7), n)
	# bát trái cây
	_shiny(_cyl(0.16, 0.08, 0.075, Vector3(0, 0.8365, 0), Color(0.92, 0.92, 0.88), n), 0.25)
	_ball(0.047, Vector3(-0.07, 0.905, 0.03), Color(0.95, 0.8, 0.1), n)
	_ball(0.05, Vector3(0.07, 0.905, -0.02), Color(0.95, 0.55, 0.15), n)
	_ball(0.046, Vector3(0.0, 0.905, -0.08), Color(0.55, 0.75, 0.25), n)
	_ball(0.046, Vector3(0.0, 0.905, 0.09), Color(0.8, 0.2, 0.2), n)
	_ball(0.045, Vector3(0.0, 0.95, 0.0), Color(0.95, 0.85, 0.15), n)
	# bình hoa
	_shiny(_cyl(0.035, 0.055, 0.2, Vector3(-0.5, 0.899, 0.02), Color(0.25, 0.45, 0.42), n), 0.15)
	var vb := Vector3(-0.5, 0.99, 0.02)
	var tilts := [Vector2(14, 0), Vector2(-16, 6), Vector2(4, -14), Vector2(-5, 16)]
	var lens := [0.2, 0.23, 0.26, 0.22]
	var fcols := [Color(0.9, 0.35, 0.45), Color(0.98, 0.85, 0.35), Color(0.95, 0.95, 0.9), Color(0.85, 0.4, 0.7)]
	for i in 4:
		var t: Vector2 = tilts[i]
		var ln: float = lens[i]
		var st := Node3D.new()
		st.position = vb
		st.rotation_degrees = Vector3(t.y, 0.0, t.x)
		n.add_child(st)
		_cyl(0.004, 0.004, ln, Vector3(0, ln / 2.0, 0), Color(0.25, 0.5, 0.25), st)
		_ball(0.034, Vector3(0, ln, 0), fcols[i], st)
	# chân nến đồng
	_shiny(_cyl(0.035, 0.035, 0.05, Vector3(0.5, 0.824, 0.0), Color(0.82, 0.66, 0.3), n), 0.3, 0.9)
	_cyl(0.014, 0.014, 0.1, Vector3(0.5, 0.899, 0.0), Color(0.97, 0.94, 0.85), n)
	_ball(0.01, Vector3(0.5, 0.96, 0.0), Color(1.0, 0.75, 0.25), n)
	# bộ đồ ăn trước mỗi ghế: tấm lót, đĩa, ly, dao, nĩa
	for px in [-0.6, 0.6]:
		for pz in [-0.27, 0.27]:
			var s := signf(pz)   # hướng về phía người ngồi
			_rbox(Vector3(0.4, 0.006, 0.28), Vector3(px, 0.797, pz), Color(0.78, 0.66, 0.46), n, 0.002)
			_shiny(_cyl(0.11, 0.09, 0.014, Vector3(px, 0.807, pz), Color(0.97, 0.97, 0.95), n), 0.2)
			_cyl(0.07, 0.07, 0.003, Vector3(px, 0.814, pz), Color(0.88, 0.9, 0.93), n)
			var gmat := _mat(Color(0.85, 0.93, 1.0, 0.35))
			gmat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
			gmat.roughness = 0.05
			var gl := _cyl(0.034, 0.028, 0.09, Vector3(px + 0.2, 0.845, pz - s * 0.12), Color.WHITE, n)
			gl.material_override = gmat
			_shiny(_box(Vector3(0.014, 0.004, 0.17), Vector3(px - 0.15, 0.802, pz), Color(0.8, 0.8, 0.82), n), 0.25, 0.85)
			_shiny(_box(Vector3(0.016, 0.004, 0.17), Vector3(px + 0.145, 0.802, pz), Color(0.8, 0.8, 0.82), n), 0.25, 0.85)
	_dchair(0.2, 1.2, 0.0)
	_dchair(1.4, 1.2, 0.0)
	_dchair(0.2, 2.8, 180.0)
	_dchair(1.4, 2.8, 180.0)

# Ghế ăn: chân thon có xà ngang, khung gỗ + đệm bọc, tựa lưng có thanh trên/dưới
func _dchair(x: float, z: float, yaw_deg: float) -> void:
	var n := _node(x, z, yaw_deg)
	var pink := Color(0.74, 0.44, 0.33)
	var pink_l := Color(0.83, 0.55, 0.42)
	var wd := Color(0.3, 0.18, 0.1)
	for sx in [-0.19, 0.19]:
		for sz in [-0.19, 0.19]:
			_leg(n, sx, sz, 0.45, 0.024, 0.016, 3.5, wd)
	# xà ngang nối chân
	for sx in [-0.19, 0.19]:
		_rbox(Vector3(0.02, 0.025, 0.36), Vector3(sx, 0.16, 0.0), wd, n, 0.008)
	_rbox(Vector3(0.36, 0.025, 0.02), Vector3(0, 0.16, 0.19), wd, n, 0.008)
	_rbox(Vector3(0.36, 0.025, 0.02), Vector3(0, 0.16, -0.19), wd, n, 0.008)
	# khung ghế + đệm ngồi có chỉ nổi
	_rbox(Vector3(0.46, 0.045, 0.46), Vector3(0, 0.465, 0), wd, n, 0.015)
	_rbox(Vector3(0.43, 0.06, 0.43), Vector3(0, 0.52, 0.01), pink, n, 0.025)
	_rbox(Vector3(0.44, 0.008, 0.44), Vector3(0, 0.494, 0.01), pink_l, n, 0.004)
	# tựa lưng nghiêng nhẹ
	var bp := Node3D.new()
	bp.position = Vector3(0, 0.46, -0.205)
	bp.rotation_degrees.x = -8.0
	n.add_child(bp)
	for sx in [-0.19, 0.19]:
		_rbox(Vector3(0.04, 0.52, 0.04), Vector3(sx, 0.26, 0), wd, bp, 0.014)
	_rbox(Vector3(0.44, 0.06, 0.045), Vector3(0, 0.51, 0), wd, bp, 0.02)
	_rbox(Vector3(0.34, 0.2, 0.045), Vector3(0, 0.36, 0), pink, bp, 0.03)
	_rbox(Vector3(0.34, 0.03, 0.035), Vector3(0, 0.17, 0), wd, bp, 0.01)
	for bx in [-0.08, 0.08]:
		_ball(0.01, Vector3(bx, 0.36, 0.024), pink_l, bp)

# Cây trong nhà kiểu Monstera: chậu gốm bo tròn có đĩa lót, đất phủ sỏi,
# nhiều cuống cong vòng, lá tim bóng có xẻ thùy và gân, vài lá non nhỏ ở gốc
func _build_plant(x: float, z: float) -> void:
	var n := _node(x, z, 0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 8

	# đĩa lót + chậu gốm (tạo bằng mặt tròn xoay, viền miệng bo mềm)
	var ceramic := StandardMaterial3D.new()
	ceramic.vertex_color_use_as_albedo = true
	ceramic.roughness = 0.35
	ceramic.cull_mode = BaseMaterial3D.CULL_DISABLED
	var saucer := MeshInstance3D.new()
	saucer.mesh = _lathe_mesh(PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(0.2, 0.0), Vector2(0.26, 0.02), Vector2(0.272, 0.045),
		Vector2(0.258, 0.047), Vector2(0.24, 0.032), Vector2(0.0, 0.03)]), 40,
		Color(0.62, 0.58, 0.52), Color(0.8, 0.76, 0.69), 0.05)
	saucer.material_override = ceramic
	n.add_child(saucer)
	var pot := MeshInstance3D.new()
	pot.mesh = _lathe_mesh(PackedVector2Array([
		Vector2(0.0, 0.0), Vector2(0.11, 0.0), Vector2(0.14, 0.015), Vector2(0.18, 0.1),
		Vector2(0.215, 0.28), Vector2(0.23, 0.42), Vector2(0.236, 0.48), Vector2(0.23, 0.507),
		Vector2(0.215, 0.507), Vector2(0.208, 0.485)]), 40,
		Color(0.72, 0.66, 0.58), Color(0.92, 0.88, 0.8), 0.51)
	pot.material_override = ceramic
	pot.position = Vector3(0, 0.03, 0)
	n.add_child(pot)
	var soil_top := 0.5
	_cyl(0.212, 0.212, 0.03, Vector3(0, soil_top - 0.015, 0), Color(0.2, 0.12, 0.07), n)

	# sỏi trang trí phủ mặt đất
	var pebble := SphereMesh.new()
	pebble.radius = 0.5
	pebble.height = 1.0
	pebble.radial_segments = 6
	pebble.rings = 3
	var pmat := StandardMaterial3D.new()
	pmat.vertex_color_use_as_albedo = true
	pmat.roughness = 0.8
	var pm := MultiMesh.new()
	pm.transform_format = MultiMesh.TRANSFORM_3D
	pm.use_colors = true
	pm.mesh = pebble
	pm.instance_count = 40
	for i in 40:
		var a := rng.randf() * TAU
		var rr := sqrt(rng.randf()) * 0.19
		var sz := rng.randf_range(0.02, 0.042)
		var b := Basis(Vector3.UP, rng.randf() * TAU) * Basis.IDENTITY.scaled(Vector3(sz * 1.2, sz * 0.6, sz))
		pm.set_instance_transform(i, Transform3D(b, Vector3(cos(a) * rr, soil_top + 0.003, sin(a) * rr)))
		var g := rng.randf_range(0.55, 0.88)
		pm.set_instance_color(i, Color(g, g * 0.98, g * 0.92))
	var pmi := MultiMeshInstance3D.new()
	pmi.multimesh = pm
	pmi.material_override = pmat
	pmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	n.add_child(pmi)

	# cuống + lá: 4 lá non nhỏ thấp, 9 lá lớn cao thấp xen kẽ
	var stem_mat := StandardMaterial3D.new()
	stem_mat.vertex_color_use_as_albedo = true
	stem_mat.roughness = 0.6
	var leaf_mat := _mon_leaf_material()
	var count := 13
	for i in count:
		var baby := i < 4
		var a := i * 137.5 * PI / 180.0 + rng.randf_range(-0.2, 0.2)
		var h := rng.randf_range(0.66, 0.82) if baby else rng.randf_range(0.8, 1.42)
		var r := rng.randf_range(0.18, 0.3) if baby else rng.randf_range(0.1, 0.42)
		var L := rng.randf_range(0.17, 0.23) if baby else rng.randf_range(0.36, 0.5)
		var dir := Vector3(cos(a), 0.0, sin(a))
		var p0 := dir * 0.03 + Vector3(0, soil_top - 0.02, 0)
		var p1 := dir * 0.02 + Vector3(0, soil_top + (h - soil_top) * 0.8, 0)
		var p2 := dir * r * 0.55 + Vector3(0, h + 0.06, 0)
		var p3 := dir * r + Vector3(0, h, 0)
		var pts := PackedVector3Array()
		var rad := PackedFloat32Array()
		for k in 17:
			var t := float(k) / 16.0
			pts.append(_bezier(p0, p1, p2, p3, t))
			rad.append(lerpf(0.017, 0.009, t))
		var st := MeshInstance3D.new()
		st.mesh = _tube_mesh(pts, rad, Color(0.2, 0.34, 0.1), Color(0.3, 0.5, 0.16), 7)
		st.material_override = stem_mat
		n.add_child(st)
		# lá đặt ở đầu cuống, hướng ra ngoài, lá cao thì chĩa lên nhiều hơn
		var holder := Node3D.new()
		holder.position = p3
		holder.rotation.y = atan2(dir.x, dir.z)
		n.add_child(holder)
		var blade := MeshInstance3D.new()
		blade.mesh = _mon_leaf_mesh(L, L * 0.52)
		blade.material_override = leaf_mat
		var hn := clampf((h - 0.66) / 0.76, 0.0, 1.0)
		blade.rotation_degrees = Vector3(-lerpf(4.0, 38.0, hn) + rng.randf_range(-6.0, 6.0), 0.0, rng.randf_range(-14.0, 14.0))
		holder.add_child(blade)

# Mặt tròn xoay quanh trục Y từ profile (bán kính, độ cao); dùng chung đỉnh nên không có đường nối
func _lathe_mesh(prof: PackedVector2Array, segs: int, c0: Color, c1: Color, ymax: float) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var np := prof.size()
	for i in np:
		var col := c0.lerp(c1, clampf(prof[i].y / ymax, 0.0, 1.0))
		for j in segs:
			var a := TAU * float(j) / float(segs)
			st.set_color(col)
			st.add_vertex(Vector3(cos(a) * prof[i].x, prof[i].y, sin(a) * prof[i].x))
	for i in np - 1:
		for j in segs:
			var j2 := (j + 1) % segs
			var a := i * segs + j
			var b := i * segs + j2
			var c := (i + 1) * segs + j
			var d := (i + 1) * segs + j2
			st.add_index(a)
			st.add_index(b)
			st.add_index(c)
			st.add_index(b)
			st.add_index(d)
			st.add_index(c)
	st.generate_normals()
	return st.commit()

# Lá Monstera: hình tim rộng, đầu nhọn, võng xuống và hơi cong lòng máng
# Mọc theo +Z, mặt trên +Y. UV.x ngang lá, UV.y gốc -> ngọn (shader vẽ gân + xẻ thùy)
func _mon_leaf_mesh(L: float, W: float) -> ArrayMesh:
	var rows := 20
	var cols := 14
	var pos := PackedVector3Array()
	var uv := PackedVector2Array()
	var col := PackedColorArray()
	for i in rows + 1:
		var u := float(i) / float(rows)
		var w := W * pow(maxf(0.0, sin(PI * pow(u, 0.45))), 0.7)
		for j in cols + 1:
			var v := float(j) / float(cols) * 2.0 - 1.0
			var zz := (u * (1.0 - 0.1 * u) - 0.06) * L
			var yy := L * (0.3 * u - 0.5 * u * u) + w * 0.25 * pow(absf(v), 1.5) + 0.01 * sin(u * 11.0 + v * 2.0) * absf(v)
			pos.append(Vector3(v * w, yy, zz))
			uv.append(Vector2(v * 0.5 + 0.5, u))
			col.append(Color.WHITE)
	return _grid_mesh(pos, uv, col, rows, cols, false)

func _mon_leaf_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_disabled, diffuse_burley;
global uniform float anim_t;

uniform vec3 dark_col : source_color = vec3(0.04, 0.2, 0.07);
uniform vec3 light_col : source_color = vec3(0.14, 0.45, 0.14);
uniform vec3 vein_col : source_color = vec3(0.45, 0.68, 0.3);

void vertex() {
	float ph = MODEL_MATRIX[3].x * 2.0 + MODEL_MATRIX[3].z * 3.0;
	VERTEX.y += sin(anim_t * 1.2 + ph) * 0.012 * UV.y * UV.y;
}

void fragment() {
	float d = abs(UV.x - 0.5) * 2.0;
	float u = UV.y;
	float s = u * 5.0 - d * 1.3;
	// xẻ thùy kiểu Monstera: khe hẹp ở gần gân, mở rộng ra mép lá
	float hw = 0.17 * smoothstep(0.42, 0.9, d) * smoothstep(0.1, 0.25, u) * (1.0 - smoothstep(0.85, 0.98, u));
	if (abs(fract(s) - 0.5) < hw) {
		discard;
	}
	float mid = (1.0 - smoothstep(0.0, 0.05, d)) * (1.0 - 0.45 * u);
	float lat = (1.0 - smoothstep(0.0, 0.06, abs(fract(s + 0.5) - 0.5))) * (1.0 - d * 0.55) * smoothstep(0.05, 0.2, u);
	vec3 col = mix(dark_col, light_col, 0.3 + 0.55 * u);
	col = mix(col, vein_col, clamp(mid * 0.9 + lat * 0.35, 0.0, 1.0));
	col *= 1.0 + 0.12 * d;
	if (!FRONT_FACING) {
		col = mix(col, vec3(0.3, 0.5, 0.25), 0.3);
	}
	ALBEDO = col;
	ROUGHNESS = 0.3;
	SPECULAR = 0.6;
	BACKLIGHT = col * 0.35;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	return mat

# ---------- Vườn cỏ xanh + ô hướng dương ----------
const GTOP := FY + 0.14   # mặt trên khối cỏ

func _build_garden() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	# viền đá cẩm thạch + khối cỏ
	_rbox(Vector3(8.4, FY, 3.8), Vector3(0, FY / 2.0, 5.3), Color(0.86, 0.87, 0.86))
	_rbox(Vector3(8.2, 0.14, 3.6), Vector3(0, FY + 0.07, 5.3), Color(0.2, 0.55, 0.14), self, 0.06)
	var plot := Rect2(-0.65, 4.75, 1.3, 1.1)   # ô đất hướng dương ở giữa (x, z, rộng, sâu)

	# cỏ: hàng chục nghìn lá cỏ thon, cong nhẹ, mềm như bông + shader gió đung đưa
	var n := 20000
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_custom_data = true
	mm.mesh = _grass_blade_mesh()
	mm.instance_count = n
	var k := 0
	while k < n:
		var px := rng.randf_range(-4.05, 4.05)
		var pz := rng.randf_range(3.55, 7.05)
		if plot.grow(0.15).has_point(Vector2(px, pz)):
			continue
		var sy := rng.randf_range(0.65, 1.35)
		var sx := rng.randf_range(0.8, 1.3)
		var e := Vector3(rng.randf_range(-0.2, 0.2), rng.randf() * TAU, rng.randf_range(-0.2, 0.2))
		var b := Basis.from_euler(e) * Basis.IDENTITY.scaled(Vector3(sx, sy, sx))
		mm.set_instance_transform(k, Transform3D(b, Vector3(px, GTOP - 0.01, pz)))
		# custom data: pha gió, độ đậm nhạt, biến thiên chiều cao
		mm.set_instance_custom_data(k, Color(rng.randf(), rng.randf(), sy, 1.0))
		k += 1
	var mmi := MultiMeshInstance3D.new()
	mmi.multimesh = mm
	mmi.material_override = _grass_material()
	mmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	mmi.custom_aabb = AABB(Vector3(-4.5, -0.2, 3.0), Vector3(9.0, 1.0, 4.6))
	add_child(mmi)

	# ô đất giữa vườn: khung gỗ + đất nâu
	_rbox(Vector3(1.3, 0.2, 1.1), Vector3(0, GTOP + 0.03, 5.3), Color(0.55, 0.38, 0.22), self, 0.04)
	_rbox(Vector3(1.1, 0.2, 0.9), Vector3(0, GTOP + 0.0, 5.3), Color(0.33, 0.2, 0.11), self, 0.05)
	_sunflower(0.0, 5.3, 0.55, 40.0)   # chỉ 1 bông hướng dương

# Một lá cỏ: thon dần về ngọn, cong cúp nhẹ, 5 đoạn để uốn mượt khi gió thổi
func _grass_blade_mesh() -> ArrayMesh:
	var segs := 5
	var H := 0.2
	var W := 0.026
	var verts := PackedVector3Array()
	var uvs := PackedVector2Array()
	var idx := PackedInt32Array()
	for i in segs + 1:
		var t := float(i) / float(segs)
		var w := W * pow(1.0 - t, 0.75) * (0.55 + 0.45 * smoothstep(0.0, 0.25, t + 0.15))
		var y := t * H
		var z := 0.32 * t * t * H   # lá cong về phía trước
		if i == segs:
			verts.append(Vector3(0, y, z))
			uvs.append(Vector2(0.5, t))
		else:
			verts.append(Vector3(-w, y, z))
			verts.append(Vector3(w, y, z))
			uvs.append(Vector2(0.0, t))
			uvs.append(Vector2(1.0, t))
	for i in segs - 1:
		var a := i * 2
		idx.append_array([a, a + 1, a + 2, a + 1, a + 3, a + 2])
	var top := (segs - 1) * 2
	idx.append_array([top, top + 1, top + 2])
	var normals := PackedVector3Array()
	for v in verts:
		normals.append(Vector3(0, 1, 0))
	var arr: Array = []
	arr.resize(Mesh.ARRAY_MAX)
	arr[Mesh.ARRAY_VERTEX] = verts
	arr[Mesh.ARRAY_NORMAL] = normals
	arr[Mesh.ARRAY_TEX_UV] = uvs
	arr[Mesh.ARRAY_INDEX] = idx
	var mesh := ArrayMesh.new()
	mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arr)
	return mesh

# Shader cỏ: gradient gốc tối -> ngọn sáng mềm, ánh xuyên sáng, gió lan thành sóng
func _grass_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_disabled, diffuse_burley, specular_disabled;
global uniform float anim_t;

uniform vec3 root_color : source_color = vec3(0.07, 0.30, 0.07);
uniform vec3 mid_color : source_color = vec3(0.22, 0.62, 0.14);
uniform vec3 tip_color : source_color = vec3(0.62, 0.86, 0.34);
uniform vec3 patch_color : source_color = vec3(0.45, 0.72, 0.12);
uniform vec2 wind_dir = vec2(1.0, 0.35);
uniform float wind_strength = 0.06;
uniform float wind_speed = 1.0;

varying float v_h;
varying float v_shade;
varying float v_tint;
varying float v_patch;
varying float v_side;

float hash21(vec2 p) {
	p = fract(p * vec2(123.34, 456.21));
	p += dot(p, p + 45.32);
	return fract(p.x * p.y);
}

float vnoise(vec2 p) {
	vec2 i = floor(p);
	vec2 f = fract(p);
	f = f * f * (3.0 - 2.0 * f);
	return mix(mix(hash21(i), hash21(i + vec2(1, 0)), f.x),
		mix(hash21(i + vec2(0, 1)), hash21(i + vec2(1, 1)), f.x), f.y);
}

void vertex() {
	vec3 origin = (MODEL_MATRIX * vec4(0.0, 0.0, 0.0, 1.0)).xyz;
	float h = UV.y;
	float t = anim_t * wind_speed;
	vec2 d = normalize(wind_dir);
	float ph = INSTANCE_CUSTOM.x * 6.2831;

	// sóng gió lớn lan qua cánh đồng + những cơn gió giật nhẹ
	float along = dot(origin.xz, d);
	float wave = sin(along * 0.9 - t * 1.5) * 0.5 + 0.5;
	float gust = vnoise(origin.xz * 0.35 - d * t * 0.55);
	float flow = 0.30 + 0.45 * wave + 0.55 * gust;

	// rung nhẹ từng lá, lệch pha nhau
	float flutter = sin(t * 2.6 + ph + origin.x * 1.7) * 0.5 + sin(t * 4.1 + ph * 1.7 + origin.z * 2.3) * 0.25;

	float bend = h * h * (flow + flutter * 0.28);
	vec2 perp = vec2(-d.y, d.x);
	vec3 wo = vec3(d.x, 0.0, d.y) * bend * wind_strength * 3.2;
	wo += vec3(perp.x, 0.0, perp.y) * sin(t * 1.9 + ph) * h * h * wind_strength * 0.9;
	VERTEX += inverse(mat3(MODEL_MATRIX)) * wo;
	VERTEX.y -= bend * bend * wind_strength * 1.5;   // cúi xuống nhưng không dài ra

	NORMAL = vec3(0.0, 1.0, 0.0);   // pháp tuyến hướng lên: bề mặt cỏ mịn như thảm
	v_h = h;
	v_shade = clamp(flow * 0.7 + flutter * 0.2, 0.0, 1.0);
	v_tint = INSTANCE_CUSTOM.y;
	v_patch = vnoise(origin.xz * 0.55);
	v_side = UV.x;
}

void fragment() {
	float h = v_h;
	vec3 col = mix(root_color, mid_color, smoothstep(0.0, 0.5, h));
	col = mix(col, tip_color, smoothstep(0.35, 1.0, h));
	col = mix(col, patch_color * (0.55 + 0.6 * h), v_patch * 0.45);     // mảng cỏ sáng/tối tự nhiên
	col *= 0.86 + 0.28 * v_tint;                                          // mỗi lá một sắc độ
	col += vec3(0.05, 0.07, 0.01) * smoothstep(0.7, 1.0, h);             // ngọn hơi óng nắng, mịn như bông
	float vein = 1.0 - abs(v_side - 0.5) * 2.0;
	col *= 0.9 + 0.14 * vein;                                             // gân giữa lá sáng hơn một chút
	col *= 1.0 + v_shade * 0.14 * h;                                      // cỏ ngả theo gió sáng lên như lớp lông

	ALBEDO = col;
	ROUGHNESS = 1.0;
	AO = mix(0.25, 1.0, smoothstep(0.0, 0.7, h));                         // chân cỏ đổ bóng sâu -> có chiều sâu
	AO_LIGHT_AFFECT = 0.8;
	BACKLIGHT = col * 0.55;                                               // ánh sáng xuyên lá, mềm mại
	EMISSION = col * 0.06 * h;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	return mat

# Hoa hướng dương (1 bông): thân cong có độ thon, lá tim có gân, đầu hoa 3 lớp cánh,
# nhụy xếp xoắn ốc Fibonacci, đài lá bắc xanh phía sau, đung đưa nhẹ theo gió
func _sunflower(x: float, z: float, s: float, face: float) -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 21
	var root := Node3D.new()
	root.position = Vector3(x, GTOP + 0.1, z)
	root.scale = Vector3(s, s, s)
	add_child(root)

	# ---- hướng đầu hoa + đường cong của thân ----
	var yaw := deg_to_rad(face)
	var pit := deg_to_rad(15.0)
	var n_vec := Vector3(sin(yaw) * cos(pit), sin(pit), cos(yaw) * cos(pit))
	var stem_h := 1.7
	var head_center := Vector3(sin(yaw), 0.0, cos(yaw)) * 0.42 + Vector3(0, stem_h, 0)
	var p3 := head_center - n_vec * 0.14
	var t_end := (n_vec * 0.7 + Vector3.UP * 0.6).normalized()
	var p0 := Vector3.ZERO
	var p1 := Vector3(0, stem_h * 0.45, 0)
	var p2 := p3 - t_end * 0.55
	var pts := PackedVector3Array()
	var radii := PackedFloat32Array()
	var ns := 28
	for i in ns + 1:
		var t := float(i) / float(ns)
		pts.append(_bezier(p0, p1, p2, p3, t))
		radii.append(lerpf(0.06, 0.04, t) + 0.02 * pow(t, 6.0))
	var stem_mat := StandardMaterial3D.new()
	stem_mat.vertex_color_use_as_albedo = true
	stem_mat.roughness = 0.75
	var stem := MeshInstance3D.new()
	stem.mesh = _tube_mesh(pts, radii, Color(0.18, 0.36, 0.08), Color(0.33, 0.56, 0.16), 10)
	stem.material_override = stem_mat
	root.add_child(stem)

	# ---- lá tim lớn mọc xoắn quanh thân, lá càng cao càng nhỏ ----
	var leaf_mat := _sf_leaf_material()
	var leaf_t := [0.1, 0.2, 0.3, 0.42, 0.54, 0.66, 0.78]
	for i in leaf_t.size():
		var idx := int(leaf_t[i] * ns)
		var sp: Vector3 = pts[idx]
		var L := lerpf(0.62, 0.3, float(i) / float(leaf_t.size() - 1))
		var holder := Node3D.new()
		holder.position = sp
		holder.rotation_degrees.y = 20.0 + i * 137.5
		root.add_child(holder)
		var k := L / 0.5
		var ppts := PackedVector3Array([Vector3(0, 0, 0), Vector3(0, 0.04, 0.08) * k, Vector3(0, 0.09, 0.17) * k])
		var prad := PackedFloat32Array([0.014, 0.011, 0.008])
		var pet := MeshInstance3D.new()
		pet.mesh = _tube_mesh(ppts, prad, Color(0.24, 0.46, 0.1), Color(0.3, 0.54, 0.14), 6)
		pet.material_override = stem_mat
		holder.add_child(pet)
		var blade := MeshInstance3D.new()
		blade.mesh = _sf_leaf_mesh(L, L * 0.46)
		blade.material_override = leaf_mat
		blade.position = Vector3(0, 0.09, 0.17) * k
		blade.rotation_degrees.x = -8.0
		holder.add_child(blade)

	# ---- đầu hoa (mặt hoa quay về +Z của node head) ----
	var head := Node3D.new()
	head.position = head_center
	head.rotation_degrees = Vector3(-15.0, face, 0.0)
	root.add_child(head)
	var R := 0.34

	# mặt sau: vòm xanh + lá bắc nhọn
	var green := _mat(Color(0.2, 0.4, 0.1))
	green.roughness = 0.8
	var dome := MeshInstance3D.new()
	var sph := SphereMesh.new()
	sph.radius = 0.5
	sph.height = 1.0
	dome.mesh = sph
	dome.material_override = green
	dome.scale = Vector3(0.64, 0.64, 0.2)
	dome.position = Vector3(0, 0, -0.075)
	head.add_child(dome)
	var bract_mat := StandardMaterial3D.new()
	bract_mat.vertex_color_use_as_albedo = true
	bract_mat.roughness = 0.7
	bract_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	var bract_mesh := _petal_mesh(0.2, 0.07, Color(0.16, 0.32, 0.07), Color(0.24, 0.45, 0.1), Color(0.36, 0.55, 0.14))
	_petal_layer(head, bract_mesh, bract_mat, 22, 0.18, -28.0, -0.05, 0.0, rng)
	_petal_layer(head, bract_mesh, bract_mat, 22, 0.2, -16.0, -0.04, 0.5, rng)

	# 3 lớp cánh vàng (màu chuyển cam đậm gốc -> vàng chanh ngọn, gân giữa cánh sẫm hơn)
	var petal_mat := StandardMaterial3D.new()
	petal_mat.vertex_color_use_as_albedo = true
	petal_mat.roughness = 0.55
	petal_mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	petal_mat.backlight_enabled = true
	petal_mat.backlight = Color(0.55, 0.32, 0.0)
	var c_base := Color(0.95, 0.5, 0.04)
	var c_mid := Color(1.0, 0.76, 0.06)
	var c_tip := Color(1.0, 0.88, 0.18)
	var pm_back := _petal_mesh(0.5, 0.095, c_base, c_mid, c_tip)
	var pm_mid := _petal_mesh(0.45, 0.09, c_base, c_mid, c_tip)
	var pm_front := _petal_mesh(0.33, 0.07, c_base, c_mid, c_tip)
	_petal_layer(head, pm_back, petal_mat, 26, 0.3, -10.0, -0.025, 0.0, rng)
	_petal_layer(head, pm_mid, petal_mat, 26, 0.29, -2.0, 0.0, 0.5, rng)
	_petal_layer(head, pm_front, petal_mat, 26, 0.3, 8.0, 0.012, 0.25, rng)

	# đĩa nhụy: nền nâu đậm + 820 hạt xếp xoắn ốc Fibonacci
	var disc := MeshInstance3D.new()
	disc.mesh = sph
	disc.material_override = _mat(Color(0.12, 0.06, 0.02))
	disc.scale = Vector3(R * 2.0, R * 2.0, 0.18)
	disc.position = Vector3(0, 0, -0.01)
	head.add_child(disc)
	var fl := SphereMesh.new()
	fl.radius = 0.5
	fl.height = 1.0
	fl.radial_segments = 6
	fl.rings = 3
	var fmat := StandardMaterial3D.new()
	fmat.vertex_color_use_as_albedo = true
	fmat.roughness = 0.9
	var nf := 820
	var fm := MultiMesh.new()
	fm.transform_format = MultiMesh.TRANSFORM_3D
	fm.use_colors = true
	fm.mesh = fl
	fm.instance_count = nf
	var ga := PI * (3.0 - sqrt(5.0))
	for i in nf:
		var t := sqrt((float(i) + 0.5) / float(nf))
		var rr := R * 0.97 * t
		var a := float(i) * ga
		var zz := -0.01 + 0.09 * sqrt(maxf(0.0, 1.0 - t * t * 0.94)) + 0.006
		var sz := (0.85 + 0.4 * t) * 0.026
		var rot := Basis(Vector3.BACK, a + 1.0) * Basis(Vector3.RIGHT, rng.randf_range(-0.3, 0.3))
		var b := rot * Basis.IDENTITY.scaled(Vector3(sz * 1.1, sz, sz * 0.85))
		fm.set_instance_transform(i, Transform3D(b, Vector3(cos(a) * rr, sin(a) * rr, zz)))
		var col: Color
		if t < 0.16:
			col = Color(0.3, 0.3, 0.08).lerp(Color(0.22, 0.13, 0.04), t / 0.16)
		elif t < 0.82:
			col = Color(0.22, 0.12, 0.035).lerp(Color(0.15, 0.075, 0.02), (t - 0.16) / 0.66)
		else:
			col = Color(0.15, 0.075, 0.02).lerp(Color(0.62, 0.36, 0.06), (t - 0.82) / 0.18)
		col = col * rng.randf_range(0.85, 1.2)
		col.a = 1.0
		fm.set_instance_color(i, col)
	var fmi := MultiMeshInstance3D.new()
	fmi.multimesh = fm
	fmi.material_override = fmat
	fmi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	head.add_child(fmi)

	# ---- gió: cả cây đung đưa rất nhẹ, hai trục lệch nhịp nhau ----
	root.rotation_degrees.z = -1.2
	var tw := create_tween().set_loops()
	tw.tween_property(root, "rotation_degrees:z", 1.6, 2.6).from(-1.2).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(root, "rotation_degrees:z", -1.2, 2.6).from(1.6).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	var tw2 := create_tween().set_loops()
	tw2.tween_property(root, "rotation_degrees:x", 1.0, 3.7).from(-0.8).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw2.tween_property(root, "rotation_degrees:x", -0.8, 3.7).from(1.0).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)

func _bezier(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var u := 1.0 - t
	return p0 * (u * u * u) + p1 * (3.0 * u * u * t) + p2 * (3.0 * u * t * t) + p3 * (t * t * t)

# Ống tròn dọc theo đường cong (thân, cuống lá), màu chuyển từ c0 -> c1
func _tube_mesh(pts: PackedVector3Array, radii: PackedFloat32Array, c0: Color, c1: Color, sides: int) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	var n := pts.size()
	for i in n:
		var tv: Vector3
		if i == 0:
			tv = pts[1] - pts[0]
		elif i == n - 1:
			tv = pts[n - 1] - pts[n - 2]
		else:
			tv = pts[i + 1] - pts[i - 1]
		tv = tv.normalized()
		var ref := Vector3.RIGHT if absf(tv.dot(Vector3.RIGHT)) < 0.9 else Vector3.FORWARD
		var sd := tv.cross(ref).normalized()
		var up := sd.cross(tv).normalized()
		var col := c0.lerp(c1, float(i) / float(n - 1))
		for j in sides + 1:
			var a := TAU * float(j) / float(sides)
			var dir := sd * cos(a) + up * sin(a)
			st.set_color(col)
			st.set_normal(dir)
			st.set_uv(Vector2(float(j) / float(sides), float(i) / float(n - 1)))
			st.add_vertex(pts[i] + dir * radii[i])
	var w := sides + 1
	for i in n - 1:
		for j in sides:
			var a := i * w + j
			var b := a + 1
			var c := a + w
			var d := c + 1
			st.add_index(a)
			st.add_index(b)
			st.add_index(c)
			st.add_index(b)
			st.add_index(d)
			st.add_index(c)
	return st.commit()

# Lưới bề mặt (rows x cols ô), flip = đảo chiều mặt trước
func _grid_mesh(pos: PackedVector3Array, uv: PackedVector2Array, col: PackedColorArray, rows: int, cols: int, flip: bool) -> ArrayMesh:
	var st := SurfaceTool.new()
	st.begin(Mesh.PRIMITIVE_TRIANGLES)
	for k in pos.size():
		st.set_color(col[k])
		st.set_uv(uv[k])
		st.add_vertex(pos[k])
	var w := cols + 1
	for i in rows:
		for j in cols:
			var a := i * w + j
			var b := a + 1
			var c := a + w
			var d := c + 1
			if flip:
				st.add_index(a)
				st.add_index(c)
				st.add_index(b)
				st.add_index(b)
				st.add_index(c)
				st.add_index(d)
			else:
				st.add_index(a)
				st.add_index(b)
				st.add_index(c)
				st.add_index(b)
				st.add_index(d)
				st.add_index(c)
	st.generate_normals()
	return st.commit()

# Một cánh hoa: hẹp ở gốc, rộng nhất ~40%, nhọn ở ngọn, cong cúp và có rãnh giữa
# Nằm trong mặt phẳng XY, mọc theo +Y, mặt trước hướng +Z
func _petal_mesh(L: float, W: float, c_base: Color, c_mid: Color, c_tip: Color) -> ArrayMesh:
	var rows := 8
	var cols := 4
	var pos := PackedVector3Array()
	var uv := PackedVector2Array()
	var col := PackedColorArray()
	for i in rows + 1:
		var u := float(i) / float(rows)
		var w := W * pow(maxf(0.0, sin(PI * pow(u, 0.7))), 0.85)
		for j in cols + 1:
			var v := float(j) / float(cols) * 2.0 - 1.0
			var zz := L * 0.12 * u * u + 0.18 * w * v * v
			pos.append(Vector3(v * w, u * L, zz))
			uv.append(Vector2(v * 0.5 + 0.5, u))
			var c := c_base.lerp(c_mid, smoothstep(0.0, 0.4, u)).lerp(c_tip, smoothstep(0.4, 1.0, u))
			c = c * (1.0 - 0.12 * (1.0 - absf(v)))
			c.a = 1.0
			col.append(c)
	return _grid_mesh(pos, uv, col, rows, cols, true)

# Rải 1 lớp cánh (MultiMesh) quanh tâm đầu hoa
func _petal_layer(parent: Node3D, mesh: ArrayMesh, mat: Material, n: int, r0: float, tilt_deg: float, z0: float, off: float, rng: RandomNumberGenerator) -> void:
	var mm := MultiMesh.new()
	mm.transform_format = MultiMesh.TRANSFORM_3D
	mm.use_colors = true
	mm.mesh = mesh
	mm.instance_count = n
	for i in n:
		var a := (float(i) + off) / float(n) * TAU + rng.randf_range(-0.04, 0.04)
		var tilt := deg_to_rad(tilt_deg + rng.randf_range(-6.0, 6.0))
		var rot := Basis(Vector3.BACK, a - PI / 2.0) * Basis(Vector3.RIGHT, tilt) * Basis(Vector3.UP, rng.randf_range(-0.2, 0.2))
		var b := rot * Basis.IDENTITY.scaled(Vector3(rng.randf_range(0.9, 1.12), rng.randf_range(0.88, 1.1), 1.0))
		mm.set_instance_transform(i, Transform3D(b, Vector3(cos(a) * r0, sin(a) * r0, z0 + rng.randf_range(-0.004, 0.004))))
		mm.set_instance_color(i, Color(1.0, rng.randf_range(0.9, 1.04), rng.randf_range(0.85, 1.05)))
	var mi := MultiMeshInstance3D.new()
	mi.multimesh = mm
	mi.material_override = mat
	mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	parent.add_child(mi)

# Lá tim: gốc rộng, đầu nhọn, mép răng cưa nhẹ, võng xuống và gợn sóng
# Mọc theo +Z, mặt trên hướng +Y. UV.x ngang lá, UV.y từ gốc -> ngọn (shader vẽ gân)
func _sf_leaf_mesh(L: float, W: float) -> ArrayMesh:
	var rows := 14
	var cols := 10
	var pos := PackedVector3Array()
	var uv := PackedVector2Array()
	var col := PackedColorArray()
	for i in rows + 1:
		var u := float(i) / float(rows)
		var w := W * pow(maxf(0.0, sin(PI * pow(u, 0.55))), 0.75) * (1.0 + 0.04 * sin(u * 46.0))
		for j in cols + 1:
			var v := float(j) / float(cols) * 2.0 - 1.0
			var zz := u * L * (1.0 - 0.12 * u)
			var yy := L * (0.26 * u - 0.6 * u * u) + w * 0.22 * pow(absf(v), 1.6) + 0.012 * sin(u * 13.0 + v * 2.5) * absf(v)
			pos.append(Vector3(v * w, yy, zz))
			uv.append(Vector2(v * 0.5 + 0.5, u))
			col.append(Color.WHITE)
	return _grid_mesh(pos, uv, col, rows, cols, false)

func _sf_leaf_material() -> ShaderMaterial:
	var sh := Shader.new()
	sh.code = """
shader_type spatial;
render_mode cull_disabled, diffuse_burley;
global uniform float anim_t;

uniform vec3 dark_col : source_color = vec3(0.10, 0.30, 0.06);
uniform vec3 light_col : source_color = vec3(0.30, 0.58, 0.14);
uniform vec3 vein_col : source_color = vec3(0.55, 0.72, 0.30);

void vertex() {
	float ph = MODEL_MATRIX[3].x * 2.0 + MODEL_MATRIX[3].z * 3.0;
	VERTEX.y += sin(anim_t * 1.5 + ph) * 0.02 * UV.y * UV.y;
	VERTEX.x += sin(anim_t * 1.1 + ph * 1.3) * 0.01 * UV.y;
}

void fragment() {
	float d = abs(UV.x - 0.5) * 2.0;
	float u = UV.y;
	float mid = (1.0 - smoothstep(0.0, 0.06, d)) * (1.0 - 0.5 * u);
	float s = u * 7.0 - d * 2.4;
	float lat = (1.0 - smoothstep(0.0, 0.07, abs(fract(s) - 0.5))) * (1.0 - d * 0.6) * smoothstep(0.04, 0.2, u);
	vec3 col = mix(dark_col, light_col, 0.35 + 0.5 * u);
	col = mix(col, vein_col, clamp(mid * 0.85 + lat * 0.4, 0.0, 1.0));
	col *= 1.0 + 0.1 * d;
	if (!FRONT_FACING) {
		col = mix(col, vec3(0.45, 0.62, 0.3), 0.3);
	}
	ALBEDO = col;
	ROUGHNESS = 0.55;
	BACKLIGHT = col * 0.45;
}
"""
	var mat := ShaderMaterial.new()
	mat.shader = sh
	return mat

func _tree(pos: Vector3, s: float) -> void:
	var trunk := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.12 * s
	cm.bottom_radius = 0.16 * s
	cm.height = 1.2 * s
	trunk.mesh = cm
	trunk.material_override = _mat(Color(0.4, 0.27, 0.15))
	trunk.position = pos + Vector3(0, 0.6 * s, 0)
	add_child(trunk)
	var leaf := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.7 * s
	sm.height = 1.4 * s
	leaf.mesh = sm
	leaf.material_override = _mat(Color(0.2, 0.55, 0.2))
	leaf.position = pos + Vector3(0, 1.5 * s, 0)
	add_child(leaf)

func _flower(pos: Vector3, c: Color) -> void:
	_box(Vector3(0.03, 0.35, 0.03), pos + Vector3(0, 0.18, 0), Color(0.2, 0.5, 0.2))
	var head := MeshInstance3D.new()
	var sm := SphereMesh.new()
	sm.radius = 0.1
	sm.height = 0.2
	head.mesh = sm
	head.material_override = _mat(c)
	head.position = pos + Vector3(0, 0.4, 0)
	add_child(head)

# ---------- Lịch treo tường (bố cục theo lịch mẫu: vòng lò xo đồng, tiêu đề, ngày tròn, lưới tháng) ----------
const CAL_X := 1.95            # nằm giữa TV và tranh, không đè lên TV nữa
const CAL_Y := FY + 1.85
const CAL_W := 0.84
const CAL_H := 1.292
const CAL_Z := -2.9835         # mặt giấy (tường trong ở z = -3.0)

func _cp(u: float, v: float, dz: float = 0.0) -> Vector3:
	return Vector3(CAL_X + (u - 0.5) * CAL_W, CAL_Y + (0.5 - v) * CAL_H, CAL_Z + dz)

func _metal(c: Color) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = c
	m.metallic = 0.85
	m.roughness = 0.3
	return m

# thanh trụ nối 2 điểm (dây treo)
func _rod(a: Vector3, b: Vector3, r: float, m: Material) -> MeshInstance3D:
	var mi := MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = r
	cm.bottom_radius = r
	cm.height = a.distance_to(b)
	cm.radial_segments = 8
	mi.mesh = cm
	mi.material_override = m
	mi.position = (a + b) * 0.5
	mi.basis = Basis(Quaternion(Vector3.UP, (b - a).normalized()))
	add_child(mi)
	return mi

func _label2(pos: Vector3, text: String, size: int, px: float, c: Color, font: Font = null) -> Label3D:
	var l := Label3D.new()
	l.position = pos
	l.text = text
	l.font_size = size
	l.pixel_size = px
	l.modulate = c
	l.outline_size = 4 if size >= 100 else (2 if size >= 44 else 1)   # viền cùng màu → chữ đậm hơn
	l.outline_modulate = c
	l.shaded = true
	if font != null:
		l.font = font
	add_child(l)
	return l

func _sys_font(names: Array, italic: bool, weight: int) -> SystemFont:
	var f := SystemFont.new()
	f.font_names = PackedStringArray(names)
	f.font_italic = italic
	f.font_weight = weight
	return f

var cal_cells: Array = []
var cal_lunar: Array = []
var cal_lunar_a: Label3D
var cal_lunar_b: Label3D
var cal_today: MeshInstance3D
var cal_year: Label3D

func _build_calendar() -> void:
	var jdv := _pick_cal_theme()
	cal_accent_labels.clear()
	var ytop := CAL_Y + CAL_H * 0.5
	var copper := _metal(Color(0.80, 0.52, 0.42))
	var rose := cal_accent
	var grey := Color(0.40, 0.40, 0.43)
	# bóng đổ mềm sau tờ lịch
	var sh := MeshInstance3D.new()
	var shq := QuadMesh.new()
	shq.size = Vector2(CAL_W + 0.05, CAL_H + 0.05)
	sh.mesh = shq
	var shm := StandardMaterial3D.new()
	shm.albedo_color = Color(0, 0, 0, 0.14)
	shm.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	shm.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	sh.material_override = shm
	sh.position = Vector3(CAL_X + 0.012, CAL_Y - 0.014, -2.997)
	sh.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	add_child(sh)
	# thân giấy + mặt in hoa văn
	_box(Vector3(CAL_W, CAL_H, 0.016), Vector3(CAL_X, CAL_Y, -2.992), Color(0.98, 0.95, 0.93))
	var pq := MeshInstance3D.new()
	var pqm := QuadMesh.new()
	pqm.size = Vector2(CAL_W, CAL_H)
	pq.mesh = pqm
	var pm := StandardMaterial3D.new()
	pm.albedo_texture = _calendar_tex(cal_theme, jdv)
	pm.roughness = 0.85
	pm.texture_filter = BaseMaterial3D.TEXTURE_FILTER_LINEAR_WITH_MIPMAPS_ANISOTROPIC
	pq.material_override = pm
	cal_pq_mat = pm
	pq.position = Vector3(CAL_X, CAL_Y, CAL_Z)
	add_child(pq)
	# lò xo đồng dọc mép trên + thanh ngang
	_rod(Vector3(CAL_X - CAL_W * 0.5 + 0.02, ytop + 0.004, -2.98), Vector3(CAL_X + CAL_W * 0.5 - 0.02, ytop + 0.004, -2.98), 0.0035, copper)
	for i in 17:
		var rx := CAL_X - CAL_W * 0.5 + 0.03 + i * ((CAL_W - 0.06) / 16.0)
		var ring := MeshInstance3D.new()
		var tm := TorusMesh.new()
		tm.inner_radius = 0.014
		tm.outer_radius = 0.021
		tm.rings = 16
		tm.ring_segments = 8
		ring.mesh = tm
		ring.material_override = copper
		ring.rotation_degrees = Vector3(0, 0, 90)
		ring.position = Vector3(rx, ytop - 0.004, -2.983)
		add_child(ring)
	# dây treo chữ V + đinh + kẹp
	var nail := Vector3(CAL_X, ytop + 0.2, -2.985)
	_rod(Vector3(CAL_X - CAL_W * 0.5 + 0.02, ytop + 0.004, -2.98), nail, 0.002, copper)
	_rod(Vector3(CAL_X + CAL_W * 0.5 - 0.02, ytop + 0.004, -2.98), nail, 0.002, copper)
	var nb := _ball(0.014, nail, Color.WHITE)
	nb.material_override = copper
	var clip := _rbox(Vector3(0.035, 0.022, 0.012), nail + Vector3(0, -0.03, 0.002), Color.WHITE, self, 0.004)
	clip.material_override = copper
	# chữ
	var script_font := _sys_font(["Segoe Script", "Brush Script MT", "Lucida Handwriting", "Snell Roundhand", "Apple Chancery", "Comic Sans MS"], true, 700)
	var bold_font := _sys_font(["Arial", "Helvetica", "Noto Sans", "sans-serif"], false, 700)
	var reg_font := _sys_font(["Arial", "Helvetica", "Noto Sans", "sans-serif"], false, 700)
	var tz := 0.0055
	cal_accent_labels.append(_label2(_cp(0.5, 0.125, tz), "Calendar", 135, 0.001, rose, script_font))
	cal_year = _label2(_cp(0.5, 0.235, tz), "2026", 130, 0.001, grey, bold_font)
	cal_day = _label2(_cp(0.21, 0.5, tz + 0.001), "20", 140, 0.001, Color(1, 1, 1), bold_font)
	cal_accent_labels.append(_label2(_cp(0.21, 0.625, tz), "Tháng", 58, 0.001, rose, bold_font))
	cal_month = _label2(_cp(0.21, 0.715, tz), "11", 140, 0.001, grey, bold_font)
	cal_week = _label2(_cp(0.21, 0.815, tz), "Thứ sáu", 58, 0.001, rose, bold_font)
	cal_accent_labels.append(cal_week)
	cal_lunar_a = _label2(_cp(0.21, 0.875, tz), "", 40, 0.001, Color(0.78, 0.30, 0.30), bold_font)
	cal_lunar_b = _label2(_cp(0.21, 0.925, tz), "", 40, 0.001, rose, bold_font)
	cal_accent_labels.append(cal_lunar_b)
	# tiêu đề các thứ (tuần bắt đầu từ thứ hai)
	var heads := ["T2", "T3", "T4", "T5", "T6", "T7", "CN"]
	for c in 7:
		var hc := cal_accent if c >= 5 else Color(0.42, 0.30, 0.32)
		var hl := _label2(_cp(0.47 + c * 0.0775, 0.545, tz), heads[c], 42, 0.001, hc, bold_font)
		if c >= 5:
			cal_accent_labels.append(hl)
	# điểm tròn đánh dấu hôm nay (nằm dưới số, ôm cả số dương lẫn âm)
	cal_today = MeshInstance3D.new()
	var cm := CylinderMesh.new()
	cm.top_radius = 0.031
	cm.bottom_radius = 0.031
	cm.height = 0.002
	cm.radial_segments = 24
	cal_today.mesh = cm
	cal_disc_mat = _mat(cal_circle)
	cal_today.material_override = cal_disc_mat
	cal_today.rotation_degrees = Vector3(90, 0, 0)
	add_child(cal_today)
	# 42 ô ngày: số dương lịch to + số âm lịch nhỏ bên dưới
	cal_cells.clear()
	cal_lunar.clear()
	for r in 6:
		for c in 7:
			var sp := _cp(0.47 + c * 0.0775, 0.612 + r * 0.058, tz)
			cal_cells.append(_label2(sp, "", 48, 0.001, Color(0.30, 0.26, 0.28), bold_font))
			cal_lunar.append(_label2(sp + Vector3(0, -0.034, 0), "", 26, 0.001, Color(0.55, 0.42, 0.44), bold_font))

# ---------- Âm lịch Việt Nam (thuật toán Hồ Ngọc Đức, múi giờ UTC+7) ----------
@warning_ignore("integer_division")
func _jd_from_date(dd: int, mm: int, yy: int) -> int:
	var a := (14 - mm) / 12
	var y := yy + 4800 - a
	var m := mm + 12 * a - 3
	var jd := dd + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045
	if jd < 2299161:
		jd = dd + (153 * m + 2) / 5 + 365 * y + y / 4 - 32083
	return jd

func _new_moon(k: int, tz: float) -> int:
	var T := k / 1236.85
	var T2 := T * T
	var T3 := T2 * T
	var dr := PI / 180.0
	var jd1 := 2415020.75933 + 29.53058868 * k + 0.0001178 * T2 - 0.000000155 * T3
	jd1 += 0.00033 * sin((166.56 + 132.87 * T - 0.009173 * T2) * dr)
	var M := 359.2242 + 29.10535608 * k - 0.0000333 * T2 - 0.00000347 * T3
	var Mpr := 306.0253 + 385.81691806 * k + 0.0107306 * T2 + 0.00001236 * T3
	var F := 21.2964 + 390.67050646 * k - 0.0016528 * T2 - 0.00000239 * T3
	var c1 := (0.1734 - 0.000393 * T) * sin(M * dr) + 0.0021 * sin(2.0 * dr * M)
	c1 -= 0.4068 * sin(Mpr * dr) - 0.0161 * sin(dr * 2.0 * Mpr)
	c1 -= 0.0004 * sin(dr * 3.0 * Mpr)
	c1 += 0.0104 * sin(dr * 2.0 * F) - 0.0051 * sin(dr * (M + Mpr))
	c1 -= 0.0074 * sin(dr * (M - Mpr)) - 0.0004 * sin(dr * (2.0 * F + M))
	c1 -= 0.0004 * sin(dr * (2.0 * F - M)) + 0.0006 * sin(dr * (2.0 * F + Mpr))
	c1 += 0.0010 * sin(dr * (2.0 * F - Mpr)) + 0.0005 * sin(dr * (2.0 * Mpr + M))
	var dt: float
	if T < -11.0:
		dt = 0.001 + 0.000839 * T + 0.0002261 * T2 - 0.00000845 * T3 - 0.000000081 * T * T3
	else:
		dt = -0.000278 + 0.000265 * T + 0.000262 * T2
	return int(jd1 + c1 - dt + 0.5 + tz / 24.0)

func _sun_longitude(jdn: int, tz: float) -> int:
	var T := (jdn - 2451545.5 - tz / 24.0) / 36525.0
	var T2 := T * T
	var dr := PI / 180.0
	var M := 357.52910 + 35999.05030 * T - 0.0001559 * T2 - 0.00000048 * T * T2
	var L0 := 280.46645 + 36000.76983 * T + 0.0003032 * T2
	var dl := (1.914600 - 0.004817 * T - 0.000014 * T2) * sin(dr * M)
	dl += (0.019993 - 0.000101 * T) * sin(dr * 2.0 * M) + 0.000290 * sin(dr * 3.0 * M)
	var L := (L0 + dl) * dr
	L -= PI * 2.0 * int(L / (PI * 2.0))
	return int(L / PI * 6.0)

func _lunar_month11(yy: int, tz: float) -> int:
	var off := _jd_from_date(31, 12, yy) - 2415021
	var k := int(off / 29.530588853)
	var nm := _new_moon(k, tz)
	if _sun_longitude(nm, tz) >= 9:
		nm = _new_moon(k - 1, tz)
	return nm

func _leap_offset(a11: int, tz: float) -> int:
	var k := int((a11 - 2415021.076998695) / 29.530588853 + 0.5)
	var i := 1
	var arc := _sun_longitude(_new_moon(k + i, tz), tz)
	var last := 0
	while true:
		last = arc
		i += 1
		arc = _sun_longitude(_new_moon(k + i, tz), tz)
		if arc == last or i >= 14:
			break
	return i - 1

# trả về [ngày âm, tháng âm, năm âm, nhuận(0/1)]
func _solar_to_lunar(dd: int, mm: int, yy: int) -> Array:
	var tz := 7.0
	var day_number := _jd_from_date(dd, mm, yy)
	var k := int((day_number - 2415021.076998695) / 29.530588853)
	var month_start := _new_moon(k + 1, tz)
	if month_start > day_number:
		month_start = _new_moon(k, tz)
	var a11 := _lunar_month11(yy, tz)
	var b11 := a11
	var lunar_year := yy
	if a11 >= month_start:
		a11 = _lunar_month11(yy - 1, tz)
	else:
		lunar_year = yy + 1
		b11 = _lunar_month11(yy + 1, tz)
	var lunar_day := day_number - month_start + 1
	var diff := int((month_start - a11) / 29.0)
	var leap := 0
	var lunar_month := diff + 11
	if b11 - a11 > 365:
		var leap_diff := _leap_offset(a11, tz)
		if diff >= leap_diff:
			lunar_month = diff + 10
			if diff == leap_diff:
				leap = 1
	if lunar_month > 12:
		lunar_month -= 12
	if lunar_month >= 11 and diff < 4:
		lunar_year -= 1
	return [lunar_day, lunar_month, lunar_year, leap]

func _can_chi(y: int) -> String:
	var can := ["Giáp", "Ất", "Bính", "Đinh", "Mậu", "Kỷ", "Canh", "Tân", "Nhâm", "Quý"]
	var chi := ["Tý", "Sửu", "Dần", "Mão", "Thìn", "Tị", "Ngọ", "Mùi", "Thân", "Dậu", "Tuất", "Hợi"]
	return "%s %s" % [can[(y + 6) % 10], chi[(y + 8) % 12]]

func _days_in_month(y: int, m: int) -> int:
	if m == 2:
		return 29 if ((y % 4 == 0 and y % 100 != 0) or y % 400 == 0) else 28
	return 30 if m in [4, 6, 9, 11] else 31

func _update_calendar() -> void:
	_refresh_painting()
	_refresh_calendar_art()
	var d := Time.get_datetime_dict_from_system()
	var weekdays := ["Chủ nhật", "Thứ hai", "Thứ ba", "Thứ tư", "Thứ năm", "Thứ sáu", "Thứ bảy"]
	var yr := int(d.year)
	var mo := int(d.month)
	var today := int(d.day)
	cal_year.text = str(yr)
	cal_month.text = str(mo)
	cal_day.text = str(today)
	cal_week.text = weekdays[int(d.weekday)]
	# âm lịch của hôm nay
	var tl := _solar_to_lunar(today, mo, yr)
	cal_lunar_a.text = "Âm lịch %d/%d%s" % [tl[0], tl[1], " nhuận" if int(tl[3]) == 1 else ""]
	cal_lunar_b.text = "Năm " + _can_chi(int(tl[2]))
	# thứ của ngày mùng 1 → vị trí bắt đầu trong lưới (thứ hai = cột 0)
	var ts := Time.get_unix_time_from_datetime_dict({"year": yr, "month": mo, "day": 1, "hour": 12, "minute": 0, "second": 0})
	var first := Time.get_datetime_dict_from_unix_time(int(ts))
	var off := (int(first.weekday) + 6) % 7
	var dim := _days_in_month(yr, mo)
	cal_today.visible = false
	for i in 42:
		var lbl: Label3D = cal_cells[i]
		var ll: Label3D = cal_lunar[i]
		var dn := i - off + 1
		if dn < 1 or dn > dim:
			lbl.text = ""
			ll.text = ""
			continue
		lbl.text = str(dn)
		var lu := _solar_to_lunar(dn, mo, yr)
		var l_day := int(lu[0])
		ll.text = ("%d/%d" % [l_day, int(lu[1])]) if l_day == 1 else str(l_day)
		var col := i % 7
		lbl.modulate = cal_accent if col >= 5 else Color(0.25, 0.21, 0.23)
		ll.modulate = Color(0.82, 0.22, 0.22) if l_day == 1 else Color(0.50, 0.38, 0.40)
		if dn == today:
			lbl.modulate = Color(1, 1, 1)
			ll.modulate = Color(1, 1, 1)
			cal_today.visible = true
			cal_today.position = Vector3(lbl.position.x, lbl.position.y - 0.013, -2.981)
		lbl.outline_modulate = lbl.modulate
		ll.outline_modulate = ll.modulate

# ---------- Chạm vào lịch → xem chi tiết tờ lịch (phóng to, chọn ngày, chuyển tháng) ----------
var cal_ui: CanvasLayer
var cal_dim: ColorRect
var cal_page: Control
var cal_big_tex: ImageTexture
var cal_vy := 2026
var cal_vm := 1
var cal_sel := 1
var cal_press := Vector2.ZERO
var ui_bold: SystemFont
var ui_script: SystemFont

# tia từ camera cắt mặt phẳng tường có lịch?
func _calendar_hit(pos: Vector2) -> bool:
	var origin := cam.project_ray_origin(pos)
	var dir := cam.project_ray_normal(pos)
	if absf(dir.z) < 0.0001:
		return false
	var t := (CAL_Z - origin.z) / dir.z
	if t < 0.0:
		return false
	var p := origin + dir * t
	return absf(p.x - CAL_X) <= CAL_W * 0.5 + 0.03 and absf(p.y - CAL_Y) <= CAL_H * 0.5 + 0.03

func _open_calendar_detail() -> void:
	var now := Time.get_datetime_dict_from_system()
	cal_vy = int(now.year)
	cal_vm = int(now.month)
	cal_sel = int(now.day)
	if cal_ui == null:
		ui_bold = _sys_font(["Arial", "Helvetica", "Noto Sans", "sans-serif"], false, 700)
		ui_script = _sys_font(["Segoe Script", "Brush Script MT", "Lucida Handwriting", "Snell Roundhand", "Apple Chancery", "Comic Sans MS"], true, 700)
		cal_ui = CanvasLayer.new()
		cal_ui.layer = 10
		add_child(cal_ui)
		cal_dim = ColorRect.new()
		cal_dim.color = Color(0, 0, 0, 0.65)
		cal_dim.set_anchors_preset(Control.PRESET_FULL_RECT)
		cal_dim.mouse_filter = Control.MOUSE_FILTER_STOP
		cal_dim.gui_input.connect(_on_dim_input)
		cal_ui.add_child(cal_dim)
		cal_page = Control.new()
		cal_page.mouse_filter = Control.MOUSE_FILTER_STOP
		cal_ui.add_child(cal_page)
		get_viewport().size_changed.connect(_on_vp_resized)
	cal_ui.visible = true
	_render_detail()
	cal_page.scale = Vector2(0.75, 0.75)
	cal_page.modulate.a = 0.0
	cal_dim.color.a = 0.0
	var tw := create_tween().set_parallel(true)
	tw.tween_property(cal_page, "scale", Vector2.ONE, 0.25).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)
	tw.tween_property(cal_page, "modulate:a", 1.0, 0.2)
	tw.tween_property(cal_dim, "color:a", 0.65, 0.2)

func _close_calendar_detail() -> void:
	if cal_ui != null:
		cal_ui.visible = false

func _on_dim_input(ev: InputEvent) -> void:
	if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
		_close_calendar_detail()

func _on_vp_resized() -> void:
	if cal_ui != null and cal_ui.visible:
		_render_detail()

func _select_day(dn: int) -> void:
	cal_sel = dn
	_render_detail()

func _nav_month(delta: int) -> void:
	cal_vm += delta
	if cal_vm > 12:
		cal_vm = 1
		cal_vy += 1
	elif cal_vm < 1:
		cal_vm = 12
		cal_vy -= 1
	var now := Time.get_datetime_dict_from_system()
	if int(now.year) == cal_vy and int(now.month) == cal_vm:
		cal_sel = int(now.day)
	else:
		cal_sel = 1
	_render_detail()

func _goto_today() -> void:
	var now := Time.get_datetime_dict_from_system()
	cal_vy = int(now.year)
	cal_vm = int(now.month)
	cal_sel = int(now.day)
	_render_detail()

func _ulabel(parent: Control, text: String, u: float, v: float, w: float, h: float, size: int, c: Color, f: Font) -> Label:
	var l := Label.new()
	l.text = text
	l.size = Vector2(w, h)
	l.position = Vector2(u * parent.size.x - w * 0.5, v * parent.size.y - h * 0.5)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_override("font", f)
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", c)
	l.add_theme_color_override("font_outline_color", c)
	l.add_theme_constant_override("outline_size", maxi(1, int(size * 0.04)))
	parent.add_child(l)
	return l

func _upanel(parent: Control, cx: float, cy: float, w: float, h: float, fill: Color, border: float = 0.0, border_col: Color = Color.WHITE) -> Panel:
	var p := Panel.new()
	p.size = Vector2(w, h)
	p.position = Vector2(cx - w * 0.5, cy - h * 0.5)
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var sb := StyleBoxFlat.new()
	sb.bg_color = fill
	sb.set_corner_radius_all(int(minf(w, h) * 0.5))
	if border > 0.0:
		sb.set_border_width_all(maxi(1, int(border)))
		sb.border_color = border_col
	p.add_theme_stylebox_override("panel", sb)
	parent.add_child(p)
	return p

func _ubutton(parent: Control, cx: float, cy: float, w: float, h: float, text: String, size: int, c: Color) -> Button:
	var b := Button.new()
	b.size = Vector2(w, h)
	b.position = Vector2(cx - w * 0.5, cy - h * 0.5)
	b.text = text
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_override("font", ui_bold)
	b.add_theme_font_size_override("font_size", size)
	for k in ["font_color", "font_hover_color", "font_pressed_color"]:
		b.add_theme_color_override(k, c)
	var hov := StyleBoxFlat.new()
	hov.bg_color = Color(1, 1, 1, 0.35)
	hov.set_corner_radius_all(int(minf(w, h) * 0.35))
	var empty := StyleBoxEmpty.new()
	b.add_theme_stylebox_override("normal", empty)
	b.add_theme_stylebox_override("focus", empty)
	b.add_theme_stylebox_override("hover", hov)
	b.add_theme_stylebox_override("pressed", hov)
	parent.add_child(b)
	return b

func _render_detail() -> void:
	for ch in cal_page.get_children():
		ch.queue_free()
	var vp := get_viewport().get_visible_rect().size
	var ph := minf(vp.y * 0.86, vp.x * 0.94 / 0.65)
	var pw := ph * 0.65
	cal_page.size = Vector2(pw, ph)
	cal_page.position = Vector2((vp.x - pw) * 0.5, (vp.y - ph) * 0.5 + vp.y * 0.03)
	cal_page.pivot_offset = Vector2(pw, ph) * 0.5
	var rose: Color = cal_accent
	var grey := Color(0.40, 0.40, 0.43)
	var dark := Color(0.25, 0.21, 0.23)
	var red := Color(0.82, 0.22, 0.22)
	var copper := Color(0.80, 0.52, 0.42)
	# tờ giấy + bóng đổ
	var back := Panel.new()
	back.size = Vector2(pw, ph)
	back.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var bsb := StyleBoxFlat.new()
	bsb.bg_color = Color(0.99, 0.97, 0.95)
	bsb.shadow_size = int(ph * 0.04)
	bsb.shadow_color = Color(0, 0, 0, 0.45)
	bsb.shadow_offset = Vector2(0, ph * 0.012)
	back.add_theme_stylebox_override("panel", bsb)
	cal_page.add_child(back)
	var bgtex := TextureRect.new()
	bgtex.texture = cal_big_tex
	bgtex.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bgtex.stretch_mode = TextureRect.STRETCH_SCALE
	bgtex.size = Vector2(pw, ph)
	bgtex.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cal_page.add_child(bgtex)
	# dây treo + lò xo đồng
	var wire := Line2D.new()
	wire.points = PackedVector2Array([Vector2(pw * 0.03, 0), Vector2(pw * 0.5, -ph * 0.07), Vector2(pw * 0.97, 0)])
	wire.width = maxf(2.0, ph * 0.004)
	wire.default_color = copper
	cal_page.add_child(wire)
	_upanel(cal_page, pw * 0.5, -ph * 0.07, ph * 0.026, ph * 0.026, copper)
	var bar := ColorRect.new()
	bar.color = copper
	bar.size = Vector2(pw * 0.94, maxf(3.0, ph * 0.006))
	bar.position = Vector2(pw * 0.03, -bar.size.y * 0.5)
	bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	cal_page.add_child(bar)
	for i in 17:
		_upanel(cal_page, pw * (0.04 + i * 0.0575), ph * 0.004, ph * 0.014, ph * 0.05, copper, 0.0)
	# tiêu đề, năm + nút chuyển tháng
	var wide := pw * 0.9
	_ulabel(cal_page, "Calendar", 0.5, 0.125, wide, ph * 0.12, int(ph * 0.085), rose, ui_script)
	_ulabel(cal_page, str(cal_vy), 0.5, 0.235, wide * 0.5, ph * 0.1, int(ph * 0.078), grey, ui_bold)
	var prev := _ubutton(cal_page, pw * 0.14, ph * 0.235, ph * 0.09, ph * 0.09, "‹", int(ph * 0.08), rose)
	prev.pressed.connect(_nav_month.bind(-1))
	var nxt := _ubutton(cal_page, pw * 0.86, ph * 0.235, ph * 0.09, ph * 0.09, "›", int(ph * 0.08), rose)
	nxt.pressed.connect(_nav_month.bind(1))
	# dữ liệu ngày đang chọn
	var dim_m := _days_in_month(cal_vy, cal_vm)
	var sel := clampi(cal_sel, 1, dim_m)
	var jd_sel := _jd_from_date(sel, cal_vm, cal_vy)
	var wd_names := ["Thứ hai", "Thứ ba", "Thứ tư", "Thứ năm", "Thứ sáu", "Thứ bảy", "Chủ nhật"]
	var tl := _solar_to_lunar(sel, cal_vm, cal_vy)
	var can := ["Giáp", "Ất", "Bính", "Đinh", "Mậu", "Kỷ", "Canh", "Tân", "Nhâm", "Quý"]
	var chi := ["Tý", "Sửu", "Dần", "Mão", "Thìn", "Tị", "Ngọ", "Mùi", "Thân", "Dậu", "Tuất", "Hợi"]
	var ly := int(tl[2])
	var lm := int(tl[1])
	var day_cc := "%s %s" % [can[(jd_sel + 9) % 10], chi[(jd_sel + 1) % 12]]
	var month_cc := "%s %s" % [can[(ly * 12 + lm + 3) % 10], chi[(lm + 1) % 12]]
	var lcw := pw * 0.42
	_ulabel(cal_page, str(sel), 0.21, 0.5, pw * 0.2, ph * 0.12, int(ph * 0.085), Color.WHITE, ui_bold)
	_ulabel(cal_page, "Tháng", 0.21, 0.625, lcw, ph * 0.05, int(ph * 0.036), rose, ui_bold)
	_ulabel(cal_page, str(cal_vm), 0.21, 0.715, lcw, ph * 0.12, int(ph * 0.09), grey, ui_bold)
	_ulabel(cal_page, wd_names[jd_sel % 7], 0.21, 0.805, lcw, ph * 0.05, int(ph * 0.036), rose, ui_bold)
	_ulabel(cal_page, "Âm lịch %d/%d%s" % [tl[0], lm, " nhuận" if int(tl[3]) == 1 else ""], 0.21, 0.862, lcw, ph * 0.04, int(ph * 0.028), red, ui_bold)
	_ulabel(cal_page, "Ngày " + day_cc, 0.21, 0.898, lcw, ph * 0.04, int(ph * 0.026), rose, ui_bold)
	_ulabel(cal_page, "Tháng " + month_cc, 0.21, 0.932, lcw, ph * 0.04, int(ph * 0.026), rose, ui_bold)
	_ulabel(cal_page, "Năm " + _can_chi(ly), 0.21, 0.966, lcw, ph * 0.04, int(ph * 0.026), rose, ui_bold)
	# tiêu đề thứ
	var heads := ["T2", "T3", "T4", "T5", "T6", "T7", "CN"]
	var cw := pw * 0.0775
	for c in 7:
		var hc := rose if c >= 5 else Color(0.42, 0.30, 0.32)
		_ulabel(cal_page, heads[c], 0.47 + c * 0.0775, 0.545, cw, ph * 0.04, int(ph * 0.026), hc, ui_bold)
	# lưới ngày
	var now := Time.get_datetime_dict_from_system()
	var is_cur := int(now.year) == cal_vy and int(now.month) == cal_vm
	var off := _jd_from_date(1, cal_vm, cal_vy) % 7
	for r in 6:
		for c in 7:
			var dn := r * 7 + c - off + 1
			if dn < 1 or dn > dim_m:
				continue
			var u := 0.47 + c * 0.0775
			var v := 0.612 + r * 0.058
			var cx := u * pw
			var cy := v * ph
			var is_sel := dn == sel
			var is_today := is_cur and dn == int(now.day)
			if is_sel:
				_upanel(cal_page, cx, cy + ph * 0.009, cw * 0.94, ph * 0.062, cal_circle)
			elif is_today:
				_upanel(cal_page, cx, cy + ph * 0.009, cw * 0.94, ph * 0.062, Color(0, 0, 0, 0), maxf(2.0, ph * 0.003), cal_circle)
			var lu := _solar_to_lunar(dn, cal_vm, cal_vy)
			var l_day := int(lu[0])
			var sc := dark
			if c >= 5:
				sc = rose
			var lc := Color(0.50, 0.38, 0.40)
			if l_day == 1:
				lc = red
			if is_sel:
				sc = Color.WHITE
				lc = Color.WHITE
			_ulabel(cal_page, str(dn), u, v - 0.004, cw, ph * 0.04, int(ph * 0.03), sc, ui_bold)
			var ltxt := ("%d/%d" % [l_day, int(lu[1])]) if l_day == 1 else str(l_day)
			_ulabel(cal_page, ltxt, u, v + 0.022, cw, ph * 0.03, int(ph * 0.0175), lc, ui_bold)
			var hit := _ubutton(cal_page, cx, cy + ph * 0.009, cw, ph * 0.062, "", 12, dark)
			hit.pressed.connect(_select_day.bind(dn))
	# về hôm nay + đóng
	var tb := _ubutton(cal_page, pw * 0.72, ph * 0.972, pw * 0.2, ph * 0.04, "Hôm nay", int(ph * 0.024), rose)
	tb.pressed.connect(_goto_today)
	var cb := _ubutton(cal_page, pw * 0.93, ph * 0.05, ph * 0.055, ph * 0.055, "✕", int(ph * 0.035), rose)
	cb.pressed.connect(_close_calendar_detail)

# ----- Vẽ nền lịch: màu nước hồng, khối hồng viền cung, hoa vàng kim, vòng tròn ngày -----
func _stamp(img: Image, cx: float, cy: float, r: float, col: Color, a: float) -> void:
	var x0 := int(floor(cx - r - 1.0))
	var x1 := int(ceil(cx + r + 1.0))
	var y0 := int(floor(cy - r - 1.0))
	var y1 := int(ceil(cy + r + 1.0))
	for yy in range(y0, y1 + 1):
		if yy < 0 or yy >= img.get_height():
			continue
		for xx in range(x0, x1 + 1):
			if xx < 0 or xx >= img.get_width():
				continue
			var dd := Vector2(xx + 0.5, yy + 0.5).distance_to(Vector2(cx, cy))
			var k := clampf(r + 0.5 - dd, 0.0, 1.0) * a
			if k > 0.0:
				img.set_pixel(xx, yy, img.get_pixel(xx, yy).lerp(col, k))

func _g_ellipse(img: Image, cen: Vector2, dir: Vector2, a: float, b: float, col: Color, al: float = 0.85) -> void:
	var perp := Vector2(-dir.y, dir.x)
	var steps := int(maxf(24.0, (a + b) * 5.0))
	for s in steps:
		var t := TAU * s / steps
		var p := cen + dir * cos(t) * a + perp * sin(t) * b
		_stamp(img, p.x, p.y, 0.6, col, al)

func _g_circle(img: Image, cen: Vector2, r: float, col: Color, al: float = 0.85) -> void:
	var steps := int(maxf(24.0, r * 7.0))
	for s in steps:
		var t := TAU * s / steps
		_stamp(img, cen.x + cos(t) * r, cen.y + sin(t) * r, 0.6, col, al)

func _g_flower(img: Image, cen: Vector2, r: float, petals: int, rot: float, col: Color, al: float = 0.85) -> void:
	for layer in 2:
		var rr := r * (1.0 if layer == 0 else 0.6)
		var n := petals if layer == 0 else maxi(petals - 1, 4)
		for i in n:
			var ang := rot + (0.0 if layer == 0 else 0.5) + TAU * i / n
			var dir := Vector2(cos(ang), sin(ang))
			_g_ellipse(img, cen + dir * rr * 0.55, dir, rr * 0.5, rr * 0.28, col, al)
	_g_circle(img, cen, r * 0.14, col, al)
	_stamp(img, cen.x, cen.y, 1.1, col, al)

func _g_sprig(img: Image, p0: Vector2, p1: Vector2, p2: Vector2, leaves: int, leaf_len: float, col: Color, al: float = 0.8) -> void:
	for s in 90:
		var t := s / 89.0
		var p := p0.lerp(p1, t).lerp(p1.lerp(p2, t), t)
		_stamp(img, p.x, p.y, 0.55, col, al)
	for i in leaves:
		var t := (i + 1.0) / (leaves + 1.0)
		var p := p0.lerp(p1, t).lerp(p1.lerp(p2, t), t)
		var p_n := p0.lerp(p1, t + 0.02).lerp(p1.lerp(p2, t + 0.02), t + 0.02)
		var tang := (p_n - p).normalized()
		var side := 1.0 if i % 2 == 0 else -1.0
		var ld := tang.rotated(side * 0.9)
		_g_ellipse(img, p + ld * leaf_len * 0.5, ld, leaf_len * 0.5, leaf_len * 0.2, col, al)
		_stamp(img, p.x + ld.x * leaf_len * 1.05, p.y + ld.y * leaf_len * 1.05, 0.9, col, al)

func _g_butterfly(img: Image, cen: Vector2, s: float, col: Color) -> void:
	_g_ellipse(img, cen + Vector2(-s * 0.55, -s * 0.35), Vector2(-0.7, -0.7), s * 0.7, s * 0.4, col, 0.8)
	_g_ellipse(img, cen + Vector2(s * 0.55, -s * 0.35), Vector2(0.7, -0.7), s * 0.7, s * 0.4, col, 0.8)
	_g_ellipse(img, cen + Vector2(-s * 0.4, s * 0.4), Vector2(-0.6, 0.8), s * 0.5, s * 0.3, col, 0.8)
	_g_ellipse(img, cen + Vector2(s * 0.4, s * 0.4), Vector2(0.6, 0.8), s * 0.5, s * 0.3, col, 0.8)
	_g_ellipse(img, cen, Vector2(0, 1), s * 0.55, s * 0.08, col, 0.9)

# ---------- Tranh trên tờ lịch: mỗi ngày một bộ màu + họa tiết hoa khác nhau (7 chủ đề, mỗi lần lặp lại bố cục lại khác) ----------
const CAL_THEMES := 7
var cal_theme: Dictionary = {}
var cal_art_day := -1
var cal_accent := Color(0.74, 0.46, 0.43)
var cal_circle := Color(0.80, 0.55, 0.54)
var cal_accent_labels: Array = []
var cal_disc_mat: StandardMaterial3D
var cal_pq_mat: StandardMaterial3D

func _cal_theme(i: int) -> Dictionary:
	var t := {
		"name": "Hồng vàng kim", "style": 0,
		"accent": Color(0.74, 0.46, 0.43), "circle": Color(0.80, 0.55, 0.54),
		"wash": Color(0.96, 0.82, 0.83), "lilac": Color(0.90, 0.86, 0.93),
		"block_a": Color(0.95, 0.83, 0.82), "block_b": Color(0.90, 0.73, 0.72), "gold": Color(0.86, 0.70, 0.36)}
	match i:
		1:
			t.merge({"name": "Oải hương tím", "style": 1,
				"accent": Color(0.50, 0.38, 0.68), "circle": Color(0.62, 0.50, 0.80),
				"wash": Color(0.88, 0.82, 0.95), "lilac": Color(0.80, 0.86, 0.98),
				"block_a": Color(0.90, 0.85, 0.96), "block_b": Color(0.78, 0.70, 0.90), "gold": Color(0.62, 0.48, 0.80)}, true)
		2:
			t.merge({"name": "Lá bạc hà", "style": 2,
				"accent": Color(0.30, 0.52, 0.45), "circle": Color(0.42, 0.67, 0.58),
				"wash": Color(0.82, 0.94, 0.88), "lilac": Color(0.85, 0.93, 0.97),
				"block_a": Color(0.84, 0.94, 0.89), "block_b": Color(0.68, 0.84, 0.76), "gold": Color(0.30, 0.58, 0.46)}, true)
		3:
			t.merge({"name": "Cúc vàng nắng", "style": 3,
				"accent": Color(0.72, 0.50, 0.10), "circle": Color(0.92, 0.68, 0.22),
				"wash": Color(1.0, 0.93, 0.70), "lilac": Color(1.0, 0.88, 0.82),
				"block_a": Color(1.0, 0.93, 0.70), "block_b": Color(0.97, 0.80, 0.45), "gold": Color(0.85, 0.58, 0.12)}, true)
		4:
			t.merge({"name": "Tinh thể xanh trời", "style": 4,
				"accent": Color(0.28, 0.45, 0.68), "circle": Color(0.40, 0.60, 0.84),
				"wash": Color(0.82, 0.90, 0.98), "lilac": Color(0.90, 0.88, 0.97),
				"block_a": Color(0.84, 0.91, 0.98), "block_b": Color(0.68, 0.80, 0.93), "gold": Color(0.38, 0.58, 0.85)}, true)
		5:
			t.merge({"name": "Đào hồng", "style": 5,
				"accent": Color(0.75, 0.36, 0.25), "circle": Color(0.92, 0.52, 0.40),
				"wash": Color(1.0, 0.87, 0.78), "lilac": Color(1.0, 0.92, 0.87),
				"block_a": Color(1.0, 0.88, 0.80), "block_b": Color(0.96, 0.70, 0.58), "gold": Color(0.90, 0.52, 0.38)}, true)
		6:
			t.merge({"name": "Hồng cổ điển", "style": 6,
				"accent": Color(0.50, 0.33, 0.24), "circle": Color(0.62, 0.42, 0.32),
				"wash": Color(0.95, 0.88, 0.78), "lilac": Color(0.93, 0.85, 0.80),
				"block_a": Color(0.94, 0.87, 0.77), "block_b": Color(0.80, 0.65, 0.50), "gold": Color(0.70, 0.48, 0.26)}, true)
	return t

@warning_ignore("integer_division")
func _pick_cal_theme() -> int:
	var d := Time.get_datetime_dict_from_system()
	var jd := _jd_from_date(int(d.day), int(d.month), int(d.year))
	cal_art_day = jd
	cal_theme = _cal_theme((jd + jd / 7) % CAL_THEMES)   # ngày liên tiếp không trùng chủ đề
	cal_accent = cal_theme["accent"]
	cal_circle = cal_theme["circle"]
	return jd

# qua nửa đêm: đổi tranh trên tờ lịch (3D + bản phóng to), đổi luôn màu chữ nhấn
func _refresh_calendar_art() -> void:
	if cal_pq_mat == null:
		return
	var d := Time.get_datetime_dict_from_system()
	if _jd_from_date(int(d.day), int(d.month), int(d.year)) == cal_art_day:
		return
	_pick_cal_theme()
	cal_pq_mat.albedo_texture = _calendar_tex(cal_theme, cal_art_day)
	for l in cal_accent_labels:
		var lb: Label3D = l
		lb.modulate = cal_accent
		lb.outline_modulate = cal_accent
	cal_disc_mat.albedo_color = cal_circle
	if cal_ui != null and cal_ui.visible:
		_render_detail()

func _g_line(img: Image, a: Vector2, b: Vector2, col: Color, al: float) -> void:
	var steps := int(a.distance_to(b) * 1.5) + 2
	for s in steps + 1:
		var p := a.lerp(b, float(s) / steps)
		_stamp(img, p.x, p.y, 0.55, col, al)

func _g_daisy(img: Image, cen: Vector2, r: float, n: int, col: Color, al: float) -> void:
	for i in n:
		var ang := TAU * i / n
		var dir := Vector2(cos(ang), sin(ang))
		_g_ellipse(img, cen + dir * r * 0.62, dir, r * 0.38, r * 0.1, col, al)
	_g_circle(img, cen, r * 0.22, col, al)
	_g_circle(img, cen, r * 0.11, col, al)

func _g_blossom(img: Image, cen: Vector2, r: float, rot: float, col: Color, al: float) -> void:
	for i in 5:
		var ang := rot + TAU * i / 5.0
		var dir := Vector2(cos(ang), sin(ang))
		_g_circle(img, cen + dir * r * 0.5, r * 0.5, col, al)
		_stamp(img, cen.x + dir.x * r * 0.22, cen.y + dir.y * r * 0.22, 0.9, col, al)
	_stamp(img, cen.x, cen.y, 1.4, col, al)

func _g_star(img: Image, cen: Vector2, r: float, col: Color, al: float) -> void:
	for i in 6:
		var ang := TAU * i / 6.0
		var dir := Vector2(cos(ang), sin(ang))
		_g_line(img, cen, cen + dir * r, col, al)
		var mid := cen + dir * r * 0.62
		_g_line(img, mid, mid + dir.rotated(0.7) * r * 0.32, col, al)
		_g_line(img, mid, mid + dir.rotated(-0.7) * r * 0.32, col, al)
		_stamp(img, cen.x + dir.x * r, cen.y + dir.y * r, 1.0, col, al)
	_g_circle(img, cen, r * 0.18, col, al)

func _g_rose(img: Image, cen: Vector2, r: float, rot: float, col: Color, al: float) -> void:
	var sh := Vector2(cos(rot), sin(rot)) * r * 0.05
	for k in 4:
		_g_circle(img, cen + sh * k, r * (0.22 + 0.2 * k), col, al)
	for i in 6:
		var ang := rot + TAU * i / 6.0
		var dir := Vector2(cos(ang), sin(ang))
		_g_ellipse(img, cen + dir * r * 0.85, dir.rotated(0.5), r * 0.3, r * 0.2, col, al * 0.8)

func _g_spike(img: Image, p0: Vector2, p1: Vector2, col: Color, al: float) -> void:
	var dir := (p1 - p0).normalized()
	var perp := Vector2(-dir.y, dir.x)
	_g_line(img, p0, p1, col, al)
	var n := 9
	for i in n:
		var t := 0.35 + 0.65 * float(i) / float(n - 1)
		var p := p0.lerp(p1, t)
		var sz := 4.2 * (1.0 - 0.45 * float(i) / n)
		for side in [-1.0, 1.0]:
			var ld: Vector2 = (dir * 0.8 + perp * float(side) * 0.7).normalized()
			_g_ellipse(img, p + ld * sz * 0.9, ld, sz, sz * 0.38, col, al)
	_g_ellipse(img, p1 + dir * 3.0, dir, 4.0, 1.6, col, al)

# cành lá uốn quanh các góc (dùng chung cho vài chủ đề)
func _cal_vines(img: Image, col: Color, al: float) -> void:
	_g_sprig(img, Vector2(215, 52), Vector2(246, 85), Vector2(250, 135), 4, 11.0, col, al)
	_g_sprig(img, Vector2(218, 30), Vector2(205, 8), Vector2(185, 4), 3, 9.0, col, al * 0.9)
	_g_sprig(img, Vector2(40, 140), Vector2(52, 160), Vector2(48, 176), 3, 9.0, col, al)
	_g_sprig(img, Vector2(12, 106), Vector2(8, 70), Vector2(24, 40), 4, 10.0, col, al * 0.9)
	_g_sprig(img, Vector2(48, 362), Vector2(80, 380), Vector2(108, 390), 4, 10.0, col, al)
	_g_sprig(img, Vector2(14, 352), Vector2(6, 325), Vector2(18, 300), 3, 9.0, col, al)
	_g_sprig(img, Vector2(222, 372), Vector2(196, 384), Vector2(168, 392), 3, 9.0, col, al)

func _cal_decor(img: Image, style: int, col: Color, rng: RandomNumberGenerator) -> void:
	var pa := Vector2(232, 40) + Vector2(rng.randf_range(-6, 6), rng.randf_range(-4, 6))
	var pb := Vector2(26, 122) + Vector2(rng.randf_range(-4, 6), rng.randf_range(-8, 8))
	var pc := Vector2(238, 160) + Vector2(rng.randf_range(-4, 4), rng.randf_range(-6, 6))
	var pd := Vector2(30, 372) + Vector2(rng.randf_range(-4, 6), rng.randf_range(-6, 4))
	var pe := Vector2(236, 380) + Vector2(rng.randf_range(-6, 4), rng.randf_range(-6, 4))
	var rot := rng.randf() * TAU
	match style:
		0:   # hoa hồng vàng kim + bướm
			_g_flower(img, pa, 20.0, 6, rot, col, 0.6)
			_g_flower(img, pb, 22.0, 7, rot + 1.0, col, 0.65)
			_g_flower(img, pc, 13.0, 5, rot + 2.0, col, 0.6)
			_g_flower(img, pd, 22.0, 7, rot + 3.0, col, 0.7)
			_g_flower(img, pe, 15.0, 6, rot + 4.0, col, 0.65)
			_cal_vines(img, col, 0.55)
			_g_butterfly(img, Vector2(62, 172), 9.0, col)
			_g_butterfly(img, Vector2(160, 150), 6.0, col)
		1:   # oải hương: các bông hoa dạng bông dài
			for s in [[Vector2(248, 4), Vector2(228, 96)], [Vector2(224, 2), Vector2(212, 72)],
					[Vector2(8, 58), Vector2(30, 150)], [Vector2(26, 40), Vector2(42, 108)],
					[Vector2(6, 398), Vector2(24, 296)], [Vector2(30, 398), Vector2(46, 322)],
					[Vector2(254, 398), Vector2(238, 346)], [Vector2(232, 398), Vector2(222, 358)]]:
				var j := Vector2(rng.randf_range(-5, 5), rng.randf_range(-4, 4))
				_g_spike(img, s[0], s[1] + j, col, 0.6)
			_g_blossom(img, pc, 9.0, rot, col, 0.6)
			_g_blossom(img, Vector2(70, 380), 9.0, rot + 1.0, col, 0.55)
			_g_butterfly(img, Vector2(64, 170), 9.0, col)
		2:   # cành lá, dương xỉ
			for s in [[Vector2(258, 18), Vector2(236, 54), Vector2(222, 118), 8, 10.0],
					[Vector2(4, 90), Vector2(26, 112), Vector2(40, 172), 7, 10.0],
					[Vector2(4, 392), Vector2(30, 360), Vector2(20, 300), 8, 11.0],
					[Vector2(256, 396), Vector2(232, 372), Vector2(250, 335), 6, 10.0],
					[Vector2(2, 12), Vector2(30, 4), Vector2(52, 30), 5, 9.0],
					[Vector2(60, 398), Vector2(100, 384), Vector2(136, 396), 5, 9.0]]:
				var off := Vector2(rng.randf_range(-4, 4), rng.randf_range(-4, 4))
				_g_sprig(img, s[0], s[1] + off, s[2], int(s[3]), float(s[4]), col, 0.6)
			_g_butterfly(img, Vector2(160, 152), 7.0, col)
		3:   # cúc họa mi
			_g_daisy(img, pa, 19.0, 13, col, 0.65)
			_g_daisy(img, pb, 21.0, 14, col, 0.65)
			_g_daisy(img, pc, 12.0, 10, col, 0.6)
			_g_daisy(img, pd, 21.0, 14, col, 0.7)
			_g_daisy(img, pe, 15.0, 12, col, 0.65)
			_cal_vines(img, col, 0.5)
			_g_butterfly(img, Vector2(62, 172), 8.0, col)
		4:   # tinh thể tuyết + bướm
			_g_star(img, pa, 16.0, col, 0.65)
			_g_star(img, pb, 14.0, col, 0.65)
			_g_star(img, pc, 9.0, col, 0.6)
			_g_star(img, pd, 16.0, col, 0.7)
			_g_star(img, pe, 12.0, col, 0.65)
			for i in 7:
				_g_star(img, Vector2(rng.randf_range(10, 250), rng.randf_range(10, 390)), rng.randf_range(3.5, 6.0), col, 0.5)
			_g_butterfly(img, Vector2(62, 170), 12.0, col)
			_g_butterfly(img, Vector2(160, 150), 8.0, col)
		5:   # hoa đào
			_g_blossom(img, pa, 16.0, rot, col, 0.65)
			_g_blossom(img, pb, 15.0, rot + 1.0, col, 0.65)
			_g_blossom(img, pc, 10.0, rot + 2.0, col, 0.6)
			_g_blossom(img, pd, 17.0, rot + 3.0, col, 0.7)
			_g_blossom(img, pe, 13.0, rot + 4.0, col, 0.65)
			_cal_vines(img, col, 0.5)
			for p in [Vector2(246, 85), Vector2(250, 135), Vector2(8, 70), Vector2(48, 176), Vector2(80, 380), Vector2(108, 390), Vector2(196, 384)]:
				_g_blossom(img, p, 7.0, rng.randf() * TAU, col, 0.55)
		6:   # hoa hồng cổ điển
			_g_rose(img, pa, 18.0, rot, col, 0.65)
			_g_rose(img, pb, 20.0, rot + 1.0, col, 0.65)
			_g_rose(img, pc, 10.0, rot + 2.0, col, 0.6)
			_g_rose(img, pd, 22.0, rot + 3.0, col, 0.7)
			_g_rose(img, pe, 15.0, rot + 4.0, col, 0.65)
			_cal_vines(img, col, 0.55)

func _calendar_tex(th: Dictionary, seed_v: int) -> ImageTexture:
	var w := 260
	var h := 400
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var nz := FastNoiseLite.new()
	nz.noise_type = FastNoiseLite.TYPE_SIMPLEX_SMOOTH
	nz.frequency = 0.012
	nz.seed = 7 + seed_v % 1000
	var cream := Color(0.99, 0.975, 0.955)
	var wash: Color = th["wash"]
	var lilac: Color = th["lilac"]
	var block_a: Color = th["block_a"]
	var block_b: Color = th["block_b"]
	var circle: Color = th["circle"]
	var gold: Color = th["gold"]
	for y in h:
		for x in w:
			var n := nz.get_noise_2d(x, y)
			var n2 := nz.get_noise_2d(x + 300.0, y * 1.3 + 90.0)
			var c := cream
			c = c.lerp(wash, clampf(n * 1.4 + 0.15, 0.0, 1.0) * 0.45)
			c = c.lerp(lilac, clampf(n2 * 1.3 - 0.05, 0.0, 1.0) * 0.4)
			var edge := h * 0.5 - 7.0 * absf(sin(float(x) * PI / 26.0))
			if y > edge:
				var t := (y - edge) / (h - edge)
				var bc := block_a.lerp(block_b, t * 0.55)
				bc = bc.lerp(cream, clampf(n * 0.8, 0.0, 1.0) * 0.22)
				c = bc
				if y < edge + 3.0:
					c = c.lerp(block_b.darkened(0.12), 0.35)
			img.set_pixel(x, y, c)
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_v
	_cal_decor(img, int(th["style"]), gold, rng)
	# vòng tròn ngày: nền đậm theo chủ đề, viền 2 lớp
	var cc := Vector2(0.21 * w, 0.5 * h)
	_stamp(img, cc.x + 1.5, cc.y + 2.0, 31.0, circle.darkened(0.45), 0.22)
	_stamp(img, cc.x, cc.y, 30.0, circle, 1.0)
	_stamp(img, cc.x, cc.y - 4.0, 24.0, circle.lightened(0.25), 0.35)
	_g_circle(img, cc, 35.5, gold, 0.9)
	_g_circle(img, cc, 26.5, Color(1, 0.95, 0.9), 0.75)
	# đường kẻ dưới hàng tiêu đề thứ
	for x in range(int(0.43 * w), int(0.96 * w)):
		_stamp(img, x, 0.572 * h, 0.5, gold, 0.8)
	# bụi kim tuyến
	for i in 34:
		_stamp(img, rng.randf_range(6, w - 6), rng.randf_range(6, h - 6), rng.randf_range(0.5, 1.1), gold, 0.7)
	var big: Image = img.duplicate()
	big.resize(w * 3, h * 3, Image.INTERPOLATE_CUBIC)
	cal_big_tex = ImageTexture.create_from_image(big)
	img.generate_mipmaps()
	return ImageTexture.create_from_image(img)

# ---------- Mưa ----------
func _build_rain() -> void:
	rain = GPUParticles3D.new()
	rain.position = Vector3(0, 9, 2)
	rain.amount = 900
	rain.lifetime = 1.2
	rain.visibility_aabb = AABB(Vector3(-10, -10, -10), Vector3(20, 20, 20))
	var p := ParticleProcessMaterial.new()
	p.emission_shape = ParticleProcessMaterial.EMISSION_SHAPE_BOX
	p.emission_box_extents = Vector3(9, 0.1, 9)
	p.direction = Vector3(0, -1, 0)
	p.spread = 0.0
	p.initial_velocity_min = 9.0
	p.initial_velocity_max = 11.0
	p.gravity = Vector3(0, -6, 0)
	rain.process_material = p
	var m := BoxMesh.new()
	m.size = Vector3(0.015, 0.5, 0.015)
	m.material = _mat(Color(0.7, 0.8, 1.0, 0.8))
	rain.draw_pass_1 = m
	rain.emitting = false
	add_child(rain)

# ---------- Thời tiết ----------
func _fetch(http: HTTPRequest) -> void:
	if exporting:
		return
	var url := "https://api.open-meteo.com/v1/forecast?latitude=%s&longitude=%s&current=weather_code,cloud_cover,is_day" % [LAT, LON]
	http.request(url)

func _on_weather(_r: int, response_code: int, _h: PackedStringArray, body: PackedByteArray) -> void:
	if response_code != 200:
		return
	var data = JSON.parse_string(body.get_string_from_utf8())
	if data == null or not data.has("current"):
		return
	code = int(data.current.weather_code)
	cloud_cover = float(data.current.cloud_cover)
	is_day = int(data.current.is_day) == 1
	_update_calendar()
	_apply_weather()

func _is_rain() -> bool:
	return (code >= 51 and code <= 67) or (code >= 80 and code <= 82) or code >= 95

func _apply_weather() -> void:
	var now: Dictionary = Time.get_time_dict_from_system()
	var hour: float = float(now["hour"]) + float(now["minute"]) / 60.0
	if hour_override >= 0.0:
		hour = hour_override
	var gray := clampf(cloud_cover / 100.0, 0.0, 1.0)
	if _is_rain():
		gray = maxf(gray, 0.85)
	# Mặt trời theo giờ
	var elev := sin((hour - 6.0) / 12.0 * PI) * 70.0
	sun.rotation_degrees = Vector3(-maxf(elev, 5.0), -90.0 + (hour - 6.0) / 12.0 * 180.0, 0)
	var day_factor := 1.0 if is_day else 0.0
	sun.light_energy = lerpf(0.05, 1.2, day_factor) * (1.0 - gray * 0.6)
	room_light.light_energy = 0.3 + (1.0 - day_factor) * 1.2 + gray * 0.4
	# Bầu trời
	var top_clear := Color(0.25, 0.5, 0.9) if is_day else Color(0.02, 0.03, 0.1)
	var hor_clear := Color(0.65, 0.8, 0.95) if is_day else Color(0.08, 0.1, 0.2)
	var top_gray := Color(0.5, 0.52, 0.56) if is_day else Color(0.04, 0.04, 0.07)
	sky_mat.sky_top_color = top_clear.lerp(top_gray, gray)
	sky_mat.sky_horizon_color = hor_clear.lerp(top_gray, gray)
	sky_mat.ground_horizon_color = sky_mat.sky_horizon_color
	sky_mat.ground_bottom_color = sky_mat.sky_horizon_color.darkened(0.15)
	env.ambient_light_color = Color(0.82, 0.86, 0.95).lerp(Color(0.6, 0.62, 0.68), gray) if is_day else Color(0.18, 0.2, 0.32)
	env.ambient_light_energy = 0.9 if is_day else 0.5
	env.fog_enabled = code == 45 or code == 48
	env.fog_density = 0.04
	rain.emitting = _is_rain()
	rain.amount = 1500 if code >= 95 else 900
	_build_clouds(gray)

func _build_clouds(gray: float) -> void:
	for c in clouds.get_children():
		c.queue_free()
	var n := int(gray * 8.0)
	var rng := RandomNumberGenerator.new()
	rng.seed = 3
	var col := Color(1, 1, 1).lerp(Color(0.55, 0.56, 0.6), gray)
	if not is_day:
		col = col.darkened(0.6)
	for i in n:
		var cloud := Node3D.new()
		cloud.position = Vector3(rng.randf_range(-12, 12), rng.randf_range(8, 11), rng.randf_range(-8, 6))
		for j in 4:
			var mi := MeshInstance3D.new()
			var sm := SphereMesh.new()
			sm.radius = 1.0
			sm.height = 2.0
			mi.mesh = sm
			mi.material_override = _mat(col)
			mi.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
			mi.position = Vector3(j * 1.2 - 1.8, rng.randf() * 0.4, 0)
			mi.scale = Vector3(1.4, 0.7, 1.0)
			cloud.add_child(mi)
		clouds.add_child(cloud)

func _process(delta: float) -> void:
	for c in clouds.get_children():
		c.position.x += delta * 0.4
		if c.position.x > 14.0:
			c.position.x = -14.0
	# lửa trong bếp củi nhấp nháy
	if not exporting:
		fire_t += delta
		anim_clock += delta
		RenderingServer.global_shader_parameter_set("anim_t", anim_clock)
	fire_light.light_energy = 1.4 + sin(fire_t * 9.0) * 0.25 + sin(fire_t * 23.0) * 0.15
	fire_mat.emission_energy_multiplier = 1.6 + sin(fire_t * 11.0) * 0.3

# ---------- Camera: kéo để xoay, cuộn/chụm để zoom ----------
func _unhandled_input(e: InputEvent) -> void:
	if e is InputEventMouseMotion and (e.button_mask & MOUSE_BUTTON_MASK_LEFT):
		yaw -= e.relative.x * 0.3
		pitch = clampf(pitch - e.relative.y * 0.3, -70.0, -8.0)
		yaw = clampf(yaw, 10.0, 80.0)
		_update_camera()
	elif e is InputEventMouseMotion:
		# con trỏ biến thành bàn tay khi rê lên tờ lịch
		var over := _calendar_hit(e.position) and (cal_ui == null or not cal_ui.visible)
		Input.set_default_cursor_shape(Input.CURSOR_POINTING_HAND if over else Input.CURSOR_ARROW)
	elif e is InputEventKey and e.pressed and e.keycode == KEY_ESCAPE and cal_ui != null and cal_ui.visible:
		_close_calendar_detail()
	elif e is InputEventMouseButton and e.button_index == MOUSE_BUTTON_LEFT:
		# nhấn nhẹ (không kéo) vào tờ lịch → mở chi tiết
		if e.pressed:
			cal_press = e.position
		elif e.position.distance_to(cal_press) < 8.0 and _calendar_hit(e.position):
			_open_calendar_detail()
	elif e is InputEventMagnifyGesture:
		dist = clampf(dist / e.factor, 9.0, 28.0)
		_update_camera()
	elif e is InputEventMouseButton and e.pressed:
		if e.button_index == MOUSE_BUTTON_WHEEL_UP:
			dist = clampf(dist - 0.7, 9.0, 28.0)
		elif e.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			dist = clampf(dist + 0.7, 9.0, 28.0)
		_update_camera()

func _update_camera() -> void:
	var target := Vector3(0, 1.2, 0.8)
	var basis_rot := Basis.from_euler(Vector3(deg_to_rad(pitch), deg_to_rad(yaw), 0))
	cam.position = target + basis_rot * Vector3(0, 0, dist)
	cam.look_at(target)

# ---------- Xuất frame cho widget (EXPORT_WIDGET = true) ----------
func _export_frames() -> void:
	get_window().size = EXP_SIZE
	get_viewport().transparent_bg = true
	env.background_mode = Environment.BG_CLEAR_COLOR   # bỏ nền trời để ảnh trong suốt
	yaw = EXP_YAW
	pitch = EXP_PITCH
	dist = EXP_DIST
	_update_camera()
	var dir := ProjectSettings.globalize_path("res://widget_frames")
	DirAccess.make_dir_recursive_absolute(dir)
	await get_tree().process_frame
	rain.preprocess = 1.5
	for v in EXP_VARIANTS:
		is_day = v["is_day"]
		code = v["code"]
		cloud_cover = v["cloud"]
		hour_override = v["hour"]
		_apply_weather()
		for i in EXP_FRAMES:
			fire_t = i * 1.1                                   # lửa nhấp nháy khác nhau mỗi frame
			RenderingServer.global_shader_parameter_set("anim_t", EXP_T0 + i * EXP_DT)
			if rain.emitting:
				rain.restart()
			await get_tree().process_frame
			await get_tree().process_frame
			await RenderingServer.frame_post_draw
			var img := get_viewport().get_texture().get_image()
			img.save_png("%s/%s_%02d.png" % [dir, v["name"], i])
		print("Đã xuất biến thể: ", v["name"])
	print("XONG. Frame nằm ở: ", dir)
	get_tree().quit()
