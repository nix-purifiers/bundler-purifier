# SPDX-License-Identifier: MIT
"""Resolve RubyGems repository inputs through the shared Nix source adapter."""
import json
import sys

import project_inputs as shared

request = json.load(sys.stdin)
inputs = shared.pin(request['references'], request.get('previous', ()), request.get('refresh', False))
views = shared.native_views(inputs, 'rubygems', request.get('roots'))
json.dump({'inputs': inputs, 'views': [
    {key: str(value) for key, value in view.items()} for view in views
]}, sys.stdout)
