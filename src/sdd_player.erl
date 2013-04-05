%%% =================================================================================== %%%
%%% Sudoku Dash Game: Player Server                                                     %%%
%%%                                                                                     %%%
%%% Copyright 2012 Anselm Eickhoff                                                      %%%
%%%                                                                                     %%%
%%% This is a gen_server that handles a connected player:                               %%%
%%% - holds temporary player state                                                      %%%
%%% - connects game and client                                                          %%%
%%% It only lives as long as the client processes it is connected to although it can    %%%
%%% handle temporary disconnects of the client.                                         %%%
%%% =================================================================================== %%%

-module(sdd_player).

%% API
-export([start_link/2, do/3, handle_game_event/5, register/3, authenticate/1, connect/3, disconnect/2]).

%% GEN_SERVER
-behaviour(gen_server).
-export([init/1, handle_cast/2, handle_call/3, handle_info/2, code_change/3, terminate/2]).

%% Records
-record(state, {
	id,
	name,
	secret,
	current_game,
	current_client,
	points,
	badges = []
}).

-record(player_info, {
	name,
	points,
	badges
}).

%%% =================================================================================== %%%
%%% API                                                                                 %%%
%%% =================================================================================== %%%

start_link(PlayerId, History) ->
	gen_server:start_link({global, {player, PlayerId}}, ?MODULE, History, []).

do(PlayerId, Action, Args) ->
	gen_server:cast({global, {player, PlayerId}}, {Action, Args}).

handle_game_event(PlayerId, GameId, Time, EventType, EventData) ->
	catch gen_server:call({global, {player, PlayerId}}, {handle_game_event, GameId, Time, EventType, EventData}, 5000).

register(PlayerId, Name, Secret) ->
	case sdd_history:persisted_state(player_history, PlayerId) of
		doesnt_exist ->
			InitialHistory = sdd_history:new(fun realize_event/3),
			History = sdd_history:append(InitialHistory, register, {PlayerId, Name, Secret}),
			HistoryWithBadge = sdd_history:append(History, get_badge, {<<"&alpha;">>,<<"Alpha Tester">>}),
			sdd_history:save_persisted(player_history, PlayerId, HistoryWithBadge),
			sdd_players_sup:start_player(PlayerId, HistoryWithBadge),
			ok;
		_Exists -> already_exists
	end.

authenticate(Secret) ->
	case sdd_history:persisted_state_by_match(player_history, #state{
		secret = Secret,
		id = '_',
		name = '_',
		current_game = '_',
		current_client = '_',
		points = '_',
		badges = '_'
	}) of
		State = #state{secret = Secret} -> {State#state.name, State#state.id};
		_Else -> false
	end.

connect(PlayerId, ClientId, ClientInfo) ->
	case global:whereis_name({player, PlayerId}) of
		undefined ->
			erlang:display("Loading Player"),
			History = sdd_history:load_persisted(player_history, PlayerId, fun realize_event/3),
			sdd_players_sup:start_player(PlayerId, History);
		_Pid -> erlang:display("Player already running"), do_nothing
	end,
	gen_server:cast({global, {player, PlayerId}}, {connect, ClientId, ClientInfo}).

disconnect(PlayerId, ClientId) ->
	gen_server:cast({global, {player, PlayerId}}, {disconnect, ClientId}).

%%% =================================================================================== %%%
%%% GEN_SERVER CALLBACKS                                                                %%%
%%% =================================================================================== %%%

%% ------------------------------------------------------------------------------------- %%
%% Creates a new player process with the given history

init(InitialHistory) ->
	{ok, InitialHistory}.

%% ------------------------------------------------------------------------------------- %%
%% Connects a new client

handle_cast({connect, ClientId, ClientInfo}, History) ->
	State = sdd_history:state(History),
	case State#state.current_client of
		undefined -> do_nothing;
		OldClient -> sdd_client:other_client_connected(OldClient)
	end,

	ListenerFunction = fun
		(state, PlayerState) ->
			sdd_client:sync_player_state(
				ClientId,
				PlayerState#state.points,
				PlayerState#state.badges,
				PlayerState#state.current_game
			);
		(event, {_Time, EventType, EventData}) -> sdd_client:handle_player_event(ClientId, EventType, EventData)
	end,
	HistoryWithListener = sdd_history:add_listener(History, ListenerFunction, tell_state),
	NewHistory = sdd_history:append(HistoryWithListener, connect, {ClientId, ClientInfo}),
	
	{noreply, NewHistory};


%% Disconnects a client, if it was the current one, stop player process

