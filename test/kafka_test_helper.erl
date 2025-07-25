-module(kafka_test_helper).

-export([ init_per_suite/1
        , common_init_per_testcase/3
        , common_end_per_testcase/2
        , produce/2
        , produce/3
        , produce/4
        , payloads/1
        , produce_payloads/3
        , create_topic/3
        , get_acked_offsets/1
        , check_committed_offsets/2
        , wait_n_messages/3
        , wait_n_messages/2
        , consumer_config/0
        , client_config/0
        , bootstrap_hosts/0
        , kill_process/2
        , kafka_version/0
        , increase_topic_partition/2
        , delete_topic/1
        ]).

-include("brod_test_macros.hrl").
-include_lib("snabbkaffe/include/snabbkaffe.hrl").

init_per_suite(Config) ->
  [ {proper_timeout, 10000}
  | Config].

common_init_per_testcase(Module, Case, Config) ->
  %% Create a client and a producer for putting test data to Kafka.
  %% By default name of the test topic is equal to the name of
  %% testcase.
  {ok, _} = application:ensure_all_started(brod),
  ok = brod:start_client(bootstrap_hosts(), ?TEST_CLIENT_ID, client_config()),
  Topics = try Module:Case(topics) of
               L -> L
           catch
             _:_ -> [{?topic(Case, 1), 1}]
           end,
  [prepare_topic(I) || I <- Topics],
  Config.

common_end_per_testcase(_Case, _Config) ->
  catch brod:stop_client(?TEST_CLIENT_ID),
  ok.

produce(TopicPartition, Value) ->
  produce(TopicPartition, <<>>, Value).

produce(TopicPartition, Key, Value) ->
  produce(TopicPartition, Key, Value, []).

produce({Topic, Partition}, Key, Value, Headers) ->
  ?tp(test_topic_produce, #{ topic     => Topic
                           , partition => Partition
                           , key       => Key
                           , value     => Value
                           , headers   => Headers
                           }),
  {ok, Offset} = brod:produce_sync_offset( ?TEST_CLIENT_ID
                                         , Topic
                                         , Partition
                                         , <<>>
                                         , [#{ value => Value
                                             , key => Key
                                             , headers => Headers
                                             }]
                                         ),
  ?log(notice, "Produced at ~p ~p, offset: ~p", [Topic, Partition, Offset]),
  Offset.

payloads(Config) ->
  MaxSeqNo = proplists:get_value(max_seqno, Config, 10),
  [<<I>> || I <- lists:seq(1, MaxSeqNo)].

%% Produce binaries to the topic and return offset of the last message:
produce_payloads(Topic, Partition, Config) ->
  Payloads = payloads(Config),
  ?log(notice, "Producing payloads to ~p", [{Topic, Partition}]),
  L = [produce({Topic, Partition}, I) + 1 || I <- payloads(Config)],
  LastOffset = lists:last(L),
  {LastOffset, Payloads}.

client_config() ->
  case kafka_version() of
    {0, 9} -> [{query_api_versions, false}];
    _      -> []
  end.

maybe_zookeeper() ->
  {Major, _} = kafka_version(),
  case Major >= 3 of
    true ->
      %% Kafka 2.2 started supporting --bootstap-server, but 2.x still supports --zookeeper
      %% Starting from 3.0, --zookeeper is no longer supported, must use --bootstrap-server
      "--bootstrap-server localhost:9092";
    false ->
      "--zookeeper " ++ env("ZOOKEEPER_IP") ++ ":2181"
  end.

kafka_version() ->
  VsnStr = env("KAFKA_VERSION"),
  [Major, Minor | _] = string:tokens(VsnStr, "."),
  {list_to_integer(Major), list_to_integer(Minor)}.

prepare_topic(Topic) when is_binary(Topic) ->
  prepare_topic({Topic, 1});
prepare_topic({Topic, NumPartitions}) ->
  prepare_topic({Topic, NumPartitions, 2});
prepare_topic({Topic, NumPartitions, NumReplicas}) ->
  delete_topic(Topic),
  0 = create_topic(Topic, NumPartitions, NumReplicas),
  ok = brod:start_producer(?TEST_CLIENT_ID, Topic, _ProducerConfig = []).

delete_topic(Name) ->
  Delete = "/opt/kafka/bin/kafka-topics.sh " ++ maybe_zookeeper() ++
    " --delete --topic ~s",
  exec_in_kafka_container(Delete, [Name]).

