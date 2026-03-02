%%% Ground Station - manages drones and communicates with other stations
-module(ground_station).
-behaviour(gen_server).

-include("drone_types.hrl").

%% API
-export([start_link/1, stop/1, launch_drone/2, get_drone_position/2,
         set_drone_waypoint/3, get_station_status/1, transfer_drone/3,
         add_neighbor/2, start_election/1, get_leader/1]).

%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
         terminate/2, code_change/3]).

%%% API Functions

start_link(StationName) ->
    % Register with the station's own name (gs1, gs2, ...)
    case gen_server:start_link({local, StationName}, ?MODULE, [StationName], []) of
        {ok, Pid} ->
            % Also register globally
            global:register_name(StationName, Pid),
            {ok, Pid};
        Error ->
            Error
    end.

stop(StationName) ->
    gen_server:call(StationName, stop).

launch_drone(StationName, DroneId) ->
    gen_server:call(StationName, {launch_drone, DroneId}).

get_drone_position(StationName, DroneId) ->
    gen_server:call(StationName, {get_drone_position, DroneId}).

% Manually add a neighbor station
add_neighbor(StationName, NeighborStation) ->
    gen_server:cast(StationName, {add_neighbor, NeighborStation}).

set_drone_waypoint(StationName, DroneId, Waypoint) ->
    gen_server:cast(StationName, {set_drone_waypoint, DroneId, Waypoint}).

get_station_status(StationName) ->
    gen_server:call(StationName, get_status).

transfer_drone(StationName, DroneId, TargetStation) ->
    gen_server:call(StationName, {transfer_drone, DroneId, TargetStation}).

%% Start leader election
start_election(StationName) ->
    gen_server:call(StationName, start_election, 10000).

%% Get current leader
get_leader(StationName) ->
    gen_server:call(StationName, get_leader).

%%% gen_server Callbacks

init([StationName]) ->
    % Register with node communicator for inter-station communication
    % Use a different name to avoid conflict
    CommName = atom_to_list(StationName) ++ "_comm",
    node_communicator:start_background(CommName),

    % Define center and radius based on station
    {Center, Radius} = case StationName of
        gs1 -> {{0.0, 0.0}, 90.0};      % center at (0,0), radius 90
        gs2 -> {{100.0, 100.0}, 90.0};  % center at (100,100), radius 90
        _   -> {{0.0, 0.0}, 90.0}       % fallback
    end,
    
    % Initial state without leader timer
    State0 = #ground_station_state{
        name = StationName,
        drones = [],
        neighbors = discover_neighbors(),
        leader = undefined,
        is_leader = false,
        last_heartbeat = erlang:system_time(seconds),
        center = Center,
        radius = Radius
    },
   
    % Start heartbeat timer
    erlang:send_after(30000, self(), send_heartbeat),
    
    % Register globally so other nodes can find this process by name
    case global:register_name(StationName, self()) of
        yes ->
            io:format("Ground Station ~p started on node ~p and registered globally~n", 
                     [StationName, node()]);
        no ->
            io:format("Ground Station ~p started on node ~p but name already exists globally!~n", 
                     [StationName, node()])
    end,
    
    % Start a timer to detect leader failure if we have a known leader
    LeaderTimer = case State0#ground_station_state.leader of
        undefined -> undefined;
        _ -> erlang:send_after(90000, self(), leader_heartbeat_timeout)  % 3 * heartbeat interval
    end,
    State = State0#ground_station_state{leader_timer = LeaderTimer, monitored_nodes = []},
    {ok, State}.

