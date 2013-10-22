%%%-------------------------------------------------------------------
%%% @author magnus <magnus@t520>
%%% @copyright (C) 2013, magnus
%%% @doc
%%%
%%% @end
%%% Created :  8 Oct 2013 by Magnus Feuer (magnus.feuer@feuerlabs.com)
%%%-------------------------------------------------------------------
-module(exometer_report).

-behaviour(gen_server).

%% API
-export([start_link/0,
	 subscribe/4,
	 unsubscribe/3]).


%% gen_server callbacks
-export([init/1, handle_call/3, handle_cast/2, handle_info/2,
	 terminate/2, code_change/3]).

-define(SERVER, ?MODULE).
-type probe() :: list().
-type datapoint() :: atom().
-type value() :: any().
-type mod_state() :: any().
-type recipient() :: pid() | atom().
-type options() :: [ { atom(), any()} ].

-type key() :: {pid | module, recipient(), probe(), datapoint()}.

%% Callback for function, not cast-based, reports that
%% are invoked in-process.
-callback report(probe(), datapoint(), value(), mod_state()) -> any().
-callback init(options()) -> any().

-record(key, {
	  type,
	  recipient,
	  probe,
	  datapoint
	 }).

-record(subscriber, {
	  key   :: key(),
	  m_ref :: reference(),
	  t_ref :: reference()
	 }).

-record(mod_state, {
	  module :: atom(),
	  state  :: any()
	 }).

-record(st, {
	  subscribers:: [ #subscriber{} ],
	  mod_states :: [ #mod_state{}  ]
	 }).

-include("log.hrl").

%%%===================================================================
%%% API
%%%===================================================================

%%--------------------------------------------------------------------
%% @doc
%% Starts the server
%%
%% @spec start_link() -> {ok, Pid} | ignore | {error, Error}
%% @end
%%--------------------------------------------------------------------
start_link() ->
    {ok, Opts} = application:get_env(exometer, exometer_report),
    gen_server:start_link({local, ?MODULE}, ?MODULE,  Opts, []).


subscribe(Recipient, Probe, DataPoint, Interval) ->
    call({subscribe, #key{type = recipient_type(Recipient),
			  recipient = Recipient,
			  probe = Probe,
			  datapoint = DataPoint}, Interval}).

unsubscribe(Recipient, Probe, DataPoint)  ->
    call({unsubscribe, #key{type = recipient_type(Recipient),
			    recipient = Recipient,
			    probe = Probe,
			    datapoint = DataPoint}}).

call(Req) ->
    gen_server:call(?MODULE, Req).

%%%===================================================================
%%% gen_server callbacks
%%%===================================================================

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Initializes the server
%%
%% @spec init(Args) -> {ok, State} |
%%                     {ok, State, Timeout} |
%%                     ignore |
%%                     {stop, Reason}
%% @end
%%--------------------------------------------------------------------
init(Opts) ->
    %% Dig out the mod opts.
    %% { modules, [ {module1, [{opt1, val}, ...]}, {module2, [...]}]}
    {value, {modules, Modules}, _Opts1 } = lists:keytake(modules, 1, Opts),

    %% Traverse list and init modules.
    %% If init fails, leave module out of module state list
    ModStates = lists:foldr(fun init_module/2, [], Modules),
    {ok, #st{
	    subscribers = [],
	    mod_states = ModStates
	   }}.

init_module({Mod, Opts}, Acc) ->
    case catch Mod:init(Opts) of
	{ok, ModSt} ->
	    [{Mod, ModSt} | Acc];
	{Error, Reason} when Error == error; Error == 'EXIT' ->
	    ?error("~p:init(~p) -> {~p, ~p}; skipping module~n",
		   [Mod, Opts, Error, Reason]),
	    Acc
    end.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Handling call messages
