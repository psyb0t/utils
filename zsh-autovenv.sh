#!/usr/bin/env bash
function cd {
  builtin cd "$@" && { # Use the built-in cd command and proceed if successful
    if [[ -d "venv" && -f "venv/bin/activate" ]]; then
      echo "Activating venv..."
      source "venv/bin/activate"
    elif [[ -n "$VIRTUAL_ENV" ]]; then
      echo "Deactivating venv..."
      deactivate
    fi
  }
}