create_topic(Name, NumPartitions, NumReplicas) ->
  Create = "/opt/kafka/bin/kafka-topics.sh " ++ maybe_zookeeper() ++
    " --create --partitions ~p --replication-factor ~p"
    " --topic ~s --config min.insync.replicas=1",
  0 = exec_in_kafka_container(Create, [NumPartitions, NumReplicas, Name]),
  wait_for_topic_by_describe(Name).

increase_topic_partition(Name, NumPartitions) ->
  Increase = "/opt/kafka/bin/kafka-topics.sh " ++ maybe_zookeeper() ++
    " --alter --partitions ~p --topic ~s",
  0 = exec_in_kafka_container(Increase, [NumPartitions, Name]),
  wait_for_topic_by_describe(Name).

exec_in_kafka_container(FMT, Args) ->
  CMD0 = lists:flatten(io_lib:format(FMT, Args)),
  CMD = "docker exec kafka-1 bash -c '" ++ CMD0 ++ "'",
  Port = open_port({spawn, CMD}, [exit_status, stderr_to_stdout]),
  ?log(notice, "Running ~s~nin kafka container", [CMD0]),
  collect_port_output(Port, CMD).

%% Kafka 3.9 in KRaft mode may not see the topic immediately after creation.
wait_for_topic_by_describe(Name) ->
  wait_for_topic_by_describe(Name, 0, undefined).

wait_for_topic_by_describe(_Name, Attempt, Reason) when Attempt >= 10 ->
  error({failed_to_create_topic, Reason});
wait_for_topic_by_describe(Name, Attempt, _Reason) ->
  Describe = "/opt/kafka/bin/kafka-topics.sh " ++ maybe_zookeeper() ++ " --describe --topic ~s",
  try
      0 = exec_in_kafka_container(Describe, [Name])
  catch
    C:E ->
      timer:sleep(100),
      wait_for_topic_by_describe(Name, Attempt + 1, {C, E})
  end.

collect_port_output(Port, CMD) ->
  receive
    {Port, {data, Str}} ->
      ?log(notice, "~s", [Str]),
      collect_port_output(Port, CMD);
    {Port, {exit_status, ExitStatus}} ->
      ExitStatus
  after 20000 ->
      error({port_timeout, CMD})
  end.

-spec get_acked_offsets(brod:group_id()) ->
                           #{brod:partition() => brod:offset()}.
get_acked_offsets(GroupId) ->
  {ok, [#{partition_responses := Resp}]} =
    brod:fetch_committed_offsets(?TEST_CLIENT_ID, GroupId),
  Fun = fun(#{partition := P, offset := O}, Acc) ->
            Acc #{P => O}
        end,
  lists:foldl(Fun, #{}, Resp).

%% Validate offsets committed to Kafka:
check_committed_offsets(GroupId, Offsets) ->
  CommittedOffsets = get_acked_offsets(GroupId),
  lists:foreach( fun({TopicPartition, Offset}) ->
                     %% Explanation for + 1: brod's `roundrobin_v2'
                     %% protocol keeps _first unprocessed_ offset
                     %% rather than _last processed_. And this is
                     %% confusing.
                     ?assertEqual( Offset + 1
                                 , maps:get( TopicPartition, CommittedOffsets
                                           , undefined)
                                 )
                 end
               , Offsets
               ).

%% Wait until total number of messages processed by a consumer group
%% becomes equal to the expected value
wait_n_messages(TestGroupId, Expected, NRetries) ->
  ?retry(1000, NRetries,
         begin
           Offsets = get_acked_offsets(TestGroupId),
           NMessages = lists:sum(maps:values(Offsets)),
           ?log( notice
               , "Number of messages processed by consumer group: ~p; "
                 "total: ~p/~p"
               , [Offsets, NMessages, Expected]
               ),
           ?assert(NMessages >= Expected)
         end).

wait_n_messages(TestGroupId, NMessages) ->
  wait_n_messages(TestGroupId, NMessages, 30).

consumer_config() ->
  %% Makes brod restart faster, this will hopefully shave off some
  %% time from failure suites:
  [ {max_wait_time, 500}
  , {sleep_timeout, 100}
  , {begin_offset, 0}
  ].

bootstrap_hosts() ->
  [ {"localhost", 9092}
  ].

kill_process(Pid, Signal) ->
  Mon = monitor(process, Pid),
  ?tp(kill_consumer, #{pid => Pid}),
  exit(Pid, Signal),
  receive
    {'DOWN', Mon, process, Pid, _Reason} ->
      ok
  after 1000 ->
      ct:fail("timed out waiting for the process to die")
  end.

env(Var) ->
  case os:getenv(Var) of
    [_|_] = Val-> Val;
    _ -> error({env_var_missing, Var})
  end.
