# Pyrlang Web Runtime Plan

**Draft version:** 0.4

This document describes the web target for Pyrlang. It depends on the
BEAM-native language runtime in `SPEC.md`.

This is not a plan for a CPython web adapter, CPython Django wrapper, or Python
runner.

The web goal is:

```text
Run WSGI applications written in Pyrlang source on a BEAM-native server called
Pyrunicorn.
```

For now, "Django-shaped" means only the deployment shape that many Python
projects use:

```text
module:callable application loading
optional settings-module environment value
request environ passed to application(environ, start_response)
middleware/app callable patterns where the Pyrlang runtime supports them
```

It does not mean upstream Django support. It does not mean importing CPython
Django. It does not mean routing requests to CPython.

Until Pyrlang can load and execute the needed source itself, the honest claim is
WSGI support with a Django-shaped boot path.

---

# 1. Runtime Boundary

The same boundary from `SPEC.md` applies here:

```text
Pyrlang source must run because Pyrlang implements Python semantics on the BEAM.
Pyrunicorn must not invoke CPython to run the application.
```

Valid web implementation forms:

```text
BEAM-native Pyrunicorn listener and worker actors
Pyrlang modules loaded by the Pyrlang BEAM runtime
Pyrlang-source WSGI applications
BEAM resources, ports, or drivers for external services
Erlang/OTP supervisors for listener, worker, and resource processes
```

Invalid web implementation forms:

```text
python -m pyrlang.runner
pyrlang.runner as a web boot path
runpy, exec, or eval around Django or Pyrlang files
CPython WSGI server hidden behind a Pyrlang command
CPython threads pretending to be Pyrlang workers
CPython Django imported and called directly
tests that claim web language support without loading Pyrlang source
tests that call only an Erlang helper app while claiming Pyrlang app support
```

An Erlang helper application is acceptable for a transport-only server test, but
that test must be labeled transport-only. It is not evidence that Pyrlang web
source runs.

---

# 2. Current Scope

Pyrunicorn should be built in this order:

```text
1. BEAM-native HTTP listener and worker actor skeleton.
2. Minimal WSGI request/response contract.
3. Pyrlang module loading through the Pyrlang runtime.
4. module:callable resolution inside a worker actor.
5. Django-shaped settings-module boot value.
6. Clear errors for unsupported language or web features.
```

This scope is intentionally smaller than Django. ORM, admin, templates, forms,
auth, sessions, static files, email, cache, tasks, ASGI, database integrations,
GIS, and production HTTP completeness are out of scope until the Pyrlang runtime
can execute the smaller WSGI path correctly from Pyrlang source.

---

# 3. Architecture

Pyrunicorn is a BEAM-native WSGI server.

```text
Client
  -> listener actor
  -> connection actor
  -> HTTP parser
  -> WSGI worker actor
  -> Pyrlang application callable
  -> response writer
```

A WSGI worker actor owns:

```text
one Pyrlang heap
one module table
one loaded application callable
one optional settings-module value
one application or middleware callable chain
```

Workers do not share mutable Python objects. Multiple workers may run in
parallel because they are BEAM processes.

---

# 4. WSGI Contract

The first web compatibility target is synchronous WSGI.

Pyrunicorn must load an application callable by Pyrlang module path:

```bash
pyrunicorn mysite.wsgi:application \
  --bind 0.0.0.0:8000 \
  --workers 4 \
  --django-settings-module mysite.settings
```

This command must be a BEAM-native entrypoint such as an escript, release
command, or equivalent BEAM launcher. It must not be a `python -m` wrapper or a
shell script that invokes CPython to run the application.

For each request, Pyrunicorn calls a Pyrlang application callable:

```python
result = application(environ, start_response)
```

Required WSGI pieces:

```text
environ dict with standard CGI/WSGI keys
wsgi.input stream object
wsgi.errors stream object
start_response(status, headers, exc_info=None)
iterable response body
close() on response iterable when present
basic error handling before and after headers are sent
```

The first worker class is `sync_wsgi`: one request at a time per worker actor.
Parallelism comes from multiple worker actors, not shared-memory threads.

---

# 5. Django-Shaped Boundary

"Django-shaped" is a boot and deployment boundary, not a Django support claim.

A feature may be described as Django-shaped only when:

```text
the application code is Pyrlang source
the source is loaded through the Pyrlang runtime
the callable executes inside a Pyrlang actor
the behavior is tested through Pyrunicorn or the Pyrlang runtime
CPython is absent from the request path
```

The first Django-shaped milestone is:

```text
load a Pyrlang-source WSGI module
set an optional settings-module value in actor-local state
resolve the WSGI application callable
serve a trivial response through Pyrunicorn
```

Do not claim Django support at this milestone.

---

# 6. Worker Failure Handling

Pyrunicorn should use BEAM process monitoring and restart behavior where that
is part of the current web scope.

Expected behavior:

```text
worker crash does not crash the server
request crash becomes HTTP 500 when possible
worker process replacement is explicit and testable
```

Listener supervision trees and external resource policies are outside the
current web scope.

---

# 7. Delete or Keep Out

Delete or keep out of the web runtime path anything that makes the boundary
unclear:

```text
Python runner entrypoints
pyrlang.runner as a web boot path
shell wrappers that invoke CPython to run the app
CPython subprocess execution of Pyrlang source
tests that claim Django support without loading code through Pyrlang
tests that claim Pyrlang WSGI support while calling only Erlang helper apps
WSGI adapters that call CPython Django directly
thread-based actor simulations
database shims that expose shared mutable CPython objects
documentation that describes CPython wrappers as Pyrlang milestones
```

Keep transport experiments only if they are labeled as transport experiments and
do not pretend to be Pyrlang language execution.

---

# 8. Acceptance Checklist

Pyrunicorn is on track only when these statements are true:

```text
The server starts as a BEAM-native entrypoint.
The WSGI application is loaded by the Pyrlang runtime.
The application callable executes inside a Pyrlang actor.
Each worker actor has isolated module globals and heap state.
No request path requires CPython.
No worker parallelism depends on CPython threads.
External resources, if any, do not execute Pyrlang source.
Worker failures are visible to BEAM monitoring and restart handling.
Unsupported Django-shaped features fail clearly instead of falling back to CPython.
```

If any statement is false, the implementation may still be a useful experiment,
but it is not Pyrlang web execution.
