%% This Source Code Form is subject to the terms of the Mozilla Public
%% License, v. 2.0. If a copy of the MPL was not distributed with this
%% file, You can obtain one at https://mozilla.org/MPL/2.0/.
%%
%% Copyright (c) 2007-2022 VMware, Inc. or its affiliates.  All rights reserved.
%%
-module(unit_SUITE).

-compile(export_all).

-include_lib("rabbit_common/include/rabbit.hrl").
-include_lib("common_test/include/ct.hrl").
-include_lib("eunit/include/eunit.hrl").

all() ->
    [
        test_own_scope,
        test_validate_payload_resource_server_id_mismatch,
        test_validate_payload,
        test_successful_access_with_a_token,
        test_successful_access_with_a_token_that_has_tag_scopes,
        test_unsuccessful_access_with_a_bogus_token,
        test_restricted_vhost_access_with_a_valid_token,
        test_insufficient_permissions_in_a_valid_token,
        test_command_json,
        test_command_pem,
        test_command_pem_no_kid,
        test_token_expiration,
        test_incorrect_kid,
        test_post_process_token_payload,
        test_post_process_token_payload_keycloak,
        test_post_process_token_payload_complex_claims,
        test_successful_access_with_a_token_that_uses_single_scope_alias_in_scope_field,
        test_successful_access_with_a_token_that_uses_multiple_scope_aliases_in_scope_field,
        test_unsuccessful_access_with_a_token_that_uses_missing_scope_alias_in_scope_field,
        test_successful_access_with_a_token_that_uses_single_scope_alias_in_extra_scope_source_field,
        test_successful_access_with_a_token_that_uses_multiple_scope_aliases_in_extra_scope_source_field,
        test_unsuccessful_access_with_a_token_that_uses_missing_scope_alias_in_extra_scope_source_field
    ].

init_per_suite(Config) ->
    application:load(rabbitmq_auth_backend_oauth2),
    Env = application:get_all_env(rabbitmq_auth_backend_oauth2),
    Config1 = rabbit_ct_helpers:set_config(Config, {env, Env}),
    rabbit_ct_helpers:run_setup_steps(Config1, []).

end_per_suite(Config) ->
    Env = ?config(env, Config),
    lists:foreach(
        fun({K, V}) ->
            application:set_env(rabbitmq_auth_backend_oauth2, K, V)
        end,
        Env),
    rabbit_ct_helpers:run_teardown_steps(Config).

init_per_testcase(test_post_process_token_payload_complex_claims, Config) ->
  application:set_env(rabbitmq_auth_backend_oauth2, extra_scopes_source, <<"additional_rabbitmq_scopes">>),
  application:set_env(rabbitmq_auth_backend_oauth2, resource_server_id, <<"rabbitmq">>),
  Config;

init_per_testcase(_, Config) ->
  Config.

end_per_testcase(test_post_process_token_payload_complex_claims, Config) ->
  application:set_env(rabbitmq_auth_backend_oauth2, extra_scopes_source, undefined),
  application:set_env(rabbitmq_auth_backend_oauth2, resource_server_id, undefined),
  Config;
end_per_testcase(_, Config) ->
  Config.

%%
%% Test Cases
%%

-define(UTIL_MOD, rabbit_auth_backend_oauth2_test_util).
-define(RESOURCE_SERVER_ID, <<"rabbitmq">>).

test_post_process_token_payload(_) ->
    ArgumentsExpections = [
        {{[<<"rabbitmq">>, <<"hare">>], [<<"read">>, <<"write">>, <<"configure">>]},
         {[<<"rabbitmq">>, <<"hare">>], [<<"read">>, <<"write">>, <<"configure">>]}},
        {{<<"rabbitmq hare">>, <<"read write configure">>},
         {[<<"rabbitmq">>, <<"hare">>], [<<"read">>, <<"write">>, <<"configure">>]}},
        {{<<"rabbitmq">>, <<"read">>},
         {[<<"rabbitmq">>], [<<"read">>]}}
    ],
    lists:foreach(
        fun({{Aud, Scope}, {ExpectedAud, ExpectedScope}}) ->
            Payload = post_process_token_payload(Aud, Scope),
            ?assertEqual(ExpectedAud, maps:get(<<"aud">>, Payload)),
            ?assertEqual(ExpectedScope, maps:get(<<"scope">>, Payload))
        end, ArgumentsExpections).

post_process_token_payload(Audience, Scopes) ->
    Jwk = ?UTIL_MOD:fixture_jwk(),
    Token = maps:put(<<"aud">>, Audience, ?UTIL_MOD:fixture_token_with_scopes(Scopes)),
    {_, EncodedToken} = ?UTIL_MOD:sign_token_hs(Token, Jwk),
    {true, Payload} = uaa_jwt_jwt:decode_and_verify(Jwk, EncodedToken),
    rabbit_auth_backend_oauth2:post_process_payload(Payload).

