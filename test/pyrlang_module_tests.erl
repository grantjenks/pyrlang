-module(pyrlang_module_tests).

-include_lib("eunit/include/eunit.hrl").

import_module_and_call_function_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir(),
    ok = file:make_dir(Dir),
    ok = file:write_file(filename:join(Dir, "mathy.pyr"), <<"value = 41\ndef inc(x):\n    return x + 1\n">>),
    ok = pyrlang:set_path([Dir | pyrlang_module:path()]),
    ?assertMatch({ok, 42, _Env}, pyrlang:run_string("import mathy\nmathy.inc(mathy.value)\n")),
    cleanup_dir(Dir).

import_py_source_module_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir(),
    ok = file:make_dir(Dir),
    ok = file:write_file(filename:join(Dir, "mathy.py"), <<"value = 41\ndef inc(x):\n    return x + 1\n">>),
    ok = pyrlang:set_path([Dir | pyrlang_module:path()]),
    ?assertMatch({ok, 42, _Env}, pyrlang:run_string("import mathy\nmathy.inc(mathy.value)\n")),
    cleanup_dir(Dir).

builtins_import_uses_pyrlang_runtime_module_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir(),
    ok = file:make_dir(Dir),
    ShadowDir = filename:join(Dir, "builtins"),
    ok = file:make_dir(ShadowDir),
    ok = file:write_file(filename:join(ShadowDir, "__init__.py"), <<"raise ImportError('shadowed')\n">>),
    ok = pyrlang:set_path([Dir]),
    ?assertMatch({ok, 5, _Env}, pyrlang:run_string("import builtins\nbuiltins.len([1, 2, 3]) + builtins.int('2')\n")),
    cleanup_dir(ShadowDir),
    file:del_dir(Dir).

from_import_alias_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir(),
    ok = file:make_dir(Dir),
    ok = file:write_file(filename:join(Dir, "settings.pyr"), <<"answer = 42\n">>),
    ok = pyrlang:set_path([Dir]),
    ?assertMatch({ok, 42, _Env}, pyrlang:run_string("from settings import answer as value\nvalue\n")),
    cleanup_dir(Dir).

importlib_util_find_spec_finds_package_submodules_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir(),
    ok = file:make_dir(Dir),
    PackageDir = filename:join(Dir, "pkg"),
    ok = file:make_dir(PackageDir),
    ok = file:write_file(filename:join(PackageDir, "__init__.py"), <<>>),
    ok = file:write_file(filename:join(PackageDir, "apps.py"), <<"value = 42\n">>),
    ok = pyrlang:set_path([Dir | pyrlang_module:path()]),
    Source =
        "from importlib.util import find_spec\n"
        "import pkg\n"
        "spec = find_spec('pkg.apps', pkg.__path__)\n"
        "(spec is not None) + (spec.name == 'pkg.apps') + spec.origin.endswith('apps.py')\n",
    ?assertMatch({ok, 3, _Env}, pyrlang:run_string(Source)),
    cleanup_dir(PackageDir),
    file:del_dir(Dir).

from_import_parenthesized_names_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir(),
    ok = file:make_dir(Dir),
    ok = file:write_file(filename:join(Dir, "settings.py"), <<"answer = 40\nextra = 2\n">>),
    ok = pyrlang:set_path([Dir]),
    Source =
        "from settings import (\n"
        "    answer,\n"
        "    extra as renamed,\n"
        ")\n"
        "answer + renamed\n",
    ?assertMatch({ok, 42, _Env}, pyrlang:run_string(Source)),
    cleanup_dir(Dir).

from_import_relative_module_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir(),
    ok = file:make_dir(Dir),
    PackageDir = filename:join(Dir, "pkg"),
    ok = file:make_dir(PackageDir),
    ok = file:write_file(filename:join(PackageDir, "__init__.py"), <<
        "from .config import value\n"
        "from . import registry\n"
        "answer = value + registry.extra\n"
    >>),
    ok = file:write_file(filename:join(PackageDir, "config.py"), <<"value = 40\n">>),
    ok = file:write_file(filename:join(PackageDir, "registry.py"), <<"extra = 2\n">>),
    ok = pyrlang:set_path([Dir]),
    ?assertMatch({ok, 42, _Env}, pyrlang:run_string("import pkg\npkg.answer\n")),
    cleanup_dir(PackageDir),
    file:del_dir(Dir).

package_loading_preserves_attached_child_modules_between_imports_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir(),
    ok = file:make_dir(Dir),
    PackageDir = filename:join(Dir, "pkg"),
    ok = file:make_dir(PackageDir),
    ok = file:write_file(filename:join(PackageDir, "__init__.py"), <<
        "from pkg import child\n"
        "from pkg import other\n"
        "answer = child.value + other.value\n"
    >>),
    ok = file:write_file(filename:join(PackageDir, "child.py"), <<"value = 40\n">>),
    ok = file:write_file(filename:join(PackageDir, "other.py"), <<"value = 2\n">>),
    ok = pyrlang:set_path([Dir]),
    Source =
        "import pkg\n"
        "pkg.answer + hasattr(pkg, 'child') + hasattr(pkg, 'other')\n",
    ?assertMatch({ok, 44, _Env}, pyrlang:run_string(Source)),
    cleanup_dir(PackageDir),
    file:del_dir(Dir).

package_init_and_dotted_import_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir(),
    ok = file:make_dir(Dir),
    PackageDir = filename:join(Dir, "pkg"),
    ok = file:make_dir(PackageDir),
    ok = file:write_file(filename:join(PackageDir, "__init__.pyr"), <<"name = 'pkg'\n">>),
    ok = file:write_file(filename:join(PackageDir, "mod.pyr"), <<"value = 7\n">>),
    ok = pyrlang:set_path([Dir]),
    ?assertMatch({ok, 10, _Env}, pyrlang:run_string("import pkg.mod\npkg.mod.value + len(pkg.name)\n")),
    cleanup_dir(PackageDir),
    file:del_dir(Dir).

py_package_init_and_dotted_import_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir(),
    ok = file:make_dir(Dir),
    PackageDir = filename:join(Dir, "pkg"),
    ok = file:make_dir(PackageDir),
    ok = file:write_file(filename:join(PackageDir, "__init__.py"), <<"name = 'pkg'\n">>),
    ok = file:write_file(filename:join(PackageDir, "mod.py"), <<"value = 7\n">>),
    ok = pyrlang:set_path([Dir]),
    ?assertMatch({ok, 10, _Env}, pyrlang:run_string("import pkg.mod\npkg.mod.value + len(pkg.name)\n")),
    cleanup_dir(PackageDir),
    file:del_dir(Dir).

package_path_is_list_like_for_stdlib_discovery_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir(),
    ok = file:make_dir(Dir),
    PackageDir = filename:join(Dir, "pkg"),
    ok = file:make_dir(PackageDir),
    ok = file:write_file(filename:join(PackageDir, "__init__.py"), <<"">>),
    ok = pyrlang:set_path([Dir]),
    Source =
        "import pkg\n"
        "len(pkg.__path__) + pkg.__path__[0].endswith('/pkg')\n",
    ?assertMatch({ok, 2, _Env}, pyrlang:run_string(Source)),
    cleanup_dir(PackageDir),
    file:del_dir(Dir).

direct_child_import_loads_parent_package_first_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir(),
    ok = file:make_dir(Dir),
    PackageDir = filename:join(Dir, "pkg"),
    ok = file:make_dir(PackageDir),
    ok = file:write_file(filename:join(PackageDir, "__init__.py"), <<"ready = 40\n">>),
    ok = file:write_file(filename:join(PackageDir, "child.py"), <<"from . import ready\nvalue = ready + 2\n">>),
    ok = pyrlang:set_path([Dir]),
    ?assertMatch({ok, 42, _Env}, pyrlang:run_string("import pkg.child\npkg.child.value\n")),
    cleanup_dir(PackageDir),
    file:del_dir(Dir).

relative_star_import_uses_all_and_binds_child_module_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir(),
    ok = file:make_dir(Dir),
    PackageDir = filename:join(Dir, "pkg"),
    ok = file:make_dir(PackageDir),
    ok = file:write_file(filename:join(PackageDir, "__init__.py"), <<
        "from .child import *\n"
        "answer = value + (child.__all__[0] == 'value') + ('hidden' in globals())\n"
    >>),
    ok = file:write_file(filename:join(PackageDir, "child.py"), <<"__all__ = ('value',)\nvalue = 41\nhidden = 99\n">>),
    ok = pyrlang:set_path([Dir]),
    ?assertMatch({ok, 42, _Env}, pyrlang:run_string("import pkg\npkg.answer\n")),
    cleanup_dir(PackageDir),
    file:del_dir(Dir).

package_in_earlier_path_entry_wins_over_later_module_file_test() ->
    pyrlang_heap:init(),
    FirstDir = temp_dir(),
    SecondDir = temp_dir(),
    ok = file:make_dir(FirstDir),
    ok = file:make_dir(SecondDir),
    PackageDir = filename:join(FirstDir, "pkg"),
    ok = file:make_dir(PackageDir),
    ok = file:write_file(filename:join(PackageDir, "__init__.py"), <<"value = 'package'\n">>),
    ok = file:write_file(filename:join(SecondDir, "pkg.py"), <<"value = 'module'\n">>),
    ok = pyrlang:set_path([FirstDir, SecondDir]),
    ?assertMatch({ok, <<"package">>, _Env}, pyrlang:run_string("import pkg\npkg.value\n")),
    cleanup_dir(PackageDir),
    file:del_dir(FirstDir),
    file:delete(filename:join(SecondDir, "pkg.py")),
    file:del_dir(SecondDir).

from_package_import_loads_child_module_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir(),
    ok = file:make_dir(Dir),
    PackageDir = filename:join(Dir, "pkg"),
    ok = file:make_dir(PackageDir),
    ok = file:write_file(filename:join(PackageDir, "__init__.py"), <<"">>),
    ok = file:write_file(filename:join(PackageDir, "tool.py"), <<"value = 42\n">>),
    ok = pyrlang:set_path([Dir]),
    ?assertMatch({ok, 42, _Env}, pyrlang:run_string("from pkg import tool\ntool.value\n")),
    cleanup_dir(PackageDir),
    file:del_dir(Dir).

child_module_attaches_to_parent_package_while_parent_is_loading_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir(),
    ok = file:make_dir(Dir),
    PackageDir = filename:join(Dir, "pkg"),
    ok = file:make_dir(PackageDir),
    ok = file:write_file(filename:join(PackageDir, "__init__.py"), <<"from pkg import child\nvalue = child.value\n">>),
    ok = file:write_file(filename:join(PackageDir, "child.py"), <<"value = 42\n">>),
    ok = pyrlang:set_path([Dir]),
    ?assertMatch({ok, 42, _Env}, pyrlang:run_string("import pkg\npkg.child.value\n")),
    cleanup_dir(PackageDir),
    file:del_dir(Dir).

child_module_sees_parent_names_bound_before_reentrant_import_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir(),
    ok = file:make_dir(Dir),
    PackageDir = filename:join(Dir, "pkg"),
    ok = file:make_dir(PackageDir),
    ok = file:write_file(filename:join(PackageDir, "__init__.py"), <<
        "from .messages import Error\n",
        "import pkg.child\n"
    >>),
    ok = file:write_file(filename:join(PackageDir, "messages.py"), <<"class Error:\n    pass\n">>),
    ok = file:write_file(filename:join(PackageDir, "child.py"), <<"from . import Error\nvalue = Error\n">>),
    ok = pyrlang:set_path([Dir]),
    ?assertMatch({ok, true, _Env}, pyrlang:run_string("import pkg\npkg.child.value is pkg.Error\n")),
    cleanup_dir(PackageDir),
    file:del_dir(Dir).

