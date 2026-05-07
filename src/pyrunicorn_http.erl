-module(pyrunicorn_http).

-export([parse_request/1, format_response/1]).

-spec parse_request(binary()) -> {ok, binary(), binary(), [{binary(), binary()}], binary()} | {error, term()}.
parse_request(Request) when is_binary(Request) ->
    case binary:split(Request, <<"\r\n\r\n">>) of
        [Head, Body] ->
            parse_head(Head, Body);
        [Head] ->
            parse_head(Head, <<"">>)
    end.

-spec format_response({binary(), [{binary(), binary()}], [binary()]}) -> binary().
format_response({Status, Headers, BodyChunks}) ->
    Body = iolist_to_binary(BodyChunks),
    HeaderLines = [
        <<Name/binary, ": ", Value/binary, "\r\n">>
        || {Name, Value} <- ensure_content_length(Headers, byte_size(Body))
    ],
    iolist_to_binary([<<"HTTP/1.1 ">>, Status, <<"\r\n">>, HeaderLines, <<"\r\n">>, Body]).

parse_head(Head, Body) ->
    Lines = binary:split(Head, <<"\r\n">>, [global]),
    case Lines of
        [RequestLine | HeaderLines] ->
            case binary:split(RequestLine, <<" ">>, [global]) of
                [Method, Target, _Version] ->
                    case parse_headers(HeaderLines) of
                        {ok, Headers} ->
                            case validate_content_length(Headers) of
                                ok -> {ok, Method, Target, Headers, Body};
                                {error, Reason} -> {error, Reason}
                            end;
                        {error, Reason} ->
                            {error, Reason}
                    end;
                _ ->
                    {error, bad_request_line}
            end;
        [] ->
            {error, empty_request}
    end.

parse_headers(Lines) ->
    parse_headers(Lines, []).

parse_headers([<<>> | Rest], Acc) ->
    parse_headers(Rest, Acc);
parse_headers([Line | Rest], Acc) ->
    case parse_header(Line) of
        {ok, Header} -> parse_headers(Rest, [Header | Acc]);
        {error, Reason} -> {error, Reason}
    end;
parse_headers([], Acc) ->
    {ok, lists:reverse(Acc)}.

parse_header(Line) ->
    case binary:split(Line, <<":">>) of
        [Name, Value] when Name =/= <<>> ->
            {ok, {string:lowercase(Name), trim_binary(Value)}};
        _ ->
            {error, {bad_header, Line}}
    end.

validate_content_length(Headers) ->
    Parsed = [
        parse_content_length(Value)
        || {Name, Value} <- Headers,
           string:lowercase(Name) =:= <<"content-length">>
    ],
    case lists:member(error, Parsed) of
        true -> {error, bad_content_length};
        false -> ok
    end.

parse_content_length(Value) ->
    try binary_to_integer(trim_binary(Value)) of
        Length when Length >= 0 -> {ok, Length};
        _Negative -> error
    catch
        error:badarg -> error
    end.

ensure_content_length(Headers, Length) ->
    [
        {Name, Value}
        || {Name, Value} <- Headers,
           string:lowercase(Name) =/= <<"content-length">>
    ] ++ [{<<"content-length">>, integer_to_binary(Length)}].

trim_binary(Binary) ->
    unicode:characters_to_binary(string:trim(binary_to_list(Binary))).
