# Pyrlang Language Specification

**Draft version:** 0.6

Pyrlang is Python implemented in Erlang/OTP to run on the BEAM.

This is the project boundary:

```text
Pyrlang source is Python syntax.
Pyrlang execution is BEAM-resident.
```

Pyrlang is not Python code that looks like Erlang. It is not a CPython package
that exposes Erlang-looking APIs. It is not a runner that hands Pyrlang files to
CPython.

The short semantic rule is:

```text
Inside one BEAM actor, Pyrlang behaves like Python.
Between BEAM actors, Pyrlang behaves like Erlang.
```

Examples in this document are Pyrlang source examples. They are not CPython
module examples:

```python
from erlang import spawn, receive
```

That imports a Pyrlang standard interop module while running under the Pyrlang
BEAM runtime. It must not be implemented as an importable CPython package named
`erlang`.

---

# 1. Runtime Boundary

A valid implementation executes Pyrlang programs inside the BEAM runtime.

Valid runtime forms:

```text
Erlang/OTP interpreter for Pyrlang source
compiler from Pyrlang source to BEAM code
hybrid parser/evaluator/compiler implemented on the BEAM
BEAM-native standard library modules
BEAM ports, NIFs, or supervised OS processes for external resources
```

External resources may be used for files, sockets, databases, or other services.
They must not be used to execute Pyrlang source.

Invalid runtime forms:

```text
executing Pyrlang programs with CPython
delegating source execution to runpy, exec, eval, or python -m
shipping pyrlang.runner as the language runtime
keeping a CPython runner fallback
wrapping CPython functions in actors and calling that Pyrlang
simulating BEAM actors with Python queues, asyncio tasks, or threading
using CPython as the hidden runtime behind WSGI, Django-shaped boot, or web demos
```

CPython may be used as a development tool for tests, scripts, or generated files
when it is outside the Pyrlang execution path. CPython must never be required to
run a Pyrlang program.

---

# 2. Project Goals

Pyrlang aims to provide:

```text
Python syntax for supported source files
Python semantics for supported local object behavior
BEAM-native actors
BEAM scheduling across cores
actor-local mutable heaps
actor-local module state
message passing with copied or imported values
links, monitors, exits, and supervision primitives
explicit Erlang/OTP interop
```

Erlang/OTP concepts appear through standard modules and runtime behavior, not by
changing Python syntax into Erlang syntax.

Pyrlang deliberately does not aim to provide:

```text
CPython bytecode compatibility
CPython C extension ABI compatibility
CPython frame object compatibility
CPython reference-counting semantics
deterministic __del__ timing
GIL compatibility
shared mutable memory across actors
arbitrary CPython package execution
exact CPython implementation internals
```

Unsupported Python features must fail clearly. They must not fall back to
CPython.

---

# 3. Core Runtime Requirements

The core runtime is the foundation for every other feature.

Required runtime pieces:

```text
source loading
lexing and parsing for the supported Pyrlang subset
AST or equivalent internal representation
actor-local value representation
actor-local mutable heap
function calls and lexical scopes
class and instance objects
attribute lookup
exceptions
imports and actor-local module state
actor spawn, send, and receive
selective receive
message copy/import at actor boundaries
links, monitors, exits, and supervision primitives
explicit Erlang/OTP interop
```

The runtime may grow incrementally, but every milestone must run on the BEAM. A
CPython-hosted prototype is not a Pyrlang milestone.

---

# 4. Source Language

Pyrlang source uses Python syntax. The supported subset should grow in
dependency order.

Initial language surface:

```text
names and assignment
literals: None, bool, int, float, str, bytes
tuples, lists, dicts, and sets
attribute access
subscript access
calls
if / elif / else
while
for
break / continue / return / pass
try / except / finally / raise
with
def
lambda
class
decorators
comprehensions
generators and yield
imports
```

Python syntax not supported by the BEAM runtime is unsupported for now.
Unsupported syntax must fail with a clear error and must not be passed to
CPython.

---

# 5. Local Python Semantics

Inside one actor, Pyrlang should preserve ordinary Python object behavior where
supported user code observes it.

Important local semantics:

```text
object identity
mutable lists and dicts
instance dictionaries
class dictionaries
dynamic attributes
bound methods
descriptors
property
staticmethod
classmethod
operator overloading
multiple inheritance
C3 MRO
super()
metaclass selection and class construction
iteration protocol
context managers
exception propagation
```

Exact CPython memory layout, reference counts, frame objects, traceback object
internals, and bytecode objects are not part of this contract.

---

# 6. Actor Semantics

An actor is a Pyrlang execution entity backed by a BEAM process.