dynamic_imports_use_actor_local_module_loader_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir(),
    ok = file:make_dir(Dir),
    ok = file:write_file(filename:join(Dir, "dyn.pyr"), <<"value = 10\n">>),
    PackageDir = filename:join(Dir, "pkg"),
    ok = file:make_dir(PackageDir),
    ok = file:write_file(filename:join(PackageDir, "__init__.pyr"), <<"">>),
    ok = file:write_file(filename:join(PackageDir, "mod.pyr"), <<"value = 20\n">>),
    ok = pyrlang:set_path([Dir]),
    Source =
        "import importlib\n"
        "from importlib import reload\n"
        "absolute = importlib.import_module('dyn')\n"
        "relative = importlib.import_module('.mod', 'pkg')\n"
        "builtin = __import__('dyn')\n"
        "builtin_kw = __import__('pkg.mod', fromlist=['value'], level=0)\n"
        "absolute.value + relative.value + builtin.value + builtin_kw.value + (reload(importlib) is importlib)\n",
    ?assertMatch({ok, 61, _Env}, pyrlang:run_string(Source)),
    _ = file:delete(filename:join(Dir, "dyn.pyr")),
    cleanup_dir(PackageDir),
    file:del_dir(Dir).

builtin_sys_metadata_supports_python_version_guards_test() ->
    pyrlang_heap:init(),
    Source =
        "import sys\n"
        "current = 'yes' if sys.version_info >= (3, 13) else 'no'\n"
        "future = 'yes' if sys.version_info >= (3, 14) else 'no'\n"
        "frame = sys._getframe(1)\n"
        "sys.modules['collections.abc'] = 'abc'\n"
        "before = sys.getrecursionlimit()\n"
        "sys.setrecursionlimit(1500)\n"
        "try:\n"
        "    sys.exit(7)\n"
        "except SystemExit as exc:\n"
        "    exited = exc.args[0]\n"
        "sys.implementation.name + ':' + current + ':' + future + ':' + sys.base_prefix + ':' + frame.f_globals.get('__name__') + ':' + sys._getframemodulename(1) + ':' + sys.modules['collections.abc'] + ':' + sys.byteorder + ':' + sys.platform + ':' + str(sys.maxsize > 0) + ':' + str(sys.float_info.max_10_exp) + ':' + sys.intern('name') + ':' + str(before) + ':' + str(sys.getrecursionlimit()) + ':' + sys.stderr.name + ':' + str(sys.stderr.write('')) + ':' + str(sys.stderr.isatty()) + ':' + sys.platlibdir + ':' + sys.abiflags + ':' + str(sys._framework) + ':' + sys._base_executable + ':' + sys.getfilesystemencoding() + ':' + sys.getfilesystemencodeerrors() + ':' + str(len(sys.path) > 0) + ':' + str(len(sys.meta_path)) + ':' + str(len(sys.path_hooks)) + ':' + str(len(sys.path_importer_cache)) + ':' + str(exited)\n",
    ?assertMatch({ok, <<"pyrlang:yes:no:/usr/local:__main__:__main__:abc:little:darwin:True:308:name:1000:1500:stderr:0:False:lib::False:pyrlang:utf-8:surrogateescape:True:0:0:0:7">>, _Env}, pyrlang:run_string(Source)).

sys_modules_tracks_modules_while_they_are_loading_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir(),
    ok = file:make_dir(Dir),
    ok = file:write_file(filename:join(Dir, "selfmod.py"), <<"import sys\nseen = sys.modules[__name__] is sys.modules['selfmod']\n">>),
    ok = pyrlang:set_path([Dir]),
    Source =
        "import selfmod\n"
        "selfmod.seen\n",
    ?assertMatch({ok, true, _Env}, pyrlang:run_string(Source)),
    _ = file:delete(filename:join(Dir, "selfmod.py")),
    file:del_dir(Dir).

builtin_pkgutil_iter_modules_scans_py_modules_and_packages_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir(),
    ok = file:make_dir(Dir),
    PackageDir = filename:join(Dir, "pkg"),
    ok = file:make_dir(PackageDir),
    ok = file:write_file(filename:join(PackageDir, "__init__.py"), <<"">>),
    ok = file:write_file(filename:join(PackageDir, "inner.py"), <<"">>),
    ok = file:write_file(filename:join(Dir, "tool.py"), <<"">>),
    ok = file:write_file(filename:join(Dir, "_private.py"), <<"">>),
    Source = lists:flatten(io_lib:format(
        "import pkgutil\n"
        "items = list(pkgutil.iter_modules(['~s']))\n"
        "walk = list(pkgutil.walk_packages(['~s']))\n"
        "names = [name for _, name, is_pkg in items if not name.startswith('_')]\n"
        "walk_names = [name for _, name, is_pkg in walk if not name.startswith('_')]\n"
        "len(names) + ('tool' in names) + ('pkg' in names) + ('pkg.inner' in walk_names)\n",
        [Dir, Dir]
    )),
    ?assertMatch({ok, 5, _Env}, pyrlang:run_string(Source)),
    ok = file:delete(filename:join(PackageDir, "inner.py")),
    cleanup_dir(PackageDir),
    cleanup_dir(Dir).

builtin_pkgutil_iter_modules_scans_none_path_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir(),
    ok = file:make_dir(Dir),
    ok = file:write_file(filename:join(Dir, "available.py"), <<"">>),
    ok = pyrlang:set_path([Dir]),
    Source =
        "import pkgutil\n"
        "names = [name for _, name, is_pkg in pkgutil.iter_modules(None)]\n"
        "'available' in names\n",
    ?assertMatch({ok, true, _Env}, pyrlang:run_string(Source)),
    cleanup_dir(Dir).

builtin_subprocess_run_returns_completed_process_test() ->
    pyrlang_heap:init(),
    Source =
        "import subprocess\n"
        "result = subprocess.run('printf pyrlang', shell=True, capture_output=True, text=True)\n"
        "result.stdout + ':' + str(result.returncode)\n",
    ?assertMatch({ok, <<"pyrlang:0">>, _Env}, pyrlang:run_string(Source)).

builtin_copy_module_uses_python_copy_hooks_test() ->
    pyrlang_heap:init(),
    Source =
        "import copy\n"
        "class Box:\n"
        "    def __init__(self, value):\n"
        "        self.value = value\n"
        "    def __copy__(self):\n"
        "        return Box(self.value + 1)\n"
        "    def __deepcopy__(self, memo):\n"
        "        memo['seen'] = self.value\n"
        "        return Box(self.value + 2)\n"
        "box = Box(3)\n"
        "memo = {}\n"
        "left = copy.copy(box)\n"
        "right = copy.deepcopy(box, memo)\n"
        "items = [1]\n"
        "items_copy = copy.copy(items)\n"
        "items_copy.append(2)\n"
        "left.value + right.value + memo['seen'] + len(items) + len(items_copy)\n",
    ?assertMatch({ok, 15, _Env}, pyrlang:run_string(Source)).

builtin_itertools_operator_and_runtime_helpers_test() ->
    pyrlang_heap:init(),
    Source =
        "import itertools\n"
        "import operator\n"
        "from _collections import _tuplegetter, defaultdict, deque\n"
        "class Box:\n"
        "    value = 4\n"
        "    field = _tuplegetter(2, 'doc')\n"
        "    def __getitem__(self, index):\n"
        "        return index + 10\n"
        "    def bump(self, amount):\n"
        "        return self.value + amount\n"
        "class UsesCounter:\n"
        "    _counter = itertools.count().__next__\n"
        "    def next(self):\n"
        "        return self._counter()\n"
        "box = Box()\n"
        "uses_counter = UsesCounter()\n"
        "values = list(itertools.chain([1, 2], (3,)))\n"
        "more = list(itertools.chain.from_iterable([[4], [5]]))\n"
        "cut = list(itertools.islice([9, 8, 7, 6, 5], 1, 5, 2))\n"
        "repeated = list(itertools.repeat('x', 3))\n"
        "starred = list(itertools.starmap(operator.add, [(2, 3), (3, 4)]))\n"
        "counter_next = itertools.count(1).__next__\n"
        "counts = defaultdict(list)\n"
        "empty_counts = 1 if counts else 0\n"
        "counts['a'].append(6)\n"
        "nonempty_counts = 1 if counts else 0\n"
        "queue = deque([7, 8])\n"
        "get_value = operator.attrgetter('value')\n"
        "pick = operator.itemgetter(1)\n"
        "bump = operator.methodcaller('bump', 3)\n"
        "sentinel = object()\n"
        "operator.add(get_value(box), pick(values)) + len(more) + cut[0] + cut[1] + len(repeated) + starred[0] + starred[1] + counter_next() + counter_next() + uses_counter.next() + uses_counter.next() + counts['a'][0] + queue[1] + (hash(sentinel) == hash(sentinel)) + len(dir(box)) + box.field + bump(box) + (empty_counts == 0) + (nonempty_counts == 1)\n",
    ?assertMatch({ok, 94, _Env}, pyrlang:run_string(Source)).

operator_itemgetter_reads_tuple_subclass_items_test() ->
    pyrlang_heap:init(),
    Source =
        "from collections import namedtuple\n"
        "from operator import itemgetter\n"
        "Row = namedtuple('Row', 'name kind')\n"
        "row = Row('django_migrations', 'table')\n"
        "pick = itemgetter(0)\n"
        "pick(row) + ':' + row[1] + ':' + row.name\n",
    ?assertMatch({ok, <<"django_migrations:table:django_migrations">>, _Env}, pyrlang:run_string(Source)).

operator_getitem_missing_method_is_catchable_typeerror_test() ->
    pyrlang_heap:init(),
    Source =
        "import operator\n"
        "class Wrapped:\n"
        "    pass\n"
        "class Lazy:\n"
        "    def __init__(self):\n"
        "        self._wrapped = Wrapped()\n"
        "    def __getitem__(self, key):\n"
        "        return operator.getitem(self._wrapped, key)\n"
        "try:\n"
        "    Lazy()['missing']\n"
        "except TypeError:\n"
        "    result = 'type'\n"
        "result\n",
    ?assertMatch({ok, <<"type">>, _Env}, pyrlang:run_string(Source)).

collections_defaultdict_pop_removes_existing_keys_test() ->
    pyrlang_heap:init(),
    Source =
        "from collections import defaultdict\n"
        "items = defaultdict(list)\n"
        "items['a'].append(4)\n"
        "popped = items.pop('a')\n"
        "popped[0] + len(items) + (items.pop('missing', 5) == 5)\n",
    ?assertMatch({ok, 5, _Env}, pyrlang:run_string(Source)).

collections_defaultdict_copy_isolates_store_test() ->
    pyrlang_heap:init(),
    Source =
        "import copy\n"
        "from collections import defaultdict\n"
        "items = defaultdict(dict)\n"
        "items['app']['model'] = 'old'\n"
        "shallow = items.copy()\n"
        "deep = copy.deepcopy(items)\n"
        "items['app']['model'] = 'new'\n"
        "shallow['extra']['model'] = 'extra'\n"
        "deep['app']['model'] + ':' + shallow['app']['model'] + ':' + str('extra' in items)\n",
    ?assertMatch({ok, <<"old:new:False">>, _Env}, pyrlang:run_string(Source)).

