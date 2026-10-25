extends RefCounted

## Binary run-file reader/writer.
##
## File layout (little endian):
##   char[8]  magic "SNPTAS01"
##   u32      header length, then var_to_bytes(Dictionary)
##   u32      initial snapshot length, then var_to_bytes(Dictionary)
##   u32      input length, then PackedByteArray (30 bytes per tick)
##   u32      hash-chain length, then repeated { s32 tick, s64 hash }
##   u32      checksum (hash of every payload byte above)
##
## The snapshot and header are Godot Variant data, so the reader validates the
## magic, version, sizes, checksum, and tick count before trusting them.

const MAGIC: String = "SNPTAS01"
const FILE_VERSION: int = 1
const MAX_BLOB_BYTES: int = 256 * 1024 * 1024
const RUN_DIR: String = "user://tas_runs"
const LAST_PATH: String = "user://tas_runs/last.snaptas"
const MANUAL_PATH: String = "user://tas_runs/manual.snaptas"


static func ensure_directory() -> bool:
	if DirAccess.dir_exists_absolute(RUN_DIR):
		return true
	return DirAccess.make_dir_recursive_absolute(RUN_DIR) == OK


static func timestamp_name() -> String:
	var now := Time.get_datetime_dict_from_system()
	return "run_%04d%02d%02d_%02d%02d%02d" % [
		int(now.get("year", 0)),
		int(now.get("month", 0)),
		int(now.get("day", 0)),
		int(now.get("hour", 0)),
		int(now.get("minute", 0)),
		int(now.get("second", 0)),
	]


static func save(
	path: String,
	meta: Dictionary,
	initial_snapshot: Dictionary,
	inputs: PackedByteArray,
	hashes: Array,
	tick_bytes: int
) -> Dictionary:
	if not ensure_directory():
		return {"ok": false, "error": "could not create " + RUN_DIR}

	var header := meta.duplicate(true)
	header["file_version"] = FILE_VERSION
	header["tick_count"] = inputs.size() / tick_bytes if tick_bytes > 0 else 0
	header["input_bytes"] = inputs.size()
	header["hash_count"] = hashes.size()

	var header_bytes := var_to_bytes(header)
	var snapshot_bytes := var_to_bytes(initial_snapshot)
	var hash_bytes := PackedByteArray()
	hash_bytes.resize(hashes.size() * 12)
	for i in hashes.size():
		var entry: Dictionary = hashes[i]
		hash_bytes.encode_s32(i * 12, int(entry.get("tick", 0)))
		hash_bytes.encode_s64(i * 12 + 4, int(entry.get("hash", 0)))

	var payload := PackedByteArray()
	payload.append_array(header_bytes)
	payload.append_array(snapshot_bytes)
	payload.append_array(inputs)
	payload.append_array(hash_bytes)

	var file := FileAccess.open(path, FileAccess.WRITE)
	if file == null:
		return {"ok": false, "error": "could not open %s (%s)" % [path, error_string(FileAccess.get_open_error())]}

	file.store_buffer(MAGIC.to_ascii_buffer())
	_store_blob(file, header_bytes)
	_store_blob(file, snapshot_bytes)
	_store_blob(file, inputs)
	_store_blob(file, hash_bytes)
	file.store_32(hash(payload))
	file.close()
	return {"ok": true, "path": path, "bytes": payload.size() + 8 + 5 * 4}


static func load(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {"ok": false, "error": "run file not found: " + path}
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return {"ok": false, "error": "could not open " + path}

	var magic := file.get_buffer(8).get_string_from_ascii()
	if magic != MAGIC:
		return {"ok": false, "error": "not a SNAPTIC-TAS run file"}

	var header_bytes := _read_blob(file)
	var snapshot_bytes := _read_blob(file)
	var inputs := _read_blob(file)
	var hash_bytes := _read_blob(file)
	if header_bytes.is_empty() and snapshot_bytes.is_empty() and inputs.is_empty() and hash_bytes.is_empty():
		return {"ok": false, "error": "truncated run file"}
	var stored_checksum := file.get_32()
	file.close()

	var payload := PackedByteArray()
	payload.append_array(header_bytes)
	payload.append_array(snapshot_bytes)
	payload.append_array(inputs)
	payload.append_array(hash_bytes)
	if hash(payload) != stored_checksum:
		return {"ok": false, "error": "run file checksum mismatch"}

	var header = bytes_to_var(header_bytes)
	var snapshot = bytes_to_var(snapshot_bytes)
	if not (header is Dictionary) or not (snapshot is Dictionary):
		return {"ok": false, "error": "run file header/snapshot is not a Dictionary"}
	if int(header.get("file_version", 0)) != FILE_VERSION:
		return {"ok": false, "error": "unsupported run file version"}
	if int(header.get("tick_count", -1)) != inputs.size() / 30:
		return {"ok": false, "error": "run file tick count does not match input data"}

	var hashes: Array = []
	for offset in range(0, hash_bytes.size(), 12):
		if offset + 12 > hash_bytes.size():
			return {"ok": false, "error": "truncated hash chain"}
		hashes.append({
			"tick": hash_bytes.decode_s32(offset),
			"hash": hash_bytes.decode_s64(offset + 4),
		})

	return {
		"ok": true,
		"path": path,
		"header": header,
		"snapshot": snapshot,
		"inputs": inputs,
		"hashes": hashes,
	}


static func _store_blob(file: FileAccess, bytes: PackedByteArray) -> void:
	file.store_32(bytes.size())
	file.store_buffer(bytes)


static func _read_blob(file: FileAccess) -> PackedByteArray:
	var size := file.get_32()
	if size < 0 or size > MAX_BLOB_BYTES or file.get_position() + size > file.get_length():
		return PackedByteArray()
	return file.get_buffer(size)
