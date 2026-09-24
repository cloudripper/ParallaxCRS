"""Claude Code bug-finding CRS package for CRC-Template.

Submodules are imported explicitly to keep imports lightweight:
    from crs.src.claude_node import ClaudeCodeNode, ClaudeState, configure_claude_env
    from crs.src import prompts
    from crs.tools import coverage, fuzzer, codeql   # no langchain dependency
"""