collections_counter_most_common_test() ->
    pyrlang_heap:init(),
    Source =
        "from collections import Counter\n"
        "counts = Counter(['a', 'b', 'a'])\n"
        "counts.update(['a'])\n"
        "pairs = counts.most_common()\n"
        "pairs[0][0] + ':' + str(pairs[0][1]) + ':' + str(counts['missing'])\n",
    ?assertMatch({ok, <<"a:3:0">>, _Env}, pyrlang:run_string(Source)).

builtin_erlang_module_exposes_actor_primitives_test() ->
    pyrlang_heap:init(),
    Source =
        "from erlang import self, spawn, send, receive\n"
        "parent = self()\n"
        "def worker():\n"
        "    send(parent, 'hello')\n"
        "pid = spawn(worker)\n"
        "receive()\n",
    ?assertMatch({ok, <<"hello">>, _Env}, pyrlang:run_string(Source)).

builtin_erlang_receive_supports_timeout_and_default_in_source_test() ->
    pyrlang_heap:init(),
    Source =
        "from erlang import receive\n"
        "receive(0, 'empty')\n",
    ?assertMatch({ok, <<"empty">>, _Env}, pyrlang:run_string(Source)).

source_level_selective_receive_preserves_unmatched_messages_test() ->
    pyrlang_heap:init(),
    Source =
        "from erlang import any, self, send, receive, receive_match\n"
        "me = self()\n"
        "send(me, ('skip', 1))\n"
        "send(me, ('want', 2))\n"
        "matched = receive_match(('want', any()), 1000)\n"
        "left = receive(1000)\n"
        "matched[1] + left[1]\n",
    ?assertMatch({ok, 3, _Env}, pyrlang:run_string(Source)).

source_level_selective_receive_exposes_bindings_test() ->
    pyrlang_heap:init(),
    Source =
        "from erlang import self, send, receive_match_bindings, var\n"
        "me = self()\n"
        "send(me, ('data', 42))\n"
        "matched = receive_match_bindings(('data', var('payload')), 1000)\n"
        "message = matched[0]\n"
        "bindings = matched[1]\n"
        "message[1] + bindings['payload']\n",
    ?assertMatch({ok, 84, _Env}, pyrlang:run_string(Source)).

actor_send_copies_user_defined_instances_in_source_test() ->
    pyrlang_heap:init(),
    Source =
        "from erlang import self, spawn, send, receive\n"
        "class Box:\n"
        "    def __init__(self, value):\n"
        "        self.value = value\n"
        "    def get(self):\n"
        "        return self.value\n"
        "parent = self()\n"
        "box = Box(1)\n"
        "def worker():\n"
        "    msg = receive()\n"
        "    msg.value = 2\n"
        "    send(parent, msg.get())\n"
        "pid = spawn(worker)\n"
        "send(pid, box)\n"
        "child_value = receive()\n"
        "child_value + box.get()\n",
    ?assertMatch({ok, 3, _Env}, pyrlang:run_string(Source)).

builtin_erlang_monitor_reports_down_in_source_test() ->
    pyrlang_heap:init(),
    Source =
        "from erlang import atom, monitor, spawn, receive\n"
        "def worker():\n"
        "    return 1\n"
        "pid = spawn(worker)\n"
        "ref = monitor(pid)\n"
        "msg = receive(1000)\n"
        "(msg[0] == atom('DOWN')) + (msg[1] == ref)\n",
    ?assertMatch({ok, 2, _Env}, pyrlang:run_string(Source)).

builtin_erlang_demonitor_flushes_down_in_source_test() ->
    pyrlang_heap:init(),
    Source =
        "from erlang import demonitor, exit, monitor, receive, spawn\n"
        "def worker():\n"
        "    receive()\n"
        "pid = spawn(worker)\n"
        "ref = monitor(pid)\n"
        "demonitor(ref)\n"
        "exit(pid, 'boom')\n"
        "receive(50, 'empty')\n",
    ?assertMatch({ok, <<"empty">>, _Env}, pyrlang:run_string(Source)).

builtin_erlang_link_trap_exit_and_exit_work_in_source_test() ->
    pyrlang_heap:init(),
    Source =
        "from erlang import atom, exit, link, receive, spawn, trap_exit\n"
        "trap_exit(True)\n"
        "def worker():\n"
        "    receive()\n"
        "pid = spawn(worker)\n"
        "link(pid)\n"
        "exit(pid, 'boom')\n"
        "msg = receive(1000)\n"
        "trap_exit(False)\n"
        "(msg[0] == atom('EXIT')) + (msg[1] == pid) + (msg[2] == 'boom')\n",
    ?assertMatch({ok, 3, _Env}, pyrlang:run_string(Source)).

builtin_erlang_spawn_link_is_source_level_linked_spawn_test() ->
    pyrlang_heap:init(),
    Source =
        "from erlang import atom, exit, receive, spawn_link, trap_exit\n"
        "trap_exit(True)\n"
        "def worker():\n"
        "    receive()\n"
        "pid = spawn_link(worker)\n"
        "exit(pid, 'boom')\n"
        "msg = receive(1000)\n"
        "trap_exit(False)\n"
        "(msg[0] == atom('EXIT')) + (msg[1] == pid)\n",
    ?assertMatch({ok, 2, _Env}, pyrlang:run_string(Source)).

builtin_erlang_apply_calls_existing_erlang_functions_explicitly_test() ->
    pyrlang_heap:init(),
    Source =
        "from erlang import apply\n"
        "length = apply('erlang', 'length', [[1, 2, 3]])\n"
        "size = apply('erlang', 'tuple_size', [(1, 2)])\n"
        "length + size\n",
    ?assertMatch({ok, 5, _Env}, pyrlang:run_string(Source)).

builtin_erlang_atom_uses_existing_atoms_test() ->
    pyrlang_heap:init(),
    ?assertMatch({ok, ok, _Env}, pyrlang:run_string("from erlang import atom\natom('ok')\n")).

builtin_erlang_register_and_whereis_do_not_create_atoms_test() ->
    pyrlang_heap:init(),
    Name = pyrlang_registered_actor_test,
    _ = catch erlang:unregister(Name),
    Source =
        "from erlang import self, register, whereis\n"
        "register('pyrlang_registered_actor_test', self())\n"
        "(whereis('pyrlang_registered_actor_test') == self()) + (whereis('pyrlang_missing_actor_name') == None)\n",
    ?assertMatch({ok, 2, _Env}, pyrlang:run_string(Source)),
    _ = catch erlang:unregister(Name),
    ok.

builtin_os_environ_is_actor_local_mapping_test() ->
    pyrlang_heap:init(),
    Source =
        "import os\n"
        "os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'mysite.settings')\n"
        "os.environ['DJANGO_SETTINGS_MODULE']\n",
    ?assertMatch({ok, <<"mysite.settings">>, _Env}, pyrlang:run_string(Source)).

builtin_os_path_uses_beam_file_helpers_test() ->
    pyrlang_heap:init(),
    Source =
        "import os\n"
        "import sysconfig\n"
        "path = os.path.join('/tmp', 'pyrlang-os-path.txt')\n"
        "flags = os.O_RDONLY + os.O_WRONLY + os.O_CREAT\n"
        "from os.path import commonprefix\n"
        "checks = os.path.isabs('/tmp') + (os.path.normpath('/tmp/../tmp') == '/tmp') + (os.path.realpath('x') == os.path.abspath('x')) + (os.path.relpath('/tmp/a/b', '/tmp') == 'a/b') + (os.path.normcase('/TMP') == '/TMP') + os.path.expanduser('~/x').endswith('/x') + (os.pathsep == ':') + bool(sysconfig.get_config_var('TZPATH')) + (os.SEEK_SET + os.SEEK_CUR + os.SEEK_END == 3) + (os.altsep is None) + (os.extsep == '.') + (os.linesep == '\\n') + (os.defpath == '/bin:/usr/bin') + (os.devnull == '/dev/null') + (os.path.split('/tmp/name.txt') == ('/tmp', 'name.txt')) + (os.path.splitext('/tmp/name.txt') == ('/tmp/name', '.txt')) + (commonprefix(['/tmp/a', '/tmp/b']) == '/tmp/')\n"
        "os.path.basename(path) + ':' + os.path.dirname(path).split('/')[-1] + ':' + str(os.path.exists('/tmp') == True) + ':' + str(flags) + ':' + str(checks)\n",
    ?assertMatch({ok, <<"pyrlang-os-path.txt:tmp:True:513:17">>, _Env}, pyrlang:run_string(Source)).

os_stat_result_type_matches_stat_instances_test() ->
    pyrlang_heap:init(),
    Source =
        "import os\n"
        "st = os.stat('/tmp')\n"
        "isinstance(st, os.stat_result) + (hasattr(os.stat_result, 'st_file_attributes') == False) + (st.st_mtime_ns >= 0)\n",
    ?assertMatch({ok, 3, _Env}, pyrlang:run_string(Source)).

os_terminal_size_type_behaves_like_named_tuple_test() ->
    pyrlang_heap:init(),
    Source =
        "import os\n"
        "size = os.terminal_size((100, 40))\n"
        "fallback = os.get_terminal_size()\n"
        "size.columns + size.lines + size[0] + size[1] + tuple(size)[0] + isinstance(size, tuple) + (fallback.columns > 0) + (fallback.lines > 0)\n",
    ?assertMatch({ok, 383, _Env}, pyrlang:run_string(Source)).

os_filesystem_mutation_helpers_use_beam_file_ops_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir(),
    Nested = filename:join([Dir, "a", "b"]),
    Source = iolist_to_binary([
        "import os\n",
        "base = '", Dir, "'\n",
        "nested = '", Nested, "'\n",
        "os.makedirs(nested, exist_ok=True)\n",
        "made = os.path.isdir(nested)\n",
        "os.rmdir(nested)\n",
        "os.rmdir(os.path.dirname(nested))\n",
        "os.rmdir(base)\n",
        "made + (not os.path.exists(base)) + (os.fstat(0).st_size == 0) + os.access('/tmp', os.F_OK | os.W_OK)\n"
    ]),
    ?assertMatch({ok, 4, _Env}, pyrlang:run_string(Source)).

errno_builtin_module_exposes_common_posix_constants_test() ->
    pyrlang_heap:init(),
    Source =
        "import errno\n"
        "errno.EINVAL + errno.EADDRINUSE + (errno.errorcode[errno.ENOENT] == 'ENOENT')\n",
    ?assertMatch({ok, 71, _Env}, pyrlang:run_string(Source)).

builtin_math_module_supports_stdlib_random_imports_test() ->
    pyrlang_heap:init(),
    Source =
        "from math import log, exp, sqrt, hypot, acos, asin, atan, atan2, cos, cosh, sin, tan, tau, floor, isfinite, lgamma, fabs, fmod, degrees, radians, gcd, isqrt, log2, fsum, sumprod\n"
        "import statistics\n"
        "int(log(8, 2) + sqrt(9) + hypot(3, 4) + floor(tau) + isfinite(exp(1)) + fabs(-2) + log2(8) + fmod(7, 4) + gcd(6, 9) + isqrt(9) + fsum([1, 2]) + sumprod([1, 2], [3, 4]))\n",
    ?assertMatch({ok, 46, _Env}, pyrlang:run_string(Source)).

