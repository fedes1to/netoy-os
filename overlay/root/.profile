#!/bin/sh
# Auto-start netoy-tui on the primary VGA (tty1) and serial (ttyS0) consoles.
# Spare consoles just fall through to a normal root shell.

export PATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

current_tty=$(tty 2>/dev/null)
current_tty=${current_tty#/dev/}
[ -z "$current_tty" ] && return

case "$current_tty" in
	tty1|ttyS0)
		# VGA console uses linux terminfo; serial uses a generic vt100 entry
		# which works with any serial terminal emulator.
		case "$current_tty" in
			tty1) export TERM=linux ;;
			*)    export TERM=vt100 ;;
			esac

		# Serial consoles often report 0x0 until the terminal emulator sends a
		# resize event, which never happens in headless setups. Force a sane size.
		set -- $(stty size 2>/dev/null)
		rows=$1
		cols=$2
		if [ -z "$rows" ] || [ -z "$cols" ] || [ "$rows" -eq 0 ] || [ "$cols" -eq 0 ]; then
			stty rows 24 cols 80 2>/dev/null || true
		fi

		# Make sure the terminal starts in a usable cooked mode; if a previous
		# TUI session left the tty in raw mode the login shell will be unusable.
		stty sane 2>/dev/null || true

		# Restore the terminal to a sane state if netoy-tui is killed or panics.
		restore_tty() {
			stty sane 2>/dev/null || true
			printf '\033[?25h' 2>/dev/null || true
		}
		trap restore_tty INT TERM HUP EXIT

		if [ -x /usr/local/bin/netoy-tui ]; then
			clear 2>/dev/null || true
			/usr/local/bin/netoy-tui
			clear 2>/dev/null || true
			echo "netoy-tui exited. Dropping to shell."
		else
			echo "netoy-tui is missing" >&2
		fi

		restore_tty
		trap - INT TERM HUP EXIT
		;;
esac
