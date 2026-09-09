# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright contributors to the vLLM project

"""Compatibility shim for uvloop on platforms where it is unavailable."""

import sys

if sys.platform == "win32":
    import asyncio

    class _WindowsUvloopCompat:
        """Provide the uvloop.run() surface using a ZMQ-compatible loop."""

        @staticmethod
        def run(main):
            return asyncio.run(main, loop_factory=asyncio.SelectorEventLoop)

    uvloop = _WindowsUvloopCompat()
else:
    import uvloop

__all__ = ["uvloop"]
