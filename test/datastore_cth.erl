-module(datastore_cth).

-include_lib("riakc/include/riakc.hrl").

%% API
-export([
	init_config/0,
	gun_open/1,
	gun_await/2,
	gun_await_json/2,
	gun_down/1,
	riaks2c_open/1,
	authorization_header/2,
	accounts/0,
	make_bucket/0,
	make_key/0
]).

%% =============================================================================
%% API
%% =============================================================================

-spec init_config() -> list().
init_config() ->
	init_accounts([]).

-spec gun_open(list()) -> pid().
gun_open(_Config) ->
	Host = "localhost",
	{_, Port} = lists:keyfind(port, 1, datastore:http_options()),
	{ok, Pid} = gun:open(Host, Port, #{retry => 0, protocols => [http2], transport => ssl}),
	Pid.

-spec gun_down(pid()) -> ok.
gun_down(Pid) ->
	receive {gun_down, Pid, _, _, _, _} -> ok
	after 500 -> error(timeout) end.

-spec gun_await(pid(), reference()) -> {100..999, [{binary(), iodata()}], binary()}.
gun_await(Pid, Ref) ->
	case gun:await(Pid, Ref) of
		{response, fin, St, Hs}   -> {St, Hs, <<>>};
		{response, nofin, St, Hs} ->
			{ok, Body} = gun:await_body(Pid, Ref),
			{St, Hs, Body}
	end.

-spec gun_await_json(pid(), reference()) -> {100..999, [{binary(), iodata()}], map()}.
gun_await_json(Pid, Ref) ->
	{St, Hs, Body} = gun_await(Pid, Ref),
	try {St, Hs, jsx:decode(Body, [return_maps, strict])}
	catch _:_ -> error({bad_response, {St, Hs, Body}}) end.

-spec riaks2c_open(list()) -> pid().
riaks2c_open(Config) ->
	#{host := Host,
		port := Port} = ct_helper:config(s2_http, Config),
	{ok, Pid} = gun:open(Host, Port, #{retry => 0, protocols => [http]}),
	Pid.

-spec authorization_header(atom(), list()) -> {binary(), iodata()}.
authorization_header(Account, Config) ->
	{_, #{access_token := Token}} = lists:keyfind(Account, 1, Config),
	{<<"authorization">>, [<<"Bearer ">>, Token]}.

-spec accounts() -> [atom()].
accounts() ->
	[bucket_reader, bucket_writer, object_reader, object_reader, anonymous, admin].

%% A bucket name must obey the following rules, which produces a DNS-compliant bucket name:
%% - Must be from 3 to 63 characters.
%% - Must be one or more labels, each separated by a period (.). Each label:
%% - Must start with a lowercase letter or a number. Must end with a lowercase letter or a number. Can contain lowercase letters, numbers and dashes.
%% - Must not be formatted as an IP address (e.g., 192.168.9.2).
%% https://docs.basho.com/riak/cs/2.1.1/references/apis/storage/s3/put-bucket
-spec make_bucket() -> iodata().
make_bucket() ->
	Uniq = integer_to_binary(erlang:unique_integer([positive])),
	Size = rand:uniform(61) -byte_size(Uniq),
	[	<<(oneof(alphanum_lowercase_chars()))>>,
		Uniq,
		list_to_binary(vector(Size, [$-|alphanum_lowercase_chars()])),
		<<(oneof(alphanum_lowercase_chars()))>> ].

-spec make_key() -> iodata().
make_key() ->
	Uniq = integer_to_binary(erlang:unique_integer([positive])),
	Size = 255 -byte_size(Uniq),
	[Uniq, list_to_binary(vector(Size, alphanum_chars()))].

%%% =============================================================================
%%% Internal functions
%%% =============================================================================

-spec init_accounts(list()) -> list().
init_accounts(Config) ->
	#{account_aclsubject := #{pool := KVpool, bucket := AclSubBucket}} = datastore:resources(),
	{ok, Pem} = file:read_file(datastore:conf_path(<<"keys/idp-example.priv.pem">>)),
	{Alg, Priv} = jose_pem:parse_key(Pem),
	CreateAccount =
		fun(Pid, AccountId, Groups) ->
			Token =
				jose_jws_compact:encode(
					#{iss => <<"idp.example.org">>,
						aud => <<"app.example.org">>,
						exp => 32503680000,
						sub => AccountId},
					Alg,
					Priv),
			riakacl:put_subject_groups(Pid, AclSubBucket, AccountId, Groups),
			#{id => AccountId, access_token => Token}
		end,

	KVpid = gunc_pool:lock(KVpool),
	AccountsConf =
		[	{bucket_reader, CreateAccount(KVpid, <<"bucket.reader">>, [{<<"bucket.reader">>, riakacl_group:new_dt()}])},
			{bucket_writer, CreateAccount(KVpid, <<"bucker.writer">>, [{<<"bucket.writer">>, riakacl_group:new_dt()}])},
			{object_reader, CreateAccount(KVpid, <<"object.reader">>, [{<<"object.reader">>, riakacl_group:new_dt()}])},
			{object_writer, CreateAccount(KVpid, <<"object.writer">>, [{<<"object.writer">>, riakacl_group:new_dt()}])},
			{anonymous, CreateAccount(KVpid, <<"anonymous">>, [{<<"anonymous">>, riakacl_group:new_dt()}])},
			{admin, CreateAccount(KVpid, <<"admin">>, [{<<"admin">>, riakacl_group:new_dt()}])} | Config ],
	gunc_pool:unlock(KVpool, KVpid),
	AccountsConf.

-spec oneof(list()) -> integer().
oneof(L) ->
	lists:nth(rand:uniform(length(L)), L).

-spec vector(non_neg_integer(), list()) -> list().
vector(MaxSize, L) ->
	vector(0, MaxSize, L, []).

-spec vector(non_neg_integer(), non_neg_integer(), list(), list()) -> list().
vector(Size, MaxSize, L, Acc) when Size < MaxSize ->
	vector(Size +1, MaxSize, L, [oneof(L)|Acc]);
vector(_, _, _, Acc) ->
	Acc.

-spec alphanum_lowercase_chars() -> list().
alphanum_lowercase_chars() ->
	"0123456789abcdefghijklmnopqrstuvwxyz".

-spec alphanum_chars() -> list().
alphanum_chars() ->
	"0123456789abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ".
