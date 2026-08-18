# BLACKOUT — Complete Game Design & Technical Specification

**Status:** Living design specification  
**Platform:** Android-first mobile game  
**Working title:** BLACKOUT  
**Document purpose:** Source-of-truth product/design spec for continued iteration and implementation planning  
**Primary genre:** Persistent urban survival / crisis-management strategy game  
**Secondary genres:** City builder, infrastructure management simulator, emergency-response strategy, disaster simulator  
**Monetization:** Free-to-play with ethical in-app purchases, cosmetics, expansions, optional acceleration, and premium upgrades  
**Core product thesis:** **You do not just build the city. You keep it alive.**

---

## 1. Executive Summary

BLACKOUT is an Android-first strategy game in which the player builds, expands, upgrades, operates, and protects a persistent city.

Unlike traditional mobile city builders, the primary challenge is not simply zoning land, placing attractive buildings, or collecting passive income. The city contains interconnected infrastructure and emergency-response systems that can fail, overload, break, or be damaged by weather, crime, accidents, disasters, and extreme late-game events.

The player is responsible for:

- Expanding the city by acquiring and developing land.
- Constructing and upgrading buildings.
- Growing population and tax revenue.
- Building and maintaining the electrical grid.
- Building and maintaining the water system.
- Maintaining roads and access.
- Operating police, fire, utility, water, construction, and eventually other response fleets.
- Responding to incidents with finite resources.
- Preparing for forecast hazards.
- Surviving disasters.
- Recovering from damage.
- Building redundancy so the same failure does not destroy the city twice.
- Continuing to grow a city that remains active while the player is away.

The defining gameplay feature is **system interaction**.

A transformer failure is not just a red icon. It can remove power from a district, shut down traffic lights, reduce business output, increase crime, create vehicle accidents, stress emergency services, disable water pumping, and worsen a fire that begins during the outage.

BLACKOUT is therefore designed around:

> **Build → Operate → Crisis → Respond → Recover → Improve → Expand**

The player creates the city, but the simulation continuously tests how resilient that city actually is.

---

# 2. Product Identity

## 2.1 What BLACKOUT Is

BLACKOUT is:

- A persistent city simulation.
- A city-building strategy game.
- An infrastructure-management game.
- An emergency-dispatch game.
- A disaster simulator.
- A resilience strategy game.
- A long-term progression game.
- A mobile game designed around short check-ins and long sessions.
- A game where one system can create consequences in another.

## 2.2 What BLACKOUT Is Not

BLACKOUT is not intended to be:

- A direct SimCity BuildIt clone.
- A Pocket City clone.
- A decoration-first city builder.
- A walking-around mayor simulator.
- A quest-heavy casual city game.
- A pure electrical-grid simulator.
- A pure emergency-dispatch simulator.
- A fully realistic engineering simulator.
- A game that simulates every citizen individually.
- A pay-to-win game where players are punished into spending money.
- A game where disasters exist only as visual effects.

---

# 3. Differentiation

The game must be intentionally differentiated from existing city builders.

Traditional city-builder emphasis:

- Placement
- Zoning
- Expansion
- Collection
- Decoration
- Passive production
- Population growth

BLACKOUT emphasis:

- Operations
- Infrastructure
- Readiness
- Emergency response
- Cascading failures
- Resilience
- Recovery
- Persistent risk
- System interaction

The player should quickly understand:

> **The city can actually break.**

The game should never reduce major city systems to simple decorative statistics.

Electricity is not merely "Power: 83%."

The player owns actual generation, substations, distribution capacity, transformers, lines, and repair crews.

Water is not merely "Water: 91%."

The player operates pumping, storage, distribution, and repair capacity.

Police and fire are not merely coverage percentages.

The player owns stations, vehicles, and finite units that can already be busy when another emergency occurs.

---

# 4. Design Pillars

BLACKOUT should be evaluated against the following pillars throughout development.

## Pillar 1 — Everything Is Connected

Systems must influence other systems.

Examples:

- Power outage → traffic lights fail → congestion increases → response times increase.
- Power outage → street lighting fails → crime probability rises.
- Power outage → water pump fails → hydrant pressure falls.
- Water-main failure → fire protection becomes weaker.
- Flood → roads become impassable → utility crews cannot reach damaged equipment.
- Stadium event → traffic and police demand increase.
- Heat wave → electrical load increases → transformers heat faster.
- Blizzard → roads slow → repair crews take longer → outages persist.
- Data center upgrade → taxes increase → electric and water demand increase sharply.

## Pillar 2 — Build It, Then Prove It

The city-building phase creates the player's infrastructure.

Disasters and incidents test those decisions.

The player should eventually learn:

- Redundancy matters.
- Geography matters.
- Emergency coverage matters.
- Infrastructure capacity matters.
- Response capacity matters.
- Over-expansion can be dangerous.
- Cheap land may carry hidden environmental risk.

## Pillar 3 — The City Must Feel Alive

The city should visually and mechanically continue to exist beyond direct player input.

The player should see:

- Traffic.
- Building activity.
- Construction.
- Emergency vehicles.
- Day/night cycles.
- Weather.
- Power failures.
- Districts lighting up and going dark.
- Fires.
- Flooding.
- Population and economic activity.

The city continues progressing while the app is closed.

## Pillar 4 — Crisis Creates Stories

The best gameplay moments should emerge naturally.

Example:

> Lightning damages a transmission line → a district loses power → a water pump stops → hydrant pressure falls → a structure fire begins → fire crews arrive but suppression is weakened → a crash blocks an alternate route → utility repair is delayed → police calls begin increasing in the darkened district.

The simulation created the mission.

## Pillar 5 — Growth Creates Both Wealth and Risk

Every meaningful upgrade should increase opportunity while also increasing demand, complexity, or consequence.

Bigger buildings:

- Produce more taxes.
- House more people or jobs.
- Consume more power.
- Consume more water.
- Increase service demand.
- Create larger consequences when they fail.

## Pillar 6 — Art Direction Over Brute-Force Realism

BLACKOUT should look premium without chasing console-level photorealism.

The target is:

- Stylized 3D.
- Strong nighttime lighting.
- Strong silhouettes.
- Weather VFX.
- High visual contrast.
- Readable utility overlays.
- Smooth camera movement.
- Efficient rendering.

The city should be visually memorable when operating normally and dramatic when systems fail.

---

