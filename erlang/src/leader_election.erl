%%% Leader election for ground stations (bully algorithm)
-module(leader_election).
-export([start_election/1, handle_message/2, is_leader/1, get_leader/0,
         become_leader/1, ping_leader/0]).

%% Start an election from this node
start_election(StationName) ->
    io:format("Starting leader election from ~p~n", [StationName]),
    % Get list of other ground stations (by their globally registered names)
    OtherStations = get_other_ground_stations(StationName),
    HigherStations = get_higher_stations(StationName, OtherStations),

    case HigherStations of
        [] ->
            % No higher stations, we are the leader
            become_leader(StationName);
        _ ->
            % Send election messages to higher stations using global:send
            lists:foreach(fun({OtherName, _OtherNode}) ->
                io:format("Sending election to ~p via global~n", [OtherName]),
                global:send(OtherName, {election, StationName, node()})
            end, HigherStations),

            % Wait for responses
            wait_for_election_response(StationName, length(HigherStations))
    end.

%% Wait for responses from higher stations
wait_for_election_response(StationName, 0) ->
    % No responses, we are the leader
    become_leader(StationName);
wait_for_election_response(StationName, _Waiting) ->
    receive
        {ok, Responder} ->
            io:format("Received OK from ~p, they will handle election~n", [Responder]),
            % Wait for leader announcement
            wait_for_leader_announcement(StationName)
    after 5000 ->
        % Timeout - assume no response, we are leader
        io:format("Election timeout, becoming leader~n"),
        become_leader(StationName)
    end.

%% Wait for leader announcement
wait_for_leader_announcement(StationName) ->
    receive
        {leader, LeaderNode, LeaderName} ->
            io:format("~p: New leader is ~p (~p)~n", [StationName, LeaderName, LeaderNode]),
            % Store leader in process dictionary
            put(leader, {LeaderNode, LeaderName}),
            LeaderName
    after 5000 ->
        % No leader announced, start new election
        io:format("No leader announcement, starting new election~n"),
        start_election(StationName)
    end.

%% Handle election messages
handle_message({election, FromStation, FromNode}, StationName) ->
    io:format("~p received election from ~p (~p)~n", [StationName, FromStation, FromNode]),
    % Respond that we are alive via global:send
    global:send(FromStation, {ok, StationName}),
    % Start our own election (we have higher priority)
    start_election(StationName),
    {ok, election_started};

handle_message({leader, LeaderNode, LeaderName}, StationName) ->
    io:format("~p acknowledges ~p (~p) as leader~n", [StationName, LeaderName, LeaderNode]),
    % Store leader information
    put(leader, {LeaderNode, LeaderName}),
    {ok, LeaderName};

handle_message({are_you_alive, _FromNode, FromStation}, StationName) ->
    % Leader checking if we're alive
    io:format("~p received alive check from leader ~p~n", [StationName, FromStation]),
    global:send(FromStation, {alive, StationName}),
    {ok, alive_response};

handle_message(_Msg, _StationName) ->
    unknown.

%% Check if this node is the leader
is_leader(StationName) ->
    case get(leader) of
        undefined ->
            % No leader known, check if we're the highest priority among known ground stations
            Stations = get_all_ground_stations(),
            % Extract just station names
            StationNames = [Name || {Name, _} <- Stations],
            case StationNames of
                [] -> false;
                _ ->
                    Highest = hd(lists:sort(StationNames)),
                    Highest == StationName
            end;
        {LeaderNode, LeaderName} ->
            LeaderName == StationName andalso LeaderNode == node()
    end.

%% Get current leader
get_leader() ->
    case get(leader) of
        undefined ->
            {unknown, unknown};
        {LeaderNode, LeaderName} ->
            {LeaderNode, LeaderName}
    end.

%% Become the leader
become_leader(StationName) ->
    io:format("*** ~p BECOMES LEADER ***~n", [StationName]),
    % Store in process dictionary
    put(leader, {node(), StationName}),

    % Announce to all other ground stations using global:send
    OtherStations = get_other_ground_stations(StationName),
    lists:foreach(fun({OtherName, _OtherNode}) ->
        io:format("Announcing leadership to ~p via global~n", [OtherName]),
        global:send(OtherName, {leader, node(), StationName})
    end, OtherStations),

    % Announce to ourselves so our ground station updates its state
    global:send(StationName, {leader, node(), StationName}),

    % Start heartbeat as leader
    erlang:send_after(5000, self(), leader_heartbeat),
    StationName.

%% Ping the leader to check if alive
ping_leader() ->
    case get(leader) of
        undefined ->
            io:format("No leader known~n"),
            {error, no_leader};
        {LeaderNode, LeaderName} ->
            io:format("Pinging leader ~p at ~p~n", [LeaderName, LeaderNode]),
            global:send(LeaderName, {are_you_alive, node(), LeaderName}),

            % Wait for response
            receive
                {alive, LeaderName} ->
                    io:format("Leader is alive~n"),
                    ok
            after 3000 ->
                io:format("Leader not responding, starting election~n"),
                start_election(LeaderName)
            end
    end.

%%% Internal Functions

%% Get all ground stations (excluding the port process)
%% Returns list of {StationName, Node} where the station is globally registered.
get_all_ground_stations() ->
    AllNames = global:registered_names(),
    % Filter names that look like ground stations (gs1, gs2, etc.) and not the port process
    lists:foldl(fun(Name, Acc) ->
        case is_ground_station_name(Name) of
            true ->
                case global:whereis_name(Name) of
                    undefined -> Acc;
                    Pid -> [{Name, node(Pid)} | Acc]
                end;
            false -> Acc
        end
    end, [], AllNames).

%% Get other ground stations (excluding ourselves)
get_other_ground_stations(MyName) ->
    All = get_all_ground_stations(),
    lists:filter(fun({Name, _Node}) -> Name /= MyName end, All).

%% Filter names that are likely ground stations (gs1, gs2, ...)
is_ground_station_name(Name) when is_atom(Name) ->
    case atom_to_list(Name) of
        "gs" ++ Rest ->
            % Check if the rest is a number
            lists:all(fun(C) -> C >= $0 andalso C =< $9 end, Rest);
        _ -> false
    end;
is_ground_station_name(_) -> false.

%% Get stations with higher priority (by station name lexicographically)
get_higher_stations(MyName, OtherStations) ->
    MyNameStr = atom_to_list(MyName),
    lists:filter(fun({Name, _Node}) ->
        atom_to_list(Name) > MyNameStr
    end, OtherStations).