handle_call({launch_drone, DroneId}, _From, State) ->
    % Start a new drone process
    case lists:member(DroneId, State#ground_station_state.drones) of
        true ->
            {reply, {error, already_exists}, State};
        false ->
            % Start drone with ground station reference
            {ok, DronePid} = drone:start_link(DroneId, State#ground_station_state.name),
            NewDrones = [DroneId | State#ground_station_state.drones],
            io:format("Launched drone ~p from station ~p~n", 
                     [DroneId, State#ground_station_state.name]),
            {reply, {ok, DronePid}, State#ground_station_state{drones = NewDrones}}
    end;

handle_call({get_drone_position, DroneId}, _From, State) ->
    case lists:member(DroneId, State#ground_station_state.drones) of
        true ->
            case drone:get_position(DroneId) of
                {ok, Position} -> {reply, {ok, Position}, State};
                Error -> {reply, Error, State}
            end;
        false ->
            {reply, {error, not_found}, State}
    end;

handle_call({transfer_drone, DroneId, TargetStation}, _From, State) ->
    io:format("Initiating transfer of drone ~p to ~p~n", [DroneId, TargetStation]),
    case whereis(drone_name(DroneId)) of
        undefined ->
            {reply, {error, drone_not_found}, State};
        _ ->
            case drone:get_status(DroneId) of
                {ok, Status} ->
                    case get_global_pid(TargetStation) of
                        undefined ->
                            io:format("Target station ~p not found~n", [TargetStation]),
                            {reply, {error, target_not_found}, State};
                        TargetPid ->
                            HandoffMsg = {handoff_request, DroneId, State#ground_station_state.name, 
                                          TargetStation, Status},
                            TargetPid ! HandoffMsg,
                            {reply, {ok, transferring}, State}
                    end;
                Error ->
                    {reply, Error, State}
            end
    end;

handle_call(get_status, _From, State) ->
    % Get status of all drones
    DroneStatus = lists:map(fun(Id) ->
        case drone:get_status(Id) of
            {ok, Status} -> Status;
            _ -> {Id, unknown}
        end
    end, State#ground_station_state.drones),
    
    Status = {State#ground_station_state.name, 
              length(State#ground_station_state.drones),
              State#ground_station_state.is_leader,
              DroneStatus},
    {reply, {ok, Status}, State};

handle_call(start_election, _From, State) ->
    % Start leader election
    io:format("Ground station ~p initiating leader election~n", [State#ground_station_state.name]),
    case leader_election:start_election(State#ground_station_state.name) of
        Leader when is_atom(Leader) ->
            NewState = State#ground_station_state{
                leader = Leader,
                is_leader = (Leader == State#ground_station_state.name)
            },
            {reply, {ok, Leader}, NewState};
        Other ->
            {reply, {error, Other}, State}
    end;

handle_call(get_leader, _From, State) ->
    {reply, {ok, State#ground_station_state.leader}, State};

handle_call(stop, _From, State) ->
    {stop, normal, ok, State};

handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

handle_cast({set_drone_waypoint, DroneId, Waypoint}, State) ->
    case lists:member(DroneId, State#ground_station_state.drones) of
        true ->
            drone:set_waypoint(DroneId, Waypoint),
            drone:start_mission(DroneId);
        false ->
            io:format("Drone ~p not found at station ~p~n", 
                     [DroneId, State#ground_station_state.name])
    end,
    {noreply, State};

handle_cast({add_neighbor, NeighborStation}, State) ->
    % Convert station name to full node name
    NeighborNode = list_to_atom(atom_to_list(NeighborStation) ++ "@A06A"),
    NewNeighbors = lists:usort([NeighborNode | State#ground_station_state.neighbors]),
    io:format("Added neighbor ~p (~p). Neighbors now: ~p~n", 
              [NeighborStation, NeighborNode, NewNeighbors]),
    
    % Monitor the neighbor node if not already monitored
    Monitored = State#ground_station_state.monitored_nodes,
    NewMonitored = case lists:member(NeighborNode, Monitored) of
        true -> Monitored;
        false ->
            erlang:monitor_node(NeighborNode, true),
            [NeighborNode | Monitored]
    end,
    
    {noreply, State#ground_station_state{
        neighbors = NewNeighbors,
        monitored_nodes = NewMonitored
    }};

handle_cast(_Msg, State) ->
    {noreply, State}.

% Handle direct handoff requests (sent via global:send or PID messaging)
handle_info({handoff_request, DroneId, FromStation, TargetStation, DroneState}, State) ->
    io:format("🟢 HANDOFF REQUEST RECEIVED on ~p~n", [State#ground_station_state.name]),
    io:format("DroneId: ~p, From: ~p, Target: ~p~n", [DroneId, FromStation, TargetStation]),
    
    if TargetStation == State#ground_station_state.name ->
        io:format("TARGET MATCH! Accepting handoff~n"),
        
        % Check if drone already exists
        case whereis(drone_name(DroneId)) of
            undefined ->
                % Extract drone state
                {_, Position, Battery, Status, WaypointCount} = DroneState,
                io:format("  Restoring drone: pos=~p, bat=~p%, status=~p, waypoints=~p~n", 
                          [Position, Battery, Status, WaypointCount]),
                % Start the drone with preserved state (position, battery, empty waypoints, status)
                InitialState = {Position, Battery, [], Status},
                {ok, _DronePid} = drone:start_link(DroneId, State#ground_station_state.name, InitialState);
            ExistingPid ->
                io:format("⚠️ Drone ~p already exists with PID ~p, reusing~n", [DroneId, ExistingPid])
        end,
        
        NewDrones = [DroneId | State#ground_station_state.drones],
        
        % Send acknowledgement back via global
        io:format("Sending handoff_ack to ~p via global~n", [FromStation]),
        global:send(FromStation, {handoff_ack, DroneId, State#ground_station_state.name}),
        
        io:format("Handoff complete for drone ~p~n", [DroneId]),
        {noreply, State#ground_station_state{drones = NewDrones}};
    true ->
        io:format("Not target (me=~p, target=~p)~n", 
                  [State#ground_station_state.name, TargetStation]),
        {noreply, State}
    end;

% Handle handoff requests that come through node_communicator (wrapped)
handle_info({message, _FromPid, {handoff_request, DroneId, FromStation, TargetStation, DroneState}}, State) ->
    io:format("🟢 HANDOFF REQUEST RECEIVED (via message) on ~p~n", [State#ground_station_state.name]),
    io:format("DroneId: ~p, From: ~p, Target: ~p~n", [DroneId, FromStation, TargetStation]),
    
    if TargetStation == State#ground_station_state.name ->
        io:format("TARGET MATCH! Accepting handoff~n"),
        
        case whereis(drone_name(DroneId)) of
            undefined ->
                {_, Position, Battery, Status, WaypointCount} = DroneState,
                io:format("  Restoring drone: pos=~p, bat=~p%, status=~p, waypoints=~p~n", 
                          [Position, Battery, Status, WaypointCount]),
                InitialState = {Position, Battery, [], Status},
                {ok, _DronePid} = drone:start_link(DroneId, State#ground_station_state.name, InitialState);
            ExistingPid ->
                io:format("⚠️ Drone ~p already exists with PID ~p, reusing~n", [DroneId, ExistingPid])
        end,
        
        NewDrones = [DroneId | State#ground_station_state.drones],
        
        io:format("Sending handoff_ack to ~p via global~n", [FromStation]),
        global:send(FromStation, {handoff_ack, DroneId, State#ground_station_state.name}),
        
        io:format("Handoff complete for drone ~p~n", [DroneId]),
        {noreply, State#ground_station_state{drones = NewDrones}};
    true ->
        io:format("Not target (me=~p, target=~p)~n", 
                  [State#ground_station_state.name, TargetStation]),
        {noreply, State}
    end;

% Handle handoff initiation (when drone crosses boundary)
handle_info({initiate_handoff, DroneId, TargetStation}, State) ->
    io:format("Initiating handoff for drone ~p to ~p~n", [DroneId, TargetStation]),
    
    % Get drone status
    case drone:get_status(DroneId) of
        {ok, Status} ->
            % Get target station's PID via global
            case global:whereis_name(TargetStation) of
                undefined ->
                    io:format("Target station ~p not found~n", [TargetStation]);
                TargetPid ->
                    % Send handoff request directly
                    HandoffMsg = {handoff_request, DroneId, State#ground_station_state.name, 
                                  TargetStation, Status},
                    TargetPid ! HandoffMsg,
                    io:format("Handoff request sent for drone ~p~n", [DroneId])
            end;
        Error ->
            io:format("Failed to get status for drone ~p: ~p~n", [DroneId, Error])
    end,
    {noreply, State};

% Handle handoff acknowledgements (direct)
handle_info({handoff_ack, DroneId, FromStation}, State) ->
    io:format("🟢 HANDOFF COMPLETE: Drone ~p transferred to ~p ***~n", [DroneId, FromStation]),
    
    % Stop the drone process
    case whereis(drone_name(DroneId)) of
        undefined ->
            io:format("Drone ~p process already terminated~n", [DroneId]);
        DronePid ->
            % Use the PID to stop the drone
            io:format("Terminating drone ~p process (PID: ~p)~n", [DroneId, DronePid]),
            % Try to stop gracefully, then kill if needed
            try
                drone:stop(DroneId)
            catch
                _:_ -> exit(DronePid, kill)
            end
    end,
    
    % Remove from our list
    NewDrones = lists:delete(DroneId, State#ground_station_state.drones),
    {noreply, State#ground_station_state{drones = NewDrones}};

% Handle handoff acknowledgements (via message wrapper)
handle_info({message, _FromPid, {handoff_ack, DroneId, FromStation}}, State) ->
    io:format("🟢 HANDOFF ACK (via message) RECEIVED: Drone ~p transferred to ~p ***~n", [DroneId, FromStation]),
    
    % Stop the drone process
    case whereis(drone_name(DroneId)) of
        undefined ->
            io:format("Drone ~p process already terminated~n", [DroneId]);
        DronePid ->
            io:format("Terminating drone ~p process (PID: ~p)~n", [DroneId, DronePid]),
            try
                drone:stop(DroneId)
            catch
                _:_ -> exit(DronePid, kill)
            end
    end,
    
    % Remove from our list
    NewDrones = lists:delete(DroneId, State#ground_station_state.drones),
    {noreply, State#ground_station_state{drones = NewDrones}};

% Handle election messages
handle_info({election, FromStation, FromNode}, State) ->
    io:format("Received election from ~p (~p)~n", [FromStation, FromNode]),
    leader_election:handle_message({election, FromStation, FromNode}, State#ground_station_state.name),
    {noreply, State};

handle_info({leader, LeaderNode, LeaderName}, State) ->
    io:format("Received leader announcement: ~p (~p)~n", [LeaderName, LeaderNode]),
    leader_election:handle_message({leader, LeaderNode, LeaderName}, State#ground_station_state.name),
    % NEW: When receiving a leader announcement, clear any existing timer.
    % If we are not the leader, we will set a new timer when we receive heartbeats.
    % But we also need to cancel the old timer.
    case State#ground_station_state.leader_timer of
        undefined -> ok;
        TRef -> erlang:cancel_timer(TRef)
    end,
    NewState = State#ground_station_state{
        leader = LeaderName,
        is_leader = (LeaderName == State#ground_station_state.name),
        leader_timer = undefined   % timer will be restarted on next heartbeat
    },
    {noreply, NewState};

handle_info({are_you_alive, FromNode, FromStation}, State) ->
    io:format("Received alive check from ~p (~p)~n", [FromStation, FromNode]),
    leader_election:handle_message({are_you_alive, FromNode, FromStation}, State#ground_station_state.name),
    {noreply, State};

handle_info(send_heartbeat, State) ->
    % Broadcast heartbeat to other stations using global registration
    lists:foreach(fun(NeighborNode) ->
        % Extract station name from node name
        NodeStr = atom_to_list(NeighborNode),
        StationName = case string:split(NodeStr, "@") of
            [Name, _Host] -> list_to_atom(Name);
            _ -> NeighborNode
        end,
        % Send heartbeat, but ignore errors if target not registered
        try
            global:send(StationName, {heartbeat, State#ground_station_state.name})
        catch
            _:_ -> ok
        end
    end, State#ground_station_state.neighbors),

    erlang:send_after(30000, self(), send_heartbeat),
    {noreply, State};
    
handle_info({heartbeat, FromStation}, State) ->
    % Update neighbor list with the station name
    NewNeighbors = lists:usort([FromStation | State#ground_station_state.neighbors]),
    {noreply, State#ground_station_state{neighbors = NewNeighbors}};

% NEW: Handler for leader heartbeats (with leader flag)
handle_info({heartbeat, FromStation, leader}, State) ->
    io:format("Received leader heartbeat from ~p~n", [FromStation]),
    % Cancel any existing leader timer and start a new one
    case State#ground_station_state.leader_timer of
        undefined -> ok;
        TRef -> erlang:cancel_timer(TRef)
    end,
    NewTimer = erlang:send_after(90000, self(), leader_heartbeat_timeout),
    NewState = State#ground_station_state{
        leader = FromStation,
        leader_timer = NewTimer
    },
    {noreply, NewState};

handle_info(leader_heartbeat, State) when State#ground_station_state.is_leader ->
    io:format("Leader ~p sending heartbeat to followers~n", [State#ground_station_state.name]),
    lists:foreach(fun(NeighborNode) ->
        NodeStr = atom_to_list(NeighborNode),
        StationName = case string:split(NodeStr, "@") of
            [Name, _Host] -> list_to_atom(Name);
            _ -> NeighborNode
        end,
        try
            global:send(StationName, {heartbeat, State#ground_station_state.name, leader})
        catch
            _:_ -> ok
        end
    end, State#ground_station_state.neighbors),

    erlang:send_after(30000, self(), leader_heartbeat),
    {noreply, State};

% NEW: Leader heartbeat timeout – leader is considered dead, start election
handle_info(leader_heartbeat_timeout, State) ->
    io:format("Leader heartbeat timeout – starting election~n"),
    % Start election in a separate process to avoid blocking
    spawn(fun() -> leader_election:start_election(State#ground_station_state.name) end),
    {noreply, State#ground_station_state{leader_timer = undefined}};

handle_info({drone_update, DroneId, Position, Battery, Status}, State) ->
    % Process drone telemetry – FIXED: convert coordinates to floats for formatting
    io:format("Station ~p: Drone ~p at (~.1f,~.1f), battery ~p%, status ~p~n",
              [State#ground_station_state.name, DroneId,
               float(element(1, Position)), float(element(2, Position)),
               Battery, Status]),
    
    % Debug: show forwarding attempt
    io:format("Attempting to forward drone ~p to port (PID: ~p)~n",
              [DroneId, global:whereis_name(drone_port_broadcast)]),
    
    % Extract coordinates for forwarding
    {X, Y} = Position,
    
    % Try to send to port process - use global lookup
    case global:whereis_name(drone_port_broadcast) of
        undefined ->
            % Port not registered globally - ignore
            ok;
        PortPid ->
            % Send broadcast message to port
            PortPid ! {broadcast, DroneId, X, Y, Battery, Status}
    end,
    
    % Check if drone needs to be handed off
    NewState = check_boundary_crossing(DroneId, Position, State),
    {noreply, NewState};

% Handle node down events
handle_info({nodedown, Node}, State) ->
    io:format("Node ~p went down – removing from neighbors~n", [Node]),
    % Remove any neighbor entries that are this node
    NewNeighbors = lists:filter(fun(N) -> N /= Node end, 
                                State#ground_station_state.neighbors),
    % Remove node from monitored list (no need to demonitor, it's automatic)
    NewMonitored = lists:delete(Node, State#ground_station_state.monitored_nodes),
    {noreply, State#ground_station_state{
        neighbors = NewNeighbors,
        monitored_nodes = NewMonitored
    }};

% Catch-all for debugging
handle_info(Msg, State) ->
    io:format("SUCCESSFUL CONNECTION: ~p~n", [Msg]),
    {noreply, State}.

terminate(_Reason, _State) ->
    io:format("Ground Station ~p stopping~n", [_State#ground_station_state.name]),
    ok.

code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%% Internal Functions

%% Helper to get global PID of another station
get_global_pid(StationName) ->
    case global:whereis_name(StationName) of
        undefined ->
            io:format("Station ~p not found globally~n", [StationName]),
            undefined;
        Pid ->
            Pid
    end.

%% Helper to get drone registered name
drone_name(DroneId) ->
    list_to_atom("drone_" ++ integer_to_list(DroneId)).

%% Discover neighbor ground stations
discover_neighbors() ->
    % Find other ground stations in the cluster - these are already full node names
    OtherNodes = nodes() -- [node()],
    OtherNodes.

%% Check if drone crosses outside this station's circular region
check_boundary_crossing(DroneId, {X, Y}, State) ->
    #ground_station_state{center = {Cx, Cy}, radius = R, neighbors = Neighbors} = State,
    % Compute Euclidean distance from center
    Dx = X - Cx,
    Dy = Y - Cy,
    Distance = math:sqrt(Dx*Dx + Dy*Dy),
    % Convert to floats for safe formatting
    Xf = float(X),
    Yf = float(Y),
    Df = float(Distance),
    Rf = float(R),
    io:format("BOUNDARY CHECK: Drone ~p at (~.1f,~.1f), distance from center = ~.1f (radius ~.1f)~n",
              [DroneId, Xf, Yf, Df, Rf]),
    
    if Distance > R ->
        case Neighbors of
            [] ->
                io:format("🔴 Drone outside region but no neighbors to hand off to ~n"),
                State;
            [Neighbor|_] ->
                io:format("🟢 Drone ~p outside region, handing off to ~p~n", [DroneId, Neighbor]),
                self() ! {initiate_handoff, DroneId, Neighbor}
        end;
    true ->
        ok
    end,
    State.