# 5. Core Player Fantasy

The player is the operator, builder, planner, and emergency coordinator of a growing city.

The fantasy is:

> **I built this city. I understand how it works. I know where its weaknesses are. When everything goes wrong, I can save it.**

The player should develop attachment to the city because:

- They chose where to expand.
- They built the infrastructure.
- They upgraded buildings.
- They invested in specific neighborhoods.
- They remember previous disasters.
- Their skyline reflects long-term progress.
- Their resilience reflects earlier strategic decisions.

---

# 6. Core Gameplay Loop

## 6.1 Primary Loop

1. Collect taxes and review city health.
2. Inspect active incidents and system warnings.
3. Dispatch available response units.
4. Repair failures.
5. Acquire new land.
6. Develop the new land.
7. Construct buildings and infrastructure.
8. Upgrade existing buildings.
9. Increase population, jobs, and tax revenue.
10. Increase electrical and water demand.
11. Expand city services.
12. Encounter incidents and disasters.
13. Recover from damage.
14. Improve weak infrastructure.
15. Repeat.

## 6.2 Emotional Loop

The intended emotional cadence is:

**Calm planning → growth → pressure → warning → crisis → chaos → stabilization → relief → rebuilding → confidence → larger crisis**

---

# 7. City Map & Expansion

## 7.1 Map Structure

The city uses a modular tile/chunk system.

The player begins with a small developed area and surrounding locked land.

The world is divided into purchasable land blocks.

A land block should generally need to border already controlled land before purchase, keeping expansion geographically coherent.

Future exceptions can include:

- Islands.
- Bridges.
- Satellite districts.
- Industrial zones.
- Special development areas.

## 7.2 Land Acquisition

Land has a purchase cost based on:

- Distance from current city center.
- Development potential.
- Terrain.
- Environmental risk.
- Existing road access.
- Waterfront/coastal location.
- Elevation.
- Proximity to desirable districts.

Example tradeoffs:

### Riverfront
Advantages:
- High property value.
- High tourism potential.
- Attractive commercial development.

Risks:
- Flooding.
- Storm surge.
- Bridge dependency.

### High Ground
Advantages:
- Flood protection.
- Good infrastructure resilience.

Costs:
- Expensive grading.
- Higher road-development cost.

### Industrial Edge
Advantages:
- Cheap land.
- Suitable for large power and industrial facilities.

Risks:
- Pollution.
- Fire.
- Hazmat incidents.
- Long utility runs.

## 7.3 Land Development

Buying land does not immediately make it usable.

Development phases can include:

1. Survey.
2. Clearing.
3. Grading.
4. Road installation.
5. Utility corridor installation.
6. Final development.

Construction vehicles should visibly work on the area.

The player should see land transform from undeveloped terrain into a buildable district.

---

# 8. Roads & Mobility

Roads are both visual infrastructure and simulation infrastructure.

They determine:

- Vehicle travel.
- Emergency-response time.
- Construction access.
- Utility crew access.
- Traffic congestion.
- Flood accessibility.
- Disaster evacuation.
- District connectivity.

## 8.1 Road Graph

Roads should internally use a graph representation.

Emergency and service vehicles use real routing.

Civilian traffic can be heavily simplified and partially cosmetic.

## 8.2 Traffic

Traffic affects:

- Police response.
- Fire response.
- EMS response.
- Utility repair time.
- Construction.
- Disaster evacuation.

Traffic can increase from:

- Rush hour.
- Stadium events.
- Road closures.
- Accidents.
- Flooding.
- Disasters.
- Evacuations.
- Construction.

---

# 9. Building System

## 9.1 Building Archetypes

Initial target: approximately 15 core building archetypes.

Each archetype has five upgrade levels.

Possible initial archetypes:

### Residential
1. House
2. Apartment Building
3. Residential High-Rise

### Commercial
4. Retail / Store
5. Office Building
6. Commercial High-Rise

### Industrial / Technology
7. Factory
8. Warehouse / Logistics Facility
9. Data Center

### Civic / Public
10. Hospital
11. School
12. Stadium
13. Police Station
14. Fire Station
15. Utility / Public Works Facility

Additional later archetypes:

- Zoo
- Prison
- Airport
- Mall
- University
- Hotel
- Resort
- Nuclear facility
- Research complex
- Spaceport
- Arcology / Megablock

## 9.2 Five-Level Upgrade Model

Every primary building archetype should have:

- Level 1
- Level 2
- Level 3
- Level 4
- Level 5

Each level should have a visibly different model.

Upgrade effects can include:

- Increased population.
- Increased jobs.
- Increased tax output.
- Increased power demand.
- Increased water demand.
- Increased road demand.
- Increased fire consequence.
- Increased crime attractiveness.
- Higher service requirements.
- More complex incident possibilities.

## 9.3 Example — Residential High-Rise

### Level 1
- Approx. 12 floors.
- Moderate population.
- Moderate tax output.
- Manageable utility load.

### Level 2
- Approx. 24 floors.
- Increased population.
- Increased electric/water use.

### Level 3
- Approx. 36 floors.
- Significant service demand.
- Greater fire consequence.

### Level 4
- Approx. 48 floors.
- High tax output.
- High infrastructure requirements.

### Level 5
- Approx. 60+ floors.
- Landmark-scale structure.
- Very high population/tax output.
- Very high utility demand.
- Major consequence during outage/fire/evacuation.

Exact values are balancing parameters, not locked design requirements.

## 9.4 Upgrade Preconditions

Money alone should not guarantee an upgrade.

An upgrade may require:

- Treasury funds.
- Construction crews.
- Sufficient power capacity.
- Sufficient water capacity.
- Road access.
- Fire coverage.
- Police coverage.
- Minimum city level.
- Research/technology unlock.
- Land or structural requirements.

Example:

> Upgrade blocked: nearby electrical capacity insufficient.

This forces the player to upgrade infrastructure before vertically expanding the city.

---

# 10. Building Identity & Risk

Special buildings should introduce special gameplay.

Examples:

## Stadium
Benefits:
- Large tax revenue.
- Tourism.
- City prestige.

Risks/events:
- Event-day traffic.
- Police requirements.
- EMS requirements.
- Crowd incidents.
- Power spikes.
- Severe consequences during storms or outages.

## Data Center
Benefits:
- Very high commercial tax output.
- Jobs.
- Technology score.

