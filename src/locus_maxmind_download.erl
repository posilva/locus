%% Copyright (c) 2020 Guilherme Andrade
%%
%% Permission is hereby granted, free of charge, to any person obtaining a
%% copy  of this software and associated documentation files (the "Software"),
%% to deal in the Software without restriction, including without limitation
%% the rights to use, copy, modify, merge, publish, distribute, sublicense,
%% and/or sell copies of the Software, and to permit persons to whom the
%% Software is furnished to do so, subject to the following conditions:
%%
%% The above copyright notice and this permission notice shall be included in
%% all copies or substantial portions of the Software.
%%
%% THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
%% IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
%% FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
%% AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
%% LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING
%% FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
%% DEALINGS IN THE SOFTWARE.
%%
%% locus is an independent project and has not been authorized, sponsored,
%% or otherwise approved by MaxMind.

-module(locus_maxmind_download).
-behaviour(gen_server).

%% ------------------------------------------------------------------
%% API Function Exports
%% ------------------------------------------------------------------

-export(
   [validate_opts/1,
    start_link/3
   ]).

-ignore_xref(
   [start_link/3
   ]).

%% ------------------------------------------------------------------
%% proc_lib Function Exports
%% ------------------------------------------------------------------

-export(
   [init_/1
   ]).

-ignore_xref(
   [init_/1
   ]).

%% ------------------------------------------------------------------
%% gen_server Function Exports
%% ------------------------------------------------------------------

-export(
   [init/1,
    handle_call/3,
    handle_cast/2,
    handle_info/2,
    terminate/2,
    code_change/3
   ]).

%% ------------------------------------------------------------------
%% Record and Type Definitions
%% ------------------------------------------------------------------

-type opt() ::
    {license_key, binary() | string()} | % TODO support reading it from file or environment
    {date, calendar:date()} |
    locus_http_download:opt().
-export_type([opt/0]).

-type msg() ::
    {event, event()} |
    locus_http_download:msg().
-export_type([msg/0]).

-type event() ::
    {finished, {error, no_license_key_defined}} |
    locus_http_download:event().
-export_type([event/0]).

-type success() :: locus_http_download:success().
-export_type([success/0]).

-record(state, {
          owner_pid :: pid(),
          edition :: atom(),
          opts :: [opt()],
          http_download_pid :: pid()
         }).
-type state() :: #state{}.

%% ------------------------------------------------------------------
%% API Function Definitions
%% ------------------------------------------------------------------

-spec validate_opts(proplists:proplist())
        -> {ok, {[opt()], proplists:proplist()}} |
           {error, BadOpt :: term()}.
%% @private
validate_opts(MixedOpts) ->
    try
        lists:partition(
          fun ({license_key, Value} = Opt) ->
                  validate_license_key_opt(Value) orelse error({badopt,Opt});
              ({date, Value} = Opt) ->
                  validate_date_opt(Value) orelse error({badopt,Opt});
              (_) ->
                  false
          end,
          MixedOpts)
    of
        {MyOpts, OtherOpts} ->
            case locus_http_download:validate_opts(OtherOpts) of
                {ok, {HttpDownloadOpts, RemainingOpts}} ->
                    {ok, {MyOpts ++ HttpDownloadOpts, RemainingOpts}};
                {error, BadOpt} ->
                    {error, BadOpt}
            end
    catch
        error:{badopt,BadOpt} ->
            {error, BadOpt}
    end.

-spec start_link(atom(), locus_http_download:headers(), [opt()]) -> {ok, pid()}.
%% @private
start_link(Edition, RequestHeaders, Opts) ->
    proc_lib:start_link(?MODULE, init_, [[self(), Edition, RequestHeaders, Opts]]).

%% ------------------------------------------------------------------
%% proc_lib Function Definitions
%% ------------------------------------------------------------------

-spec init_([InitArg, ...]) -> no_return()
        when InitArg :: OwnerPid | Edition | RequestHeaders | Opts,
             OwnerPid :: pid(),
             Edition :: atom(),
             RequestHeaders :: locus_http_download:headers(),
             Opts :: [opt()].
%% @private
init_([OwnerPid, Edition, RequestHeaders, Opts]) ->
    _ = process_flag(trap_exit, true),
    proc_lib:init_ack(OwnerPid, {ok, self()}),
    {MyOpts, HttpDownloadOpts} =
        lists:partition(
          fun ({Opt, _}) ->
                  lists:member(Opt, [license_key, date]);
              (_) ->
                  false
          end,
          Opts),

    case get_license_key(Opts) of
        {ok, LicenseKey} ->
            URL = build_download_url(Edition, LicenseKey, Opts),
            {ok, HttpDownloadPid} = locus_http_download:start_link(URL, RequestHeaders, HttpDownloadOpts),
            State =
                #state{
                   owner_pid = OwnerPid,
                   edition = Edition,
                   opts = MyOpts,
                   http_download_pid = HttpDownloadPid
                  },
            gen_server:enter_loop(?MODULE, [], State);
        {error, Reason} ->
            notify_owner_process(OwnerPid, {finished, {error, Reason}}),
            exit(normal)
    end.

