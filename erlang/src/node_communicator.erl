%% This module allows nodes to send and receive messages with non-blocking background operation
-module(node_communicator).
-include("drone_types.hrl").
-export([start/0, start/1, start_background/1, send_message/2, 
         receive_messages/0, node_info/0, stop/0, is_running/0, 
         send_message_to/3, stop/1, is_running/1]).

%% API Functions

% Start the communicator with default node name
start() ->
    start("anon").

% Start the communicator with a given node name (blocks shell)
start(NodeName) ->
    % Register this process so other nodes can find it
    register(list_to_atom(NodeName), self()),
    io:format("~s started with PID: ~p~n", [NodeName, self()]),
    io:format("This node is: ~p~n", [node()]),
    io:format("*** Shell is now in receive loop. Press Ctrl+G then 'c' to break. ***~n", []),
    % Start the message receiving loop (this will block)
    receive_messages().

% Start the communicator in the background (does NOT block shell)
start_background(NodeName) ->
    % Spawn a new process for the receiver
    Pid = spawn(fun() -> init_background(NodeName) end),
    % Give it a moment to register
    timer:sleep(100),
    io:format("~s started in BACKGROUND with PID: ~p~n", [NodeName, Pid]),
    io:format("This node is: ~p~n", [node()]),
    io:format("Use node_communicator:is_running(). to check status~n", []),
    Pid.

% Initialize the background process
init_background(NodeName) ->
    % Register with the given name
    case catch register(list_to_atom(NodeName), self()) of
        {'EXIT', {badarg, _}} ->
            io:format("Error: Name ~s is already in use~n", [NodeName]);
        _ ->
            io:format("[Background ~s] Ready and waiting for messages~n", [NodeName]),
            receive_messages()
    end.

% Send a message to another node using the dynamic registered name
send_message(Message, TargetNode) when is_atom(TargetNode) ->
    % Check if the target node is alive
    case net_adm:ping(TargetNode) of
        pong ->
            % Instead of hardcoding 'node_communicator', we need to know what name
            % the target node registered. By convention, we'll try 'receiver' first
            % since that's what we use in start_background/1
            RegisteredName = receiver,
            {RegisteredName, TargetNode} ! {message, self(), Message},
            io:format("Message sent to ~p@~p: ~s~n", [RegisteredName, TargetNode, Message]),
            {ok, sent};
        pang ->
            io:format("Node ~p is unreachable~n", [TargetNode]),
            {error, unreachable}
    end;
send_message(Message, TargetNodeName) when is_list(TargetNodeName) ->
    % Convert string node name to atom and call the atom version
    TargetNode = list_to_atom(TargetNodeName),
    send_message(Message, TargetNode).

% Send a message to a specific registered process on another node
send_message_to(Message, TargetNode, RegisteredName) when is_atom(TargetNode), is_atom(RegisteredName) ->
    case net_adm:ping(TargetNode) of
        pong ->
            {RegisteredName, TargetNode} ! {message, self(), Message},
            % Fix the formatting - TargetNode is already the full node name
            io:format("Message sent to ~p @ ~p: ~p~n", [RegisteredName, TargetNode, Message]),
            {ok, sent};
        pang ->
            io:format("Node ~p is unreachable~n", [TargetNode]),
            {error, unreachable}
    end;
send_message_to(Message, TargetNodeName, RegisteredName) when is_list(TargetNodeName), is_atom(RegisteredName) ->
    TargetNode = list_to_atom(TargetNodeName),
    send_message_to(Message, TargetNode, RegisteredName);
send_message_to(Message, TargetNode, RegisteredName) when is_atom(TargetNode), is_list(RegisteredName) ->
    send_message_to(Message, TargetNode, list_to_atom(RegisteredName));
send_message_to(Message, TargetNodeName, RegisteredName) when is_list(TargetNodeName), is_list(RegisteredName) ->
    TargetNode = list_to_atom(TargetNodeName),
    send_message_to(Message, TargetNode, list_to_atom(RegisteredName)).

% Receive and process messages (called internally)
receive_messages() ->
    receive
        {message, From, Content} ->
            io:format("[~p] Received from ~p: ~s~n", 
                      [self(), From, Content]),
            % Acknowledge receipt
            From ! {ack, self(), "Message received: " ++ Content},
            receive_messages();
            
        {ack, From, Content} ->
            io:format("[~p] Acknowledgement from ~p: ~s~n", 
                      [self(), From, Content]),
            receive_messages();
            
        {broadcast, From, Content} ->
            io:format("[~p] Broadcast from ~p: ~s~n", 
                      [self(), From, Content]),
            receive_messages();
            
        {status_request, From} ->
            From ! {status_response, self(), node(), erlang:time()},
            io:format("[~p] Status request from ~p~n", [self(), From]),
            receive_messages();
            
        {ping, From} ->
            From ! {pong, self()},
            io:format("[~p] Ping from ~p, sent pong~n", [self(), From]),
            receive_messages();
            
        stop ->
            io:format("Stopping communicator on ~p~n", [node()]),
            ok;
            
        Unknown ->
            io:format("[~p] Unknown message: ~p~n", [self(), Unknown]),
            receive_messages()
    end.

% Stop a background communicator (default name)
stop() ->
    stop("receiver").

% Stop a specific named communicator
stop(Name) when is_list(Name) ->
    case whereis(list_to_atom(Name)) of
        undefined ->
            io:format("No process named ~s found~n", [Name]);
        Pid ->
            Pid ! stop,
            io:format("Stop signal sent to ~p~n", [Pid])
    end;
stop(Name) when is_atom(Name) ->
    stop(atom_to_list(Name)).

% Check if a communicator is running (default name)
is_running() ->
    is_running("receiver").

% Check if a specific named communicator is running
is_running(Name) when is_list(Name) ->
    case whereis(list_to_atom(Name)) of
        undefined -> 
            io:format("No process named ~s is running~n", [Name]),
            false;
        Pid ->
            io:format("Process ~s is running with PID: ~p~n", [Name, Pid]),
            true
    end;
is_running(Name) when is_atom(Name) ->
    is_running(atom_to_list(Name)).

% Display information about connected nodes
node_info() ->
    io:format("=== Node Information ===~n"),
    io:format("Current node: ~p~n", [node()]),
    io:format("Visible nodes: ~p~n", [nodes()]),
    % Check connectivity to all visible nodes
    lists:foreach(fun(N) ->
        case net_adm:ping(N) of
            pong -> io:format("  ✓ ~p: connected~n", [N]);
            pang -> io:format("  ✗ ~p: disconnected~n", [N])
        end
    end, nodes()),
    
    % Show registered processes on this node
    io:format("~nRegistered processes on this node:~n"),
    Registered = registered(),
    lists:foreach(fun(RegName) ->
        Pid = whereis(RegName),
        io:format("  ~p -> ~p~n", [RegName, Pid])
    end, Registered),
    ok.