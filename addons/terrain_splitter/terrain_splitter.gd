@tool
extends EditorPlugin

var toolbar_button: Button
var split_dialog: ConfirmationDialog
var spin_x: SpinBox
var spin_z: SpinBox
var static_checkbox: CheckBox

var selected_mesh_instance: MeshInstance3D

func _enter_tree():
	# 1. Create the Toolbar Button
	toolbar_button = Button.new()
	toolbar_button.text = "Split Terrain"
	toolbar_button.hide()
	toolbar_button.pressed.connect(_on_toolbar_button_pressed)
	
	add_control_to_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, toolbar_button)
	
	# 2. Create the Split Dialog
	split_dialog = ConfirmationDialog.new()
	split_dialog.title = "Split into chunks"
	split_dialog.confirmed.connect(_on_split_confirmed)
	
	var vbox = VBoxContainer.new()
	
	var hbox_x = HBoxContainer.new()
	var label_x = Label.new()
	label_x.text = "Chunks X:"
	spin_x = SpinBox.new()
	spin_x.min_value = 1
	spin_x.max_value = 100
	spin_x.value = 2
	hbox_x.add_child(label_x)
	hbox_x.add_child(spin_x)
	
	var hbox_z = HBoxContainer.new()
	var label_z = Label.new()
	label_z.text = "Chunks Z:"
	spin_z = SpinBox.new()
	spin_z.min_value = 1
	spin_z.max_value = 100
	spin_z.value = 2
	hbox_z.add_child(label_z)
	hbox_z.add_child(spin_z)
	
	static_checkbox = CheckBox.new()
	static_checkbox.text = "Make static bodies"
	static_checkbox.button_pressed = true 
	
	vbox.add_child(hbox_x)
	vbox.add_child(hbox_z)
	vbox.add_child(static_checkbox)
	
	split_dialog.add_child(vbox)
	EditorInterface.get_base_control().add_child(split_dialog)

func _exit_tree():
	if toolbar_button:
		remove_control_from_container(EditorPlugin.CONTAINER_SPATIAL_EDITOR_MENU, toolbar_button)
		toolbar_button.queue_free()
	if split_dialog:
		split_dialog.queue_free()

func _handles(object):
	return object is MeshInstance3D

func _edit(object):
	selected_mesh_instance = object as MeshInstance3D

func _make_visible(visible):
	if toolbar_button:
		toolbar_button.visible = visible

func _on_toolbar_button_pressed():
	if selected_mesh_instance and selected_mesh_instance.mesh:
		split_dialog.popup_centered()
	else:
		push_warning("Selected MeshInstance3D does not have a valid mesh.")

func _on_split_confirmed():
	if not selected_mesh_instance or not selected_mesh_instance.mesh: return
	
	var chunks_x = int(spin_x.value)
	var chunks_z = int(spin_z.value)
	var make_static = static_checkbox.button_pressed
	
	split_mesh(selected_mesh_instance, chunks_x, chunks_z, make_static)

func split_mesh(mi: MeshInstance3D, c_x: int, c_z: int, make_static: bool):
	var mesh = mi.mesh
	if mesh.get_surface_count() == 0: return
	
	var arrays = mesh.surface_get_arrays(0)
	var vertices = arrays[Mesh.ARRAY_VERTEX]
	var indices = arrays[Mesh.ARRAY_INDEX]
	var normals = arrays[Mesh.ARRAY_NORMAL] if arrays.size() > Mesh.ARRAY_NORMAL else null
	var uvs = arrays[Mesh.ARRAY_TEX_UV] if arrays.size() > Mesh.ARRAY_TEX_UV else null
	
	var aabb = mesh.get_aabb()
	var min_pos = aabb.position
	var size = aabb.size
	var chunk_size_x = size.x / c_x
	var chunk_size_z = size.z / c_z
	
	var chunks_data = {}
	
	for i in range(0, indices.size(), 3):
		var i1 = indices[i]
		var i2 = indices[i+1]
		var i3 = indices[i+2]
		
		var v1 = vertices[i1]
		var v2 = vertices[i2]
		var v3 = vertices[i3]
		
		var centroid = (v1 + v2 + v3) / 3.0
		
		var grid_x = int(clamp((centroid.x - min_pos.x) / chunk_size_x, 0, c_x - 1))
		var grid_z = int(clamp((centroid.z - min_pos.z) / chunk_size_z, 0, c_z - 1))
		var coord = Vector2i(grid_x, grid_z)
		
		if not chunks_data.has(coord):
			chunks_data[coord] = {
				"v": PackedVector3Array(),
				"n": PackedVector3Array(),
				"uv": PackedVector2Array(),
				"i": PackedInt32Array(),
				"map": {} 
			}
			
		var c_data = chunks_data[coord]
		
		for orig_idx in [i1, i2, i3]:
			if not c_data.map.has(orig_idx):
				c_data.map[orig_idx] = c_data.v.size()
				c_data.v.append(vertices[orig_idx])
				if normals: c_data.n.append(normals[orig_idx])
				if uvs: c_data.uv.append(uvs[orig_idx])
			
			c_data.i.append(c_data.map[orig_idx])
			
	var root = EditorInterface.get_edited_scene_root()
	var undo_redo = get_undo_redo()
	
	undo_redo.create_action("Split Terrain into Chunks")
	
	for coord in chunks_data:
		var c_data = chunks_data[coord]
		var new_arrays = []
		new_arrays.resize(Mesh.ARRAY_MAX)
		new_arrays[Mesh.ARRAY_VERTEX] = c_data.v
		new_arrays[Mesh.ARRAY_INDEX] = c_data.i
		if not c_data.n.is_empty(): new_arrays[Mesh.ARRAY_NORMAL] = c_data.n
		if not c_data.uv.is_empty(): new_arrays[Mesh.ARRAY_TEX_UV] = c_data.uv
		
		var new_mesh = ArrayMesh.new()
		new_mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, new_arrays)
		
		var new_mi = MeshInstance3D.new()
		new_mi.mesh = new_mesh
		
		if mesh.get_surface_count() > 0 and mesh.surface_get_material(0):
			new_mi.material_override = mesh.surface_get_material(0)
		elif mi.material_override:
			new_mi.material_override = mi.material_override
			
		var chunk_root: Node3D
		
		# --- NEW HIERARCHY LOGIC ---
		if make_static:
			var static_body = StaticBody3D.new()
			static_body.name = "TerrainChunk_%d_%d" % [coord.x, coord.y]
			
			new_mi.name = "MeshInstance3D"
			static_body.add_child(new_mi)
			
			var collision_shape = CollisionShape3D.new()
			collision_shape.name = "CollisionShape3D"
			collision_shape.shape = new_mesh.create_trimesh_shape() 
			static_body.add_child(collision_shape)
			
			chunk_root = static_body # StaticBody is the parent
		else:
			new_mi.name = "TerrainChunk_%d_%d" % [coord.x, coord.y]
			chunk_root = new_mi # MeshInstance is the parent if no static body
		
		# DO: Adds the root node to the tree and sets the owner properly for all children
		undo_redo.add_do_method(self, "_add_node_and_set_owner", mi, chunk_root, root)
		# UNDO: Removes the root node from the tree
		undo_redo.add_undo_method(mi, "remove_child", chunk_root)
		
	undo_redo.commit_action()

func _add_node_and_set_owner(parent: Node, child: Node, owner_node: Node):
	parent.add_child(child)
	_set_owner_recursive(child, owner_node)

func _set_owner_recursive(node: Node, owner_node: Node):
	node.owner = owner_node
	for child in node.get_children():
		_set_owner_recursive(child, owner_node)
