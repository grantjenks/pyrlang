ERLC ?= erlc
ERL ?= erl
ERLFMT ?= erlfmt
ERLC_FLAGS ?= -Wall -Werror

EBIN := ebin
INCLUDE := include
SRC := $(wildcard src/*.erl)
TEST := $(wildcard test/*_tests.erl)
FORMAT_FILES := $(SRC) $(TEST) $(wildcard include/*.hrl)
MODULES := pyrlang_heap_tests, pyrlang_actor_tests, pyrlang_eval_tests, pyrlang_object_tests, pyrlang_module_tests, pyrlang_supervisor_tests, pyrlang_sqlite_tests, pyrunicorn_wsgi_tests, pyrlang_cli_tests

.PHONY: all compile test format format-check entrypoints clean

all: compile

$(EBIN):
	mkdir -p $(EBIN)

compile: $(EBIN)
	$(ERLC) $(ERLC_FLAGS) -I $(INCLUDE) -o $(EBIN) $(SRC) $(TEST)

test: compile
	$(ERL) -pa $(EBIN) -noshell -eval 'case eunit:test([$(MODULES)], [verbose]) of ok -> halt(0); _ -> halt(1) end.'

format:
	$(ERLFMT) -w $(FORMAT_FILES)

format-check:
	$(ERLFMT) -c $(FORMAT_FILES)

entrypoints: compile
	chmod +x bin/pyrlang bin/pyrunicorn

clean:
	rm -rf $(EBIN)