stdlib_random_imports_with_native_entropy_and_helpers_test() ->
    pyrlang_heap:init(),
    erlang:erase(pyrlang_module_path),
    Source =
        "import os\n"
        "import random\n"
        "from itertools import accumulate, tee, zip_longest\n"
        "from bisect import bisect\n"
        "from operator import index\n"
        "values = list(accumulate([1, 2, 3]))\n"
        "left, right = tee([1, 2])\n"
        "zipped = list(zip_longest(left, [3], fillvalue=9))\n"
        "len(os.urandom(4)) + index(True) + values[-1] + bisect(values, 3) + (random.randrange(10) < 10) + len(right) + zipped[1][1]\n",
    ?assertMatch({ok, 25, _Env}, pyrlang:run_string(Source)).

bisect_module_supports_left_and_insort_helpers_test() ->
    pyrlang_heap:init(),
    Source =
        "from bisect import bisect_left, bisect_right, insort, insort_left\n"
        "items = [1, 2, 2, 4]\n"
        "left = bisect_left(items, 2)\n"
        "right = bisect_right(items, 2)\n"
        "insort(items, 3)\n"
        "insort_left(items, 2)\n"
        "left + right + items[2] + items[4]\n",
    ?assertMatch({ok, 9, _Env}, pyrlang:run_string(Source)).

builtin_re_module_provides_basic_matching_test() ->
    pyrlang_heap:init(),
    Source =
        "import re\n"
        "m = re.match('h(.)', 'hi')\n"
        "p = re.compile('i$', re.VERBOSE | re.DOTALL)\n"
        "ws = re.compile(r'\\s*')\n"
        "decoded = re.compile(br'=([a-fA-F0-9]{2})').sub(lambda m: bytes.fromhex(m.group(1).decode()), b'a=20b=3D')\n"
        "parts = re.compile(r'([ ]+)').split('a b c', 1)\n"
        "found = re.compile(r'[a-z]').findall('a1b')\n"
        "module_found = ''.join(re.findall(r'[<>]', '<x>'))\n"
        "module_split = ''.join(re.split(r'\\s+', 'a b'))\n"
        "defaults = ''.join(re.match(r'(a)?(b)', 'b').groups(default='-'))\n"
        "named = re.match(r'(?P<word>a)?b', 'b').groupdict(default='-')['word']\n"
        "m.group(0) + m.group(1) + p.search('hi').group() + ':' + str(m.start()) + str(m.end()) + str(m.span()[1]) + ':' + decoded + ':' + re.sub('i', 'o', 'hii', 1) + ':' + parts[0] + parts[1] + parts[2] + ':' + ''.join(found) + ':' + module_found + ':' + module_split + ':' + defaults + named + ':' + str(ws.match('x  y', 1).end())\n",
    ?assertMatch({ok, <<"hiii:022:a b=:hoi:a b c:ab:<>:ab:-b-:3">>, _Env}, pyrlang:run_string(Source)).

builtin_re_finditer_named_groups_verbose_and_escape_test() ->
    pyrlang_heap:init(),
    Source =
        "import re\n"
        "import copy\n"
        "escaped = re.escape('|')\n"
        "p = re.compile(r'''^ (?P<word> [a-z]+ )''', re.VERBOSE)\n"
        "m = p.search('ab')\n"
        "flagged = re.match(r'(?P<num>\\d+)', '12', re.ASCII)\n"
        "seen = []\n"
        "for item in re.compile(r'(?P<word>[a-z]+)').finditer('ab 12 cd'):\n"
        "    seen.append(item['word'] + str(item.span()[1]))\n"
        "class Box:\n"
        "    pass\n"
        "box = Box()\n"
        "box.pattern = p\n"
        "box_copy = copy.copy(box)\n"
        "nested = copy.deepcopy({'patterns': [p]})\n"
        "multi = flagged.group('num', 0)\n"
        "escaped + ':' + m['word'] + ':' + m.group('word') + ':' + flagged.group('num') + ':' + multi[0] + ':' + multi[1] + ':' + '|'.join(seen) + ':' + str(box_copy.pattern is p) + ':' + str(nested['patterns'][0] is p)\n",
    ?assertMatch({ok, <<"\\|:ab:ab:12:12:12:ab2|cd8:True:True">>, _Env}, pyrlang:run_string(Source)).

gc_builtin_module_exposes_noop_runtime_hooks_test() ->
    pyrlang_heap:init(),
    Source =
        "import gc\n"
        "gc.disable()\n"
        "gc.enable()\n"
        "counts = gc.get_count()\n"
        "str(gc.collect()) + ':' + str(gc.isenabled()) + ':' + str(counts[0] + counts[1] + counts[2])\n",
    ?assertMatch({ok, <<"0:True:0">>, _Env}, pyrlang:run_string(Source)).

builtin_functools_cache_decorators_are_callable_test() ->
    pyrlang_heap:init(),
    Source =
        "import functools\n"
        "@functools.lru_cache\n"
        "def value():\n"
        "    return 7\n"
        "@functools.cache\n"
        "def other():\n"
        "    return 5\n"
        "@functools.lru_cache(typed=True)\n"
        "def keyed():\n"
        "    return 3\n"
        "class Box:\n"
        "    @functools.cached_property\n"
        "    def answer(self):\n"
        "        return 4\n"
        "    @functools.cache\n"
        "    def method(self):\n"
        "        return 5\n"
        "wrapped = functools._lru_cache_wrapper(value, None, False, object)\n"
        "box = Box()\n"
        "value() + other() + keyed() + hasattr(keyed, 'cache_clear') + box.answer + hasattr(functools, '_lru_cache_wrapper') + isinstance(functools._lru_cache_wrapper, type) + wrapped() + box.method() + box.method()\n",
    ?assertMatch({ok, 38, _Env}, pyrlang:run_string(Source)).

functools_reduce_folds_iterables_test() ->
    pyrlang_heap:init(),
    Source =
        "from functools import reduce\n"
        "reduce(lambda a, b: a + b, [1, 2, 3]) + reduce(lambda a, b: a + b, [], 4)\n",
    ?assertMatch({ok, 10, _Env}, pyrlang:run_string(Source)).

functools_singledispatch_registers_explicit_classes_test() ->
    pyrlang_heap:init(),
    Source =
        "from functools import singledispatch\n"
        "@singledispatch\n"
        "def label(value):\n"
        "    return 'object'\n"
        "@label.register(str)\n"
        "def _(value):\n"
        "    return 'str:' + value\n"
        "def integer(value):\n"
        "    return 'int:' + str(value)\n"
        "label.register(int, integer)\n"
        "label('x') + '|' + label(3) + '|' + label([])\n",
    ?assertMatch({ok, <<"str:x|int:3|object">>, _Env}, pyrlang:run_string(Source)).

functools_singledispatch_infers_plain_register_annotations_test() ->
    pyrlang_heap:init(),
    Source =
        "from functools import singledispatch\n"
        "@singledispatch\n"
        "def label(value):\n"
        "    return 'object'\n"
        "@label.register\n"
        "def _(value: str):\n"
        "    return 'str:' + value\n"
        "@label.register\n"
        "def _(value: None):\n"
        "    return 'none'\n"
        "label('x') + '|' + label(None) + '|' + label(3)\n",
    ?assertMatch({ok, <<"str:x|none|object">>, _Env}, pyrlang:run_string(Source)).

importlib_resources_files_reads_package_data_test() ->
    pyrlang_heap:init(),
    Unique = integer_to_binary(erlang:unique_integer([positive])),
    Dir = filename:join("/tmp", "pyrlang_resources_" ++ binary_to_list(Unique)),
    PkgDir = filename:join(Dir, "pkg"),
    _ = file:del_dir_r(Dir),
    ok = file:make_dir(Dir),
    ok = file:make_dir(PkgDir),
    ok = file:write_file(filename:join(PkgDir, "__init__.py"), <<"value = 1\n">>),
    ok = file:write_file(filename:join(PkgDir, "data.txt"), <<"hello">>),
    erlang:erase(pyrlang_module_path),
    pyrlang_module:set_path([Dir | pyrlang_module:path()]),
    Source =
        "from importlib import resources\n"
        "import pkg\n"
        "data = resources.files('pkg').joinpath('data.txt').open('r').read()\n"
        "pkg.__spec__.name + ':' + data\n",
    ?assertMatch({ok, <<"pkg:hello">>, _Env}, pyrlang:run_string(Source)).

contextlib_generator_context_manager_reraises_body_exception_test() ->
    pyrlang_heap:init(),
    Source =
        "from contextlib import contextmanager\n"
        "@contextmanager\n"
        "def cm():\n"
        "    yield\n"
        "try:\n"
        "    with cm():\n"
        "        raise ValueError('bad')\n"
        "except ValueError:\n"
        "    'caught'\n",
    ?assertMatch({ok, <<"caught">>, _Env}, pyrlang:run_string(Source)).

contextlib_generator_context_manager_defers_finally_until_exit_test() ->
    pyrlang_heap:init(),
    Source =
        "from contextlib import contextmanager\n"
        "events = []\n"
        "@contextmanager\n"
        "def cm():\n"
        "    events.append('enter')\n"
        "    try:\n"
        "        yield 'value'\n"
        "    finally:\n"
        "        events.append('exit')\n"
        "with cm() as value:\n"
        "    events.append(value)\n"
        "'|'.join(events)\n",
    ?assertMatch({ok, <<"enter|value|exit">>, _Env}, pyrlang:run_string(Source)).

contextlib_generator_context_manager_return_continues_outer_function_test() ->
    pyrlang_heap:init(),
    Source =
        "from contextlib import contextmanager\n"
        "@contextmanager\n"
        "def cm():\n"
        "    yield\n"
        "    return\n"
        "def run():\n"
        "    with cm():\n"
        "        value = 1\n"
        "    return value + 1\n"
        "run()\n",
    ?assertMatch({ok, 2, _Env}, pyrlang:run_string(Source)).

contextlib_generator_context_manager_preserves_nested_render_context_test() ->
    pyrlang_heap:init(),
    Source =
        "from contextlib import contextmanager\n"
        "class RenderContext:\n"
        "    def __init__(self):\n"
        "        self.dicts = [{'block_context': 'active'}]\n"
        "        self.template = None\n"
        "    def push(self):\n"
        "        self.dicts.append({})\n"
        "    def pop(self):\n"
        "        self.dicts.pop()\n"
        "    @contextmanager\n"
        "    def push_state(self, template, isolated_context=True):\n"
        "        initial = self.template\n"
        "        self.template = template\n"
        "        if isolated_context:\n"
        "            self.push()\n"
        "        try:\n"
        "            yield\n"
        "        finally:\n"
        "            self.template = initial\n"
        "            if isolated_context:\n"
        "                self.pop()\n"
        "rc = RenderContext()\n"
        "with rc.push_state('parent', isolated_context=False):\n"
        "    before = 'block_context' in rc.dicts[-1]\n"
        "    with rc.push_state('child'):\n"
        "        inner = 'block_context' in rc.dicts[-1]\n"
        "    after = 'block_context' in rc.dicts[-1]\n"
        "before and (not inner) and after and rc.template is None\n",
    ?assertMatch({ok, true, _Env}, pyrlang:run_string(Source)).

contextlib_generator_context_manager_handles_pre_yield_exceptions_test() ->
    pyrlang_heap:init(),
    Source =
        "from contextlib import contextmanager\n"
        "@contextmanager\n"
        "def cm():\n"
        "    try:\n"
        "        raise RuntimeError('expected')\n"
        "    except RuntimeError:\n"
        "        ready = True\n"
        "    if ready:\n"
        "        yield 'ok'\n"
        "with cm() as value:\n"
        "    result = value\n"
        "result\n",
    ?assertMatch({ok, <<"ok">>, _Env}, pyrlang:run_string(Source)).

