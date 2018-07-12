
-module(element).

-include("aql.hrl").
-include("parser.hrl").
-include("types.hrl").

-ifdef(TEST).
-include_lib("eunit/include/eunit.hrl").
-endif.

-define(CRDT_TYPE, antidote_crdt_map_go).
-define(EL_ANON, none).
-define(STATE, '#st').
-define(STATE_TYPE, antidote_crdt_register_mv).
-define(VERSION, '#version').
-define(VERSION_TYPE, antidote_crdt_register_lww).

-export([primary_key/1, set_primary_key/2,
        foreign_keys/1, foreign_keys/2, foreign_keys/3,
        attributes/1,
        data/1,
        table/1]).

-export([create_key/2, st_key/0,
        is_visible/3, is_visible/4]).

-export([new/1, new/2,
        put/3, set_version/2, build_fks/2,
        get/2, get/3, get/4,
        get_by_name/2,
        insert/1, insert/2,
        delete/2]).

%% ====================================================================
%% Property functions
%% ====================================================================

ops({_BObj, _Table, Ops, _Data}) -> Ops.
set_ops({BObj, Table, _Ops, Data}, Ops) -> ?T_ELEMENT(BObj, Table, Ops, Data).

primary_key({BObj, _Table, _Ops, _Data}) -> BObj.
set_primary_key({_BObj, Table, Ops, Data}, BObj) -> ?T_ELEMENT(BObj, Table, Ops, Data).

foreign_keys(Element) ->
  foreign_keys:from_columns(attributes(Element)).

attributes(Element) ->
  Table = table(Element),
  table:columns(Table).

data({_BObj, _Table, _Ops, Data}) -> Data.
set_data({BObj, Table, Ops, _Data}, Data) -> ?T_ELEMENT(BObj, Table, Ops, Data).

table({_BObj, Table, _Ops, _Data}) -> Table.

%% ====================================================================
%% Utils functions
%% ====================================================================

create_key({Key, Type, Bucket}, _TName) ->
  {Key, Type, Bucket};
create_key(Key, TName) ->
  KeyAtom = utils:to_atom(Key),
  crdt:create_bound_object(KeyAtom, ?CRDT_TYPE, TName).

st_key() ->
  ?MAP_KEY(?STATE, ?STATE_TYPE).

version_key() ->
  ?MAP_KEY(?VERSION, ?VERSION_TYPE).

explicit_state(Data, Rule) ->
  Value = proplists:get_value(st_key(), Data),
  case Value of
    undefined ->
      throw("No explicit state found");
    _Else ->
      ipa:status(Rule, Value)
  end.

is_visible(Element, Tables, TxId) when is_tuple(Element) ->
  Data = data(Element),
  TName = table:name(table(Element)),
  is_visible(Data, TName, Tables, TxId).

is_visible([], _TName, _Tables, _TxId) -> false;
is_visible(Data, TName, Tables, TxId) ->
  Table = table:lookup(TName, Tables),
  Policy = table:policy(Table),
  Rule = crp:get_rule(Policy),
  ExplicitState = explicit_state(Data, Rule),
  case length(Data) of
    1 ->
      ipa:is_visible(ExplicitState);
    _Else ->
      case crp:dep_level(Policy) of
        ?REMOVE_WINS ->
          ipa:is_visible(ExplicitState) andalso
            implicit_state(Table, Data, Tables, TxId);
        _Other ->
          ipa:is_visible(ExplicitState)
      end
  end.

throwNoSuchColumn(ColName, TableName) ->
  MsgFormat = io_lib:format("Column ~p does not exist in table ~p", [ColName, TableName]),
  throw(lists:flatten(MsgFormat)).

%% ====================================================================
%% API functions
%% ====================================================================

new(Table) when ?is_table(Table) ->
  new(?EL_ANON, Table).

new(Key, Table) ->
  Bucket = table:name(Table),
  BoundObject = create_key(Key, Bucket),
  StateOp = crdt:field_map_op(st_key(), crdt:assign_lww(ipa:new())),
  Ops = [StateOp],
  Element = ?T_ELEMENT(BoundObject, Table, Ops, []),
  load_defaults(Element).

load_defaults(Element) ->
  Columns = attributes(Element),
  Defaults = column:s_filter_defaults(Columns),
  maps:fold(fun (CName, Column, Acc) ->
    {?DEFAULT_TOKEN, Value} = column:constraint(Column),
    Constraint = {?DEFAULT_TOKEN, Value},
    append(CName, Value, column:type(Column), Constraint, Acc)
  end, Element, Defaults).

put([Key | OKeys], [Value | OValues], Element) ->
  utils:assert_same_size(OKeys, OValues, "Illegal number of keys and values"),
  Res = put(Key, Value, Element),
  put(OKeys, OValues, Res);