Risks:
- Huge electrical demand.
- Significant cooling/water demand.
- Backup-generator dependence.
- Cooling failure.
- Fire.
- Outage penalties.

## Zoo
Benefits:
- Tourism.
- Happiness.
- Tax revenue.

Risks/events:
- Animal escape.
- Crowd panic.
- Police response.
- Specialized containment.
- Road closures.
- Property damage.

## Prison
Benefits:
- Jobs.
- Civic capacity.

Risks/events:
- Riot.
- Escape.
- Lockdown.
- Police mobilization.

## Nuclear Plant
Benefits:
- Massive generation.

Risks:
- Expensive maintenance.
- Strict reliability requirements.
- High-consequence emergency.
- Potential evacuation scenario.

## Arcology / Megablock
Late-game building.

Benefits:
- Enormous population.
- Enormous tax output.
- Efficient land use.

Risks:
- Extreme power and water demand.
- High emergency complexity.
- Catastrophic consequences during prolonged failure.

---

# 11. Economy & Taxes

## 11.1 Core Currency

The primary gameplay currency is the city treasury.

The city earns money primarily through taxes and fees.

Potential revenue streams:

- Residential property taxes.
- Commercial taxes.
- Industrial taxes.
- Entertainment/stadium revenue.
- Tourism.
- Utility fees.
- Special development revenue.
- Late-game exports or regional contracts.

## 11.2 Expenses

Ongoing expenses include:

- Police operations.
- Fire operations.
- Utility crews.
- Water services.
- Construction/public works.
- Building maintenance.
- Grid maintenance.
- Vehicle maintenance.
- Fuel.
- Debt service.
- Disaster recovery.
- Infrastructure replacement.

## 11.3 Budget Design

The player should always face a meaningful question:

> **Do I spend today for resilience, or grow faster and accept more risk?**

---

# 12. Construction System

Construction is a finite city resource.

## 12.1 Construction Crews

Early game:
- 1–2 basic crews.

Later game:
- More crews.
- Specialized crews.
- Faster crews.
- Larger project capacity.

Possible specializations:

- General construction.
- Excavation.
- High-rise construction.
- Road construction.
- Bridge construction.
- Heavy infrastructure.
- Disaster recovery.

## 12.2 Project Queue

Construction projects enter a queue.

Projects may include:

- New buildings.
- Building upgrades.
- Roads.
- Utility expansions.
- Substations.
- Water facilities.
- Bridges.
- Disaster repairs.
- Land development.

The player must prioritize limited construction capacity.

## 12.3 Construction Visualization

Major projects should visibly progress through stages.

Example high-rise:

1. Site preparation.
2. Excavation/foundation.
3. Structural frame.
4. Exterior buildout.
5. Rooftop/mechanical equipment.
6. Completion.

Construction cranes, trucks, fencing, and partially completed structures reinforce city progression visually.

---

# 13. Electrical Grid

The electrical system is one of the game's most important simulation layers.

## 13.1 Components

Possible components:

- Power plants.
- Renewable generation.
- Batteries.
- Transmission lines.
- Substations.
- Feeders.
- Transformers.
- Distribution lines.
- Backup generators.
- Switching/tie points.

## 13.2 Electrical Attributes

Components can have:

- Capacity.
- Current load.
- Condition.
- Temperature.
- Failure probability.
- Weather exposure.
- Maintenance state.
- Upgrade level.
- Redundancy.

## 13.3 Failure Types

- Overload.
- Transformer failure.
- Line failure.
- Lightning strike.
- Substation trip.
- Generator failure.
- Fuel shortage.
- Flood damage.
- Wind damage.
- Heat stress.
- Fire.
- Cascading failure.

## 13.4 Grid Gameplay

The player can:

- Expand capacity.
- Build redundancy.
- Add alternate routes.
- Upgrade substations.
- Upgrade transformers.
- Add generation.
- Add storage.
- Prioritize critical facilities.
- Dispatch utility crews.
- Restore outages.
- Perform a black start in advanced scenarios.

## 13.5 Grid Overlay

A dedicated power overlay should show:

- Generation.
- Capacity.
- Load.
- Substations.
- Lines.
- Transformers.
- Outages.
- Overloads.
- Critical facilities.
- Animated power flow.

Color/state language should be simple:

- Normal.
- Warning.
- Critical.
- Failed/offline.

---

# 14. Water System

Water is the second major infrastructure system.

## 14.1 Components

Potential components:

- Water source.
- Treatment plant.
- Pumping station.
- Storage tank/reservoir.
- Water mains.
- Pressure zones.
- Distribution network.

## 14.2 Water Attributes

- Capacity.
- Demand.
- Pressure.
- Condition.
- Pump status.
- Storage level.
- Power dependency.

## 14.3 Failure Types

- Main break.
- Pump failure.
- Treatment failure.
- Low pressure.
- Flood contamination.
- Freeze damage.
- Power loss.
- Capacity shortage.

## 14.4 Cross-System Effects

Critical rule:

**Water depends on electricity unless backup systems are present.**

Water problems can affect:

- Fire hydrants.
- Hospitals.
- Residential happiness.
- Commercial activity.
- Industry.
- Health.
- Fire suppression.

---

# 15. Emergency & Service Response

Response resources are finite.

A major part of the strategy is deciding which incident deserves which available unit.

## 15.1 Initial Departments

### Police
Responds to:
- Crime.
- Traffic incidents.
- Riot/unrest.
- Security events.
- Special incidents.

### Fire
Responds to:
- Structure fire.
- Vehicle fire.
- Industrial fire.
- Rescue.
- Disaster fire.
- Hazmat later.

### Electrical Utility
Responds to:
- Transformer failure.
- Downed line.
- Substation issue.
- Grid damage.
- Restoration.

### Water Utility
Responds to:
- Main break.
- Pump failure.
- Flood-related infrastructure.
- Pressure problems.

### Construction/Public Works
Responds to:
- Construction.
- Debris removal.
- Road damage.
- Bridge damage.
- Disaster rebuilding.

## 15.2 Later Departments

- EMS.
- Hazmat.
- Search & rescue.
- Animal control.
- SWAT.
- Emergency management.
- Transit.
- National/state assistance.
- Military support in extreme scenarios.

## 15.3 Dispatch Queue

If all units are busy, new incidents enter a queue.

Consequences grow with wait time.

Example:

