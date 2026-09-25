PYTHON ?= python3

.DEFAULT_GOAL := help
.PHONY: help install update test check

help:
	@printf '%s\n' \
		'MikroTik Dude Telegram Queue' \
		'' \
		'make install  Installa script, coda e scheduler sul router' \
		'make update   Aggiorna gli script conservando configurazione e stato' \
		'make test     Esegue i test di integrazione sul router di prova' \
		'make check    Controlla localmente la sintassi degli strumenti Python' \
		'' \
		'Interprete configurabile: make check PYTHON=python3.12'

install:
	$(PYTHON) script/deploy.py --production --enable-scheduler

update:
	$(PYTHON) script/deploy.py --production

test:
	$(PYTHON) script/test_router.py

check:
	$(PYTHON) -m py_compile script/router.py script/deploy.py script/test_router.py
