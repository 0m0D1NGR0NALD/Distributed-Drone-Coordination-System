%%% Drone process module
%% Each drone runs as a separate process, manages state, movement, and communication with ground station
-module(drone).
-behaviour(gen_server).

-include("drone_types.hrl").

%% API
-export([start_link/2, start_link/3, stop/1, get_position/1, set_waypoint/2,
         get_status/1, start_mission/1, emergency_land/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%%% API Functions

%% Start a new drone process (without initial state – uses defaults)
start_link(Id, GroundStation) ->
    gen_server:start_link({local, drone_name(Id)}, ?MODULE,
                         [Id, GroundStation, undefined], []).

%% Start a new drone process with a given initial state (used during handoff)
start_link(Id, GroundStation, InitialState) ->
    gen_server:start_link({local, drone_name(Id)}, ?MODULE,
                         [Id, GroundStation, InitialState], []).

%% Stop the drone
stop(DroneId) ->
    gen_server:call(drone_name(DroneId), stop).

%% Get drone's current position
get_position(DroneId) ->
    gen_server:call(drone_name(DroneId), get_position).

%% Set a new waypoint
set_waypoint(DroneId, Waypoint) ->
    gen_server:cast(drone_name(DroneId), {set_waypoint, Waypoint}).

%% Get complete drone status
get_status(DroneId) ->
    gen_server:call(drone_name(DroneId), get_status).

%% Start moving through waypoints
start_mission(DroneId) ->
    gen_server:cast(drone_name(DroneId), start_mission).

%% Emergency landing
emergency_land(DroneId) ->
    gen_server:cast(drone_name(DroneId), emergency_land).

%%% gen_server Callbacks

init([Id, GroundStation, InitialState]) ->
    % Determine initial position, battery, waypoints, status
    {InitPos, InitBattery, InitWaypoints, InitStatus} =
        case InitialState of
            undefined ->
                % Default: station center, full battery, no waypoints, idle
                DefaultPos = case GroundStation of
                    gs1 -> {0.0, 0.0};
                    gs2 -> {100.0, 100.0};
                    _   -> {0.0, 0.0}
                end,
                {DefaultPos, 100, [], idle};
            {Pos, Bat, Waypoints, Status} ->
                {Pos, Bat, Waypoints, Status}
        end,

    % Register with the ground station
    GroundStationPid = whereis(GroundStation),
    if GroundStationPid /= undefined ->
        GroundStationPid ! {drone_ready, self(), Id};
       true ->
        io:format("Warning: Ground station ~p not found~n", [GroundStation])
    end,

    State = #drone_state{
        id = Id,
        ground_station = GroundStation,
        position = InitPos,
        battery = InitBattery,
        waypoints = InitWaypoints,
        status = InitStatus,
        last_update = erlang:system_time(seconds)
    },
    io:format("Drone ~p initialized at ground station ~p at position ~p~n", [Id, GroundStation, InitPos]),
    {ok, State}.

handle_call(get_position, _From, State) ->
    {reply, {ok, State#drone_state.position}, State};

handle_call(get_status, _From, State) ->
    Status = {State#drone_state.id, State#drone_state.position,
              State#drone_state.battery, State#drone_state.status,
              length(State#drone_state.waypoints)},
    {reply, {ok, Status}, State};

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({set_waypoint, Waypoint}, State) ->
    NewWaypoints = State#drone_state.waypoints ++ [Waypoint],
    NewStatus = update_status(State#drone_state.status, NewWaypoints),
    io:format("Drone ~p: waypoint added ~p, queue: ~p~n",
              [State#drone_state.id, Waypoint, NewWaypoints]),
    {noreply, State#drone_state{waypoints = NewWaypoints, status = NewStatus}};

handle_cast(start_mission, State) ->
    % Start periodic movement
    self() ! move_step,
    {noreply, State};

handle_cast(emergency_land, State) ->
    io:format("EMERGENCY: Drone ~p landing immediately~n", [State#drone_state.id]),
    {noreply, State#drone_state{status = emergency, waypoints = []}};

handle_cast(_Msg, State) ->
    {noreply, State}.

handle_info(move_step, State) ->
    % Move one step
    {NewPosition, NewWaypoints, NewStatus} = move_towards_waypoint(State),

    % Decrease battery
    NewBattery = max(0, State#drone_state.battery - 1),

    % Check battery level
    FinalStatus = check_battery(NewBattery, NewStatus),

    % Report position to ground station
    report_to_ground_station(State#drone_state.id, NewPosition,
                            NewBattery, FinalStatus, State#drone_state.ground_station),

    % Schedule next move if still moving
    NewState = State#drone_state{
        position = NewPosition,
        waypoints = NewWaypoints,
        battery = NewBattery,
        status = FinalStatus,
        last_update = erlang:system_time(seconds)
    },

    case FinalStatus of
        emergency ->
            {noreply, NewState};  % Stop moving
        _ when NewWaypoints /= [] ->
            % Schedule next move in 1 second
            erlang:send_after(1000, self(), move_step),
            {noreply, NewState};
        _ ->
            {noreply, NewState}
    end;

handle_info({ground_station_response, Msg}, State) ->
    io:format("Drone ~p received from ground: ~p~n", [State#drone_state.id, Msg]),
    {noreply, State};

handle_info(_Info, State) ->
    {noreply, State}.

terminate(_Reason, _State) ->
    io:format("Drone ~p terminating~n", [_State#drone_state.id]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%% Internal Functions

%% Generate registered name for drone
drone_name(Id) ->
    list_to_atom("drone_" ++ integer_to_list(Id)).

%% Update status based on waypoints
update_status(_Current, []) -> idle;
update_status(_Current, _) -> moving.

%% Move towards first waypoint
move_towards_waypoint(State) ->
    case State#drone_state.waypoints of
        [] ->
            {State#drone_state.position, [], idle};
        [Next | Rest] ->
            {X, Y} = State#drone_state.position,
            {Tx, Ty} = Next,

            Dx = Tx - X,
            Dy = Ty - Y,
            Distance = math:sqrt(Dx*Dx + Dy*Dy),

            if Distance < State#drone_state.speed ->
                % Reached waypoint
                io:format("Drone ~p reached waypoint ~p~n",
                         [State#drone_state.id, Next]),
                {Next, Rest, case Rest of [] -> idle; _ -> moving end};
            true ->
                % Move towards waypoint
                MoveX = X + (Dx / Distance) * State#drone_state.speed,
                MoveY = Y + (Dy / Distance) * State#drone_state.speed,
                {{MoveX, MoveY}, State#drone_state.waypoints, moving}
            end
    end.

%% Check battery level and update status
check_battery(Battery, Status) when Battery < 20, Status /= emergency ->
    low_battery;
check_battery(_, Status) ->
    Status.

%% Report position to ground station - using global registration
report_to_ground_station(DroneId, Position, Battery, Status, GroundStation) ->
    case global:whereis_name(GroundStation) of
        undefined ->
            io:format("Drone ~p: ground station ~p not found globally~n", [DroneId, GroundStation]);
        GSPid ->
            GSPid ! {drone_update, DroneId, Position, Battery, Status}
    end.