handle_cast({disconnect, ClientId}, History) ->
	State = sdd_history:state(History),
	case State#state.current_client of
		ClientId ->
			case State#state.current_game of
				undefined -> {noreply, History};
				GameId ->
					sdd_games_manager:leave(State#state.id, GameId, disconnect),
					{stop, normal, History}
			end;
		_OtherClient -> {noreply, History}
	end;

%% Finds a game and joins it

handle_cast({find_game, Options}, History) ->
	State = sdd_history:state(History),
	PlayerInfo = #player_info{
		name = State#state.name,
		points = State#state.points,
		badges = State#state.badges
	},
	sdd_games_manager:find_game_and_join(State#state.id, PlayerInfo, Options, State#state.current_game),
	{noreply, History};

%% Leaves the current game, for a reason, and notifies the game

handle_cast({leave, Reason}, History) ->
	NewHistory = sdd_history:append(History, leave, Reason),
	{noreply, NewHistory};

%% Increases a player's points by a given amount

handle_cast({get_points, Increase}, History) ->	
	NewHistory = sdd_history:append(History, get_points, Increase),
	{noreply, NewHistory};

%% Adds a badge

handle_cast({get_badge, Badge}, History) ->
	NewHistory = sdd_history:append(History, get_badge, Badge),
	{noreply, NewHistory};


%% Does our part of joining a game, coming from a source
handle_cast({join, {GameId, Source}}, History) ->
	NewHistory = sdd_history:append(History, join, {GameId, Source}),
	{noreply, NewHistory}.

%% ------------------------------------------------------------------------------------- %%
%% Returns continue_listening for events from our current game
%% and redirects them to the client

handle_call({handle_game_event, GameId, Time, EventType, EventData}, _From, History) ->
	State = sdd_history:state(History),
	CurrentGame = State#state.current_game,
	MyId = State#state.id,
	case GameId of
		CurrentGame ->
			case State#state.current_client of
				undefined -> do_nothing;
				ClientId -> sdd_client:handle_game_event(ClientId, GameId, Time, EventType, EventData)
			end,
			case {EventType, EventData} of
				{leave, {MyId, _Reason}} -> {reply, left, History};
				_StillInGame -> {reply, continue_listening, History}
			end;
		_WrongGame ->
			{reply, wrong_game, History}
	end.

terminate(_Reason, History) ->
	State = sdd_history:state(History),
	sdd_history:save_persisted(player_history, State#state.id, History),
	ok.

%% ------------------------------------------------------------------------------------- %%
%% Rest of gen_server calls

handle_info(_Info, State) ->
	State.

code_change(_OldVsn, State, _Extra) ->
	{ok, State}.

%%% =================================================================================== %%%
%%% HISTORY CALLBACKS                                                                   %%%
%%% =================================================================================== %%%

%% ------------------------------------------------------------------------------------- %%
%% Create initial state

realize_event(_EmptyState, register, {Id, Name, Secret}) ->
	#state{id = Id, name = Name, secret = Secret, points = 0};

%% Change current game

realize_event(State, join, {GameId, _Source}) ->
	State#state{current_game = GameId};

%% Reset current game

realize_event(State, leave, _Reason) ->
	State#state{current_game = undefined};

%% Add a badge

realize_event(State, get_badge, Badge) ->
	State#state{badges = [Badge | State#state.badges]};

%% Get points

realize_event(State, get_points, Increase) ->
	State#state{points = State#state.points + Increase};

%% Set new client

realize_event(State, connect, {ClientId, _ClientInfo}) ->
	State#state{current_client = ClientId}.

%%% =================================================================================== %%%
%%% TESTS                                                                               %%%
%%% =================================================================================== %%%

-ifdef(TEST).

-include_lib("eunit/include/eunit.hrl").
-include_lib("sdd_history_test_macros.hrl").


-define(init_peter,
	sdd_history:append(sdd_history:new(fun realize_event/3), register, {"Peter", "Name", "secret"})
).

init_createsPlayerProcessWithAHistory_test() ->
	{ok, InitialHistory} = init(dummy_history),
	?assertEqual(InitialHistory, dummy_history).

join_setsGameAsCurrentGame_test() ->

	InitialHistory = ?init_peter,

	{noreply, HistoryAfterGoodJoin} = handle_cast({join, {"GameId", invite}}, InitialHistory),

	?history_assert_state_field_equals(HistoryAfterGoodJoin, current_game, "GameId"),
	?history_assert_past_matches(HistoryAfterGoodJoin, [{_Time, join, {"GameId", invite}} | _ ]).

-define(init_peter_and_join_good_game,
	fun () ->
		InitialHistory = ?init_peter,
		handle_cast({join, {"GoodGame", invite}}, InitialHistory)
	end ()
).

leave_resetsCurrentGame_test() ->
	{noreply, HistoryAfterGoodJoin} = ?init_peter_and_join_good_game,

	{noreply, HistoryAfterLeaving} = handle_cast({leave, timeout}, HistoryAfterGoodJoin),
	
	?history_assert_state_field_equals(HistoryAfterLeaving, current_game, undefined),
	?history_assert_past_matches(HistoryAfterLeaving, [{_Time, leave, timeout} | _ ]).

handle_game_event_continuesListeningOnlyIfEventWasFromCurrentGame_test() ->
	{noreply, HistoryAfterGoodJoin} = ?init_peter_and_join_good_game,

	?assertMatch(
		{reply, continue_listening, _NewHistory},
		handle_call({handle_game_event, "GoodGame", some_time, some_event, some_data}, from, HistoryAfterGoodJoin)
	),
	?assertMatch(
		{reply, wrong_game, _NewHistory},
		handle_call({handle_game_event, "OtherGame", some_time, some_event, some_data}, from, HistoryAfterGoodJoin)
	).

-define(meck_sdd_client, 
	meck:new(sdd_client),
	meck:expect(sdd_client, handle_game_event, fun
		(_ClientId, _GameId, _Time, _EventType, _EventData) -> ok
	end),
	meck:expect(sdd_client, handle_player_event, fun
		(_ClientId, _EventType, _EventData) -> ok
	end),
	meck:expect(sdd_client, sync_player_state, fun
		(_ClientId, _Points, _Badges, _CurrentGame) -> ok
	end)
).	

handle_game_event_redirectsToCurrentClientIfExistsAndIfEventWasFromCurrentGame_test() ->
	{noreply, HistoryAfterGoodJoin} = ?init_peter_and_join_good_game,

	%% Nothing should happen when event comes from wrong game, otherwise undef will be thrown here
	handle_call({handle_game_event, "BadGame", some_time, some_event, some_data}, from, HistoryAfterGoodJoin),

	%% Nothing should happen with no client, otherwise undef will be thrown here
	handle_call({handle_game_event, "GoodGame", some_time, some_event, some_data}, from, HistoryAfterGoodJoin),

	?meck_sdd_client,

	{noreply, HistoryAfterConnect} = handle_cast({connect, "ClientA", "ClientAInfo"}, HistoryAfterGoodJoin),
	handle_call({handle_game_event, "GoodGame", some_time, some_event, some_data}, from, HistoryAfterConnect),
	?assert(meck:called(sdd_client, handle_game_event, ["ClientA", "GoodGame", some_time, some_event, some_data])),
	?assert(meck:validate(sdd_client)),
	meck:unload(sdd_client).

get_points_addsPoints_test() ->
	InitialHistory = ?init_peter,

	{noreply, HistoryAfterGettingPoints} = handle_cast({get_points, 3}, InitialHistory),

	?history_assert_state_field_equals(HistoryAfterGettingPoints, points, 3),
	?history_assert_past_matches(HistoryAfterGettingPoints, [{_Time, get_points, 3} | _ ]).

get_badge_addsABadge_test() ->
	InitialHistory = ?init_peter,

	Badge1 = {"Good Test Subject", "For being an important part of these unit tests"},
	Badge2 = {"Good Person", "For having a beautiful personality"},

	{noreply, HistoryAfterGettingFirstBadge} = handle_cast({get_badge, Badge1}, InitialHistory),
	{noreply, HistoryAfterGettingSecondBadge} = handle_cast({get_badge, Badge2}, HistoryAfterGettingFirstBadge),
	
	?history_assert_state_field_equals(HistoryAfterGettingSecondBadge, badges, [Badge2, Badge1]),
	?history_assert_past_matches(HistoryAfterGettingSecondBadge, [{_Time2, get_badge, Badge2}, {_Time1, get_badge, Badge1} | _ ]).

connect_setsNewClientAndMakesClientAListenerOfPlayerHistory_test() ->
	InitialHistory = ?init_peter,

	?meck_sdd_client,

	% make sure client gets player state without secret field
	State = sdd_history:state(InitialHistory),

	{noreply, HistoryAfterConnect} = handle_cast({connect, "ClientA", "ClientAInfo"}, InitialHistory),

	?assert(meck:called(sdd_client, sync_player_state, ["ClientA", State#state.points, State#state.badges, State#state.current_game])),

	?assert(meck:called(sdd_client, handle_player_event, ["ClientA", connect, {"ClientA", "ClientAInfo"}])),
	?assert(meck:validate(sdd_client)),
	meck:unload(sdd_client),

	?history_assert_state_field_equals(HistoryAfterConnect, current_client, "ClientA"),
	?history_assert_past_matches(HistoryAfterConnect, [{_Time, connect, {"ClientA", "ClientAInfo"}} | _ ]).

-endif.