Transformer failure waits:
- Outage duration increases.
- Business output falls.
- Crime risk rises.
- Population dissatisfaction rises.
- Secondary incidents become more likely.

## 15.4 Vehicle Progression

Players can unlock/earn/buy more vehicles using city resources.

Vehicles should not simply be stat boosts; each new unit increases simultaneous response capacity.

Examples:

Police:
- Patrol car.
- Supervisor.
- SWAT.

Fire:
- Engine.
- Ladder.
- Rescue.
- Hazmat.

Utility:
- Service truck.
- Bucket truck.
- Heavy repair truck.
- Mobile transformer.

Water:
- Repair truck.
- Pump truck.
- Flood response.

Construction:
- General crew.
- Heavy equipment crew.
- Crane crew.
- Road crew.

---

# 16. Crime & Stability

Crime should not be completely random.

Each district has a stability state.

Possible inputs:

- Power availability.
- Street lighting.
- Police presence.
- Employment.
- Population density.
- Water availability.
- City happiness.
- Disaster state.
- Economic stress.
- Local building types.

## 16.1 Stability Thresholds

Illustrative behavior:

### High Stability
- Low crime.
- Minor incidents.

### Moderate Stability
- Theft.
- Vandalism.
- Burglary.

### Low Stability
- Assault.
- Looting.
- Larger police demand.

### Critical Stability
- Widespread unrest.
- Riots.
- Arson.
- Civil emergency.

Power outages, disasters, unemployment, or weak policing can drive stability downward.

---

# 17. Fire System

Fire can result from:

- Electrical failure.
- Structure risk.
- Industrial incident.
- Wildfire.
- Lightning.
- Riot/arson.
- Vehicle crash.
- Disaster damage.
- Utility failure.

Fire severity depends on:

- Building type.
- Building level.
- Response time.
- Water pressure.
- Fire-station availability.
- Weather.
- Wind.
- Nearby building density.

A Level 5 high-rise fire must be significantly more consequential than a Level 1 house fire.

---

# 18. Weather System

Weather is not cosmetic.

Weather changes city behavior.

## 18.1 Core Weather Types

- Clear.
- Cloudy.
- Rain.
- Heavy rain.
- Thunderstorm.
- Heat wave.
- Snow.
- Blizzard.
- High wind.
- Fog.
- Extreme cold.

## 18.2 Weather Effects

### Heat Wave
- High power demand.
- High water demand.
- Transformer heat.
- Health risk during outages.

### Snow/Blizzard
- Slower vehicles.
- Increased heating demand.
- Road closures.
- Construction slowdown.
- Frozen water infrastructure.
- Power-line damage.

### Thunderstorm
- Lightning.
- Wind damage.
- Flooding.
- Electrical failure.
- Fire.

### Extreme Rain
- Drainage stress.
- Flash flooding.
- Road closure.
- Substation risk.

Weather should move visibly across the city where feasible.

---

# 19. Disaster System

Disasters are a defining feature.

## 19.1 Tier 1 — Realistic Events

- Severe thunderstorm.
- Flash flood.
- River flood.
- Blizzard.
- Heat wave.
- Wildfire.
- Tornado.
- Hurricane.
- Earthquake.
- Major blackout.
- Major fire.
- Riot.
- Infrastructure collapse.

## 19.2 Tier 2 — Extreme Events

- Dam failure.
- Mega-earthquake.
- Superstorm.
- Catastrophic regional blackout.
- Large chemical accident.
- Major industrial explosion.
- Meteor strike.
- Massive solar storm.

## 19.3 Tier 3 — BLACKOUT Events

Optional/late-game outrageous scenarios:

- Zombie outbreak.
- Alien invasion.
- Zoo breakout.
- Massive prison escape.
- Experimental technology failure.
- Citywide communications collapse.
- Other high-concept seasonal/expansion scenarios.

These events should use existing systems rather than become unrelated minigames.

### Zombie Event Example

- Population evacuates.
- Roads clog.
- Police calls multiply.
- Hospitals overload.
- Utility crews lose access to areas.
- Buildings are abandoned.
- Containment zones are created.
- Power and water restoration becomes harder.
- Players reclaim districts.

### Alien Event Example

- Infrastructure targets are attacked.
- Fires spread.
- Roads become blocked.
- Power generation is damaged.
- Citizens panic.
- Emergency fleets are overwhelmed.
- The player must stabilize critical services.

### Zoo Breakout Example

- Escaped animals generate moving incidents.
- Police close roads.
- Animal-control resources are required.
- Traffic changes.
- Property damage can occur.
- Public panic reduces district stability.

---

# 20. Disaster Director

The Disaster Director controls challenge pacing.

It must avoid feeling unfair.

## 20.1 Inputs

The Director can consider:

- City age.
- Population.
- Treasury.
- Infrastructure redundancy.
- Emergency fleet strength.
- Recent disaster history.
- Current weather.
- Player progression.
- Current city stability.
- Current incident load.
- Difficulty setting.

## 20.2 Principles

The Director should:

- Avoid repeatedly attacking the same weakness without recovery time.
- Avoid destroying months of progress arbitrarily.
- Increase challenge gradually.
- Prefer readable cause-and-effect.
- Give warnings for major forecastable disasters.
- Allow preparation.
- Create combinations, not only larger numbers.
- Respect cooldown periods.
- Prevent catastrophic events from spawning when the city is already unrecoverable unless explicitly part of a challenge mode.

## 20.3 Forecastable vs Sudden Events

### Forecastable
- Hurricane.
- Heat wave.
- Blizzard.
- River flood.
- Major storm.

The player gets preparation time.

### Sudden
- Transformer explosion.
- Earthquake.
- Industrial accident.
- Crime.
- Vehicle accident.
- Zoo escape.

---

# 21. Persistent Simulation

The city continues while the app is closed.

This is a core requirement.

## 21.1 Design Principle

The game should not rely on the entire rendered city remaining alive in memory.

Instead:

- Save deterministic city state.
- Save simulation timestamp.
- Close rendering.
- When background execution occurs or the app reopens, advance the simulation mathematically.
- Generate an event history.
- Resolve automatic responses according to player settings.
- Present results.

## 21.2 Offline Catch-Up

When the player returns:

> WHILE YOU WERE AWAY

Possible report:

- Taxes collected.
- Construction progress.
- Population changes.
- Repairs completed.
- Crimes.
- Fires.
- Utility failures.
- Disasters.
- Units dispatched.
- Major unresolved emergencies.