put([], [], Element) ->
  {ok, Element};
put(ColName, Value, Element) ->
  ColSearch = maps:get(ColName, attributes(Element)),
  case ColSearch of
    {badkey, _} ->
      Table = table(Element),
      TName = table:name(Table),
      throwNoSuchColumn(ColName, TName);
    Col ->
      ColType = column:type(Col),
      Constraint = column:constraint(Col),
      Element1 = set_if_primary(Col, Value, Element),
      append(ColName, Value, ColType, Constraint, Element1)
  end.

set_if_primary(Col, Value, Element) ->
  case column:is_primary_key(Col) of
    true ->
      ?BOUND_OBJECT(_Key, _Type, Bucket) = primary_key(Element),
      set_primary_key(Element, create_key(Value, Bucket));
    _Else ->
      Element
  end.

set_version(Element, TxId) ->
  VersionKey = version_key(),
  CurrOps = ops(Element),
  ElemData = data(Element),

  Key = primary_key(Element),
  {ok, [CurrData]} = antidote:read_objects(Key, TxId),
  Version = case CurrData of
              [] -> 1;
              _Else ->
                proplists:get_value(VersionKey, CurrData) + 1
            end,

  VersionOp = crdt:assign_lww(Version),

  Element1 = set_data(Element, lists:append(ElemData, [{VersionKey, Version}])),
  set_ops(Element1, utils:proplists_upsert(VersionKey, VersionOp, CurrOps)).

build_fks(Element, TxId) ->
  Data = data(Element),
  Table = table(Element),
  Fks = table:shadow_columns(Table),
  Parents = parents(Data, Fks, Table, TxId),
  lists:foldl(fun(?T_FK(FkName, _, _, FkColName, _), AccElement) ->
    case length(FkName) of
      1 ->
        [{_, ParentId}] = FkName,
        Parent = dict:fetch(ParentId, Parents),
        Value = get_by_name(foreign_keys:to_cname(FkColName), Parent),
        ParentVersion = get_by_name(?VERSION, Parent),
        append(FkName, {Value, ParentVersion}, ?AQL_VARCHAR, ?IGNORE_OP, AccElement);
      _Else ->
        [{_, ParentId} | ParentCol] = FkName,
        Parent = dict:fetch(ParentId, Parents),
        Value = get_by_name(ParentCol, Parent),
        append(FkName, Value, ?AQL_VARCHAR, ?IGNORE_OP, AccElement)
    end
  end, Element, Fks).

parents(Data, Fks, Table, TxId) ->
  lists:foldl(fun(?T_FK(Name, Type, TTName, _, _), Dict) ->
    case Name of
      [ShCol] ->
        {_FkTable, FkName} = ShCol,
        Value = get(FkName, types:to_crdt(Type, ?IGNORE_OP), Data, Table),
        Key = create_key(Value, TTName),
        {ok, [Parent]} = antidote:read_objects(Key, TxId),
        dict:store(FkName, Parent, Dict);
      _Else -> Dict
    end
  end, dict:new(), Fks).


get_by_name(ColName, [{{ColName, _Type}, Value} | _]) ->
	Value;
get_by_name(ColName, [_KV | Data]) ->
	get_by_name(ColName, Data);
get_by_name(_ColName, []) -> undefined.

get(ColName, Element) ->
  Columns = attributes(Element),
  Col = maps:get(ColName, Columns),
  AQL = column:type(Col),
  Constraint = column:constraint(Col),
  get(ColName, types:to_crdt(AQL, Constraint), Element).

get(ColName, Crdt, Element) when ?is_element(Element) ->
  get(ColName, Crdt, data(Element), table(Element)).

get(ColName, Crdt, Data, Table) when is_atom(Crdt) ->
  Value = proplists:get_value(?MAP_KEY(ColName, Crdt), Data),
  case Value of
    undefined ->
      TName = table:name(Table),
      throwNoSuchColumn(ColName, TName);
    _Else ->
      Value
    end;
get(ColName, Cols, Data, TName) ->
  Col = maps:get(ColName, Cols),
  AQL = column:type(Col),
  Constraint = column:constraint(Col),
  get(ColName, types:to_crdt(AQL, Constraint), Data, TName).

insert(Element) ->
  Ops = ops(Element),
  Key = primary_key(Element),
  crdt:map_update(Key, Ops).
insert(Element, TxId) ->
  Op = insert(Element),
  antidote:update_objects(Op, TxId).

append(Key, Value, AQL, Constraint, Element) ->
  Data = data(Element),
  Ops = ops(Element),
  OffValue = apply_offset(Key, AQL, Constraint, Value),
  OpKey = ?MAP_KEY(Key, types:to_crdt(AQL, Constraint)),
  OpVal = types:to_insert_op(AQL, Constraint, OffValue),
  case OpVal of
    ?IGNORE_OP ->
      Element;
    _Else ->
      Element1 = set_data(Element, lists:append(Data, [{OpKey, Value}])),
      set_ops(Element1, utils:proplists_upsert(OpKey, OpVal, Ops))
  end.

