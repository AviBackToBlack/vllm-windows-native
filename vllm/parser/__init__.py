# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: Copyright contributors to the vLLM project

from typing import TYPE_CHECKING, Any

from vllm.parser.abstract_parser import (
    DelegatingParser,
    Parser,
)
from vllm.parser.parser_manager import ParserManager

if TYPE_CHECKING:
    from vllm.parser.harmony import HarmonyParser


def __getattr__(name: str) -> Any:
    if name == "HarmonyParser":
        # Harmony's structural-tag support depends on xgrammar, which is not
        # available on every platform. Keep the optional backend lazy so the
        # general CLI/server import path does not require it.
        from vllm.parser.harmony import HarmonyParser

        return HarmonyParser
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")


__all__ = [
    "Parser",
    "DelegatingParser",
    "HarmonyParser",
    "ParserManager",
]