## 21.3 Automatic Response Rules

Players can configure policies such as:

- Automatically dispatch nearest fire unit.
- Automatically dispatch police to high-priority calls.
- Utility priority: hospital → water → residential.
- Reserve one fire engine at all times.
- Do not spend emergency contractor funds automatically.
- Auto-repair failures below a cost threshold.

This allows the persistent city to remain functional without requiring continuous player presence.

---

# 22. Notifications

BLACKOUT should notify the player about meaningful events.

Examples:

- Major power outage.
- Severe storm warning.
- Hurricane approaching.
- Crime surge.
- Major fire.
- Water-system failure.
- Construction completion.
- City treasury threshold.
- Disaster escalation.
- Critical infrastructure warning.

Notifications should be rate-limited and priority-based.

The game should not spam players with minor incidents.

Suggested priority classes:

### Priority 1 — Critical
- Major disaster.
- Large outage.
- Hospital threat.
- Citywide emergency.

### Priority 2 — Important
- Major fire.
- Significant crime surge.
- Water failure.
- Large construction complete.

### Priority 3 — Routine
- Upgrade complete.
- New land ready.
- Long-term milestone.

---

# 23. Time Model

The exact time scaling remains configurable during balancing, but the architecture should support:

- Real elapsed time while offline.
- Compressed in-game simulation time.
- Construction timers.
- Disaster warning timers.
- Day/night cycles.
- Scheduled building events.
- Stadium events.
- Rush hour.

Recommended design direction:

- The simulation has a canonical game clock.
- Real elapsed time maps to game time through a configurable scale.
- Different modes can use different time multipliers.
- Offline catch-up uses the same deterministic clock.
- Major timers should be data-driven, not hard-coded.

---

# 24. Camera & Presentation

## 24.1 Camera

Target:

- 3D isometric / elevated city view.
- Pinch zoom.
- Pan.
- Optional controlled rotation.
- Quick jump to incidents.
- Quick jump to selected districts.
- Smooth transition between city overview and neighborhood detail.

## 24.2 Nighttime

Night should be one of the game's strongest visual moments.

The city should show:

- Lit windows.
- Street lights.
- Vehicle headlights.
- Emergency lights.
- Stadium lights.
- Industrial lights.
- Substation/electrical glow.
- Weather effects.

A power outage should visibly darken the affected district.

Restoring power should visibly relight the district.

This is a signature visual mechanic.

---

# 25. Art Direction

## 25.1 Style

Target style:

**Dark, atmospheric, neo-noir urban infrastructure simulation**

Not a direct copy of any copyrighted city or franchise.

Influences can include:

- Dense metropolitan skylines.
- Art-deco-inspired towers.
- Industrial infrastructure.
- Modern glass high-rises.
- Rainy nights.
- Fog.
- Neon accents.
- Strong emergency lighting.
- Dramatic weather.

## 25.2 Art Goals

- Premium appearance.
- Strong readability on phone screens.
- Stylized enough for performance.
- Buildings readable by type and level.
- Weather visually dramatic.
- Utility states visually obvious.
- High contrast at night.
- Avoid excessively cartoonish style if it weakens the crisis identity.

---

# 26. Utility Overlays

The normal city view remains visually clean.

Infrastructure details appear through overlays.

## Power Overlay
Shows:
- Plants.
- Lines.
- Substations.
- Transformers.
- Load.
- Capacity.
- Outages.
- Critical facilities.

## Water Overlay
Shows:
- Pumps.
- Tanks.
- Mains.
- Pressure.
- Failures.
- Coverage.

## Police Overlay
Shows:
- Stations.
- Available units.
- Crime hotspots.
- Coverage.
- Active incidents.

## Fire Overlay
Shows:
- Stations.
- Engines.
- Fire coverage.
- Water/hydrant effectiveness.
- Fire risk.

## Traffic Overlay
Shows:
- Congestion.
- Closures.
- Emergency routes.
- Flooded roads.

## Construction Overlay
Shows:
- Active projects.
- Crew assignments.
- Completion status.

---

# 27. Simulation Architecture

The simulation must remain independent from rendering.

## 27.1 High-Level Architecture

### Simulation Core
Responsible for:
- Buildings.
- Economy.
- Utilities.
- Population aggregates.
- Incidents.
- Vehicles.
- Weather.
- Disasters.
- Time.
- Persistence.
- Deterministic offline catch-up.

### Rendering Layer
Responsible for:
- 3D city.
- Buildings.
- Vehicles.
- Weather.
- Lighting.
- Effects.
- Camera.
- UI overlays.

### Android Native Layer
Responsible for:
- Notifications.
- Background scheduling where appropriate.
- Google Play Billing.
- Android lifecycle.
- Permissions.
- Deep links.
- Store integration.

### Save/Data Layer
Responsible for:
- City state.
- Player state.
- Unlocks.
- Settings.
- Purchases.
- Simulation timestamp.
- Event history.
- Recovery/checkpoints.

---

# 28. Recommended Technology Direction

Current recommended direction:

## Game Engine
**Unity 6 + URP** as the leading implementation candidate.

Reasons:
- Strong Android support.
- Mature mobile 3D rendering.
- Good tooling.
- C# simulation development.
- Asset ecosystem.
- LOD/culling support.
- Native Android plugin compatibility.

Alternative:
- Godot, if licensing/tooling/preference shifts during implementation planning.

## Simulation
C# systems separated from Unity scene objects wherever possible.

## Android Integration
Small Kotlin plugin/module for Android-specific functionality.

## Persistence
Local structured save state.

Potential implementation choices:
- SQLite.
- Binary save format.
- JSON only for debugging/export, not necessarily as the primary production format.

---

# 29. Performance Strategy

A visually large city does not require every city entity to run at full simulation frequency.

## 29.1 Population

Do not simulate citizens individually.

A building stores aggregate population data.

Example:

- Population.
- Employment.
- Health.
- Happiness.
- Crime exposure.
- Utility access.

Decorative pedestrians can be visual-only.

## 29.2 Civilian Traffic

Do not run advanced AI for every civilian vehicle.

Use:
- Spawn/despawn traffic.
- Lightweight route segments.
- Cosmetic motion.
- Density derived from traffic state.

Emergency/service vehicles use actual routing.

## 29.3 Level of Detail

