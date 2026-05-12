-module(pyrlang_eval_tests).

-include_lib("eunit/include/eunit.hrl").

parse_and_eval_arithmetic_test() ->
    pyrlang_heap:init(),
    ?assertEqual({ok, 7}, pyrlang:eval_expr("1 + 2 * 3")).

integer_bit_shift_operators_test() ->
    pyrlang_heap:init(),
    ?assertEqual({ok, 17}, pyrlang:eval_expr("(1 << 4) + (8 >> 3)")).

integer_floor_division_operator_test() ->
    pyrlang_heap:init(),
    Source =
        "n = 9\n"
        "n //= 2\n"
        "n + (5 // 2)\n",
    ?assertMatch({ok, 6, _Env}, pyrlang:run_string(Source)).

integer_modulo_uses_python_sign_rules_test() ->
    pyrlang_heap:init(),
    ?assertEqual({ok, true}, pyrlang:eval_expr("(-174 % 4 == 2) and (174 % -4 == -2)")).

integer_power_and_bit_length_test() ->
    pyrlang_heap:init(),
    Source =
        "num = 5\n"
        "packed = (258).to_bytes(2, 'big') + (258).to_bytes(2, 'little')\n"
        "roundtrip = int.from_bytes(bytes([1, 2]), 'big') + int.from_bytes(bytes([1, 2]), 'little')\n"
        "2 ** (num).bit_length() + 2 ** 3 ** 2 + -2 ** 2 + (packed == bytes([1, 2, 2, 1])) + roundtrip + (int.from_bytes(bytes([255]), 'big', signed=True) == -1)\n",
    ?assertMatch({ok, 1289, _Env}, pyrlang:run_string(Source)).

builtin_round_matches_basic_python_cases_test() ->
    pyrlang_heap:init(),
    ?assertEqual({ok, 0.7}, pyrlang:eval_expr("round(0.7, 3)")),
    ?assertEqual({ok, 126}, pyrlang:eval_expr("round(2.5) + round(3.5) + round(123, -1)")).

builtin_abs_matches_basic_python_cases_test() ->
    pyrlang_heap:init(),
    ?assertEqual({ok, 7}, pyrlang:eval_expr("abs(-3) + abs(True) + int(abs(3j))")).

base_prefixed_integer_literals_test() ->
    pyrlang_heap:init(),
    ?assertEqual({ok, 33}, pyrlang:eval_expr("0x10 + 0o10 + 0b1001")).

numeric_literals_allow_underscores_test() ->
    pyrlang_heap:init(),
    ?assertEqual({ok, 10248.0}, pyrlang:eval_expr("10_000 + 0x7_b + 1.2_5e2")).

imaginary_numeric_literals_test() ->
    pyrlang_heap:init(),
    ?assertEqual({ok, true}, pyrlang:eval_expr("1j == complex(0, 1)")),
    ?assertEqual({ok, true}, pyrlang:eval_expr("1.25e2J == complex(0, 125.0)")),
    ?assertEqual({ok, true}, pyrlang:eval_expr("-2j == complex(0, -2)")).

ellipsis_literal_test() ->
    pyrlang_heap:init(),
    ?assertEqual({ok, ellipsis}, pyrlang:eval_expr("...")),
    ?assertEqual({ok, true}, pyrlang:eval_expr("type(...) == type(Ellipsis)")).

integer_bitwise_or_augmented_assignment_test() ->
    pyrlang_heap:init(),
    Source =
        "mask = 1\n"
        "mask |= 4\n"
        "mask <<= 1\n"
        "mask\n",
    ?assertMatch({ok, 10, _Env}, pyrlang:run_string(Source)).

integer_bitwise_and_xor_and_invert_test() ->
    pyrlang_heap:init(),
    ?assertEqual({ok, 6}, pyrlang:eval_expr("((7 & ~1) ^ 0)")).

unary_plus_test() ->
    pyrlang_heap:init(),
    ?assertEqual({ok, 5}, pyrlang:eval_expr("+5")).

