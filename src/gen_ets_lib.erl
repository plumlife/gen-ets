%%% The MIT License
%%%
%%% Copyright (C) 2011-2012 by Joseph Wayne Norton <norton@alum.mit.edu>
%%%
%%% Permission is hereby granted, free of charge, to any person obtaining a copy
%%% of this software and associated documentation files (the "Software"), to deal
%%% in the Software without restriction, including without limitation the rights
%%% to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
%%% copies of the Software, and to permit persons to whom the Software is
%%% furnished to do so, subject to the following conditions:
%%%
%%% The above copyright notice and this permission notice shall be included in
%%% all copies or substantial portions of the Software.
%%%
%%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
%%% OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
%%% THE SOFTWARE.

-module(gen_ets_lib).

-include("gen_ets.hrl").

%% External exports
-export([reg_setup/0
         , reg_teardown/0
         , reg_list/0
         , reg_insert/3
         , reg_delete/1
         , reg_lookup/1
         %% ets friends
         , foldl/3
         , foldr/3
         %% , nfoldl/4
         %% , nfoldr/4
         %% , nfoldl/1
         %% , nfoldr/1
         , match/2
         , match/3
         , match/1
         , match_delete/2
         , match_object/2
         , match_object/3
         , match_object/1
         , select/2
         , select/3
         , select/1
         , select_count/2
         , select_delete/2
         , select_reverse/2
         , select_reverse/3
         , select_reverse/1
         , tab2list/1
        ]).

%%%----------------------------------------------------------------------
%%% Types/Specs/Records
%%%----------------------------------------------------------------------

