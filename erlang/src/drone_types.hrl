%% Drone state record
-record(drone_state, {
    id :: integer(),
    ground_station :: atom(), % Managing ground station
    position = {0.0, 0.0} :: {float(), float()},
    waypoints = [] :: list({float(), float()}),
    battery = 100 :: integer(), % Percentage 0-100
    status = idle :: idle | moving | returning | low_battery | emergency,
    speed = 1.0 :: float(), % Drone Movement speed
    last_update :: integer() % Timestamp of last update
}).

%% Ground station state record
-record(ground_station_state, {
    name :: atom(),
    drones :: list(integer()),
    neighbors :: list(atom()),
    leader :: atom() | undefined,
    is_leader :: boolean(),
    last_heartbeat :: integer(),
    center :: {float(), float()},
    radius :: float(),
    leader_timer :: reference() | undefined,
    monitored_nodes :: list(node())
}).

%% Message types for inter-node communication
-record(drone_update, {
    drone_id :: integer(),
    position :: {float(), float()},
    battery :: integer(),
    status :: atom(),
    timestamp :: integer()
}).

%% Handoff request when drone crosses regions
-record(handoff_request, {
    drone_id :: integer(),
    from_station :: atom(),
    to_station :: atom(),
    drone_state :: #drone_state{},
    timestamp :: integer()
}).