module_assignments_are_actor_local_env_test() ->
    pyrlang_heap:init(),
    Source = "x = 10\nx + 5\n",
    ?assertEqual({ok, 15, #{<<"x">> => 10}}, pyrlang:run_string(Source)).

globals_and_locals_return_current_bindings_test() ->
    pyrlang_heap:init(),
    Source =
        "x = 10\n"
        "g = globals()\n"
        "l = locals()\n"
        "class Box:\n"
        "    pass\n"
        "box = Box()\n"
        "box.value = 5\n"
        "v = vars(box)\n"
        "z = vars()\n"
        "g['x'] + l['x'] + v.pop('value') + ('box' in z)\n",
    ?assertMatch({ok, 26, _Env}, pyrlang:run_string(Source)).

dir_without_args_lists_current_bindings_test() ->
    pyrlang_heap:init(),
    Source =
        "alpha = 1\n"
        "beta = 2\n"
        "('alpha' in dir()) + ('beta' in dir())\n",
    ?assertMatch({ok, 2, _Env}, pyrlang:run_string(Source)).

list_literal_allocates_mutable_heap_object_test() ->
    pyrlang_heap:init(),
    {ok, Ref} = pyrlang:eval_expr("[1, 2, 3]"),
    pyrlang_heap:list_append(Ref, 4),
    ?assertEqual([1, 2, 3, 4], pyrlang_heap:list_items(Ref)).

list_augmented_add_extends_with_any_iterable_test() ->
    pyrlang_heap:init(),
    Source =
        "values = [1]\n"
        "same = values\n"
        "values += {2, 3}\n"
        "values += (4,)\n"
        "(same is values) + (2 in values) + (3 in values) + (values[-1] == 4) + len(values)\n",
    ?assertMatch({ok, 8, _Env}, pyrlang:run_string(Source)).

dict_literal_allocates_mutable_heap_object_test() ->
    pyrlang_heap:init(),
    {ok, Ref} = pyrlang:eval_expr("{'answer': 42}"),
    ?assertEqual(42, pyrlang_heap:dict_get(Ref, <<"answer">>)),
    Source =
        "base = {'a': 1, 'b': 2}\n"
        "merged = {**base, 'a': 3, 'c': 4}\n"
        "merged['a'] + merged['b'] + merged['c']\n",
    ?assertMatch({ok, 9, _Env}, pyrlang:run_string(Source)).

dict_and_set_membership_use_python_equality_fallback_test() ->
    pyrlang_heap:init(),
    Source =
        "class Node:\n"
        "    def __init__(self, key):\n"
        "        self.key = key\n"
        "    def __eq__(self, other):\n"
        "        return self.key == other\n"
        "    def __hash__(self):\n"
        "        return hash(self.key)\n"
        "node = Node(('contenttypes', '0001_initial'))\n"
        "applied = {('contenttypes', '0001_initial'): True}\n"
        "parents = {('contenttypes', '0001_initial')}\n"
        "(node in applied) + (node in parents)\n",
    ?assertMatch({ok, 2, _Env}, pyrlang:run_string(Source)).

float_bytes_tuple_and_set_literals_test() ->
    pyrlang_heap:init(),
    ?assertEqual({ok, 3.75}, pyrlang:eval_expr("1.5 + 2.25")),
    ?assertEqual({ok, 1000.25}, pyrlang:eval_expr("1e3 + 2.5e-1")),
    ?assertEqual({ok, <<"abc">>}, pyrlang:eval_expr("b'abc'")),
    ?assertEqual({ok, {1, <<"two">>, 3}}, pyrlang:eval_expr("(1, 'two', 3)")),
    ?assertEqual({ok, {<<"left">>, false}}, pyrlang:eval_expr("'left', False")),
    Source =
        "values = {1, 2, 2}\n"
        "values.add(3)\n"
        "values.discard(1)\n"
        "len(values) + (2 in values) + (1 in values)\n",
    ?assertMatch({ok, 3, _Env}, pyrlang:run_string(Source)).

string_concat_test() ->
    pyrlang_heap:init(),
    ?assertEqual({ok, <<"pyrlang">>}, pyrlang:eval_expr("'pyr' + 'lang'")),
    ?assertEqual({ok, <<"pyrlang">>}, pyrlang:eval_expr("'pyr' 'lang'")),
    ?assertEqual({ok, true}, pyrlang:eval_expr("'__' in 'content_type__app_label'")),
    ?assertEqual({ok, <<"Test_Proj 1Name">>}, pyrlang:eval_expr("'test_PROJ 1name'.title()")),
    ?assertEqual({ok, <<"User name">>}, pyrlang:eval_expr("'user NAME'.capitalize()")),
    ?assertEqual({ok, true}, pyrlang:eval_expr("repr('Todo') == \"'Todo'\"")),
    ?assertEqual(<<"'\\xe4\\n\\xdc'">>, pyrlang_builtins:builtin_repr(<<228, 10, 220>>)),
    ?assertEqual({ok, true}, pyrlang:eval_expr("'%r' % 'Todo' == \"'Todo'\"")),
    ?assertEqual({ok, <<"0007">>}, pyrlang:eval_expr("'%04i' % 7")),
    ?assertEqual({ok, true}, pyrlang:eval_expr("'a\\r\\nb\\n'.splitlines() == ['a', 'b']")),
    ?assertEqual(
        {ok, true}, pyrlang:eval_expr("'a\\r\\nb\\n'.splitlines(True) == ['a\\r\\n', 'b\\n']")
    ),
    ?assertEqual(
        {ok, true}, pyrlang:eval_expr("'filter capfirst'.split(None, 1) == ['filter', 'capfirst']")
    ),
    ?assertEqual({ok, true}, pyrlang:eval_expr("' a  b  c '.split(None, 1) == ['a', 'b  c ']")).

binary_encode_decode_accept_codec_keywords_test() ->
    pyrlang_heap:init(),
    Source =
        "left = '/todos/'.encode('iso-8859-1')\n"
        "right = left.decode(errors='replace')\n"
        "right\n",
    ?assertMatch({ok, <<"/todos/">>, _Env}, pyrlang:run_string(Source)).

lazy_string_proxy_methods_are_discovered_from_str_dict_test() ->
    pyrlang_heap:init(),
    Source =
        "class Proxy:\n"
        "    pass\n"
        "for method_name in str.__dict__:\n"
        "    if hasattr(Proxy, method_name):\n"
        "        continue\n"
        "    def wrapper(self, *args, __method_name=method_name, **kw):\n"
        "        return getattr('abc', __method_name)(*args, **kw)\n"
        "    setattr(Proxy, method_name, wrapper)\n"
        "p = Proxy()\n"
        "str(hasattr(p, '__iter__')) + ':' + next(iter(p)) + ':' + p[1]\n",
    ?assertMatch({ok, <<"True:a:b">>, _Env}, pyrlang:run_string(Source)).

lazy_dunder_proxy_can_use_common_string_methods_test() ->
    pyrlang_heap:init(),
    Source =
        "class __proxy__:\n"
        "    def __str__(self):\n"
        "        return 'Authentication and Authorization'\n"
        "__proxy__().lower()\n",
    ?assertMatch({ok, <<"authentication and authorization">>, _Env}, pyrlang:run_string(Source)).

missing_instance_subscript_raises_typeerror_test() ->
    pyrlang_heap:init(),
    Source =
        "class Box:\n"
        "    pass\n"
        "try:\n"
        "    Box()['missing']\n"
        "except TypeError:\n"
        "    result = 'type'\n"
        "result\n",
    ?assertMatch({ok, <<"type">>, _Env}, pyrlang:run_string(Source)).

formatted_string_literal_test() ->
    pyrlang_heap:init(),
    Source =
        "name = 'pyr'\n"
        "suffix = 'lang'\n"
        "dt = 1e3\n"
        "f'hello {name!r}' f'{suffix} {dt:.3f} {suffix=}'\n",
    ?assertMatch({ok, <<"hello pyrlang 1000.000 suffix=lang">>, _Env}, pyrlang:run_string(Source)).

formatted_string_expression_allows_slice_colons_test() ->
    pyrlang_heap:init(),
    Source = "f'{\"x:y\"[:1]}'\n",
    ?assertMatch({ok, <<"x">>, _Env}, pyrlang:run_string(Source)).

formatted_string_expression_allows_nested_quotes_test() ->
    pyrlang_heap:init(),
    Source =
        "left = f\"value {('a', 'b')[1]}\"\n"
        "right = f'len {len('xy')}'\n"
        "left + ':' + right\n",
    ?assertMatch({ok, <<"value b:len 2">>, _Env}, pyrlang:run_string(Source)).

inline_comments_are_ignored_outside_strings_test() ->
    pyrlang_heap:init(),
    Source =
        "value = 1  # comment after code\n"
        "text = '# not a comment'\n"
        "value + len(text)\n",
    ?assertMatch({ok, 16, _Env}, pyrlang:run_string(Source)).

comment_brackets_do_not_join_following_lines_test() ->
    pyrlang_heap:init(),
    Source =
        "# comment with unmatched ( bracket\n"
        "value = 1\n"
        "def after():\n"
        "    return 2\n"
        "value + after()\n",
    ?assertMatch({ok, 3, _Env}, pyrlang:run_string(Source)).

comment_triple_quotes_do_not_join_following_lines_test() ->
    pyrlang_heap:init(),
    Source =
        "# comment mentioning ''' should stay a comment\n"
        "value = 41\n"
        "value + 1\n",
    ?assertMatch({ok, 42, _Env}, pyrlang:run_string(Source)).

global_statement_is_supported_syntax_test() ->
    pyrlang_heap:init(),
    Source =
        "name = 'module'\n"
        "def read_name():\n"
        "    global name\n"
        "    return name\n"
        "read_name()\n",
    ?assertMatch({ok, <<"module">>, _Env}, pyrlang:run_string(Source)).

global_statement_assigns_module_binding_test() ->
    pyrlang_heap:init(),
    Unique = integer_to_binary(erlang:unique_integer([positive])),
    Dir = filename:join("/tmp", "pyrlang_global_" ++ binary_to_list(Unique)),
    _ = file:del_dir_r(Dir),
    ok = file:make_dir(Dir),
    Path = filename:join(Dir, "globalmod.py"),
    ok = file:write_file(Path, <<
        "name = 'module'\n"
        "def write_name():\n"
        "    global name\n"
        "    name = 'updated'\n"
        "write_name()\n"
    >>),
    erlang:erase(pyrlang_module_path),
    pyrlang_module:set_path([Dir | pyrlang_module:path()]),
    Source =
        "import globalmod\n"
        "globalmod.name\n",
    ?assertMatch({ok, <<"updated">>, _Env}, pyrlang:run_string(Source)).

nonlocal_statement_is_supported_syntax_test() ->
    pyrlang_heap:init(),
    Source =
        "def outer():\n"
        "    value = 1\n"
        "    def inner():\n"
        "        nonlocal value\n"
        "        return value + 1\n"
        "    return inner()\n"
        "outer()\n",
    ?assertMatch({ok, 2, _Env}, pyrlang:run_string(Source)).

backslash_line_continuation_test() ->
    pyrlang_heap:init(),
    Source =
        "value = \\\n"
        "    1 + 2\n"
        "value\n",
    ?assertMatch({ok, 3, _Env}, pyrlang:run_string(Source)).

semicolon_separated_simple_statements_test() ->
    pyrlang_heap:init(),
    Source =
        "left = 1; right = 2; text = 'a;b'\n"
        "template = \"\"\"x;y\"\"\"\n"
        "left + right + len(text) + len(template)\n",
    ?assertMatch({ok, 9, _Env}, pyrlang:run_string(Source)).

function_definition_and_call_test() ->
    pyrlang_heap:init(),
    Source = "def add(x, y):\n    return x + y\nresult = add(2, 3)\nresult\n",
    {ok, 5, Env} = pyrlang:run_string(Source),
    ?assertEqual(5, maps:get(<<"result">>, Env)).

inline_function_definition_test() ->
    pyrlang_heap:init(),
    Source = "def value(): return 42\nvalue()\n",
    ?assertMatch({ok, 42, _Env}, pyrlang:run_string(Source)).

async_function_definition_parses_as_function_test() ->
    pyrlang_heap:init(),
    Source = "async def value(): return 42\nawait value()\n",
    ?assertMatch({ok, 42, _Env}, pyrlang:run_string(Source)).

async_with_and_for_syntax_parse_test() ->
    pyrlang_heap:init(),
    Source =
        "async def value():\n"
        "    async with manager:\n"
        "        pass\n"
        "    async for item in []:\n"
        "        pass\n"
        "    return 42\n"
        "value\n",
    ?assertMatch({ok, _Function, _Env}, pyrlang:run_string(Source)).

await_expression_parses_as_unary_expression_test() ->
    pyrlang_heap:init(),
    Source =
        "class Sender:\n"
        "    def asend(self, value):\n"
        "        return 42\n"
        "async def value(): return await Sender().asend(None)\n"
        "await value()\n",
    ?assertMatch({ok, 42, _Env}, pyrlang:run_string(Source)).

async_function_call_returns_coroutine_with_close_test() ->
    pyrlang_heap:init(),
    Source =
        "async def value(): pass\n"
        "coro = value()\n"
        "same_type = type(coro) == type(value())\n"
        "closed = coro.close()\n"
        "same_type + (closed is None)\n",
    ?assertMatch({ok, 2, _Env}, pyrlang:run_string(Source)).

module_functions_resolve_later_global_definitions_test() ->
    pyrlang_heap:init(),
    Source =
        "def outer():\n"
        "    return inner()\n"
        "def inner():\n"
        "    return 42\n"
        "outer()\n",
    ?assertMatch({ok, 42, _Env}, pyrlang:run_string(Source)).

nested_function_preserves_outer_parameter_closure_test() ->
    pyrlang_heap:init(),
    Source =
        "def make_middleware_decorator(middleware_class):\n"
        "    def _make_decorator(*m_args, **m_kwargs):\n"
        "        def _decorator(view_func):\n"
        "            return middleware_class(view_func, *m_args, **m_kwargs)\n"
        "        return _decorator\n"
        "    return _make_decorator\n"
        "def middleware(view, *args, **kwargs):\n"
        "    return 42\n"
        "decorator = make_middleware_decorator(middleware)\n"
        "decorator()(None)\n",
    ?assertMatch({ok, 42, _Env}, pyrlang:run_string(Source)).

function_without_return_uses_none_test() ->
    pyrlang_heap:init(),
    Source = "def add_one(x):\n    x + 1\nadd_one(9) is None\n",
    ?assertMatch({ok, true, _Env}, pyrlang:run_string(Source)).

function_without_return_does_not_return_compound_statement_value_test() ->
    pyrlang_heap:init(),
    Source =
        "def clean(value):\n"
        "    return value\n"
        "def validate(value):\n"
        "    try:\n"
        "        clean(value)\n"
        "    except Exception:\n"
        "        pass\n"
        "validate('admin') is None\n",
    ?assertMatch({ok, true, _Env}, pyrlang:run_string(Source)).

dict_update_accepts_mapping_protocol_and_instance_dict_test() ->
    pyrlang_heap:init(),
    Source =
        "class Mapping:\n"
        "    def keys(self):\n"
        "        return ['async_mode']\n"
        "    def __getitem__(self, key):\n"
        "        return 'yes'\n"
        "class Box:\n"
        "    pass\n"
        "box = Box()\n"
        "box.value = 'box'\n"
        "data = {}\n"
        "data.update(Mapping())\n"
        "data.update(box.__dict__)\n"
        "data['async_mode'] + ':' + data['value']\n",
    ?assertMatch({ok, <<"yes:box">>, _Env}, pyrlang:run_string(Source)).

subscript_assignment_accepts_none_returning_setitem_test() ->
    pyrlang_heap:init(),
    Source =
        "class Headers:\n"
        "    def __init__(self):\n"
        "        self.store = {}\n"
        "    def __setitem__(self, key, value):\n"
        "        self.store[key] = value\n"
        "headers = Headers()\n"
        "headers['Content-Type'] = 'text/plain'\n"
        "headers.store['Content-Type']\n",
    ?assertMatch({ok, <<"text/plain">>, _Env}, pyrlang:run_string(Source)).

iter_falls_back_to_indexed_getitem_test() ->
    pyrlang_heap:init(),
    Source =
        "class Match:\n"
        "    def __getitem__(self, index):\n"
        "        values = ('func', (), {})\n"
        "        return values[index]\n"
        "callback, args, kwargs = Match()\n"
        "callback + ':' + str(len(args)) + ':' + str(len(kwargs))\n",
    ?assertMatch({ok, <<"func:0:0">>, _Env}, pyrlang:run_string(Source)).

bare_return_and_yield_use_none_test() ->
    pyrlang_heap:init(),
    Source =
        "def f():\n"
        "    return\n"
        "def g():\n"
        "    yield\n"
        "next(g()) == None and f() == None\n",
    ?assertMatch({ok, true, _Env}, pyrlang:run_string(Source)).

class_definition_instantiation_and_method_call_test() ->
    pyrlang_heap:init(),
    Source =
        "class Counter:\n"
        "    def __init__(self, value):\n"
        "        self.value = value\n"
        "    def inc(self, amount):\n"
        "        self.value = self.value + amount\n"
        "        return self.value\n"
        "counter = Counter(10)\n"
        "counter.inc(5)\n",
    ?assertMatch({ok, 15, _Env}, pyrlang:run_string(Source)).

class_instantiation_passes_keywords_to_init_not_object_new_test() ->
    pyrlang_heap:init(),
    Source =
        "class Box:\n"
        "    def __init__(self, value=None):\n"
        "        self.value = value\n"
        "Box(value=42).value\n",
    ?assertMatch({ok, 42, _Env}, pyrlang:run_string(Source)).

inline_class_definition_test() ->
    pyrlang_heap:init(),
    Source =
        "class Marker: pass\n"
        "isinstance(Marker(), Marker)\n",
    ?assertMatch({ok, true, _Env}, pyrlang:run_string(Source)).

class_base_expression_allows_nested_calls_test() ->
    pyrlang_heap:init(),
    Source =
        "def choose_base(label):\n"
        "    return object\n"
        "class Derived(choose_base('Derived')):\n"
        "    pass\n"
        "isinstance(Derived(), Derived)\n",
    ?assertMatch({ok, true, _Env}, pyrlang:run_string(Source)).

multiline_class_base_list_allows_trailing_comma_test() ->
    pyrlang_heap:init(),
    Source =
        "class One:\n"
        "    pass\n"
        "class Two:\n"
        "    pass\n"
        "class Both(\n"
        "    One,\n"
        "    Two,\n"
        "):\n"
        "    pass\n"
        "isinstance(Both(), One) and isinstance(Both(), Two)\n",
    ?assertMatch({ok, true, _Env}, pyrlang:run_string(Source)).

class_type_parameters_are_ignored_at_runtime_test() ->
    pyrlang_heap:init(),
    Source =
        "class Base:\n"
        "    value = 42\n"
        "class Box[T](Base):\n"
        "    pass\n"
        "class Inline[T]: value = 1\n"
        "Box().value + Inline.value\n",
    ?assertMatch({ok, 43, _Env}, pyrlang:run_string(Source)).

method_name_does_not_shadow_existing_global_test() ->
    pyrlang_heap:init(),
    Source =
        "copy = 'global'\n"
        "class Box:\n"
        "    def copy(self):\n"
        "        return copy\n"
        "Box().copy()\n",
    ?assertMatch({ok, <<"global">>, _Env}, pyrlang:run_string(Source)).

exception_type_can_be_used_as_class_base_test() ->
    pyrlang_heap:init(),
    Source =
        "class LocalError(Exception):\n"
        "    def marker(self):\n"
        "        return 'ok'\n"
        "class ChildError(LocalError):\n"
        "    pass\n"
        "class InitError(Exception):\n"
        "    def __init__(self, *args):\n"
        "        super().__init__(*args)\n"
        "try:\n"
        "    raise ChildError('bad')\n"
        "except LocalError as exc:\n"
        "    caught = exc.marker() + ':' + str(exc) + ':' + exc.args[0]\n"
        "init_exc = InitError('via super')\n"
        "try:\n"
        "    raise ChildError\n"
        "except LocalError as class_exc:\n"
        "    class_caught = class_exc.marker() + ':' + str(len(class_exc.args))\n"
        "score = 0\n"
        "if isinstance(ChildError('x'), Exception):\n"
        "    score += 1\n"
        "if issubclass(ChildError, Exception):\n"
        "    score += 1\n"
        "caught + ':' + init_exc.args[0] + ':' + class_caught + ':' + str(score)\n",
    ?assertMatch({ok, <<"ok:bad:bad:via super:ok:0:2">>, _Env}, pyrlang:run_string(Source)).

undefined_name_raises_catchable_name_error_test() ->
    pyrlang_heap:init(),
    Source =
        "try:\n"
        "    missing_name\n"
        "except NameError:\n"
        "    result = 'caught'\n"
        "result\n",
    ?assertMatch({ok, <<"caught">>, _Env}, pyrlang:run_string(Source)).

try_except_sees_completed_try_body_assignments_test() ->
    pyrlang_heap:init(),
    Source =
        "try:\n"
        "    before_error = 'ready'\n"
        "    missing_name\n"
        "except NameError:\n"
        "    result = before_error + ':caught'\n"
        "result\n",
    ?assertMatch({ok, <<"ready:caught">>, _Env}, pyrlang:run_string(Source)).

try_except_sees_loop_target_when_for_body_raises_test() ->
    pyrlang_heap:init(),
    Source =
        "try:\n"
        "    for bit in ['missing']:\n"
        "        {}[bit]\n"
        "except Exception:\n"
        "    result = bit\n"
        "result\n",
    ?assertMatch({ok, <<"missing">>, _Env}, pyrlang:run_string(Source)).

function_exception_env_does_not_escape_to_caller_except_test() ->
    pyrlang_heap:init(),
    Source =
        "def boom():\n"
        "    for bit in ['missing']:\n"
        "        {}[bit]\n"
        "def wrapper():\n"
        "    def local_handler():\n"
        "        return 'caller'\n"
        "    try:\n"
        "        boom()\n"
        "    except Exception:\n"
        "        return local_handler()\n"
        "wrapper()\n",
    ?assertMatch({ok, <<"caller">>, _Env}, pyrlang:run_string(Source)).

bare_raise_in_nested_call_uses_active_exception_test() ->
    pyrlang_heap:init(),
    Source =
        "def reraiser():\n"
        "    raise\n"
        "try:\n"
        "    {}['missing']\n"
        "except Exception as exc:\n"
        "    try:\n"
        "        reraiser()\n"
        "    except Exception as reraised:\n"
        "        result = reraised is exc\n"
        "result\n",
    ?assertMatch({ok, true, _Env}, pyrlang:run_string(Source)).

missing_import_raises_module_not_found_with_name_test() ->
    pyrlang_heap:init(),
    Source =
        "try:\n"
        "    import definitely_missing_pyrlang_module\n"
        "except ModuleNotFoundError as err:\n"
        "    result = (err.name == 'definitely_missing_pyrlang_module') + isinstance(err, ImportError)\n"
        "result\n",
    ?assertMatch({ok, 2, _Env}, pyrlang:run_string(Source)).

if_else_and_while_control_flow_test() ->
    pyrlang_heap:init(),
    Source =
        "x = 0\n"
        "while(x < 3):\n"
        "    x = x + 1\n"
        "if(x == 3):\n"
        "    result = 'ok'\n"
        "else:\n"
        "    result = 'bad'\n"
        "result\n",
    ?assertEqual(
        {ok, <<"ok">>, #{<<"x">> => 3, <<"result">> => <<"ok">>}}, pyrlang:run_string(Source)
    ).

elif_control_flow_test() ->
    pyrlang_heap:init(),
    Source =
        "x = 2\n"
        "if x == 1:\n"
        "    result = 'one'\n"
        "elif x == 2:\n"
        "    result = 'two'\n"
        "else:\n"
        "    result = 'other'\n"
        "result\n",
    ?assertMatch({ok, <<"two">>, _Env}, pyrlang:run_string(Source)).

inline_if_suite_test() ->
    pyrlang_heap:init(),
    Source =
        "value = 1\n"
        "if value: value += 2; value += 2\n"
        "if not value: value = 0\n"
        "else: value += 3\n"
        "value\n",
    ?assertMatch({ok, 8, _Env}, pyrlang:run_string(Source)).

for_loop_break_and_continue_test() ->
    pyrlang_heap:init(),
    Source =
        "total = 0\n"
        "for n in [1, 2, 3, 4]:\n"
        "    if n == 2:\n"
        "        continue\n"
        "    if n == 4:\n"
        "        break\n"
        "    total = total + n\n"
        "total\n",
    ?assertMatch({ok, 4, _Env}, pyrlang:run_string(Source)).

for_loop_does_not_preconsume_iterator_test() ->
    pyrlang_heap:init(),
    Source =
        "it = iter(chr(92) + 'Z')\n"
        "seen = []\n"
        "for ch in it:\n"
        "    if ch == chr(92):\n"
        "        seen.append(next(it))\n"
        "seen[0]\n",
    ?assertMatch({ok, <<"Z">>, _Env}, pyrlang:run_string(Source)).

generator_for_loop_does_not_preconsume_iterator_test() ->
    pyrlang_heap:init(),
    Source =
        "def scan(input_iter):\n"
        "    for ch in input_iter:\n"
        "        if ch == chr(92):\n"
        "            ch = next(input_iter)\n"
        "            if ch == 'Z':\n"
        "                continue\n"
        "        yield ch\n"
        "list(scan(iter(chr(92) + 'Za')))[0]\n",
    ?assertMatch({ok, <<"a">>, _Env}, pyrlang:run_string(Source)).

generator_preserves_yield_before_continue_test() ->
    pyrlang_heap:init(),
    Source =
        "def scan(values):\n"
        "    for ch in values:\n"
        "        if ch != 'x':\n"
        "            yield ch\n"
        "            continue\n"
        "        yield 'bad'\n"
        "result = list(scan('ab'))\n"
        "result[0] + result[1]\n",
    ?assertMatch({ok, <<"ab">>, _Env}, pyrlang:run_string(Source)).

function_decorator_test() ->
    pyrlang_heap:init(),
    Source =
        "def add_one(fn):\n"
        "    def wrapper(x):\n"
        "        return fn(x) + 1\n"
        "    return wrapper\n"
        "@add_one\n"
        "def ident(x):\n"
        "    return x\n"
        "ident(4)\n",
    ?assertMatch({ok, 5, _Env}, pyrlang:run_string(Source)).

class_decorator_test() ->
    pyrlang_heap:init(),
    Source =
        "def decorate(cls):\n"
        "    cls.label = 'decorated'\n"
        "    return cls\n"
        "@decorate\n"
        "class Box:\n"
        "    pass\n"
        "Box.label\n",
    ?assertMatch({ok, <<"decorated">>, _Env}, pyrlang:run_string(Source)).

python_descriptor_get_binds_class_and_instance_access_test() ->
    pyrlang_heap:init(),
    Source =
        "import functools\n"
        "class Switch:\n"
        "    def __init__(self, class_method, instance_method):\n"
        "        self.class_method = class_method\n"
        "        self.instance_method = instance_method\n"
        "    def __get__(self, instance, owner):\n"
        "        if instance is None:\n"
        "            return functools.partial(self.class_method, owner)\n"
        "        return functools.partial(self.instance_method, instance)\n"
        "class Box:\n"
        "    base = 5\n"
        "    def class_value(cls, amount):\n"
        "        return cls.base + amount\n"
        "    def instance_value(self, amount):\n"
        "        return self.base + amount + 10\n"
        "    chooser = Switch(class_value, instance_value)\n"
        "Box.chooser(1) + Box().chooser(2)\n",
    ?assertMatch({ok, 23, _Env}, pyrlang:run_string(Source)).

class_subclasses_lists_direct_child_classes_test() ->
    pyrlang_heap:init(),
    Source =
        "class Parent:\n"
        "    pass\n"
        "class Child(Parent):\n"
        "    pass\n"
        "class Grandchild(Child):\n"
        "    pass\n"
        "len(Parent.__subclasses__()) + len(Child.__subclasses__())\n",
    ?assertMatch({ok, 2, _Env}, pyrlang:run_string(Source)).

class_staticmethod_new_is_bound_for_instantiation_test() ->
    pyrlang_heap:init(),
    Source =
        "def decorate(klass):\n"
        "    def __new__(cls, value):\n"
        "        obj = super(klass, cls).__new__(cls)\n"
        "        obj.value = value\n"
        "        return obj\n"
        "    klass.__new__ = staticmethod(__new__)\n"
        "    return klass\n"
        "@decorate\n"
        "class Box:\n"
        "    pass\n"
        "class Child(Box):\n"
        "    pass\n"
        "Box(5).value + Child(7).value\n",
    ?assertMatch({ok, 12, _Env}, pyrlang:run_string(Source)).

context_manager_enter_exit_test() ->
    pyrlang_heap:init(),
    Source =
        "class Manager:\n"
        "    def __enter__(self):\n"
        "        self.entered = 'yes'\n"
        "        return self\n"
        "    def __exit__(self, exc_type, exc, tb):\n"
        "        self.exited = 'yes'\n"
        "        return False\n"
        "cm = Manager()\n"
        "with cm as active:\n"
        "    inside = active.entered\n"
        "inside + cm.exited\n",
    ?assertMatch({ok, <<"yesyes">>, _Env}, pyrlang:run_string(Source)).

context_manager_as_target_supports_destructuring_test() ->
    pyrlang_heap:init(),
    Source =
        "class Manager:\n"
        "    def __enter__(self):\n"
        "        return (2, 3)\n"
        "    def __exit__(self, exc_type, exc, tb):\n"
        "        return False\n"
        "with Manager() as (left, right):\n"
        "    value = left + right\n"
        "value\n",
    ?assertMatch({ok, 5, _Env}, pyrlang:run_string(Source)).

context_manager_can_suppress_exception_test() ->
    pyrlang_heap:init(),
    Source =
        "class Manager:\n"
        "    def __enter__(self):\n"
        "        return self\n"
        "    def __exit__(self, exc_type, exc, tb):\n"
        "        self.seen = 'yes'\n"
        "        return True\n"
        "cm = Manager()\n"
        "with cm:\n"
        "    raise ValueError('bad')\n"
        "cm.seen\n",
    ?assertMatch({ok, <<"yes">>, _Env}, pyrlang:run_string(Source)).

multiple_context_managers_enter_and_exit_in_order_test() ->
    pyrlang_heap:init(),
    Source =
        "events = []\n"
        "class Manager:\n"
        "    def __init__(self, name):\n"
        "        self.name = name\n"
        "    def __enter__(self):\n"
        "        events.append('enter:' + self.name)\n"
        "        return self.name\n"
        "    def __exit__(self, exc_type, exc, tb):\n"
        "        events.append('exit:' + self.name)\n"
        "        return False\n"
        "with Manager('a') as a, Manager('b') as b:\n"
        "    events.append(a + b)\n"
        "events[0] + '|' + events[1] + '|' + events[2] + '|' + events[3] + '|' + events[4]\n",
    ?assertMatch({ok, <<"enter:a|enter:b|ab|exit:b|exit:a">>, _Env}, pyrlang:run_string(Source)).

generator_yield_and_next_test() ->
    pyrlang_heap:init(),
    Source =
        "def nums():\n"
        "    yield 1\n"
        "    yield 2\n"
        "g = nums()\n"
        "next(g) + next(g)\n",
    ?assertMatch({ok, 3, _Env}, pyrlang:run_string(Source)).

next_builtin_returns_default_when_iterator_exhausted_test() ->
    pyrlang_heap:init(),
    Source =
        "it = iter([1])\n"
        "first = next(it, 9)\n"
        "second = next(it, 9)\n"
        "third = next(iter([]), 5)\n"
        "first + second + third\n",
    ?assertMatch({ok, 15, _Env}, pyrlang:run_string(Source)).

iter_builtin_accepts_callable_and_sentinel_test() ->
    pyrlang_heap:init(),
    Source =
        "values = [0, 2, 1]\n"
        "def read():\n"
        "    return values.pop()\n"
        "it = iter(read, 0)\n"
        "first = next(it)\n"
        "second = next(it)\n"
        "third = next(it, 7)\n"
        "empty = next(iter(lambda: [], []), 4)\n"
        "try:\n"
        "    iter(True)\n"
        "    caught = 0\n"
        "except TypeError:\n"
        "    caught = 1\n"
        "first + second + third + empty + caught\n",
    ?assertMatch({ok, 15, _Env}, pyrlang:run_string(Source)).

generator_yield_from_test() ->
    pyrlang_heap:init(),
    Source =
        "def nums():\n"
        "    yield 1\n"
        "    yield from [2, 3]\n"
        "g = nums()\n"
        "attrs = hasattr(g, 'gi_frame') + (g.gi_running == False) + (iter(g) is g)\n"
        "next(g) + next(g) + next(g) + attrs\n",
    ?assertMatch({ok, 9, _Env}, pyrlang:run_string(Source)).

generator_try_finally_yields_and_return_stops_collection_test() ->
    pyrlang_heap:init(),
    Source =
        "def nums():\n"
        "    try:\n"
        "        yield 1\n"
        "        return\n"
        "    finally:\n"
        "        marker = 2\n"
        "    yield 3\n"
        "g = nums()\n"
        "first = next(g)\n"
        "try:\n"
        "    second = next(g)\n"
        "except StopIteration:\n"
        "    second = 2\n"
        "first + second\n",
    ?assertMatch({ok, 3, _Env}, pyrlang:run_string(Source)).

for_loop_can_iterate_generator_test() ->
    pyrlang_heap:init(),
    Source =
        "def nums():\n"
        "    for n in [1, 2, 3]:\n"
        "        yield n\n"
        "total = 0\n"
        "for n in nums():\n"
        "    total = total + n\n"
        "total\n",
    ?assertMatch({ok, 6, _Env}, pyrlang:run_string(Source)).

loop_else_runs_only_without_break_test() ->
    pyrlang_heap:init(),
    Source =
        "total = 0\n"
        "for n in [1, 2]:\n"
        "    total = total + n\n"
        "else:\n"
        "    total = total + 10\n"
        "for n in [1, 2]:\n"
        "    break\n"
        "else:\n"
        "    total = total + 100\n"
        "while total < 20:\n"
        "    total = total + 1\n"
        "else:\n"
        "    total = total + 1000\n"
        "total\n",
    ?assertMatch({ok, 1020, _Env}, pyrlang:run_string(Source)).

match_statement_supports_captures_class_patterns_and_guards_test() ->
    pyrlang_heap:init(),
    Source =
        "class Pair:\n"
        "    __match_args__ = ('left', 'right')\n"
        "    def __init__(self, left, right):\n"
        "        self.left = left\n"
        "        self.right = right\n"
        "item = Pair(2, 3)\n"
        "match item:\n"
        "    case Pair(left, right) if right > 2:\n"
        "        result = left + right\n"
        "    case _:\n"
        "        result = 0\n"
        "match result:\n"
        "    case 5:\n"
        "        final = 'ok'\n"
        "    case other:\n"
        "        final = other\n"
        "final\n",
    ?assertMatch({ok, <<"ok">>, _Env}, pyrlang:run_string(Source)).

match_statement_supports_or_class_patterns_test() ->
    pyrlang_heap:init(),
    Source =
        "value = 'name'\n"
        "match value:\n"
        "    case bytes() | str():\n"
        "        result = 'text'\n"
        "    case _:\n"
        "        result = 'other'\n"
        "result\n",
    ?assertMatch({ok, <<"text">>, _Env}, pyrlang:run_string(Source)).

generator_exhaustion_raises_stop_iteration_test() ->
    pyrlang_heap:init(),
    Source =
        "def nums():\n"
        "    yield 1\n"
        "g = nums()\n"
        "next(g)\n"
        "try:\n"
        "    next(g)\n"
        "except StopIteration:\n"
        "    result = 'done'\n"
        "result\n",
    ?assertMatch({ok, <<"done">>, _Env}, pyrlang:run_string(Source)).

user_defined_iterator_protocol_test() ->
    pyrlang_heap:init(),
    Source =
        "class Counter:\n"
        "    def __init__(self):\n"
        "        self.n = 0\n"
        "    def __iter__(self):\n"
        "        return self\n"
        "    def __next__(self):\n"
        "        if self.n == 3:\n"
        "            raise StopIteration()\n"
        "        self.n = self.n + 1\n"
        "        return self.n\n"
        "it = Counter()\n"
        "total = 0\n"
        "for n in it:\n"
        "    total = total + n\n"
        "try:\n"
        "    next(it)\n"
        "except StopIteration:\n"
        "    done = 'yes'\n"
        "total + len(done)\n",
    ?assertMatch({ok, 9, _Env}, pyrlang:run_string(Source)).

builtin_container_constructors_and_iter_range_test() ->
    pyrlang_heap:init(),
    Source =
        "items = list(range(4))\n"
        "it = iter(items)\n"
        "first = next(it)\n"
        "second = next(it)\n"
        "pairs = list([('a', 1), ('b', 2)])\n"
        "mapping = dict(pairs, c=3)\n"
        "letters = set('abca')\n"
        "as_tuple = tuple(range(3))\n"
        "seen = list(enumerate(['x', 'y'], 5))\n"
        "kw_seen = list(enumerate(['z'], start=7))\n"
        "rev = list(reversed([1, 2, 3]))\n"
        "zipped = list(zip(['a', 'b'], [4, 5]))\n"
        "leftover_iter = iter([6, 7])\n"
        "empty_zip = list(zip([], leftover_iter))\n"
        "leftover = next(leftover_iter)\n"
        "def add(a, b):\n"
        "    return a + b\n"
        "mapped = list(map(add, [1, 2], [10, 20]))\n"
        "filtered = list(filter(None, [0, 1, '', 2]))\n"
        "first + second + mapping['a'] + mapping['b'] + mapping['c'] + len(letters) + as_tuple[2] + seen[1][0] + kw_seen[0][0] + rev[0] + zipped[1][1] + len(empty_zip) + leftover + mapped[1] + filtered[1]\n",
    ?assertMatch({ok, 63, _Env}, pyrlang:run_string(Source)).

all_and_any_builtins_reduce_iterable_truth_values_test() ->
    pyrlang_heap:init(),
    Source =
        "all([1, True, 'x']) + (any([0, '', 3]) == True) + (all([1, 0]) == False)\n",
    ?assertMatch({ok, 3, _Env}, pyrlang:run_string(Source)).

sorted_builtin_orders_iterables_with_key_and_reverse_test() ->
    pyrlang_heap:init(),
    Source =
        "items = sorted(['bbb', 'a', 'cc'], key=len, reverse=True)\n"
        "items[0] + ':' + items[2]\n",
    ?assertMatch({ok, <<"bbb:a">>, _Env}, pyrlang:run_string(Source)).

min_and_max_builtin_support_iterables_args_key_and_default_test() ->
    pyrlang_heap:init(),
    Source =
        "longest = max(['a', 'bbb', 'cc'], key=len)\n"
        "smallest = min(7, 3, 9)\n"
        "fallback = max([], default=11)\n"
        "len(longest) + smallest + fallback\n",
    ?assertMatch({ok, 17, _Env}, pyrlang:run_string(Source)).

sum_builtin_totals_iterables_with_optional_start_test() ->
    pyrlang_heap:init(),
    Source =
        "items = sum([[1], [2, 3]], [])\n"
        "sum([1, 2, 3]) + sum((4, 5), start=10) + len(items) + items[2]\n",
    ?assertMatch({ok, 31, _Env}, pyrlang:run_string(Source)).

builtin_scalar_constructors_test() ->
    pyrlang_heap:init(),
    Source =
        "empty = bytes()\n"
        "data = bytes([65, 66])\n"
        "mutable = bytearray([67])\n"
        "table = list(range(256))\n"
        "for c in b'-':\n"
        "    table[c] = chr(c)\n"
        "int('40') + int('ff', 16) + int('0b10', 0) + int(2.9) + int(True) + (float('2.5') == 2.5) + bool(data) + (bool(empty) == False) + len(mutable) + ord('A') + (chr(66) == 'B') + (chr(b'-') == '-') + (table[45] == '-') + (str(bytes([65, 66]), 'ascii') == 'AB') + (bytes([1, 15, 255]).hex() == '010fff') + (mutable.hex() == '43')\n",
    ?assertMatch({ok, 375, _Env}, pyrlang:run_string(Source)).

percent_hex_format_accepts_single_byte_values_test() ->
    pyrlang_heap:init(),
    Source = "'%x' % b'\"'\n",
    ?assertMatch({ok, <<"22">>, _Env}, pyrlang:run_string(Source)).

special_float_values_test() ->
    pyrlang_heap:init(),
    Source =
        "nan = float('nan')\n"
        "inf = float('inf')\n"
        "neg = float('-inf')\n"
        "(nan != nan) + (inf == -neg) + (inf > 1000000) + (neg < -1000000) + isinstance(inf, float) + (float.__repr__(nan) == 'nan')\n",
    ?assertMatch({ok, 6, _Env}, pyrlang:run_string(Source)).

builtin_id_is_stable_and_usable_as_dict_key_test() ->
    pyrlang_heap:init(),
    Source =
        "box = object()\n"
        "seen = {id(box): box}\n"
        "(id(box) in seen) + (seen[id(box)] is box)\n",
    ?assertMatch({ok, 2, _Env}, pyrlang:run_string(Source)).

builtin_complex_type_is_available_test() ->
    pyrlang_heap:init(),
    Source =
        "value = complex(1, 2)\n"
        "isinstance(value, complex) + (type(value) is complex)\n",
    ?assertMatch({ok, 2, _Env}, pyrlang:run_string(Source)).

builtin_scalar_and_container_types_are_class_objects_test() ->
    pyrlang_heap:init(),
    Source =
        "class Label(str):\n"
        "    pass\n"
        "isinstance('x', str) + isinstance(1, int) + isinstance([], list) + isinstance({}, dict) + isinstance((), tuple) + issubclass(frozenset, frozenset) + issubclass(memoryview, memoryview) + (None.__new__ is object.__new__) + (len(object().__repr__()) > 0) + issubclass(int, object) + (int.__repr__ is object.__repr__) + isinstance(slice(1), slice) + (slice(1, 3).stop == 3) + (('__pyrlang_builtin_constructor__' in str.__dict__) == False)\n",
    ?assertMatch({ok, 14, _Env}, pyrlang:run_string(Source)).

identity_and_negative_membership_comparisons_test() ->
    pyrlang_heap:init(),
    Source =
        "xs = []\n"
        "ys = xs\n"
        "zs = []\n"
        "(xs is ys) + (xs is not zs) + (3 not in [1, 2]) + (2 in [1, 2])\n",
    ?assertMatch({ok, 4, _Env}, pyrlang:run_string(Source)).

chained_comparisons_preserve_middle_operand_test() ->
    pyrlang_heap:init(),
    Source =
        "name = '__module__'\n"
        "(1 < 2 < 3) + (1 < 2 > 3) + (name[:2] == name[-2:] == '__')\n",
    ?assertMatch({ok, 2, _Env}, pyrlang:run_string(Source)).

source_classes_implicitly_inherit_object_test() ->
    pyrlang_heap:init(),
    Source =
        "class Box:\n"
        "    pass\n"
        "box = Box()\n"
        "issubclass(Box, object) + (box != Box()) + (Box.__name__ == 'Box') + (Box.__bases__[0] is object) + (Box.__mro__[0] is Box) + (Box.mro()[0] is Box) + (type.mro(Box)[-1] is object)\n",
    ?assertMatch({ok, 7, _Env}, pyrlang:run_string(Source)).

zero_argument_super_uses_c3_mro_test() ->
    pyrlang_heap:init(),
    Source =
        "class A:\n"
        "    def f(self):\n"
        "        return 'A'\n"
        "class B(A):\n"
        "    def f(self):\n"
        "        return super().f() + 'B'\n"
        "class C(A):\n"
        "    def f(self):\n"
        "        return super().f() + 'C'\n"
        "class D(B, C):\n"
        "    def f(self):\n"
        "        return super().f() + 'D'\n"
        "D().f()\n",
    ?assertMatch({ok, <<"ACBD">>, _Env}, pyrlang:run_string(Source)).

zero_argument_super_in_decorated_descriptor_function_uses_owner_class_test() ->
    pyrlang_heap:init(),
    Source =
        "class cached:\n"
        "    def __init__(self, func):\n"
        "        self.func = func\n"
        "    def __get__(self, instance, cls):\n"
        "        return self.func(instance)\n"
        "class Base:\n"
        "    @cached\n"
        "    def value(self):\n"
        "        return 'base'\n"
        "class Child(Base):\n"
        "    @cached\n"
        "    def value(self):\n"
        "        return super().value + ':child'\n"
        "Child().value\n",
    ?assertMatch({ok, <<"base:child">>, _Env}, pyrlang:run_string(Source)).

zero_argument_super_in_property_uses_owner_class_test() ->
    pyrlang_heap:init(),
    Source =
        "class Base:\n"
        "    @property\n"
        "    def value(self):\n"
        "        return 'base'\n"
        "class Child(Base):\n"
        "    @property\n"
        "    def value(self):\n"
        "        return super().value + ':child'\n"
        "Child().value\n",
    ?assertMatch({ok, <<"base:child">>, _Env}, pyrlang:run_string(Source)).

explicit_argument_super_uses_supplied_class_and_instance_test() ->
    pyrlang_heap:init(),
    Source =
        "class A:\n"
        "    def f(self):\n"
        "        return 'A'\n"
        "class B(A):\n"
        "    def f(self):\n"
        "        return super(B, self).f() + 'B'\n"
        "B().f()\n",
    ?assertMatch({ok, <<"AB">>, _Env}, pyrlang:run_string(Source)).

property_staticmethod_and_classmethod_test() ->
    pyrlang_heap:init(),
    Source =
        "class Box:\n"
        "    label = 'box'\n"
        "    def __init__(self, value):\n"
        "        self.raw = value\n"
        "    @property\n"
        "    def value(self):\n"
        "        return self.raw + 1\n"
        "    @value.setter\n"
        "    def value(self, new):\n"
        "        self.raw = new - 1\n"
        "    @value.deleter\n"
        "    def value(self):\n"
        "        self.raw = 0\n"
        "    @staticmethod\n"
        "    def add(a, b):\n"
        "        return a + b\n"
        "    @classmethod\n"
        "    def name(cls):\n"
        "        return cls.label\n"
        "box = Box(4)\n"
        "before = box.value\n"
        "box.value = 10\n"
        "del box.value\n"
        "deleted = box.value\n"
        "flag = False\n"
        "def raw(cls):\n"
        "    return cls.label\n"
        "raw_func = classmethod(raw).__func__\n"
        "raw_func.marker = 1\n"
        "before + deleted + Box.add(2, 3) + len(Box.name()) + len(Box.name.__func__.__name__) + (Box.name.__self__ is Box) + (type(Box.__dict__['value']) is property) + (type(Box.__dict__['add']) is staticmethod) + (type(Box.__dict__['name']) is classmethod) + (Box.__doc__ is None) + (Box.__dict__['value'].__doc__ is None) + (flag.__doc__ is None)\n",
    ?assertMatch({ok, 24, _Env}, pyrlang:run_string(Source)).

property_accepts_keyword_arguments_test() ->
    pyrlang_heap:init(),
    Source =
        "class Box:\n"
        "    def _get_value(self):\n"
        "        return 7\n"
        "    value = property(_get_value, doc='value doc')\n"
        "    other = property(fget=_get_value, doc='other doc')\n"
        "box = Box()\n"
        "box.value + box.other + (Box.__dict__['value'].__doc__ == 'value doc') + (Box.__dict__['other'].__doc__ == 'other doc')\n",
    ?assertMatch({ok, 16, _Env}, pyrlang:run_string(Source)).

builtin_descriptor_and_type_classes_can_be_subclassed_test() ->
    pyrlang_heap:init(),
    Source =
        "class Meta(type):\n"
        "    pass\n"
        "class Model(metaclass=Meta):\n"
        "    field = 5\n"
        "class MyProperty(property):\n"
        "    pass\n"
        "class MyStatic(staticmethod):\n"
        "    pass\n"
        "class MyClass(classmethod):\n"
        "    pass\n"
        "class Box:\n"
        "    label = 'Box'\n"
        "    def __init__(self, value):\n"
        "        self.raw = value\n"
        "    @MyProperty\n"
        "    def value(self):\n"
        "        return self.raw\n"
        "    @MyStatic\n"
        "    def add(a, b):\n"
        "        return a + b\n"
        "    @MyClass\n"
        "    def name(cls):\n"
        "        return cls.label\n"
        "box = Box(7)\n"
        "Model.field + box.value + Box.add(2, 3) + len(Box.name()) + issubclass(Meta, type) + issubclass(MyProperty, property)\n",
    ?assertMatch({ok, 22, _Env}, pyrlang:run_string(Source)).

generic_alias_from_builtin_class_subscription_test() ->
    pyrlang_heap:init(),
    Source =
        "from types import GenericAlias\n"
        "from types import NoneType\n"
        "alias = list[int]\n"
        "class Mine(GenericAlias):\n"
        "    pass\n"
        "data = {}\n"
        "dict.__setitem__(data, 'x', 3)\n"
        "items = [1]\n"
        "list.append(items, 2)\n"
        "translated = 'abc'.translate(str.maketrans('ab', 'xy', 'c'))\n"
        "(type(alias) == GenericAlias) + issubclass(Mine, GenericAlias) + (type(list) == type) + (type(None) == NoneType) + dict.__getitem__(data, 'x') + list.__getitem__(items, 1) + len(translated)\n",
    ?assertMatch({ok, 11, _Env}, pyrlang:run_string(Source)).

pep604_type_union_test() ->
    pyrlang_heap:init(),
    Source =
        "from types import UnionType\n"
        "union = int | str\n"
        "maybe = str | None\n"
        "(type(union) == UnionType) + (union.__args__[0] is int) + (union.__args__[1] is str) + isinstance(1, union) + isinstance('x', union) + (maybe.__args__[1] is type(None))\n",
    ?assertMatch({ok, 6, _Env}, pyrlang:run_string(Source)).

type_construction_and_new_allocation_test() ->
    pyrlang_heap:init(),
    Source =
        "namespace = {'_tuple_new': tuple.__new__}\n"
        "make = eval('lambda _cls, left, right: _tuple_new(_cls, (left, right))', namespace)\n"
        "Pair = type('Pair', (tuple,), {'__new__': make})\n"
        "pair = Pair(2, 5)\n"
        "tuple.__new__(tuple, [1, 2])[1] + pair[0] + pair[1]\n",
    ?assertMatch({ok, 9, _Env}, pyrlang:run_string(Source)).

source_classes_expose_module_name_test() ->
    pyrlang_heap:init(),
    Source =
        "class Local:\n"
        "    pass\n"
        "Local.__module__ + ':' + object.__module__\n",
    ?assertMatch({ok, <<"__main__:builtins">>, _Env}, pyrlang:run_string(Source)).

type_dict_exposes_mro_dict_and_bases_descriptors_test() ->
    pyrlang_heap:init(),
    Source =
        "class Base:\n"
        "    pass\n"
        "class Child(Base):\n"
        "    value = 40\n"
        "mro_get = type.__dict__['__mro__'].__get__\n"
        "dict_get = type.__dict__['__dict__'].__get__\n"
        "bases_get = type.__dict__['__bases__'].__get__\n"
        "(mro_get(Child)[0] is Child) + (bases_get(Child)[0] is Base) + dict_get(Child)['value']\n",
    ?assertMatch({ok, 42, _Env}, pyrlang:run_string(Source)).

iterator_objects_have_a_type_test() ->
    pyrlang_heap:init(),
    Source =
        "items = iter([])\n"
        "type(items) == type(iter(()))\n",
    ?assertMatch({ok, true, _Env}, pyrlang:run_string(Source)).

non_reference_attribute_lookup_raises_attribute_error_test() ->
    pyrlang_heap:init(),
    Source =
        "try:\n"
        "    None.missing\n"
        "except AttributeError:\n"
        "    'handled'\n",
    ?assertMatch({ok, <<"handled">>, _Env}, pyrlang:run_string(Source)).

exception_instances_support_dynamic_attributes_test() ->
    pyrlang_heap:init(),
    Source =
        "try:\n"
        "    raise Exception('boom')\n"
        "except Exception as e:\n"
        "    before = hasattr(e, 'detail')\n"
        "    e.detail = 42\n"
        "    str(before) + ':' + str(e.detail)\n",
    ?assertMatch({ok, <<"False:42">>, _Env}, pyrlang:run_string(Source)).

instance_attribute_lookup_falls_back_to_getattr_test() ->
    pyrlang_heap:init(),
    Source =
        "class Lazy:\n"
        "    def __getattr__(self, name):\n"
        "        if name == 'answer':\n"
        "            return 42\n"
        "        raise AttributeError(name)\n"
        "obj = Lazy()\n"
        "try:\n"
        "    obj.missing\n"
        "except AttributeError:\n"
        "    obj.answer\n",
    ?assertMatch({ok, 42, _Env}, pyrlang:run_string(Source)).

range_is_lazy_but_iterable_test() ->
    pyrlang_heap:init(),
    Source =
        "items = iter(range(1 << 1000))\n"
        "next(items) + next(items) + tuple(range(3))[2] + isinstance(range(0), range)\n",
    ?assertMatch({ok, 4, _Env}, pyrlang:run_string(Source)).

operator_overloading_test() ->
    pyrlang_heap:init(),
    Source =
        "class Box:\n"
        "    def __init__(self, value):\n"
        "        self.value = value\n"
        "    def __add__(self, other):\n"
        "        return Box(self.value + other.value)\n"
        "    def __radd__(self, other):\n"
        "        return Box(self.value + other)\n"
        "    def __eq__(self, other):\n"
        "        return self.value == other.value\n"
        "result = Box(2) + Box(3)\n"
        "reflected = 4 + Box(6)\n"
        "result.value + reflected.value + (result == Box(5))\n",
    ?assertMatch({ok, 16, _Env}, pyrlang:run_string(Source)).

callable_instance_dunder_call_test() ->
    pyrlang_heap:init(),
    Source =
        "class AddOne:\n"
        "    def __call__(self, value):\n"
        "        return value + 1\n"
        "fn = AddOne()\n"
        "fn(4)\n",
    ?assertMatch({ok, 5, _Env}, pyrlang:run_string(Source)).

builtin_callable_predicate_test() ->
    pyrlang_heap:init(),
    Source =
        "def fn():\n"
        "    return 1\n"
        "class Plain:\n"
        "    pass\n"
        "class Runner:\n"
        "    def __call__(self):\n"
        "        return 1\n"
        "callable(fn) + callable(Plain) + callable(Runner()) + (not callable(Plain())) + (not callable(42))\n",
    ?assertMatch({ok, 5, _Env}, pyrlang:run_string(Source)).

mutable_container_methods_test() ->
    pyrlang_heap:init(),
    Source =
        "xs = []\n"
        "xs.append(1)\n"
        "xs.extend([2, 3])\n"
        "xs.insert(1, 9)\n"
        "last = xs.pop()\n"
        "middle = xs.pop(1)\n"
        "xs.__setitem__(0, 4)\n"
        "xs.reverse()\n"
        "list.insert(xs, -99, 8)\n"
        "cleared = [1]\n"
        "cleared.clear()\n"
        "data = {}\n"
        "data.set('last', last)\n"
        "data.__setitem__('bonus', 5)\n"
        "pair = (2, 3, 2)\n"
        "len(xs) + data.get('last') + middle + xs.__getitem__(2) + data.__getitem__('bonus') + xs.__contains__(4) + xs.__getitem__(0) + xs.count(2) + xs.index(4) + (xs.index(2, 1) == 1) + 'banana'.count('ana') + 'aaaa'.count('aa') + [None, 1, None].count(None) + pair.index(3) + pair.count(2) + (pair.index(2, 1) == 2) + (len(cleared) == 0)\n",
    ?assertMatch({ok, 47, _Env}, pyrlang:run_string(Source)).

sequence_concatenation_test() ->
    pyrlang_heap:init(),
    Source =
        "xs = ['all_feature_names'] + ['nested_scopes', 'generators']\n"
        "pair = (1, 2) + (3, 4)\n"
        "ys = [0] * 3\n"
        "word = 'ab' * 2\n"
        "triple = (5,) * 2\n"
        "len(xs) + pair[0] + pair[3] + len(ys) + len(word) + triple[1]\n",
    ?assertMatch({ok, 20, _Env}, pyrlang:run_string(Source)).

dict_common_methods_test() ->
    pyrlang_heap:init(),
    Source =
        "data = {'a': 1}\n"
        "missing = data.get('missing', 4)\n"
        "existing = data.setdefault('a', 9)\n"
        "inserted = data.setdefault('b')\n"
        "data.update({'c': 3}, d=4)\n"
        "copied = data.copy()\n"
        "data.clear()\n"
        "made = dict.fromkeys(['x', 'y'], 7)\n"
        "seen = set(['a']).__contains__('a') + copied.__contains__('a')\n"
        "missing + existing + (inserted == None) + len(data.keys()) + len(copied.values()) + len(copied.items()) + seen + copied['c'] + copied['d'] + made['x'] + made['y']\n",
    ?assertMatch({ok, 37, _Env}, pyrlang:run_string(Source)).

dict_dunder_getitem_missing_key_raises_keyerror_test() ->
    pyrlang_heap:init(),
    Source =
        "import operator\n"
        "caught = 0\n"
        "try:\n"
        "    dict.__getitem__({}, 'missing')\n"
        "except KeyError:\n"
        "    caught += 1\n"
        "try:\n"
        "    operator.getitem({}, 'missing')\n"
        "except KeyError:\n"
        "    caught += 1\n"
        "caught\n",
    ?assertMatch({ok, 2, _Env}, pyrlang:run_string(Source)).

dict_subclass_super_can_access_dict_methods_test() ->
    pyrlang_heap:init(),
    Source =
        "class Query(dict):\n"
        "    def lists(self):\n"
        "        return list(super().items())\n"
        "q = Query()\n"
        "q['next'] = '/admin/login/'\n"
        "q.lists()[0][0] + ':' + q.lists()[0][1]\n",
    ?assertMatch({ok, <<"next:/admin/login/">>, _Env}, pyrlang:run_string(Source)).

dict_subclass_subscript_assignment_uses_setitem_override_test() ->
    pyrlang_heap:init(),
    Source =
        "class Query(dict):\n"
        "    def __setitem__(self, key, value):\n"
        "        super().__setitem__(key, [value])\n"
        "q = Query()\n"
        "q['next'] = '/admin/'\n"
        "q['next'][0]\n",
    ?assertMatch({ok, <<"/admin/">>, _Env}, pyrlang:run_string(Source)).

dict_and_set_pop_methods_test() ->
    pyrlang_heap:init(),
    Source =
        "data = {'a': 1}\n"
        "values = set(['x', 'y'])\n"
        "removed = values.pop()\n"
        "values.update(['z'], ['w'])\n"
        "data.pop('a') + data.pop('missing', 2) + len(values) + (removed not in values) + ('z' in values) + ('w' in values)\n",
    ?assertMatch({ok, 9, _Env}, pyrlang:run_string(Source)).

dynamic_attribute_and_instance_builtins_test() ->
    pyrlang_heap:init(),
    Source =
        "class A:\n"
        "    pass\n"
        "class B(A):\n"
        "    pass\n"
        "obj = B()\n"
        "setattr(obj, 'name', 'box')\n"
        "(getattr(obj, 'name') == 'box') + (getattr(obj, 'missing', 'fallback') == 'fallback') + hasattr(obj, 'name') + isinstance(obj, A) + issubclass(B, A) + (type(obj) == B) + (obj.__class__ is B)\n",
    ?assertMatch({ok, 7, _Env}, pyrlang:run_string(Source)).

instance_dunder_class_assignment_changes_runtime_class_test() ->
    pyrlang_heap:init(),
    Source =
        "class Empty:\n"
        "    pass\n"
        "class Field:\n"
        "    pass\n"
        "obj = Empty()\n"
        "obj.__class__ = Field\n"
        "isinstance(obj, Field) + (type(obj).__name__ == 'Field')\n",
    ?assertMatch({ok, 2, _Env}, pyrlang:run_string(Source)).

dunder_class_property_participates_in_isinstance_test() ->
    pyrlang_heap:init(),
    Source =
        "from operator import attrgetter\n"
        "class Target:\n"
        "    pass\n"
        "class Proxy:\n"
        "    @property\n"
        "    def __class__(self):\n"
        "        return Target\n"
        "proxy = Proxy()\n"
        "(proxy.__class__ is Target) + isinstance(proxy, Target) + isinstance(proxy, Proxy) + (attrgetter('__class__')(proxy) is Target)\n",
    ?assertMatch({ok, 4, _Env}, pyrlang:run_string(Source)).

container_equality_compares_values_test() ->
    pyrlang_heap:init(),
    Source =
        "({} == {}) + ({} != {'x': 1}) + ({'x': [1, 2]} == {'x': [1, 2]}) + ([1, {'a': 2}] == [1, {'a': 2}]) + ({1, 2} == {2, 1})\n",
    ?assertMatch({ok, 5, _Env}, pyrlang:run_string(Source)).

tuple_subclass_new_can_consume_keyword_only_arguments_test() ->
    pyrlang_heap:init(),
    Source =
        "class Immutable(tuple):\n"
        "    def __new__(cls, *args, warning='default', **kwargs):\n"
        "        self = tuple.__new__(cls, *args, **kwargs)\n"
        "        self.warning = warning\n"
        "        return self\n"
        "items = Immutable([1], warning='custom')\n"
        "len(items) + (items.warning == 'custom')\n",
    ?assertMatch({ok, 2, _Env}, pyrlang:run_string(Source)).

nested_functions_can_reference_their_own_name_test() ->
    pyrlang_heap:init(),
    Source =
        "def outer(function):\n"
        "    def apply_next_model(model):\n"
        "        next_function = apply_next_model.func\n"
        "        return next_function(model)\n"
        "    apply_next_model.func = function\n"
        "    return apply_next_model(41)\n"
        "outer(lambda value: value + 1)\n",
    ?assertMatch({ok, 42, _Env}, pyrlang:run_string(Source)).

nested_function_attributes_are_closure_local_test() ->
    pyrlang_heap:init(),
    Source =
        "def make(value):\n"
        "    def inner(extra):\n"
        "        return inner.func + extra\n"
        "    inner.func = value\n"
        "    return inner\n"
        "first = make(3)\n"
        "second = make(5)\n"
        "first(4) + second(6)\n",
    ?assertMatch({ok, 18, _Env}, pyrlang:run_string(Source)).

decorated_nested_function_keeps_lexical_self_name_after_wraps_test() ->
    pyrlang_heap:init(),
    Source =
        "from functools import wraps\n"
        "def decorator(func):\n"
        "    @wraps(func)\n"
        "    def wrapper():\n"
        "        wrapper.x = 1\n"
        "        return func() + wrapper.x\n"
        "    return wrapper\n"
        "@decorator\n"
        "def target():\n"
        "    return 41\n"
        "target()\n",
    ?assertMatch({ok, 42, _Env}, pyrlang:run_string(Source)).

delattr_and_del_attribute_remove_existing_attributes_test() ->
    pyrlang_heap:init(),
    Source =
        "class Box:\n"
        "    value = 41\n"
        "    def __setattr__(self, name, value):\n"
        "        raise TypeError('frozen')\n"
        "box = Box()\n"
        "object.__setattr__(box, 'name', 'pyrlang')\n"
        "delattr(Box, 'value')\n"
        "object.__delattr__(box, 'name')\n"
        "(not hasattr(Box, 'value')) and (not hasattr(box, 'name'))\n",
    ?assertMatch({ok, true, _Env}, pyrlang:run_string(Source)).

function_objects_support_actor_local_attributes_test() ->
    pyrlang_heap:init(),
    Source =
        "def inner():\n"
        "    return 1\n"
        "inner._mask_wrapped = False\n"
        "inner.__dict__.update({})\n"
        "(inner.__module__ == '__main__') + (inner.__name__ == 'inner') + (getattr(inner, '_mask_wrapped', True) == False) + hasattr(inner, '__dict__')\n",
    ?assertMatch({ok, 4, _Env}, pyrlang:run_string(Source)).

function_objects_expose_minimal_code_metadata_test() ->
    pyrlang_heap:init(),
    Source =
        "def inner(a, b):\n"
        "    return a + b\n"
        "inner.__code__.co_argcount + (type(inner.__code__).__name__ == 'code')\n",
    ?assertMatch({ok, 3, _Env}, pyrlang:run_string(Source)).

instance_dunder_dict_writes_back_to_attributes_test() ->
    pyrlang_heap:init(),
    Source =
        "class Box:\n"
        "    answer = 41\n"
        "box = Box()\n"
        "box.__dict__['value'] = 42\n"
        "total = 0\n"
        "for name in Box.__dict__:\n"
        "    if name == 'answer':\n"
        "        total = total + 1\n"
        "box.value + total\n",
    ?assertMatch({ok, 43, _Env}, pyrlang:run_string(Source)).

instance_dunder_dict_assignment_replaces_attributes_test() ->
    pyrlang_heap:init(),
    Source =
        "class Box:\n"
        "    pass\n"
        "box = Box()\n"
        "box.old = 1\n"
        "box.__dict__ = {'value': 42}\n"
        "other = Box()\n"
        "other.__dict__ = box.__dict__\n"
        "box.value + other.value + hasattr(box, 'old')\n",
    ?assertMatch({ok, 84, _Env}, pyrlang:run_string(Source)).

instance_dict_copy_returns_regular_dict_test() ->
    pyrlang_heap:init(),
    Source =
        "class Box:\n"
        "    pass\n"
        "box = Box()\n"
        "box.value = 41\n"
        "data = box.__dict__.copy()\n"
        "made = dict(box.__dict__)\n"
        "contains = ('value' in box.__dict__) + ('missing' not in box.__dict__)\n"
        "data['value'] + made['value'] + isinstance(data, dict) + contains\n",
    ?assertMatch({ok, 85, _Env}, pyrlang:run_string(Source)).

nested_classes_in_class_body_test() ->
    pyrlang_heap:init(),
    Source =
        "class Model:\n"
        "    class Meta:\n"
        "        app_label = 'todos'\n"
        "    def label(self):\n"
        "        return self.Meta.app_label\n"
        "Model.Meta.app_label + ':' + Model().label()\n",
    ?assertMatch({ok, <<"todos:todos">>, _Env}, pyrlang:run_string(Source)).

class_body_if_and_for_statements_test() ->
    pyrlang_heap:init(),
    Source =
        "class Settings:\n"
        "    enabled = True\n"
        "    if enabled:\n"
        "        value = 1\n"
        "    else:\n"
        "        value = 9\n"
        "    for n in [1, 2, 3]:\n"
        "        last = n\n"
        "Settings.value + Settings.last + Settings.n\n",
    ?assertMatch({ok, 7, _Env}, pyrlang:run_string(Source)).

class_body_executes_supported_statement_suites_test() ->
    pyrlang_heap:init(),
    Source =
        "class Manager:\n"
        "    def __enter__(self):\n"
        "        return 'entered'\n"
        "    def __exit__(self, t, v, tb):\n"
        "        return False\n"
        "class C:\n"
        "    import os\n"
        "    i = 0\n"
        "    total = 0\n"
        "    temp = 'remove'\n"
        "    left = 1\n"
        "    right = 2\n"
        "    del temp, left, right\n"
        "    while i < 3:\n"
        "        total = total + i\n"
        "        i = i + 1\n"
        "    try:\n"
        "        raise ValueError('bad')\n"
        "    except ValueError:\n"
        "        handled = 'yes'\n"
        "    finally:\n"
        "        done = 'done'\n"
        "    with Manager() as value:\n"
        "        entered = value\n"
        "str(hasattr(C, 'temp') or hasattr(C, 'left') or hasattr(C, 'right')) + str(C.total) + C.handled + C.done + C.entered + C.os.__name__\n",
    ?assertMatch({ok, <<"False3yesdoneenteredos">>, _Env}, pyrlang:run_string(Source)).

class_creation_calls_set_name_hooks_test() ->
    pyrlang_heap:init(),
    Source =
        "class Marker:\n"
        "    def __set_name__(self, owner, name):\n"
        "        owner.bound_name = name\n"
        "class Box:\n"
        "    field = Marker()\n"
        "Box.bound_name\n",
    ?assertMatch({ok, <<"field">>, _Env}, pyrlang:run_string(Source)).

set_name_hooks_can_call_metaclass_methods_test() ->
    pyrlang_heap:init(),
    Source =
        "class Meta(type):\n"
        "    def record(cls, name):\n"
        "        cls.bound_name = name\n"
        "class Marker:\n"
        "    def __set_name__(self, owner, name):\n"
        "        owner.record(name)\n"
        "Box = type.__new__(Meta, 'Box', (), {'field': Marker()})\n"
        "Box.bound_name\n",
    ?assertMatch({ok, <<"field">>, _Env}, pyrlang:run_string(Source)).

subscript_read_and_write_test() ->
    pyrlang_heap:init(),
    Source =
        "xs = [1, 2, 3]\n"
        "xs[1] = 5\n"
        "data = {}\n"
        "data['value'] = xs[1]\n"
        "pair = (10, 20)\n"
        "data['value'] + xs[-1] + pair[True] + pair[False]\n",
    ?assertMatch({ok, 38, _Env}, pyrlang:run_string(Source)).

instance_slice_calls_getitem_with_slice_object_test() ->
    pyrlang_heap:init(),
    Source =
        "class Items:\n"
        "    def __getitem__(self, key):\n"
        "        return (key.start is None) + key.stop + key.step\n"
        "Items()[:10:2]\n",
    ?assertMatch({ok, 13, _Env}, pyrlang:run_string(Source)).

len_calls_instance_dunder_len_test() ->
    pyrlang_heap:init(),
    Source =
        "class Items:\n"
        "    def __len__(self):\n"
        "        return 42\n"
        "len(Items())\n",
    ?assertMatch({ok, 42, _Env}, pyrlang:run_string(Source)).

tuple_subscript_key_test() ->
    pyrlang_heap:init(),
    Source =
        "data = {}\n"
        "data[1, 2] = 5\n"
        "data[(1, 2)]\n",
    ?assertMatch({ok, 5, _Env}, pyrlang:run_string(Source)).

del_subscript_statement_test() ->
    pyrlang_heap:init(),
    Source =
        "xs = [1, 2, 3]\n"
        "data = {'value': 4}\n"
        "del xs[1]\n"
        "del data['value']\n"
        "len(xs) + xs[1] + ('value' in data)\n",
    ?assertMatch({ok, 5, _Env}, pyrlang:run_string(Source)).

destructuring_assignment_and_for_target_test() ->
    pyrlang_heap:init(),
    Source =
        "first, second = (1, 2)\n"
        "[left, right] = [3, 4]\n"
        "head, *middle, tail = [7, 8, 9, 10]\n"
        "_, *token_info = ('kind', 11, 12)\n"
        "total = 0\n"
        "for name, value in [('a', 5), ('b', 6)]:\n"
        "    total = total + value\n"
        "first + second + left + right + total + head + middle[0] + tail + token_info[1]\n",
    ?assertMatch({ok, 58, _Env}, pyrlang:run_string(Source)).

augmented_assignment_test() ->
    pyrlang_heap:init(),
    Source =
        "class Box:\n"
        "    value = 1\n"
        "Box.value += 2\n"
        "xs = [4]\n"
        "xs[0] += 5\n"
        "total = 6\n"
        "total += 7\n"
        "Box.value + xs[0] + total\n",
    ?assertMatch({ok, 25, _Env}, pyrlang:run_string(Source)).

chained_assignment_test() ->
    pyrlang_heap:init(),
    Source =
        "left = right = 3\n"
        "items = [0]\n"
        "box = {}\n"
        "items[0] = box['value'] = 4\n"
        "left + right + items[0] + box['value']\n",
    ?assertMatch({ok, 14, _Env}, pyrlang:run_string(Source)).

simple_slice_subscripts_test() ->
    pyrlang_heap:init(),
    Source =
        "xs = [0, 1, 2, 3]\n"
        "word = 'pyrlang'\n"
        "pair = (0, 1, 2, 3)\n"
        "part = xs[1:3]\n"
        "tail = xs[2:]\n"
        "head = word[:3]\n"
        "none_tail = word[None:None]\n"
        "subpair = pair[-3:-1]\n"
        "xs[:] = xs[1:]\n"
        "del xs[1:2]\n"
        "part[0] + part[1] + tail[0] + len(head) + (none_tail == word) + (word.rfind('g', 0, None) == 6) + (word.rindex('g') == 6) + (word.index('r') == 2) + subpair[0] + subpair[1] + xs[0] + xs[1]\n",
    ?assertMatch({ok, 19, _Env}, pyrlang:run_string(Source)),
    ?assertEqual({ok, <<"dcba">>}, pyrlang:eval_expr("'abcde'[-2::-1]")),
    ?assertEqual({ok, <<"eca">>}, pyrlang:eval_expr("'abcde'[::-2]")),
    ?assertEqual({ok, 4}, pyrlang:eval_expr("len(bytes([222, 18, 4, 149])[:4])")),
    ?assertMatch(
        {ok, 2500072158, _Env},
        pyrlang:run_string("import struct\nstruct.unpack('<I', bytes([222, 18, 4, 149])[:4])[0]\n")
    ).

default_and_keyword_arguments_test() ->
    pyrlang_heap:init(),
    Source =
        "def combine(a, b=2, c=3):\n"
        "    return a + b + c\n"
        "def default_items(items=[1, 2], mapping={'x': 3}):\n"
        "    return len(items) + mapping['x']\n"
        "combine(1, c=10) + default_items()\n",
    ?assertMatch({ok, 18, _Env}, pyrlang:run_string(Source)).

positional_only_and_keyword_only_parameters_test() ->
    pyrlang_heap:init(),
    Source =
        "def read(self, size=-1, /):\n"
        "    return self + size\n"
        "def combine(a, /, b=2, *, c=3, **kwargs):\n"
        "    return a + b + c + kwargs['bonus']\n"
        "read(10, 5) + combine(1, 2, c=4, bonus=8)\n",
    ?assertMatch({ok, 30, _Env}, pyrlang:run_string(Source)).

function_header_allows_parenthesized_default_before_posonly_marker_test() ->
    pyrlang_heap:init(),
    Source =
        "def size(other=(), /, **kwds):\n"
        "    return len(other) + len(kwds)\n"
        "size(alpha=1)\n",
    ?assertMatch({ok, 1, _Env}, pyrlang:run_string(Source)).

function_type_parameters_are_ignored_at_runtime_test() ->
    pyrlang_heap:init(),
    Source =
        "def reveal[T](obj: T, /) -> T:\n"
        "    return obj\n"
        "async def later[T](obj: T) -> T:\n"
        "    return obj\n"
        "reveal(42) + (later(1).close() is None)\n",
    ?assertMatch({ok, 43, _Env}, pyrlang:run_string(Source)).

type_alias_statement_creates_lazy_runtime_alias_test() ->
    pyrlang_heap:init(),
    Source =
        "Callable = {(..., 1): 1}\n"
        "Any = 1\n"
        "type Alias = 41\n"
        "type Func = Callable[..., Any]\n"
        "Alias.__value__ + Func.__value__ + (Func.__name__ == 'Func')\n",
    ?assertMatch({ok, 43, _Env}, pyrlang:run_string(Source)).

function_parameter_and_return_annotations_are_ignored_test() ->
    pyrlang_heap:init(),
    Source =
        "module_value: int = 2\n"
        "module_missing: str\n"
        "def use(value: int, /) -> int:\n"
        "    return value + 1\n"
        "class Box:\n"
        "    value: int = 4\n"
        "    missing: str\n"
        "use(41) + module_value + Box.value + hasattr(Box, 'missing') + ('module_missing' in globals())\n",
    ?assertMatch({ok, 48, _Env}, pyrlang:run_string(Source)).

varargs_kwargs_and_call_expansion_test() ->
    pyrlang_heap:init(),
    Source =
        "def collect(a, *args, **kwargs):\n"
        "    more = args + (4,)\n"
        "    return a + len(args) + kwargs['bonus'] + more[0] + more[2]\n"
        "xs = [2, 3]\n"
        "kw = {}\n"
        "kw['bonus'] = 4\n"
        "first = collect(1, 2, 3, bonus=4)\n"
        "second = collect(1, *xs, **kw)\n"
        "first + second\n",
    ?assertMatch({ok, 26, _Env}, pyrlang:run_string(Source)).

builtin_zip_accepts_strict_keyword_test() ->
    pyrlang_heap:init(),
    Source =
        "pairs = list(zip([1, 2], [3, 4], strict=True))\n"
        "pairs[1][0] + pairs[1][1]\n",
    ?assertMatch({ok, 6, _Env}, pyrlang:run_string(Source)).

boolean_membership_and_list_comprehension_test() ->
    pyrlang_heap:init(),
    Source =
        "xs = [1, 2, 3, 4]\n"
        "ys = [x * 2 for x in xs if x in [2, 4]]\n"
        "flag = not False and (3 in xs) or False\n"
        "ys[0] + ys[1] + len(ys) + flag\n",
    ?assertMatch({ok, 15, _Env}, pyrlang:run_string(Source)).

dict_and_set_comprehensions_test() ->
    pyrlang_heap:init(),
    Source =
        "xs = [1, 2, 3, 4]\n"
        "data = {x: x * 2 for x in xs if x in [2, 4]}\n"
        "seen = {x * 2 for x in xs if x in [1, 3]}\n"
        "data[2] + data[4] + len(seen) + (6 in seen)\n",
    ?assertMatch({ok, 15, _Env}, pyrlang:run_string(Source)).

comprehension_destructuring_target_and_string_prefix_test() ->
    pyrlang_heap:init(),
    Source =
        "items = [(0, 'alpha', False), (1, '_skip', False), (2, 'pkg', True)]\n"
        "names = [name for _, name, is_pkg in items if not is_pkg and not name.startswith('_')]\n"
        "names[0]\n",
    ?assertMatch({ok, <<"alpha">>, _Env}, pyrlang:run_string(Source)).

dict_set_and_generator_destructuring_comprehension_targets_test() ->
    pyrlang_heap:init(),
    Source =
        "items = [(1, 2), (3, 4)]\n"
        "data = {left: right for left, right in items}\n"
        "seen = {left + right for left, right in items}\n"
        "products = list(left * right for left, right in items)\n"
        "data[1] + data[3] + len(seen) + products[0] + products[1]\n",
    ?assertMatch({ok, 22, _Env}, pyrlang:run_string(Source)).

nested_comprehension_for_clauses_test() ->
    pyrlang_heap:init(),
    Source =
        "groups = [[1, 2], [3]]\n"
        "values = {opt for group in groups for opt in group if opt != 2}\n"
        "pairs = [(left, right) for left in [1, 3] for right in [2, 4] if right == left + 1]\n"
        "len(values) + (1 in values) + (3 in values) + pairs[0][0] + pairs[1][1]\n",
    ?assertMatch({ok, 9, _Env}, pyrlang:run_string(Source)).

async_comprehension_clauses_parse_like_regular_iteration_test() ->
    pyrlang_heap:init(),
    Source =
        "async def collect():\n"
        "    values = [item async for item in [1, 2, 3] if item != 2]\n"
        "    return values[0] + values[1]\n"
        "await collect()\n",
    ?assertMatch({ok, 4, _Env}, pyrlang:run_string(Source)).

comprehension_targets_do_not_overwrite_outer_bindings_test() ->
    pyrlang_heap:init(),
    Source =
        "def keep(name):\n"
        "    items = [('inner', 1)]\n"
        "    pairs = [(name, value) for name, value in items]\n"
        "    leaked = 'value' in locals()\n"
        "    return name + ':' + pairs[0][0] + ':' + str(leaked)\n"
        "keep('outer')\n",
    ?assertMatch({ok, <<"outer:inner:False">>, _Env}, pyrlang:run_string(Source)).

set_union_operator_and_method_test() ->
    pyrlang_heap:init(),
    Source =
        "left = {'a'}\n"
        "right = {'b'}\n"
        "extra = {'c': 1}\n"
        "values = (left | right).union(extra)\n"
        "same = values & {'a', 'c'}\n"
        "len(values) + ('a' in values) + ('b' in values) + ('c' in values) + len(same) + values.issuperset({'a', 'b'}) + same.issubset(values) + values.isdisjoint({'z'})\n",
    ?assertMatch({ok, 11, _Env}, pyrlang:run_string(Source)).

set_difference_operator_test() ->
    pyrlang_heap:init(),
    Source =
        "items = {'a', 'b', 'c'} - {'b'}\n"
        "len(items) + ('a' in items) + ('b' not in items) + ('c' in items)\n",
    ?assertMatch({ok, 5, _Env}, pyrlang:run_string(Source)).

set_common_methods_test() ->
    pyrlang_heap:init(),
    Source =
        "items = {'a', 'b', 'c'}\n"
        "diff = items.difference({'b'}, {'z'})\n"
        "inter = items.intersection({'b', 'c'}, {'c', 'd'})\n"
        "sym = items.symmetric_difference({'c', 'd'})\n"
        "copy = items.copy()\n"
        "copy.difference_update({'a'})\n"
        "copy.intersection_update({'b', 'z'})\n"
        "copy.symmetric_difference_update({'z'})\n"
        "copy.remove('z')\n"
        "try:\n"
        "    copy.remove('missing')\n"
        "except KeyError:\n"
        "    missing = 1\n"
        "len(diff) + ('a' in diff) + ('b' not in diff) + len(inter) + ('c' in inter) + len(sym) + ('d' in sym) + len(copy) + ('z' not in copy) + missing\n",
    ?assertMatch({ok, 13, _Env}, pyrlang:run_string(Source)).

list_literal_starred_unpacking_test() ->
    pyrlang_heap:init(),
    Source =
        "def values():\n"
        "    return [1, 2]\n"
        "items = [0, *values(), 3]\n"
        "items[0] + items[1] + items[2] + items[3]\n",
    ?assertMatch({ok, 6, _Env}, pyrlang:run_string(Source)).

tuple_literal_starred_unpacking_test() ->
    pyrlang_heap:init(),
    Source =
        "xs = (1, 2)\n"
        "items = (*xs, 3)\n"
        "len(items) + items[2]\n",
    ?assertMatch({ok, 6, _Env}, pyrlang:run_string(Source)).

set_literal_starred_unpacking_test() ->
    pyrlang_heap:init(),
    Source =
        "left = {1, 2}\n"
        "right = [2, 3]\n"
        "items = {*left, *right, 4}\n"
        "len(items) + (1 in items) + (4 in items)\n",
    ?assertMatch({ok, 6, _Env}, pyrlang:run_string(Source)).

lambda_expression_test() ->
    pyrlang_heap:init(),
    Source =
        "add = lambda x, y: x + y\n"
        "add(2, 5)\n",
    ?assertMatch({ok, 7, _Env}, pyrlang:run_string(Source)).

lambda_varargs_kwargs_and_defaults_test() ->
    pyrlang_heap:init(),
    Source =
        "f = lambda first=1, *args, **kwargs: first + len(args) + kwargs['extra']\n"
        "f(3, 4, 5, extra=6)\n",
    ?assertMatch({ok, 11, _Env}, pyrlang:run_string(Source)).

lambda_yield_expression_creates_generator_test() ->
    pyrlang_heap:init(),
    Source =
        "gen = (lambda: (yield))()\n"
        "type(gen) == type((lambda: (yield))())\n",
    ?assertMatch({ok, true, _Env}, pyrlang:run_string(Source)).

conditional_expression_and_parenthesized_continuation_test() ->
    pyrlang_heap:init(),
    Source =
        "class Settings:\n"
        "    FORCE_SCRIPT_NAME = None\n"
        "settings = Settings()\n"
        "def choose(value):\n"
        "    return (\n"
        "        '/' if value is None else value\n"
        "    )\n"
        "choose(settings.FORCE_SCRIPT_NAME)\n",
    ?assertMatch({ok, <<"/">>, _Env}, pyrlang:run_string(Source)).

conditional_expression_allows_lambda_else_branch_test() ->
    pyrlang_heap:init(),
    Source =
        "maker = [str] if False else [lambda n: int(n != 1)]\n"
        "maker[0](2)\n",
    ?assertMatch({ok, 1, _Env}, pyrlang:run_string(Source)).

parenthesized_continuation_allows_comment_lines_test() ->
    pyrlang_heap:init(),
    Source =
        "def check(value):\n"
        "    return (value == 1 or\n"
        "            # comment between continued expression lines\n"
        "            value == 2)\n"
        "check(2)\n",
    ?assertMatch({ok, true, _Env}, pyrlang:run_string(Source)).

named_expression_test() ->
    pyrlang_heap:init(),
    Source =
        "empty = None\n"
        "class Box:\n"
        "    value = 5\n"
        "box = Box()\n"
        "if (cached := box.value) is not empty:\n"
        "    result = cached + 1\n"
        "if direct := box.value:\n"
        "    result = result + direct\n"
        "result\n",
    ?assertMatch({ok, 11, _Env}, pyrlang:run_string(Source)).

named_expression_in_default_argument_binds_outer_scope_test() ->
    pyrlang_heap:init(),
    Source =
        "def check(value=(sentinel := object())):\n"
        "    return value is sentinel\n"
        "check()\n",
    ?assertMatch({ok, true, _Env}, pyrlang:run_string(Source)).

loop_break_and_continue_preserve_body_assignments_test() ->
    pyrlang_heap:init(),
    Source =
        "for item in [1]:\n"
        "    before_break = item + 1\n"
        "    break\n"
        "for item in [2]:\n"
        "    before_continue = item + 1\n"
        "    continue\n"
        "before_break + before_continue\n",
    ?assertMatch({ok, 5, _Env}, pyrlang:run_string(Source)).

percent_operator_and_string_formatting_test() ->
    pyrlang_heap:init(),
    Source =
        "left = 10 % 4\n"
        "text = '.dev%s' % 'abc'\n"
        "pair = '%s:%d' % ('v', 3)\n"
        "zero = 'n-%d' % 0\n"
        "mapped = '%(left)s:%(right)d:%(hex)x' % {'left': 'L', 'right': 5, 'hex': 255}\n"
        "ignored_mapping = 'plain%%' % {'unused': 1}\n"
        "ignored_list = 'plain' % []\n"
        "braced = '\\\\u{0:04x}:{1}:{name!s}:{{}}'.format(10, 'ok', name='N')\n"
        "list_value = '%s' % [1, 2]\n"
        "def sample():\n"
        "    return 1\n"
        "func_value = '%s' % sample\n"
        "class Label:\n"
        "    def __str__(self):\n"
        "        return 'label'\n"
        "object_value = '%s' % Label()\n"
        "text + ':' + pair + ':' + zero + ':' + mapped + ':' + ignored_mapping + ':' + ignored_list + ':' + str(left) + ':' + braced + ':' + str('abc'.isascii()) + str(chr(233).isascii()) + ':' + str(len(list_value) > 0) + ':' + str(len(func_value) > 0) + ':' + object_value\n",
    ?assertMatch(
        {ok, <<".devabc:v:3:n-0:L:5:ff:plain%:plain:2:\\u000a:ok:N:{}:TrueFalse:True:True:label">>,
            _Env},
        pyrlang:run_string(Source)
    ).

percent_formatting_preserves_unicode_codepoints_test() ->
    pyrlang_heap:init(),
    Source =
        "ellipsis = chr(8230)\n"
        "apostrophe = chr(8217)\n"
        "text = 'filter' + ellipsis\n"
        "mapped = '%(msg)s' % {'msg': 'don' + apostrophe + 't'}\n"
        "('%s' % text) + ':' + mapped + ':' + ('%3s' % chr(233))\n",
    Expected = unicode:characters_to_binary(["filter", 8230, ":don", 8217, "t:  ", 233]),
    ?assertMatch({ok, Expected, _Env}, pyrlang:run_string(Source)).

generator_expression_in_call_test() ->
    pyrlang_heap:init(),
    Source =
        "version = (5, 2, 10)\n"
        "parts = 2\n"
        "'.'.join(str(x) for x in version[:parts])\n",
    ?assertMatch({ok, <<"5.2">>, _Env}, pyrlang:run_string(Source)).

parenthesized_generator_expression_test() ->
    pyrlang_heap:init(),
    Source =
        "items = [1, 2, 3]\n"
        "values = (x * 2 for x in items if x != 2)\n"
        "list(values)[1]\n",
    ?assertMatch({ok, 6, _Env}, pyrlang:run_string(Source)).

assert_statement_test() ->
    pyrlang_heap:init(),
    Source =
        "assert 1 + 1 == 2\n"
        "try:\n"
        "    assert False\n"
        "except AssertionError:\n"
        "    'caught'\n",
    ?assertMatch({ok, <<"caught">>, _Env}, pyrlang:run_string(Source)).

raise_from_statement_test() ->
    pyrlang_heap:init(),
    Source =
        "try:\n"
        "    raise ValueError('bad') from None\n"
        "except ValueError:\n"
        "    'caught'\n",
    ?assertMatch({ok, <<"caught">>, _Env}, pyrlang:run_string(Source)).

raise_from_ignores_from_inside_string_literals_test() ->
    pyrlang_heap:init(),
    Source =
        "try:\n"
        "    raise KeyError('pop from empty WeakSet') from None\n"
        "except KeyError:\n"
        "    'caught'\n",
    ?assertMatch({ok, <<"caught">>, _Env}, pyrlang:run_string(Source)).

raw_string_literal_test() ->
    pyrlang_heap:init(),
    Source = "r\"(\\d+|[a-z]+|\\.)\"\n",
    ?assertMatch({ok, <<"(\\d+|[a-z]+|\\.)">>, _Env}, pyrlang:run_string(Source)),
    ?assertEqual({ok, <<2, 1>>}, pyrlang:eval_expr("b'\\x02\\x01'")),
    ?assertEqual({ok, <<"x\ny\tz">>}, pyrlang:eval_expr("'x\\ny\\tz'")),
    ?assertEqual({ok, <<"\\w">>}, pyrlang:eval_expr("'\\w'")),
    ?assertEqual(
        {ok, <<"^[ \\t\\f]*(?:[#\\r\\n]|$)">>}, pyrlang:eval_expr("br'^[ \\t\\f]*(?:[#\\r\\n]|$)'")
    ),
    ?assertEqual({ok, <<"x\\ny">>}, pyrlang:eval_expr("RB'x\\ny'")),
    ?assertEqual({ok, <<"(?s:name)\\Z">>}, pyrlang:eval_expr("fr'(?s:{\"name\"})\\Z'")),
    ?assertEqual({ok, <<"\\\\">>}, pyrlang:eval_expr("r'\\\\'")),
    ?assertEqual({ok, <<"a\\'b">>}, pyrlang:eval_expr("r'a\\'b'")).

multiline_triple_quoted_string_literal_test() ->
    pyrlang_heap:init(),
    Source =
        "text = r\"\"\"a # keep\n"
        "(b)\n"
        "\"\"\"\n"
        "text.startswith('a #') + (text.find('(b)') > 0)\n",
    ?assertMatch({ok, 2, _Env}, pyrlang:run_string(Source)).

multiline_triple_quoted_call_argument_is_not_docstring_test() ->
    pyrlang_heap:init(),
    Source =
        "def size(pattern, flag):\n"
        "    return len(pattern) + flag\n"
        "value = size(\n"
        "    r\"\"\"\n"
        "        # keep this comment text\n"
        "        ([a-z]+)\n"
        "    \"\"\",\n"
        "    3,\n"
        ")\n"
        "(value > 20)\n",
    ?assertMatch({ok, true, _Env}, pyrlang:run_string(Source)).

backslash_continued_triple_quoted_assignment_test() ->
    pyrlang_heap:init(),
    Source =
        "text = \\\n"
        "    \"\"\"alpha\n"
        "    pass\n"
        "    \"\"\"\n"
        "text.find('pass') > 0\n",
    ?assertMatch({ok, true, _Env}, pyrlang:run_string(Source)).

triple_quote_text_inside_string_does_not_join_lines_test() ->
    pyrlang_heap:init(),
    Source =
        "_MULTI_QUOTES = ('\"\"\"', \"'''\")\n"
        "value = len(_MULTI_QUOTES)\n"
        "value\n",
    ?assertMatch({ok, 2, _Env}, pyrlang:run_string(Source)).

docstring_only_class_and_raw_function_docstring_parse_test() ->
    pyrlang_heap:init(),
    Source =
        "class Choice:\n"
        "    \"\"\"Represent multiple possibilities.\"\"\"\n"
        "def normalize(pattern):\n"
        "    r\"\"\"\n"
        "    Normalize a regular expression.\n"
        "    \"\"\"\n"
        "    return pattern\n"
        "normalize('ok')\n",
    ?assertMatch({ok, <<"ok">>, _Env}, pyrlang:run_string(Source)).

metaclass_keyword_and_type_constructor_test() ->
    pyrlang_heap:init(),
    Source =
        "def Meta(name, bases, attrs):\n"
        "    cls = type(name, bases, attrs)\n"
        "    cls.marked = 'yes'\n"
        "    return cls\n"
        "class Model(metaclass=Meta):\n"
        "    field = 41\n"
        "Model.field + len(Model.marked)\n",
    ?assertMatch({ok, 44, _Env}, pyrlang:run_string(Source)).

metaclass_init_runs_for_created_classes_test() ->
    pyrlang_heap:init(),
    Source =
        "class Meta(type):\n"
        "    def __init__(cls, name, bases, namespace):\n"
        "        cls.ready = 41\n"
        "class Model(metaclass=Meta):\n"
        "    pass\n"
        "Model.ready + isinstance(Model, Meta)\n",
    ?assertMatch({ok, 42, _Env}, pyrlang:run_string(Source)).

metaclass_instance_and_subclass_checks_are_honored_test() ->
    pyrlang_heap:init(),
    Source =
        "class Meta(type):\n"
        "    def __instancecheck__(cls, obj):\n"
        "        return obj == 42\n"
        "    def __subclasscheck__(cls, sub):\n"
        "        return sub.__name__ == 'Accepted'\n"
        "class Marker(metaclass=Meta):\n"
        "    pass\n"
        "class Accepted:\n"
        "    pass\n"
        "isinstance(42, Marker) + issubclass(Accepted, Marker)\n",
    ?assertMatch({ok, 2, _Env}, pyrlang:run_string(Source)).

metaclass_zero_arg_super_uses_metaclass_mro_test() ->
    pyrlang_heap:init(),
    Source =
        "class BaseMeta(type):\n"
        "    def __init__(cls, name, bases, namespace):\n"
        "        cls.base_ready = 40\n"
        "class Meta(BaseMeta):\n"
        "    def __init__(cls, *args, **kwargs):\n"
        "        super().__init__(*args, **kwargs)\n"
        "        cls.ready = 2\n"
        "class Model(metaclass=Meta):\n"
        "    pass\n"
        "Model.base_ready + Model.ready\n",
    ?assertMatch({ok, 42, _Env}, pyrlang:run_string(Source)).

metaclass_type_check_super_methods_use_default_type_hooks_test() ->
    pyrlang_heap:init(),
    Source =
        "class Meta(type):\n"
        "    def __instancecheck__(cls, obj):\n"
        "        return super().__instancecheck__(obj)\n"
        "    def __subclasscheck__(cls, sub):\n"
        "        return super().__subclasscheck__(sub)\n"
        "class Base(metaclass=Meta):\n"
        "    pass\n"
        "class Child(Base):\n"
        "    pass\n"
        "class Other:\n"
        "    pass\n"
        "Base.__instancecheck__(Child()) + Base.__subclasscheck__(Child) + (not Base.__instancecheck__(Other())) + (not Base.__subclasscheck__(Other))\n",
    ?assertMatch({ok, 4, _Env}, pyrlang:run_string(Source)).

metaclass_receives_only_explicit_bases_test() ->
    pyrlang_heap:init(),
    Source =
        "def Meta(name, bases, attrs):\n"
        "    attrs['base_count'] = len(bases)\n"
        "    return type(name, bases, attrs)\n"
        "class Model(metaclass=Meta):\n"
        "    pass\n"
        "Model.base_count\n",
    ?assertMatch({ok, 0, _Env}, pyrlang:run_string(Source)).

type_constructor_empty_bases_still_inherits_object_test() ->
    pyrlang_heap:init(),
    Source =
        "Model = type('Model', (), {})\n"
        "issubclass(Model, object)\n",
    ?assertMatch({ok, true, _Env}, pyrlang:run_string(Source)).

type_constructor_passes_keywords_to_inherited_metaclass_test() ->
    pyrlang_heap:init(),
    Source =
        "class Meta(type):\n"
        "    def __new__(metacls, name, bases, attrs, *, flag=None, **kwds):\n"
        "        attrs['flag'] = flag\n"
        "        return super().__new__(metacls, name, bases, attrs, **kwds)\n"
        "class Base(metaclass=Meta):\n"
        "    pass\n"
        "Child = type('Child', (Base,), {}, flag=41)\n"
        "Child.flag + len(Child.__bases__)\n",
    ?assertMatch({ok, 42, _Env}, pyrlang:run_string(Source)).

class_header_keywords_are_passed_to_metaclass_test() ->
    pyrlang_heap:init(),
    Source =
        "class Meta(type):\n"
        "    def __new__(metacls, name, bases, attrs, *, flag=None, **kwds):\n"
        "        attrs['flag'] = flag\n"
        "        return super().__new__(metacls, name, bases, attrs, **kwds)\n"
        "class Base(metaclass=Meta):\n"
        "    pass\n"
        "class Child(Base, flag=42):\n"
        "    pass\n"
        "Child.flag\n",
    ?assertMatch({ok, 42, _Env}, pyrlang:run_string(Source)).

class_header_non_metaclass_keywords_are_accepted_test() ->
    pyrlang_heap:init(),
    Source =
        "STRICT = 'strict'\n"
        "class Flag(boundary=STRICT):\n"
        "    value = 42\n"
        "Flag.value\n",
    ?assertMatch({ok, 42, _Env}, pyrlang:run_string(Source)).

metaclass_methods_bind_to_class_objects_test() ->
    pyrlang_heap:init(),
    Source =
        "class Meta(type):\n"
        "    def register(cls, subclass):\n"
        "        cls.seen = subclass\n"
        "        return subclass\n"
        "class Base(metaclass=Meta):\n"
        "    pass\n"
        "class Child:\n"
        "    pass\n"
        "(Base.register(Child) is Child) + (Base.seen is Child)\n",
    ?assertMatch({ok, 2, _Env}, pyrlang:run_string(Source)).

class_method_defaults_can_reference_prior_class_attrs_test() ->
    pyrlang_heap:init(),
    Source =
        "class Box:\n"
        "    marker = object()\n"
        "    def get(self, default=marker):\n"
        "        return default\n"
        "Box().get() is Box.marker\n",
    ?assertMatch({ok, true, _Env}, pyrlang:run_string(Source)).

classmethod_body_can_reference_own_class_name_test() ->
    pyrlang_heap:init(),
    Source =
        "class Box:\n"
        "    value = 41\n"
        "    @classmethod\n"
        "    def get(cls):\n"
        "        return Box.value\n"
        "Box.get() + 1\n",
    ?assertMatch({ok, 42, _Env}, pyrlang:run_string(Source)).

inherited_metaclass_is_used_for_subclasses_test() ->
    pyrlang_heap:init(),
    Source =
        "class Meta(type):\n"
        "    def __new__(metacls, name, bases, attrs):\n"
        "        attrs['created_by'] = name\n"
        "        return super().__new__(metacls, name, bases, attrs)\n"
        "class Base(metaclass=Meta):\n"
        "    base = 'base'\n"
        "class Child(Base):\n"
        "    child = 'child'\n"
        "Base.created_by + ':' + Child.created_by + ':' + Child.base + ':' + Child.child\n",
    ?assertMatch({ok, <<"Base:Child:base:child">>, _Env}, pyrlang:run_string(Source)).

builtin_list_can_be_used_as_base_class_test() ->
    pyrlang_heap:init(),
    Source =
        "class Choice(list):\n"
        "    pass\n"
        "items = Choice((1, 2))\n"
        "len(items) + len(list((3, 4)))\n",
    ?assertMatch({ok, 4, _Env}, pyrlang:run_string(Source)).

list_subclass_instances_keep_attributes_and_list_methods_test() ->
    pyrlang_heap:init(),
    Source =
        "class NodeList(list):\n"
        "    contains_nontext = False\n"
        "    def mark(self):\n"
        "        self.contains_nontext = True\n"
        "nodes = NodeList()\n"
        "nodes.append(1)\n"
        "before = nodes.contains_nontext\n"
        "nodes.mark()\n"
        "len(nodes) + before + nodes.contains_nontext + isinstance(nodes, NodeList) + isinstance(nodes, list)\n",
    ?assertMatch({ok, 4, _Env}, pyrlang:run_string(Source)).

list_subclass_init_accepts_keywords_ignored_by_list_new_test() ->
    pyrlang_heap:init(),
    Source =
        "class ErrorList(list):\n"
        "    def __init__(self, initlist=None, renderer=None):\n"
        "        super().__init__(initlist or [])\n"
        "        self.renderer = renderer\n"
        "errors = ErrorList(renderer='html')\n"
        "len(errors) + (errors.renderer == 'html')\n",
    ?assertMatch({ok, 1, _Env}, pyrlang:run_string(Source)).

list_subclass_new_accepts_extra_init_arguments_test() ->
    pyrlang_heap:init(),
    Source =
        "class ResultList(list):\n"
        "    def __init__(self, form, items):\n"
        "        self.form = form\n"
        "        self.items = items\n"
        "rows = ResultList('form', [1, 2])\n"
        "len(rows) + (rows.form == 'form') + (rows.items[1] == 2)\n",
    ?assertMatch({ok, 2, _Env}, pyrlang:run_string(Source)).

dict_subclass_instances_keep_attributes_and_dict_init_test() ->
    pyrlang_heap:init(),
    Source =
        "class ContextDict(dict):\n"
        "    def __init__(self, context, *args, **kwargs):\n"
        "        super().__init__(*args, **kwargs)\n"
        "        context.append(self)\n"
        "        self.context = context\n"
        "    def __enter__(self):\n"
        "        return self\n"
        "    def __exit__(self, *args, **kwargs):\n"
        "        pass\n"
        "context = []\n"
        "with ContextDict(context, {'True': True}, x=2) as data:\n"
        "    total = data['True'] + data['x']\n"
        "total + len(context) + (data.context is context) + isinstance(data, dict)\n",
    ?assertMatch({ok, 6, _Env}, pyrlang:run_string(Source)).

builtin_str_new_allocates_subclass_instances_test() ->
    pyrlang_heap:init(),
    Source =
        "class Label(str):\n"
        "    pass\n"
        "item = str.__new__(Label, 'ready')\n"
        "item.state = 'set'\n"
        "str(item) + ':' + item.state + ':' + str(isinstance(item, Label))\n",
    ?assertMatch({ok, <<"ready:set:True">>, _Env}, pyrlang:run_string(Source)).

str_subclass_uses_inherited_python_new_test() ->
    pyrlang_heap:init(),
    Source =
        "class Token(str):\n"
        "    def __new__(cls, value, token_type):\n"
        "        self = super().__new__(cls, value)\n"
        "        self.token_type = token_type\n"
        "        return self\n"
        "class Child(Token):\n"
        "    pass\n"
        "item = Child('.', 'dot')\n"
        "parts = Child('a,b', 'csv').split(',')\n"
        "str(item) + ':' + item.token_type + ':' + str(isinstance(item, Child)) + ':' + parts[1] + ':' + item[0] + ':' + str(len(item))\n",
    ?assertMatch({ok, <<".:dot:True:b:.:1">>, _Env}, pyrlang:run_string(Source)).

str_preserves_string_subclass_returned_from_dunder_str_test() ->
    pyrlang_heap:init(),
    Source =
        "class Safe(str):\n"
        "    def __str__(self):\n"
        "        return self\n"
        "    def __html__(self):\n"
        "        return self\n"
        "class Widget:\n"
        "    def __str__(self):\n"
        "        return Safe('<input>')\n"
        "value = str(Widget())\n"
        "isinstance(value, Safe) and (value.__html__() is value)\n",
    ?assertMatch({ok, true, _Env}, pyrlang:run_string(Source)).

int_mixin_enum_members_use_int_new_test() ->
    pyrlang_heap:init(),
    Source =
        "import enum\n"
        "class Code(enum.IntEnum):\n"
        "    OK = 200\n"
        "class Flags(enum.IntFlag):\n"
        "    READ = 1\n"
        "    WRITE = 2\n"
        "    BOTH = READ | WRITE\n"
        "int(Code.OK) + Flags.BOTH.value + isinstance(Code.OK, int)\n",
    ?assertMatch({ok, 204, _Env}, pyrlang:run_string(Source)).

plain_enum_members_use_object_new_test() ->
    pyrlang_heap:init(),
    Source =
        "import enum\n"
        "class State(enum.Enum):\n"
        "    READY = enum.auto()\n"
        "    DONE = enum.auto()\n"
        "State.READY.value + State.DONE.value\n",
    ?assertMatch({ok, 3, _Env}, pyrlang:run_string(Source)).

function_objects_are_descriptors_test() ->
    pyrlang_heap:init(),
    Source =
        "def get_value(self):\n"
        "    return self.value\n"
        "class Box:\n"
        "    value = 41\n"
        "bound = get_value.__get__(Box(), Box)\n"
        "hasattr(get_value, '__get__') + bound()\n",
    ?assertMatch({ok, 42, _Env}, pyrlang:run_string(Source)).

simple_enum_decorator_keeps_methods_out_of_members_test() ->
    pyrlang_heap:init(),
    Source =
        "from enum import IntEnum, auto, _simple_enum\n"
        "@_simple_enum(IntEnum)\n"
        "class Precedence:\n"
        "    START = auto()\n"
        "    END = auto()\n"
        "    def next(self):\n"
        "        try:\n"
        "            return self.__class__(self + 1)\n"
        "        except ValueError:\n"
        "            return self\n"
        "Precedence.START.next().value + ('next' in Precedence.__members__)\n",
    ?assertMatch({ok, 2, _Env}, pyrlang:run_string(Source)).