test_post_process_token_payload_keycloak(_) ->
    Pairs = [
        %% common case
        {
          #{<<"permissions">> =>
                [#{<<"rsid">> => <<"2c390fe4-02ad-41c7-98a2-cebb8c60ccf1">>,
                   <<"rsname">> => <<"allvhost">>,
                   <<"scopes">> => [<<"rabbitmq-resource.read:*/*">>]},
                 #{<<"rsid">> => <<"e7f12e94-4c34-43d8-b2b1-c516af644cee">>,
                   <<"rsname">> => <<"vhost1">>,
                   <<"scopes">> => [<<"rabbitmq-resource-read">>]},
                 #{<<"rsid">> => <<"12ac3d1c-28c2-4521-8e33-0952eff10bd9">>,
                   <<"rsname">> => <<"Default Resource">>}]},
          [<<"rabbitmq-resource.read:*/*">>, <<"rabbitmq-resource-read">>]
        },

        %% one scopes field with a string instead of an array
        {
          #{<<"permissions">> =>
                [#{<<"rsid">> => <<"2c390fe4-02ad-41c7-98a2-cebb8c60ccf1">>,
                   <<"rsname">> => <<"allvhost">>,
                   <<"scopes">> => <<"rabbitmq-resource.read:*/*">>},
                 #{<<"rsid">> => <<"e7f12e94-4c34-43d8-b2b1-c516af644cee">>,
                   <<"rsname">> => <<"vhost1">>,
                   <<"scopes">> => [<<"rabbitmq-resource-read">>]},
                 #{<<"rsid">> => <<"12ac3d1c-28c2-4521-8e33-0952eff10bd9">>,
                   <<"rsname">> => <<"Default Resource">>}]},
          [<<"rabbitmq-resource.read:*/*">>, <<"rabbitmq-resource-read">>]
        },

        %% no scopes field in permissions
        {
          #{<<"permissions">> =>
                [#{<<"rsid">> => <<"2c390fe4-02ad-41c7-98a2-cebb8c60ccf1">>,
                   <<"rsname">> => <<"allvhost">>},
                 #{<<"rsid">> => <<"e7f12e94-4c34-43d8-b2b1-c516af644cee">>,
                   <<"rsname">> => <<"vhost1">>},
                 #{<<"rsid">> => <<"12ac3d1c-28c2-4521-8e33-0952eff10bd9">>,
                   <<"rsname">> => <<"Default Resource">>}]},
          []
        },

        %% no permissions
        {
          #{<<"permissions">> => []},
          []
        },
        %% missing permissions key
        {#{}, []}
    ],
    lists:foreach(
        fun({Authorization, ExpectedScope}) ->
            Payload = post_process_payload_with_keycloak_authorization(Authorization),
            ?assertEqual(ExpectedScope, maps:get(<<"scope">>, Payload))
        end, Pairs).

post_process_payload_with_keycloak_authorization(Authorization) ->
    Jwk = ?UTIL_MOD:fixture_jwk(),
    Token = maps:put(<<"authorization">>, Authorization, ?UTIL_MOD:fixture_token_with_scopes([])),
    {_, EncodedToken} = ?UTIL_MOD:sign_token_hs(Token, Jwk),
    {true, Payload} = uaa_jwt_jwt:decode_and_verify(Jwk, EncodedToken),
    rabbit_auth_backend_oauth2:post_process_payload(Payload).



test_post_process_token_payload_complex_claims(_) ->
    Pairs = [
        %% claims in form of binary
        {
          <<"rabbitmq.rabbitmq-resource.read:*/* rabbitmq.rabbitmq-resource-read">>,
          [<<"rabbitmq.rabbitmq-resource.read:*/*">>, <<"rabbitmq.rabbitmq-resource-read">>]
        },
        %% claims in form of binary - empty result
        {<<>>, []},
        %% claims in form of list
        {
          [<<"rabbitmq.rabbitmq-resource.read:*/*">>,
           <<"rabbitmq2.rabbitmq-resource-read">>],
          [<<"rabbitmq.rabbitmq-resource.read:*/*">>, <<"rabbitmq2.rabbitmq-resource-read">>]
        },
        %% claims in form of list - empty result
        {[], []},
        %% claims are map with list content
        {
          #{<<"rabbitmq">> =>
                [<<"rabbitmq-resource.read:*/*">>,
                 <<"rabbitmq-resource-read">>],
            <<"rabbitmq3">> =>
                [<<"rabbitmq-resource.write:*/*">>,
                 <<"rabbitmq-resource-write">>]},
          [<<"rabbitmq.rabbitmq-resource.read:*/*">>, <<"rabbitmq.rabbitmq-resource-read">>]
        },
        %% claims are map with list content - empty result
        {
          #{<<"rabbitmq2">> =>
                 [<<"rabbitmq-resource.read:*/*">>,
                  <<"rabbitmq-resource-read">>]},
          []
        },
        %% claims are map with binary content
        {
          #{<<"rabbitmq">> => <<"rabbitmq-resource.read:*/* rabbitmq-resource-read">>,
           <<"rabbitmq3">> => <<"rabbitmq-resource.write:*/* rabbitmq-resource-write">>},
          [<<"rabbitmq.rabbitmq-resource.read:*/*">>, <<"rabbitmq.rabbitmq-resource-read">>]
        },
        %% claims are map with binary content - empty result
        {
          #{<<"rabbitmq2">> => <<"rabbitmq-resource.read:*/* rabbitmq-resource-read">>}, []
        },
        %% claims are map with empty binary content - empty result
        {
          #{<<"rabbitmq">> => <<>>}, []
        },
        %% claims are map with empty list content - empty result
        {
          #{<<"rabbitmq">> => []}, []
        },
        %% no extra claims provided
        {[], []},
        %% no extra claims provided
        {#{}, []}
    ],
    lists:foreach(
        fun({Authorization, ExpectedScope}) ->
            Payload = post_process_payload_with_complex_claim_authorization(Authorization),
            ?assertEqual(ExpectedScope, maps:get(<<"scope">>, Payload))
        end, Pairs).

post_process_payload_with_complex_claim_authorization(Authorization) ->
    Jwk = ?UTIL_MOD:fixture_jwk(),
    Token =  maps:put(<<"additional_rabbitmq_scopes">>, Authorization, ?UTIL_MOD:fixture_token_with_scopes([])),
    {_, EncodedToken} = ?UTIL_MOD:sign_token_hs(Token, Jwk),
    {true, Payload} = uaa_jwt_jwt:decode_and_verify(Jwk, EncodedToken),
    rabbit_auth_backend_oauth2:post_process_payload(Payload).

