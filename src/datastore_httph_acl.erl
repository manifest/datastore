-module(datastore_httph_acl).

-include("datastore_log.hrl").

%% REST handler callbacks
-export([
	init/2,
	is_authorized/2,
	forbidden/2,
	resource_exists/2,
	content_types_provided/2,
	content_types_accepted/2,
	allowed_methods/2,
	options/2
]).

%% Content callbacks
-export([
	from_json/2,
	to_json/2
]).

%% Types
-record(state, {
	rdesc              :: map(),
	authconf           :: map(),
	aclgroup           :: iodata(),
	bucket             :: iodata(),
	key    = undefined :: undefined | iodata(),
	authm  = #{}       :: map(),
	r      = undefined :: undefined | map()
}).

%% =============================================================================
%% REST handler callbacks
%% =============================================================================

init(Req, Opts) ->
	#{authentication := AuthConf, resources := R} = Opts,
	State =
		#state{
			rdesc = R,
			authconf = AuthConf,
			aclgroup = cowboy_req:binding(aclgroup, Req),
			bucket = cowboy_req:binding(bucket, Req),
			key = cowboy_req:binding(key, Req)},
	{cowboy_rest, Req, State}.

is_authorized(#{method := <<"OPTIONS">>} =Req, State)  -> {true, Req, State};
is_authorized(Req, #state{authconf = AuthConf} =State) ->
	try datastore_http:decode_access_token(Req, AuthConf) of
		TokenPayload ->
			?INFO_REPORT([{access_token, TokenPayload} | datastore_http_log:format_request(Req)]),
			{true, Req, State#state{authm = TokenPayload}}
	catch
		T:R ->
			?ERROR_REPORT(datastore_http_log:format_unauthenticated_request(Req), T, R),
			{{false, datastore_http:access_token_type()}, Req, State}
	end.

forbidden(Req, #state{rdesc = Rdesc, bucket = Bucket, authm = AuthM} =State) ->
	try datastore:authorize(Bucket, AuthM, Rdesc) of
		{ok, #{write := true}} -> {false, Req, State};
		_                      -> {true, Req, State}
	catch T:R ->
		?ERROR_REPORT(datastore_http_log:format_request(Req), T, R),
		{stop, cowboy_req:reply(422, Req), State}
	end.

resource_exists(Req, #state{bucket = Bucket, key = Key, aclgroup = Gname, rdesc = Rdesc} =State) ->
	try datastore_acl:read(Bucket, Key, Gname, Rdesc) of
		{ok, Val} -> {true, Req, State#state{r = Val}};
		_         -> {false, Req, State}
	catch T:R ->
		?ERROR_REPORT(datastore_http_log:format_request(Req), T, R),
		{stop, cowboy_req:reply(422, Req), State}
	end.

content_types_provided(Req, State) ->
	Handlers = [{{<<"application">>, <<"json">>, '*'}, to_json}],
	{Handlers, Req, State}.

content_types_accepted(Req, State) ->
	Handlers = [{{<<"application">>, <<"json">>, '*'}, from_json}],
	{Handlers, Req, State}.

allowed_methods(Req, State) ->
	Methods = [<<"GET">>, <<"PUT">>, <<"OPTIONS">>],
	{Methods, Req, State}.

options(Req0, State) ->
	Req1 = cowboy_req:set_resp_header(<<"access-control-allow-methods">>, <<"GET, PUT">>, Req0),
	Req2 = cowboy_req:set_resp_header(<<"access-control-allow-headers">>, <<"Authorization, Content-Type">>, Req1),
	Req3 = cowboy_req:set_resp_header(<<"access-control-allow-credentials">>, <<"true">>, Req2),
	{ok, Req3, State}.

%% =============================================================================
%% Content callbacks
%% =============================================================================

from_json(Req0, #state{bucket = Bucket, key = Key, aclgroup = Gname, rdesc = Rdesc} =State) ->
	datastore_http:handle_payload(Req0, State, fun(Payload, Req1) ->
		datastore_http:handle_response(Req1, State, fun() ->
			datastore_acl:update(Bucket, Key, Gname, datastore_acl:parse_group_data(jsx:decode(Payload)), Rdesc)
		end)
	end).

to_json(Req, #state{r = R} =State) ->
	datastore_http:handle_response(Req, State, fun() ->
		jsx:encode(R)
	end).