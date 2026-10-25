extends Node

## Runs after LookInput (priority 0) and before the camera manager (priority 10).
## In record mode it snapshots the look vector that the camera manager is about
## to consume. In replay mode it injects the recorded look vector.

var runtime: Node = null


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	process_priority = 1


func _physics_process(_delta: float) -> void:
	if runtime == null or not is_instance_valid(runtime):
		return
	runtime.call(&"camera_tick")