test_successful_access_with_a_token(_) ->
    %% Generate a token with JOSE
    %% Check authorization with the token
    %% Check user access granted by token
    Jwk = ?UTIL_MOD:fixture_jwk(),
    UaaEnv = [{signing_keys, #{<<"token-key">> => {map, Jwk}}}],
    application:set_env(rabbitmq_auth_backend_oauth2, key_config, UaaEnv),
    application:set_env(rabbitmq_auth_backend_oauth2, resource_server_id, <<"rabbitmq">>),

    VHost    = <<"vhost">>,
    Username = <<"username">>,
    Token    = ?UTIL_MOD:sign_token_hs(?UTIL_MOD:fixture_token(), Jwk),

    {ok, #auth_user{username = Username} = User} =
        rabbit_auth_backend_oauth2:user_login_authentication(Username, [{password, Token}]),
    {ok, #auth_user{username = Username} = User} =
        rabbit_auth_backend_oauth2:user_login_authentication(Username, #{password => Token}),

    ?assertEqual(true, rabbit_auth_backend_oauth2:check_vhost_access(User, <<"vhost">>, none)),
    assert_resource_access_granted(User, VHost, <<"foo">>, configure),
    assert_resource_access_granted(User, VHost, <<"foo">>, write),
    assert_resource_access_granted(User, VHost, <<"bar">>, read),
    assert_resource_access_granted(User, VHost, custom, <<"bar">>, read),

    assert_topic_access_granted(User, VHost, <<"bar">>, read, #{routing_key => <<"#/foo">>}).

test_successful_access_with_a_token_that_has_tag_scopes(_) ->
    Jwk = ?UTIL_MOD:fixture_jwk(),
    UaaEnv = [{signing_keys, #{<<"token-key">> => {map, Jwk}}}],
    application:set_env(rabbitmq_auth_backend_oauth2, key_config, UaaEnv),
    application:set_env(rabbitmq_auth_backend_oauth2, resource_server_id, <<"rabbitmq">>),
    Username = <<"username">>,
    Token    = ?UTIL_MOD:sign_token_hs(?UTIL_MOD:fixture_token([<<"rabbitmq.tag:management">>,
                                                                <<"rabbitmq.tag:policymaker">>]), Jwk),

    {ok, #auth_user{username = Username, tags = [management, policymaker]}} =
        rabbit_auth_backend_oauth2:user_login_authentication(Username, [{password, Token}]).

test_successful_access_with_a_token_that_uses_single_scope_alias_in_scope_field(_) ->
    Jwk = ?UTIL_MOD:fixture_jwk(),
    UaaEnv = [{signing_keys, #{<<"token-key">> => {map, Jwk}}}],
    application:set_env(rabbitmq_auth_backend_oauth2, key_config, UaaEnv),
    application:set_env(rabbitmq_auth_backend_oauth2, resource_server_id, <<"rabbitmq">>),
    Alias = <<"client-alias-1">>,
    application:set_env(rabbitmq_auth_backend_oauth2, scope_aliases, #{
        Alias => [
            <<"rabbitmq.configure:vhost/one">>,
            <<"rabbitmq.write:vhost/two">>,
            <<"rabbitmq.read:vhost/one">>,
            <<"rabbitmq.read:vhost/two">>,
            <<"rabbitmq.read:vhost/two/abc">>,
            <<"rabbitmq.tag:management">>,
            <<"rabbitmq.tag:custom">>
        ]
    }),

    VHost = <<"vhost">>,
    Username = <<"username">>,
    Token    = ?UTIL_MOD:sign_token_hs(?UTIL_MOD:token_with_scope_alias_in_scope_field(Alias), Jwk),

    {ok, #auth_user{username = Username, tags = [custom, management]} = AuthUser} =
        rabbit_auth_backend_oauth2:user_login_authentication(Username, [{password, Token}]),
    assert_vhost_access_granted(AuthUser, VHost),
    assert_vhost_access_denied(AuthUser, <<"some-other-vhost">>),

    assert_resource_access_granted(AuthUser, VHost, <<"one">>, configure),
    assert_resource_access_granted(AuthUser, VHost, <<"one">>, read),
    assert_resource_access_granted(AuthUser, VHost, <<"two">>, read),
    assert_resource_access_granted(AuthUser, VHost, <<"two">>, write),
    assert_resource_access_denied(AuthUser, VHost, <<"three">>, configure),
    assert_resource_access_denied(AuthUser, VHost, <<"three">>, read),
    assert_resource_access_denied(AuthUser, VHost, <<"three">>, write),

    application:unset_env(rabbitmq_auth_backend_oauth2, scope_aliases),
    application:unset_env(rabbitmq_auth_backend_oauth2, key_config),
    application:unset_env(rabbitmq_auth_backend_oauth2, resource_server_id).

test_successful_access_with_a_token_that_uses_multiple_scope_aliases_in_scope_field(_) ->
    Jwk = ?UTIL_MOD:fixture_jwk(),
    UaaEnv = [{signing_keys, #{<<"token-key">> => {map, Jwk}}}],
    application:set_env(rabbitmq_auth_backend_oauth2, key_config, UaaEnv),
    application:set_env(rabbitmq_auth_backend_oauth2, resource_server_id, <<"rabbitmq">>),
    Role1 = <<"client-aliases-1">>,
    Role2 = <<"client-aliases-2">>,
    Role3 = <<"client-aliases-3">>,
    application:set_env(rabbitmq_auth_backend_oauth2, scope_aliases, #{
        Role1 => [
            <<"rabbitmq.configure:vhost/one">>,
            <<"rabbitmq.tag:management">>
        ],
        Role2 => [
            <<"rabbitmq.write:vhost/two">>
        ],
        Role3 => [
            <<"rabbitmq.read:vhost/one">>,
            <<"rabbitmq.read:vhost/two">>,
            <<"rabbitmq.read:vhost/two/abc">>,
            <<"rabbitmq.tag:custom">>
        ]
    }),

    VHost = <<"vhost">>,
    Username = <<"username">>,
    Token    = ?UTIL_MOD:sign_token_hs(?UTIL_MOD:token_with_scope_alias_in_scope_field([Role1, Role2, Role3]), Jwk),

    {ok, #auth_user{username = Username, tags = [custom, management]} = AuthUser} =
        rabbit_auth_backend_oauth2:user_login_authentication(Username, [{password, Token}]),
    assert_vhost_access_granted(AuthUser, VHost),
    assert_vhost_access_denied(AuthUser, <<"some-other-vhost">>),

    assert_resource_access_granted(AuthUser, VHost, <<"one">>, configure),
    assert_resource_access_granted(AuthUser, VHost, <<"one">>, read),
    assert_resource_access_granted(AuthUser, VHost, <<"two">>, read),
    assert_resource_access_granted(AuthUser, VHost, <<"two">>, write),
    assert_resource_access_denied(AuthUser, VHost, <<"three">>, configure),
    assert_resource_access_denied(AuthUser, VHost, <<"three">>, read),
    assert_resource_access_denied(AuthUser, VHost, <<"three">>, write),

    application:unset_env(rabbitmq_auth_backend_oauth2, scope_aliases),
    application:unset_env(rabbitmq_auth_backend_oauth2, key_config),
    application:unset_env(rabbitmq_auth_backend_oauth2, resource_server_id).

test_unsuccessful_access_with_a_token_that_uses_missing_scope_alias_in_scope_field(_) ->
    Jwk = ?UTIL_MOD:fixture_jwk(),
    UaaEnv = [{signing_keys, #{<<"token-key">> => {map, Jwk}}}],
    application:set_env(rabbitmq_auth_backend_oauth2, key_config, UaaEnv),
    application:set_env(rabbitmq_auth_backend_oauth2, resource_server_id, <<"rabbitmq">>),
    Alias = <<"client-alias-33">>,
    application:set_env(rabbitmq_auth_backend_oauth2, scope_aliases, #{
        <<"non-existent-alias-23948sdkfjsdof8">> => [
            <<"rabbitmq.configure:vhost/one">>,
            <<"rabbitmq.write:vhost/two">>,
            <<"rabbitmq.read:vhost/one">>,
            <<"rabbitmq.read:vhost/two">>,
            <<"rabbitmq.read:vhost/two/abc">>
        ]
    }),

    VHost = <<"vhost">>,
    Username = <<"username">>,
    Token    = ?UTIL_MOD:sign_token_hs(?UTIL_MOD:token_with_scope_alias_in_scope_field(Alias), Jwk),

    {ok, AuthUser} = rabbit_auth_backend_oauth2:user_login_authentication(Username, [{password, Token}]),
    assert_vhost_access_denied(AuthUser, VHost),
    assert_vhost_access_denied(AuthUser, <<"some-other-vhost">>),

    assert_resource_access_denied(AuthUser, VHost, <<"one">>, configure),
    assert_resource_access_denied(AuthUser, VHost, <<"one">>, read),
    assert_resource_access_denied(AuthUser, VHost, <<"two">>, read),
    assert_resource_access_denied(AuthUser, VHost, <<"two">>, write),
    assert_resource_access_denied(AuthUser, VHost, <<"three">>, configure),
    assert_resource_access_denied(AuthUser, VHost, <<"three">>, read),
    assert_resource_access_denied(AuthUser, VHost, <<"three">>, write),

    application:unset_env(rabbitmq_auth_backend_oauth2, scope_aliases),
    application:unset_env(rabbitmq_auth_backend_oauth2, key_config),
    application:unset_env(rabbitmq_auth_backend_oauth2, resource_server_id).

test_successful_access_with_a_token_that_uses_single_scope_alias_in_extra_scope_source_field(_) ->
    Jwk = ?UTIL_MOD:fixture_jwk(),
    UaaEnv = [{signing_keys, #{<<"token-key">> => {map, Jwk}}}],
    application:set_env(rabbitmq_auth_backend_oauth2, key_config, UaaEnv),
    application:set_env(rabbitmq_auth_backend_oauth2, extra_scopes_source, <<"claims">>),
    application:set_env(rabbitmq_auth_backend_oauth2, resource_server_id, <<"rabbitmq">>),
    Alias = <<"client-alias-1">>,
    application:set_env(rabbitmq_auth_backend_oauth2, scope_aliases, #{
        Alias => [
            <<"rabbitmq.configure:vhost/one">>,
            <<"rabbitmq.write:vhost/two">>,
            <<"rabbitmq.read:vhost/one">>,
            <<"rabbitmq.read:vhost/two">>,
            <<"rabbitmq.read:vhost/two/abc">>
        ]
    }),

    VHost = <<"vhost">>,
    Username = <<"username">>,
    Token    = ?UTIL_MOD:sign_token_hs(?UTIL_MOD:token_with_scope_alias_in_claim_field(Alias, [<<"unrelated">>]), Jwk),

    {ok, AuthUser} = rabbit_auth_backend_oauth2:user_login_authentication(Username, [{password, Token}]),
    assert_vhost_access_granted(AuthUser, VHost),
    assert_vhost_access_denied(AuthUser, <<"some-other-vhost">>),

    assert_resource_access_granted(AuthUser, VHost, <<"one">>, configure),
    assert_resource_access_granted(AuthUser, VHost, <<"one">>, read),
    assert_resource_access_granted(AuthUser, VHost, <<"two">>, read),
    assert_resource_access_granted(AuthUser, VHost, <<"two">>, write),
    assert_resource_access_denied(AuthUser, VHost, <<"three">>, configure),
    assert_resource_access_denied(AuthUser, VHost, <<"three">>, read),
    assert_resource_access_denied(AuthUser, VHost, <<"three">>, write),

    application:unset_env(rabbitmq_auth_backend_oauth2, scope_aliases),
    application:unset_env(rabbitmq_auth_backend_oauth2, key_config),
    application:unset_env(rabbitmq_auth_backend_oauth2, resource_server_id).

test_successful_access_with_a_token_that_uses_multiple_scope_aliases_in_extra_scope_source_field(_) ->
    Jwk = ?UTIL_MOD:fixture_jwk(),
    UaaEnv = [{signing_keys, #{<<"token-key">> => {map, Jwk}}}],
    application:set_env(rabbitmq_auth_backend_oauth2, key_config, UaaEnv),
    application:set_env(rabbitmq_auth_backend_oauth2, extra_scopes_source, <<"claims">>),
    application:set_env(rabbitmq_auth_backend_oauth2, resource_server_id, <<"rabbitmq">>),
    Role1 = <<"client-aliases-1">>,
    Role2 = <<"client-aliases-2">>,
    Role3 = <<"client-aliases-3">>,
    application:set_env(rabbitmq_auth_backend_oauth2, scope_aliases, #{
        Role1 => [
            <<"rabbitmq.configure:vhost/one">>
        ],
        Role2 => [
            <<"rabbitmq.write:vhost/two">>
        ],
        Role3 => [
            <<"rabbitmq.read:vhost/one">>,
            <<"rabbitmq.read:vhost/two">>,
            <<"rabbitmq.read:vhost/two/abc">>
        ]
    }),

    VHost = <<"vhost">>,
    Username = <<"username">>,
    Claims   = [Role1, Role2, Role3],
    Token    = ?UTIL_MOD:sign_token_hs(?UTIL_MOD:token_with_scope_alias_in_claim_field(Claims, [<<"unrelated">>]), Jwk),

    {ok, AuthUser} = rabbit_auth_backend_oauth2:user_login_authentication(Username, [{password, Token}]),
    assert_vhost_access_granted(AuthUser, VHost),
    assert_vhost_access_denied(AuthUser, <<"some-other-vhost">>),

    assert_resource_access_granted(AuthUser, VHost, <<"one">>, configure),
    assert_resource_access_granted(AuthUser, VHost, <<"one">>, read),
    assert_resource_access_granted(AuthUser, VHost, <<"two">>, read),
    assert_resource_access_granted(AuthUser, VHost, <<"two">>, write),
    assert_resource_access_denied(AuthUser, VHost, <<"three">>, configure),
    assert_resource_access_denied(AuthUser, VHost, <<"three">>, read),
    assert_resource_access_denied(AuthUser, VHost, <<"three">>, write),

    application:unset_env(rabbitmq_auth_backend_oauth2, scope_aliases),
    application:unset_env(rabbitmq_auth_backend_oauth2, key_config),
    application:unset_env(rabbitmq_auth_backend_oauth2, resource_server_id).

test_unsuccessful_access_with_a_token_that_uses_missing_scope_alias_in_extra_scope_source_field(_) ->
    Jwk = ?UTIL_MOD:fixture_jwk(),
    UaaEnv = [{signing_keys, #{<<"token-key">> => {map, Jwk}}}],
    application:set_env(rabbitmq_auth_backend_oauth2, key_config, UaaEnv),
    application:set_env(rabbitmq_auth_backend_oauth2, extra_scopes_source, <<"claims">>),
    application:set_env(rabbitmq_auth_backend_oauth2, resource_server_id, <<"rabbitmq">>),
    Alias = <<"client-alias-11">>,
    application:set_env(rabbitmq_auth_backend_oauth2, scope_aliases, #{
        <<"non-existent-client-alias-9238923789">> => [
            <<"rabbitmq.configure:vhost/one">>,
            <<"rabbitmq.write:vhost/two">>,
            <<"rabbitmq.read:vhost/one">>,
            <<"rabbitmq.read:vhost/two">>,
            <<"rabbitmq.read:vhost/two/abc">>
        ]
    }),

    VHost = <<"vhost">>,
    Username = <<"username">>,
    Token    = ?UTIL_MOD:sign_token_hs(?UTIL_MOD:token_with_scope_alias_in_claim_field(Alias, [<<"unrelated">>]), Jwk),

    {ok, AuthUser} = rabbit_auth_backend_oauth2:user_login_authentication(Username, [{password, Token}]),
    assert_vhost_access_denied(AuthUser, VHost),
    assert_vhost_access_denied(AuthUser, <<"some-other-vhost">>),

    assert_resource_access_denied(AuthUser, VHost, <<"one">>, configure),
    assert_resource_access_denied(AuthUser, VHost, <<"one">>, read),
    assert_resource_access_denied(AuthUser, VHost, <<"two">>, read),
    assert_resource_access_denied(AuthUser, VHost, <<"two">>, write),
    assert_resource_access_denied(AuthUser, VHost, <<"three">>, configure),
    assert_resource_access_denied(AuthUser, VHost, <<"three">>, read),
    assert_resource_access_denied(AuthUser, VHost, <<"three">>, write),

    application:unset_env(rabbitmq_auth_backend_oauth2, scope_aliases),
    application:unset_env(rabbitmq_auth_backend_oauth2, key_config),
    application:unset_env(rabbitmq_auth_backend_oauth2, resource_server_id).

test_unsuccessful_access_with_a_bogus_token(_) ->
    Username = <<"username">>,
    application:set_env(rabbitmq_auth_backend_oauth2, resource_server_id, <<"rabbitmq">>),

    Jwk0 = ?UTIL_MOD:fixture_jwk(),
    Jwk  = Jwk0#{<<"k">> => <<"bm90b2tlbmtleQ">>},
    UaaEnv = [{signing_keys, #{<<"token-key">> => {map, Jwk}}}],
    application:set_env(rabbitmq_auth_backend_oauth2, key_config, UaaEnv),

    ?assertMatch({refused, _, _},
                 rabbit_auth_backend_oauth2:user_login_authentication(Username, [{password, <<"not a token">>}])).

test_restricted_vhost_access_with_a_valid_token(_) ->
    Username = <<"username">>,
    application:set_env(rabbitmq_auth_backend_oauth2, resource_server_id, <<"rabbitmq">>),

    Jwk   = ?UTIL_MOD:fixture_jwk(),
    Token = ?UTIL_MOD:sign_token_hs(?UTIL_MOD:fixture_token(), Jwk),
    UaaEnv = [{signing_keys, #{<<"token-key">> => {map, Jwk}}}],
    application:set_env(rabbitmq_auth_backend_oauth2, key_config, UaaEnv),

    %% this user can authenticate successfully and access certain vhosts
    {ok, #auth_user{username = Username, tags = []} = User} =
        rabbit_auth_backend_oauth2:user_login_authentication(Username, [{password, Token}]),

    %% access to a different vhost
    ?assertEqual(false, rabbit_auth_backend_oauth2:check_vhost_access(User, <<"different vhost">>, none)).

test_insufficient_permissions_in_a_valid_token(_) ->
    VHost = <<"vhost">>,
    Username = <<"username">>,
    application:set_env(rabbitmq_auth_backend_oauth2, resource_server_id, <<"rabbitmq">>),

    Jwk   = ?UTIL_MOD:fixture_jwk(),
    Token = ?UTIL_MOD:sign_token_hs(?UTIL_MOD:fixture_token(), Jwk),
    UaaEnv = [{signing_keys, #{<<"token-key">> => {map, Jwk}}}],
    application:set_env(rabbitmq_auth_backend_oauth2, key_config, UaaEnv),

    {ok, #auth_user{username = Username} = User} =
        rabbit_auth_backend_oauth2:user_login_authentication(Username, [{password, Token}]),

    %% access to these resources is not granted
    assert_resource_access_denied(User, VHost, <<"foo1">>, configure),
    assert_resource_access_denied(User, VHost, <<"bar">>, write),
    assert_topic_access_refused(User, VHost, <<"bar">>, read, #{routing_key => <<"foo/#">>}).

test_token_expiration(_) ->
    VHost = <<"vhost">>,
    Username = <<"username">>,
    Jwk = ?UTIL_MOD:fixture_jwk(),
    UaaEnv = [{signing_keys, #{<<"token-key">> => {map, Jwk}}}],
    application:set_env(rabbitmq_auth_backend_oauth2, key_config, UaaEnv),
    application:set_env(rabbitmq_auth_backend_oauth2, resource_server_id, <<"rabbitmq">>),
    TokenData = ?UTIL_MOD:expirable_token(),
    Username  = <<"username">>,
    Token     = ?UTIL_MOD:sign_token_hs(TokenData, Jwk),
    {ok, #auth_user{username = Username} = User} =
        rabbit_auth_backend_oauth2:user_login_authentication(Username, [{password, Token}]),

    assert_resource_access_granted(User, VHost, <<"foo">>, configure),
    assert_resource_access_granted(User, VHost, <<"foo">>, write),

    ?UTIL_MOD:wait_for_token_to_expire(),
    #{<<"exp">> := Exp} = TokenData,
    ExpectedError = "Provided JWT token has expired at timestamp " ++ integer_to_list(Exp) ++ " (validated at " ++ integer_to_list(Exp) ++ ")",
    assert_resource_access_errors(ExpectedError, User, VHost, <<"foo">>, configure),

    ?assertMatch({refused, _, _},
                 rabbit_auth_backend_oauth2:user_login_authentication(Username, [{password, Token}])).

test_incorrect_kid(_) ->
    AltKid   = <<"other-token-key">>,
    Username = <<"username">>,
    Jwk      = ?UTIL_MOD:fixture_jwk(),
    Jwk1     = Jwk#{<<"kid">> := AltKid},
    application:set_env(rabbitmq_auth_backend_oauth2, resource_server_id, <<"rabbitmq">>),
    Token = ?UTIL_MOD:sign_token_hs(?UTIL_MOD:fixture_token(), Jwk1),

    ?assertMatch({refused, "Authentication using an OAuth 2/JWT token failed: ~p", [{error,key_not_found}]},
                 rabbit_auth_backend_oauth2:user_login_authentication(Username, #{password => Token})).

test_command_json(_) ->
    Username = <<"username">>,
    Jwk      = ?UTIL_MOD:fixture_jwk(),
    Json     = rabbit_json:encode(Jwk),
    'Elixir.RabbitMQ.CLI.Ctl.Commands.AddUaaKeyCommand':run(
        [<<"token-key">>],
        #{node => node(), json => Json}),
    application:set_env(rabbitmq_auth_backend_oauth2, resource_server_id, <<"rabbitmq">>),
    Token = ?UTIL_MOD:sign_token_hs(?UTIL_MOD:fixture_token(), Jwk),
    {ok, #auth_user{username = Username} = User} =
        rabbit_auth_backend_oauth2:user_login_authentication(Username, #{password => Token}),

    ?assertEqual(true, rabbit_auth_backend_oauth2:check_vhost_access(User, <<"vhost">>, none)).

test_command_pem_file(Config) ->
    Username = <<"username">>,
    application:set_env(rabbitmq_auth_backend_oauth2, resource_server_id, <<"rabbitmq">>),
    CertsDir = ?config(rmq_certsdir, Config),
    Keyfile = filename:join([CertsDir, "client", "key.pem"]),
    Jwk = jose_jwk:from_pem_file(Keyfile),

    PublicJwk  = jose_jwk:to_public(Jwk),
    PublicKeyFile = filename:join([CertsDir, "client", "public.pem"]),
    jose_jwk:to_pem_file(PublicKeyFile, PublicJwk),

    'Elixir.RabbitMQ.CLI.Ctl.Commands.AddUaaKeyCommand':run(
        [<<"token-key">>],
        #{node => node(), pem_file => PublicKeyFile}),

    Token = ?UTIL_MOD:sign_token_rsa(?UTIL_MOD:fixture_token(), Jwk, <<"token-key">>),
    {ok, #auth_user{username = Username} = User} =
        rabbit_auth_backend_oauth2:user_login_authentication(Username, #{password => Token}),

    ?assertEqual(true, rabbit_auth_backend_oauth2:check_vhost_access(User, <<"vhost">>, none)).


test_command_pem_file_no_kid(Config) ->
    Username = <<"username">>,
    application:set_env(rabbitmq_auth_backend_oauth2, resource_server_id, <<"rabbitmq">>),
    CertsDir = ?config(rmq_certsdir, Config),
    Keyfile = filename:join([CertsDir, "client", "key.pem"]),
    Jwk = jose_jwk:from_pem_file(Keyfile),

    PublicJwk  = jose_jwk:to_public(Jwk),
    PublicKeyFile = filename:join([CertsDir, "client", "public.pem"]),
    jose_jwk:to_pem_file(PublicKeyFile, PublicJwk),

    'Elixir.RabbitMQ.CLI.Ctl.Commands.AddUaaKeyCommand':run(
        [<<"token-key">>],
        #{node => node(), pem_file => PublicKeyFile}),

    %% Set default key
    {ok, UaaEnv0} = application:get_env(rabbitmq_auth_backend_oauth2, key_config),
    UaaEnv1 = proplists:delete(default_key, UaaEnv0),
    UaaEnv2 = [{default_key, <<"token-key">>} | UaaEnv1],
    application:set_env(rabbitmq_auth_backend_oauth2, key_config, UaaEnv2),

    Token = ?UTIL_MOD:sign_token_no_kid(?UTIL_MOD:fixture_token(), Jwk),
    {ok, #auth_user{username = Username} = User} =
        rabbit_auth_backend_oauth2:user_login_authentication(Username, #{password => Token}),

    ?assertEqual(true, rabbit_auth_backend_oauth2:check_vhost_access(User, <<"vhost">>, none)).

test_command_pem(Config) ->
    Username = <<"username">>,
    application:set_env(rabbitmq_auth_backend_oauth2, resource_server_id, <<"rabbitmq">>),
    CertsDir = ?config(rmq_certsdir, Config),
    Keyfile = filename:join([CertsDir, "client", "key.pem"]),
    Jwk = jose_jwk:from_pem_file(Keyfile),

    Pem = jose_jwk:to_pem(jose_jwk:to_public(Jwk)),

    'Elixir.RabbitMQ.CLI.Ctl.Commands.AddUaaKeyCommand':run(
        [<<"token-key">>],
        #{node => node(), pem => Pem}),

    Token = ?UTIL_MOD:sign_token_rsa(?UTIL_MOD:fixture_token(), Jwk, <<"token-key">>),
    {ok, #auth_user{username = Username} = User} =
        rabbit_auth_backend_oauth2:user_login_authentication(Username, #{password => Token}),

    ?assertEqual(true, rabbit_auth_backend_oauth2:check_vhost_access(User, <<"vhost">>, none)).


test_command_pem_no_kid(Config) ->
    Username = <<"username">>,
    application:set_env(rabbitmq_auth_backend_oauth2, resource_server_id, <<"rabbitmq">>),
    CertsDir = ?config(rmq_certsdir, Config),
    Keyfile = filename:join([CertsDir, "client", "key.pem"]),
    Jwk = jose_jwk:from_pem_file(Keyfile),

    Pem = jose_jwk:to_pem(jose_jwk:to_public(Jwk)),

    'Elixir.RabbitMQ.CLI.Ctl.Commands.AddUaaKeyCommand':run(
        [<<"token-key">>],
        #{node => node(), pem => Pem}),

    %% This is the default key
    {ok, UaaEnv0} = application:get_env(rabbitmq_auth_backend_oauth2, key_config),
    UaaEnv1 = proplists:delete(default_key, UaaEnv0),
    UaaEnv2 = [{default_key, <<"token-key">>} | UaaEnv1],
    application:set_env(rabbitmq_auth_backend_oauth2, key_config, UaaEnv2),

    Token = ?UTIL_MOD:sign_token_no_kid(?UTIL_MOD:fixture_token(), Jwk),
    {ok, #auth_user{username = Username} = User} =
        rabbit_auth_backend_oauth2:user_login_authentication(Username, #{password => Token}),

    ?assertEqual(true, rabbit_auth_backend_oauth2:check_vhost_access(User, <<"vhost">>, none)).


test_own_scope(_) ->
    Examples = [
        {<<"foo">>, [<<"foo">>, <<"foo.bar">>, <<"bar.foo">>,
                     <<"one.two">>, <<"foobar">>, <<"foo.other.third">>],
                    [<<"bar">>, <<"other.third">>]},
        {<<"foo">>, [], []},
        {<<"foo">>, [<<"foo">>, <<"other.foo.bar">>], []},
        {<<"">>, [<<"foo">>, <<"bar">>], [<<"foo">>, <<"bar">>]}
    ],
    lists:map(
        fun({ResId, Src, Dest}) ->
            Dest = rabbit_auth_backend_oauth2:filter_scopes(Src, ResId)
        end,
        Examples).

test_validate_payload_resource_server_id_mismatch(_) ->
    NoKnownResourceServerId = #{<<"aud">>   => [<<"foo">>, <<"bar">>],
                                <<"scope">> => [<<"foo">>, <<"foo.bar">>,
                                                <<"bar.foo">>, <<"one.two">>,
                                                <<"foobar">>, <<"foo.other.third">>]},
    EmptyAud = #{<<"aud">>   => [],
                 <<"scope">> => [<<"foo.bar">>, <<"bar.foo">>]},

    ?assertEqual({refused, {invalid_aud, {resource_id_not_found_in_aud, ?RESOURCE_SERVER_ID,
                                          [<<"foo">>,<<"bar">>]}}},
                 rabbit_auth_backend_oauth2:validate_payload(NoKnownResourceServerId, ?RESOURCE_SERVER_ID)),

    ?assertEqual({refused, {invalid_aud, {resource_id_not_found_in_aud, ?RESOURCE_SERVER_ID, []}}},
                 rabbit_auth_backend_oauth2:validate_payload(EmptyAud, ?RESOURCE_SERVER_ID)).

test_validate_payload(_) ->
    KnownResourceServerId = #{<<"aud">>   => [?RESOURCE_SERVER_ID],
                              <<"scope">> => [<<"foo">>, <<"rabbitmq.bar">>,
                                              <<"bar.foo">>, <<"one.two">>,
                                              <<"foobar">>, <<"rabbitmq.other.third">>]},
    ?assertEqual({ok, #{<<"aud">>   => [?RESOURCE_SERVER_ID],
                        <<"scope">> => [<<"bar">>, <<"other.third">>]}},
                 rabbit_auth_backend_oauth2:validate_payload(KnownResourceServerId, ?RESOURCE_SERVER_ID)).


%%
%% Helpers
%%

assert_vhost_access_granted(AuthUser, VHost) ->
    assert_vhost_access_response(true, AuthUser, VHost).

assert_vhost_access_denied(AuthUser, VHost) ->
    assert_vhost_access_response(false, AuthUser, VHost).

assert_vhost_access_response(ExpectedResult, AuthUser, VHost) ->
    ?assertEqual(ExpectedResult,
        rabbit_auth_backend_oauth2:check_vhost_access(AuthUser, VHost, none)).

assert_resource_access_granted(AuthUser, VHost, ResourceName, PermissionKind) ->
        assert_resource_access_response(true, AuthUser, VHost, ResourceName, PermissionKind).

assert_resource_access_denied(AuthUser, VHost, ResourceName, PermissionKind) ->
        assert_resource_access_response(false, AuthUser, VHost, ResourceName, PermissionKind).

assert_resource_access_errors(ExpectedError, AuthUser, VHost, ResourceName, PermissionKind) ->
    assert_resource_access_response({error, ExpectedError}, AuthUser, VHost, ResourceName, PermissionKind).

assert_resource_access_response(ExpectedResult, AuthUser, VHost, ResourceName, PermissionKind) ->
    ?assertEqual(ExpectedResult,
            rabbit_auth_backend_oauth2:check_resource_access(
                          AuthUser,
                          rabbit_misc:r(VHost, queue, ResourceName),
                          PermissionKind, #{})).

assert_resource_access_granted(AuthUser, VHost, ResourceKind, ResourceName, PermissionKind) ->
        assert_resource_access_response(true, AuthUser, VHost, ResourceKind, ResourceName, PermissionKind).

assert_resource_access_denied(AuthUser, VHost, ResourceKind, ResourceName, PermissionKind) ->
        assert_resource_access_response(false, AuthUser, VHost, ResourceKind, ResourceName, PermissionKind).

assert_resource_access_errors(ExpectedError, AuthUser, VHost, ResourceKind, ResourceName, PermissionKind) ->
    assert_resource_access_response({error, ExpectedError}, AuthUser, VHost, ResourceKind, ResourceName, PermissionKind).

assert_resource_access_response(ExpectedResult, AuthUser, VHost, ResourceKind, ResourceName, PermissionKind) ->
    ?assertEqual(ExpectedResult,
            rabbit_auth_backend_oauth2:check_resource_access(
                          AuthUser,
                          rabbit_misc:r(VHost, ResourceKind, ResourceName),
                          PermissionKind, #{})).

assert_topic_access_granted(AuthUser, VHost, ResourceName, PermissionKind, AuthContext) ->
    assert_topic_access_response(true, AuthUser, VHost, ResourceName, PermissionKind, AuthContext).

assert_topic_access_refused(AuthUser, VHost, ResourceName, PermissionKind, AuthContext) ->
    assert_topic_access_response(false, AuthUser, VHost, ResourceName, PermissionKind, AuthContext).

assert_topic_access_response(ExpectedResult, AuthUser, VHost, ResourceName, PermissionKind, AuthContext) ->
        ?assertEqual(ExpectedResult, rabbit_auth_backend_oauth2:check_topic_access(
                         AuthUser,
                         #resource{virtual_host = VHost,
                                   kind = topic,
                                   name = ResourceName},
                         PermissionKind,
                         AuthContext)).