-record(gen_reg, {name :: gen_ets:name(), pid::pid(), tid :: #gen_tid{}}).
-define(TAB, ?MODULE).

%%%----------------------------------------------------------------------
%%% API
%%%----------------------------------------------------------------------

reg_setup() ->
    case ets:info(?TAB, name) of
        undefined ->
            Caller = self(),
            Fun = fun() ->
                          register(?MODULE, self()),
                          ets:new(?TAB, [ordered_set, public, named_table, {keypos, #gen_reg.name}, {read_concurrency, true}]),
                          Caller ! self(),
                          receive
                              {Pid, stop} ->
                                  Pid ! self()
                          end
                  end,

            {Pid, Ref} = spawn_monitor(Fun),
            try
                receive
                    Pid ->
                        ok;
                    {'DOWN', Ref, process, _Object, _Info} ->
                        ok
                end
            after
                demonitor(Ref, [flush])
            end;
        _ ->
            ok
    end.

reg_teardown() ->
    case whereis(?MODULE) of
        undefined ->
            ok;
        Pid ->
            Ref = monitor(process, Pid),
            try
                Pid ! {self(), stop},
                receive
                    Pid ->
                        ok;
                    {'DOWN', Ref, process, _Object, _Info} ->
                        ok
                end
            after
                demonitor(Ref, [flush])
            end
    end.

reg_list() ->
    reg_setup(),
    [ if Named -> Name; true -> Tid end
      || #gen_reg{name=Name, tid=#gen_tid{named_table=Named}=Tid} <- ets:tab2list(?TAB) ].

reg_insert(#gen_tid{name=Name, named_table=Named}=PreTid, open=Op, Opts) ->
    reg_setup(),
    PreReg = #gen_reg{name=Name, tid=undefined},
    case ets:insert_new(?TAB, PreReg) of
        true ->
            try
                Parent = self(),
                Fun = fun() -> reg_loop(PreTid, Op, Opts, PreReg, Parent) end,

                {Child, ChildRef} = spawn_monitor(Fun),
                receive
                    {Child, Tid} ->
                        if Named ->
                                Name;
                           true ->
                                Tid
                        end;
                    {'DOWN', ChildRef, process, _Object, _Info} ->
                        undefined
                end
            after
                %% cleanup failures
                catch ets:delete_object(?TAB, PreReg)
            end;
        false ->
            undefined
    end;
reg_insert(#gen_tid{name=Name, mod=Mod}=Tid, Op, Opts) ->
    reg_setup(),
    case reg_lookup(Name) of
        undefined ->
            Mod:Op(Tid, Opts);
        _ ->
            undefined
    end.

reg_delete(#gen_tid{name=Name}) ->
    try
        case ets:lookup(?TAB, Name) of
            [#gen_reg{pid=undefined}] ->
                false;
            [#gen_reg{pid=Pid}] ->
                Ref = monitor(process, Pid),
                Pid ! stop,
                try
                    receive
                        {'DOWN', Ref, process, _Object, _Info} ->
                            true
                    end
                after
                    demonitor(Ref, [flush])
                end;
            [] ->
                false
        end
    catch
        error:badarg ->
            false
    end.

reg_lookup(Name) ->
    try
        case ets:lookup(?TAB, Name) of
            [#gen_reg{tid=undefined}] ->
                undefined;
            [#gen_reg{tid=Tid}] ->
                Tid;
            [] ->
                undefined
        end
    catch
        error:badarg ->
            undefined
    end.

reg_loop(#gen_tid{mod=Mod}=PreTid, Op, Opts, PreReg, Parent) ->
    ParentRef = monitor(process, Parent),

    Impl = Mod:Op(PreTid, Opts),
    Tid = PreTid#gen_tid{impl=Impl},
    Reg = PreReg#gen_reg{pid=self(), tid=Tid},

    ets:insert(?TAB, Reg),
    try
        Parent ! {self(), Tid},
        receive
            stop ->
                ok;
            {'DOWN', ParentRef, process, _Object, _Info} ->
                ok
        end,
        %% delete
        Mod:delete(Tid)
    after
        %% cleanup
        ets:delete_object(?TAB, Reg),
        demonitor(ParentRef, [flush])
    end.

foldl(Fun, Acc0, #gen_tid{mod=Mod}=Tid) ->
    foldl(Fun, Acc0, Tid, Mod:first_iter(Tid)).

foldr(Fun, Acc0, #gen_tid{mod=Mod}=Tid) ->
    foldr(Fun, Acc0, Tid, Mod:last_iter(Tid)).

nfoldl(Fun, Acc0, #gen_tid{mod=Mod}=Tid, Limit) when Limit > 0 ->
    nfoldl(Fun, Acc0, Acc0, Tid, Limit, Limit, Mod:first_iter(Tid));
nfoldl(_Fun, _Acc0, _Tid, Limit) ->
    exit({badarg,Limit}).

nfoldl('$end_of_table') ->
    '$end_of_table';
nfoldl({_Fun, _Acc0, _Tid, _Limit0, '$end_of_table'}) ->
    '$end_of_table';
nfoldl({Fun, Acc0, #gen_tid{mod=Mod}=Tid, Limit0, Key}) ->
    nfoldl(Fun, Acc0, Acc0, Tid, Limit0, Limit0, Mod:next_iter(Tid, Key)).

nfoldr(Fun, Acc0, #gen_tid{mod=Mod}=Tid, Limit) when Limit > 0 ->
    nfoldr(Fun, Acc0, Acc0, Tid, Limit, Limit, Mod:last_iter(Tid));
nfoldr(_Fun, _Acc0, _Tid, Limit) ->
    exit({badarg,Limit}).

nfoldr('$end_of_table') ->
    '$end_of_table';
nfoldr({_Fun, _Acc0, _Tid, _Limit0, '$end_of_table'}) ->
    '$end_of_table';
nfoldr({Fun, Acc0, #gen_tid{mod=Mod}=Tid, Limit0, Key}) ->
    nfoldr(Fun, Acc0, Acc0, Tid, Limit0, Limit0, Mod:prev_iter(Tid, Key)).

tab2list(Tid) ->
    foldr(fun(X, Acc) -> [X|Acc] end, [], Tid).

match(Tid, Pattern) ->
    select(Tid, [{Pattern, [], ['$$']}]).

match(Tid, Pattern, Limit) ->
    select(Tid, [{Pattern, [], ['$$']}], Limit).

match(Cont) ->
    select(Cont).

match_delete(Tid, Pattern) ->
    select_delete(Tid, [{Pattern, [], [true]}]),
    true.

match_object(Tid, Pattern) ->
    select(Tid, [{Pattern, [], ['$_']}]).

match_object(Tid, Pattern, Limit) ->
    select(Tid, [{Pattern, [], ['$_']}], Limit).

match_object(Cont) ->
    select(Cont).

select(Tid, Spec) ->
    Fun = fun(_Object, Match, Acc) -> [Match|Acc] end,
    selectr(Fun, [], Tid, Spec).

select(Tid, Spec, Limit) ->
    Fun = fun(_Object, Match, Acc) -> [Match|Acc] end,
    case nselectl(Fun, [], Tid, Spec, Limit) of
        {Acc, Cont} ->
            {lists:reverse(Acc), Cont};
        Cont ->
            Cont
    end.

select(Cont0) ->
    case nselectl(Cont0) of
        {Acc, Cont} ->
            {lists:reverse(Acc), Cont};
        Cont ->
            Cont
    end.

select_count(Tid, Spec) ->
    Fun = fun(_Object, true, Acc) ->
                  Acc + 1;
             (_Object, _Match, Acc) ->
                  Acc
          end,
    selectl(Fun, 0, Tid, Spec).

select_delete(#gen_tid{keypos=KeyPos, mod=Mod}=Tid, Spec) ->
    Fun = fun(Object, true, Acc) ->
                  Key = element(KeyPos, Object),
                  Mod:delete(Tid, Key),
                  Acc + 1;
             (_Object, _Match, Acc) ->
                  Acc
          end,
    selectl(Fun, 0, Tid, Spec).

select_reverse(Tid, Spec) ->
    Fun = fun(_Object, Match, Acc) -> [Match|Acc] end,
    selectl(Fun, [], Tid, Spec).

select_reverse(Tid, Spec, Limit) ->
    Fun = fun(_Object, Match, Acc) -> [Match|Acc] end,
    case nselectr(Fun, [], Tid, Spec, Limit) of
        {Acc, Cont} ->
            {lists:reverse(Acc), Cont};
        Cont ->
            Cont
    end.

select_reverse(Cont0) ->
    case nselectr(Cont0) of
        {Acc, Cont} ->
            {lists:reverse(Acc), Cont};
        Cont ->
            Cont
    end.

foldl(_Fun, Acc, Tid, '$end_of_table') ->
    ets_safe_fixtable(Tid, false),
    Acc;
foldl(Fun, Acc, #gen_tid{keypos=KeyPos, mod=Mod}=Tid, Object) ->
    Key = element(KeyPos, Object),
    foldl(Fun, Fun(Object, Acc), Tid, Mod:next_iter(Tid, Key)).

foldr(_Fun, Acc, Tid, '$end_of_table') ->
    ets_safe_fixtable(Tid, false),
    Acc;
foldr(Fun, Acc, #gen_tid{keypos=KeyPos, mod=Mod}=Tid, Object) ->
    Key = element(KeyPos, Object),
    foldr(Fun, Fun(Object, Acc), Tid, Mod:prev_iter(Tid, Key)).

nfoldl(_Fun, Acc0, Acc0, Tid, _Limit0, _Limit, '$end_of_table') ->
    ets_safe_fixtable(Tid, false),
    '$end_of_table';
nfoldl(_Fun, _Acc0, Acc, Tid, _Limit0, _Limit, '$end_of_table'=Cont) ->
    ets_safe_fixtable(Tid, false),
    {Acc, Cont};
nfoldl(Fun, Acc0, Acc, #gen_tid{keypos=KeyPos, mod=Mod}=Tid, Limit0, Limit, Object) ->
    Key = element(KeyPos, Object),
    case Fun(Object, Acc) of
        {true, NewAcc} ->
            if Limit > 1 ->
                    nfoldl(Fun, Acc0, NewAcc, Tid, Limit0, Limit-1, Mod:next_iter(Tid, Key));
               true ->
                    Cont = {Fun, Acc0, Tid, Limit0, Key},
                    {NewAcc, Cont}
            end;
        {false, NewAcc} ->
            nfoldl(Fun, Acc0, NewAcc, Tid, Limit0, Limit, Mod:next_iter(Tid, Key))
    end.

nfoldr(_Fun, Acc0, Acc0, Tid, _Limit0, _Limit, '$end_of_table') ->
    ets_safe_fixtable(Tid, false),
    '$end_of_table';
nfoldr(_Fun, _Acc0, Acc, Tid, _Limit0, _Limit, '$end_of_table'=Cont) ->
    ets_safe_fixtable(Tid, false),
    {Acc, Cont};
nfoldr(Fun, Acc0, Acc, #gen_tid{keypos=KeyPos, mod=Mod}=Tid, Limit0, Limit, Object) ->
    Key = element(KeyPos, Object),
    case Fun(Object, Acc) of
        {true, NewAcc} ->
            if Limit > 1 ->
                    nfoldr(Fun, Acc0, NewAcc, Tid, Limit0, Limit-1, Mod:prev_iter(Tid, Key));
               true ->
                    Cont = {Fun, Acc0, Tid, Limit0, Key},
                    {NewAcc, Cont}
            end;
        {false, NewAcc} ->
            nfoldr(Fun, Acc0, NewAcc, Tid, Limit0, Limit, Mod:prev_iter(Tid, Key))
    end.

selectl(Fun, Acc0, Tid, Spec) ->
    ets_safe_fixtable(Tid, true),
    foldl(selectfun(Fun, Spec), Acc0, Tid).

selectr(Fun, Acc0, Tid, Spec) ->
    ets_safe_fixtable(Tid, true),
    foldr(selectfun(Fun, Spec), Acc0, Tid).

nselectl(Fun, Acc0, Tid, Spec, Limit0) ->
    ets_safe_fixtable(Tid, true),
    nfoldl(nselectfun(Fun, Spec), Acc0, Tid, Limit0).

nselectr(Fun, Acc0, Tid, Spec, Limit0) ->
    ets_safe_fixtable(Tid, true),
    nfoldr(nselectfun(Fun, Spec), Acc0, Tid, Limit0).

nselectl(Cont) ->
    nfoldl(Cont).

nselectr(Cont) ->
    nfoldr(Cont).

selectfun(Fun, Spec) ->
    CMSpec = ets:match_spec_compile(Spec),
    fun(Object, Acc) ->
            case ets:match_spec_run([Object], CMSpec) of
                [] ->
                    Acc;
                [Match] ->
                    Fun(Object, Match, Acc)
            end
    end.

nselectfun(Fun, Spec) ->
    CMSpec = ets:match_spec_compile(Spec),
    fun(Object, Acc) ->
            case ets:match_spec_run([Object], CMSpec) of
                [] ->
                    {false, Acc};
                [Match] ->
                    {true, Fun(Object, Match, Acc)}
            end
    end.

ets_safe_fixtable(#gen_tid{type=set, mod=gen_ets_impl_ets, impl=Impl}, Flag) ->
    ets:safe_fixtable(Impl, Flag);
ets_safe_fixtable(_Tid, _Flag) ->
    true.
