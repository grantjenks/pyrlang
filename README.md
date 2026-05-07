# Pyrlang

Pyrlang is Python implemented on the BEAM, primarily in Erlang/OTP.

The project goal is not to build a CPython package, a `python -m` runner, or a
Python library that mimics Erlang. Pyrlang source is parsed, loaded, evaluated,
interpreted, or compiled by BEAM-resident runtime code.

Current repository contents:

- `SPEC.md`: language and runtime semantics.
- `WEB.md`: Pyrunicorn WSGI target architecture.
- `src/`: BEAM-native Erlang runtime modules.
- `test/`: EUnit tests for the current runtime slice.
- `bin/`: BEAM-native escript entrypoints for `pyrlang` and `pyrunicorn`.
- `include/`: shared Erlang definitions.
- `Makefile`: plain `erlc`/`erl` build and test entrypoint.

Implemented foundation:

- Actor-local heaps and mutable container/object references.
- Message export/import with copied mutable values and cyclic object graphs.
  Native stdlib objects that close over actor-local state or BEAM resources are
  marked unsendable and surface as Pyrlang `TypeError` through source-level
  `send()`.
- BEAM actor primitives: spawn, send, receive, selective receive, call/reply,
  source-level links, monitors, demonitoring, linked spawn, exit trapping,
  registration, source-level receive timeouts, and explicit atom-safe Erlang
  calls through `erlang.apply`.
- Parser/evaluator subset for expressions, assignments, functions, classes,
  methods, attributes, subscripts, decorators, `if`/`elif`/`else`, `while`,
  `for`, `try`/`except`/`finally`, `with`, `yield`, lambdas, boolean
  operators, membership, identity comparisons, simple slices,
  keyword/default arguments, `*args`/`**kwargs`, call expansion, `range`, and
  list/dict/set comprehensions.
- Literal support for `None`, booleans, integers, floats, strings, bytes,
  tuples, lists, dicts, and sets.
- Object model foundation: classes, instances, descriptors, bound methods, and
  C3 MRO, including `super()`, `property`, `staticmethod`, `classmethod`, and
  callable instances plus arithmetic/comparison special-method dispatch. Class
  suites execute supported Pyrlang statements including nested classes,
  imports, conditionals, loops, exception handlers, and context managers.
- Basic metaclass creation and inherited metaclass selection through
  `class C(metaclass=...)` and `type(name, bases, attrs)`.
- Dynamic object helpers: `getattr`, `setattr`, `hasattr`, `isinstance`,
  `issubclass`, and `type(obj)` for Pyrlang instances.
- BEAM-backed `open()` for basic file read/write/close and context-manager
  use, with live file handles marked as actor-local unsendable resources.
- Actor-local module/package loading/imports from `.py` and `__init__.py`
  source files, with `.pyr` accepted as a legacy project-local extension, plus BEAM-native `erlang`, `os`, `re`, `hashlib`, `hmac`,
  `secrets`, `contextvars`, `weakref`, `threading`, `importlib`, `datetime`,
  `decimal`, `logging`, `pathlib`, `http.cookies`, `urllib.parse`, and
  `email.utils` modules, plus a minimal actor-backed `sqlite3` DB-API surface.
- Pyrlang exception values with catch/raise flow, `StopIteration`, catchable
  attribute/subscript/operator errors, and bare `raise` re-raising the active
  exception inside exception handlers.
- Generator objects, the user-visible `__iter__`/`__next__` protocol, and
  source-level mutable list/dict operations, including `iter`, `list`, `tuple`,
  `dict`, and `set` constructors.
- One-for-one supervisor foundation.
- Actor-backed SQLite access through an Erlang port to `sqlite3`, with
  connection-scoped transactions, DB-API connection/cursor objects marked as
  actor-local resources, and connection actor crashes mapped to DB-API
  operational errors.
- Pyrunicorn WSGI environ/worker/http/server foundation that loads Pyrlang
  `module:callable` apps inside worker actors, provides basic WSGI stream
  objects with sized and line reads, supports iterable response bodies and the
  `start_response` write callable including `exc_info` replacement before
  headers are sent, threads configured and socket-derived WSGI environ values
  such as `SERVER_PORT` and `REMOTE_ADDR` into Pyrlang-source apps, isolates
  worker module globals, returns 400 responses for malformed requests and 500
  responses for app and worker failures, reads `Content-Length` bodies across
  TCP packets, serves over a real TCP socket with a round-robin worker pool,
  restarts crashed workers, and boots a small Pyrlang-source Django-shaped WSGI
  shim with a minimal middleware chain.
- BEAM-native `bin/pyrlang` and `bin/pyrunicorn` escript wrappers. `pyrunicorn`
  accepts `--bind`, `--workers`, `--django-settings-module`, and `--path`.
- `pyrlang -m module ...` executes a module or package `__main__.py` through the
  Pyrlang runtime and exposes arguments through the BEAM-native `sys.argv`.

Run the current verification suite:

```bash
make test
```

Build and refresh executable entrypoint bits:

```bash
make entrypoints
```

This repository implements the current scoped contracts in `SPEC.md` and
`WEB.md`: Python-syntax Pyrlang source running on BEAM-resident runtime code,
actor-backed runtime behavior, and Pyrlang-source WSGI on BEAM-native
Pyrunicorn. Larger Python and Django compatibility areas remain outside the
current scope until the specifications are expanded.