apply_offset(Key, AQL, Constraint, Value) when is_atom(Key) ->
  case {AQL, Constraint} of
    {?AQL_COUNTER_INT, ?CHECK_KEY({Key, ?COMPARATOR_KEY(Comp), Offset})} ->
      bcounter:to_bcounter(Key, Value, Offset, Comp);
    _Else -> Value
  end;
apply_offset(_Key,_AQL, _Constraint, Value) -> Value.

foreign_keys(Fks, Element) when is_tuple(Element) ->
  Data = data(Element),
  TName = table(Element),
  foreign_keys(Fks, Data, TName).

foreign_keys(Fks, Data, TName) ->
  lists:map(fun(?T_FK(CName, CType, FkTable, FkAttr, DeleteRule)) ->
    Value = get(CName, types:to_crdt(CType, ?IGNORE_OP), Data, TName),
    {{CName, CType}, {FkTable, FkAttr}, DeleteRule, Value}
  end, Fks).

implicit_state(Table, RecordData, Tables, TxId) ->
  FKs = table:shadow_columns(Table),
  implicit_state(Table, RecordData, Tables, FKs, TxId).

implicit_state(Table, Data, Tables, [?T_FK(FkName, FkType, FKTName, _, _) | Fks], TxId) ->
  Policy = table:policy(Table),
  IsVisible =
    case length(FkName) of
      1 ->
        {RefValue, RefVersion} = element:get(FkName, types:to_crdt(FkType, ?IGNORE_OP), Data, Table),

        FKBoundObj = create_key(RefValue, FKTName),
        {ok, [FKData]} = antidote:read_objects(FKBoundObj, TxId),
        FKTable = table:lookup(FKTName, Tables),
        FkVersion = element:get(?VERSION, ?VERSION_TYPE, FKData, FKTable),
        case crp:dep_level(Policy) of
          ?REMOVE_WINS ->
            FkVersion =:= RefVersion andalso
              is_visible(FKData, FKTName, Tables, TxId);
          _ ->
            true
        end;
      _ ->
        true
    end,

  IsVisible andalso implicit_state(Table, Data, Tables, Fks, TxId);
implicit_state(_Table, _Data, _Tables, [], _TxId) ->
  true.

delete(ObjKey, TxId) ->
  StateOp = crdt:field_map_op(element:st_key(), crdt:assign_lww(ipa:delete())),
  Update = crdt:map_update(ObjKey, StateOp),
  ok = antidote:update_objects(Update, TxId),
  false.

%%====================================================================
%% Eunit tests
%%====================================================================

-ifdef(TEST).

primary_key_test() ->
  Table = eutils:create_table_aux(),
  Element = new(key, Table),
  ?assertEqual(create_key(key, 'Universities'), primary_key(Element)).

attributes_test() ->
  Table = eutils:create_table_aux(),
  Columns = table:columns(Table),
  Element = new(key, Table),
  ?assertEqual(Columns, attributes(Element)).

create_key_test() ->
  Key = key,
  TName = test,
  Expected = crdt:create_bound_object(Key, ?CRDT_TYPE, TName),
  ?assertEqual(Expected, create_key(Key, TName)).

new_test() ->
  Key = key,
  Table = eutils:create_table_aux(),
  BoundObject = create_key(Key, table:name(Table)),
  Ops = [crdt:field_map_op(st_key(), crdt:assign_lww(ipa:new()))],
  Expected = ?T_ELEMENT(BoundObject, Table, Ops, []),
  Expected1 = load_defaults(Expected),
  Element = new(Key, Table),
  ?assertEqual(Expected1, Element),
  ?assertEqual(crdt:assign_lww(ipa:new()), proplists:get_value(st_key(), ops(Element))).

new_1_test() ->
  Table = eutils:create_table_aux(),
  ?assertEqual(new(?EL_ANON, Table), new(Table)).

append_raw_test() ->
  Table = eutils:create_table_aux(),
  Value = 9,
  Element = new(key, Table),
  % assert not fail
  append('NationalRank', Value, ?AQL_INTEGER, ?IGNORE_OP, Element).

get_default_test() ->
  Table = eutils:create_table_aux(),
  El = new(key, Table),
  ?assertEqual("aaa", get('InstitutionId', ?CRDT_VARCHAR, El)).

get_by_name_test() ->
  Data = [{{a, abc}, 1}, {{b, abc}, 2}],
  ?assertEqual(1, get_by_name(a, Data)),
  ?assertEqual(undefined, get_by_name(c, Data)),
  ?assertEqual(undefined, get_by_name(a, [])).

-endif.
