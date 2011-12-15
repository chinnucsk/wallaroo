%% @author William C. Benton <willb@redhat.com>
%% @copyright 2011 Red Hat, Inc. and William C. Benton
%% @doc Wallaroo node resource

-module(wallaroo_node_resource).
-export([init/1, to_json/2, resource_exists/2]). 
-export([from_json/2]).
-export([process_post/2, process_put/2]).
-export([allowed_methods/2, content_types_provided/2, content_types_accepted/2, finish_request/2]).

-include_lib("webmachine/include/webmachine.hrl").

init(Ctx) ->
    {{trace, "priv"}, Ctx}.

allowed_methods(ReqData, Ctx) ->
    {['HEAD', 'GET', 'POST', 'PUT'], ReqData, Ctx}.

resource_exists(ReqData, [{show_all}]=Ctx) ->
    {true, ReqData, Ctx};
resource_exists(ReqData, Ctx) ->
    Tag=wrq:get_qs_value("tag", "", ReqData),
    Commit=wrq:get_qs_value("commit", "", ReqData),
    case wrq:path_info(name, ReqData) of
	undefined ->
	    {false, ReqData, Ctx};
	"bogus" ->
	    {false, ReqData, Ctx};
	[_|_]=Node ->
	    {true, ReqData, [{Node, Tag, Commit}|Ctx]}
    end.

content_types_accepted(ReqData, Ctx) ->
    {[{"application/json", from_json}], ReqData, Ctx}.

content_types_provided(ReqData, Ctx) ->
    {[{"application/json", to_json}], ReqData, Ctx}.

finish_request(ReqData, Ctx) ->
    {true, ReqData, Ctx}.

process_post(ReqData, Ctx) ->
    {true, ReqData, Ctx}.

process_put(ReqData, Ctx) ->
    {true, ReqData, Ctx}.

to_json(ReqData, [{show_all}]=Ctx) ->
    {"\"all nodes\"", ReqData, Ctx};
to_json(ReqData, [{Node, Tag, Commit}|_]=Ctx) ->
    node_to_json(Tag, Commit, Node, ReqData, Ctx).

node_to_json(Tag, Commit, Node, ReqData, Ctx) ->
    case {Tag, Commit} of
    	{[], []} ->
    	    {"{name : \"" ++ Node ++ "\"}", ReqData, Ctx};
    	{_, []} ->
    	    {"{name : \"" ++ Node ++ "\"; tag : \"" ++ Tag ++ "\"}", ReqData, Ctx};
    	{[], _} ->
    	    {"{name : \"" ++ Node ++ "\"; commit : \"" ++ Commit ++ "\"}", ReqData, Ctx};
    	{_, _} ->
    	    {"\"can't specify both tag and commit\"", ReqData, Ctx}
    end.

from_json(ReqData, Ctx) ->
    case wrq:path_info(id, ReqData) of
        undefined ->
            {false, ReqData, Ctx};
        ID ->
            {true, ReqData, Ctx}
    end.
