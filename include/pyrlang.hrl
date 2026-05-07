-define(PY_HEAP_KEY, pyrlang_heap).
-define(PY_ACTOR_KEY, pyrlang_actor).

-define(PY_MSG, pyrlang_message).
-define(PY_WIRE, pyrlang_wire).
-define(PY_OBJ, pyrlang_object).
-define(PY_REF, py_ref).

-type py_ref() :: {?PY_REF, pos_integer()}.
-type py_heap_cell() :: #{type := atom(), data := term()}.
