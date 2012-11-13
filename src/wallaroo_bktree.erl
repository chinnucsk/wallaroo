-module(wallaroo_bktree).
% XXX:  should store/3 and friends be exported?
-export([empty/0, store/3, find/2, has/2, get_path/3, put_path/4, del_path/3, put_tree/2, children/1, diff/2]).


-define(TAG_OBJ, wObj).
-define(TAG_ACCESSIBLE_TREE, wAT).
-define(TAG_BUCKETED_TREE, wBT).
-define(MAX_TREE_SIZE, 1024).

-type rawtree() :: gb_tree().
% tag, depth, tree
-type bucketed_tree() :: {?TAG_BUCKETED_TREE, int(), rawtree()}.
-type accessible_tree() :: {?TAG_ACCESSIBLE_TREE, rawtree()}.
-type object() :: {?TAG_OBJECT, any()}.
-type tree() :: bucketed_tree() | accessible_tree().
-type find_result() :: 'none' | {'value', _}.
-type resolve_elt() :: {'none', tree(), list()} | {'none', tree(), {any(), list()}} | {{any(), any()}, tree(), int(), bitstring()}.
-type resolution() :: [resolve_elt()].
-export_type([tree/0, find_result/0]).

%% @doc returns an empty (accessible) tree
-spec empty() -> tree().
empty() ->
    {?TAG_ACCESSIBLE_TREE, gb_trees:empty()}.

wrap_object({?TAG_OBJECT, _}=O) ->
    O;
wrap_object(O) ->
    {?TAG_OBJECT, O}.

unwrap_object({?TAG_OBJECT, O}) ->
    O;
unwrap_object(O) ->
    O.

%% @doc stores an entry in an accessible Tree with key Key and value Val
-spec store(_,_,tree()) -> tree().
store(Key, Val, {?TAG_ACCESSIBLE_TREE=Tag, Tree}) ->
    case gb_trees:lookup(Key, Tree) of
	none ->
	    {Tag, gb_trees:insert(Key, Val, Tree)};
	{value, _} ->
	    {Tag, gb_trees:update(Key, Val, Tree)}
    end.

%% When you split, take the kth byte of the hash and use that as a key
kth_part(K, Bin) when is_bitstring(Bin) && is_integer(K) ->
    SkipSize = K * 8,
    <<Skip:SkipSize, Take:8, Rest/binary>> = Bin,
    Take.

% Returns a raw gb_tree of trees mapping from key_hash_part -> key -> value
map_pairs([_|_]=Pairs, Depth) when is_integer(Depth) ->
    FoldFun = fun({Key, Val}, Acc) ->
		      HashPart = kth_part(Depth, wallaroo_db:identity(Key)),
		      case gb_trees:lookup(Key, HashPart) of
			  none ->
			      Subtree = gb_trees:insert(Key, Val, gb_trees:empty()),
			      gb_trees:insert(HashPart, Subtree, Acc);
			  {value, ExistingSubtree} ->
			      Subtree = gb_trees:insert(Key, Val, ExistingSubtree),
			      gb_trees:update(HashPart, Subtree, Acc)
		      end
	      end,
    lists:foldl(FoldFun, gb_trees:empty(), Pairs).

%% @doc splits and balances an accessible tree into buckets if necessary; requires a storage module
%% @return a tree that should be hashed and stored
split({?TAG_ACCESSIBLE_TREE=Tag, {Sz,_}=Tree}, _, _) when Sz <= ?MAX_TREE_SIZE ->
    {Tag, Tree};
split({?TAG_ACCESSIBLE_TREE=Tag, Tree}, Depth, StoreMod) ->
    RawTree = map_pairs(gb_trees:to_list(Tree), Depth),
    StoreFunc = fun(HashPart, Subtree) -> wallaroo_db:hash_and_store(Subtree, StoreMod) end,
    NewTree = gb_trees:map(StoreFunc, RawTree),
    {?TAG_BUCKETED_TREE, Depth, NewTree}.

%% @doc finds the value stored in Tree under Key
-spec find(_, tree()) -> find_result().
find(Key, {?TAG_ACCESSIBLE_TREE=Tag, Tree}) ->
    gb_trees:lookup(Key, Tree);
find(Key, {?TAG_BUCKETED_TREE=Tag, Depth, Tree}) ->
    gb_trees:lookup(Key, Tree).

%% @doc returns true if Tree contains an entry for Key
-spec has(_, tree()) -> boolean().
has(Key, {?TAG_ACCESSIBLE_TREE=Tag, Tree}) ->
    gb_trees:is_defined(Key, Tree).