Buildings use LOD.

### Far
- Simplified geometry.
- Minimal animation.
- Reduced lighting detail.

### Medium
- Standard building model.
- Basic windows/materials.

### Near
- Full model.
- Props.
- Detailed lighting.
- Construction detail.
- Emergency effects.

## 29.4 Chunking

World is divided into spatial chunks.

Only nearby/visible chunks receive full rendering attention.

Simulation state can continue globally in lightweight form.

## 29.5 Tick Rates

Different systems update at different rates.

Illustrative:

- Rendering: 60 FPS target on supported devices.
- Emergency vehicle logic: 10–30 Hz with interpolation.
- Utility simulation: 1–5 Hz.
- Incident evaluation: slower.
- Economy: slower still.
- Population growth: very low frequency.

Exact rates are profiling decisions.

## 29.6 Target Experience

Goal:
- Smooth camera.
- Fast UI.
- Stable simulation.
- Reasonable battery use.
- Graceful quality scaling.

Graphics settings can include:

- Performance.
- Balanced.
- High.

---

# 30. Day/Night Cycle

The city uses a dynamic day/night cycle.

Gameplay effects may include:

### Day
- Commercial activity.
- Construction.
- Traffic.
- Work population.

### Night
- Residential demand shifts.
- Street lighting demand.
- Higher visibility of blackouts.
- Potential crime modifier.
- Different traffic patterns.
- Strong visual atmosphere.

---

# 31. Population Model

Population is aggregate rather than individual.

Population is influenced by:

- Available housing.
- Taxes.
- Utility reliability.
- Safety.
- Employment.
- City stability.
- Disaster history.
- Services.
- Building upgrades.

Population loss can occur from:

- Long-term outages.
- Extended water failure.
- Severe disasters.
- Housing destruction.
- Poor stability.
- Major health emergencies.

Deaths should only occur from credible severe conditions, not short routine outages.

---

# 32. City Stability

A major city-wide and district-level metric.

Inputs may include:

- Power reliability.
- Water reliability.
- Crime.
- Police response.
- Fire response.
- Employment.
- Disaster state.
- Road access.
- Public confidence.
- Health.
- Infrastructure condition.

Stability influences:

- Crime.
- Population growth.
- Tax productivity.
- Business activity.
- Disaster recovery.
- Public confidence.

---

# 33. Incident System

Incidents are simulation objects.

Each incident can contain:

- Type.
- Location.
- Severity.
- Required units.
- Optional units.
- Time since start.
- Escalation timer.
- Dependencies.
- Consequences.
- Resolution state.
- Reward/penalty.
- Visibility.
- Notification priority.

Incidents can escalate.

Example:

Minor transformer issue  
→ failure  
→ outage  
→ district instability  
→ secondary crimes/fire

---

# 34. Failure & Cascading Event Model

The simulation should support dependency graphs.

Example:

Electrical feeder
↓
Water pump
↓
Hydrant pressure
↓
Fire effectiveness

Failure propagation should be data-driven where possible.

The goal is emergent behavior without requiring thousands of hand-scripted scenarios.

---

# 35. Difficulty

Potential difficulty modes:

## Casual
- Slower disasters.
- More warning.
- Cheaper recovery.
- Less punishing offline incidents.

## Standard
- Intended default.

## Hard
- Faster escalation.
- More expensive recovery.
- Stronger disasters.
- Lower infrastructure tolerances.

## Crisis / Survival
- Designed for experienced players.
- High event frequency.
- Limited resources.
- Leaderboard or challenge potential later.

Difficulty should change pressure, not just multiply health/damage values.

---

# 36. Progression

Progression should unlock:

- More land.
- Higher building levels.
- New building archetypes.
- Larger utilities.
- Better vehicles.
- New disaster classes.
- New technologies.
- District specializations.
- Advanced infrastructure.
- Late-game extreme events.

Possible broad eras:

1. Town.
2. Small city.
3. Metro.
4. Major metropolis.
5. Megacity.
6. Arcology era.
7. Experimental/future technology.
8. Optional off-world expansion later.

Off-world progression is a long-term expansion concept, not MVP scope.

---

# 37. Monetization Principles

The game should monetize expansion and personalization, not manufactured frustration.

## 37.1 Acceptable Monetization

- Cosmetic city themes.
- Cosmetic buildings.
- Special architecture packs.
- Optional currency packs.
- Construction acceleration.
- Additional city slots.
- Premium statistics/tools.
- Major content expansions.
- Disaster scenario packs.
- Future technology packs.
- Ad removal.
- Optional subscription only if it provides sustained value.

## 37.2 Avoid

- Paywalling basic emergency response.
- Creating artificial disasters purely to force spending.
- Making recovery effectively impossible without payment.
- Selling invulnerability.
- Making free players permanently noncompetitive in core gameplay.
- Excessive timers designed only to frustrate.

## 37.3 Premium Content Ideas

- Neo-noir architecture pack.
- Futuristic skyline pack.
- Disaster expansion.
- Zombie scenario pack.
- Alien invasion expansion.
- Advanced grid technology.
- Arcology pack.
- Seasonal city themes.

## 37.4 Building Purchases

Premium purchases can unlock access to special building families, but the player should still need to construct and support those buildings using in-game city resources.

Real money should unlock possibility, not bypass the entire simulation.

---

# 38. Ads

If ads are included:

- Do not interrupt crises.
- Do not show forced ads during active gameplay.
- Prefer optional rewarded ads.
- Consider a one-time ad-removal purchase.
- Rewarded ads can offer modest acceleration or recovery assistance.

Ads should never undermine premium atmosphere.

---

# 39. Audio

Audio should reinforce infrastructure and crisis.

Important sounds:

- Ambient city noise.
- Rain.
- Thunder.
- Wind.
- Sirens.
- Fire engines.
- Police.
- Utility vehicles.
- Construction.
- Electrical hum.
- Transformer failure.
- Grid trip.
- Power restoration.
- Flood water.
- Crowd panic.
- Disaster warnings.

Power restoration should have a satisfying audiovisual signature.

---

# 40. User Interface

The UI should remain operational and information-dense without feeling like a desktop spreadsheet.

## 40.1 Primary HUD

Potential top-level values:

- Population.
- Treasury.
- Net income.
- Grid health.
- Water health.
- Crime/stability.
- Active incidents.
- Weather.

