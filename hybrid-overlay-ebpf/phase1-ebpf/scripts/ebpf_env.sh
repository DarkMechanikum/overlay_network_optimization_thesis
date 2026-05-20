#!/usr/bin/env bash

run_in_attach_ns() {
	if [[ -n "${NETNS:-}" ]]; then
		nsenter --net="${NETNS}" "$@"
	else
		"$@"
	fi
}

maybe_sudo() {
	if [[ "${EUID}" -eq 0 ]]; then
		"$@"
	else
		sudo "$@"
	fi
}