functools_update_wrapper_and_wraps_copy_function_metadata_test() ->
    pyrlang_heap:init(),
    Source =
        "from functools import update_wrapper, wraps\n"
        "def source():\n"
        "    return 1\n"
        "def target():\n"
        "    return 2\n"
        "same = update_wrapper(target, source) is target\n"
        "@wraps(source)\n"
        "def decorated():\n"
        "    return 3\n"
        "same + (target.__name__ == 'source') + hasattr(target, '__wrapped__') + (decorated.__name__ == 'source') + hasattr(decorated, '__wrapped__')\n",
    ?assertMatch({ok, 5, _Env}, pyrlang:run_string(Source)).

operator_or_combines_values_test() ->
    pyrlang_heap:init(),
    Source =
        "from functools import reduce\n"
        "from operator import or_\n"
        "items = reduce(or_, [{1}, {2}, {1, 3}])\n"
        "len(items) + or_(1, 2)\n",
    ?assertMatch({ok, 6, _Env}, pyrlang:run_string(Source)).

operator_arithmetic_helpers_cover_stdlib_fractions_import_test() ->
    pyrlang_heap:init(),
    Source =
        "import fractions\n"
        "import operator\n"
        "operator.sub(7, 2) + operator.mul(3, 4) + operator.floordiv(7, 2) + operator.mod(7, 2)\n",
    ?assertMatch({ok, 21, _Env}, pyrlang:run_string(Source)).

functools_partial_binds_args_and_keywords_test() ->
    pyrlang_heap:init(),
    Source =
        "from functools import partial\n"
        "def combine(a, b, c=0):\n"
        "    return a + b + c\n"
        "add = partial(combine, 2, c=5)\n"
        "add(3) + add(3, c=7) + add.func(1, 2, c=3)\n",
    ?assertMatch({ok, 28, _Env}, pyrlang:run_string(Source)).

functools_partialmethod_binds_instance_args_and_keywords_test() ->
    pyrlang_heap:init(),
    Source =
        "from functools import partialmethod\n"
        "class Box:\n"
        "    def combine(self, a, b, c=0):\n"
        "        return self.base + a + b + c\n"
        "    add = partialmethod(combine, 2, c=5)\n"
        "    def __init__(self):\n"
        "        self.base = 10\n"
        "Box().add(3) + Box().add(3, c=7)\n",
    ?assertMatch({ok, 42, _Env}, pyrlang:run_string(Source)).

functools_unwrap_partial_helpers_return_underlying_function_test() ->
    pyrlang_heap:init(),
    Source =
        "import functools\n"
        "def combine(a, b):\n"
        "    return a + b\n"
        "wrapped = functools.partial(functools.partial(combine, 2), 3)\n"
        "(functools._unwrap_partial(wrapped).__code__.co_argcount == 2) + "
        "(functools._unwrap_partialmethod(combine) is combine)\n",
    ?assertMatch({ok, 2, _Env}, pyrlang:run_string(Source)).

functools_total_ordering_adds_missing_comparisons_test() ->
    pyrlang_heap:init(),
    Source =
        "import functools\n"
        "@functools.total_ordering\n"
        "class Box:\n"
        "    def __init__(self, value):\n"
        "        self.value = value\n"
        "    def __lt__(self, other):\n"
        "        return self.value < other.value\n"
        "    def __eq__(self, other):\n"
        "        return self.value == other.value\n"
        "small = Box(1)\n"
        "large = Box(2)\n"
        "(small <= large) + (large > small) + (large >= small) + (small >= small)\n",
    ?assertMatch({ok, 4, _Env}, pyrlang:run_string(Source)).

builtin_struct_module_packs_and_unpacks_stdlib_formats_test() ->
    pyrlang_heap:init(),
    erlang:erase(pyrlang_module_path),
    Source =
        "import struct\n"
        "from _struct import _clearcache\n"
        "data = struct.pack('>I', 258)\n"
        "little = struct.unpack('<H', b'\\x02\\x01')[0]\n"
        "words = struct.Struct('!2I').unpack(b'\\x00\\x00\\x00\\x01\\x00\\x00\\x00\\x02')\n"
        "size = struct.calcsize('>I')\n"
        "same = struct.unpack('>I', data)[0]\n"
        "_clearcache()\n"
        "same + little + words[0] + words[1] + size\n",
    ?assertMatch({ok, 523, _Env}, pyrlang:run_string(Source)).

builtin_crypto_modules_provide_hash_hmac_and_tokens_test() ->
    pyrlang_heap:init(),
    Source =
        "import hashlib\n"
        "import hmac\n"
        "import secrets\n"
        "sha = hashlib.sha256(b'abc').hexdigest()\n"
        "md5 = hashlib.md5(b'abc', usedforsecurity=False).hexdigest()\n"
        "rolling = hashlib.md5(usedforsecurity=False)\n"
        "rolling.update(b'a')\n"
        "clone = rolling.copy()\n"
        "rolling.update(b'bc')\n"
        "empty = hashlib.sha1().hexdigest()\n"
        "mac = hmac.new(b'key', b'msg', 'sha256').hexdigest()\n"
        "mac_kw = hmac.new(b'key', msg=b'msg', digestmod=hashlib.sha256).hexdigest()\n"
        "len(sha) + len(mac) + len(md5) + len(empty) + len(secrets.token_hex(4)) + len(secrets.choice('ab')) + (rolling.hexdigest() == md5) + (clone.hexdigest() == hashlib.md5(b'a').hexdigest()) + (mac_kw == mac)\n",
    ?assertMatch({ok, 212, _Env}, pyrlang:run_string(Source)).

hashlib_pbkdf2_and_native_hash_attrs_match_cpython_binding_test() ->
    pyrlang_heap:init(),
    Source =
        "import hashlib\n"
        "class Hasher:\n"
        "    digest = hashlib.sha256\n"
        "h = Hasher()\n"
        "derived = hashlib.pbkdf2_hmac('sha256', b'password', b'salt', 1)\n"
        "(len(derived) == 32) + (h.digest().name == 'sha256') + (h.digest(b'abc').hexdigest() == hashlib.sha256(b'abc').hexdigest())\n",
    ?assertMatch({ok, 3, _Env}, pyrlang:run_string(Source)).

zlib_builtin_compresses_and_checksums_bytes_test() ->
    pyrlang_heap:init(),
    Source =
        "import zlib\n"
        "data = zlib.compress(b'abc')\n"
        "plain = zlib.decompress(data)\n"
        "len(data) + len(plain) + (zlib.crc32(b'abc') == 891568578) + (zlib.adler32(b'abc') == 38600999)\n",
    ?assertMatch({ok, 16, _Env}, pyrlang:run_string(Source)).

gzip_builtin_reads_text_and_compresses_bytes_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir(),
    ok = file:make_dir(Dir),
    Path = filename:join(Dir, "words.txt.gz"),
    ok = file:write_file(Path, zlib:gzip(<<"alpha\nbeta\n">>)),
    Source =
        "import gzip\n"
        "with gzip.open('" ++ Path ++ "', 'rt', encoding='utf-8') as f:\n"
        "    values = [x.strip() for x in f]\n"
        "data = gzip.decompress(gzip.compress(b'abc'))\n"
        "values[0] + values[1] + data.decode()\n",
    ?assertMatch({ok, <<"alphabetaabc">>, _Env}, pyrlang:run_string(Source)),
    cleanup_dir(Dir).

binascii_builtin_supports_stdlib_base64_test() ->
    pyrlang_heap:init(),
    erlang:erase(pyrlang_module_path),
    Source =
        "import base64\n"
        "import binascii\n"
        "encoded = base64.b64encode(b'abc')\n"
        "decoded = base64.b64decode(encoded)\n"
        "raw = binascii.a2b_base64(b'YWI=\\n')\n"
        "hexed = binascii.hexlify(b'Az')\n"
        "plain = binascii.unhexlify(hexed)\n"
        "try:\n"
        "    binascii.unhexlify(b'f')\n"
        "except binascii.Error:\n"
        "    marker = b'!'\n"
        "decoded + raw + plain + marker\n",
    ?assertMatch({ok, <<"abcabAz!">>, _Env}, pyrlang:run_string(Source)).

string_builtin_module_supports_stdlib_string_import_test() ->
    pyrlang_heap:init(),
    erlang:erase(pyrlang_module_path),
    Source =
        "import string\n"
        "value = string.ascii_lowercase[:3] + string.digits[-1]\n"
        "rendered = string.Formatter().format('{}', 'ok')\n"
        "value + rendered\n",
    ?assertMatch({ok, <<"abc9ok">>, _Env}, pyrlang:run_string(Source)).

builtin_contextvars_are_actor_local_test() ->
    pyrlang_heap:init(),
    Source =
        "import contextvars\n"
        "var = contextvars.ContextVar('request', default='missing')\n"
        "before = var.get()\n"
        "token = var.set('active')\n"
        "before + var.get() + token.old_value\n",
    ?assertMatch({ok, <<"missingactivemissing">>, _Env}, pyrlang:run_string(Source)).

builtin_native_resource_instances_are_unsendable_test() ->
    pyrlang_heap:init(),
    Source =
        "from erlang import self, send\n"
        "import contextvars\n"
        "import threading\n"
        "var = contextvars.ContextVar('request')\n"
        "lock = threading.Lock()\n"
        "caught = 0\n"
        "try:\n"
        "    send(self(), var)\n"
        "except TypeError:\n"
        "    caught = caught + 1\n"
        "try:\n"
        "    send(self(), lock)\n"
        "except TypeError:\n"
        "    caught = caught + 1\n"
        "caught\n",
    ?assertMatch({ok, 2, _Env}, pyrlang:run_string(Source)).

builtin_weakref_module_provides_actor_local_refs_and_containers_test() ->
    pyrlang_heap:init(),
    Source =
        "import weakref\n"
        "class Box:\n"
        "    pass\n"
        "box = Box()\n"
        "box.name = 'primary'\n"
        "ref = weakref.ref(box)\n"
        "proxy = weakref.proxy(box)\n"
        "values = weakref.WeakKeyDictionary()\n"
        "values[box] = 'seen'\n"
        "seen = weakref.WeakSet()\n"
        "seen.add(box)\n"
        "(ref().name == proxy.name) + (values[box] == 'seen') + (box in seen) + isinstance(ref, weakref.ReferenceType)\n",
    ?assertMatch({ok, 4, _Env}, pyrlang:run_string(Source)).

weakref_finalize_is_callable_and_detachable_test() ->
    pyrlang_heap:init(),
    Source =
        "import weakref\n"
        "class Box:\n"
        "    pass\n"
        "box = Box()\n"
        "calls = []\n"
        "def cleanup(value, *, extra=0):\n"
        "    calls.append(value + extra)\n"
        "    return value + extra\n"
        "fin = weakref.finalize(box, cleanup, 4, extra=3)\n"
        "before = fin.alive\n"
        "peek = fin.peek()\n"
        "result = fin()\n"
        "after = fin.alive\n"
        "detached = weakref.finalize(box, cleanup, 1).detach()\n"
        "before + result + len(calls) + after + (peek[0] is box) + (detached[0] is box)\n",
    ?assertMatch({ok, 11, _Env}, pyrlang:run_string(Source)).