## 40.2 Incident Drawer

Shows:

- Active incidents.
- Severity.
- Time waiting.
- Assigned units.
- Escalation risk.

## 40.3 City Dashboard

Example:

**Population:** 184,291  
**Treasury:** $8.42M  
**Net Income:** +$138K/day  
**Grid:** 91% stable  
**Water:** 97%  
**Crime:** Moderate  
**Fire Risk:** Elevated  
**Public Confidence:** 82%  
**Active Incidents:** 7

## 40.4 Building Panel

Shows:

- Building name.
- Level.
- Occupants/jobs.
- Tax contribution.
- Power consumption.
- Water consumption.
- Condition.
- Risk.
- Service coverage.
- Upgrade requirements.

---

# 41. Onboarding

The first session should demonstrate the core identity quickly.

Target onboarding sequence:

1. Player receives starter city.
2. Build one house.
3. Connect/confirm power.
4. Connect/confirm water.
5. Collect taxes.
6. Place one service building.
7. Receive one controlled incident.
8. Dispatch a unit.
9. Repair problem.
10. Upgrade one building.
11. Acquire first new land block.

The player should understand within the first session:

> **This city can fail, and I am responsible for keeping it running.**

---

# 42. Starter City

The game should begin with enough city to look attractive immediately.

Do not begin on an empty featureless grid.

Starter city could contain:

- Small residential area.
- Small commercial area.
- Roads.
- Basic power source.
- Small substation.
- Basic water source/tank.
- Police station.
- Fire station.
- Construction yard.
- A few undeveloped blocks.

The player is given something alive, then gradually gains control.

---

# 43. MVP / First Playable Scope

The first playable should prove the gameplay thesis rather than the full vision.

## 43.1 MVP Systems

Required:

- Small 3D city.
- Land purchase.
- Land development.
- Roads.
- Building placement.
- Building upgrades.
- Taxes.
- Population.
- Power.
- Water.
- Police.
- Fire.
- Utility repair.
- Construction crews.
- One weather system.
- One disaster.
- Persistent save.
- Offline catch-up.
- Basic notifications.
- Day/night.
- Emergency dispatch.
- Basic city dashboard.

## 43.2 MVP Building Types

Suggested initial subset:

1. House.
2. Apartment.
3. Commercial store.
4. Office.
5. High-rise.
6. Data center.
7. Police station.
8. Fire station.
9. Power facility.
10. Substation.
11. Water facility.
12. Construction yard.

Not all 15 archetypes must exist in the first prototype.

## 43.3 MVP Incidents

- Crime.
- Building fire.
- Transformer failure.
- Water-main failure.
- Traffic accident.
- Thunderstorm damage.

## 43.4 MVP Disaster

Recommended first major disaster:

**Severe thunderstorm**

Reason:
It can naturally test:
- Power.
- Roads.
- Fire.
- Utility crews.
- Water.
- Emergency dispatch.
- Weather rendering.

---

# 44. Vertical Slice Goal

The vertical slice should support:

> **Buy land → develop → build → collect taxes → upgrade → overload infrastructure → improve infrastructure → survive an incident/disaster → repair → continue growing**

If this loop is fun with limited content, the design is validated.

If this loop is not fun, adding more buildings or disasters will not solve the underlying problem.

---

# 45. Phase Roadmap

## Phase 0 — Design/Prototype
- Finalize simulation rules.
- Camera prototype.
- City grid prototype.
- Building placement.
- Basic roads.
- Basic rendering benchmark.
- Basic power graph.
- Emergency vehicle routing.

## Phase 1 — Core Vertical Slice
- Economy.
- Taxes.
- Power.
- Water.
- Basic buildings.
- Five-level upgrade architecture.
- Construction.
- Police.
- Fire.
- Utility crews.
- Day/night.
- Thunderstorm.
- Persistence.

## Phase 2 — Alpha City
- More building types.
- Land development.
- Full incident queue.
- Weather.
- Flooding.
- Better traffic.
- Notifications.
- Offline simulation.
- Disaster Director v1.
- Graphics polish.

## Phase 3 — Beta
- More disasters.
- More vehicles.
- Building-specific incidents.
- City stability.
- Advanced economy.
- IAP.
- Analytics.
- Performance optimization.
- Save recovery.
- Tutorial/polish.

## Phase 4 — Launch
- Android Play Store.
- Production billing.
- Crash reporting.
- Final balancing.
- Store assets.
- Onboarding.
- Launch events.

## Phase 5 — Post-Launch
- Zoo.
- Prison.
- Stadium event depth.
- Advanced grid.
- Hurricanes.
- Tornadoes.
- Earthquakes.
- Wildfires.
- Arcologies.
- Zombie scenario.
- Alien scenario.
- Major expansion packs.

---

# 46. Technical Data Model — Conceptual

## Building

```text
id
type
level
position
footprint
population
jobs
tax_output
power_demand
water_demand
condition
fire_risk
crime_risk
service_requirements
upgrade_state
construction_state
```

## Utility Node

```text
id
type
position
capacity
current_load
condition
temperature
power_state
water_state
connections[]
```

## Incident

```text
id
type
position
severity
start_time
escalation_time
required_units[]
assigned_units[]
dependencies[]
status
notification_priority
```

## Vehicle

```text
id
department
type
home_station
position
status
assigned_incident
route
speed
capabilities[]
```

## Land Block

```text
id
ownership_state
development_state
terrain
risk_profile
purchase_cost
development_cost
buildable_tiles
```

## District

```text
id
population
jobs
tax_output
stability
crime_index
power_reliability
water_reliability
fire_risk
traffic_state
```

---

# 47. Determinism & Saves

Offline catch-up should be reproducible where practical.

Recommended:

- Seeded random event generation.
- Timestamped state.
- Versioned save format.
- Periodic checkpoints.
- Safe recovery after interrupted save.
- Migration support between app versions.

The player must not lose a long-running city due to an update.

---

# 48. Analytics & Balancing

Track aggregate game events such as:

- Session length.
- Return interval.
- City age.
- Population.
- Average incident load.
- Common failure causes.
- Disaster outcomes.
- Upgrade choices.
- Land-purchase choices.
- Player churn points.
- IAP conversion.
- Ad engagement if ads exist.
- Tutorial completion.

Do not design solely around monetization analytics.

The primary metric must remain whether the game is engaging and understandable.

---

