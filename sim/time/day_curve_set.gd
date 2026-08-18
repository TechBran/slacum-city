class_name DayCurveSet
extends RefCounted
## Piecewise-linear day curves + channel definitions (doc 01 §2.6).
## Keyframes sit on whole game-hours (validated); sampling is always at a step
## midpoint, which makes the mean of an hour's fine samples equal the coarse
## sample exactly.

const NORMALIZED_MEAN_TOLERANCE := 0.02

var _curves: Dictionary = {}  # name -> {kind: String, keys: Array[[h, v]]}
var _channels: Dictionary = {}  # name -> {curve: String, min: float, max: float}
var errors: PackedStringArray = []


func load_from(data: Dictionary) -> bool:
	errors.clear()
	_curves.clear()
	_channels.clear()
	var curves: Dictionary = data.get("curves", {})
	for curve_name in curves:
		var c: Dictionary = curves[curve_name]
		var kind := String(c.get("kind", ""))
		if kind != "normalized" and kind != "absolute":
			errors.append("curve %s: bad kind '%s'" % [curve_name, kind])
			continue
		var keys: Array = c.get("keys", [])
		if keys.is_empty():
			errors.append("curve %s: no keyframes" % curve_name)
			continue
		var last_h := -1
		var valid := true
		for k in keys:
			var h := float(k[0])
			if h != floorf(h) or h < 0 or h > 23:
				errors.append("curve %s: keyframe hour %s not a whole hour in [0,23]" % [curve_name, str(h)])
				valid = false
			if int(h) <= last_h:
				errors.append("curve %s: keyframe hours not strictly ascending" % curve_name)
				valid = false
			last_h = int(h)
		if not valid:
			continue
		_curves[curve_name] = {"kind": kind, "keys": keys}
		if kind == "normalized":
			var mean := curve_mean_24h(String(curve_name))
			if absf(mean - 1.0) > NORMALIZED_MEAN_TOLERANCE:
				errors.append("curve %s: normalized mean %f outside 1.000 ± %.2f" % [curve_name, mean, NORMALIZED_MEAN_TOLERANCE])
	var channels: Dictionary = data.get("channels", {})
	for channel_name in channels:
		var ch: Dictionary = channels[channel_name]
		var curve_ref := String(ch.get("curve", ""))
		if not _curves.has(curve_ref):
			errors.append("channel %s: references missing curve '%s'" % [channel_name, curve_ref])
			continue
		var lo := float(ch.get("min", 0.0))
		var hi := float(ch.get("max", 1.0))
		if lo > hi:
			errors.append("channel %s: min > max" % channel_name)
			continue
		_channels[channel_name] = {"curve": curve_ref, "min": lo, "max": hi}
	return errors.is_empty()


func channel_names() -> Array:
	var names := _channels.keys()
	names.sort()
	return names


func has_channel(channel_name: String) -> bool:
	return _channels.has(channel_name)


## Sample a curve at hour-of-day x (wraps at 24).
func sample(curve_name: String, x: float) -> float:
	assert(_curves.has(curve_name), "unknown curve: " + curve_name)
	var keys: Array = _curves[curve_name]["keys"]
	var n := keys.size()
	if n == 1:
		return float(keys[0][1])
	x = fposmod(x, 24.0)
	# Before the first keyframe: interpolate from the last keyframe wrapped back.
	if x < float(keys[0][0]):
		var h0 := float(keys[n - 1][0]) - 24.0
		var v0 := float(keys[n - 1][1])
		var h1 := float(keys[0][0])
		var v1 := float(keys[0][1])
		return v0 + (x - h0) / (h1 - h0) * (v1 - v0)
	for i in n:
		var h1 := float(keys[i + 1][0]) if i + 1 < n else float(keys[0][0]) + 24.0
		var v1 := float(keys[i + 1][1]) if i + 1 < n else float(keys[0][1])
		if x < h1:
			var h0 := float(keys[i][0])
			var v0 := float(keys[i][1])
			return v0 + (x - h0) / (h1 - h0) * (v1 - v0)
	return float(keys[0][1])  # unreachable


## Exact 24-hour mean of the piecewise-linear curve (trapezoid, including wrap).
func curve_mean_24h(curve_name: String) -> float:
	var keys: Array = _curves[curve_name]["keys"]
	var n := keys.size()
	if n == 1:
		return float(keys[0][1])
	var area := 0.0
	for i in n:
		var h0 := float(keys[i][0])
		var v0 := float(keys[i][1])
		var h1 := float(keys[(i + 1) % n][0])
		var v1 := float(keys[(i + 1) % n][1])
		if i + 1 == n:
			h1 += 24.0
		area += (v0 + v1) * 0.5 * (h1 - h0)
	return area / 24.0


func channel_curve_value(channel_name: String, x: float) -> float:
	assert(_channels.has(channel_name), "unknown channel: " + channel_name)
	return sample(String(_channels[channel_name]["curve"]), x)


func channel_clamp(channel_name: String, value: float) -> float:
	var ch: Dictionary = _channels[channel_name]
	return clampf(value, float(ch["min"]), float(ch["max"]))
