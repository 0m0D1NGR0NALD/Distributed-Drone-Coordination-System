%% drone_port_broadcast.erl
-module(drone_port_broadcast).
-export([start/0, start/1, start_link/0, start_link/1, loop/1, init/1]).
-export([broadcast/5]).

-record(state, {clients=[], listen_socket}).

start() ->
    start(9000).

start(Port) ->
    spawn(fun() -> init(Port) end).

start_link() ->
    start_link(9000).

start_link(Port) ->
    spawn_link(fun() -> init(Port) end).

init(Port) ->
    {ok, ListenSocket} = gen_tcp:listen(Port, [binary, {packet, 4}, {reuseaddr, true}, {active, false}]),
    io:format("🟢 Drone port listening on port ~p (background)~n", [Port]),

    % Register this process globally
    register(?MODULE, self()),
    global:register_name(?MODULE, self()),

    % Start client connection acceptor
    spawn(fun() -> accept_clients(ListenSocket) end),

    % Keep the process alive with state
    loop(#state{clients=[], listen_socket=ListenSocket}).

accept_clients(ListenSocket) ->
    case gen_tcp:accept(ListenSocket) of
        {ok, Socket} ->
            io:format("🟢 Python client connected~n"),
            % Send initial connection confirmation
            gen_tcp:send(Socket, "CONNECTED"),
            % Add this socket to the broadcast list
            Pid = whereis(?MODULE),
            if Pid /= undefined ->
                Pid ! {add_client, Socket};
            true ->
                ok
            end,
            % Start a new acceptor for further clients
            spawn(fun() -> accept_clients(ListenSocket) end),
            % Handle this client's commands
            handle_client(Socket, Pid);
        {error, closed} ->
            io:format("🔴 Listening socket closed, stopping acceptor~n"),
            ok;  % exit gracefully
        {error, Reason} ->
            io:format("🔴 Accept error: ~p, restarting acceptor~n", [Reason]),
            % Restart acceptor after a short delay
            timer:sleep(1000),
            accept_clients(ListenSocket)
    end.

handle_client(Socket, MainPid) ->
    % Enable active mode for one message
    inet:setopts(Socket, [{active, once}]),
    receive
        {tcp, Socket, Data} ->
            io:format("Port received raw data: ~p~n", [Data]),
            Command = binary_to_list(Data),
            io:format("Port received command: ~s~n", [Command]),

            % Parse command and execute
            Result = case string:tokens(Command, ",") of
                ["launch", Station, DroneId] ->
                    io:format("   Parsed as launch: ~p ~p~n", [Station, DroneId]),
                    Node = list_to_atom(Station ++ "@A06A"),
                    RpcResult = rpc:call(Node, ground_station, launch_drone,
                                          [list_to_atom(Station), list_to_integer(DroneId)]),
                    io:format("   RPC result: ~p~n", [RpcResult]),
                    case RpcResult of
                        {ok, _} -> "OK";
                        _ -> "ERROR"
                    end;

                ["waypoint", Station, DroneId, X, Y] ->
                    io:format("   Parsed as waypoint: ~p ~p ~p ~p~n", [Station, DroneId, X, Y]),
                    Node = list_to_atom(Station ++ "@A06A"),
                    RpcResult = rpc:call(Node, ground_station, set_drone_waypoint,
                                          [list_to_atom(Station), list_to_integer(DroneId),
                                           {list_to_float(X), list_to_float(Y)}]),
                    io:format("   RPC result: ~p~n", [RpcResult]),
                    case RpcResult of
                        ok -> "OK";
                        _ -> "ERROR"
                    end;

                ["transfer", Station, DroneId, Target] ->
                    io:format("   Parsed as transfer: ~p ~p ~p~n", [Station, DroneId, Target]),
                    Node = list_to_atom(Station ++ "@A06A"),
                    RpcResult = rpc:call(Node, ground_station, transfer_drone,
                                          [list_to_atom(Station), list_to_integer(DroneId),
                                           list_to_atom(Target)]),
                    io:format("   RPC result: ~p~n", [RpcResult]),
                    case RpcResult of
                        {ok, _} -> "OK";
                        _ -> "ERROR"
                    end;

                ["status", Station] ->
                    io:format("   Parsed as status: ~p~n", [Station]),
                    Node = list_to_atom(Station ++ "@A06A"),
                    StatusResult = rpc:call(Node, ground_station, get_status, [list_to_atom(Station)]),
                    io:format("   Status result: ~p~n", [StatusResult]),
                    case StatusResult of
                        {ok, {_Name, DroneCount, IsLeader, DroneList}} ->
                            % Format: "STATUS,Station,DroneCount,IsLeader,DroneId1,DroneId2,..."
                            DroneIds = [integer_to_list(Id) || {Id, _, _, _, _} <- DroneList],
                            string:join(["STATUS", atom_to_list(Station),
                                         integer_to_list(DroneCount),
                                         atom_to_list(IsLeader) | DroneIds], ",");
                        _ ->
                            "ERROR"
                    end;

                _ ->
                    io:format("   Unknown command: ~p~n", [Command]),
                    "ERROR"
            end,
            % Send the response back to Python
            gen_tcp:send(Socket, Result),
            % Re‑arm for next message
            inet:setopts(Socket, [{active, once}]),
            handle_client(Socket, MainPid);

        {tcp_closed, Socket} ->
            io:format("🔴 Python client disconnected~n"),
            if MainPid /= undefined ->
                MainPid ! {remove_client, Socket};
            true ->
                ok
            end,
            ok;

        {tcp_error, Socket, Reason} ->
            io:format("🔴 TCP error on socket ~p: ~p~n", [Socket, Reason]),
            if MainPid /= undefined ->
                MainPid ! {remove_client, Socket};
            true ->
                ok
            end,
            ok
    end.

loop(State) ->
    receive
        {add_client, Socket} ->
            NewClients = [Socket | State#state.clients],
            io:format("Client added. Total clients: ~p~n", [length(NewClients)]),
            loop(State#state{clients = NewClients});

        {remove_client, Socket} ->
            NewClients = lists:delete(Socket, State#state.clients),
            io:format("Client removed. Total clients: ~p~n", [length(NewClients)]),
            loop(State#state{clients = NewClients});

        {broadcast, DroneId, X, Y, Battery, Status} ->
            % Convert X and Y to floats to avoid formatting errors
            XFloat = if is_integer(X) -> X * 1.0; is_float(X) -> X; true -> 0.0 end,
            YFloat = if is_integer(Y) -> Y * 1.0; is_float(Y) -> Y; true -> 0.0 end,
            Message = io_lib:format("~p,~.1f,~.1f,~p,~s", [DroneId, XFloat, YFloat, Battery, Status]),
            FlatMessage = lists:flatten(Message),
            io:format("Broadcasting: ~s to ~p clients~n", [FlatMessage, length(State#state.clients)]),

            % Send to all connected clients
            lists:foreach(fun(Socket) ->
                try
                    gen_tcp:send(Socket, FlatMessage)
                catch
                    _:_ -> ok  % Ignore errors for disconnected clients
                end
            end, State#state.clients),

            loop(State);

        stop ->
            ok;

        _ ->
            loop(State)
    end.

%% Helper function for testing
broadcast(DroneId, X, Y, Battery, Status) ->
    case global:whereis_name(?MODULE) of
        undefined ->
            io:format("Port process not found~n");
        Pid ->
            Pid ! {broadcast, DroneId, X, Y, Battery, Status}
    end.