Each actor owns:

```text
pid
mailbox
actor-local Pyrlang heap
actor-local module table
call stack, not necessarily user-visible
links and monitors
optional supervisor metadata
```

Actor operations are exposed through Pyrlang source and backed by BEAM process
semantics:

```python
from erlang import self, spawn, send, receive

def worker():
    msg = receive()
    send(msg["reply_to"], {"ok": msg["value"]})

pid = spawn(worker)
send(pid, {"value": 42, "reply_to": self()})
reply = receive()
```

Message ordering is guaranteed per sender to a receiver. Global ordering across
multiple senders is not guaranteed. Blocking receives should support timeouts.
Selective receive is part of the actor model.

---

# 7. Sendability

Always sendable values:

```text
None
bool
int
float
str
bytes
atoms
pids
references
tuples containing sendable values
frozen immutable values containing sendable values
```

Mutable values may be sent only by copying or by an explicit runtime-defined
transfer/import protocol:

```text
lists
dicts
sets
instances
exceptions
user-defined objects
```

Unsendable values include actor-local resources such as open files, sockets,
database connections, live generators, live iterators, and opaque BEAM resources
unless a module defines a specific proxy protocol for them.

---

# 8. Imports and Modules

Modules are actor-local by default. Importing a module creates or reuses that
module in the importing actor's module table.

Module globals are not shared mutable state between actors. If two actors import
the same Pyrlang module, each actor observes its own module global objects unless
the module explicitly talks to a shared service actor.

The core runtime reserves this module name:

```text
erlang
```

The `erlang` module exposes BEAM interop and actor primitives. It is a Pyrlang
standard module, not a CPython package.

---

# 9. Errors and Exits

Pyrlang supports Python-style exceptions for ordinary language errors.

Actor exits are separate runtime events. They may be represented as messages,
exceptions, or supervisor signals depending on the operation, but the actor
boundary must stay explicit.

Links, monitors, and supervisors follow Erlang/OTP semantics where possible:

```text
links propagate exits
monitors report exits without linking fate
supervisors restart children according to child specs
```

---

# 10. BEAM Interop

Pyrlang may call Erlang modules through explicit interop APIs. Interop must be
visible in source or configuration. It must not make CPython the execution
engine.

Preferred type mapping:

```text
Pyrlang None      <-> Erlang undefined or nil by API convention
Pyrlang bool      <-> Erlang true/false
Pyrlang int       <-> Erlang integer
Pyrlang float     <-> Erlang float
Pyrlang str       <-> Erlang binary
Pyrlang bytes     <-> Erlang binary
Pyrlang tuple     <-> Erlang tuple
Pyrlang list      <-> Erlang list when proper and acyclic
Pyrlang dict      <-> Erlang map
Pyrlang atom      <-> Erlang atom
Pyrlang pid       <-> Erlang pid
Pyrlang reference <-> Erlang reference
```

The runtime must avoid unbounded atom creation from untrusted input.

Native code must not block BEAM schedulers. Blocking external work belongs in
ports, supervised OS processes, dirty schedulers, or dedicated resource actors.

---

# 11. Delete or Keep Out

Delete or keep out of the runtime path anything that depends on these ideas:

```text
pyrlang.runner as the executor for Pyrlang programs
python -m pyrlang.runner or equivalent wrapper entrypoints
Python packages that merely expose Erlang-looking names
Python APIs that make CPython code look like actor code
CPython subprocess execution of Pyrlang source
tests that pass because CPython executed the source
tests that bypass the Pyrlang parser/evaluator/compiler for language claims
thread-based actor simulations
shared mutable CPython objects crossing actor boundaries
web demos that call CPython Django and label it Pyrlang
documentation that presents CPython wrappers as Pyrlang milestones
examples that teach users to import Pyrlang as a CPython package
```

Transport experiments, generators, scripts, and host tools are acceptable only
when they are clearly outside the Pyrlang execution path.

---

# 12. Conformance Checklist

A change moves the project toward Pyrlang only if it preserves these rules:

```text
Pyrlang source is executed by BEAM-resident runtime code.
CPython is not in the execution path for Pyrlang programs.
The runnable entrypoint is BEAM-native.
Each actor owns its heap.
Mutable objects are not shared across actors.
Messages are copied or imported at actor boundaries.
Python object semantics work inside one actor for supported features.
Actor primitives map to BEAM process semantics.
Supervision maps to OTP supervision concepts.
Erlang interop is explicit.
Unsupported Python features fail clearly instead of falling back to CPython.
```

Anything that violates those rules should be deleted or moved out of the runtime
path before more features are added.
