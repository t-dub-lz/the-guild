# Makefile - dispatches to Justfile
%:
	@just $@

.DEFAULT_GOAL := help

help:
	@just --list
