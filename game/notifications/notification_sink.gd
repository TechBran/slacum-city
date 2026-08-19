class_name NotificationSink
extends RefCounted
## **The seam.** Doc 08 §4's `INotificationSink`: what a delivered notification
## leaves the game through.
##
## What ships now and what does not
## --------------------------------
##
## `NotificationRouter` produces a *plan* — a class, a channel id, a pair of
## string keys, a deeplink and a fire time — and hands it to a sink. This base
## class is the **null sink**: it answers "unavailable" to everything and drops
## every plan on the floor. That is the shipped behaviour, and it is correct,
## because doc 08 §2.13 is explicit that the sim does not run while the app is
## closed and doc 13 owns the platform half (channels, `AlarmManager`, the
## `POST_NOTIFICATIONS` flow) as **phase 2**.
##
## So: the in-app pipeline is live, every push decision is *made* and recorded,
## and nothing buzzes. When doc 13 phase 2 lands, it subclasses this, or extends
## `NativeNotificationSink` below, and nothing above the seam changes — the
## router already ran the budget, so **doc 13 applies no rate limiting of its
## own** (report C-71) and the plan it receives is final.
##
## What the seam guarantees, and why each guarantee is here
## --------------------------------------------------------
##
## * **Copy is keys, never sentences.** A plan carries `title_key` / `body_key`
##   under doc 08 §3.3's convention (`n_<notify_id>_title`). The sink resolves
##   them against doc 13's `data/notifications_text.json` at delivery, which is
##   what stops a push and its in-app row from ever drifting apart (G-8) and
##   what makes localisation a table rather than a code change.
## * **Channel ids come from the class table**, so system settings work: a
##   player who silences `slacum_routine` in Android's own UI has silenced P3
##   here (spec §49), and the id is stable for the life of the install.
## * **The router never asks whether delivery worked.** `deliver()` returns a
##   bool for logging, not for retry. A push that did not go out is not a lost
##   event: the event is already in the ring and in the WHILE YOU WERE AWAY
##   report, which is doc 08's anti-frustration rule and the reason this seam can
##   be a no-op without anything being wrong.
## * **`cancel_all()` on resume.** Doc 08 §2.13: on resume every pending alarm is
##   cancelled and re-planned, because a notification whose predicted event did
##   not happen has to be reconciled rather than left to fire.

## Delivery outcomes, for a caller that logs them.
const DELIVERED := "delivered"
const UNAVAILABLE := "unavailable"


## False everywhere except a build whose platform layer can actually post. The
## router checks this once and keeps making decisions either way.
func is_available() -> bool:
	return false


## Hand the sink `data/notifications.json`'s `delivery` block (doc 13's platform
## half). Called by `NotificationRouter.set_sink`, so a sink never has to open a
## file and a test can pass a fixture.
func configure(_delivery: Dictionary) -> void:
	pass


## Create (or update) one Android channel per enabled class. Called once at
## bring-up with the rows from `NotificationConfig.classes()`. Returns how many
## channels the platform now has.
func ensure_channels(_class_rows: Array) -> int:
	return 0


## Post or schedule one plan. `plan` is `NotificationRouter`'s dictionary,
## unmodified.
func deliver(_plan: Dictionary) -> bool:
	return false


## Drop every scheduled-but-unfired notification. doc 08 §2.13's resume step.
func cancel_all() -> int:
	return 0
