%% @author William C. Benton <willb@redhat.com>
%% @copyright 2011 Red Hat, Inc. and William C. Benton
%% @doc Wallaroo subsystem resource

-module(wallaroo_subsystem_resource).
-export([init/1, to_json/2, resource_exists/2]). 
-export([from_json/2]).
-export([is_authorized/2, allowed_methods/2, content_types_provided/2, content_types_accepted/2, finish_request/2, delete_resource/2, delete_completed/2]).

-include_lib("webmachine/include/webmachine.hrl").
-include("wallaroo_web_auth.hrl").

init(Args) ->
    wallaroo_web_common:generic_init(Args).

allowed_methods(ReqData, Ctx) ->
    {['HEAD', 'GET', 'POST', 'PUT', 'DELETE'], ReqData, Ctx}.

resource_exists(ReqData, Ctx) ->
    wallaroo_web_common:generic_entity_exists(ReqData, Ctx, fun(Name, Commit) -> wallaroo:get_entity(Name, subsystem, Commit) end).

is_authorized(ReqData, Ctx) ->
    ?STANDARD_AUTH(ReqData, Ctx).

content_types_accepted(ReqData, Ctx) ->
    {[{"application/json", from_json}], ReqData, Ctx}.

content_types_provided(ReqData, Ctx) ->
    {[{"application/json", to_json}], ReqData, Ctx}.

finish_request(ReqData, Ctx) ->
    {true, ReqData, Ctx}.

delete_resource(ReqData, Ctx) ->
    wallaroo_web_common:generic_delete_entity(ReqData, Ctx, subsystem, "subsystems").

delete_completed(ReqData, Ctx) ->
    {true, ReqData, Ctx}.


to_json(ReqData, Ctx) ->
    wallaroo_web_common:generic_to_json(ReqData, Ctx, fun(Commit) -> wallaroo:list_entities(subsystem, Commit) end, fun(Name, Commit) -> wallaroo:get_entity(Name, subsystem, Commit) end).

from_json(ReqData, Ctx) ->
    wallaroo_web_common:generic_from_json(ReqData, Ctx, fun(Nm) -> wallaby_subsystem:new(Nm) end, subsystem, "subsystems", fun validate/2).

validate({wallaby_subsystem, _}=Subsystem, none) ->
    Parameters = {nonexistent_parameters, {array, [P || {P, _} <- wallaby_subsystem:parameters(Subsystem)]}},
    case [Fail || Fail={_, Ls} <- [Parameters], Ls =/= {array, []}] of
	[] -> ok;
	Ls ->
	    {error, {struct, Ls}}
    end;
validate({wallaby_subsystem, _}=Subsystem, Commit) ->
    BadParameters = {nonexistent_parameters, {array, [P || {P, _} <- wallaby_subsystem:parameters(Subsystem), wallaroo:get_entity(P, parameter, Commit) =:= none]}},
    case [Fail || Fail={_, Ls} <- [BadParameters], Ls =/= {array, []}] of
	[] -> ok;
	Ls ->
	    {error, {struct, Ls}}
    end.
