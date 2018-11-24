-module(update).

-include("aql.hrl").
-include("parser.hrl").
-include("types.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-export([exec/3]).

-export([table/1,
  set/1,
  where/1]).

%%====================================================================
%% API
%%====================================================================

exec({Table, Tables}, Props, TxId) ->
  TName = table:name(Table),
  SetClause = set(Props),
  WhereClause = where(Props),

  Keys = where:scan(Table, WhereClause, TxId),
  VisibleKeys = lists:foldl(fun(Key, AccKeys) ->
    {ok, [Record]} = antidote_handler:read_objects(Key, TxId),
    case element:is_visible(Record, TName, Tables, TxId) of
      true -> AccKeys ++ [{Key, Record}];
      false -> AccKeys
    end
  end, [], Keys),

  {_NewKeys, MapUpdates} = generate_updates({[], []}, VisibleKeys, Table, Tables, SetClause, TxId),
  UpdateMsg =
    case MapUpdates of
      [] -> ok;
      _Else ->
        antidote_handler:update_objects(MapUpdates, TxId)
    end,
  UpdateMsg.

table({TName, _Set, _Where}) -> TName.

set({_TName, ?SET_CLAUSE(Set), _Where}) -> Set.

where({_TName, _Set, Where}) -> Where.

%%====================================================================
%% Internal functions
%%====================================================================

create_update(BoundObj, Table, Tables, Acc, [{ColumnName, Op, OpParam} | Tail], TxId) ->
  TName = table:name(Table),
  Column = column:s_get(Table, ColumnName),
  {ok, NewBoundObj, Updates} = resolve_op(BoundObj, Column, Op, OpParam, TName, Tables, TxId),
  case Updates of
    [?IGNORE_OP] ->
      create_update(NewBoundObj, Table, Tables, Acc, Tail, TxId);
    _Else ->
      create_update(NewBoundObj, Table, Tables, [Updates | Acc], Tail, TxId)
  end;
create_update(BoundObj, _Table, _Tables, Acc, [], _TxId) ->
  {BoundObj, Acc}.

% varchar -> assign
resolve_op(BoundObj, Column, ?ASSIGN_OP(_TChars), Value, TName, Tables, TxId) when is_list(Value) ->
  Op = fun crdt:assign_lww/1,
  resolve_op(Column, ?AQL_VARCHAR, Op, Value, BoundObj, TName, Tables, TxId);
% integer -> assign
resolve_op(BoundObj, Column, ?ASSIGN_OP(_TChars), Value, TName, Tables, TxId) when is_integer(Value) ->
  Op = fun crdt:set_integer/1,
  resolve_op(Column, ?AQL_INTEGER, Op, Value, BoundObj, TName, Tables, TxId);
% boolean -> assign
resolve_op(BoundObj, Column, ?ASSIGN_OP(_TChars), Value, TName, Tables, TxId) when is_boolean(Value) ->
  Op =
    case Value of
      true -> fun crdt:enable_flag/1;
      false -> fun crdt:disable_flag/1
    end,
  resolve_op(Column, ?AQL_BOOLEAN, Op, Value, BoundObj, TName, Tables, TxId);
% counter -> increment
resolve_op(BoundObj, Column, ?INCREMENT_OP(_TChars), Value, TName, Tables, TxId) ->
  {IncFun, DecFun} = counter_functions(increment, Column),
  Op = resolve_op_counter(Column, IncFun, DecFun),
  resolve_op(Column, ?AQL_COUNTER_INT, Op, Value, BoundObj, TName, Tables, TxId);
% counter -> decrement
resolve_op(BoundObj, Column, ?DECREMENT_OP(_Tchars), Value, TName, Tables, TxId) ->
  {DecFun, IncFun} = counter_functions(decrement, Column),
  Op = resolve_op_counter(Column, DecFun, IncFun),
  resolve_op(Column, ?AQL_COUNTER_INT, Op, Value, BoundObj, TName, Tables, TxId).

resolve_op(Column, AQL, Op, Value, BoundObj, TName, Tables, _TxId) ->
  CName = column:name(Column),
  CType = column:type(Column),
  Constraint = column:constraint(Column),
  case CType of
    AQL ->
      Update = crdt:field_map_op(CName, types:to_crdt(AQL, Constraint), Op(Value)),
      NewKey = set_partition(CName, Value, BoundObj, table:lookup(TName, Tables)),
      {ok, NewKey, [Update]};
    _Else ->
      resolve_fail(CName, CType)
  end.

resolve_op_counter(Column, Forward, Reverse) ->
  case column:constraint(Column) of
    ?CHECK_KEY({_Key, ?COMPARATOR_KEY(Comp), _Offset}) ->
      case Comp of
        ?PARSER_GREATER ->
          Forward;
        _Else ->
          Reverse
      end;
    _Else ->
      Forward
  end.

set_partition(Col, Value, BoundObj, Table) ->
  case table:partition_col(Table) of
    [Col] ->
      ?BOUND_OBJECT(Key, _Type, _Bucket) = BoundObj,
      TName = table:name(Table),
      HashValue = utils:to_hash(Value),
      element:create_key(Key, TName, HashValue);
    _ ->
      BoundObj
  end.

counter_functions(increment, ?T_COL(_, _, ?CHECK_KEY(_))) ->
  {fun crdt:increment_bcounter/1, fun crdt:decrement_bcounter/1};
counter_functions(decrement, ?T_COL(_, _, ?CHECK_KEY(_))) ->
  {fun crdt:decrement_bcounter/1, fun crdt:increment_bcounter/1};
counter_functions(increment, _) ->
  {fun crdt:increment_counter/1, fun crdt:decrement_counter/1};
counter_functions(decrement, _) ->
  {fun crdt:decrement_counter/1, fun crdt:increment_counter/1}.

resolve_fail(CName, CType) ->
  Msg = io_lib:format("Cannot assign to column ~p of type ~p", [CName, CType]),
  {err, lists:flatten(Msg)}.

generate_updates(Acc, [{Key, Record} | Keys], Table, Tables, SetClause, TxId) ->
  StateOp = crdt:field_map_op(element:st_key(), crdt:assign_lww(ipa:insert())),

  {NewKey, FieldUpdates0} = create_update(Key, Table, Tables, [], SetClause, TxId),
  FieldUpdates1 = lists:append([StateOp], lists:flatten(FieldUpdates0)),
  Updates =
    case NewKey of
      Key ->
        FieldUpdates1;
      _Else ->
        lists:foldl(fun({{ColName, ColType}, Value}, UpdAcc) ->
          case element:get_by_name(ColName, FieldUpdates1) of
            undefined ->
              MapOp = crdt:field_map_op({ColName, ColType}, types:to_insert_op(ColType, Value)),
              UpdAcc ++ [MapOp];
            _ ->
              UpdAcc
          end
        end, FieldUpdates1, Record)
    end,
  MapUpdate = crdt:map_update(NewKey, lists:flatten(Updates)),

  {KeyAcc, MapUpdAcc} = Acc,
  NewAcc = {KeyAcc ++ [NewKey], MapUpdAcc ++ [MapUpdate]},
  generate_updates(NewAcc, Keys, Table, Tables, SetClause, TxId);
generate_updates(Acc, [], _Table, _Tables, _SetClause, _TxId) ->
  Acc.

%%====================================================================
%% Eunit tests
%%====================================================================

-ifdef(TEST).
create_column_aux(CName, CType) ->
  ?T_COL(CName, CType, ?NO_CONSTRAINT).

resolve_op_varchar_test() ->
  Table = ?T_TABLE(table, undef, [], [], [], []),
  Tables = [{{table, antidote_crdt_register_lww}, Table}],
  CName = col1,
  CType = ?AQL_VARCHAR,
  Column = create_column_aux(CName, CType),
  Value = "Value",
  Expected = {ok, {k, t, b}, [crdt:field_map_op(CName, ?CRDT_VARCHAR, crdt:assign_lww(Value))]},
  Actual = resolve_op({k, t, b}, Column, ?ASSIGN_OP("SomeChars"), Value, table, Tables, ?IGNORE_OP),
  ?assertEqual(Expected, Actual).

resolve_op_integer_test() ->
  Table = ?T_TABLE(table, undef, [], [], [], []),
  Tables = [{{table, antidote_crdt_register_lww}, Table}],
  CName = col1,
  CType = ?AQL_INTEGER,
  Column = create_column_aux(CName, CType),
  Value = 2,
  Expected = {ok, {k, t, b}, [crdt:field_map_op(CName, ?CRDT_INTEGER, crdt:set_integer(Value))]},
  Actual = resolve_op({k, t, b}, Column, ?ASSIGN_OP(2), Value, table, Tables, ?IGNORE_OP),
  ?assertEqual(Expected, Actual).

resolve_op_counter_increment_test() ->
  Table = ?T_TABLE(table, undef, [], [], [], []),
  Tables = [{{table, antidote_crdt_register_lww}, Table}],
  CName = col1,
  CType = ?AQL_COUNTER_INT,
  Column = create_column_aux(CName, CType),
  Value = 2,
  Expected = {ok, {k, t, b}, [crdt:field_map_op(CName, ?CRDT_COUNTER_INT, crdt:increment_counter(Value))]},
  Actual = resolve_op({k, t, b}, Column, ?INCREMENT_OP(3), Value, table, Tables, ?IGNORE_OP),
  ?assertEqual(Expected, Actual).

resolve_op_counter_decrement_test() ->
  Table = ?T_TABLE(table, undef, [], [], [], []),
  Tables = [{{table, antidote_crdt_register_lww}, Table}],
  CName = col1,
  CType = ?AQL_COUNTER_INT,
  Column = create_column_aux(CName, CType),
  Value = 2,
  Expected = {ok, {k, t, b}, [crdt:field_map_op(CName, ?CRDT_COUNTER_INT, crdt:decrement_counter(Value))]},
  Actual = resolve_op({k, t, b}, Column, ?DECREMENT_OP(3), Value, table, Tables, ?IGNORE_OP),
  ?assertEqual(Expected, Actual).

-endif.