builtin_private_weakref_supports_stdlib_weakrefset_test() ->
    pyrlang_heap:init(),
    erlang:erase(pyrlang_module_path),
    Source =
        "from _weakref import ref, getweakrefcount, getweakrefs, _remove_dead_weakref\n"
        "from _weakrefset import WeakSet\n"
        "class Box:\n"
        "    pass\n"
        "box = Box()\n"
        "wr = ref(box)\n"
        "seen = WeakSet()\n"
        "seen.add(box)\n"
        "data = {'gone': 1}\n"
        "_remove_dead_weakref(data, 'gone')\n"
        "(wr() is box) + (box in seen) + len(data) + getweakrefcount(box) + len(getweakrefs(box))\n",
    ?assertMatch({ok, 2, _Env}, pyrlang:run_string(Source)).

builtin_abc_module_supports_register_on_abcmeta_classes_test() ->
    pyrlang_heap:init(),
    Source =
        "from abc import ABCMeta\n"
        "class Base(metaclass=ABCMeta):\n"
        "    pass\n"
        "class Child:\n"
        "    pass\n"
        "Base.register(Child) is Child\n",
    ?assertMatch({ok, true, _Env}, pyrlang:run_string(Source)).

builtin_ast_backing_module_exposes_stdlib_classes_test() ->
    pyrlang_heap:init(),
    Source =
        "from _ast import AST, Constant, PyCF_ONLY_AST\n"
        "issubclass(Constant, AST) and PyCF_ONLY_AST == 1024\n",
    ?assertMatch({ok, true, _Env}, pyrlang:run_string(Source)).

types_method_type_binds_function_to_instance_test() ->
    pyrlang_heap:init(),
    Source =
        "from types import FunctionType, MethodType, coroutine\n"
        "class Box:\n"
        "    pass\n"
        "def add(self, value):\n"
        "    return self.base + value\n"
        "@coroutine\n"
        "def pause():\n"
        "    yield\n"
        "box = Box()\n"
        "box.base = 40\n"
        "bound = MethodType(add, box)\n"
        "bound(2) + bound.__func__(box, 1) + (bound.__self__ is box) + isinstance(add, FunctionType) + (next(pause()) is None)\n",
    ?assertMatch({ok, 86, _Env}, pyrlang:run_string(Source)).

types_mapping_proxy_and_dynamic_class_attribute_are_available_test() ->
    pyrlang_heap:init(),
    Source =
        "from types import MappingProxyType, DynamicClassAttribute\n"
        "data = {'x': 40}\n"
        "proxy = MappingProxyType(data)\n"
        "class Mine(DynamicClassAttribute):\n"
        "    pass\n"
        "proxy['x'] + proxy.get('missing', 1) + issubclass(Mine, DynamicClassAttribute)\n",
    ?assertMatch({ok, 42, _Env}, pyrlang:run_string(Source)).

typing_callable_alias_subscription_is_lazy_runtime_metadata_test() ->
    pyrlang_heap:init(),
    Source =
        "from typing import Any, Callable, TypeVar\n"
        "Alias = Callable[..., Any]\n"
        "T = TypeVar('T', bound=Alias)\n"
        "(T.__bound__ is Alias) + (len(Alias.__args__) == 2)\n",
    ?assertMatch({ok, 2, _Env}, pyrlang:run_string(Source)).

builtin_threading_module_maps_state_to_actor_local_objects_test() ->
    pyrlang_heap:init(),
    Source =
        "import threading\n"
        "import _thread\n"
        "class LocalState(threading.local):\n"
        "    pass\n"
        "class Worker(threading.Thread):\n"
        "    pass\n"
        "state = threading.local()\n"
        "state.count = 1\n"
        "substate = LocalState()\n"
        "substate.extra = 1\n"
        "lock = threading.RLock()\n"
        "with lock:\n"
        "    state.count = state.count + 1\n"
        "raw_lock = _thread.allocate_lock()\n"
        "raw_lock.acquire()\n"
        "raw_lock.release()\n"
        "sem = threading.Semaphore(0)\n"
        "sem_before = sem.acquire(blocking=False)\n"
        "sem.release()\n"
        "sem_after = sem.acquire(timeout=0)\n"
        "event = threading.Event()\n"
        "before = event.is_set()\n"
        "event.set()\n"
        "after = event.wait()\n"
        "atexit_result = threading._register_atexit(lambda: None)\n"
        "thread = threading.current_thread()\n"
        "worker = Worker(name='worker')\n"
        "worker.start()\n"
        "state.count + substate.extra + isinstance(substate, LocalState) + issubclass(LocalState, threading.local) + isinstance(thread, threading.Thread) + isinstance(worker, threading.Thread) + worker.is_alive() + lock.acquire() + raw_lock.acquire() + (sem_before == False) + sem_after + (before == False) + after + (atexit_result is None) + thread.is_alive() + (threading.get_ident() == thread.ident) + (_thread.get_ident() == _thread._get_main_thread_ident())\n",
    ?assertMatch({ok, 18, _Env}, pyrlang:run_string(Source)).

time_builtin_module_exposes_common_clock_and_timezone_hooks_test() ->
    pyrlang_heap:init(),
    Source =
        "import time\n"
        "now = time.time()\n"
        "tick = time.monotonic()\n"
        "epoch = time.gmtime(0)\n"
        "time.tzset()\n"
        "(now > 0) + (tick != 0) + (epoch[0] == 1970) + (time.strftime('%Y-%m-%d', epoch) == '1970-01-01') + (time.tzname[0] == 'UTC')\n",
    ?assertMatch({ok, 5, _Env}, pyrlang:run_string(Source)).

builtin_datetime_decimal_and_logging_modules_test() ->
    pyrlang_heap:init(),
    Source =
        "from datetime import datetime, date, time, timedelta, timezone, tzinfo\n"
        "from decimal import Context, Decimal, DecimalException, InvalidOperation, ROUND_UP, Rounded, getcontext\n"
        "import logging\n"
        "logger = logging.getLogger('pyrlang')\n"
        "logger.info('boot')\n"
        "now = datetime.now()\n"
        "aware = datetime.now(tz=timezone.utc)\n"
        "class MyDateTime(datetime):\n"
        "    pass\n"
        "stamp = now.isoformat()\n"
        "today = date.today().isoformat()\n"
        "sample = date(2001, 1, 1)\n"
        "delta = timedelta(minutes=2)\n"
        "fixed = timezone(delta, 'Fixed')\n"
        "amount = Decimal('1.50') + Decimal('2.25')\n"
        "rounded = int(Decimal('2.1').quantize(Decimal('0'), rounding=ROUND_UP))\n"
        "ctx = getcontext().copy()\n"
        "ctx.traps[Rounded] = 1\n"
        "rounded2 = int(Decimal('2.1').quantize(Decimal('0'), ROUND_UP, Context(prec=3)))\n"
        "parsed = datetime.fromisoformat('2026-05-04 12:34:56')\n"
        "parsed_date = date.fromisoformat('2026-05-04')\n"
        "parsed_time = time.fromisoformat('12:34:56')\n"
        "expires = datetime(2026, 5, 6, 1, 2, 3) + timedelta(seconds=60)\n"
        "tomorrow = datetime(2026, 5, 6, 1, 2, 3) + timedelta(days=1)\n"
        "delta_sum = timedelta(minutes=2) + timedelta(seconds=30)\n"
        "delta_diff = datetime(2026, 5, 6, 1, 2, 3) - datetime(2026, 5, 6, 1, 1, 3)\n"
        "try:\n"
        "    datetime.fromisoformat('')\n"
        "    invalid_iso = False\n"
        "except ValueError:\n"
        "    invalid_iso = True\n"
        "len(stamp) + len(today) + len(amount.value) + rounded + (time.__name__ == 'TimeType') + (sample.weekday() == 0) + (sample.strftime('%A %B') == 'Monday January') + (date(1970, 1, 1).toordinal() == 719163) + isinstance(delta, timedelta) + (delta.total_seconds() == 120) + isinstance(fixed, tzinfo) + (fixed.tzname(None) == 'Fixed') + (timezone.utc.tzname(None) == 'UTC') + (datetime(1970, 1, 1).toordinal() == 719163) + (now.date().isoformat() == today) + issubclass(InvalidOperation, DecimalException) + (getcontext().prec == 28) + (Context(prec=3).prec == 3) + (ctx.traps[Rounded] == 1) + rounded2 + issubclass(MyDateTime, datetime) + isinstance(now, datetime) + isinstance(aware, datetime) + (aware.utcoffset().total_seconds() == 0) + (aware.astimezone(fixed).utcoffset().total_seconds() == 120) + (aware.replace(tzinfo=None).utcoffset() is None) + (str(datetime(2026, 5, 4, 1, 2, 3)) == '2026-05-04 01:02:03') + (parsed.second == 56) + (parsed_date.day == 4) + (parsed_time.minute == 34) + (expires.minute == 3) + (tomorrow.day == 7) + (delta_sum.total_seconds() == 150) + (delta_diff.total_seconds() == 60) + invalid_iso\n",
    ?assertMatch({ok, 69, _Env}, pyrlang:run_string(Source)).

sqlite3_fetch_rows_are_tuples_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir(),
    ok = file:make_dir(Dir),
    DbPath = filename:join(Dir, "rows.sqlite3"),
    Source = iolist_to_binary([
        "import sqlite3\n",
        "conn = sqlite3.connect('", DbPath, "')\n",
        "cur = conn.cursor()\n",
        "cur.execute('create table items (name text, count integer)')\n",
        "cur.execute('insert into items values (?, ?)', ('task', 3))\n",
        "row = cur.execute('select name, count from items').fetchone()\n",
        "rows = cur.execute('select name, count from items').fetchall()\n",
        "('%s:%d' % row) + ':' + str(isinstance(row, tuple)) + ':' + str(isinstance(rows, list)) + ':' + str(isinstance(rows[0], tuple))\n"
    ]),
    ?assertMatch({ok, <<"task:3:True:True:True">>, _Env}, pyrlang:run_string(Source)),
    cleanup_dir(Dir).

psycopg2_builtin_module_runs_basic_dbapi_queries_test() ->
    case os:find_executable("psql") of
        false ->
            ok;
        _Psql ->
            pyrlang_heap:init(),
            Table = lists:flatten(io_lib:format("pyrlang_pg_~p_~p", [erlang:unique_integer([positive]), erlang:system_time(millisecond)])),
            Source = iolist_to_binary([
                "import psycopg2\n",
                "from psycopg2 import extensions\n",
                "conn = psycopg2.connect(dbname='postgres')\n",
                "cur = conn.cursor()\n",
                "cur.execute('drop table if exists ", Table, "')\n",
                "cur.execute('create table ", Table, "(id integer generated by default as identity primary key, title text, done boolean)')\n",
                "row = cur.execute('insert into ", Table, "(title, done) values (%s, %s) returning id', ['write pg', False]).fetchone()\n",
                "updated = cur.execute('update ", Table, " set done = %s where id = %s', [True, row[0]]).rowcount\n",
                "rows = cur.execute('select id, title, done from ", Table, " where id = %s', [row[0]]).fetchall()\n",
                "quoted = extensions.adapt(\"O'Reilly\").getquoted().decode()\n",
                "cur.execute('drop table ", Table, "')\n",
                "conn.close()\n",
                "str(row[0]) + ':' + rows[0][1] + ':' + str(rows[0][2]) + ':' + str(updated) + ':' + quoted\n"
            ]),
            ?assertMatch({ok, <<"1:write pg:True:1:'O''Reilly'">>, _Env}, pyrlang:run_string(Source))
    end.

