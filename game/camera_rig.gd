class_name CameraRig
extends Node3D
## Thin Node over ui/'s CameraState (doc 11 §2.5 / doc 12 §2.16 split):
## doc 12 owns {focus, zoom_t, yaw} and every gesture; this rig derives the
## Camera3D transform and applies the doc-11 projection constants.

var state: CameraState
var camera: Camera3D


func setup(camera_state: CameraState, render_data: Dictionary) -> void:
	state = camera_state
	camera = Camera3D.new()
	var projection: Dictionary = render_data.get("camera", {})
	camera.fov = float(projection.get("fov_deg", 40.0))
	camera.near = float(projection.get("near", 1.0))
	camera.far = float(projection.get("far", 1600.0))
	add_child(camera)


func _process(delta: float) -> void:
	if state == null:
		return
	state.advance(delta)  # momentum + rubber-band integration
	camera.global_transform = state.camera_transform()
