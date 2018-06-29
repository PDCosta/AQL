
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

  StateOp = crdt:field_map_op(element:st_key(), crdt:assign_lww(ipa:insert())),
  FieldUpdates = create_update(Table, [], SetClause),

  Keys = where:scan(TName, WhereClause, TxId),
  VisibleKeys = lists:foldl(fun(Key, AccKeys) ->
    {ok, [Record]} = antidote:read_objects(Key, TxId),
    case element:is_visible(Record, TName, Tables, TxId) of
      true -> AccKeys ++ [Key];
      false -> AccKeys
    end
  end, [], Keys),

  MapUpdates = crdt:map_update(VisibleKeys, lists:append([StateOp], FieldUpdates)),
  UpdateMsg = case MapUpdates of
    [] -> ok;
    ?IGNORE_OP -> ok;
    _Else ->
      antidote:update_objects(MapUpdates, TxId)
  end,

  case UpdateMsg of
    ok ->
      lists:foreach(fun(Key) -> touch_cascade(Key, Table, Tables, TxId) end, VisibleKeys),
      ok;
    Msg -> Msg
  end.

table({TName, _Set, _Where}) -> TName.

set({_TName, ?SET_CLAUSE(Set), _Where}) -> Set.

where({_TName, _Set, Where}) -> Where.

%%====================================================================
%% Internal functions
%%====================================================================

create_update(Table, Acc, [{ColumnName, Op, OpParam} | Tail]) ->
  Column = column:s_get(Table, ColumnName),
  {ok, Update} = resolve_op(Column, Op, OpParam),
  case Update of
    ?IGNORE_OP ->
      create_update(Table, Acc, Tail);
    _Else ->
      create_update(Table, [Update | Acc], Tail)
  end;
create_update(_Table, Acc, []) ->
  Acc.

% varchar -> assign
resolve_op(Column, ?ASSIGN_OP(_TChars), Value) when is_list(Value) ->
  Op = fun crdt:assign_lww/1,
  resolve_op(Column, ?AQL_VARCHAR, Op, Value);
% integer -> assign
resolve_op(Column, ?ASSIGN_OP(_TChars), Value) ->
  Op = fun crdt:set_integer/1,
  resolve_op(Column, ?AQL_INTEGER, Op, Value);
% counter -> increment
resolve_op(Column, ?INCREMENT_OP(_TChars), Value) ->
  {IncFun, DecFun} = counter_functions(increment, Column),
  Op = resolve_op_counter(Column, IncFun, DecFun),
  resolve_op(Column, ?AQL_COUNTER_INT, Op, Value);
% counter -> decrement
resolve_op(Column, ?DECREMENT_OP(_Tchars), Value) ->
  {DecFun, IncFun} = counter_functions(decrement, Column),
  Op = resolve_op_counter(Column, DecFun, IncFun),
  resolve_op(Column, ?AQL_COUNTER_INT, Op, Value).

resolve_op(Column, AQL, Op, Value) ->
  CName = column:name(Column),
  CType = column:type(Column),
  Constraint = column:constraint(Column),
  case CType of
    AQL ->
      Update = crdt:field_map_op(CName, types:to_crdt(AQL, Constraint), Op(Value)),
      {ok, Update};
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

counter_functions(increment, ?T_COL(_, _, ?CHECK_KEY(_))) ->
  {fun crdt:increment_bcounter/1, fun crdt:decrement_bcounter/1};
counter_functions(decrement, ?T_COL(_, _, ?CHECK_KEY(_))) ->
  {fun crdt:decrement_bcounter/1, fun crdt:increment_bcounter/1};
counter_functions(increment, _) ->
  {fun crdt:increment_counter/1, fun crdt:decrement_counter/1};
counter_functions(decrement, _) ->
  {fun crdt:decrement_counter/1, fun crdt:increment_counter/1}.

resolve_fail(CName, CType) ->
  Msg = lists:concat(["Cannot assign to column ", CName, " of type ", CType]),
  {err, Msg}.

touch_cascade(Key, Table, Tables, TxId) ->
  {ok, [Record]} = antidote:read_objects(Key, TxId),
  insert:touch_cascade(record, Record, Table, Tables, TxId).

%%====================================================================
%% Eunit tests
%%====================================================================

-ifdef(TEST).
create_column_aux(CName, CType) ->
  ?T_COL(CName, CType, ?NO_CONSTRAINT).

resolve_op_varchar_test() ->
  CName = col1,
  CType = ?AQL_VARCHAR,
  Column = create_column_aux(CName, CType),
  Value = "Value",
  Expected = {ok, crdt:field_map_op(CName, ?CRDT_VARCHAR, crdt:assign_lww(Value))},
  Actual = resolve_op(Column, ?ASSIGN_OP("SomeChars"), Value),
  ?assertEqual(Expected, Actual).

resolve_op_integer_test() ->
  CName = col1,
  CType = ?AQL_INTEGER,
  Column = create_column_aux(CName, CType),
  Value = 2,
  Expected = {ok, crdt:field_map_op(CName, ?CRDT_INTEGER, crdt:set_integer(Value))},
  Actual = resolve_op(Column, ?ASSIGN_OP(2), Value),
  ?assertEqual(Expected, Actual).

resolve_op_counter_increment_test() ->
  CName = col1,
  CType = ?AQL_COUNTER_INT,
  Column = create_column_aux(CName, CType),
  Value = 2,
  Expected = {ok, crdt:field_map_op(CName, ?CRDT_COUNTER_INT, crdt:increment_counter(Value))},
  Actual = resolve_op(Column, ?INCREMENT_OP(3), Value),
  ?assertEqual(Expected, Actual).

resolve_op_counter_decrement_test() ->
  CName = col1,
  CType = ?AQL_COUNTER_INT,
  Column = create_column_aux(CName, CType),
  Value = 2,
  Expected = {ok, crdt:field_map_op(CName, ?CRDT_COUNTER_INT, crdt:decrement_counter(Value))},
  Actual = resolve_op(Column, ?DECREMENT_OP(3), Value),
  ?assertEqual(Expected, Actual).

-endif.