builtin_pathlib_module_uses_beam_file_io_test() ->
    pyrlang_heap:init(),
    Unique = integer_to_binary(erlang:system_time(nanosecond)),
    Dir = filename:join("/tmp", "pyrlang_pathlib_" ++ binary_to_list(Unique)),
    ok = file:make_dir(Dir),
    Source = iolist_to_binary([
        "import os\n"
        "from pathlib import Path, PurePath, PosixPath\n",
        "__file__ = '", Dir, "/pkg/module.py'\n",
        "base = Path('", Dir, "')\n",
        "path = base / 'note.txt'\n",
        "pure = PurePath('", Dir, "')\n",
        "combo = Path('", Dir, "', 'nested')\n",
        "written = path.write_text('hello')\n",
        "root = Path(__file__).resolve().parent.parent\n",
        "written + len(path.read_text()) + path.exists() + base.is_dir() + path.is_file() + (not path.is_dir()) + str(root).startswith('/') + (path.__fspath__().endswith('note.txt')) + isinstance(path, PurePath) + isinstance(path, Path) + isinstance(path, os.PathLike) + isinstance(pure, PurePath) + isinstance(pure, Path) + (PosixPath is Path) + str(combo).endswith('/nested')\n"
    ]),
    ?assertMatch({ok, 22, _Env}, pyrlang:run_string(Source)),
    _ = file:delete(filename:join(Dir, "note.txt")),
    _ = file:del_dir(Dir),
    ok.

builtin_open_uses_beam_file_io_and_is_actor_local_resource_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir(),
    ok = file:make_dir(Dir),
    Path = filename:join(Dir, "note.txt"),
    Source = iolist_to_binary([
        "from erlang import self, send\n",
        "with open('", Path, "', 'w') as f:\n",
        "    written = f.write('hello')\n",
        "with open('", Path, "') as f:\n",
        "    data = f.read()\n",
        "with open('", Path, "', 'rb') as f:\n",
        "    f.seek(2)\n",
        "    pos = f.tell()\n",
        "    tail = f.read()\n",
        "with open('", Path, "', encoding='utf-8') as f:\n",
        "    data_kw = f.read()\n",
        "f = open('", Path, "')\n",
        "try:\n",
        "    send(self(), f)\n",
        "    marker = 'sent'\n",
        "except TypeError:\n",
        "    marker = 'unsendable'\n",
        "f.close()\n",
        "try:\n"
        "    open('", filename:join(Dir, "missing.txt"), "')\n"
        "    missing = 'opened'\n"
        "except FileNotFoundError:\n"
        "    missing = 'missing'\n"
        "str(written) + ':' + data + ':' + data_kw + ':' + str(pos) + ':' + tail.decode() + ':' + marker + ':' + missing\n"
    ]),
    ?assertMatch({ok, <<"5:hello:hello:2:llo:unsendable:missing">>, _Env}, pyrlang:run_string(Source)),
    cleanup_dir(Dir).

builtin_io_module_loads_stdlib_io_test() ->
    pyrlang_heap:init(),
    Source =
        "import io\n"
        "class LimitedStream(io.IOBase):\n"
        "    pass\n"
        "bio = io.BytesIO(b'ab')\n"
        "bio.write(b'cd')\n"
        "pos = bio.tell()\n"
        "bio.seek(0)\n"
        "data = bio.read()\n"
        "sio = io.StringIO('hi')\n"
        "sio.seek(2)\n"
        "sio.write('!')\n"
        "io.DEFAULT_BUFFER_SIZE + (io.UnsupportedOperation.__module__ == 'io') + (LimitedStream().close() is None) + (pos == 2) + (data == b'cd') + (sio.getvalue() == 'hi!')\n",
    ?assertMatch({ok, 8197, _Env}, pyrlang:run_string(Source)).

builtin_opcode_module_supports_stdlib_dis_import_test() ->
    pyrlang_heap:init(),
    Source =
        "import dis\n"
        "('dis' == dis.__name__) + (len(dis.opname) > 0)\n",
    ?assertMatch({ok, 2, _Env}, pyrlang:run_string(Source)).

collections_abc_alias_loads_stdlib_collections_abc_test() ->
    pyrlang_heap:init(),
    Source =
        "import collections.abc\n"
        "('collections.abc' == collections.abc.__name__) + hasattr(collections.abc, 'Mapping') + isinstance([], collections.abc.Iterable) + isinstance('x', collections.abc.Iterable) + (not isinstance(1, collections.abc.Iterable))\n",
    ?assertMatch({ok, 5, _Env}, pyrlang:run_string(Source)).

imp_builtin_module_supports_importlib_bootstrap_imports_test() ->
    pyrlang_heap:init(),
    Source =
        "import _imp\n"
        "_imp.acquire_lock()\n"
        "_imp.release_lock()\n"
        "len(_imp.extension_suffixes()) + (_imp.is_builtin('sys') == False) + (_imp.is_frozen('x') == False) + len(_imp.source_hash(1, b'data'))\n",
    ?assertMatch({ok, 10, _Env}, pyrlang:run_string(Source)).

frozen_importlib_aliases_load_bootstrap_helpers_test() ->
    pyrlang_heap:init(),
    Source =
        "import _frozen_importlib as bootstrap\n"
        "import _frozen_importlib_external as external\n"
        "from _frozen_importlib_external import _unpack_uint16\n"
        "import importlib.util\n"
        "hasattr(bootstrap, '_verbose_message') + hasattr(external, '_LoaderBasics') + (_unpack_uint16(b'\\x02\\x00') == 2) + (importlib.util.find_spec('pyrlang_missing_module_name') is None)\n",
    ?assertMatch({ok, 4, _Env}, pyrlang:run_string(Source)).

warnings_builtin_module_supports_stdlib_warning_hooks_test() ->
    pyrlang_heap:init(),
    Source =
        "import _warnings\n"
        "_warnings.warn('note', DeprecationWarning)\n"
        "len(_warnings.filters) + (_warnings._defaultaction == 'default') + hasattr(_warnings, 'warn_explicit')\n",
    ?assertMatch({ok, 2, _Env}, pyrlang:run_string(Source)).

warnings_stdlib_module_uses_sys_warnoptions_test() ->
    pyrlang_heap:init(),
    Source =
        "import warnings\n"
        "import sys\n"
        "len(sys.warnoptions) + hasattr(warnings, 'warn')\n",
    ?assertMatch({ok, 1, _Env}, pyrlang:run_string(Source)).

hasattr_and_getattr_default_treat_missing_module_attrs_as_absent_test() ->
    pyrlang_heap:init(),
    Source =
        "import sys\n"
        "import warnings\n"
        "(not hasattr(warnings, 'missing')) + (getattr(warnings, 'missing', 'fallback') == 'fallback') + (sys.modules['warnings'] is warnings)\n",
    ?assertMatch({ok, 3, _Env}, pyrlang:run_string(Source)).

module_getattr_is_used_for_missing_module_attributes_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir(),
    ok = file:make_dir(Dir),
    ok = file:write_file(filename:join(Dir, "lazy.py"), <<
        "def __getattr__(name):\n"
        "    if name == 'answer':\n"
        "        return 42\n"
        "    raise AttributeError(name)\n"
    >>),
    ok = pyrlang:set_path([Dir]),
    ?assertMatch({ok, 42, _Env}, pyrlang:run_string("from lazy import answer\nanswer\n")),
    file:delete(filename:join(Dir, "lazy.py")),
    file:del_dir(Dir).

dir_on_modules_exposes_module_globals_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir(),
    ok = file:make_dir(Dir),
    ok = file:write_file(filename:join(Dir, "config.py"), <<
        "TIME_ZONE = 'UTC'\n"
        "SECRET_KEY = 'test'\n"
        "_private = 1\n"
    >>),
    ok = pyrlang:set_path([Dir]),
    Source =
        "import config\n"
        "names = dir(config)\n"
        "('TIME_ZONE' in names) + ('SECRET_KEY' in names) + ('_private' in names)\n",
    ?assertMatch({ok, 3, _Env}, pyrlang:run_string(Source)),
    file:delete(filename:join(Dir, "config.py")),
    file:del_dir(Dir).

marshal_builtin_module_is_available_for_importlib_test() ->
    pyrlang_heap:init(),
    Source =
        "import marshal\n"
        "len(marshal.dumps(1)) + marshal.version\n",
    ?assertMatch({ok, 5, _Env}, pyrlang:run_string(Source)).

codecs_builtin_module_supports_stdlib_tokenize_test() ->
    pyrlang_heap:init(),
    erlang:erase(pyrlang_module_path),
    Source =
        "import codecs\n"
        "import tokenize\n"
        "info = codecs.lookup('utf-8')\n"
        "decoded = b'abc'.decode('utf-8')\n"
        "encoded = codecs.encode('abc', 'utf-8')\n"
        "lines = iter([b'# coding: utf-8'])\n"
        "detected = tokenize.detect_encoding(lines.__next__)[0]\n"
        "info.name + ':' + decoded + ':' + encoded + ':' + detected\n",
    ?assertMatch({ok, <<"utf-8:abc:abc:utf-8">>, _Env}, pyrlang:run_string(Source)).

types_builtin_module_supports_stdlib_inspect_test() ->
    pyrlang_heap:init(),
    erlang:erase(pyrlang_module_path),
    Source =
        "import inspect\n"
        "import types\n"
        "def fn(first, second=2, *args, flag=True, **kwargs):\n"
        "    return first\n"
        "async def coro():\n"
        "    return 1\n"
        "def gen():\n"
        "    yield 1\n"
        "async def agen():\n"
        "    yield 1\n"
        "def marked():\n"
        "    return 1\n"
        "marked = inspect.markcoroutinefunction(marked)\n"
        "class Backend:\n"
        "    def authenticate(self, request, username=None, password=None, **kwargs):\n"
        "        return username\n"
        "sig = inspect.signature(fn)\n"
        "params = sig.parameters\n"
        "bound = sig.bind(1, 3, flag=False, extra=True)\n"
        "backend_sig = inspect.signature(Backend().authenticate)\n"
        "backend_bound = backend_sig.bind(None, username='u', password='p')\n"
        "try:\n"
        "    sig.bind()\n"
        "    missing = False\n"
        "except TypeError:\n"
        "    missing = True\n"
        "hasattr(types, 'MemberDescriptorType') + hasattr(types, 'GetSetDescriptorType') + hasattr(types, 'WrapperDescriptorType') + hasattr(inspect, 'signature') + (fn.__defaults__[0] == 2) + (fn.__kwdefaults__['flag'] == True) + ('kwargs' in params) + hasattr(bound, 'arguments') + hasattr(backend_bound, 'arguments') + missing + inspect.iscoroutinefunction(coro) + inspect.iscoroutinefunction(marked) + inspect.isgeneratorfunction(gen) + inspect.isasyncgenfunction(agen) + (not inspect.iscoroutinefunction(gen))\n",
    ?assertMatch({ok, 15, _Env}, pyrlang:run_string(Source)).

typing_helper_module_provides_type_parameter_primitives_test() ->
    pyrlang_heap:init(),
    Source =
        "import _typing\n"
        "T = _typing.TypeVar('T', default=int)\n"
        "P = _typing.ParamSpec('P')\n"
        "class Box(_typing.Generic[T]):\n"
        "    pass\n"
        "isinstance(T, _typing.TypeVar) + T.has_default() + (P.args.__origin__ is P) + (_typing._idfunc('x') == 'x') + (Box.__bases__[0] is _typing.Generic)\n",
    ?assertMatch({ok, 5, _Env}, pyrlang:run_string(Source)).