%%
%% @spec handle_call(Request, From, State) ->
%%                                   {reply, Reply, State} |
%%                                   {reply, Reply, State, Timeout} |
%%                                   {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, Reply, State} |
%%                                   {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_call({subscribe, #key{type = Type,
			     recipient = Recipient} = Key, Interval},
	    _From, #st{subscribers = Subs} = St) ->
    %% FIXME: Validate Probe and datapoint
    %% FIXME: Monitor on pids.
    TRef = erlang:send_after(Interval, self(), {report, Key, Interval}),
    MRef = set_monitor(Type, Recipient),
    Sub = #subscriber{key = Key,
		      m_ref = MRef,
		      t_ref = TRef},
    {reply, ok, St#st{subscribers = [Sub | Subs]}};
%%
handle_call({unsubscribe, #key{} = Key}, _, #st{subscribers = Subs} = St) ->
    case lists:keytake(Key, #subscriber.key, Subs) of
	{value, #subscriber{t_ref = TRef, m_ref = MRef}, Rem} ->
	    cancel_timer(TRef),
	    cancel_monitor(MRef),
	    {reply, ok, St#st{subscribers = Rem}};
	_ ->
	    {reply, not_found, St }
    end;
%%
handle_call(_Request, _From, State) ->
    {reply, {error, unknown_call}, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc Handling cast messages.
%%
%% @spec handle_cast(Msg, State) -> {noreply, State} |
%%                                  {noreply, State, Timeout} |
%%                                  {stop, Reason, State}
%% @end
%%--------------------------------------------------------------------
handle_cast(_Msg, State) ->
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc Handling all non call/cast messages.
%%
%% @spec handle_info(Info, State) -> {noreply, State} |
%%                                   {noreply, State, Timeout} |
%%                                   {stop, Reason, State}
%% @endo
%%--------------------------------------------------------------------
handle_info({report, #key{type = Type, recipient = Recipient, probe = Probe,
			  datapoint = DataPoint} = Key, Interval},
	    #st{mod_states = ModStates, subscribers = Subs} = St) ->
    case lists:keyfind(Key, #subscriber.key, Subs) of
	#subscriber{} = Sub ->
	    case exometer_entry:get_value(Probe, [DataPoint]) of
		{ok, [{_, Val}]} ->
		    %% Distribute probe value to pid subscriber or module,
		    %% depending on type.
		    %% Store indication if we should re-arm the timer,
		    %% and the new module states (for module reporting).
		    {ReArmTimer, NewModStates} =
			report_value(Type, Recipient, Probe,
				     DataPoint, Val, ModStates),

		    %% If the reporting went well, re-arm the timer
		    %% for next round
		    TRef = if ReArmTimer ->
				   erlang:send_after(
				     Interval, self(), {report, Key, Interval});
			      true -> undefined
			   end,
		    %% Replace the pid_subscriber info with a record having
		    %% the new timer ref. Replace mod states with the updates
		    %% state returned by Recipient:report()
		    {noreply, St#st{mod_states = NewModStates,
				    subscribers =
					lists:keyreplace(
					  Key, #subscriber.key, Subs,
					  Sub#subscriber{t_ref = TRef})}};
		_ ->
		    %% Entry removed while timer in progress.
		    ?error("Probe(~p) Datapoint(~p) not found~n",
			   [Probe, DataPoint]),
		    {noreply, St}
	    end;
	false ->
	    %% Possibly an unsubscribe removed the subscriber
	    ?error("No such subscriber (Key=~p)~n", [Key]),
	    {noreply, St}
    end;
%%
handle_info({'DOWN', _, _, Pid, _}, #st{subscribers = Subs} = St) ->
    case [S || #subscriber{key = #key{recipient = P}} = S <- Subs, P==Pid] of
	[#subscriber{t_ref = TRef} = Subscriber] ->
	    cancel_timer(TRef),
	    {noreply, St#st{subscribers = Subs -- [Subscriber]}};
	[] ->
	    {noreply, St}
    end;
handle_info(_Info, State) ->
    io:format("exometer_report:info(??): ~p~n", [ _Info ]),
    {noreply, State}.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% This function is called by a gen_server when it is about to
%% terminate. It should be the opposite of Module:init/1 and do any
%% necessary cleaning up. When it returns, the gen_server terminates
%% with Reason. The return value is ignored.
%%
%% @spec terminate(Reason, State) -> void()
%% @end
%%--------------------------------------------------------------------
terminate(_Reason, _State) ->
    ok.

%%--------------------------------------------------------------------
%% @private
%% @doc
%% Convert process state when code is changed
%%
%% @spec code_change(OldVsn, State, Extra) -> {ok, NewState}
%% @end
%%--------------------------------------------------------------------
code_change(_OldVsn, State, _Extra) ->
    {ok, State}.

%%%===================================================================
%%% Internal functions
%%%===================================================================

recipient_type(P) when is_pid(P)  -> pid;
recipient_type(M) when is_atom(M) -> module.

set_monitor(pid, P) when is_pid(P) ->
    erlang:monitor(process, P);
set_monitor(_, _) ->
    undefined.


cancel_timer(undefined) -> ok;
cancel_timer(TRef) ->
    erlang:cancel_timer(TRef).

cancel_monitor(undefined) -> ok;
cancel_monitor(MRef) ->
    erlang:demonitor(MRef).

report_value(pid, Recipient, Probe, DataPoint, Val, ModStates) ->
    %% Send a message to the recipient process
    Recipient ! {exometer_report, os:timestamp(), Probe, DataPoint, Val},
    {true, ModStates};
report_value(module, Mod, Probe, DataPoint, Val, ModStates) ->
    %% Invoke the module with probe, datapoint and current
    %% module state. New state will be saved.
    case lists:keyfind(Mod, 1, ModStates) of
	{_, ModSt} ->
	    %% Check that the reporting went well.
	    %% If not, remove from ModState list
	    case catch Mod:report(Probe, DataPoint, Val, ModSt) of
		{ok, NewModSt} ->
		    {true, lists:keyreplace(
			     Mod, 1, ModStates, {Mod, NewModSt})};
		{Error, Reason} ->
		    ?error("~p:report(~p, ~p, ~p, ~p) ->"
			   " {~p, ~p}; removing module~n",
			   [Mod, Probe, DataPoint, Val, ModSt, Error, Reason]),
		    {false, lists:keydelete(Mod, 1, ModStates)}
	    end;
	false ->
	    ?error("Cannot find module ~p~n", [Mod]),
	    {false, ModStates}
    end.
