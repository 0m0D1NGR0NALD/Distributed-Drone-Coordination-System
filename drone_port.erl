%% erlang/src/drone_port.erl
-module(drone_port).
-export([start/0, start/1, loop/1]).

start() ->
    start(9000).

start(Port) ->
    {ok, ListenSocket} = gen_tcp:listen(Port, [binary, {packet, 4}, {reuseaddr, true}, {active, false}]),
    io:format("***Drone port listening on port ~p~n", [Port]),
    {ok, Socket} = gen_tcp:accept(ListenSocket),
    io:format("🟢 Python client connected~n"),
    loop(Socket).

loop(Socket) ->
    receive
        {tcp, Socket, Data} ->
            % Handle commands from Python
            Command = binary_to_list(Data),
            io:format("Received command: ~s~n", [Command]),
            
            % Parse command and execute
            case string:tokens(Command, ",") of
                ["launch", Station, DroneId] ->
                    % Call ground_station:launch_drone
                    ground_station:launch_drone(list_to_atom(Station), list_to_integer(DroneId)),
                    gen_tcp:send(Socket, "OK");
                    
                ["waypoint", Station, DroneId, X, Y] ->
                    ground_station:set_drone_waypoint(
                        list_to_atom(Station), 
                        list_to_integer(DroneId), 
                        {list_to_float(X), list_to_float(Y)}),
                    gen_tcp:send(Socket, "OK");
                    
                ["transfer", Station, DroneId, Target] ->
                    ground_station:transfer_drone(
                        list_to_atom(Station), 
                        list_to_integer(DroneId), 
                        list_to_atom(Target)),
                    gen_tcp:send(Socket, "OK");
                    
                ["status", Station] ->
                    % Get station status and send back as CSV
                    case ground_station:get_station_status(list_to_atom(Station)) of
                        {ok, {Name, DroneCount, IsLeader, Drones}} ->
                            % Format: "STATUS,Name,DroneCount,IsLeader,DroneList"
                            Response = io_lib:format("STATUS,~s,~p,~p,~p", 
                                                    [Name, DroneCount, IsLeader, length(Drones)]),
                            gen_tcp:send(Socket, list_to_binary(Response));
                        _ ->
                            gen_tcp:send(Socket, "ERROR")
                    end;
                    
                _ ->
                    gen_tcp:send(Socket, "ERROR")
            end,
            loop(Socket);
        
        {tcp_closed, Socket} ->
            io:format("Python client disconnected~n"),
            ok
    end.