posix_builtin_module_supports_importlib_filesystem_hooks_test() ->
    pyrlang_heap:init(),
    Source =
        "import posix\n"
        "root = posix._path_splitroot('/tmp/a')\n"
        "base = (posix.fspath('x') == 'x') + (root[1] == '/') + (posix.stat('.').st_size >= 0) + len(posix.listdir('.')) >= 3\n"
        "base + (posix.O_RDONLY == 0)\n",
    ?assertMatch({ok, 2, _Env}, pyrlang:run_string(Source)).

builtin_http_cookies_module_supports_dotted_import_test() ->
    pyrlang_heap:init(),
    Source =
        "import http\n"
        "import http.client\n"
        "import http.cookies\n"
        "from http.cookies import SimpleCookie\n"
        "cookie = SimpleCookie()\n"
        "cookie.load('session=abc; csrftoken=xyz')\n"
        "http.HTTPStatus.OK.phrase + http.client.OK.phrase + http.client.responses[http.HTTPStatus.OK] + cookie.get('session') + cookie.get('csrftoken') + http.cookies.SimpleCookie().output() + cookie.values()[0].output(header='') + http.cookies._unquote('\\\"quoted\\\"')\n",
    ?assertMatch({ok, <<"OKOKOKabcxyzsession=abcquoted">>, _Env}, pyrlang:run_string(Source)).

http_simplecookie_supports_item_assignment_and_morsel_attrs_test() ->
    pyrlang_heap:init(),
    Source =
        "from http.cookies import SimpleCookie\n"
        "cookie = SimpleCookie()\n"
        "cookie['csrftoken'] = 'abc'\n"
        "cookie['csrftoken']['path'] = '/'\n"
        "cookie['csrftoken']['samesite'] = 'Lax'\n"
        "cookie.get('csrftoken') + '|' + cookie['csrftoken'].output(header='')\n",
    ?assertMatch({ok, <<"abc|csrftoken=abc; Path=/; SameSite=Lax">>, _Env}, pyrlang:run_string(Source)).

builtin_urllib_parse_module_handles_web_url_helpers_test() ->
    pyrlang_heap:init(),
    Source =
        "import urllib.parse\n"
        "encoded = urllib.parse.quote('/a b')\n"
        "plus = urllib.parse.urlencode({'q': 'a b'})\n"
        "seq = urllib.parse.urlencode({'tag': ['a b', 'c']}, True)\n"
        "parsed = urllib.parse.parse_qs('q=a+b&q=c')\n"
        "split = urllib.parse.urlsplit('https://example.com/a?x=1#top')\n"
        "parse = urllib.parse.urlparse('https://example.com/a?x=1#top')\n"
        "port = urllib.parse._splitport('example.com:443')\n"
        "rebuilt = urllib.parse.urlunparse(('https', 'example.com', '/a', '', 'x=1', 'top'))\n"
        "static_url = urllib.parse.urljoin('/static/', 'admin/css/base.css')\n"
        "pairs = urllib.parse.parse_qsl('q=a+b&empty=', keep_blank_values=True)\n"
        "rebuilt_split = urllib.parse.urlunsplit(('https', 'example.com', '/a', 'x=1', 'top'))\n"
        "defrag = urllib.parse.urldefrag('/static/app.css#v1')\n"
        "defrag_url, defrag_fragment = defrag\n"
        "encoded + '|' + plus + '|' + seq + '|' + parsed['q'][0] + parsed['q'][1] + pairs[0][1] + pairs[1][1] + '|' + split.scheme + split.netloc + split.path + split.query + split.fragment + '|' + parse[1] + port[1] + '|' + rebuilt + '|' + rebuilt_split + '|' + static_url + '|' + defrag_url + ':' + defrag_fragment + ':' + defrag.fragment\n",
    ?assertMatch({ok, <<"/a%20b|q=a+b|tag=a+b&tag=c|a bca b|httpsexample.com/ax=1top|example.com443|https://example.com/a?x=1#top|https://example.com/a?x=1#top|/static/admin/css/base.css|/static/app.css:v1:v1">>, _Env}, pyrlang:run_string(Source)).

builtin_email_utils_module_formats_dates_test() ->
    pyrlang_heap:init(),
    Source =
        "from datetime import datetime\n"
        "from email.utils import formatdate, format_datetime, _has_surrogates\n"
        "formatdate(0) + ':' + formatdate(0, usegmt=True) + ':' + format_datetime(datetime(1970, 1, 1), usegmt=True) + ':' + str(_has_surrogates('plain'))\n",
    ?assertMatch({ok, <<"Thu, 01 Jan 1970 00:00:00 GMT:Thu, 01 Jan 1970 00:00:00 GMT:Thu, 01 Jan 1970 00:00:00 GMT:False">>, _Env}, pyrlang:run_string(Source)).

module_cache_is_actor_local_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir(),
    ok = file:make_dir(Dir),
    Path = filename:join(Dir, "state.pyr"),
    ok = file:write_file(Path, <<"value = 1\n">>),
    ok = pyrlang:set_path([Dir]),
    ?assertMatch({ok, 1, _Env}, pyrlang:run_string("import state\nstate.value\n")),
    ok = file:write_file(Path, <<"value = 2\n">>),
    Parent = pyrlang_actor:self(),
    Pid = pyrlang_actor:spawn(fun() ->
        ok = pyrlang:set_path([Dir]),
        {ok, Value, _Env} = pyrlang:run_string("import state\nstate.value\n"),
        pyrlang_actor:send(Parent, Value)
    end),
    ?assert(is_pid(Pid)),
    ?assertEqual(2, pyrlang_actor:recv(1000)),
    ?assertMatch({ok, 1, _Env}, pyrlang:run_string("import state\nstate.value\n")),
    cleanup_dir(Dir).

failed_imports_are_not_left_in_module_cache_test() ->
    pyrlang_heap:init(),
    Dir = temp_dir(),
    ok = file:make_dir(Dir),
    Path = filename:join(Dir, "broken.py"),
    ok = file:write_file(Path, <<"import definitely_missing_pyrlang_module\nvalue = 1\n">>),
    ok = pyrlang:set_path([Dir]),
    Source =
        "try:\n"
        "    import broken\n"
        "except ImportError:\n"
        "    first = 'caught'\n"
        "try:\n"
        "    import broken\n"
        "except ImportError:\n"
        "    second = 'caught'\n"
        "first + second\n",
    ?assertMatch({ok, <<"caughtcaught">>, _Env}, pyrlang:run_string(Source)),
    cleanup_dir(Dir).

try_except_finally_test() ->
    pyrlang_heap:init(),
    Source =
        "result = 'missing'\n"
        "try:\n"
        "    raise ValueError('bad')\n"
        "except ValueError as err:\n"
        "    result = 'caught'\n"
        "finally:\n"
        "    result = result + '!'\n"
        "result\n",
    ?assertMatch({ok, <<"caught!">>, _Env}, pyrlang:run_string(Source)).

try_except_else_test() ->
    pyrlang_heap:init(),
    Source =
        "items = []\n"
        "try:\n"
        "    value = int('3')\n"
        "except ValueError:\n"
        "    items.append('bad')\n"
        "else:\n"
        "    items.append(value)\n"
        "items[0]\n",
    ?assertMatch({ok, 3, _Env}, pyrlang:run_string(Source)).

base_exception_handlers_match_ordinary_exceptions_test() ->
    pyrlang_heap:init(),
    Source =
        "try:\n"
        "    raise ValueError('bad')\n"
        "except Exception:\n"
        "    result = 'caught'\n"
        "result\n",
    ?assertMatch({ok, <<"caught">>, _Env}, pyrlang:run_string(Source)).

tuple_exception_handlers_match_any_listed_type_test() ->
    pyrlang_heap:init(),
    Source =
        "try:\n"
        "    raise TypeError('bad')\n"
        "except (ValueError, TypeError):\n"
        "    result = 'caught'\n"
        "result\n",
    ?assertMatch({ok, <<"caught">>, _Env}, pyrlang:run_string(Source)).

builtin_exception_constructors_keep_args_and_match_base_types_test() ->
    pyrlang_heap:init(),
    Source =
        "try:\n"
        "    raise FileNotFoundError(2, 'missing', 'path.txt')\n"
        "except OSError as err:\n"
        "    result = (err.args[0] == 2) + (err.errno == 2) + (err.strerror == 'missing') + (err.filename == 'path.txt') + isinstance(err, FileNotFoundError) + issubclass(FileNotFoundError, OSError) + (str(err) == 'missing')\n"
        "result\n",
    ?assertMatch({ok, 7, _Env}, pyrlang:run_string(Source)).

exception_matcher_rejects_non_exception_patterns_test() ->
    Exception = pyrlang_exception:make(pyrlang_exception:type(<<"AttributeError">>), <<"end">>),
    ?assertEqual(false, pyrlang_exception:matches(95, Exception)).

bare_raise_reraises_active_exception_test() ->
    pyrlang_heap:init(),
    Source =
        "try:\n"
        "    try:\n"
        "        raise ValueError('bad')\n"
        "    except ValueError:\n"
        "        raise\n"
        "except ValueError:\n"
        "    result = 'reraised'\n"
        "result\n",
    ?assertMatch({ok, <<"reraised">>, _Env}, pyrlang:run_string(Source)).

bare_raise_without_active_exception_is_runtime_error_test() ->
    pyrlang_heap:init(),
    Source =
        "try:\n"
        "    raise\n"
        "except RuntimeError:\n"
        "    result = 'runtime'\n"
        "result\n",
    ?assertMatch({ok, <<"runtime">>, _Env}, pyrlang:run_string(Source)).

attribute_and_subscript_errors_are_catchable_pyrlang_exceptions_test() ->
    pyrlang_heap:init(),
    Source =
        "class Box:\n"
        "    pass\n"
        "obj = Box()\n"
        "try:\n"
        "    obj.missing\n"
        "except AttributeError:\n"
        "    attr = 'attr'\n"
        "try:\n"
        "    [1][5]\n"
        "except IndexError:\n"
        "    index = 'index'\n"
        "try:\n"
        "    {}['missing']\n"
        "except KeyError:\n"
        "    key = 'key'\n"
        "attr + ':' + index + ':' + key\n",
    ?assertMatch({ok, <<"attr:index:key">>, _Env}, pyrlang:run_string(Source)).

operator_errors_are_catchable_pyrlang_exceptions_test() ->
    pyrlang_heap:init(),
    Source =
        "try:\n"
        "    1 + []\n"
        "except TypeError:\n"
        "    type_error = 'type'\n"
        "try:\n"
        "    1 / 0\n"
        "except ZeroDivisionError:\n"
        "    zero_error = 'zero'\n"
        "type_error + ':' + zero_error\n",
    ?assertMatch({ok, <<"type:zero">>, _Env}, pyrlang:run_string(Source)).

uncaught_exception_returns_error_test() ->
    pyrlang_heap:init(),
    {error, Exception} = pyrlang:run_string("raise ValueError('bad')\n"),
    ?assert(pyrlang_exception:is_exception(Exception)),
    ?assertEqual(<<"ValueError">>, pyrlang_exception:exception_type(Exception)),
    ?assertEqual(<<"bad">>, pyrlang_exception:message(Exception)).

temp_dir() ->
    filename:join(
        "/tmp",
        lists:flatten(io_lib:format("pyrlang_module_~p_~p", [erlang:unique_integer([positive]), erlang:system_time(millisecond)]))
    ).

cleanup_dir(Dir) ->
    case file:list_dir(Dir) of
        {ok, Files} ->
            lists:foreach(fun(File) -> file:delete(filename:join(Dir, File)) end, Files),
            file:del_dir(Dir);
        _ ->
            ok
    end.
