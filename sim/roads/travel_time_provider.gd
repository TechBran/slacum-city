class_name TravelTimeProvider
extends RefCounted
## The interface doc 06's dispatch injects (doc 10 §4 / §5.2).
##
##   func travel_gs(from: Vector2i, to: Vector2i) -> int
##
## Whole GAME-SECONDS, because doc 06's unit ledger is integer game-seconds and
## its arrival timestamps must round-trip a save exactly. **−1 means UNREACHABLE**
## — never a large finite number, so doc 06's `min()` cannot silently pick an
## impossible unit (§4 guarantee 3, restated for the integer contract; the float
## API `route_minutes` still returns INF).
##
## The base class is a null provider: it says "everything is 60 game-seconds
## away", which lets doc 06 be unit-tested with no road network at all.

var flat_gs: int = 60


func travel_gs(_from: Vector2i, _to: Vector2i) -> int:
	return flat_gs
