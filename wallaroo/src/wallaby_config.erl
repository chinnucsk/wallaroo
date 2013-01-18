%% @author William C. Benton <willb@redhat.com>
%% @copyright 2012 Red Hat, Inc. and William C. Benton
%% @doc Wallaby configuration-generation support

-module(wallaby_config).

-behaviour(gen_server).

-export([init/1, handle_call/3, handle_cast/2, handle_info/2, terminate/2, code_change/3]).

-export([for/3]).

-compile([export_all]).

-record(cstate, {re, table, storage}).

-define(SERVER, ?MODULE).

init(Options) when is_list(Options) ->
    {ok, RE} = re:compile(list_to_binary("(?-mix:^(?:(>=|&&=|\\?=|\\|\\|=)\\s*)+(.*?)\\s*$)")),
    Table = ets:new(config, []),
    StoreMod = case orddict:find(storage_module, Options) of
		   {ok, Mod} ->
		       Mod;
		   error ->
		       wallaroo_store_ets
	       end,
    {ok, #cstate{re=RE, table=Table, storage=StoreMod}};
init(_) ->
    init([]).

%%% API functions

for(Kind, Name, Commit) ->
    gen_server:call(?SERVER, {config_for, Kind, Name, Commit}).

%%% gen_server callbacks
handle_cast(stop, State) ->
    {stop, normal, State}.

handle_call({config_for, Kind, Name, Commit}, _From, #cstate{re=RE, table=Cache, storage=StoreMod}=State) ->
    {reply, generic_find(Kind, Name, Commit, State), State}.

handle_info(_X, State) ->
    {noreply, State}.

terminate(_, _) ->
    ok.

code_change(_, State, _) ->
    {ok, State}.

%%% helpers


%% XXX: refactor me plz
transitively_reachable(Graph, StartNode) ->
    ordsets:from_list(digraph_utils:reachable_neighbours([StartNode], Graph)).

transitively_reachable(Graph, StartNode, Filter) ->
    [Node || Node <- transitively_reachable(Graph, StartNode), Filter(Node)].

interesting_install_edge({Kind, _, {'group', _}}) when Kind =:= 'member_of' ->
    true;
interesting_install_edge({Kind, _, {'feature', _}}) when Kind =:= 'includes' orelse Kind =:= 'installs' ->
    true;
interesting_install_edge(_) ->
    false.

interesting_install_vertex({'feature', _}) ->
    true;
interesting_install_vertex({'node', _}) ->
    true;
interesting_install_vertex({'group', _}) -> 
    true;
interesting_install_vertex(_) -> 
    false.

%% interesting_value_edge({'param_value', _, _}) ->
%%     true;
%% interesting_value_edge(X) ->
%%     interesting_install_edge(X).

calc_configs(Commit, #cstate{re=RE, table=Cache, storage=StoreMod}=State) ->
    Tree = wallaby_commit:get_tree(Commit, StoreMod),
    {Entities, Relationships} = wallaby_graph:extract_graph(Tree, StoreMod),
    Installs = digraph:new([private]),
    [digraph:add_vertex(Installs, Ent) || Ent <- Entities, interesting_install_vertex(Ent)],
    [digraph:add_edge(Installs, E1, E2, Kind) || F={Kind, E1, E2} <- Relationships, interesting_install_edge(F)],
    Order = lists:reverse(digraph_utils:topsort(Installs)),
    [calc_one_config(Entity, Tree, Commit, State) || Entity <- Order].

path_for_kind(feature) ->
    <<"features">>;
path_for_kind(group) ->
    <<"groups">>;
path_for_kind(node) ->
    <<"nodes">>;
path_for_kind(parameter) ->
    <<"parameters">>;
path_for_kind(X) when is_atom(X) ->
    list_to_binary(atom_to_list(X) ++ "s").

%% XXX:  should store these in lightweight format
calc_one_config({Kind, Name}, Tree, Commit, #cstate{re=RE, table=Cache, storage=StoreMod}=State) 
  when Kind =:= 'feature' ->
    %% get feature object from tree
    {value, EntityObj} = wallaroo_tree:get_path([path_for_kind(Kind), Name], Tree, StoreMod),
    %% apply included feature configs to empty config; these should already be in the cache
    BaseConfig = lists:foldl(apply_factory(true, State), [], [cache_fetch(Kind, Included, Commit, State) || Included <- lists:reverse(wallaby_feature:includes(EntityObj))]),
    %% resolve "defaulted" parameters
    MyConfig = orddict:map(fun(Param, 0) ->
				   {value, PObj} = wallaroo_tree:get_path([path_for_kind(parameter), Param], Tree, StoreMod),
				   wallaby_parameter:default_val(PObj);
			      (_, V) ->
				   V
			   end, wallaby_feature:parameters(EntityObj)),
    %% apply params to generated config and store in cache
    cache_store(Kind, Name, Commit, apply_to(BaseConfig, MyConfig, true, State), State);
calc_one_config({Kind, Name}, Tree, Commit, #cstate{re=RE, table=Cache, storage=StoreMod}=State) 
  when Kind =:= 'group' ->
    %% get group object from tree
    {value, EntityObj} = wallaroo_tree:get_path([path_for_kind(Kind), Name], Tree, StoreMod),
    %% apply installed feature configs to empty config; these should already be in the cache
    BaseConfig = lists:foldl(apply_factory(true, State), [], [cache_fetch(feature, Installed, Commit, State) || Installed <- lists:reverse(wallaby_group:features(EntityObj))]),
    %% apply my parameters to the base config
    cache_store(Kind, Name, Commit, apply_to(BaseConfig, wallaby_group:parameters(EntityObj), true, State), State); 
calc_one_config({Kind, Name}, Tree, Commit, #cstate{re=RE, table=Cache, storage=StoreMod}=State) 
  when Kind =:= 'node' ->
    %% get node object from tree
    {value, EntityObj} = wallaroo_tree:get_path([path_for_kind(Kind), Name], Tree, StoreMod),
    Config = lists:foldl(apply_factory(false, State), [], [cache_fetch(group, Membership, Commit, State) || Membership <- lists:reverse(wallaby_node:all_memberships(EntityObj))]),
    cache_store(Kind, Name, Commit, Config, State).
    
    


join_factory(Bin) when is_binary(Bin) ->
    fun(Old, New) ->
	    <<New/binary, Bin/binary, Old/binary>>
    end.

combine_factory(<<">=">>) ->
    join_factory(<<", ">>);
combine_factory(<<"&&=">>) ->
    join_factory(<<" && ">>);
combine_factory(<<"&=">>) ->
    join_factory(<<" && ">>);
combine_factory(<<"||=">>) ->
    join_factory(<<" || ">>);
combine_factory(<<"|=">>) ->
    join_factory(<<" || ">>);
combine_factory(<<"?=">>) ->
    fun(Old, New) -> Old end.

apply_val_factory(RE, SSPrepend) ->
    fun(_, Old, New) ->
	 case re:run(New, RE, [{capture, all_but_first, binary}]) of
	     {match, [Prepend, Val]} ->
		 F = combine_factory(Prepend),
		 case SSPrepend of
		     true ->
			 NewVal = F(Old, Val),
			 <<Prepend/binary, 32, NewVal/binary>>;
		     false ->
			 F(Old, Val)
		 end;
	     nomatch ->
		 New
	 end
    end.

apply_to(BaseConfig, NewConfig, SSPrepend) ->
    {ok, RE} = re:compile(list_to_binary("(?-mix:^(?:(>=|&&=|\\?=|\\|\\|=)\\s*)+(.*?)\\s*$)")),
    apply_to(BaseConfig, NewConfig, SSPrepend, #cstate{re=RE}).

apply_to(BaseConfig, NewConfig, SSPrepend, #cstate{re=RE}=State) ->
    orddict:merge(apply_val_factory(RE, SSPrepend), BaseConfig, NewConfig).

apply_factory(SSPrepend, State) ->
    fun(BaseConfig, NewConfig) ->
	    apply_to(BaseConfig, NewConfig, SSPrepend, State)
    end.

cache_store(Kind, Name, Commit, Config, #cstate{table=Cache}) ->
    ets:insert(Cache, {{Kind, Name, Commit}, Config}),
    Config.

cache_find(Kind, Name, Commit, #cstate{table=Cache}) ->
    case ets:match(Cache, {{Kind, Name, Commit}, '$1'}) of
	[[Config]] ->
	    {value, Config};
	 _ ->
	    find_failed
    end.

cache_fetch(Kind, Name, Commit, State) ->
    {value, Result} = cache_find(Kind, Name, Commit, State),
    Result.

generic_find(Kind, Name, Commit, State) ->
    case cache_find(Kind, Name, Commit, State) of
	{value, Config} ->
	    {value, Config};
	 find_failed ->
	    calc_configs(Commit, State),
	    cache_fetch(Kind, Name, Commit, State)
    end.