%% XXX: first any is really tree() | bitstring() | object(); need a new type for this
-spec resolve(list(), any(), atom()) -> resolution().
resolve(Path, Tree, StoreMod) ->
    resolve_it(Path, Tree, StoreMod, 0, nil, []).

%% XXX: first any is really tree() | bitstring() | object(); second any is really 'nil' | bitstring()
-spec resolve_it(list(), any(), atom(), integer(), any(), resolution()) -> resolution().
resolve_it([], Tree, StoreMod, Depth, KeyHash, Acc) ->
    Acc;
resolve_it([P|Rest]=Path, {?TAG_ACCESSIBLE_TREE, _}=Tree, StoreMod, Depth, KeyHash, Acc) ->
    case find(P, Tree) of
	none ->
	    [{none, Tree, Depth, lists:reverse(Path)}|Acc];
	{value, ElementHash} ->
	    Branch = StoreMod:find_object(ElementHash),
	    Entry = {{P, Branch}, Tree, Depth, KeyHash},
	    resolve_it(Rest, Branch, StoreMod, 0, nil, [Entry|Acc])
    end;
resolve_it([P|_]=Path, {?TAG_BUCKETED_TREE, Depth, _}=Tree, StoreMod, Depth, nil, Acc) ->
    KeyHash = wallaroo_db:identity(P),
    resolve_it(Path, Tree, StoreMod, Depth, KeyHash, Acc);
resolve_it(Path, {?TAG_BUCKETED_TREE, Depth, _}=Tree, StoreMod, ProvidedDepth, KeyHash, Acc) ->
    Subkey = kth_part(Depth, KeyHash),
    case find(Subkey, Tree) of
	none ->
	    [{none, Tree, Depth, {Subkey, lists:reverse(Path)}}|Acc];
	{value, ElementHash} ->
	    Subtree = StoreMod:findObject(ElementHash),
	    NewDepth = case Subtree of
			   {?TAG_BUCKETED_TREE, D, _} ->
			       D;
			   {?TAG_ACCESSIBLE_TREE, _} ->
			       ProvidedDepth + 1
		       end,
	    Entry = {{Subkey, Subtree}, Tree, Depth, KeyHash},
	    resolve_it(Path, Subtree, StoreMod, Depth, KeyHash, [Entry|Acc])
    end.


-spec put_tree(tree(), atom()) -> binary().
put_tree(Tree, StoreMod) ->
    wallaroo_db:hash_and_store(Tree, StoreMod).

%% @doc returns the result of looking up a path
-spec get_path([any()], _, atom()) -> find_result().
get_path(Path, Tree, StoreMod) ->
    case resolve(Path, Tree, StoreMod) of
	[{none,_,_,_}|_] ->
	    none;
	[{_,V},_,_,_|_] ->
	    {value, V};
	Val ->
	    {value, Val}
    end.

%% @doc stores Val in Tree at PathPart, assuming that no component of PathPart is already in Tree; returns hash for updated Tree
fold_absent(PathPart, {?TAG_OBJECT, _}=Val, Tree, Depth, StoreMod) ->
    [Last|Tser] = PathPart,
    ValHash = wallaroo_db:hash_and_store(Val, StoreMod),
    LeafHash = wallaroo_db:hash_and_store(store(Last, ValHash, empty()), StoreMod),
    FoldFun = fun(Element, AccHash) ->
		      T = store(Element, AccHash, empty()),
		      wallaroo_db:hash_and_store(T, StoreMod)
	      end,
    NewBranch = lists:foldl(FoldFun, LeafHash, Tser),
    NewSubtree = case Tree of 
		     {?TAG_BUCKETED_TREE, _, _} ->
			 store(Last, NewBranch, Tree);
		     {?TAG_ACCESSIBLE_TREE, _} ->
			 split(store(Last, NewBranch, Tree), Depth + 1, StoreMod)
		 end,
    wallaroo_db:hash_and_store(NewSubtree, StoreMod).

get_depth([]) ->
    0;
get_depth([{{_,_}, _, D, _}|_]) ->
    D;
get_depth(_) ->
    0.

%% @doc stores a value at a given path
-spec put_path(list(), object(), tree(), atom()) -> binary().
put_path(Path, {?TAG_OBJECT, _}=Object, Tree, StoreMod) when is_list(Path) ->
    ResolvedPath = resolve(Path, Tree, StoreMod),
    case ResolvedPath of
	[{none, Subtree, {SK, AbsentPath}}|Rest] ->	    
	    NBHash = fold_absent([SK|AbsentPath], Object, Subtree, get_depth(Rest), StoreMod)