%% ------------------------------------------------------------------
%% gen_server Function Definitions
%% ------------------------------------------------------------------

-spec init(_) -> no_return().
%% @private
init(_) ->
    exit(not_called).

-spec handle_call(term(), {pid(),reference()}, state())
        -> {stop, unexpected_call, state()}.
%% @private
handle_call(_Call, _From, State) ->
    {stop, unexpected_call, State}.

-spec handle_cast(term(), state())
        -> {stop, unexpected_cast, state()}.
%% @private
handle_cast(_Cast, State) ->
    {stop, unexpected_cast, State}.

-spec handle_info(term(), state())
        -> {noreply, state()} |
           {stop, normal, state()} |
           {stop, unexpected_info, state()}.
%% @private
handle_info({HttpDownloadPid, Msg}, State)
  when HttpDownloadPid =:= State#state.http_download_pid ->
    handle_http_download_msg(Msg, State);
handle_info({'EXIT', Pid, Reason}, State) ->
    handle_linked_process_death(Pid, Reason, State);
handle_info(_Info, State) ->
    {stop, unexpected_info, State}.

-spec terminate(term(), state()) -> ok.
%% @private
terminate(_Reason, _State) ->
    ok.

-spec code_change(term(), state(), term()) -> {ok, state()}.
%% @private
code_change(_OldVsn, #state{} = State, _Extra) ->
    {ok, State}.

%% ------------------------------------------------------------------
%% Internal Function Definitions
%% ------------------------------------------------------------------

-spec validate_license_key_opt(term()) -> boolean().
validate_license_key_opt(Value) ->
    locus_util:is_utf8_binary(Value) orelse
    locus_util:is_unicode_string(Value).

-spec validate_date_opt(term()) -> boolean().
validate_date_opt(Date) ->
    locus_util:is_date(Date).

-spec get_license_key([opt()]) -> {ok, binary()} | {error, no_license_key_defined}.
get_license_key(Opts) ->
    OptValue = proplists:get_value(license_key, Opts),
    AppConfigValue = application:get_env(locus, license_key, undefined),

    if is_binary(OptValue) ->
           {ok, OptValue};
       is_binary(AppConfigValue), AppConfigValue =/= <<"YOUR_LICENSE_KEY">> ->
           {ok, AppConfigValue};
       length(AppConfigValue) >= 0, AppConfigValue =/= "YOUR_LICENSE_KEY" ->
           <<Value/bytes>> = unicode:characters_to_binary(AppConfigValue),
           {ok, Value};
       true ->
           {error, no_license_key_defined}
    end.

-spec build_download_url(atom(), binary(), [opt()]) -> string().
build_download_url(Edition, LicenseKey, Opts) ->
    BinEdition = atom_to_binary(Edition, utf8),
    BaseQueryIoPairs = [["edition_id=", locus_util:url_query_encode(BinEdition)],
                        ["license_key=", locus_util:url_query_encode(LicenseKey)],
                        ["suffix=tar.gz"]],
    QueryIoPairs =
        lists:foldl(
          fun ({date, Date}, Acc) ->
                  {DateYear, DateMonth, DateDay} = Date,
                  IoDate = io_lib:format("~4..0B~2..0B~2..0B", [DateYear, DateMonth, DateDay]),
                  [["date=", IoDate] | Acc];
              (_, Acc) ->
                  Acc
          end,
          BaseQueryIoPairs, Opts),

    QueryIoString = lists:join($&, QueryIoPairs),
    Binary = iolist_to_binary(["https://download.maxmind.com/app/geoip_download?", QueryIoString]),
    binary_to_list(Binary).

-spec handle_http_download_msg(locus_http_download:msg(), state())
        -> {noreply, state()} | {stop, normal, state()}.
handle_http_download_msg({finished,_} = Msg, State) ->
    locus_util:expect_linked_process_termination(State#state.http_download_pid),
    notify_owner(Msg, State),
    {stop, normal, State};
handle_http_download_msg(Msg, State) ->
    notify_owner(Msg, State),
    {noreply, State}.

-spec notify_owner(msg(), state()) -> ok.
notify_owner(Msg, State) ->
    #state{owner_pid = OwnerPid} = State,
    notify_owner_process(OwnerPid, Msg).

-spec notify_owner_process(pid(), msg()) -> ok.
notify_owner_process(OwnerPid, Msg) ->
    _ = erlang:send(OwnerPid, {self(),Msg}, [noconnect]),
    ok.

-spec handle_linked_process_death(pid(), term(), state()) -> {stop, normal, state()}.
handle_linked_process_death(Pid, _, State)
  when Pid =:= State#state.owner_pid ->
    {stop, normal, State};
handle_linked_process_death(Pid, Reason, State)
  when Pid =:= State#state.http_download_pid ->
    {stop, {http_download_stopped, Pid, Reason}, State}.
