extends SimTest


func test_same_seed_same_sequence() -> void:
	var a := RngStreams.new(42)
	var b := RngStreams.new(42)
	for i in 20:
		assert_eq(a.stream("weather").randi(), b.stream("weather").randi(), "draw %d" % i)


func test_different_seeds_differ() -> void:
	var a := RngStreams.new(1)
	var b := RngStreams.new(2)
	var identical := true
	for i in 10:
		if a.stream("failures").randi() != b.stream("failures").randi():
			identical = false
	assert_false(identical, "different master seeds must give different sequences")


func test_streams_are_independent() -> void:
	# Drawing from one stream must not perturb another.
	var a := RngStreams.new(7)
	var b := RngStreams.new(7)
	for i in 50:
		a.stream("traffic").randi()  # extra draws on a different stream
	for i in 10:
		assert_eq(a.stream("director").randi(), b.stream("director").randi(), "draw %d" % i)


func test_serialize_resumes_sequence() -> void:
	var a := RngStreams.new(99)
	for i in 17:
		a.stream("incidents").randi()
	var saved := a.serialize()
	var expected: Array[int] = []
	for i in 10:
		expected.append(a.stream("incidents").randi())
	var restored := RngStreams.new(0)
	restored.deserialize(saved)
	for i in 10:
		assert_eq(restored.stream("incidents").randi(), expected[i], "resumed draw %d" % i)


func test_all_named_streams_exist() -> void:
	var streams := RngStreams.new(0)
	for stream_name in RngStreams.STREAM_NAMES:
		assert_true(streams.stream(stream_name) != null, stream_name)