# 49. Accessibility & Mobile UX

Requirements:

- Readable text on phones.
- Scalable UI.
- Large touch targets.
- Color + icon states, not color alone.
- Haptic feedback optional.
- Graphics-quality options.
- Battery-conscious mode.
- Pause/slow-speed controls while app is open.
- Incident prioritization.
- One-tap jump to emergency.
- Clear notification controls.

---

# 50. Performance Acceptance Targets

Initial targets, subject to device profiling:

- 60 FPS target on modern flagship Android devices.
- 30 FPS acceptable fallback on lower tiers.
- Smooth pan and zoom.
- No simulation hitch during ordinary play.
- Offline catch-up must complete quickly enough to feel immediate.
- Large cities use LOD/chunking.
- Emergency vehicles remain responsive during major incidents.
- Weather effects scale by graphics preset.
- Large population values must not imply individual-agent simulation.

---

# 51. Risk Register

## Risk 1 — Scope Explosion

The vision can become enormous.

Mitigation:
- Build vertical slice first.
- Treat later systems as expansions.
- Never add a system unless it strengthens the core loop.

## Risk 2 — Too Similar to Existing City Builders

Mitigation:
- Prioritize operations and crisis.
- Make utilities physical systems.
- Make emergency dispatch central.
- Build cascading failure mechanics.
- Use distinct dark visual identity.

## Risk 3 — Simulation Too Complex for Players

Mitigation:
- Progressive unlocks.
- Strong overlays.
- Clear warnings.
- Contextual explanations.
- Start with few systems.

## Risk 4 — Simulation Too Expensive

Mitigation:
- Aggregate population.
- Lightweight traffic.
- Different tick rates.
- Chunking.
- LOD.
- Data-oriented simulation.
- Separate rendering from simulation.

## Risk 5 — Offline City Feels Unfair

Mitigation:
- Automatic response rules.
- Disaster cooldowns.
- Major warning systems.
- Recovery protection.
- Notification priority.
- Difficulty options.

## Risk 6 — Disasters Feel Random

Mitigation:
- Disaster Director.
- Forecasts.
- Visible causes.
- City-risk modeling.
- Player preparation.

## Risk 7 — Monetization Damages Reviews

Mitigation:
- Monetize expansion/content/cosmetics.
- Avoid engineered frustration.
- Keep core gameplay viable without payment.

---

# 52. Non-Goals for Initial Release

Do not require at launch:

- Millions of individually simulated citizens.
- Full pedestrian simulation.
- Fully realistic electrical engineering calculations.
- Full sewage simulation.
- Full public transit simulation.
- Full political simulation.
- Detailed individual household economics.
- Real-world GIS maps.
- Multiplayer.
- PvP.
- Off-world cities.
- Zombies.
- Aliens.
- Every disaster type.
- 50+ building archetypes.
- Desktop release.

These can be evaluated later.

---

# 53. Naming & Branding Note

**BLACKOUT** is the current working title.

The final release name should undergo:

- Google Play search.
- App Store search.
- Steam search if relevant.
- Domain search.
- Trademark screening.

The brand should emphasize:

- City operations.
- Infrastructure.
- Crisis.
- Survival.
- Darkness/power.
- Resilience.

Potential tagline:

> **You built it. Now keep it alive.**

---

# 54. Success Criteria

BLACKOUT is succeeding if players:

- Become attached to their city.
- Understand why failures occurred.
- Learn from disasters.
- Build redundancy.
- Feel tension when multiple incidents occur.
- Enjoy watching their city recover.
- Return to check what happened while away.
- Share spectacular disaster moments.
- See visible long-term city progression.
- View upgrades as strategic choices rather than simple stat increases.
- Understand that every major building increases both opportunity and risk.

---

# 55. Core Design Rules

These should remain protected during iteration.

1. **Everything is connected.**
2. **The city continues while the player is away.**
3. **Buildings produce both value and demand.**
4. **Upgrades visibly change buildings.**
5. **Every main building archetype supports five upgrade levels.**
6. **Emergency resources are finite.**
7. **Incidents can escalate.**
8. **Weather affects gameplay.**
9. **Disasters test previous planning decisions.**
10. **Utilities are systems, not decorative meters.**
11. **The renderer and simulation remain separate.**
12. **The player should be able to understand why a crisis happened.**
13. **Real money should expand possibility, not remove deliberately created pain.**
14. **The city must look good during normal operation and spectacular during failure.**
15. **The first playable must prove the core loop before scope expands.**

---

# 56. One-Sentence Product Definition

> **BLACKOUT is a persistent, dark atmospheric mobile strategy game where players build a growing city, operate its utilities and emergency services, and survive cascading infrastructure failures, crime, weather, natural disasters, and eventually extraordinary citywide crises in a simulation that continues even when the app is closed.**

---

# 57. One-Paragraph Pitch

BLACKOUT is a persistent urban survival strategy game built for mobile. Build and upgrade a living city, collect taxes, expand into new land, operate the electrical grid and water network, and manage finite police, fire, utility, and construction fleets. Your city keeps running while you are away, and failures can cascade across systems: a power outage can disable traffic lights, increase crime, reduce water pressure, delay emergency crews, and turn a routine incident into a citywide crisis. Prepare for thunderstorms, floods, blizzards, tornadoes, hurricanes, earthquakes, blackouts, riots, fires, and eventually outrageous late-game events such as zoo escapes, zombie outbreaks, and alien invasions. You built the city. Now keep it alive.

---

# 58. Immediate Next Design Tasks

The next iteration should focus on the following in order:

1. Lock the exact game-time model.
2. Define the initial 10–15 building archetypes.
3. Define five upgrade states for each launch building.
4. Define starting-city layout.
5. Define land-block dimensions.
6. Define economy formulas.
7. Define power capacity model.
8. Define water capacity model.
9. Define dispatch and incident timing.
10. Define Disaster Director rules.
11. Define first thunderstorm disaster.
12. Define offline catch-up behavior.
13. Define notification policy.
14. Prototype city rendering/performance.
15. Prototype road and emergency-vehicle routing.
16. Finalize MVP scope.
17. Build implementation plan.

---

# 59. Final Product Principle

BLACKOUT should never be judged by whether it contains more buildings than another city builder.

It should be judged by whether the player believes:

> **This city is mine, every system matters, something can go wrong at any time, and I know enough about the city I built to save it when it does.**
