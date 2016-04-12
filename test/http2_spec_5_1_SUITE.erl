-module(http2_spec_5_1_SUITE).

-include("http2.hrl").
-include_lib("eunit/include/eunit.hrl").
-include_lib("common_test/include/ct.hrl").
-compile([export_all]).

all() ->
    [
     sends_rst_stream_to_idle,
     half_closed_remote_sends_headers,
     sends_window_update_to_idle,
     client_sends_even_stream_id,
     exceeds_max_concurrent_streams
    ].

init_per_suite(Config) ->
    application:ensure_started(crypto),
    Config.


init_per_testcase(exceeds_max_concurrent_streams, Config) ->
    chatterbox_test_buddy:start(
      [
       {max_concurrent_streams, 10},
       {enable_push, 0}
       |Config]
     );
init_per_testcase(_, Config) ->
    chatterbox_test_buddy:start(Config).

end_per_testcase(_, Config) ->
    chatterbox_test_buddy:stop(Config),
    ok.

exceeds_max_concurrent_streams(Config) ->
    MaxConcurrent = ?config(max_concurrent_streams, Config),

    {ok, Client} = http2c:start_link(),
    RequestHeaders =
        [
         {<<":method">>, <<"GET">>},
         {<<":path">>, <<"/index.html">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>}
        ],

    StreamIds = lists:seq(1,MaxConcurrent*2,2),

    %% See Caine/Hackman Theory
    AStreamTooFar = 1 + MaxConcurrent*2,

    FinalEC =
        lists:foldl(
          fun(StreamId, EncodeContext) ->
                  {H1, NewEC} =
                      http2_frame_headers:to_frames(
                        StreamId,
                        RequestHeaders,
                        EncodeContext,
                        16384,
                        false),
                  http2c:send_unaltered_frames(Client, H1),
                  NewEC
          end,
          hpack:new_context(),
          StreamIds
         ),
    timer:sleep(100),
    %% Now Max Streams should be open, but let's make sure we haven't
    %% heard back from anyone

    Resp0 = http2c:get_frames(Client,0),
    ?assertEqual([], Resp0),
    [ begin
          Resp = http2c:get_frames(Client, StreamId),
          ?assertEqual([], Resp)
      end || StreamId <- StreamIds],

    %% Now, open AStreamTooFar

    {HFinal, _UnusedEC} =
        http2_frame_headers:to_frames(
          AStreamTooFar,
          RequestHeaders,
          FinalEC,
          16384,
          false),
    http2c:send_unaltered_frames(Client, HFinal),

    %% Response should be RST_STREAM ?REFUSED_STREAM

    Response = http2c:wait_for_n_frames(Client, AStreamTooFar, 1),
    ?assertEqual(1, length(Response)),
    [{RstH, RstP}] = Response,
    ?assertEqual(?RST_STREAM, RstH#frame_header.type),
    ?assertEqual(?REFUSED_STREAM, http2_frame_rst_stream:error_code(RstP)),
    ok.

sends_rst_stream_to_idle(_Config) ->
    {ok, Client} = http2c:start_link(),

    RstStream = http2_frame_rst_stream:new(?CANCEL),
    RstStreamBin = http2_frame:to_binary(
                     {#frame_header{
                         stream_id=1
                        },
                      RstStream}),

    http2c:send_binary(Client, RstStreamBin),

    Resp = http2c:wait_for_n_frames(Client, 0, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, length(Resp)),
    [{_GoAwayH, GoAway}] = Resp,
    ?assertEqual(?PROTOCOL_ERROR, http2_frame_goaway:error_code(GoAway)),
    ok.

half_closed_remote_sends_headers(_Config) ->
    {ok, Client} = http2c:start_link(),
    RequestHeaders =
        [
         {<<":method">>, <<"GET">>},
         {<<":path">>, <<"/index.html">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>}
        ],

    {H1, EC} =
        http2_frame_headers:to_frames(1,
                                      RequestHeaders,
                                      hpack:new_context(),
                                      16384,
                                      true),

    http2c:send_unaltered_frames(Client, H1),

    %% The stream should be half closed remote now

    {H2, _EC2} =
        http2_frame_headers:to_frames(1,
                                      RequestHeaders,
                                      EC,
                                      16384,
                                      true),


    http2c:send_unaltered_frames(Client, H2),

    Resp = http2c:wait_for_n_frames(Client, 1, 4),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(4, length(Resp)),
    [ {HeadersH, _}, {DataH, _}, {RstStreamH, RstStream}, _] = Resp,
    ?assertEqual(?HEADERS, HeadersH#frame_header.type),
    ?assertEqual(?DATA, DataH#frame_header.type),
    ?assertEqual(?RST_STREAM, RstStreamH#frame_header.type),
    ?assertEqual(?STREAM_CLOSED, http2_frame_rst_stream:error_code(RstStream)),
    ok.

sends_window_update_to_idle(_Config) ->
    {ok, Client} = http2c:start_link(),
    WUBin = http2_frame:to_binary(
                     {#frame_header{
                         stream_id=1
                        },
                      http2_frame_window_update:new(1)
                      }),

    http2c:send_binary(Client, WUBin),

    Resp = http2c:wait_for_n_frames(Client, 0, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, length(Resp)),
    [{GoAwayH, GoAway}] = Resp,
    ?assertEqual(?GOAWAY, GoAwayH#frame_header.type),
    ?assertEqual(?PROTOCOL_ERROR, http2_frame_goaway:error_code(GoAway)),
    ok.

client_sends_even_stream_id(_Config) ->
    {ok, Client} = http2c:start_link(),

    RequestHeaders =
        [
         {<<":method">>, <<"GET">>},
         {<<":path">>, <<"/index.html">>},
         {<<":scheme">>, <<"https">>},
         {<<":authority">>, <<"localhost:8080">>},
         {<<"accept">>, <<"*/*">>},
         {<<"accept-encoding">>, <<"gzip, deflate">>},
         {<<"user-agent">>, <<"chattercli/0.0.1 :D">>}
        ],

    {H, _} =
        http2_frame_headers:to_frames(2,
                                      RequestHeaders,
                                      hpack:new_context(),
                                      16384,
                                      false),

    http2c:send_unaltered_frames(Client, H),

    Resp = http2c:wait_for_n_frames(Client, 0, 1),
    ct:pal("Resp: ~p", [Resp]),
    ?assertEqual(1, length(Resp)),
    [{GoAwayH, GoAway}] = Resp,
    ?assertEqual(?GOAWAY, GoAwayH#frame_header.type),
    ?assertEqual(?PROTOCOL_ERROR, http2_frame_goaway:error_code(GoAway)),
    ok.
